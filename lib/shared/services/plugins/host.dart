// 职责: 发现、配置并激活插件，执行工具调用与设置页操作，维护状态及每次调用的独立资源。
// 关联文件:
//   lib/shared/services/plugins/config.dart
//   lib/shared/services/plugins/runtime.dart
//   lib/shared/models/plugin/manifest.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../agent/agent_tool_dispatcher.dart';
import '../../database/daos/plugin_dao.dart';
import '../../logger/app_logger.dart';
import '../../models/plugin/action.dart';
import '../../models/plugin/manifest.dart';
import '../../models/plugin/setting_field.dart';
import 'config.dart';
import 'data.dart';
import 'http.dart';
import 'registry.dart';
import 'runtime.dart';
import '../../models/plugin/request.dart';
import 'package:uuid/uuid.dart';

final _log = AppLogger.forModule('Plugin');

class PluginPackage {
  PluginPackage(this.path, this.manifest, this.code, {this.source = 'bundled'});
  final String path, code, source;
  final PluginManifest manifest;
}

class PluginStatus {
  PluginStatus({
    required this.id,
    required this.path,
    this.manifest,
    this.enabled = false,
    this.state = 'disabled',
    this.error,
    this.source = 'bundled',
    this.needsConfig = false,
  });
  final String id, path, source;
  final PluginManifest? manifest;
  bool enabled;
  String state;
  String? error;

  /// 必填配置未填写；此时不能开启插件。
  bool needsConfig;
}

typedef PluginExecutorFactory =
    PluginExecutor Function(PluginHostCall call, void Function() stop);

class PluginHostService {
  PluginHostService({
    required this.dao,
    required this.registry,
    this.packages,
    this.data,
    PluginExecutorFactory? executorFactory,
    String? platform,
    this.applicationSupport,
  }) : executorFactory =
           executorFactory ??
           ((call, stop) => PluginRuntime(hostCall: call, onStop: stop)),
       platform = platform ?? Platform.operatingSystem;
  final Future<Directory> Function()? applicationSupport;
  Future<Directory> supportDirectory() =>
      applicationSupport?.call() ?? getApplicationSupportDirectory();
  final PluginDataService? data;
  final PluginDao dao;
  final PluginRegistry registry;
  final Future<List<PluginPackage>> Function()? packages;
  final PluginExecutorFactory executorFactory;
  final String platform;
  final _changes = StreamController<List<PluginStatus>>.broadcast();
  Future<PluginRequestContext> requestContext({
    required String? sessionId,
    required String agentId,
    required String fallbackSessionId,
    ({String? workId, String mode})? scope,
  }) async {
    final row = scope == null && sessionId != null
        ? await dao.attachedDatabase.aiChatSessionDao.getById(sessionId)
        : null;
    if (scope == null && sessionId != null && row == null) {
      throw PluginHostError('invalid_scope', 'Host session no longer exists');
    }
    final workId = scope != null
        ? scope.workId
        : (row?.novelId.isNotEmpty == true ? row!.novelId : null);
    if (workId != null &&
        await dao.attachedDatabase.novelDao.get(workId) == null) {
      throw PluginHostError('invalid_scope', 'Host work no longer exists');
    }
    return PluginRequestContext(
      requestId: const Uuid().v4(),
      sessionId: sessionId ?? fallbackSessionId,
      workId: workId,
      agentId: agentId,
      mode: scope?.mode ?? row?.mode ?? 'headless',
      boundSessionId: row?.id,
    );
  }

  Future<bool> _requestCurrent(PluginRequestContext request) async {
    if (request.workId != null &&
        await dao.attachedDatabase.novelDao.get(request.workId!) == null) {
      return false;
    }
    final id = request.boundSessionId;
    if (id == null) {
      return true;
    }
    final row = await dao.attachedDatabase.aiChatSessionDao.getById(id);
    return row != null &&
        (row.novelId.isEmpty ? null : row.novelId) == request.workId;
  }

  final _registrations = <String, List<Map<String, dynamic>>>{};
  final _packages = <String, PluginPackage>{};
  final _statuses = <String, PluginStatus>{};
  final _serial = <String, Future<void>>{};
  Future<void> _snapshotBarrier = Future<void>.value();
  final _running = <String, int>{};
  final _maintenance = <String>{};
  final _drainers = <String, Completer<void>>{};

  Future<void> validatePackage(PluginPackage package) async {
    final definitions = await executorFactory(
      _applyApi(package.manifest.id),
      () {},
    ).activate(package.manifest, package.code);
    final tools = <PluginTool>[];
    for (final definition in definitions) {
      if (definition['kind'] == null) {
        tools.add(
          PluginTool(
            package.manifest.id,
            package.manifest.name,
            package.source,
            definition,
          ),
        );
      }
    }
    registry.validate(package.manifest.id, tools);
  }

  final _queues = <String, List<Completer<bool>>>{};
  Future<void>? _starting;
  bool _disposed = false;
  List<PluginStatus> get statuses => List.unmodifiable(_statuses.values);
  Stream<List<PluginStatus>> get changes => _changes.stream;
  void _emit() {
    if (!_disposed) {
      _changes.add(statuses);
    }
  }

  Future<String> readPackageText(
    PluginPackage package,
    String relative, {
    required int maxBytes,
  }) async {
    if (relative.startsWith('/') ||
        relative.contains('\\') ||
        relative.contains(':') ||
        relative.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw const FormatException('Invalid package resource path');
    }
    if (package.source == 'bundled') {
      final bytes = await rootBundle.load('${package.path}/$relative');
      if (bytes.lengthInBytes > maxBytes) {
        throw const FormatException('Package resource exceeds limit');
      }
      return utf8.decode(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    }
    final support = await supportDirectory();
    final root = Directory(p.join(support.path, package.path));
    final file = File(p.joinAll([root.path, ...relative.split('/')]));
    if (!p.isWithin(
          await root.resolveSymbolicLinks(),
          await file.resolveSymbolicLinks(),
        ) ||
        await file.length() > maxBytes) {
      throw const FormatException(
        'Package resource escapes root or exceeds limit',
      );
    }
    return file.readAsString();
  }

  Future<void> start() => _starting ??= _start();
  Future<List<PluginPackage>> _discover() async {
    final assets = await AssetManifest.loadFromAssetBundle(rootBundle);
    final result = <PluginPackage>[];
    for (final path in assets.listAssets().where(
      (p) => RegExp(r'^assets/plugins/[^/]+/plugin.json$').hasMatch(p),
    )) {
      try {
        final manifest = PluginManifest.fromJson(
          jsonDecode(await rootBundle.loadString(path)) as Map<String, dynamic>,
        );
        final directory = path.substring(0, path.lastIndexOf('/'));
        final data = await rootBundle.load('$directory/${manifest.main}');
        if (data.lengthInBytes > 2 * 1024 * 1024) {
          throw const FormatException('Entry exceeds 2 MB');
        }
        result.add(
          PluginPackage(
            directory,
            manifest,
            utf8.decode(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            ),
          ),
        );
      } catch (error, stack) {
        _statuses[path] = PluginStatus(
          id: path,
          path: path,
          state: 'failed',
          error: error.toString(),
        );
        _log.error(
          'Manifest load failed: $path',
          error: error,
          stackTrace: stack,
        );
      }
    }
    final local = await dao.localPlugins();
    if (local.isNotEmpty) {
      final support = await supportDirectory();
      for (final row in local) {
        try {
          final expected = 'plugins/${row.pluginId}/${row.version}';
          if (row.packagePath != expected) {
            throw const FormatException('Invalid installed plugin path');
          }
          final directory = Directory(
            p.joinAll([support.path, ...expected.split('/')]),
          );
          final manifest = PluginManifest.fromJson(
            jsonDecode(
                  await File(
                    p.join(directory.path, 'plugin.json'),
                  ).readAsString(),
                )
                as Map<String, dynamic>,
          );
          if (manifest.id != row.pluginId || manifest.version != row.version) {
            throw const FormatException('Installed package identity mismatch');
          }
          final file = File(
            p.joinAll([directory.path, ...manifest.main.split('/')]),
          );
          if (await file.length() > 2 * 1024 * 1024) {
            throw const FormatException('Entry exceeds 2 MB');
          }
          result.add(
            PluginPackage(
              expected,
              manifest,
              await file.readAsString(),
              source: 'local',
            ),
          );
        } catch (error, stack) {
          _statuses[row.pluginId] = PluginStatus(
            id: row.pluginId,
            path: row.packagePath,
            source: 'local',
            enabled: row.enabled,
            state: 'failed',
            error: error.toString(),
          );
          _log.error(
            'Local package load failed: ${row.pluginId}',
            error: error,
            stackTrace: stack,
          );
        }
      }
    }
    return result;
  }

  Future<void> _start() async {
    final found = await (packages?.call() ?? _discover());
    final ordered = <(PluginPackage, DateTime)>[];
    for (final package in found) {
      final manifest = package.manifest;
      if (_packages.containsKey(manifest.id)) {
        throw StateError('Duplicate plugin id: ${manifest.id}');
      }
      await dao.register(
        pluginId: manifest.id,
        version: manifest.version,
        source: package.source,
        packagePath: package.path,
        defaultEnabled: manifest.defaultEnabled,
      );
      final row = (await dao.getPlugin(manifest.id))!;
      _packages[manifest.id] = package;
      _statuses[manifest.id] = PluginStatus(
        id: manifest.id,
        path: package.path,
        manifest: manifest,
        enabled: row.enabled,
        source: package.source,
        needsConfig: await _missingRequiredKey(manifest) != null,
      );
      ordered.add((package, row.createdAt));
    }
    ordered.sort((a, b) {
      final c = a.$2.compareTo(b.$2);
      return c != 0 ? c : a.$1.manifest.id.compareTo(b.$1.manifest.id);
    });
    _emit();
    for (final item in ordered) {
      await _activate(item.$1.manifest.id);
    }
  }

  Future<void> _activate(String pluginId) async {
    final status = _statuses[pluginId]!;
    registry.remove(pluginId);
    _registrations.remove(pluginId);
    status.error = null;
    status.state = 'activating';
    if (!status.enabled) {
      status.state = 'disabled';
      _emit();
      return;
    }
    if (!status.manifest!.platforms.contains(platform)) {
      status.state = 'unsupported';
      _emit();
      return;
    }
    if (!(await dao.grantedPermissions(
      pluginId,
    )).containsAll(status.manifest!.permissions)) {
      status.state = 'needs_permission';
      _emit();
      return;
    }
    if (await _missingRequiredKey(status.manifest!) != null) {
      status.needsConfig = true;
      status.state = 'needs_config';
      _emit();
      return;
    }
    status.state = 'activating';
    _emit();
    if (!await _acquire(pluginId, allowMaintenance: true)) {
      return;
    }
    try {
      if (_disposed) {
        return;
      }
      final package = _packages[pluginId]!;
      final runtime = executorFactory(_applyApi(pluginId), () {});
      final definitions = await runtime.activate(
        package.manifest,
        package.code,
      );
      if (_disposed) {
        return;
      }
      registry.register(pluginId, [
        for (final definition in definitions)
          if (definition['kind'] == null)
            PluginTool(
              pluginId,
              package.manifest.name,
              package.source,
              definition,
            ),
      ]);
      _registrations[pluginId] = List.unmodifiable(definitions);
      status.state = 'available';
    } catch (error, stack) {
      status.state = 'failed';
      status.error = error.toString();
      _log.error(
        'Activation failed: $pluginId',
        error: error,
        stackTrace: stack,
      );
    } finally {
      _releaseQueue(pluginId);
    }
    _emit();
  }

  Future<T> mutate<T>(String id, Future<T> Function() action) {
    final snapshot = _snapshotBarrier;
    final next = (_serial[id] ?? Future<void>.value()).then((_) async {
      await snapshot;
      if (_disposed) {
        throw PluginHostError('unavailable', 'Plugin host is disposed');
      }
      return action();
    });
    _serial[id] = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// Refresh an installed package only after its registry transaction commits.
  Future<void> loadInstalled(PluginPackage package) async {
    final id = package.manifest.id;
    final row = await dao.getPlugin(id);
    if (row == null) {
      throw StateError('Installed plugin registration is missing');
    }
    _packages[id] = package;
    _statuses[id] = PluginStatus(
      id: id,
      path: package.path,
      source: package.source,
      manifest: package.manifest,
      enabled: row.enabled,
      needsConfig: await _missingRequiredKey(package.manifest) != null,
    );
    await _activate(id);
  }

  Future<void> confirmPermissions(String id) => mutate(id, () async {
    await dao.grantPermissions(id, _manifest(id).permissions);
    await _activate(id);
  });

  Future<void> revokePermissions(String id) => mutate(id, () async {
    for (final permission in _manifest(id).permissions) {
      await dao.revokePermission(id, permission);
    }
    await _activate(id);
  });

  Future<void> uninstall(String id) => mutate(id, () async {
    await dao.uninstall(id);
    registry.remove(id);
    _registrations.remove(id);
    _packages.remove(id);
    _statuses.remove(id);
    _emit();
  });

  Future<void> setEnabled(String pluginId, bool enabled) {
    return mutate(pluginId, () async {
      await start();
      if (!_packages.containsKey(pluginId)) {
        throw StateError('Unknown plugin: $pluginId');
      }
      if (enabled) {
        final missing = await _missingRequiredKey(
          _packages[pluginId]!.manifest,
        );
        if (missing != null) {
          throw StateError('Required plugin configuration: $missing');
        }
      }
      await dao.setEnabled(pluginId, enabled);
      _statuses[pluginId]!.enabled = enabled;
      await _activate(pluginId);
    });
  }

  /// 第一个未填写的必填配置项；全部已填写时返回 null。
  Future<String?> _missingRequiredKey(PluginManifest manifest) async {
    final required = manifest.settings.where((field) => field.required);
    if (required.isEmpty) {
      return null;
    }
    final config = await readPluginConfig(dao, manifest);
    for (final field in required) {
      if (field.isSecret
          ? !config.savedSecrets.contains(field.key)
          : validatePluginSettingValue(field, config.values[field.key]) !=
                null) {
        return field.key;
      }
    }
    return null;
  }

  PluginManifest _manifest(String pluginId) =>
      _packages[pluginId]?.manifest ??
      (throw StateError('Unknown plugin: $pluginId'));

  Future<PluginConfig> loadConfig(String pluginId) =>
      readPluginConfig(dao, _manifest(pluginId));

  /// 与启停共用串行队列，避免清空必填凭据与开启插件交错。
  Future<void> saveConfig(
    String pluginId, {
    required Map<String, Object?> settings,
    required Map<String, String?> secrets,
  }) {
    return mutate(pluginId, () async {
      final manifest = _manifest(pluginId);
      final disabled = await PluginConfigOrchestrator().save(
        dao: dao,
        manifest: manifest,
        settings: settings,
        secrets: secrets,
      );
      final status = _statuses[pluginId]!;
      status.needsConfig = await _missingRequiredKey(manifest) != null;
      if (disabled) {
        status.enabled = false;
        await _activate(pluginId);
      } else {
        _emit();
      }
    });
  }

  Future<Map<String, dynamic>> execute(
    String name,
    Map<String, dynamic> input, {
    String callId = '',
    String? sessionId,
    ToolExecutionContext? executionContext,
    AgentCancellationToken? cancellation,
    PluginRequestContext? request,
  }) async {
    final tool = registry.resolve(name);
    Map<String, dynamic> unavailable() => {
      'ok': false,
      'error_code': 'plugin_unavailable',
      'error': 'Plugin tool unavailable: $name',
    };
    if (_disposed ||
        tool == null ||
        _statuses[tool.pluginId]?.state != 'available') {
      return unavailable();
    }
    final id = tool.pluginId;
    Map<String, dynamic> cancelled() => {
      'ok': false,
      'plugin_id': id,
      'error_code': 'user_cancelled',
      'error': 'Plugin call cancelled',
      'cancelled': true,
    };
    final acquired = await _acquire(id, cancellation: cancellation);
    if (!acquired) {
      return cancellation?.isCancellationRequested == true
          ? cancelled()
          : unavailable();
    }
    if (cancellation?.isCancellationRequested == true) {
      _releaseQueue(id);
      return cancelled();
    }
    if (_disposed ||
        registry.resolve(name)?.pluginId != id ||
        _statuses[id]?.state != 'available') {
      _releaseQueue(id);
      return unavailable();
    }
    final http = PluginHttpApi();
    final sqlCancellation = AgentCancellationController();
    final unlinkSql = cancellation?.onCancel(sqlCancellation.cancel);
    try {
      final package = _packages[id]!;
      final scope =
          request ??
          await requestContext(
            sessionId: sessionId,
            agentId: 'tool',
            fallbackSessionId: callId.isEmpty ? const Uuid().v4() : callId,
          );
      if (!await _requestCurrent(scope)) {
        throw PluginHostError(
          'invalid_scope',
          'Request scope is no longer valid',
        );
      }
      final expected = _registrations[id]!;
      final secrets = await dao.secretValues(id);
      if (cancellation?.isCancellationRequested == true) {
        return cancelled();
      }
      final runtime = executorFactory(
        _hostApi(
          id,
          package,
          http,
          secrets,
          sessionId: scope.workId == null ? null : sessionId,
          workId: scope.workId,
          executionContext: executionContext,
          toolName: name,
          cancellation: sqlCancellation.token,
        ),
        () {
          http.cancel();
          sqlCancellation.cancel();
        },
      );

      return await runtime.invoke(
        package.manifest,
        package.code,
        expected,
        name,
        input,
        callId,
        cancellation,
        request: scope.toJson(),
      );
    } catch (error) {
      return {
        'ok': false,
        'plugin_id': id,
        'error_code': error is PluginExecutionError
            ? error.code
            : error is PluginHostError
            ? error.code
            : 'plugin_error',
        'error': error is PluginExecutionError
            ? error.message
            : error is PluginHostError
            ? error.message
            : error.toString(),
        if (error is PluginExecutionError && error.code == 'user_cancelled')
          'cancelled': true,
      };
    } finally {
      unlinkSql?.call();
      sqlCancellation.cancel();
      http.cancel();
      _releaseQueue(id);
    }
  }

  /// 执行设置页操作。[settings]、[secrets] 是表单里尚未保存的值，覆盖已保存配置，
  /// 凭据为 null 表示待清空。插件未开启时也可执行，便于开启前验证配置。
  Future<PluginActionResult> runAction(
    String pluginId,
    String name, {
    Map<String, Object?> settings = const {},
    Map<String, String?> secrets = const {},
    AgentCancellationToken? cancellation,
  }) async {
    await start();
    final package = _packages[pluginId];
    final redactions = [
      for (final value in secrets.values)
        if (value != null && value.isNotEmpty) value,
    ];
    PluginActionResult failed(String code, String message) {
      _log.warning(
        'Action failed: $pluginId.$name $code '
        '${_redact(message, redactions)}',
      );
      return (ok: false, code: code);
    }

    if (_disposed ||
        package == null ||
        !package.manifest.actions.any((action) => action.name == name)) {
      return failed('unavailable', 'Unknown plugin action');
    }
    if (!package.manifest.platforms.contains(platform)) {
      return failed('unsupported', 'Plugin does not support $platform');
    }
    if (!await _acquire(pluginId, cancellation: cancellation)) {
      return failed('unavailable', 'No execution slot');
    }
    final http = PluginHttpApi();
    final sqlCancellation = AgentCancellationController();
    final unlinkSql = cancellation?.onCancel(sqlCancellation.cancel);
    try {
      redactions.addAll(await dao.secretValues(pluginId));
      final runtime = executorFactory(
        _hostApi(
          pluginId,
          package,
          http,
          redactions,
          cancellation: sqlCancellation.token,
          draftSettings: settings,
          draftSecrets: secrets,
        ),
        () {
          http.cancel();
          sqlCancellation.cancel();
        },
      );
      final value = await runtime.runAction(
        package.manifest,
        package.code,
        name,
        const Uuid().v4(),
        cancellation,
      );
      if (value['ok'] == true) {
        return (ok: true, code: null);
      }
      return failed(
        value['code'] is String ? value['code'] as String : 'failed',
        '${value['message'] ?? ''}',
      );
    } on PluginExecutionError catch (error) {
      return failed(
        error.code == 'plugin_timeout' ? 'timeout' : error.code,
        error.message,
      );
    } catch (error) {
      return failed('plugin_error', error.toString());
    } finally {
      unlinkSql?.call();
      sqlCancellation.cancel();
      http.cancel();
      _releaseQueue(pluginId);
    }
  }

  /// 插件可调用的宿主 API。设置页操作传入表单草稿，覆盖已保存的配置。
  PluginHostCall _hostApi(
    String id,
    PluginPackage package,
    PluginHttpApi http,
    List<String> secrets, {
    String? sessionId,
    String? workId,
    ToolExecutionContext? executionContext,
    String? toolName,
    AgentCancellationToken? cancellation,
    bool promptReadOnly = false,
    Duration sqlWaitBudget = const Duration(seconds: 5),
    Map<String, Object?> draftSettings = const {},
    Map<String, String?> draftSecrets = const {},
  }) => (method, args) async {
    if (promptReadOnly &&
        !const {
          'sqlite.query',
          'storage.get',
          'settings.get',
          'log.info',
          'log.warn',
          'log.error',
        }.contains(method)) {
      throw PluginHostError(
        'permission_denied',
        'Prompt providers may only read private data/settings and log diagnostics',
      );
    }
    if (method == 'ai.generateText') {
      throw PluginHostError(
        'permission_denied',
        'AI generation is only available inside a scheduled task',
      );
    }
    if (method.startsWith('chapters.') || method.startsWith('characters.')) {
      final parts = method.split('.');
      final permission =
          '${parts.first}.${parts.last == 'update' ? 'write' : 'read'}';
      if (!package.manifest.permissions.contains(permission) ||
          !(await dao.grantedPermissions(id)).contains(permission)) {
        throw PluginHostError(
          'permission_denied',
          'Missing permission: $permission',
        );
      }
      final service = data;
      if (service == null) {
        throw StateError('Plugin data service is not configured');
      }
      return service.call(
        method,
        args,
        sessionId: sessionId,
        scopeWorkId: workId,
        executionContext: executionContext,
        toolName: toolName,
      );
    }
    if (method == 'http.fetch') {
      return http.fetch(args);
    }
    if (['storage.get', 'storage.set', 'storage.remove'].contains(method)) {
      final key = args['key'];
      if (key is! String || key.isEmpty || key.length > 256) {
        throw PluginHostError(
          'invalid_argument',
          'Storage key must be 1–256 characters',
        );
      }
      if (method == 'storage.get') {
        final value = await dao.getStorage(id, 'data.$key');
        return value == null ? null : jsonDecode(value);
      }
      if (method == 'storage.remove') {
        await dao.removePluginData(id, key);
        return null;
      }
      if (!args.containsKey('value')) {
        throw PluginHostError('invalid_argument', 'Storage value is required');
      }
      try {
        await dao.setPluginData(id, key, jsonEncode(args['value']));
      } on PluginStorageQuotaException {
        throw PluginHostError('too_large', 'Plugin storage quota exceeded');
      }
      return null;
    }
    if (method == 'settings.get' || method == 'secrets.get') {
      final key = args['key'];
      final field = package.manifest.settings
          .where((field) => field.key == key)
          .firstOrNull;
      if (key is! String ||
          field == null ||
          field.isSecret != (method == 'secrets.get')) {
        throw PluginHostError(
          'invalid_argument',
          'Undeclared $method key: $key',
        );
      }
      if (field.isSecret) {
        if (draftSecrets.containsKey(key)) {
          final value = draftSecrets[key];
          return value == null || value.isEmpty ? null : value;
        }
        return readPluginSecret(dao, id, key);
      }
      if (draftSettings.containsKey(key)) {
        return draftSettings[key] ?? field.defaultValue;
      }
      return readPluginSetting(dao, id, field);
    }
    if (method.startsWith('log.')) {
      return _pluginLog(id, method, args, secrets);
    }
    throw PluginHostError('unavailable', 'Host API not implemented: $method');
  };

  /// apply 阶段只能写日志；插件此时尚未取得凭据，无需脱敏。
  PluginHostCall _applyApi(String id) => (method, args) async {
    if (method.startsWith('log.')) {
      return _pluginLog(id, method, args, const []);
    }
    throw PluginHostError('unavailable', 'Host APIs unavailable during apply');
  };

  Object? _pluginLog(
    String id,
    String method,
    Map<String, dynamic> args,
    List<String> secrets,
  ) {
    final message = args['message'];
    if (message is! String) {
      throw PluginHostError('invalid_argument', 'Log message must be a string');
    }
    final text =
        'plugin=$id ${_redact(message, secrets)}'
        '${args['data'] == null ? '' : ' ${_redact(jsonEncode(args['data']), secrets)}'}';
    switch (method) {
      case 'log.info':
        _log.info(text);
      case 'log.warn':
        _log.warning(text);
      case 'log.error':
        _log.error(text);
      default:
        throw PluginHostError(
          'unavailable',
          'Host API not implemented: $method',
        );
    }
    return null;
  }

  /// 同时替换原文和 JSON 转义后的凭据。
  String _redact(String text, Iterable<String> secrets) {
    var result = text;
    for (final secret in secrets.where((s) => s.isNotEmpty)) {
      final encoded = jsonEncode(secret);
      result = result
          .replaceAll(secret, '***')
          .replaceAll(encoded.substring(1, encoded.length - 1), '***');
    }
    return result;
  }

  Future<bool> _acquire(
    String id, {
    AgentCancellationToken? cancellation,
    bool allowMaintenance = false,
  }) async {
    if (_disposed ||
        (!allowMaintenance && _maintenance.contains(id)) ||
        cancellation?.isCancellationRequested == true) {
      return false;
    }
    if ((_running[id] ?? 0) < 4) {
      _running[id] = (_running[id] ?? 0) + 1;
      return true;
    }
    final waiter = Completer<bool>();
    final queue = (_queues[id] ??= []);
    queue.add(waiter);
    final unlink = cancellation?.onCancel(() {
      // remove 成功说明还未接手槽位；交接后的取消由 execute 释放其租约。
      if (queue.remove(waiter)) {
        waiter.complete(false);
      }
    });
    try {
      return await waiter.future;
    } finally {
      unlink?.call();
    }
  }

  void _releaseQueue(String id) {
    final queue = _queues[id];
    if (queue != null && queue.isNotEmpty) {
      queue.removeAt(0).complete(true);
    } else {
      _running[id] = (_running[id] ?? 1) - 1;
      if (_running[id] == 0) {
        _drainers[id]?.complete();
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final id in _packages.keys) {
      registry.remove(id);
      _registrations.remove(id);
    }
    for (final queue in _queues.values) {
      for (final waiter in queue) {
        waiter.complete(false);
      }
      queue.clear();
    }
    await _changes.close();
  }
}

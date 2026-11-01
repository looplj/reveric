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
import '../../models/plugin/view.dart';
import '../../models/plugin/setting_field.dart';
import 'config.dart';
import 'data.dart';
import 'http.dart';
import 'registry.dart';
import 'runtime.dart';
import 'sqlite.dart';
import 'database_install.dart';
import 'prompt.dart';
import 'tasks.dart';
import 'ai.dart';
import '../../models/plugin/task.dart';
import '../../models/plugin/request.dart';
import 'ui_session.dart';
import 'a2ui_session.dart';
import 'page_session.dart';
import '../../widgets/a2ui/session.dart';
import '../../models/plugin/ui_tree.dart';
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
    this.modelSelections = const {},
  });
  final String id, path, source;
  final PluginManifest? manifest;
  bool enabled;
  String state;
  String? error;

  /// 必填配置未填写；此时不能开启插件。
  bool needsConfig;

  /// 各 `model` 配置项已保存的模型；界面据此提示已被删除或停用的模型。
  Map<String, PluginModelSelection> modelSelections;
  PluginPromptDiagnostic? promptDiagnostic;
}

typedef PluginExecutorFactory =
    PluginExecutor Function(PluginHostCall call, void Function() stop);

class PluginHostService {
  PluginHostService({
    required this.dao,
    required this.registry,
    this.packages,
    this.data,
    this.ai,
    PluginExecutorFactory? executorFactory,
    String? platform,
    this.applicationSupport,
  }) : _executorFactoryOverride = executorFactory,
       platform = platform ?? Platform.operatingSystem {
    this.executorFactory =
        executorFactory ??
        ((call, stop) =>
            PluginRuntime(hostCall: call, onStop: stop, business: _business));
  }
  final _business = PluginBusinessRuntime();
  final Future<Directory> Function()? applicationSupport;
  Future<Directory> supportDirectory() =>
      applicationSupport?.call() ?? getApplicationSupportDirectory();
  Future<PluginSqliteService>? _databases;
  Future<PluginSqliteService> privateDatabases() => _databases ??=
      supportDirectory().then((root) => PluginSqliteService(root: root));
  Future<List<Map<String, Object?>>> databaseMigrations(
    PluginPackage package,
  ) async {
    final declaration = package.manifest.database;
    if (declaration == null) {
      throw PluginHostError(
        'database_not_declared',
        'Plugin has not declared a database',
      );
    }
    return [
      for (final migration in declaration.migrations)
        {
          'version': migration.version,
          'sql': await readPackageText(
            package,
            migration.source,
            maxBytes: 1024 * 1024,
          ),
        },
    ];
  }

  final PluginDataService? data;
  final PluginAiApi? ai;
  final PluginDao dao;
  final PluginRegistry registry;
  final Future<List<PluginPackage>> Function()? packages;
  late final PluginExecutorFactory executorFactory;
  final PluginExecutorFactory? _executorFactoryOverride;
  final String platform;
  final _changes = StreamController<List<PluginStatus>>.broadcast();
  final _pages =
      <
        String,
        ({
          String pluginId,
          PluginPageSession session,
          Future<bool> Function() confirmDiscard,
        })
      >{};
  final _openingPages = <String, int>{};

  Future<PluginUiSession> openTsxView(
    PluginView view, {
    required String? workId,
    required Future<bool> Function() confirmDiscard,
    Set<String> iconNames = const {},
    PluginHostCall? uiCall,
    void Function()? onClose,
  }) => mutate(
    view.pluginId,
    () => _openTsxView(
      view,
      workId: workId,
      confirmDiscard: confirmDiscard,
      iconNames: iconNames,
      uiCall: uiCall,
      onClose: onClose,
    ),
  );

  Future<PluginUiSession> _openTsxView(
    PluginView view, {
    required String? workId,
    required Future<bool> Function() confirmDiscard,
    required Set<String> iconNames,
    PluginHostCall? uiCall,
    void Function()? onClose,
  }) async {
    final id = view.pluginId;
    final package = _packages[id];
    if (_disposed ||
        package == null ||
        _statuses[id]?.state != 'available' ||
        !view.isTsx ||
        !(_views[id]?.contains(view) ?? false)) {
      throw PluginHostError('unavailable', 'View is not available');
    }
    final count =
        _pages.values.where((p) => p.pluginId == id).length +
        (_openingPages[id] ?? 0);
    if (count >= 2 ||
        _pages.length + _openingPages.values.fold(0, (a, b) => a + b) >= 4) {
      throw PluginHostError('plugin_ui_limit', 'Too many open plugin pages');
    }
    _openingPages[id] = (_openingPages[id] ?? 0) + 1;
    final instance = const Uuid().v4();
    final http = PluginHttpApi(requestLimit: null);
    final cancellation = AgentCancellationController();
    PluginUiSession? session;
    try {
      final source = await readPackageText(
        package,
        view.source,
        maxBytes: 2 * 1024 * 1024,
      );
      final secrets = await dao.secretValues(id);
      if (_disposed ||
          _packages[id] != package ||
          _statuses[id]?.state != 'available') {
        throw PluginHostError('unavailable', 'View changed while opening');
      }
      final api = _hostApi(
        id,
        package,
        http,
        secrets,
        workId: workId,
        cancellation: cancellation.token,
        aiLabel: 'page:${view.id}',
      );
      session = PluginUiSession(
        tree: PluginUiTree(
          surface: instance,
          generation: 1,
          iconNames: iconNames,
        ),
        hostCall: (method, args) async {
          if (_disposed ||
              _packages[id] != package ||
              _statuses[id]?.state != 'available' ||
              !_pages.containsKey(instance)) {
            throw PluginHostError(
              'unavailable',
              'Page is closed or plugin changed',
            );
          }
          if (method.startsWith('ui.') && uiCall != null) {
            return uiCall(method, args);
          }
          return api(method, args);
        },
        onClosing: () {
          http.cancel();
          cancellation.cancel();
          onClose?.call();
        },
        onClose: () {
          _pages.remove(instance);
        },
        readSourceMap: () => readPackageText(
          package,
          '${view.source}.map',
          maxBytes: 8 * 1024 * 1024,
        ),
      );
      _pages[instance] = (
        pluginId: id,
        session: session,
        confirmDiscard: confirmDiscard,
      );
      await session.start(
        source: source,
        scope: {
          'plugin': {'id': id, 'version': package.manifest.version},
          'page': {'viewId': view.id, 'instanceId': instance, 'workId': workId},
        },
        environment: {},
      );
      return session;
    } catch (_) {
      http.cancel();
      await session?.close();
      rethrow;
    } finally {
      _openingPages[id] = _openingPages[id]! - 1;
    }
  }

  Future<PluginA2uiSession> openA2uiView(
    PluginView view, {
    required String? workId,
    required Future<bool> Function() confirmDiscard,
    PluginHostCall? uiCall,
    void Function()? onClose,
  }) => mutate(view.pluginId, () async {
    final id = view.pluginId;
    final package = _packages[id];
    if (_disposed ||
        package == null ||
        _statuses[id]?.state != 'available' ||
        view.isTsx ||
        !(_views[id]?.contains(view) ?? false)) {
      throw PluginHostError('unavailable', 'View is not available');
    }
    if (_pages.values.where((p) => p.pluginId == id).length +
                (_openingPages[id] ?? 0) >=
            2 ||
        _pages.length + _openingPages.values.fold(0, (a, b) => a + b) >= 4) {
      throw PluginHostError('plugin_ui_limit', 'Too many open plugin pages');
    }
    _openingPages[id] = (_openingPages[id] ?? 0) + 1;
    final instance = const Uuid().v4();
    final cancellation = AgentCancellationController();
    PluginA2uiSession? page;
    try {
      final messages = jsonDecode(
        await readPackageText(package, view.source, maxBytes: 1024 * 1024),
      );
      if (_disposed ||
          _packages[id] != package ||
          _statuses[id]?.state != 'available') {
        throw PluginHostError('unavailable', 'View changed while opening');
      }
      final session = PluginA2uiSession(
        onClose: () {
          cancellation.cancel();
          onClose?.call();
          _pages.remove(instance);
        },
      );
      page = session;
      session.surface = A2uiSurfaceSession.load(
        surfaceId: instance,
        messages: messages,
        onMessages: (event) async {
          if (session.closed ||
              !view.actionNames.contains(event.name) ||
              _packages[id] != package ||
              _statuses[id]?.state != 'available') {
            throw PluginHostError('unavailable', 'View action unavailable');
          }
          if (!await _acquire(id, cancellation: cancellation.token)) {
            throw PluginHostError('cancelled', 'View action cancelled');
          }
          final http = PluginHttpApi();
          final sqlCancellation = AgentCancellationController();
          final unlinkSql = cancellation.token.onCancel(sqlCancellation.cancel);
          try {
            final secrets = await dao.secretValues(id);
            final api = _hostApi(
              id,
              package,
              http,
              secrets,
              workId: workId,
              cancellation: sqlCancellation.token,
              aiLabel: 'page:${view.id}',
            );
            final runtime = executorFactory(
              (method, args) async {
                if (session.closed ||
                    _packages[id] != package ||
                    _statuses[id]?.state != 'available') {
                  throw PluginHostError(
                    'unavailable',
                    'Page closed or plugin changed',
                  );
                }
                if (method == 'view.setDirty') {
                  if (args['value'] is! bool) {
                    throw PluginHostError(
                      'invalid_argument',
                      'Dirty value must be boolean',
                    );
                  }
                  session.dirty.value = args['value'] as bool;
                  return null;
                }
                if (method.startsWith('ui.') && uiCall != null) {
                  return uiCall(method, args);
                }
                return api(method, args);
              },
              () {
                http.cancel();
                sqlCancellation.cancel();
              },
            );
            return await runtime.runViewAction(
              package.manifest,
              package.code,
              _registrations[id]!,
              view.id,
              event.name,
              {
                'data': event.data,
                'event': {
                  'name': event.name,
                  'sourceComponentId': event.sourceComponentId,
                  'context': event.context,
                },
                'page': {
                  'viewId': view.id,
                  'instanceId': instance,
                  'workId': workId,
                },
              },
              const Uuid().v4(),
              cancellation.token,
            );
          } finally {
            unlinkSql();
            sqlCancellation.cancel();
            http.cancel();
            _releaseQueue(id);
          }
        },
        onActionError: (_, error) {
          if (!session.closed) {
            session.actionError.value = error;
          }
        },
      );
      if (session.surface.error.value != null) {
        throw session.surface.error.value!;
      }
      _pages[instance] = (
        pluginId: id,
        session: session,
        confirmDiscard: confirmDiscard,
      );
      final mount = view.definition['onMount'];
      if (mount is String) {
        session.surface.dispatchAction(
          A2uiActionEvent(
            name: mount,
            sourceComponentId: '',
            context: const {},
            data: session.surface.dataSnapshot(),
          ),
        );
      }
      return session;
    } catch (_) {
      page?.dispose();
      rethrow;
    } finally {
      _openingPages[id] = _openingPages[id]! - 1;
    }
  });

  /// Confirm every affected draft before closing any page or changing a package.
  Future<void> closePluginPages(String id) async {
    final pages = _pages.values.where((p) => p.pluginId == id).toList();
    for (final page in pages) {
      if (!page.session.closed &&
          page.session.dirty.value &&
          !await page.confirmDiscard()) {
        throw PluginHostError(
          'cancelled',
          'Plugin change cancelled to preserve drafts',
        );
      }
    }
    for (final page in pages) {
      await page.session.close();
    }
  }

  late final tasks = PluginTaskScheduler(
    dao: dao.attachedDatabase.pluginTaskDao,
    run: _runScheduledTask,
    canRun: (definition) =>
        !_disposed &&
        !_maintenance.contains(definition.pluginId) &&
        _statuses[definition.pluginId]?.state == 'available' &&
        _packages[definition.pluginId]?.manifest.version == definition.version,
    onChanged: _emit,
  );
  Future<void> setForeground(bool foreground) =>
      tasks.setForeground(foreground);
  Future<PluginTaskResult> _runScheduledTask(
    PluginTaskDefinition definition,
    PluginTaskRun run,
    AgentCancellationToken cancellation,
  ) async {
    final id = definition.pluginId, package = _packages[definition.pluginId];
    if (package == null ||
        package.manifest.version != definition.version ||
        _statuses[id]?.state != 'available') {
      throw PluginHostError(
        'unavailable',
        'Task plugin version is unavailable',
      );
    }
    final expected = _registrations[id]!;
    final http = PluginHttpApi(),
        sqlCancellation = AgentCancellationController();
    final unlink = cancellation.onCancel(sqlCancellation.cancel);
    // 同一 runId 的重试累计用量，展示整次运行的成本。
    Map<String, dynamic>? usage;
    try {
      final taskRow = await dao.attachedDatabase.pluginTaskDao.get(
        id,
        definition.id,
      );
      if (taskRow == null ||
          taskRow.runId != run.runId ||
          taskRow.leaseExpiresAt == null) {
        throw PluginHostError('cancelled', 'Task lease is no longer current');
      }
      final prior = taskRow.lastUsage;
      if (prior?['runId'] == run.runId && prior!['calls'] is int) {
        usage = Map<String, dynamic>.from(prior);
      }
      Future<void> addUsage(PluginAiResult result) async {
        final next = <String, dynamic>{
          ...?usage,
          'runId': run.runId,
          'calls': ((usage?['calls'] as int?) ?? 0) + 1,
        };
        for (final MapEntry(:key, :value) in result.usage.entries) {
          if (value is num) {
            next[key] = ((next[key] as num?) ?? 0) + value;
          }
        }
        usage = next;
        if (!await dao.attachedDatabase.pluginTaskDao.recordUsage(
          taskRow,
          next,
          DateTime.now(),
        )) {
          throw PluginHostError(
            'cancelled',
            'Task lease changed before usage could be recorded',
          );
        }
      }

      final secrets = await dao.secretValues(id);
      final api = _hostApi(
        id,
        package,
        http,
        secrets,
        cancellation: sqlCancellation.token,
        aiLabel: 'task:${definition.id}',
        aiRunId: run.runId,
        onAiResult: addUsage,
      );
      final runtime = executorFactory(
        (method, args) async {
          if (cancellation.isCancellationRequested ||
              sqlCancellation.token.isCancellationRequested ||
              _packages[id] != package ||
              _statuses[id]?.state != 'available' ||
              _maintenance.contains(id)) {
            throw PluginHostError(
              'cancelled',
              'Task is cancelled or its plugin changed',
            );
          }
          if (method.startsWith('ui.')) {
            throw PluginHostError(
              'permission_denied',
              'Background tasks cannot open UI',
            );
          }
          return api(method, args);
        },
        () {
          http.cancel();
          sqlCancellation.cancel();
        },
      );
      final summary = await runtime.runTask(
        package.manifest,
        package.code,
        expected,
        definition.id,
        run.toJson(),
        cancellation,
      );
      return (summary: summary, usage: usage);
    } catch (error) {
      throw PluginTaskExecutionError(
        error is PluginHostError
            ? error.code
            : error is PluginExecutionError
            ? error.code
            : 'task_failed',
        error.toString(),
        usage: usage,
      );
    } finally {
      unlink();
      sqlCancellation.cancel();
      http.cancel();
    }
  }

  late final _promptCollector = PluginPromptCollector(
    onDiagnostic: _promptDiagnostic,
  );
  void _promptDiagnostic(PluginPromptDiagnostic diagnostic) {
    _log.warning(
      'Prompt omitted plugin=${diagnostic.pluginId} provider=${diagnostic.providerId} request=${diagnostic.requestId} code=${diagnostic.code}: ${diagnostic.message}',
    );
    _statuses[diagnostic.pluginId]?.promptDiagnostic = diagnostic;
    _emit();
  }

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

  bool _promptAvailable(String id) =>
      _statuses[id]?.state == 'available' && !_maintenance.contains(id);

  PluginPromptSource _promptSource(
    String id,
    List<Map<String, dynamic>> definitions,
    String provider,
    PluginRequestContext request,
  ) {
    final package = _packages[id]!;
    return PluginPromptSource(
      pluginId: id,
      providerId: provider,
      current: () async =>
          !_disposed &&
          _packages[id] == package &&
          _promptAvailable(id) &&
          await _requestCurrent(request),
      run: (budget, cancellation) async {
        final http = PluginHttpApi();
        final sqlCancellation = AgentCancellationController();
        final unlink = cancellation.onCancel(sqlCancellation.cancel);
        try {
          final secrets = await dao.secretValues(id);
          return await executorFactory(
            _hostApi(
              id,
              package,
              http,
              secrets,
              promptReadOnly: true,
              cancellation: sqlCancellation.token,
              sqlWaitBudget: budget,
            ),
            () {
              http.cancel();
              sqlCancellation.cancel();
            },
          ).runPrompt(
            package.manifest,
            package.code,
            definitions,
            provider,
            request.toJson(),
            budget,
            cancellation,
          );
        } finally {
          unlink();
          sqlCancellation.cancel();
          http.cancel();
        }
      },
    );
  }

  /// 本轮模型请求的插件参考数据；由调用方与历史快照比较后决定是否追加消息。
  Future<List<PluginPromptResult>> requestPromptContext(
    PluginRequestContext request,
  ) async {
    if (_disposed) {
      return const [];
    }
    final sources = <PluginPromptSource>[];
    for (final entry in _registrations.entries) {
      if (!_promptAvailable(entry.key)) {
        continue;
      }
      final providers = [
        for (final definition in entry.value)
          if (definition['kind'] == 'prompt')
            definition['prompt']['id'] as String,
      ];
      if (providers.isEmpty) {
        continue;
      }
      _statuses[entry.key]?.promptDiagnostic = null;
      for (final provider in providers) {
        sources.add(_promptSource(entry.key, entry.value, provider, request));
      }
    }
    if (sources.isEmpty) {
      return const [];
    }
    _emit();
    return _promptCollector.collect(request, sources);
  }

  /// 替换请求所属会话模式的 system prompt；无匹配、多个插件冲突、失败或返回空时为 null。
  Future<String?> requestSystemPrompt(PluginRequestContext request) async {
    if (_disposed) {
      return null;
    }
    final matches = <({String id, String provider})>[];
    for (final entry in _registrations.entries) {
      if (!_promptAvailable(entry.key)) {
        continue;
      }
      for (final definition in entry.value) {
        if (definition['kind'] == 'systemPrompt' &&
            (definition['systemPrompt']['modes'] as List).contains(
              request.mode,
            )) {
          matches.add((
            id: entry.key,
            provider: definition['systemPrompt']['id'] as String,
          ));
        }
      }
    }
    if (matches.isEmpty) {
      return null;
    }
    for (final match in matches) {
      _statuses[match.id]?.promptDiagnostic = null;
    }
    if (matches.length > 1) {
      final owners = matches.map((m) => '${m.id}/${m.provider}').join(', ');
      for (final match in matches) {
        _promptDiagnostic(
          PluginPromptDiagnostic(
            pluginId: match.id,
            providerId: match.provider,
            requestId: request.requestId,
            code: 'prompt_conflict',
            message:
                'Multiple providers replace the ${request.mode} system prompt: $owners',
          ),
        );
      }
      return null;
    }
    _emit();
    final match = matches.single;
    final results = await _promptCollector.collect(
      request,
      [
        _promptSource(
          match.id,
          _registrations[match.id]!,
          match.provider,
          request,
        ),
      ],
      pluginTokens: 8000,
      totalTokens: 8000,
    );
    return results.isEmpty ? null : results.single.text;
  }

  final _registrations = <String, List<Map<String, dynamic>>>{};
  final _views = <String, List<PluginView>>{};
  List<PluginView> get views =>
      List.unmodifiable(_views.values.expand((v) => v));
  final _packages = <String, PluginPackage>{};
  final _statuses = <String, PluginStatus>{};
  final _serial = <String, Future<void>>{};
  Future<void> _snapshotBarrier = Future<void>.value();
  final _running = <String, int>{};
  final _maintenance = <String>{};
  final _drainers = <String, Completer<void>>{};
  final _recoveryErrors = <String, Object>{};

  Future<void> validatePackage(PluginPackage package) async {
    final tools = await _candidateTools(
      package.manifest,
      package.code,
      package.source,
    );
    for (final view in package.manifest.pages) {
      await readPackageText(
        package,
        view.source,
        maxBytes: view.isTsx ? 2 * 1024 * 1024 : 1024 * 1024,
      );
    }
    registry.validate(package.manifest.id, tools);
  }

  /// 安装预览：只执行候选包的 apply 读取工具声明，不登记、不保留任何状态。
  Future<List<PluginTool>> previewTools(PluginManifest manifest, String code) =>
      _candidateTools(manifest, code, 'local');

  Future<List<PluginTool>> _candidateTools(
    PluginManifest manifest,
    String code,
    String source,
  ) async {
    // Candidate code must not replace resident registrations or consume their
    // shared execution/memory budget, even if apply fails or never returns.
    final validationRuntime = PluginBusinessRuntime();
    try {
      const call = _applyApi;
      final executor =
          _executorFactoryOverride?.call(call, () {}) ??
          PluginRuntime(hostCall: call, business: validationRuntime);
      final definitions = await executor.activate(manifest, code);
      return [
        for (final definition in definitions)
          if (definition['kind'] == null)
            PluginTool(manifest.id, manifest.name, source, definition),
      ];
    } finally {
      await validationRuntime.dispose();
    }
  }

  Future<void Function()> beginMaintenance(String id) async {
    if (_maintenance.contains(id)) {
      throw PluginHostError(
        'database_busy',
        'Plugin is already in maintenance',
      );
    }
    await closePluginPages(id);
    final databases = await privateDatabases();
    _maintenance.add(id);
    await _promptCollector.cancelPlugin(id);
    await tasks.suspendPlugin(id);
    databases.pause(id);
    void release() {
      if (!_recoveryErrors.containsKey(id)) {
        _maintenance.remove(id);
        databases.resume(id);
        tasks.kick();
      }
    }

    try {
      final queue = _queues[id];
      if (queue != null) {
        for (final waiter in queue) {
          waiter.complete(false);
        }
        queue.clear();
      }
      if ((_running[id] ?? 0) > 0) {
        await (_drainers[id] = Completer<void>()).future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw PluginHostError(
            'plugin_busy',
            'Plugin executions are still running; update was not applied',
          ),
        );
      }
      await databases.drain(id);
      return release;
    } catch (_) {
      release();
      rethrow;
    } finally {
      _drainers.remove(id);
    }
  }

  void markRecoveryRequired(String id, Object error) {
    _recoveryErrors[id] = error;
    registry.remove(id);
    _views.remove(id);
    _registrations.remove(id);
    final status = _statuses[id];
    if (status != null) {
      status.state = 'failed';
      status.error = error.toString();
    }
    _emit();
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

  Future<Object?> readToolCard(String pluginId, String toolName) async {
    final package = _packages[pluginId];
    if (package == null || _statuses[pluginId]?.state != 'available') {
      return null;
    }
    final tools = registry
        .toolsFor(pluginId)
        .where((tool) => tool.name == toolName);
    if (tools.isEmpty) {
      return null;
    }
    final view = tools.single.display?['view'];
    if (view is! Map || view['protocol'] != 'reveric-ui-v1') {
      return null;
    }
    final messages = jsonDecode(
      await readPackageText(
        package,
        view['source'] as String,
        maxBytes: 1024 * 1024,
      ),
    );
    if (_packages[pluginId] != package ||
        _statuses[pluginId]?.state != 'available') {
      return null;
    }
    return messages;
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
    if ((await dao.attachedDatabase.appStateDao.getAllByPrefix(
      'plugin_install.',
    )).isNotEmpty) {
      _recoveryErrors.addAll(
        await PluginDatabaseInstallOrchestrator().recover(
          database: dao.attachedDatabase,
          root: await supportDirectory(),
        ),
      );
    }
    await tasks.initialize();
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
        modelSelections: await _modelSelections(manifest),
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
    await tasks.start();
  }

  Future<void> _activate(String pluginId) async {
    final status = _statuses[pluginId]!;
    registry.remove(pluginId);
    _registrations.remove(pluginId);
    _views.remove(pluginId);
    status.error = null;
    status.state = 'activating';
    await _promptCollector.cancelPlugin(pluginId);
    await tasks.stopPlugin(pluginId);
    await _business.unload(pluginId);
    if (_recoveryErrors.containsKey(pluginId)) {
      status.state = 'failed';
      status.error = _recoveryErrors[pluginId].toString();
      _emit();
      return;
    }
    if (!status.enabled) {
      status.state = 'disabled';
      await _closeIdleDatabase(pluginId);
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
      if (package.manifest.database != null) {
        final databases = await privateDatabases();
        await databases.close(pluginId);
        databases.resume(pluginId);
        await databases.migrate(pluginId, await databaseMigrations(package));
      }
      final runtime = executorFactory(_applyApi, () {});
      final definitions = await runtime.activate(
        package.manifest,
        package.code,
      );
      if (_disposed) {
        return;
      }
      final views = package.manifest.pages;
      for (final view in views) {
        await readPackageText(
          package,
          view.source,
          maxBytes: view.isTsx ? 2 * 1024 * 1024 : 1024 * 1024,
        );
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
      _views[pluginId] = List.unmodifiable(views);
      await tasks.register(pluginId, package.manifest.tasks);
      status.state = 'available';
      tasks.kick();
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

  Future<T> withPackageSnapshot<T>(Future<T> Function() action) async {
    await start();
    final previous = _snapshotBarrier;
    final mutations = _serial.values.toList();
    final gate = Completer<void>();
    _snapshotBarrier = gate.future;
    try {
      await previous;
      await Future.wait(mutations);
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<void> shutdownForRestore() => withPackageSnapshot(() async {
    final releases = <void Function()>[];
    try {
      for (final id in _packages.keys.toList()) {
        releases.add(await beginMaintenance(id));
      }
      await dispose();
    } finally {
      for (final release in releases) {
        release();
      }
    }
  });

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
      modelSelections: await _modelSelections(package.manifest),
    );
    await _activate(id);
  }

  Future<void> confirmPermissions(String id) => mutate(id, () async {
    await dao.grantPermissions(id, _manifest(id).permissions);
    await _activate(id);
  });

  Future<void> revokePermissions(String id) => mutate(id, () async {
    await closePluginPages(id);
    for (final permission in _manifest(id).permissions) {
      await dao.revokePermission(id, permission);
    }
    await _activate(id);
  });

  Future<void> _closeIdleDatabase(String id) async {
    final pending = _databases;
    if (pending == null) {
      return;
    }
    final databases = await pending;
    databases.pause(id);
    unawaited(
      databases.close(id).catchError((Object error, StackTrace stack) {
        _log.warning('Database close deferred plugin=$id: $error');
      }),
    );
  }

  Future<void> uninstall(String id) => mutate(id, () async {
    await closePluginPages(id);
    await _promptCollector.cancelPlugin(id);
    await tasks.stopPlugin(id);
    await _business.unload(id);
    await _closeIdleDatabase(id);
    await dao.uninstall(id);
    registry.remove(id);
    _registrations.remove(id);
    _views.remove(id);
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
      await closePluginPages(pluginId);
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

  Future<Map<String, PluginModelSelection>> _modelSelections(
    PluginManifest manifest,
  ) async => {
    for (final field in manifest.settings)
      if (field.type == PluginSettingType.model)
        field.key: ?pluginModelSelection(
          await readPluginSetting(dao, manifest.id, field),
        ),
  };

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
      status.modelSelections = await _modelSelections(manifest);
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
          aiLabel: 'tool:$name',
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
          aiLabel: 'action:$name',
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
    String? aiLabel,
    String? aiRunId,
    Future<void> Function(PluginAiResult result)? onAiResult,
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
    if (method == 'ai.listModels' || method == 'ai.generateText') {
      if (aiLabel == null) {
        throw PluginHostError(
          'permission_denied',
          'AI is unavailable in this context',
        );
      }
      if (!package.manifest.permissions.contains('ai.generateText') ||
          !(await dao.grantedPermissions(id)).contains('ai.generateText')) {
        throw PluginHostError(
          'permission_denied',
          'Missing permission: ai.generateText',
        );
      }
      final service = ai;
      if (service == null) {
        throw PluginHostError(
          'model_not_configured',
          'Plugin AI service is not configured',
        );
      }
      if (method == 'ai.listModels') {
        return service.listModels();
      }
      final result = await service.generate(
        PluginAiRequest.fromArgs(
          args,
          pluginId: id,
          label: aiLabel,
          runId: aiRunId,
        ),
        cancellation ?? AgentCancellationController().token,
      );
      await onAiResult?.call(result);
      return {
        'text': result.text,
        'finishReason': result.finishReason,
        'providerId': result.providerId,
        'model': result.model,
      };
    }
    if (method.startsWith('sqlite.')) {
      if (package.manifest.database == null) {
        throw PluginHostError(
          'database_not_declared',
          'Plugin has not declared a database',
        );
      }
      if (_disposed ||
          _packages[id] != package ||
          _statuses[id]?.state != 'available') {
        throw PluginHostError('unavailable', 'Plugin database is unavailable');
      }
      return (await privateDatabases()).call(
        id,
        method.substring('sqlite.'.length),
        args,
        cancellation: cancellation,
        waitBudget: sqlWaitBudget,
        readOnly: promptReadOnly,
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

  /// apply 阶段只做注册，不开放任何宿主 API。
  static Future<Object?> _applyApi(
    String method,
    Map<String, dynamic> args,
  ) async => throw PluginHostError(
    'unavailable',
    'Host APIs unavailable during apply',
  );

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
    await _promptCollector.dispose();
    await tasks.dispose();
    await _business.dispose();
    for (final page in _pages.values.toList()) {
      await page.session.close();
    }
    for (final id in _packages.keys) {
      registry.remove(id);
      _registrations.remove(id);
      _views.remove(id);
    }
    for (final queue in _queues.values) {
      for (final waiter in queue) {
        waiter.complete(false);
      }
      queue.clear();
    }
    if (_databases != null) {
      await (await _databases!).dispose();
    }
    await _changes.close();
  }
}

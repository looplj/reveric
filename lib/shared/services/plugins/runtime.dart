// 职责: 在常驻业务引擎中加载插件并隔离各次调用的桥接、结果、预算与取消。
// 关联文件:
//   lib/shared/services/plugins/host.dart
import 'dart:async';
import '../javascript.dart';
import 'dart:convert';
import 'dart:math';
import 'package:fjs/fjs.dart';
import '../../agent/agent_tool_dispatcher.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_session_mode.dart';
import '../../models/plugin/manifest.dart';
import 'prelude.dart';
import 'registry.dart';

/// 运行失败。[code] 为插件抛出的业务错误码，或运行时自身的 plugin_* 错误码。
class PluginExecutionError implements Exception {
  PluginExecutionError(this.code, this.message);
  final String code, message;
  @override
  String toString() => '$code: $message';
}

abstract interface class PluginExecutor {
  Future<List<Map<String, dynamic>>> activate(
    PluginManifest manifest,
    String code,
  );
  Future<Map<String, dynamic>> invoke(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String tool,
    Map<String, dynamic> input,
    String callId,
    AgentCancellationToken? cancellation, {
    Map<String, dynamic> request = const {},
  });

  Future<String?> runTask(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String taskId,
    Map<String, dynamic> run,
    AgentCancellationToken cancellation,
  );

  Future<String?> runPrompt(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String providerId,
    Map<String, dynamic> request,
    Duration budget,
    AgentCancellationToken cancellation,
  );

  Future<List<dynamic>> runViewAction(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String viewId,
    String action,
    Map<String, dynamic> input,
    String callId,
    AgentCancellationToken? cancellation,
  );

  /// 执行清单声明的设置页操作；插件未开启时也可执行。
  Future<Map<String, dynamic>> runAction(
    PluginManifest manifest,
    String code,
    String action,
    String callId,
    AgentCancellationToken? cancellation,
  );
}

/// 插件可替换 system prompt 的会话模式。
final pluginPromptModes = {for (final mode in AiSessionMode.values) mode.value};

final _errorCode = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

final _log = AppLogger.forModule('PluginRuntime');

// Host cancellation gets a bounded chance to unwind JS before retiring the runtime.
const _cancellationGrace = Duration(milliseconds: 500);

/// FJS reports queued background failures from close only after teardown has
/// finished. No invocation remains to fail, so they are diagnostics: throwing
/// would leave unload, update and reset stuck on an already released context.
void _logCloseReport(String owner, PluginExecutionError cause, Object report) {
  // The interrupt has already been delivered to every affected invocation.
  if (const {'plugin_timeout', 'plugin_runtime_reset'}.contains(cause.code) &&
      report.toString().contains('InternalError: interrupted')) {
    return;
  }
  _log.warning('Background errors reported on close: $owner $report');
}

typedef PluginHostCall =
    Future<Object?> Function(String method, Map<String, dynamic> args);

/// Owns one runtime with a native context and a bridge table for each plugin.
///
/// 架构取舍：插件共用 QuickJS Runtime，仅按插件隔离 context，
/// 不改为每插件独立 Runtime。内存和连续执行预算由所有插件共享；
/// 接受同步密集计算阻塞其他插件，以及原生超时、内存耗尽触发全局
/// reset 时中断其他调用的影响，暂不为这些极端场景增加隔离或恢复机制。
/// 普通 SQLite 等宿主异步请求的等待超时本身不触发全局 reset。
class PluginBusinessRuntime {
  final _realms = <String, _PluginRealm>{};
  final _retiring = <String, Future<void>>{};
  bool _disposed = false;
  Future<JsEngineGroup>? _group;
  Future<void>? _closing;

  Future<JsEngineGroup> _runtime() {
    if (_disposed) {
      throw PluginExecutionError('plugin_error', 'Business runtime disposed');
    }
    final closing = _closing;
    return _group ??= (() async {
      await closing;
      await initializeJavascript();
      final group = await JsEngineGroup.create(
        runtimeOptions: JsEngineRuntimeOptions(
          memoryLimit: BigInt.from(128 * 1024 * 1024),
          maxStackSize: BigInt.from(1024 * 1024),
        ),
      );
      try {
        await group.setExecutionTimeLimit(limitMillis: 2000);
        return group;
      } catch (_) {
        await group.close();
        rethrow;
      }
    })();
  }

  Future<void> reset(PluginExecutionError error) async {
    final group = _group;
    _group = null;
    final realms = _realms.values.toList();
    _realms.clear();
    final retiring = _retiring.values.toList();
    _retiring.clear();
    final previous = _closing;
    final closing = (() async {
      final contexts = Future.wait([
        ...retiring,
        for (final realm in realms) realm.dispose(error),
      ]);
      // Observe both cleanup paths even if one reports a diagnostic.
      await Future.wait([
        contexts,
        (() async {
          await previous;
          if (group == null) {
            return;
          }
          final JsEngineGroup created;
          try {
            created = await group;
          } catch (_) {
            // A failed creation was already reported to the call that awaited it.
            return;
          }
          try {
            await created.close();
          } catch (report) {
            _logCloseReport('runtime', error, report);
          }
        })(),
      ]);
    })();
    _closing = closing;
    await closing;
  }

  _PluginRealm _forPlugin(String id) {
    if (_disposed) {
      throw PluginExecutionError('plugin_error', 'Business runtime disposed');
    }
    return _realms.putIfAbsent(
      id,
      () => _PluginRealm(this, id, _retiring.remove(id)),
    );
  }

  Future<void> unload(String id) async {
    final realm = _realms.remove(id);
    if (realm != null) {
      final closing = realm.dispose();
      _retiring[id] = closing;
      await closing;
    } else {
      await _retiring[id];
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await reset(
      PluginExecutionError('user_cancelled', 'Business runtime disposed'),
    );
  }
}

/// Tokens route calls within one plugin; the native context binds bridge identity.
class _PluginRealm {
  _PluginRealm(this.owner, this.pluginId, this._closing);
  final PluginBusinessRuntime owner;
  final String pluginId;
  PluginExecutionError? _invalidated;
  // Remember issued calls without retaining an unbounded set of expired tokens.
  // The native context, rather than an invocation token, is the security boundary.
  final _invocationPrefix = token();
  var _issuedInvocations = 0;
  String invocationToken() => '$_invocationPrefix:${++_issuedInvocations}';
  bool _wasIssued(Object? value) {
    if (value is! String || !value.startsWith('$_invocationPrefix:')) {
      return false;
    }
    final suffix = value.substring(_invocationPrefix.length + 1);
    final sequence = int.tryParse(suffix);
    return sequence != null &&
        sequence > 0 &&
        sequence <= _issuedInvocations &&
        sequence.toString() == suffix;
  }

  Future<JsEngine>? _engine;
  Future<void>? _closing;
  int _generation = 0;
  final _loads =
      <
        String,
        ({
          String signature,
          String slot,
          int generation,
          Future<_LoadedPlugin> ready,
        })
      >{};
  final _bridges = <String, Future<JsResult> Function(JsValue)>{};
  final _stops = <String, void Function(PluginExecutionError)>{};
  bool _disposed = false;
  static final _random = Random.secure();
  static String token() =>
      base64UrlEncode(List.generate(24, (_) => _random.nextInt(256)));

  void checkCurrent(int generation) {
    if (_invalidated != null) {
      throw _invalidated!;
    }
    if (_disposed ||
        generation != _generation ||
        !identical(owner._realms[pluginId], this)) {
      throw PluginExecutionError(
        'plugin_runtime_reset',
        'Plugin loading environment was replaced',
      );
    }
  }

  Future<JsEngine> engine() {
    final generation = _generation;
    checkCurrent(generation);
    final existing = _engine;
    if (existing != null) {
      return existing;
    }
    final closing = _closing;
    // Acquire the group future before yielding. A retiring context must not
    // wait on a later group whose cleanup is itself waiting for this context.
    final group = owner._runtime();
    return _engine = (() async {
      try {
        await closing;
        checkCurrent(generation);
        final currentGroup = await group;
        checkCurrent(generation);
        return await _create(currentGroup, generation);
      } catch (_) {
        checkCurrent(generation);
        rethrow;
      }
    })();
  }

  Future<JsEngine> _create(JsEngineGroup group, int generation) async {
    final engine = await group.createEngine();
    try {
      checkCurrent(generation);
      await engine.init(
        bridge: (value) async {
          if (value is JsValue_String &&
              utf8.encode(value.field0).length <= 2 * 1024 * 1024) {
            Object? message;
            try {
              message = jsonDecode(value.field0);
            } on FormatException catch (error) {
              return JsResult.ok(
                JsValue.string(
                  jsonEncode({
                    'ok': false,
                    'code': 'plugin_error',
                    'error': error.toString(),
                  }),
                ),
              );
            }
            final bridge = message is Map ? _bridges[message['token']] : null;
            if (bridge != null) {
              return bridge(value);
            }
            if (!_disposed &&
                message is Map &&
                message['kind'] == 'call' &&
                _wasIssued(message['token'])) {
              await reset(
                PluginExecutionError(
                  'plugin_runtime_reset',
                  'A completed plugin invocation attempted another Host call; shared runtime restarted',
                ),
              );
            }
          }
          return JsResult.ok(
            JsValue.string(
              jsonEncode({
                'ok': false,
                'code': 'permission_denied',
                'error': 'A live invocation capability is required',
              }),
            ),
          );
        },
      );
      checkCurrent(generation);
      return engine;
    } catch (_) {
      await engine.close();
      rethrow;
    }
  }

  Future<void> reset(PluginExecutionError error) => owner.reset(error);

  Future<void> _close(PluginExecutionError error) async {
    _invalidated ??= error;
    final engine = _engine;
    _engine = null;
    _generation++;
    _loads.clear();
    final closing = engine == null
        ? _closing
        : (() async {
            final JsEngine created;
            try {
              created = await engine;
            } catch (_) {
              // A failed creation was already reported to the call that awaited it.
              return;
            }
            try {
              await created.close();
            } catch (report) {
              _logCloseReport('plugin=$pluginId', error, report);
            }
          })();
    _closing = closing;
    for (final stop in _stops.values.toList()) {
      stop(error);
    }
    await closing;
  }

  Future<void> dispose([PluginExecutionError? error]) async {
    _disposed = true;
    await _close(
      error ??
          PluginExecutionError('user_cancelled', 'Plugin context unloaded'),
    );
  }
}

/// A successful load and the exact native context that owns its registrations.
class _LoadedPlugin {
  _LoadedPlugin({
    required List<Map<String, dynamic>> definitions,
    required this.slot,
    required this.realm,
    required this.engine,
    required this.generation,
  }) : definitions = List.unmodifiable(definitions);
  final List<Map<String, dynamic>> definitions;
  final String slot;
  final _PluginRealm realm;
  final JsEngine engine;
  final int generation;

  void checkCurrent() => realm.checkCurrent(generation);
}

class PluginRuntime implements PluginExecutor {
  PluginRuntime({
    required this.hostCall,
    PluginBusinessRuntime? business,
    this.onStop,
    this.activationTimeout = const Duration(seconds: 5),
    this.callTimeout = const Duration(seconds: 60),
    this.actionTimeout = const Duration(seconds: 20),
    this.taskTimeout = const Duration(minutes: 5),
  }) : business = business ?? PluginBusinessRuntime();
  final PluginBusinessRuntime business;
  final PluginHostCall hostCall;
  final void Function()? onStop;
  final Duration activationTimeout, callTimeout, actionTimeout, taskTimeout;
  @override
  Future<List<Map<String, dynamic>>> activate(
    PluginManifest manifest,
    String code,
  ) async {
    final loaded = await _load(manifest, code);
    loaded.checkCurrent();
    return List.of(loaded.definitions);
  }

  Future<_LoadedPlugin> _load(PluginManifest manifest, String code) async {
    final signature = '$code\n${canonicalPluginJson(manifest.json)}';
    var realm = business._forPlugin(manifest.id);
    var load = realm._loads[manifest.id];
    if (load != null && load.signature != signature) {
      await business.unload(manifest.id);
      realm = business._forPlugin(manifest.id);
      load = null;
    }
    if (load == null) {
      final slot = _PluginRealm.token();
      final generation = realm._generation;
      final ready = _run(
        manifest,
        code,
        slot: slot,
        loadingRealm: realm,
        loadingGeneration: generation,
      ).then((value) => value.loaded!);
      load = (
        signature: signature,
        slot: slot,
        generation: generation,
        ready: ready,
      );
      realm._loads[manifest.id] = load;
    }
    try {
      final loaded = await load.ready;
      loaded.checkCurrent();
      return loaded;
    } catch (_) {
      if (identical(realm._loads[manifest.id]?.ready, load.ready) &&
          identical(business._realms[manifest.id], realm)) {
        await business.unload(manifest.id);
      }
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> invoke(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String tool,
    Map<String, dynamic> input,
    String callId,
    AgentCancellationToken? cancellation, {
    Map<String, dynamic> request = const {},
  }) async => (await _run(
    manifest,
    code,
    expected: expected,
    tool: tool,
    input: input,
    callId: callId,
    cancellation: cancellation,
    request: request,
  )).result!;
  @override
  Future<String?> runTask(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String taskId,
    Map<String, dynamic> run,
    AgentCancellationToken cancellation,
  ) async {
    final result = (await _run(
      manifest,
      code,
      expected: expected,
      taskId: taskId,
      input: run,
      cancellation: cancellation,
    )).result!;
    final summary = result['summary'];
    if (summary != null && (summary is! String || summary.length > 2000)) {
      throw PluginExecutionError(
        'plugin_invalid_result',
        'Task summary must be text up to 2000 characters',
      );
    }
    return summary as String?;
  }

  @override
  Future<String?> runPrompt(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String providerId,
    Map<String, dynamic> request,
    Duration budget,
    AgentCancellationToken cancellation,
  ) async {
    final run = await _run(
      manifest,
      code,
      expected: expected,
      promptId: providerId,
      input: request,
      timeout: budget,
      cancellation: cancellation,
    );
    final result = run.result!;
    if (!result.containsKey('text') ||
        (result['text'] != null && result['text'] is! String)) {
      throw PluginExecutionError(
        'plugin_invalid_result',
        'Prompt must return text or null',
      );
    }
    return result['text'] as String?;
  }

  @override
  Future<List<dynamic>> runViewAction(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String viewId,
    String action,
    Map<String, dynamic> input,
    String callId,
    AgentCancellationToken? cancellation,
  ) async {
    final run = await _run(
      manifest,
      code,
      expected: expected,
      viewId: viewId,
      action: action,
      input: input,
      callId: callId,
      cancellation: cancellation,
    );
    final messages = run.result!['messages'];
    if (messages is! List ||
        messages.any(
          (m) =>
              m is! Map ||
              m.keys.where((k) => k != 'version').length != 1 ||
              (!m.containsKey('updateComponents') &&
                  !m.containsKey('updateDataModel')),
        )) {
      throw PluginExecutionError(
        'plugin_invalid_result',
        'View action must return updateComponents/updateDataModel messages',
      );
    }
    return messages;
  }

  @override
  Future<Map<String, dynamic>> runAction(
    PluginManifest manifest,
    String code,
    String action,
    String callId,
    AgentCancellationToken? cancellation,
  ) async => (await _run(
    manifest,
    code,
    action: action,
    callId: callId,
    cancellation: cancellation,
  )).result!;
  Future<
    ({
      List<Map<String, dynamic>> definitions,
      Map<String, dynamic>? result,
      _LoadedPlugin? loaded,
    })
  >
  _run(
    PluginManifest manifest,
    String code, {
    String? slot,
    _PluginRealm? loadingRealm,
    int? loadingGeneration,
    List<Map<String, dynamic>>? expected,
    String? tool,
    String? action,
    String? viewId,
    String? promptId,
    String? taskId,
    Duration? timeout,
    Map<String, dynamic> request = const {},
    Map<String, dynamic> input = const {},
    String callId = '',
    AgentCancellationToken? cancellation,
  }) async {
    if (utf8.encode(code).length > 2 * 1024 * 1024) {
      throw PluginExecutionError('plugin_error', 'Entry exceeds 2 MB');
    }
    if (utf8.encode(jsonEncode(input)).length >
        (viewId == null ? 256 * 1024 : 1024 * 1024)) {
      throw PluginExecutionError(
        'invalid_argument',
        'Input exceeds execution payload limit',
      );
    }
    JsEngine? engine;
    _PluginRealm? realm = loadingRealm;
    int? generation = loadingGeneration;
    final completed = Completer<void>();
    final pendingHostCalls = <Completer<Object?>>{};
    String? token;
    final executionSettled = Completer<void>();
    var executionStarted = false;
    PluginExecutionError? failure;
    PluginExecutionError? outcomeError;
    var nativeInterrupted = false;
    var accepting = true;
    final activating =
        tool == null &&
        action == null &&
        viewId == null &&
        promptId == null &&
        taskId == null;
    final definitions = <Map<String, dynamic>>[];
    Map<String, dynamic>? output;
    var receivedResult = false;
    // 插件与 prelude 共享 JS 环境，业务 API 必须由宿主在注册校验后放行。
    var registering = true;
    void rejectHostWaits(PluginExecutionError error) {
      for (final pending in pendingHostCalls.toList()) {
        if (!pending.isCompleted) {
          pending.completeError(error);
        }
      }
    }

    Future<Object?> callHost(String method, Map<String, dynamic> args) async {
      final pending = Completer<Object?>();
      pendingHostCalls.add(pending);
      // Observe the host's eventual outcome, but retain cancellation bookkeeping
      // only while this bridge is pending, not for every call in a long task.
      unawaited(
        Future<Object?>.sync(() => hostCall(method, args)).then<void>(
          (value) {
            if (!pending.isCompleted) {
              pending.complete(value);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!pending.isCompleted) {
              pending.completeError(error, stack);
            }
          },
        ),
      );
      try {
        return await pending.future;
      } finally {
        pendingHostCalls.remove(pending);
      }
    }

    void stop(PluginExecutionError error) {
      if (failure != null) {
        return;
      }
      failure = error;
      accepting = false;
      rejectHostWaits(error);
      if (!activating) {
        onStop?.call();
      }
      if (!completed.isCompleted) {
        completed.complete();
      }
    }

    void register(Map<String, dynamic> message) {
      if (!registering) {
        throw StateError('Registration closed');
      }
      final names = message['actions'];
      if (names is! List ||
          names.any((name) => name is! String) ||
          names.toSet().length != names.length ||
          names.length != manifest.actions.length ||
          !manifest.actions.every((a) => names.contains(a.name))) {
        throw PluginExecutionError(
          'plugin_registration_mismatch',
          'Registered actions differ from manifest',
        );
      }
      final values = message['definitions'];
      if (values is! List || values.any((v) => v is! Map<String, dynamic>)) {
        throw const FormatException('Invalid registration batch');
      }
      final pageActions = <String>{}, prompts = <String>{}, tasks = <String>{};
      for (final value in values.cast<Map<String, dynamic>>()) {
        switch (value['kind']) {
          case 'pageAction':
            final pageId = value['pageId'];
            final name = value['name'];
            if (value.length != 3 ||
                !manifest.pages.any(
                  (page) =>
                      page.id == pageId && page.actionNames.contains(name),
                ) ||
                !pageActions.add('$pageId/$name')) {
              throw PluginExecutionError(
                'plugin_registration_mismatch',
                'Invalid or duplicate page action',
              );
            }
          case 'task':
            final task = value['task'];
            final id = task is Map ? task['id'] : null;
            if (task is! Map ||
                task.length != 1 ||
                id is! String ||
                !manifest.tasks.any((task) => task.id == id) ||
                !tasks.add(id)) {
              throw PluginExecutionError(
                'plugin_registration_mismatch',
                'Invalid or duplicate scheduled task handler',
              );
            }
          case 'prompt':
            final prompt = value['prompt'];
            final id = prompt is Map ? prompt['id'] : null;
            if (prompt is! Map<String, dynamic> ||
                prompt.length != 1 ||
                id is! String ||
                !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(id) ||
                !prompts.add(id)) {
              throw const FormatException(
                'Invalid or duplicate prompt provider',
              );
            }
            definitions.add({'kind': 'prompt', 'prompt': prompt});
          case 'systemPrompt':
            final prompt = value['systemPrompt'];
            final id = prompt is Map ? prompt['id'] : null;
            final modes = prompt is Map ? prompt['modes'] : null;
            if (prompt is! Map<String, dynamic> ||
                prompt.length != 2 ||
                id is! String ||
                !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(id) ||
                modes is! List ||
                modes.isEmpty ||
                modes.toSet().length != modes.length ||
                modes.any((mode) => !pluginPromptModes.contains(mode)) ||
                !prompts.add(id)) {
              throw const FormatException(
                'Invalid or duplicate system prompt provider',
              );
            }
            definitions.add({'kind': 'systemPrompt', 'systemPrompt': prompt});
          case null:
            PluginTool(manifest.id, manifest.name, 'bundled', value);
            definitions.add(value);
          default:
            throw const FormatException('Reserved registration kind');
        }
      }
      if (tasks.length != manifest.tasks.length ||
          pageActions.length !=
              manifest.pages.fold<int>(
                0,
                (count, page) => count + page.actionNames.length,
              )) {
        throw PluginExecutionError(
          'plugin_registration_mismatch',
          'Missing declared task or page action handler',
        );
      }
      definitions.addAll([
        for (final page in manifest.pages)
          {'kind': 'view', 'view': page.definition},
        for (final task in manifest.tasks)
          {'kind': 'task', 'task': task.definition},
      ]);
      if (expected != null &&
          canonicalPluginJson(definitions) != canonicalPluginJson(expected)) {
        throw PluginExecutionError(
          'plugin_registration_mismatch',
          'Registration differs from activation',
        );
      }
      registering = false;
    }

    final remove = cancellation?.onCancel(
      () =>
          stop(PluginExecutionError('user_cancelled', 'Plugin call cancelled')),
    );
    final timer = Timer(
      timeout ??
          (taskId != null
              ? taskTimeout
              : action != null && viewId == null
              ? actionTimeout
              : (activating ? activationTimeout : callTimeout)),
      () => stop(
        PluginExecutionError('plugin_timeout', 'Plugin execution timed out'),
      ),
    );
    try {
      if (!activating) {
        final loaded = await Future.any([
          _load(manifest, code),
          completed.future.then<_LoadedPlugin>((_) => throw failure!),
        ]);
        // The handoff itself yields; validate the captured environment again.
        loaded.checkCurrent();
        realm = loaded.realm;
        generation = loaded.generation;
        engine = loaded.engine;
        slot = loaded.slot;
        definitions.addAll(loaded.definitions);
        if (expected != null &&
            canonicalPluginJson(definitions) != canonicalPluginJson(expected)) {
          throw PluginExecutionError(
            'plugin_registration_mismatch',
            'Registration differs from activation',
          );
        }
        registering = false;
      }
      if (failure != null) {
        throw failure!;
      }
      realm!.checkCurrent(generation!);
      token = activating ? _PluginRealm.token() : realm.invocationToken();
      realm._stops[token] = stop;
      if (activating) {
        engine = await realm.engine();
        realm.checkCurrent(generation);
      }
      if (failure != null) {
        throw failure!;
      }
      realm._bridges[token] = (value) async {
        Map<String, dynamic> reply;
        try {
          if (!accepting) {
            throw failure ?? StateError('Execution closed');
          }
          if (value is! JsValue_String ||
              utf8.encode(value.field0).length > 2 * 1024 * 1024) {
            throw const FormatException('Invalid bridge message');
          }
          final message = jsonDecode(value.field0) as Map<String, dynamic>;
          switch (message['kind']) {
            case 'register':
              register(message);
            case 'log':
              try {
                await hostCall('log.${message['level']}', {
                  'message': message['message'],
                  'data': message['data'],
                });
              } catch (_) {
                // 日志不影响插件执行结果。
              }
            case 'call':
              if (registering) {
                throw StateError('Host API unavailable during apply');
              }
              final method = message['method'] as String;
              final result = await callHost(
                method,
                message['args'] as Map<String, dynamic>,
              );
              if (!accepting) {
                throw failure ??
                    PluginExecutionError(
                      'user_cancelled',
                      'Invocation completed',
                    );
              }
              return JsResult.ok(
                JsValue.string(jsonEncode({'ok': true, 'result': result})),
              );
            case 'result':
              if (receivedResult) {
                throw StateError('Duplicate result');
              }
              receivedResult = true;
              if (message['invalid'] case final String invalid) {
                throw PluginExecutionError('plugin_invalid_result', invalid);
              }
              if (message['error'] != null) {
                if (message['error'].toString().contains(
                  'InternalError: interrupted',
                )) {
                  nativeInterrupted = true;
                  throw PluginExecutionError(
                    'plugin_timeout',
                    message['error'].toString(),
                  );
                }
                final code = message['code'];
                if (code is String && _errorCode.hasMatch(code)) {
                  throw PluginExecutionError(
                    code,
                    '${message['message'] ?? message['error']}',
                  );
                }
                throw PluginExecutionError(
                  RegExp(
                        'out of memory|stack overflow|memory limit',
                        caseSensitive: false,
                      ).hasMatch(message['error'].toString())
                      ? 'plugin_memory_limit'
                      : 'plugin_error',
                  message['error'].toString(),
                );
              }
              if (registering) {
                throw PluginExecutionError(
                  'plugin_registration_mismatch',
                  'Registration was not reported',
                );
              }
              if (!activating) {
                if (message['value'] is! Map<String, dynamic> ||
                    utf8.encode(jsonEncode(message['value'])).length >
                        (viewId == null ? 256 * 1024 : 1024 * 1024)) {
                  throw PluginExecutionError(
                    'plugin_invalid_result',
                    '${action != null ? 'Action' : 'Tool'} must return a JSON object up to 256 KB',
                  );
                }
                output = message['value'] as Map<String, dynamic>;
              }
            default:
              throw const FormatException('Unknown bridge kind');
          }
          reply = {'ok': true, 'result': null};
        } catch (error) {
          if (error is PluginExecutionError) {
            stop(error);
          } else if (error is! PluginHostError) {
            stop(PluginExecutionError('plugin_error', error.toString()));
          }
          reply = {
            'ok': false,
            'code': switch (error) {
              PluginHostError() => error.code,
              PluginExecutionError() => error.code,
              _ => 'plugin_error',
            },
            'error': error is PluginHostError
                ? error.message
                : error.toString(),
          };
        }
        return JsResult.ok(JsValue.string(jsonEncode(reply)));
      };
      final String source;
      if (activating) {
        source = pluginPrelude(
          manifest.id,
          manifest.version,
          slot!,
          token,
        ).replaceFirst('__PLUGIN_CODE__', code);
      } else {
        final invocation = taskId != null
            ? pluginInvokeTask(taskId, input)
            : promptId != null
            ? pluginInvokePrompt(promptId, input)
            : viewId != null
            ? pluginInvokeViewAction(viewId, action!, input)
            : action != null
            ? pluginInvokeAction(action, callId)
            : pluginInvoke(tool!, input, callId, request);
        source =
            'await globalThis[${jsonEncode(slot)}](${jsonEncode(token)}, ${jsonEncode('(async () => {$invocation})()')});';
      }
      executionStarted = true;
      realm.checkCurrent(generation);
      final evaluation = engine!.eval(source: JsCode.code(source));

      final observed = evaluation.catchError((
        Object error,
        StackTrace stack,
      ) async {
        if (realm != null &&
            generation == realm._generation &&
            (error is JsError_Timeout ||
                error.toString().contains('InternalError: interrupted'))) {
          await realm.reset(
            PluginExecutionError(
              'plugin_timeout',
              'Plugin exceeded the continuous JavaScript execution budget: $error',
            ),
          );
        }
        Error.throwWithStackTrace(error, stack);
      });
      final tracked = observed.whenComplete(() => executionSettled.complete());
      await Future.any<void>([tracked.then((_) {}), completed.future]);
      if (failure != null) {
        throw failure!;
      }
      if (!receivedResult) {
        throw PluginExecutionError('plugin_invalid_result', 'Missing result');
      }
      realm.checkCurrent(generation);
      return (
        definitions: definitions,
        result: output,
        loaded: activating
            ? _LoadedPlugin(
                definitions: definitions,
                slot: slot!,
                realm: realm,
                engine: engine,
                generation: generation,
              )
            : null,
      );
    } catch (error) {
      final text = error.toString();
      if (failure != null) {
        outcomeError = failure;
      } else if (error is PluginExecutionError) {
        outcomeError = error;
      } else if (error is JsError_Timeout) {
        outcomeError = PluginExecutionError(
          'plugin_timeout',
          'Plugin exceeded the continuous JavaScript execution budget: $text',
        );
      } else {
        outcomeError = PluginExecutionError(
          RegExp(
                'out of memory|stack overflow|memory limit',
                caseSensitive: false,
              ).hasMatch(text)
              ? 'plugin_memory_limit'
              : 'plugin_error',
          text,
        );
      }
      if (realm != null &&
          generation == realm._generation &&
          (nativeInterrupted ||
              error is JsError_Timeout ||
              outcomeError?.code == 'plugin_memory_limit')) {
        await realm.reset(outcomeError!);
      }
      throw outcomeError!;
    } finally {
      accepting = false;
      timer.cancel();
      remove?.call();
      if (!activating) {
        onStop?.call();
      }
      rejectHostWaits(
        failure ??
            PluginExecutionError('user_cancelled', 'Invocation completed'),
      );
      if (!completed.isCompleted) {
        completed.complete();
      }
      try {
        if (failure != null &&
            executionStarted &&
            realm != null &&
            generation == realm._generation) {
          await executionSettled.future.timeout(
            _cancellationGrace,
            onTimeout: () async {
              if (generation == realm!._generation &&
                  !executionSettled.isCompleted) {
                await realm.reset(
                  PluginExecutionError(
                    'plugin_runtime_reset',
                    'Plugin ${manifest.id} did not stop after cancellation; shared runtime restarted',
                  ),
                );
              }
            },
          );
        }
      } finally {
        realm?._bridges.remove(token);
        realm?._stops.remove(token);
        // The resident context does not fail later calls with detached errors;
        // report what has accumulated so far once this call is finished.
        final background = engine?.drainUnhandledJobErrors() ?? const [];
        if (background.isNotEmpty) {
          _log.warning(
            'Background errors: plugin=${manifest.id} ${background.join('\n')}',
          );
        }
      }
    }
  }
}

class PluginHostError implements Exception {
  PluginHostError(this.code, this.message);
  final String code, message;
  @override
  String toString() => '$code: $message';
}

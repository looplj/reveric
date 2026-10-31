// 职责: 执行单次 fjs 插件激活、工具调用或设置页操作，约束桥接、资源与取消。
// 关联文件:
//   lib/shared/services/plugins/host.dart
import 'dart:async';
import '../javascript.dart';
import 'dart:convert';
import 'package:fjs/fjs.dart';
import '../../agent/agent_tool_dispatcher.dart';
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

typedef PluginHostCall =
    Future<Object?> Function(String method, Map<String, dynamic> args);

class PluginRuntime implements PluginExecutor {
  PluginRuntime({
    required this.hostCall,
    this.onStop,
    this.activationTimeout = const Duration(seconds: 5),
    this.callTimeout = const Duration(seconds: 60),
    this.actionTimeout = const Duration(seconds: 20),
    this.taskTimeout = const Duration(minutes: 5),
  });
  final PluginHostCall hostCall;
  final void Function()? onStop;
  final Duration activationTimeout, callTimeout, actionTimeout, taskTimeout;
  @override
  Future<List<Map<String, dynamic>>> activate(
    PluginManifest manifest,
    String code,
  ) async => (await _run(manifest, code)).definitions;
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
    ({List<Map<String, dynamic>> definitions, Map<String, dynamic>? result})
  >
  _run(
    PluginManifest manifest,
    String code, {
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
    Future<void>? closing;
    PluginExecutionError? failure;
    PluginExecutionError? outcomeError;
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
    Future<void> close() async {
      if (engine != null) {
        await (closing ??= engine.close());
      }
    }

    void stop(PluginExecutionError error) {
      failure ??= error;
      accepting = false;
      onStop?.call();
      unawaited(close().catchError((Object _) {}));
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
      await initializeJavascript();
      if (failure != null) {
        throw failure!;
      }
      engine = await JsEngine.create(
        builtins: JsBuiltinOptions.none(),
        runtimeOptions: JsEngineRuntimeOptions(
          memoryLimit: BigInt.from(128 * 1024 * 1024),
          maxStackSize: BigInt.from(1024 * 1024),
        ),
      );
      if (failure != null) {
        throw failure!;
      }
      await engine.init(
        bridge: (value) async {
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
              case 'mismatch':
                throw PluginExecutionError(
                  'plugin_registration_mismatch',
                  '${message['message'] ?? 'Registration differs from activation'}',
                );
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
                final result = await hostCall(
                  method,
                  message['args'] as Map<String, dynamic>,
                );
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
              'code': error is PluginHostError ? error.code : 'plugin_error',
              'error': error is PluginHostError
                  ? error.message
                  : error.toString(),
            };
          }
          return JsResult.ok(JsValue.string(jsonEncode(reply)));
        },
      );
      await engine.eval(
        source: JsCode.code(
          '${pluginPrelude(manifest.id, manifest.version)}\n$code\n${taskId != null
              ? pluginInvokeTask(taskId, input)
              : promptId != null
              ? pluginInvokePrompt(promptId, input)
              : viewId != null
              ? pluginInvokeViewAction(viewId, action!, input)
              : action != null
              ? pluginInvokeAction(action, callId)
              : tool != null
              ? pluginInvoke(tool, input, callId, request)
              : pluginActivate()}',
        ),
      );
      if (failure != null) {
        throw failure!;
      }
      if (!receivedResult) {
        throw PluginExecutionError('plugin_invalid_result', 'Missing result');
      }
      return (definitions: definitions, result: output);
    } catch (error) {
      final text = error.toString();
      if (failure != null) {
        outcomeError = failure;
      } else if (error is PluginExecutionError) {
        outcomeError = error;
      } else if (taskId != null && error is JsError_Timeout) {
        outcomeError = PluginExecutionError(
          'plugin_timeout',
          'Task exceeded the continuous JavaScript execution budget: $text',
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
      throw outcomeError!;
    } finally {
      accepting = false;
      timer.cancel();
      remove?.call();
      onStop?.call();
      try {
        await close();
      } catch (error) {
        throw PluginExecutionError(
          outcomeError?.code ?? 'plugin_error',
          '${outcomeError == null ? '' : '${outcomeError.message}\n'}Runtime cleanup: $error',
        );
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

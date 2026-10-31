// 职责: 驱动原生插件页面会话，确认节点批次并隔离事件、Host 请求与关闭后的迟到结果。
// 关联文件:
//   lib/shared/models/plugin/ui_tree.dart
//   lib/shared/services/javascript.dart
//   lib/shared/services/plugins/runtime.dart
import 'dart:async';
import 'dart:convert';
import 'package:fjs/fjs.dart' as fjs;
import 'package:flutter/foundation.dart';
import '../../logger/app_logger.dart';
import '../../models/plugin/ui_tree.dart';
import '../javascript.dart';
import 'runtime.dart';
import 'page_session.dart';
import 'source_map.dart';

final _log = AppLogger.forModule('PluginUi');

/// Script name the native runtime gives the evaluated view bundle.
const pluginViewFilename = 'plugin-view.js';

class PluginUiSession implements PluginPageSession {
  PluginUiSession({
    required this.tree,
    required this.hostCall,
    this.onClosing,
    this.onClose,
    this.readSourceMap,
  });
  final PluginUiTree tree;
  final PluginHostCall hostCall;

  /// Loads the view source map only when a failure needs TSX positions.
  final Future<String> Function()? readSourceMap;
  final void Function()? onClosing;
  final void Function()? onClose;
  @override
  final ValueNotifier<bool> dirty = ValueNotifier(false);
  final error = ValueNotifier<String?>(null);
  final ready = ValueNotifier(false);
  fjs.UiSession? _native;
  StreamSubscription<fjs.UiOutput>? _output;
  bool _closed = false;
  Future<void>? _closeFuture;
  Map<String, Object?>? _environment;
  @override
  bool get closed => _closed;

  Future<void> start({
    required String source,
    required Map<String, Object?> scope,
    required Map<String, Object?> environment,
  }) async {
    if (_closed || _native != null) {
      throw StateError('UI session already started or closed');
    }
    await initializeJavascript();
    if (_closed) {
      return;
    }
    final native = fjs.UiSession.create();
    _native = native;
    _output = native
        .start(
          surface: tree.surface,
          generation: tree.generation,
          source: source,
          scope: encodeUiValue(scope),
          environment: encodeUiValue(_environment ?? environment),
        )
        .listen(
          (event) => unawaited(_handle(event)),
          onError: (Object failure, StackTrace stack) => fail(failure, stack),
        );
  }

  Future<void> _handle(fjs.UiOutput event) async {
    if (_closed) {
      return;
    }
    try {
      switch (event) {
        case fjs.UiOutput_Batch(:final field0):
          if (tree.apply(field0)) {
            ready.value = true;
            await _native!.ackBatch(seq: field0.seq);
          }
        case fjs.UiOutput_HostCall(:final callId, :final method, :final args):
          Object? value;
          String? failure;
          try {
            final decoded = decodeUiValue(args);
            if (decoded is! Map<String, dynamic>) {
              throw PluginHostError(
                'invalid_argument',
                'Host arguments must be an object',
              );
            }
            if (method == 'view.setDirty') {
              if (decoded['value'] is! bool) {
                throw PluginHostError(
                  'invalid_argument',
                  'Dirty state must be boolean',
                );
              }
              dirty.value = decoded['value'] as bool;
            } else {
              value = await hostCall(method, decoded);
            }
          } catch (exception, stack) {
            _log.error(
              'Host request failed surface=${tree.surface} method=$method',
              error: exception,
              stackTrace: stack,
            );
            failure = jsonEncode({
              'code': exception is PluginHostError
                  ? exception.code
                  : 'plugin_error',
              'message': exception.toString(),
            });
          }
          if (!_closed) {
            await _native!.replyHost(
              callId: callId,
              value: encodeUiValue(value),
              error: failure,
            );
          }
        case fjs.UiOutput_Error(:final code, :final message):
          fail(PluginExecutionError(code, message), StackTrace.current);
        case fjs.UiOutput_Closed():
          await close();
      }
    } catch (failure, stack) {
      fail(failure, stack);
    }
  }

  void dispatch(PluginUiNode node, String event, Map<String, Object?> payload) {
    if (_closed) {
      return;
    }
    final handler = node.handlers[event];
    if (handler == null || tree.node(node.id)?.handlers[event] != handler) {
      return;
    }
    unawaited(
      _native!
          .dispatch(
            event: fjs.UiEvent(
              surface: tree.surface,
              generation: tree.generation,
              seq: BigInt.from(tree.sequence),
              node: BigInt.from(node.id),
              handler: BigInt.from(handler),
              event: event,
              payload: encodeUiValue(payload),
            ),
          )
          .catchError((Object failure, StackTrace stack) {
            fail(failure, stack);
          }),
    );
  }

  Future<void> setEnvironment(Map<String, Object?> environment) async {
    if (mapEquals(_environment, environment)) {
      return;
    }
    _environment = Map.unmodifiable(environment);
    if (_closed || _native == null) {
      return;
    }
    try {
      await _native!.setEnvironment(environment: encodeUiValue(environment));
    } catch (failure, stack) {
      fail(failure, stack);
    }
  }

  void fail(Object failure, StackTrace stack) {
    if (_closed) {
      return;
    }
    error.value = failure.toString();
    unawaited(_report(failure, stack));
    unawaited(close());
  }

  Future<void> _report(Object failure, StackTrace stack) async {
    var reported = failure;
    if (failure is PluginExecutionError && readSourceMap != null) {
      try {
        final map = PluginSourceMap.parse(await readSourceMap!());
        reported = PluginExecutionError(
          failure.code,
          map.rewrite(failure.message, pluginViewFilename),
        );
      } catch (mapError) {
        _log.warning(
          'View source map unavailable surface=${tree.surface} error=$mapError',
        );
      }
    }
    _log.error(
      'Page failed surface=${tree.surface}',
      error: reported,
      stackTrace: stack,
    );
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    final done = Completer<void>();
    _closeFuture = done.future;
    _closed = true;
    unawaited(_finishClose(done));
    return done.future;
  }

  Future<void> _finishClose(Completer<void> done) async {
    try {
      try {
        onClosing?.call();
      } catch (failure, stack) {
        _log.error(
          'Page cancellation callback failed',
          error: failure,
          stackTrace: stack,
        );
      }
      await _native?.close();
      await _output?.cancel();
      _native?.dispose();
      _native = null;
      onClose?.call();
      done.complete();
    } catch (failure, stack) {
      done.completeError(failure, stack);
    }
  }

  /// Called after the surface widget has detached its listeners.
  void dispose() {
    unawaited(close());
    tree.dispose();
    dirty.dispose();
    error.dispose();
    ready.dispose();
  }
}

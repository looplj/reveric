// 职责: 持有单个 A2UI 界面的协议状态 — 加载并校验消息、应用数据更新、按顺序把 action 交给事件处理方。
// 关联文件:
//   lib/shared/widgets/a2ui/catalog.dart
//   lib/shared/widgets/a2ui/surface_view.dart
//   lib/shared/widgets/a2ui/component.dart

import 'dart:async';
import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart';
import 'package:flutter/foundation.dart';

import '../../logger/app_logger.dart';
import 'catalog.dart';
import 'component.dart';

final _log = AppLogger.forModule('A2ui');

/// 对外 UI 协议 `reveric-ui-v1` 对应的 A2UI 版本。
const String a2uiProtocolVersion = 'v1.0';

/// 一条按路径的数据更新，语义同 A2UI `updateDataModel`；`value` 为 null 表示删除该路径。
@immutable
class A2uiDataUpdate {
  const A2uiDataUpdate({required this.path, this.value});

  /// 解析事件处理方返回的 `{ "path": "/x", "value": ... }`。
  factory A2uiDataUpdate.fromJson(Object? json) {
    if (json is! Map || json['path'] is! String) {
      throw const FormatException(
        'Data update must be an object with a string "path".',
      );
    }
    return A2uiDataUpdate(path: json['path'] as String, value: json['value']);
  }

  final String path;
  final Object? value;

  Map<String, Object?> toJson() => {'path': path, 'value': value};
}

/// 交给事件处理方的一次用户操作。
@immutable
class A2uiActionEvent {
  const A2uiActionEvent({
    required this.name,
    required this.sourceComponentId,
    required this.context,
    required this.data,
  });

  final String name;
  final String sourceComponentId;

  /// action 声明的 context，已按触发时的页面数据解析。
  final Map<String, Object?> context;

  /// 触发时页面数据的深拷贝快照。
  final Object? data;
}

/// 事件处理方：插件页面交给插件 action，AI 生成的界面交给 Agent。
/// 返回的数据更新由会话应用到页面；页面关闭后返回的结果直接丢弃。
typedef A2uiActionHandler =
    Future<List<A2uiDataUpdate>> Function(A2uiActionEvent event);

/// 界面描述的数量与大小上限；超出时整个界面显示局部错误。
@immutable
class A2uiLimits {
  const A2uiLimits({
    this.maxComponents = 500,
    this.maxDepth = 32,
    this.maxPayloadBytes = 1024 * 1024,
  });

  /// 一个界面最多声明的组件数（按组件 ID 计，数据模板展开的实例不计）。
  final int maxComponents;

  /// 组件嵌套的最大深度。
  final int maxDepth;

  /// 一次加载的消息或一次返回的数据更新，序列化后的最大字节数。
  final int maxPayloadBytes;
}

/// 加载或更新界面失败；[message] 保留底层原因，供插件作者与 Agent 排查。
class A2uiSessionException implements Exception {
  const A2uiSessionException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'A2uiSessionException($code): $message';
}

const _createSurface = 'createSurface';
const _updateComponents = 'updateComponents';
const _updateDataModel = 'updateDataModel';
const _deleteSurface = 'deleteSurface';

/// 单个界面的协议会话。界面 ID 由宿主分配，消息中的 `surfaceId` 一律被替换。
class A2uiSurfaceSession {
  A2uiSurfaceSession._({
    required this.surfaceId,
    required this.limits,
    required A2uiCatalog catalog,
    required this._onAction,
    required this._onMessages,
    required this._onActionError,
  }) : _catalog = catalog,
       _processor = MessageProcessor<A2uiComponent>(
         catalogs: [catalog],
         defaultVersion: A2uiProtocolVersion.v1_0,
         validationConfig: ValidationConfig(
           // 数据模板引用的组件不从 root 直接可达。
           allowOrphanComponents: true,
           maxDepth: limits.maxDepth,
         ),
       );

  /// 加载一组 A2UI 消息，首条必须是 `createSurface`。
  /// 加载失败不抛异常，而是进入 [error] 状态，由界面显示局部错误。
  factory A2uiSurfaceSession.load({
    required String surfaceId,
    required Object? messages,
    A2uiActionHandler? onAction,
    Future<List<dynamic>> Function(A2uiActionEvent event)? onMessages,
    void Function(A2uiActionEvent event, Object error)? onActionError,
    A2uiCatalog? catalog,
    A2uiLimits limits = const A2uiLimits(),
  }) {
    final session = A2uiSurfaceSession._(
      surfaceId: surfaceId,
      limits: limits,
      catalog: catalog ?? revericA2uiCatalog,
      onAction: onAction,
      onMessages: onMessages,
      onActionError: onActionError,
    );
    try {
      session._load(messages);
    } on Object catch (error) {
      session._fail(error);
    }
    return session;
  }

  final String surfaceId;
  final A2uiLimits limits;
  final A2uiCatalog _catalog;
  final A2uiActionHandler? _onAction;
  final Future<List<dynamic>> Function(A2uiActionEvent event)? _onMessages;
  int _dataVersion = 0;
  final void Function(A2uiActionEvent event, Object error)? _onActionError;
  final MessageProcessor<A2uiComponent> _processor;
  final Set<String> _componentIds = {};
  final List<Subscription> _subscriptions = [];
  final ValueNotifier<A2uiSessionException?> _error = ValueNotifier(null);
  final ValueNotifier<List<String>> _pendingSources = ValueNotifier(const []);
  Future<void> _actionQueue = Future.value();
  bool _disposed = false;
  bool _actionsClosed = false;

  void cancelActions() {
    _actionsClosed = true;
  }

  /// 加载成功后的界面；失败或已删除时为 null。
  SurfaceModel<A2uiComponent>? get surface =>
      _disposed ? null : _processor.model.getSurface(surfaceId);

  /// 界面失败原因；正常时为 null。
  ValueListenable<A2uiSessionException?> get error => _error;

  /// 已触发、尚未处理完的 action 来源组件 ID，按触发顺序排列。
  ValueListenable<List<String>> get pendingSources => _pendingSources;

  bool get isDisposed => _disposed;

  void _load(Object? messages) {
    final envelopes = _envelopesOf(messages);
    if (envelopes.isEmpty ||
        _messageTypeOf(envelopes.first) != _createSurface) {
      throw const A2uiSessionException(
        'INVALID_MESSAGES',
        'The first message must be createSurface.',
      );
    }
    _checkPayloadSize(envelopes);
    final prepared = [
      for (final (index, envelope) in envelopes.indexed)
        _prepare(
          envelope,
          allowed: index == 0
              ? const {_createSurface}
              : const {_updateComponents, _updateDataModel},
        ),
    ];
    _processor.processMessages(prepared);
    final surface = this.surface;
    if (surface == null) {
      throw const A2uiSessionException(
        'INVALID_MESSAGES',
        'createSurface did not create a surface.',
      );
    }
    _subscriptions
      ..add(
        surface.dataModel.subscribe<Object?>('/', (_) {
          _dataVersion++;
        }),
      )
      ..add(surface.onAction.subscribe(_enqueueAction))
      ..add(
        surface.onError.subscribe(
          (error) => _log.warning(
            'surface=$surfaceId runtime error ${error.code}: ${error.message}'
            '${error.path == null ? '' : ' path=${error.path}'}',
          ),
        ),
      );
  }

  /// 应用后续消息（如 Agent 推送的组件或数据更新），不允许再次创建界面。
  /// 校验失败时抛出异常，未通过校验的那条消息不生效。
  void applyMessages(Object? messages) {
    _ensureReady();
    final envelopes = _envelopesOf(messages);
    _checkPayloadSize(envelopes);
    final countedIds = {..._componentIds};
    try {
      final prepared = [
        for (final envelope in envelopes)
          _prepare(
            envelope,
            allowed: const {
              _updateComponents,
              _updateDataModel,
              _deleteSurface,
            },
          ),
      ];
      _processor.processMessages(prepared);
    } on Object {
      // 被拒绝的消息不计入组件数。
      _componentIds
        ..clear()
        ..addAll(countedIds);
      rethrow;
    }
  }

  /// 应用事件处理方返回的数据更新。
  void applyDataUpdates(List<A2uiDataUpdate> updates) {
    _ensureReady();
    if (updates.isEmpty) {
      return;
    }
    _checkPayloadSize([for (final update in updates) update.toJson()]);
    _processor.processMessages([
      for (final update in updates)
        {
          'version': a2uiProtocolVersion,
          _updateDataModel: {
            'surfaceId': surfaceId,
            'path': update.path,
            'value': update.value,
          },
        },
    ]);
  }

  /// 当前页面数据的深拷贝快照。
  Object? dataSnapshot() {
    final surface = this.surface;
    if (surface == null) {
      return null;
    }
    return jsonDecode(jsonEncode(surface.dataModel.get('/')));
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final subscription in _subscriptions) {
      subscription.unsubscribe();
    }
    _processor.dispose();
    _error.dispose();
    _pendingSources.dispose();
  }

  void _ensureReady() {
    if (_disposed) {
      throw const A2uiSessionException(
        'SURFACE_DISPOSED',
        'The surface has been closed.',
      );
    }
    if (_error.value != null || surface == null) {
      throw A2uiSessionException(
        'SURFACE_UNAVAILABLE',
        _error.value?.message ?? 'The surface does not exist.',
      );
    }
  }

  void _fail(Object error) {
    final exception = switch (error) {
      final A2uiSessionException e => e,
      final A2uiError e => A2uiSessionException(e.code, e.message),
      final FormatException e => A2uiSessionException(
        'INVALID_MESSAGES',
        e.message,
      ),
      _ => A2uiSessionException('INTERNAL_ERROR', error.toString()),
    };
    _log.warning(
      'surface=$surfaceId load failed ${exception.code}: ${exception.message}',
    );
    _error.value = exception;
  }

  List<Map<String, Object?>> _envelopesOf(Object? messages) {
    final items = switch (messages) {
      final List<Object?> list => list,
      final Map<Object?, Object?> map when map['messages'] is List =>
        map['messages'] as List<Object?>,
      final Map<Object?, Object?> map => [map],
      _ => throw const A2uiSessionException(
        'INVALID_MESSAGES',
        'Messages must be an envelope or a list of envelopes.',
      ),
    };
    return [
      for (final item in items)
        if (item is Map<String, Object?>)
          item
        else if (item is Map && item.keys.every((key) => key is String))
          item.cast<String, Object?>()
        else
          throw const A2uiSessionException(
            'INVALID_MESSAGES',
            'Every message must be a JSON object.',
          ),
    ];
  }

  String? _messageTypeOf(Map<String, Object?> envelope) {
    for (final type in const [
      _createSurface,
      _updateComponents,
      _updateDataModel,
      _deleteSurface,
    ]) {
      if (envelope.containsKey(type)) {
        return type;
      }
    }
    return null;
  }

  /// 校验消息类型与版本，替换界面 ID，补默认组件目录，并累计组件数。
  Map<String, Object?> _prepare(
    Map<String, Object?> envelope, {
    required Set<String> allowed,
  }) {
    final version = envelope['version'];
    if (version != a2uiProtocolVersion) {
      throw A2uiSessionException(
        'UNSUPPORTED_VERSION',
        'Message version must be "$a2uiProtocolVersion", got "$version".',
      );
    }
    final type = _messageTypeOf(envelope);
    if (type == null || !allowed.contains(type)) {
      throw A2uiSessionException(
        'MESSAGE_NOT_ALLOWED',
        'Message ${type ?? envelope.keys.join(',')} is not allowed here; '
            'allowed: ${allowed.join(', ')}.',
      );
    }
    final body = envelope[type];
    if (body is! Map) {
      throw A2uiSessionException(
        'INVALID_MESSAGES',
        'Message $type must be an object.',
      );
    }
    final rewritten = <String, Object?>{
      ...body.cast<String, Object?>(),
      'surfaceId': surfaceId,
    };
    if (type == _createSurface) {
      rewritten.putIfAbsent('catalogId', () => _catalog.id);
    }
    _countComponents(rewritten['components']);
    return {'version': version, type: rewritten};
  }

  void _countComponents(Object? components) {
    if (components is! List) {
      return;
    }
    for (final component in components) {
      if (component is Map && component['id'] is String) {
        _componentIds.add(component['id'] as String);
      }
    }
    if (_componentIds.length > limits.maxComponents) {
      throw A2uiSessionException(
        'TOO_MANY_COMPONENTS',
        'A surface may declare at most ${limits.maxComponents} components, '
            'got ${_componentIds.length}.',
      );
    }
  }

  void _checkPayloadSize(List<Object?> payload) {
    final bytes = utf8.encode(jsonEncode(payload)).length;
    if (bytes > limits.maxPayloadBytes) {
      throw A2uiSessionException(
        'PAYLOAD_TOO_LARGE',
        'Payload is $bytes bytes, the limit is ${limits.maxPayloadBytes}.',
      );
    }
  }

  void _enqueueAction(A2uiRendererAction action) {
    if (_disposed || _actionsClosed) {
      return;
    }
    if (_onMessages != null) {
      dispatchAction(
        A2uiActionEvent(
          name: action.name,
          sourceComponentId: action.sourceComponentId,
          context: Map.unmodifiable(action.context),
          data: dataSnapshot(),
        ),
      );
      return;
    }
    final handler = _onAction;
    if (handler == null || _disposed) {
      _log.info('surface=$surfaceId action ${action.name} ignored: no handler');
      return;
    }
    _pendingSources.value = [
      ..._pendingSources.value,
      action.sourceComponentId,
    ];
    // 同一界面的 action 按触发顺序执行，前一个返回后再执行下一个。
    _actionQueue = _actionQueue.then((_) => _runAction(action, handler));
  }

  /// Dispatch an onMount or user action with its immutable data snapshot.
  void dispatchAction(A2uiActionEvent event) {
    _ensureReady();
    if (_onMessages == null) {
      throw StateError('No message action handler');
    }
    final version = _dataVersion;
    _pendingSources.value = [..._pendingSources.value, event.sourceComponentId];
    _actionQueue = _actionQueue.then((_) async {
      if (_disposed || _actionsClosed) {
        return;
      }
      try {
        final messages = await _onMessages(event);
        if (_disposed || _actionsClosed) {
          return;
        }
        if (version != _dataVersion) {
          throw const A2uiSessionException(
            'STALE_ACTION_RESULT',
            'Page data changed while action was pending; refresh before retrying',
          );
        }
        final envelopes = _envelopesOf(messages);
        if (envelopes.any(
          (m) => !const {
            _updateComponents,
            _updateDataModel,
          }.contains(_messageTypeOf(m)),
        )) {
          throw const A2uiSessionException(
            'MESSAGE_NOT_ALLOWED',
            'Actions may only update this surface',
          );
        }
        applyMessages(envelopes);
      } catch (error, stack) {
        if (!_disposed) {
          _log.error(
            'surface=$surfaceId action ${event.name} failed',
            error: error,
            stackTrace: stack,
          );
          _onActionError?.call(event, error);
        }
      } finally {
        if (!_disposed) {
          _pendingSources.value = [..._pendingSources.value]
            ..remove(event.sourceComponentId);
        }
      }
    });
  }

  Future<void> _runAction(
    A2uiRendererAction action,
    A2uiActionHandler handler,
  ) async {
    if (_disposed || _actionsClosed) {
      return;
    }
    final event = A2uiActionEvent(
      name: action.name,
      sourceComponentId: action.sourceComponentId,
      context: Map.unmodifiable(action.context),
      data: dataSnapshot(),
    );
    try {
      final updates = await handler(event);
      if (_disposed || _actionsClosed) {
        return;
      }
      applyDataUpdates(updates);
    } on Object catch (error, stackTrace) {
      if (_disposed || _actionsClosed) {
        return;
      }
      _log.error(
        'surface=$surfaceId action ${action.name} failed',
        error: error,
        stackTrace: stackTrace,
      );
      _onActionError?.call(event, error);
    } finally {
      if (!_disposed) {
        final pending = [..._pendingSources.value]
          ..remove(action.sourceComponentId);
        _pendingSources.value = pending;
      }
    }
  }
}

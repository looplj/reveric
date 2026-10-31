// 职责: 验证 A2UI 会话的加载校验、上限、数据更新与 action 顺序执行契约。
// 关联文件:
//   lib/shared/widgets/a2ui/session.dart
//   lib/shared/widgets/a2ui/catalog.dart
//   lib/shared/widgets/a2ui/preview/samples.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:async';

import 'package:a2ui_core/a2ui_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/widgets/a2ui/catalog.dart';
import 'package:reveric/shared/widgets/a2ui/component.dart';
import 'package:reveric/shared/widgets/a2ui/preview/samples.dart';
import 'package:reveric/shared/widgets/a2ui/session.dart';

Map<String, Object?> _create(
  List<Map<String, Object?>> components, {
  Map<String, Object?> dataModel = const {},
  String version = a2uiProtocolVersion,
}) => {
  'version': version,
  'createSurface': {
    'surfaceId': 'from-plugin',
    'components': components,
    'dataModel': dataModel,
  },
};

Map<String, Object?> _button(String id, String eventName) => {
  'id': id,
  'component': 'Button',
  'child': '${id}_label',
  'action': {
    'event': {
      'name': eventName,
      'context': {
        'value': {'@path': '/value'},
      },
    },
  },
};

/// root Column 下一个文字和两个按钮，按钮 action 带上 /value。
List<Map<String, Object?>> _twoButtons() => [
  {
    'id': 'root',
    'component': 'Column',
    'children': ['text', 'first', 'second'],
  },
  {
    'id': 'text',
    'component': 'Text',
    'text': {'@path': '/value'},
  },
  {'id': 'first_label', 'component': 'Text', 'text': 'First'},
  {'id': 'second_label', 'component': 'Text', 'text': 'Second'},
  _button('first', 'first'),
  _button('second', 'second'),
];

A2uiSurfaceSession _load(
  Object? messages, {
  A2uiActionHandler? onAction,
  void Function(A2uiActionEvent event, Object error)? onActionError,
  A2uiLimits limits = const A2uiLimits(),
}) {
  final session = A2uiSurfaceSession.load(
    surfaceId: 'host-1',
    messages: messages,
    onAction: onAction,
    onActionError: onActionError,
    limits: limits,
  );
  addTearDown(session.dispose);
  return session;
}

/// 与界面点击相同：从解析后的节点取 action 闭包，调用时按当时的页面数据解析 context。
Future<void> Function() _actionOf(A2uiSurfaceSession session, String id) {
  final resolver = NodeResolver<A2uiComponent>(session.surface!);
  addTearDown(resolver.dispose);
  A2uiNode? find(A2uiNode node) {
    if (node.componentId == id) {
      return node;
    }
    for (final child in A2uiProps(node.props.peek()).children('children')) {
      final found = find(child);
      if (found != null) {
        return found;
      }
    }
    return null;
  }

  final node = find(resolver.rootNode.peek()!)!;
  return A2uiProps(node.props.peek()).action('action')!;
}

void main() {
  group('load', () {
    test('every sample except the invalid one loads', () {
      for (final sample in a2uiSamples) {
        final session = _load(sample.messages);
        if (sample == invalidA2uiSample) {
          expect(session.error.value, isNotNull, reason: sample.id);
        } else {
          expect(session.error.value, isNull, reason: sample.id);
          expect(session.surface, isNotNull, reason: sample.id);
        }
      }
    });

    test('replaces the surface id and fills in the catalog id', () {
      final session = _load([_create(_twoButtons())]);

      expect(session.error.value, isNull);
      expect(session.surface!.id, 'host-1');
      expect(session.surface!.defaultCatalog!.id, revericA2uiCatalogId);
    });

    test('rejects a first message that is not createSurface', () {
      final session = _load([
        {
          'version': a2uiProtocolVersion,
          'updateDataModel': {'surfaceId': 'x', 'path': '/a', 'value': 1},
        },
      ]);

      expect(session.error.value?.code, 'INVALID_MESSAGES');
      expect(session.surface, isNull);
    });

    test('rejects other protocol versions', () {
      final session = _load([_create(_twoButtons(), version: 'v0.9')]);

      expect(session.error.value?.code, 'UNSUPPORTED_VERSION');
    });

    test('rejects deleteSurface in a page file', () {
      final session = _load([
        _create(_twoButtons()),
        {
          'version': a2uiProtocolVersion,
          'deleteSurface': {'surfaceId': 'from-plugin'},
        },
      ]);

      expect(session.error.value?.code, 'MESSAGE_NOT_ALLOWED');
    });

    test('rejects components outside the catalog with the reason kept', () {
      final session = _load(invalidA2uiSample.messages);

      expect(session.error.value?.code, 'VALIDATION_FAILED');
      expect(session.error.value?.message, contains('Video'));
    });

    test('rejects props that do not match the component schema', () {
      final session = _load([
        _create([
          {
            'id': 'root',
            'component': 'Column',
            'children': ['gap'],
          },
          {'id': 'gap', 'component': 'Gap', 'size': 'huge'},
        ]),
      ]);

      expect(session.error.value?.code, 'VALIDATION_FAILED');
    });

    test('a Button child must be a Text or an Icon', () {
      final session = _load([
        _create([
          {
            'id': 'root',
            'component': 'Column',
            'children': ['button'],
          },
          {'id': 'field', 'component': 'TextField', 'label': 'Name'},
          {
            'id': 'button',
            'component': 'Button',
            'child': 'field',
            'action': {
              'event': {'name': 'go'},
            },
          },
        ]),
      ]);

      expect(session.error.value, isNotNull);
    });

    test('enforces the component count limit', () {
      final session = _load([
        _create(_twoButtons()),
      ], limits: const A2uiLimits(maxComponents: 5));

      expect(session.error.value?.code, 'TOO_MANY_COMPONENTS');
    });

    test('enforces the nesting depth limit', () {
      final session = _load([
        _create([
          {
            'id': 'root',
            'component': 'Column',
            'children': ['a'],
          },
          {
            'id': 'a',
            'component': 'Column',
            'children': ['b'],
          },
          {
            'id': 'b',
            'component': 'Column',
            'children': ['c'],
          },
          {'id': 'c', 'component': 'Text', 'text': 'deep'},
        ]),
      ], limits: const A2uiLimits(maxDepth: 2));

      expect(session.error.value, isNotNull);
    });

    test('enforces the payload size limit', () {
      final session = _load([
        _create(_twoButtons(), dataModel: {'value': 'x' * 2048}),
      ], limits: const A2uiLimits(maxPayloadBytes: 1024));

      expect(session.error.value?.code, 'PAYLOAD_TOO_LARGE');
    });
  });

  group('updates', () {
    test('data updates reach the data model and null removes a path', () {
      final session = _load([
        _create(_twoButtons(), dataModel: {'value': 'a', 'extra': 1}),
      ]);

      session.applyDataUpdates(const [
        A2uiDataUpdate(path: '/value', value: 'b'),
        A2uiDataUpdate(path: '/extra'),
      ]);

      expect(session.dataSnapshot(), {'value': 'b'});
    });

    test('later messages cannot create another surface', () {
      final session = _load([_create(_twoButtons())]);

      expect(
        () => session.applyMessages([_create(_twoButtons())]),
        throwsA(
          isA<A2uiSessionException>().having(
            (e) => e.code,
            'code',
            'MESSAGE_NOT_ALLOWED',
          ),
        ),
      );
    });

    test('a rejected update does not count toward the component limit', () {
      final session = _load([
        _create(_twoButtons()),
      ], limits: const A2uiLimits(maxComponents: 7));
      Map<String, Object?> update(String id, String component) => {
        'version': a2uiProtocolVersion,
        'updateComponents': {
          'surfaceId': 'x',
          'components': [
            {'id': id, 'component': component, 'text': 'new'},
          ],
        },
      };

      expect(
        () => session.applyMessages([update('extra', 'Nope')]),
        throwsA(anything),
      );
      session.applyMessages([update('extra', 'Text')]);
      expect(session.surface!.componentsModel.get('extra'), isNotNull);
    });

    test('A2uiDataUpdate.fromJson requires a string path', () {
      expect(A2uiDataUpdate.fromJson({'path': '/a', 'value': 1}).value, 1);
      expect(
        () => A2uiDataUpdate.fromJson({'value': 1}),
        throwsFormatException,
      );
    });
  });

  test(
    'message actions reject edited snapshots and update component structure',
    () async {
      final gates = <Completer<List<dynamic>>>[];
      final errors = <Object>[];
      final session = A2uiSurfaceSession.load(
        surfaceId: 'host-message',
        messages: [
          _create(_twoButtons(), dataModel: {'value': 'start'}),
        ],
        onMessages: (event) {
          expect(event.data, {'value': gates.isEmpty ? 'start' : 'edited'});
          final gate = Completer<List<dynamic>>();
          gates.add(gate);
          return gate.future;
        },
        onActionError: (_, error) => errors.add(error),
      );
      addTearDown(session.dispose);
      await _actionOf(session, 'first')();
      await pumpEventQueue();
      session.surface!.dataModel.set('/value', 'edited');
      gates[0].complete([
        {
          'version': 'v1.0',
          'updateDataModel': {'path': '/value', 'value': 'stale'},
        },
      ]);
      await pumpEventQueue();
      expect(session.dataSnapshot(), {'value': 'edited'});
      expect(
        (errors.single as A2uiSessionException).code,
        'STALE_ACTION_RESULT',
      );
      await _actionOf(session, 'first')();
      await pumpEventQueue();
      gates[1].complete([
        {
          'version': 'v1.0',
          'updateComponents': {
            'components': [
              {'id': 'extra', 'component': 'Text', 'text': 'Added'},
            ],
          },
        },
        {
          'version': 'v1.0',
          'updateDataModel': {'path': '/value', 'value': 'fresh'},
        },
      ]);
      await pumpEventQueue();
      expect(session.dataSnapshot(), {'value': 'fresh'});
      expect(errors, hasLength(1));
    },
  );

  group('actions', () {
    test('run one at a time in trigger order with a data snapshot', () async {
      final started = <String>[];
      final gates = <String, Completer<List<A2uiDataUpdate>>>{};
      final session = _load(
        [
          _create(_twoButtons(), dataModel: {'value': 'start'}),
        ],
        onAction: (event) {
          started.add(event.name);
          expect(event.data, {'value': started.length == 1 ? 'start' : '1'});
          return (gates[event.name] = Completer()).future;
        },
      );

      await _actionOf(session, 'first')();
      await _actionOf(session, 'second')();
      await pumpEventQueue();

      expect(started, ['first']);
      expect(session.pendingSources.value, ['first', 'second']);

      gates['first']!.complete(const [
        A2uiDataUpdate(path: '/value', value: '1'),
      ]);
      await pumpEventQueue();

      expect(started, ['first', 'second']);
      expect(session.pendingSources.value, ['second']);

      gates['second']!.complete(const [
        A2uiDataUpdate(path: '/value', value: '2'),
      ]);
      await pumpEventQueue();

      expect(session.pendingSources.value, isEmpty);
      expect(session.dataSnapshot(), {'value': '2'});
    });

    test('a failed action is reported and the next one still runs', () async {
      final errors = <String>[];
      final session = _load(
        [_create(_twoButtons())],
        onAction: (event) async {
          if (event.name == 'first') {
            throw StateError('plugin crashed');
          }
          return const [A2uiDataUpdate(path: '/value', value: 'ok')];
        },
        onActionError: (event, error) => errors.add('${event.name}: $error'),
      );

      await _actionOf(session, 'first')();
      await _actionOf(session, 'second')();
      await pumpEventQueue();

      expect(errors, ['first: Bad state: plugin crashed']);
      expect(session.dataSnapshot(), {'value': 'ok'});
      expect(session.pendingSources.value, isEmpty);
    });

    test('results returned after the surface closes are dropped', () async {
      final gate = Completer<List<A2uiDataUpdate>>();
      final errors = <Object>[];
      final session = A2uiSurfaceSession.load(
        surfaceId: 'host-1',
        messages: [_create(_twoButtons())],
        onAction: (_) => gate.future,
        onActionError: (_, error) => errors.add(error),
      );

      await _actionOf(session, 'first')();
      await pumpEventQueue();
      session.dispose();
      gate.complete(const [A2uiDataUpdate(path: '/value', value: 'late')]);
      await pumpEventQueue();

      expect(errors, isEmpty);
      expect(session.surface, isNull);
    });
  });
}

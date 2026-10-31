// 职责: 验证插件节点批次的原子性、身份/结构校验与输入回写顺序。
// 关联文件:
//   lib/shared/models/plugin/ui_tree.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:fjs/fjs.dart' as fjs;
import 'package:reveric/shared/models/plugin/ui_tree.dart';

BigInt id(int value) => BigInt.from(value);
fjs.UiOp create(int value, String component) =>
    fjs.UiOp.create(id: id(value), component: component);
fjs.UiOp set(int value, Map<String, dynamic> props, {int? revision}) =>
    fjs.UiOp.set_(
      id: id(value),
      props: props.map((key, value) => MapEntry(key, encodeUiValue(value))),
      unset: [],
      editRevision: revision == null ? null : id(revision),
    );
fjs.UiOp insert(int parent, int child, {String slot = 'children'}) =>
    fjs.UiOp.insert(
      parent: id(parent),
      child: id(child),
      slot: slot,
      before: null,
    );
fjs.UiBatch batch(int seq, List<fjs.UiOp> ops) =>
    fjs.UiBatch(surface: 'test', generation: 1, seq: id(seq), ops: ops);
void main() {
  late PluginUiTree tree;
  setUp(() => tree = PluginUiTree(surface: 'test', generation: 1));
  tearDown(() => tree.dispose());
  test(
    'commits whole batch once and rejects invalid changes without partial writes',
    () {
      tree.apply(
        batch(1, [
          create(2, 'Text'),
          set(2, {'text': 'original'}),
          insert(1, 2),
        ]),
      );
      final original = tree.node(2);
      expect(
        () => tree.apply(
          batch(2, [
            set(2, {'text': 'changed'}),
            create(3, 'Unknown'),
          ]),
        ),
        throwsFormatException,
      );
      expect(tree.node(2), same(original));
      expect(tree.sequence, 1);
      expect(
        tree.apply(
          batch(1, [
            set(2, {'text': 'duplicate'}),
          ]),
        ),
        true,
      );
      expect(tree.node(2)!.props['text'], 'original');
    },
  );
  test('rejects cycles, reuse, wrong slots and skipped sequences', () {
    tree.apply(
      batch(1, [
        create(2, 'Fragment'),
        create(3, 'Fragment'),
        insert(1, 2),
        insert(2, 3),
      ]),
    );
    expect(() => tree.apply(batch(2, [insert(3, 2)])), throwsFormatException);
    expect(tree.node(2)!.parent, 1);
    expect(
      () => tree.apply(batch(2, [create(2, 'Text')])),
      throwsFormatException,
    );
    expect(
      () => tree.apply(batch(2, [insert(1, 3, slot: 'body')])),
      throwsFormatException,
    );
    expect(() => tree.apply(batch(3, [])), throwsFormatException);
  });
  test('ignores stale text echoes while committing independent properties', () {
    tree.apply(
      batch(1, [
        create(2, 'TextField'),
        set(2, {'value': ''}),
        insert(1, 2),
      ]),
    );
    tree.recordEdit(2);
    tree.recordEdit(2);
    tree.apply(
      batch(2, [
        set(2, {'value': 'old', 'error': 'check'}, revision: 1),
      ]),
    );
    expect(tree.node(2)!.props['value'], '');
    expect(tree.node(2)!.props['error'], 'check');
    tree.apply(
      batch(3, [
        set(2, {'value': 'new'}, revision: 2),
      ]),
    );
    expect(tree.node(2)!.props['value'], 'new');
    expect(tree.node(2)!.editRevision, 2);
  });
  test(
    'rejects missing required fields, malformed options and virtualized editors',
    () {
      expect(
        () => tree.apply(batch(1, [create(2, 'Button')])),
        throwsFormatException,
      );
      expect(
        () => tree.apply(
          batch(1, [
            create(2, 'Select'),
            set(2, {
              'value': null,
              'options': [
                {'value': 'a', 'label': 'A'},
                {'value': 'a', 'label': 'B'},
              ],
            }),
          ]),
        ),
        throwsFormatException,
      );
      expect(
        () => tree.apply(
          batch(1, [
            create(2, 'List'),
            set(2, {'height': 100, 'itemExtent': 30}),
            insert(1, 2),
            create(3, 'TextField'),
            set(3, {'value': 'draft'}),
            insert(2, 3),
          ]),
        ),
        throwsFormatException,
      );
      expect(tree.nodes.keys, [1]);
    },
  );
  test('notifies changed nodes after atomically publishing the whole tree', () {
    tree.apply(
      batch(1, [
        create(2, 'Text'),
        set(2, {'text': 'A'}),
        insert(1, 2),
        create(3, 'Text'),
        set(3, {'text': 'B'}),
        insert(1, 3),
      ]),
    );
    var changed = 0, untouched = 0;
    tree.watch(2).addListener(() {
      changed++;
      expect(tree.node(2)!.props['text'], 'new');
    });
    tree.watch(3).addListener(() => untouched++);
    tree.apply(
      batch(2, [
        set(2, {'text': 'new'}),
      ]),
    );
    expect(changed, 1);
    expect(untouched, 0);
  });
  test('validates moved subtrees against their new ancestors', () {
    tree.apply(
      batch(1, [
        create(2, 'List'),
        set(2, {'height': 100, 'itemExtent': 30}),
        insert(1, 2),
        create(3, 'Fragment'),
        insert(1, 3),
        create(4, 'TextField'),
        set(4, {'value': 'draft'}),
        insert(3, 4),
      ]),
    );
    final before = tree.node(3);
    expect(() => tree.apply(batch(2, [insert(2, 3)])), throwsFormatException);
    expect(tree.node(3), same(before));
    expect(tree.node(2)!.slots['children'] ?? const <int>[], isEmpty);
  });
  test('flex changes notify the layout parent through fragments', () {
    tree.apply(
      batch(1, [
        create(2, 'Row'),
        insert(1, 2),
        create(3, 'Fragment'),
        insert(2, 3),
        create(4, 'Text'),
        set(4, {'text': 'A'}),
        insert(3, 4),
      ]),
    );
    var row = 0;
    tree.watch(2).addListener(() => row++);
    tree.apply(
      batch(2, [
        set(4, {'text': 'B'}),
      ]),
    );
    expect(row, 0);
    tree.apply(
      batch(3, [
        set(4, {'flex': 1}),
      ]),
    );
    expect(row, 1);
  });
}

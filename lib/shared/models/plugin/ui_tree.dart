// 职责: 校验并原子提交原生插件 UI 批次，维护稳定节点与本地输入序号。
// 关联文件:
//   lib/shared/models/plugin/ui_schema.dart
//   third/fjs/lib/src/frb/api/ui.dart
import 'package:fjs/fjs.dart' as fjs;
import 'package:flutter/foundation.dart';
import 'ui_schema.dart';

Object? decodeUiValue(fjs.UiValue value, [int depth = 0]) {
  if (depth > 32) {
    throw const FormatException('UI value nesting exceeds 32');
  }
  return switch (value) {
    fjs.UiValue_Null() => null,
    fjs.UiValue_Boolean(:final field0) => field0,
    fjs.UiValue_Number(:final field0) when field0.isFinite => field0,
    fjs.UiValue_String(:final field0) => field0,
    fjs.UiValue_Array(:final field0) => List<Object?>.unmodifiable(
      field0.map((v) => decodeUiValue(v, depth + 1)),
    ),
    fjs.UiValue_Object(:final field0) => Map<String, Object?>.unmodifiable(
      field0.map((k, v) => MapEntry(k, decodeUiValue(v, depth + 1))),
    ),
    _ => throw const FormatException('UI numbers must be finite'),
  };
}

fjs.UiValue encodeUiValue(Object? value, [int depth = 0]) {
  if (depth > 32) {
    throw const FormatException('UI value nesting exceeds 32');
  }
  return switch (value) {
    null => const fjs.UiValue.null_(),
    bool v => fjs.UiValue.boolean(v),
    num v when v.isFinite => fjs.UiValue.number(v.toDouble()),
    String v => fjs.UiValue.string(v),
    List v => fjs.UiValue.array(
      v.map((v) => encodeUiValue(v, depth + 1)).toList(),
    ),
    Map<String, dynamic> v => fjs.UiValue.object(
      v.map((k, v) => MapEntry(k, encodeUiValue(v, depth + 1))),
    ),
    _ => throw const FormatException('Unsupported UI value'),
  };
}

class PluginUiNode {
  PluginUiNode({
    required this.id,
    required this.component,
    required Map<String, Object?> props,
    Map<String, List<int>> slots = const {},
    Map<String, int> handlers = const {},
    this.parent,
    this.parentSlot,
    this.editRevision = 0,
  }) : props = Map.unmodifiable(props),
       slots = Map.unmodifiable(
         slots.map((k, v) => MapEntry(k, List<int>.unmodifiable(v))),
       ),
       handlers = Map.unmodifiable(handlers);
  final int id;
  final String component;
  final Map<String, Object?> props;
  final Map<String, List<int>> slots;
  final Map<String, int> handlers;
  final int? parent;
  final String? parentSlot;
  final int editRevision;
}

class _Draft {
  _Draft(PluginUiNode node)
    : id = node.id,
      component = node.component,
      props = Map.of(node.props),
      slots = node.slots.map((k, v) => MapEntry(k, List.of(v))),
      handlers = Map.of(node.handlers),
      parent = node.parent,
      parentSlot = node.parentSlot,
      editRevision = node.editRevision;
  final int id;
  final String component;
  final Map<String, Object?> props;
  final Map<String, List<int>> slots;
  final Map<String, int> handlers;
  int? parent;
  String? parentSlot;
  int editRevision;
  PluginUiNode freeze() => PluginUiNode(
    id: id,
    component: component,
    props: props,
    slots: slots,
    handlers: handlers,
    parent: parent,
    parentSlot: parentSlot,
    editRevision: editRevision,
  );
}

class PluginUiTree {
  PluginUiTree({
    required this.surface,
    required this.generation,
    this.iconNames = const {},
  }) {
    _nodes[1] = PluginUiNode(
      id: 1,
      component: 'Column',
      props: _defaults('Column'),
    );
  }
  final String surface;
  final int generation;
  final Set<String> iconNames;
  final Map<int, PluginUiNode> _nodes = {};
  final _listeners = <int, ValueNotifier<PluginUiNode?>>{};
  final _edits = <int, int>{};
  final _removed = ValueNotifier<PluginUiNode?>(null);
  int sequence = 0;
  int _lastId = 1;
  bool _disposed = false;
  Map<int, PluginUiNode> get nodes => Map.unmodifiable(_nodes);
  PluginUiNode? node(int id) => _nodes[id];
  List<int> children(int id, String slot) {
    final result = <int>[];
    void append(int child) {
      final value = _nodes[child]!;
      if (value.component == 'Fragment') {
        for (final nested in value.slots['children'] ?? const <int>[]) {
          append(nested);
        }
      } else {
        result.add(child);
      }
    }

    for (final child in _nodes[id]?.slots[slot] ?? const <int>[]) {
      append(child);
    }
    return result;
  }

  ValueListenable<PluginUiNode?> watch(int id) => !_nodes.containsKey(id)
      ? _removed
      : _listeners.putIfAbsent(id, () => ValueNotifier(_nodes[id]));
  int recordEdit(int id) => _edits[id] = (_edits[id] ?? 0) + 1;
  int editRevision(int id) => _edits[id] ?? 0;

  /// Returns false for an obsolete surface; duplicates only acknowledge again.
  bool apply(fjs.UiBatch batch) {
    if (_disposed ||
        batch.surface != surface ||
        batch.generation != generation) {
      return false;
    }
    final seq = _id(batch.seq);
    if (seq == sequence) {
      return true;
    }
    if (seq != sequence + 1 || batch.ops.length > 4096) {
      throw const FormatException(
        'Invalid UI batch sequence or operation count',
      );
    }
    // Copy-on-write overlay: only nodes this batch reads for mutation are
    // copied, and null marks a release.
    final staged = <int, _Draft?>{};
    final changed = <int>{}, attached = <int>{};
    var lastId = _lastId, count = _nodes.length;
    _Draft? draft(int id) {
      if (staged.containsKey(id)) {
        return staged[id];
      }
      final node = _nodes[id];
      return node == null ? null : staged[id] = _Draft(node);
    }

    _Draft require(int id) =>
        draft(id) ?? (throw FormatException('Unknown UI node $id'));
    ({String component, int? parent, Iterable<int> children})? read(int id) {
      if (staged.containsKey(id)) {
        final node = staged[id];
        return node == null
            ? null
            : (
                component: node.component,
                parent: node.parent,
                children: node.slots.values.expand((ids) => ids),
              );
      }
      final node = _nodes[id];
      return node == null
          ? null
          : (
              component: node.component,
              parent: node.parent,
              children: node.slots.values.expand((ids) => ids),
            );
    }

    void touch(int id) {
      final visited = <int>{};
      while (visited.add(id)) {
        changed.add(id);
        // Listeners only fire for a new frozen instance, so copy what changes.
        final node = draft(id);
        if (node?.component != 'Fragment' || node?.parent == null) {
          break;
        }
        id = node!.parent!;
      }
    }

    void detach(_Draft child) {
      if (child.parent case final int parent) {
        require(parent).slots[child.parentSlot]?.remove(child.id);
        touch(parent);
      }
      child.parent = null;
      child.parentSlot = null;
    }

    for (final operation in batch.ops) {
      switch (operation) {
        case fjs.UiOp_Create(:final id, :final component):
          final value = _id(id);
          if (value <= lastId || count >= 2000) {
            throw const FormatException(
              'Node ID reused or UI node budget exceeded',
            );
          }
          _definition(component);
          lastId = value;
          count++;
          staged[value] = _Draft(
            PluginUiNode(
              id: value,
              component: component,
              props: _defaults(component),
            ),
          );
          touch(value);
        case fjs.UiOp_Set(
          :final id,
          :final props,
          :final unset,
          :final editRevision,
        ):
          final node = require(_id(id));
          final fields = _fields(node.component);
          final values = props.map((k, v) => MapEntry(k, decodeUiValue(v)));
          for (final key in {...values.keys, ...unset}) {
            if (!fields.containsKey(key)) {
              throw FormatException('Unknown ${node.component} property $key');
            }
          }
          final revision = editRevision == null
              ? 0
              : _id(editRevision, zero: true);
          if (values.containsKey('value') &&
              ['TextField', 'SearchField'].contains(node.component)) {
            if (revision < (_edits[node.id] ?? 0)) {
              values.remove('value');
            } else {
              node.editRevision = revision;
            }
          }
          for (final key in unset) {
            final definition = fields[key] as Map;
            if (definition.containsKey('default')) {
              node.props[key] = definition['default'];
            } else {
              node.props.remove(key);
            }
          }
          node.props.addAll(values);
          touch(node.id);
          // Row/Column read child flex while laying out their own children.
          if ((values.containsKey('flex') || unset.contains('flex')) &&
              node.parent != null) {
            touch(node.parent!);
          }
        case fjs.UiOp_Insert(
          :final parent,
          :final child,
          :final slot,
          :final before,
        ):
          final target = require(_id(parent)), node = require(_id(child));
          final slots = _definition(target.component)['slots'] as Map;
          if (!slots.containsKey(slot) || node.id == 1) {
            throw const FormatException('Invalid slot or root move');
          }
          final children = target.slots.putIfAbsent(slot, () => []);
          final anchor = before == null ? null : _id(before);
          if (anchor != null && !children.contains(anchor)) {
            throw const FormatException('Insertion anchor is outside slot');
          }
          if (anchor == node.id) {
            continue;
          }
          detach(node);
          if (slots[slot] == 'one' && children.isNotEmpty) {
            throw const FormatException('Slot accepts only one child');
          }
          children.insert(
            anchor == null ? children.length : children.indexOf(anchor),
            node.id,
          );
          node.parent = target.id;
          node.parentSlot = slot;
          attached.add(node.id);
          touch(target.id);
          touch(node.id);
        case fjs.UiOp_Remove(:final parent, :final child, :final slot):
          final target = require(_id(parent)), node = require(_id(child));
          if (node.parent != target.id || node.parentSlot != slot) {
            throw const FormatException('Removal parent does not own child');
          }
          detach(node);
          touch(node.id);
        case fjs.UiOp_Listen(:final id, :final event, :final handler):
          final node = require(_id(id));
          if (!(_definition(node.component)['events'] as Map).containsKey(
            event,
          )) {
            throw FormatException('Unknown ${node.component} event $event');
          }
          if (handler == null) {
            node.handlers.remove(event);
          } else {
            node.handlers[event] = _id(handler);
          }
          touch(node.id);
        case fjs.UiOp_Release(:final id):
          final node = require(_id(id));
          if (node.id == 1 ||
              node.parent != null ||
              node.slots.values.any((nodes) => nodes.isNotEmpty)) {
            throw const FormatException('Only detached leaves may be released');
          }
          staged[node.id] = null;
          count--;
          changed.add(node.id);
      }
    }
    for (final node in staged.values) {
      if (node != null && changed.contains(node.id)) {
        _validateProps(node);
      }
    }
    // Structure only changes below inserted nodes, so only their ancestry
    // and subtrees need cycle, depth and virtualization checks.
    void subtree(int id, int depth, bool insideList) {
      final node = read(id)!;
      if (depth > 32) {
        throw const FormatException('UI cycle or excessive nesting');
      }
      if (insideList && _editable.contains(node.component)) {
        throw const FormatException('Editable fields cannot be virtualized');
      }
      for (final child in node.children) {
        subtree(child, depth + 1, insideList || node.component == 'List');
      }
    }

    for (final id in attached) {
      final node = read(id);
      if (node?.parent == null) {
        continue;
      }
      final ancestors = <int>{id};
      var insideList = false;
      for (int? parent = node!.parent; parent != null;) {
        if (!ancestors.add(parent) || ancestors.length > 32) {
          throw const FormatException('UI cycle or excessive nesting');
        }
        final ancestor =
            read(parent) ?? (throw FormatException('Unknown UI node $parent'));
        insideList |= ancestor.component == 'List';
        parent = ancestor.parent;
      }
      subtree(id, ancestors.length, insideList);
    }
    for (final MapEntry(:key, :value) in staged.entries) {
      if (value == null) {
        _nodes.remove(key);
      } else if (changed.contains(key)) {
        _nodes[key] = value.freeze();
      }
    }
    sequence = seq;
    _lastId = lastId;
    for (final id in changed) {
      if (!_nodes.containsKey(id)) {
        final notifier = _listeners.remove(id);
        notifier?.value = null;
        notifier?.dispose();
        _edits.remove(id);
      } else {
        _listeners[id]?.value = _nodes[id];
      }
    }
    return true;
  }

  void _validateProps(_Draft node) {
    for (final entry in _fields(node.component).entries) {
      final definition = entry.value as Map;
      if (!node.props.containsKey(entry.key)) {
        if (definition['required'] == true) {
          throw FormatException('Missing ${node.component}.${entry.key}');
        }
        continue;
      }
      final value = node.props[entry.key];
      final valid = switch (definition['type']) {
        'string' => value is String,
        'boolean' => value is bool,
        'nullableString' => value == null || value is String,
        'nonnegative' => value is num && value.isFinite && value >= 0,
        'positive' => value is num && value.isFinite && value > 0,
        'integer' =>
          value is num &&
              value.isFinite &&
              value >= 0 &&
              value == value.roundToDouble(),
        'positiveInteger' =>
          value is num &&
              value.isFinite &&
              value > 0 &&
              value == value.roundToDouble(),
        'selectOptions' => _options(value, 'value', {
          'value',
          'label',
          'disabled',
        }),
        'tabs' => _options(value, 'id', {'id', 'label'}),
        'menuItems' => _options(value, 'id', {
          'id',
          'label',
          'disabled',
          'danger',
        }),
        _ => false,
      };
      if (!valid ||
          definition['enum'] is List &&
              !(definition['enum'] as List).contains(value)) {
        throw FormatException('Invalid ${node.component}.${entry.key}');
      }
    }
    for (final key in ['icon', if (node.component == 'Icon') 'name']) {
      if (node.props[key] case final String icon) {
        if (!iconNames.contains(icon)) {
          throw FormatException('Unknown icon $icon');
        }
      }
    }
    for (final dimension in ['Width', 'Height']) {
      final min = node.props['min$dimension'],
          max = node.props['max$dimension'];
      if (min is num && max is num && min > max) {
        throw const FormatException('Minimum size exceeds maximum');
      }
    }
  }

  static bool _options(Object? value, String identity, Set<String> keys) {
    if (value is! List) {
      return false;
    }
    final seen = <String>{};
    for (final item in value) {
      if (item is! Map ||
          item.keys.any((k) => !keys.contains(k)) ||
          item[identity] is! String ||
          item['label'] is! String ||
          !seen.add(item[identity] as String)) {
        return false;
      }
      for (final key in ['disabled', 'danger']) {
        if (item.containsKey(key) && item[key] is! bool) {
          return false;
        }
      }
    }
    return true;
  }

  static const _editable = {
    'TextField',
    'SearchField',
    'Select',
    'Checkbox',
    'Switch',
  };
  static Map<String, dynamic> _definition(String component) =>
      (pluginUiSchema['components'] as Map)[component]
          as Map<String, dynamic>? ??
      (throw FormatException('Unknown component $component'));
  static Map<String, dynamic> _fields(String component) => {
    ...Map<String, dynamic>.from(pluginUiSchema['common'] as Map),
    ...Map<String, dynamic>.from(_definition(component)['props'] as Map),
  };
  static Map<String, Object?> _defaults(String component) => {
    for (final entry in _fields(component).entries)
      if ((entry.value as Map).containsKey('default'))
        entry.key: (entry.value as Map)['default'],
  };
  static int _id(BigInt value, {bool zero = false}) {
    if (value < BigInt.from(zero ? 0 : 1) ||
        value > BigInt.from(9007199254740991)) {
      throw const FormatException('Invalid UI identifier');
    }
    return value.toInt();
  }

  void dispose() {
    _disposed = true;
    for (final notifier in _listeners.values) {
      notifier.dispose();
    }
    _listeners.clear();
    _removed.dispose();
    _nodes.clear();
    _edits.clear();
  }
}

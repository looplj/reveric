// 职责: 保持插件文本节点的 controller、焦点和 IME，并为输入事件分配递增编辑序号。
// 关联文件:
//   lib/shared/models/plugin/ui_tree.dart
//   lib/shared/components/reveric_text_field.dart
//   lib/shared/components/reveric_search_field.dart
//   lib/shared/utils/text_input_composing.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/search-debounce.md
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../models/plugin/ui_tree.dart';
import '../../components/reveric_text_field.dart';
import '../../components/reveric_search_field.dart';
import '../../utils/text_input_composing.dart';
import '../../theme/theme.dart';

typedef PluginUiEventCallback =
    void Function(
      PluginUiNode node,
      String event,
      Map<String, Object?> payload,
    );

class PluginUiInput extends HookWidget {
  const PluginUiInput({
    super.key,
    required this.tree,
    required this.node,
    required this.onEvent,
  });
  final PluginUiTree tree;
  final PluginUiNode node;
  final PluginUiEventCallback onEvent;
  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(
      text: node.props['value'] as String,
    );
    final focus = useFocusNode();
    final latest = useRef(node);
    latest.value = node;
    final syncing = useRef(false);
    final previous = useRef(controller.text);
    final wasComposing = useRef(false);
    final deferred = useRef(false);
    final timer = useRef<Timer?>(null);
    final callback = useRef(onEvent);
    callback.value = onEvent;
    void send(String event) {
      if (!context.mounted) {
        return;
      }
      callback.value(latest.value, event, {
        'value': controller.text,
        'editRevision': tree.editRevision(node.id),
      });
    }

    bool syncFromHost() {
      final value = latest.value.props['value'] as String;
      deferred.value = isTextInputComposing(controller);
      if (deferred.value ||
          latest.value.editRevision < tree.editRevision(node.id) ||
          controller.text == value) {
        return false;
      }
      timer.value?.cancel();
      syncing.value = true;
      controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      previous.value = value;
      syncing.value = false;
      return true;
    }

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          syncFromHost();
        }
      });
      return null;
    }, [node.props['value'], node.editRevision]);
    useOnListenableChange(controller, () {
      if (syncing.value) {
        return;
      }
      final changed = controller.text != previous.value;
      if (changed) {
        // Without onChange the plugin never echoes edits, so counting them
        // would make every later host value look stale.
        if (latest.value.handlers.containsKey('onChange')) {
          tree.recordEdit(node.id);
        }
        previous.value = controller.text;
      }
      final composing = isTextInputComposing(controller);
      final committed = wasComposing.value && !composing;
      wasComposing.value = composing;
      if (composing) {
        timer.value?.cancel();
        return;
      }
      // A deferred echo may have become stale during further composition.
      // Only consume the commit when the host actually replaces the text.
      if (committed && !changed && deferred.value && syncFromHost()) {
        return;
      }
      if (!changed && !committed) {
        return;
      }
      timer.value?.cancel();
      final delay = node.component == 'SearchField'
          ? (latest.value.props['debounceMs'] as num).toInt()
          : 0;
      if (delay == 0 || controller.text.isEmpty) {
        send('onChange');
      } else {
        timer.value = Timer(
          Duration(milliseconds: delay),
          () => send('onChange'),
        );
      }
    });
    useEffect(
      () =>
          () => timer.value?.cancel(),
      const [],
    );
    void submit(String _) {
      if (timer.value?.isActive ?? false) {
        timer.value!.cancel();
        send('onChange');
      }
      send('onSubmit');
    }

    final props = node.props;
    if (node.component == 'SearchField') {
      final typo = RevericTheme.typographyOf(context),
          colors = RevericTheme.colorsOf(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (props['label'] case final String label) ...[
            Text(
              label,
              style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: RevericSpacing.xs),
          ],
          RevericSearchField(
            controller: controller,
            focusNode: focus,
            enabled: props['disabled'] != true,
            hint: props['placeholder'] as String? ?? '',
            onSubmitted: submit,
          ),
          if (props['error'] case final String error)
            Text(
              error,
              style: typo.uiSmall.copyWith(color: colors.warningText),
            ),
        ],
      );
    }
    return RevericTextField(
      controller: controller,
      focusNode: focus,
      label: props['label'] as String?,
      hintText: props['placeholder'] as String?,
      errorText: props['error'] as String?,
      enabled: props['disabled'] != true,
      multiline: props['multiline'] == true,
      onSubmitted: submit,
    );
  }
}

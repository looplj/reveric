// 职责: A2UI ComboField — 可编辑文本框加建议菜单，选中写入选项值，清单外的文本也可以保存。
// 关联文件:
//   lib/shared/widgets/a2ui/catalog.dart
//   lib/shared/widgets/a2ui/components/text_field.dart
//   lib/shared/widgets/a2ui/components/write_back.dart
//   lib/shared/components/reveric_text_field.dart
//   lib/shared/components/reveric_select.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/performance.md

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../components/reveric_text_field.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../theme/theme.dart';
import '../../../utils/text_input_composing.dart';
import '../component.dart';
import 'field_frame.dart';
import 'write_back.dart';

typedef _Suggestion = ({String value, String label});

Widget buildComboField(
  BuildContext context,
  A2uiNode node,
  A2uiProps props,
  A2uiChildBuilder buildChild,
) {
  return _A2uiComboField(
    label: props.string('label'),
    placeholder: props.string('placeholder'),
    value: props.string('value') ?? '',
    suggestions: [
      for (final item in props.list('options'))
        if (item case final Map<Object?, Object?> option)
          if (option['value'] case final String value)
            (value: value, label: A2uiProps.asString(option['label']) ?? value),
    ],
    error: a2uiCheckMessage(context, props.validationErrors.firstOrNull),
    write: a2uiWriterFor(context, props, 'value'),
  );
}

class _A2uiComboField extends HookWidget {
  const _A2uiComboField({
    required this.label,
    required this.placeholder,
    required this.value,
    required this.suggestions,
    required this.error,
    required this.write,
  });

  final String? label;
  final String? placeholder;
  final String value;
  final List<_Suggestion> suggestions;
  final String? error;
  final bool Function(Object? value)? write;

  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(text: value);
    final portal = useMemoized(OverlayPortalController.new);
    final open = useState(false);
    final filterActive = useMemoized(() => ValueNotifier(false));
    useEffect(() => filterActive.dispose, [filterActive]);
    final touched = useState(false);
    final latestValue = useRef(value);
    final latestWrite = useRef(write);
    latestValue.value = value;
    latestWrite.value = write;

    useEffect(() {
      if (controller.text != value && !isTextInputComposing(controller)) {
        controller.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
      }
      return null;
    }, [value]);

    useOnListenableChange(controller, () {
      if (isTextInputComposing(controller) ||
          controller.text == latestValue.value) {
        return;
      }
      final writer = latestWrite.value;
      if (writer == null) {
        return;
      }
      if (!touched.value) {
        touched.value = true;
      }
      if (open.value && !filterActive.value) {
        filterActive.value = true;
      }
      writer(controller.text);
    });

    void setOpen(bool next) {
      if (open.value == next) {
        return;
      }
      if (next) {
        filterActive.value = false;
      }
      open.value = next;
      if (next) {
        portal.show();
      } else if (portal.isShowing) {
        portal.hide();
      }
    }

    final colors = RevericTheme.colorsOf(context);
    final shownError = touched.value ? error : null;
    final chooseLabel = context.t(LocaleKeys.commonChoose);
    final noResultsLabel = context.t(LocaleKeys.commonNoResults);
    final enabled = write != null;

    return OverlayPortal.overlayChildLayoutBuilder(
      controller: portal,
      overlayChildBuilder: (context, info) => CustomSingleChildLayout(
        delegate: _ComboMenuLayout(
          MatrixUtils.transformRect(
            info.childPaintTransform,
            Offset.zero & info.childSize,
          ),
        ),
        child: TapRegion(
          groupId: portal,
          child: ValueListenableBuilder<bool>(
            valueListenable: filterActive,
            builder: (context, filtering, _) =>
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, editingValue, _) => _ComboMenu(
                    width: info.childSize.width,
                    suggestions: suggestions,
                    text: editingValue.text,
                    filtering: filtering,
                    noResultsLabel: noResultsLabel,
                    onPick: (suggestion) {
                      final writer = latestWrite.value;
                      controller.value = TextEditingValue(
                        text: suggestion,
                        selection: TextSelection.collapsed(
                          offset: suggestion.length,
                        ),
                      );
                      touched.value = true;
                      writer?.call(suggestion);
                      setOpen(false);
                    },
                  ),
                ),
          ),
        ),
      ),
      child: TapRegion(
        groupId: portal,
        onTapOutside: (_) => setOpen(false),
        child: RevericTextField(
          controller: controller,
          label: label == null || label!.isEmpty ? null : label,
          hintText: placeholder == null || placeholder!.isEmpty
              ? null
              : placeholder,
          errorText: shownError,
          enabled: enabled,
          suffixIcon: Tooltip(
            message: chooseLabel,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: enabled ? () => setOpen(!open.value) : null,
                  borderRadius: BorderRadius.circular(RevericRadius.medium),
                  hoverColor: colors.hover,
                  child: Center(
                    child: AnimatedRotation(
                      turns: open.value ? 0.5 : 0,
                      duration: const Duration(milliseconds: 140),
                      child: RevericIcon(
                        RevericIcons.expand_more,
                        size: 13,
                        color: open.value ? colors.accent : colors.textSubtle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 必须给 Center 包一层才能让 Icon 按 size: 13 渲染；直接把 Tight 约束
          // 传给 RevericIcon 会把 SVG 撑满 36×36。
          suffixIconConstraints: const BoxConstraints.tightFor(
            width: RevericSizes.fieldHeight,
            height: RevericSizes.fieldHeight,
          ),
        ),
      ),
    );
  }
}

List<_Suggestion> _visibleSuggestions(
  List<_Suggestion> suggestions,
  String text, {
  required bool filtering,
}) {
  if (!filtering) {
    return suggestions;
  }
  final query = text.trim().toLowerCase();
  if (query.isEmpty) {
    return suggestions;
  }
  return [
    for (final item in suggestions)
      if (item.label.toLowerCase().contains(query) ||
          item.value.toLowerCase().contains(query))
        item,
  ];
}

class _ComboMenuLayout extends SingleChildLayoutDelegate {
  const _ComboMenuLayout(this.anchor);

  final Rect anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final spaceBelow = size.height - anchor.bottom - RevericSpacing.xs;
    final spaceAbove = anchor.top - RevericSpacing.xs;
    final dropUp = childSize.height > spaceBelow && spaceAbove > spaceBelow;
    final rawY = dropUp
        ? anchor.top - RevericSpacing.xs - childSize.height
        : anchor.bottom + RevericSpacing.xs;
    final maxX = math.max(0.0, size.width - childSize.width);
    final maxY = math.max(0.0, size.height - childSize.height);
    return Offset(anchor.left.clamp(0.0, maxX), rawY.clamp(0.0, maxY));
  }

  @override
  bool shouldRelayout(_ComboMenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor;
}

class _ComboMenu extends StatefulWidget {
  const _ComboMenu({
    required this.width,
    required this.suggestions,
    required this.text,
    required this.filtering,
    required this.noResultsLabel,
    required this.onPick,
  });

  final double width;
  final List<_Suggestion> suggestions;
  final String text;
  final bool filtering;
  final String noResultsLabel;
  final ValueChanged<String> onPick;

  @override
  State<_ComboMenu> createState() => _ComboMenuState();
}

class _ComboMenuState extends State<_ComboMenu> {
  int? _hoveredIndex;
  final GlobalKey _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final selectedContext = _selectedKey.currentContext;
      if (selectedContext == null) {
        return;
      }
      Scrollable.ensureVisible(
        selectedContext,
        alignment: 0.5,
        duration: Duration.zero,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final visible = _visibleSuggestions(
      widget.suggestions,
      widget.text,
      filtering: widget.filtering,
    );
    return Material(
      type: MaterialType.transparency,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        builder: (context, t, child) {
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 4),
              child: child,
            ),
          );
        },
        child: Container(
          width: widget.width,
          constraints: const BoxConstraints(maxHeight: 288),
          padding: const EdgeInsets.all(RevericSpacing.xs),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(RevericRadius.large),
            border: Border.all(color: colors.border),
            boxShadow: [
              BoxShadow(
                color: colors.textPrimary.withValues(alpha: 0.16),
                blurRadius: 40,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: visible.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: RevericSpacing.md,
                  ),
                  child: Center(
                    child: Text(
                      widget.noResultsLabel,
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  ),
                )
              : ListView(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  clipBehavior: Clip.antiAlias,
                  children: [
                    for (final (index, suggestion) in visible.indexed)
                      Padding(
                        key: suggestion.value == widget.text
                            ? _selectedKey
                            : null,
                        padding: EdgeInsets.only(
                          bottom: index == visible.length - 1
                              ? 0
                              : RevericSpacing.xxs,
                        ),
                        child: _ComboOption(
                          suggestion: suggestion,
                          selected: suggestion.value == widget.text,
                          hovered: _hoveredIndex == index,
                          colors: colors,
                          typo: typo,
                          onHoverChanged: (hovering) {
                            setState(() {
                              if (hovering) {
                                _hoveredIndex = index;
                              } else if (_hoveredIndex == index) {
                                _hoveredIndex = null;
                              }
                            });
                          },
                          onPick: () => widget.onPick(suggestion.value),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _ComboOption extends StatelessWidget {
  const _ComboOption({
    required this.suggestion,
    required this.selected,
    required this.hovered,
    required this.colors,
    required this.typo,
    required this.onHoverChanged,
    required this.onPick,
  });

  final _Suggestion suggestion;
  final bool selected;
  final bool hovered;
  final RevericColors colors;
  final RevericTypography typo;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final subtitle = suggestion.label == suggestion.value
        ? null
        : suggestion.value;
    final background = selected
        ? colors.selected
        : hovered
        ? colors.hover
        : colors.surface.withValues(alpha: 0);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPick,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.sm,
            vertical: RevericSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(RevericRadius.medium),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      suggestion.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmallSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: RevericSpacing.sm),
                RevericIcon(
                  RevericIcons.check_circle,
                  size: 15,
                  color: colors.accent,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// 职责: 统一的 AI 模型选择器 — compact（chat composer）与 field（表单）两种形态共用同一下拉菜单。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/components/reveric_search_field.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   lib/desktop/widgets/ai/chat/composer.dart
//   lib/desktop/widgets/agent_management/subagent_edit_panel.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/icons.md
//   .agents/rules/design-system.md
//   .agents/rules/search-debounce.md
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../shared/components/reveric_search_field.dart';
import '../../../../shared/models/ai_provider.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/widgets/ai/reasoning_effort_bars.dart';
import '../../../../shared/widgets/ai/provider_model_icon.dart';
import '../../agent_management/ai_providers_page.dart';

/// 模型选择回调类型
typedef SelectModelCallback = void Function(AiModelOption option);

/// 模型 + effort 选择回调（用于推理模型的 effort 子菜单）
typedef SelectModelWithEffortCallback =
    void Function(AiModelOption option, String effort);

enum _ModelSelectorVariant { compact, field }

/// 菜单高度估算 — 与 [_ModelMenuContent] 布局保持一致，供定位时限高 / 翻转。
double _estimateModelMenuHeight({
  required int modelCount,
  required bool hasUnset,
  required bool showAddModel,
}) {
  const maxVisibleItems = 8;
  const itemHeight = 56.0;
  const footerHeight = 45.0;

  // ListView 上下 padding（RevericSpacing.xs）。
  const listPadding = RevericSpacing.xs * 2;
  final rowCount = modelCount + (hasUnset ? 1 : 0);
  final listHeight = rowCount > maxVisibleItems
      ? maxVisibleItems * itemHeight
      : rowCount * itemHeight;
  return _modelMenuSearchHeight +
      listHeight +
      listPadding +
      (showAddModel ? footerHeight : 0);
}

/// 菜单顶部搜索框占用的高度（含上方留白）。
const _modelMenuSearchHeight = RevericSizes.fieldHeightSm + RevericSpacing.sm;

/// 统一模型选择器。
///
/// - [ModelSelector.compact]：chat composer 用的紧凑触发器（模型名 + 箭头），
///   下拉菜单向上弹出；回调返回选中的 [AiModelOption]。
/// - [ModelSelector.field]：表单用的整宽边框触发器（provider 图标 + 模型名 +
///   provider 名），下拉菜单向下弹出；回调返回选中项 id（`null` 表示未设置）。
///
/// 两种形态共用同一套下拉菜单 [_ModelMenuContent]（provider 图标 / 模型名 /
/// provider 显示名 / 选中态对勾 / 可选「未设置」项 / 可选「添加模型」页脚）。
/// 模型行 / 触发器上展示的 effort：选中项优先用会话值，否则回落到模型默认档位。
String? _displayEffortFor({
  required AiModelOption option,
  required bool selected,
  required String? selectedEffort,
}) {
  if (option.reasoningEfforts == null || option.reasoningEfforts!.isEmpty) {
    return null;
  }
  if (selected && selectedEffort != null) {
    return selectedEffort;
  }
  return defaultEffortFor(option);
}

class ModelSelector extends StatefulWidget {
  /// 紧凑形态（chat composer）。
  const ModelSelector.compact({
    super.key,
    required this.modelName,
    required this.resolvedId,
    required this.availableModels,
    required this._onSelect,
    this.colors,
    this.typo,
    this.disabledModelIds = const {},

    this.autoOpenTrigger,
    this.onMenuVisibilityChanged,
    this.selectedEffort,
    this.compactMaxWidth,
    this._onSelectWithEffort,
    this.showAddModel = true,
  }) : _variant = _ModelSelectorVariant.compact,
       _onChanged = null,
       selectedId = resolvedId,
       unsetLabel = null,
       placeholder = null,
       emptyMessage = null,
       enabled = true,
       dense = false;

  /// 字段形态（表单）。[onChanged] 收到 `null` 表示选择了「未设置」项。
  ///
  /// 传入 [onSelectWithEffort] 时，推理模型行会挂上 effort 子菜单，闭合态触发器
  /// 也展示当前 [selectedEffort] 药丸（与 compact 形态一致）。
  const ModelSelector.field({
    super.key,
    required this.availableModels,
    required this.selectedId,
    required this._onChanged,
    this.unsetLabel,
    this.placeholder,
    this.emptyMessage,
    this.enabled = true,
    this.dense = false,
    this.disabledModelIds = const {},

    this.showAddModel = false,
    this.selectedEffort,
    this._onSelectWithEffort,
  }) : _variant = _ModelSelectorVariant.field,
       _onSelect = null,
       colors = null,
       typo = null,
       modelName = '',
       compactMaxWidth = null,
       resolvedId = selectedId ?? '',
       autoOpenTrigger = null,
       onMenuVisibilityChanged = null;

  final _ModelSelectorVariant _variant;

  /// compact 形态由调用方传入主题色（composer 中已就近持有）；field 形态从
  /// context 解析。
  final RevericColors? colors;
  final RevericTypography? typo;

  /// compact 形态：闭合态显示的模型名。
  final String modelName;

  /// compact 形态：触发器可使用的最大宽度；为空时保持内容本征宽度。
  final double? compactMaxWidth;

  /// compact 形态：当前模型 resolved id。
  final String resolvedId;

  /// compact 形态：当前选中模型的 reasoning effort（推理模型才有）。
  final String? selectedEffort;

  /// field 形态：当前选中 option id（`null` 表示未设置）。
  final String? selectedId;

  /// 候选模型列表（由调用方按需过滤）。
  final List<AiModelOption> availableModels;

  /// 当前不可选择的模型 id。
  final Set<String> disabledModelIds;

  /// field 形态：非空时菜单首项为「未设置」项，且未选中时闭合态显示此文案。
  final String? unsetLabel;

  /// field 形态：未选中且无 [unsetLabel] 时的斜体占位文案。
  final String? placeholder;

  /// field 形态：候选为空且非空时显示的提示文案。
  final String? emptyMessage;

  /// field 形态：是否允许编辑。`false` 时禁用并隐藏展开箭头。
  final bool enabled;

  /// field 形态：紧凑布局（更小内边距）。
  final bool dense;

  /// 是否在菜单底部显示「添加模型」页脚（点击打开设置）。
  final bool showAddModel;

  /// compact 形态：外部增量触发自动打开菜单。
  final ValueNotifier<int>? autoOpenTrigger;

  /// compact 形态：菜单打开/关闭回调。
  final ValueChanged<bool>? onMenuVisibilityChanged;

  final SelectModelCallback? _onSelect;
  final SelectModelWithEffortCallback? _onSelectWithEffort;
  final ValueChanged<String?>? _onChanged;

  /// 把选择结果分发到对应形态的回调。`null` 表示「未设置」（仅 field 形态）。
  void _emit(AiModelOption? option) {
    if (_variant == _ModelSelectorVariant.compact) {
      if (option != null) {
        _onSelect!(option);
      }
    } else {
      _onChanged!(option?.id);
    }
  }

  @override
  State<ModelSelector> createState() => _ModelSelectorState();
}

class _ModelSelectorState extends State<ModelSelector> {
  OverlayEntry? _menuEntry;
  bool _openedByAuto = false;
  double? _menuPanelLeft;
  double? _menuPanelRight;

  bool get _isCompact => widget._variant == _ModelSelectorVariant.compact;

  @override
  void initState() {
    super.initState();
    widget.autoOpenTrigger?.addListener(_onAutoOpenTrigger);
  }

  @override
  void didUpdateWidget(covariant ModelSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.autoOpenTrigger != widget.autoOpenTrigger) {
      oldWidget.autoOpenTrigger?.removeListener(_onAutoOpenTrigger);
      widget.autoOpenTrigger?.addListener(_onAutoOpenTrigger);
    }
  }

  @override
  void dispose() {
    widget.autoOpenTrigger?.removeListener(_onAutoOpenTrigger);
    _hideMenu(notify: false);
    super.dispose();
  }

  void _onAutoOpenTrigger() {
    if (_menuEntry != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _menuEntry != null) {
        return;
      }
      _showMenu(openedByAuto: true);
    });
  }

  RevericColors _colorsOf(BuildContext context) =>
      widget.colors ?? RevericTheme.colorsOf(context);
  RevericTypography _typoOf(BuildContext context) =>
      widget.typo ?? RevericTheme.typographyOf(context);

  @override
  Widget build(BuildContext context) {
    final colors = _colorsOf(context);
    final typo = _typoOf(context);

    if (_isCompact) {
      return _buildCompactTrigger(context, colors, typo);
    }
    return _buildFieldTrigger(context, colors, typo);
  }

  /// 触发器上的 effort 药丸 — 纯展示当前档位，切换在模型菜单的
  /// effort flyout 中进行；无推理档位或缺少回调时返回 null。compact 与
  /// field 形态共用。
  Widget? _currentEffortPill({required RevericColors colors}) {
    if (widget._onSelectWithEffort == null) {
      return null;
    }
    final currentOption = widget.availableModels
        .where((opt) => opt.id == widget.resolvedId)
        .firstOrNull;
    final effort = currentOption == null
        ? null
        : _displayEffortFor(
            option: currentOption,
            selected: true,
            selectedEffort: widget.selectedEffort,
          );
    if (effort == null) {
      return null;
    }
    return _EffortPill(effort: effort, colors: colors);
  }

  // ---- compact trigger（chat composer）----------------------------------
  Widget _buildCompactTrigger(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
  ) {
    final modelName = Text(
      widget.modelName,
      style: typo.uiSmall.copyWith(color: colors.textPrimary),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    // 与制片输入栏的参数下拉同一套触发器：前置模型图标 + 模型名 + 小箭头。
    final trigger = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RevericIcon(RevericIcons.auto_awesome, size: 15, color: colors.accent),
        const SizedBox(width: RevericSpacing.sm),
        if (widget.compactMaxWidth == null)
          modelName
        else
          Flexible(child: modelName),
        if (_currentEffortPill(colors: colors) case final effortPill?) ...[
          const SizedBox(width: 4),
          effortPill,
        ],
        const SizedBox(width: RevericSpacing.xxs),
        RevericIcon(
          RevericIcons.expand_more,
          size: 11,
          color: colors.textSubtle,
        ),
      ],
    );
    return TapRegion(
      groupId: this,
      child: GestureDetector(
        onTap: _toggleMenu,
        child: widget.compactMaxWidth == null
            ? trigger
            : ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.compactMaxWidth!),
                child: trigger,
              ),
      ),
    );
  }

  // ---- field trigger（表单）---------------------------------------------
  Widget _buildFieldTrigger(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
  ) {
    // 与 RevericSelect 触发器保持一致的固定高度（默认 36 / dense 32），
    // 避免在表单里与 RevericSelect 并排时高度不一致。
    final triggerHeight = widget.dense
        ? RevericSizes.fieldHeightSm
        : RevericSizes.fieldHeight;

    if (widget.availableModels.isEmpty && widget.emptyMessage != null) {
      return Container(
        constraints: BoxConstraints(minHeight: triggerHeight),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.lg),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(RevericRadius.large),
          border: Border.all(color: colors.borderInput),
        ),
        child: Text(
          widget.emptyMessage!,
          style: typo.ui.copyWith(color: colors.textMuted),
        ),
      );
    }

    final selectedOption = widget.selectedId == null
        ? null
        : widget.availableModels
              .where((opt) => opt.id == widget.selectedId)
              .firstOrNull;

    return TapRegion(
      groupId: this,
      child: GestureDetector(
        onTap: widget.enabled ? _toggleMenu : null,
        child: Container(
          height: triggerHeight,
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(RevericRadius.large),
            border: Border.all(color: colors.borderInput),
          ),
          padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.lg),
          child: Row(
            children: [
              Expanded(
                child: selectedOption != null
                    ? Row(
                        children: [
                          RevericIcon(
                            providerModelIcon(selectedOption.providerId),
                            size: 16,
                            color: widget.enabled
                                ? colors.textSecondary
                                : colors.textMuted,
                          ),
                          const SizedBox(width: RevericSpacing.sm),
                          Flexible(
                            child: Text(
                              selectedOption.displayModelName,
                              overflow: TextOverflow.ellipsis,
                              style: typo.ui.copyWith(
                                color: widget.enabled
                                    ? colors.textPrimary
                                    : colors.textMuted,
                              ),
                            ),
                          ),
                          const SizedBox(width: RevericSpacing.sm),
                          Flexible(
                            child: Text(
                              selectedOption.providerDisplayName,
                              overflow: TextOverflow.ellipsis,
                              style: typo.uiSmall.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
                          ),
                        ],
                      )
                    : Text(
                        widget.unsetLabel ?? widget.placeholder ?? '',
                        style: typo.ui.copyWith(
                          color: colors.textSubtle,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
              ),
              if (_currentEffortPill(colors: colors)
                  case final effortPill?) ...[
                const SizedBox(width: RevericSpacing.sm),
                effortPill,
              ],
              if (widget.enabled) ...[
                const SizedBox(width: RevericSpacing.sm),
                RevericIcon(
                  RevericIcons.expand_more,
                  size: 18,
                  color: colors.textMuted,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---- overlay menu ------------------------------------------------------
  void _toggleMenu() {
    if (_menuEntry == null) {
      _showMenu();
    } else {
      _hideMenu();
    }
  }

  void _showMenu({bool openedByAuto = false}) {
    if (_menuEntry != null) {
      return;
    }
    final renderBox = context.findRenderObject() as RenderBox?;
    final overlayState = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    if (renderBox == null || overlayBox == null) {
      return;
    }

    final colors = _colorsOf(context);
    final typo = _typoOf(context);
    final btnPos = renderBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final btnRight = btnPos.dx + renderBox.size.width;
    final btnBottom = btnPos.dy + renderBox.size.height;
    _openedByAuto = openedByAuto;

    final compactMenuWidth = 320.0;
    if (_isCompact) {
      _menuPanelLeft = btnRight - compactMenuWidth;
      _menuPanelRight = btnRight;
    }

    final desiredMenuHeight = _estimateModelMenuHeight(
      modelCount: widget.availableModels.length,
      hasUnset: widget.unsetLabel != null,
      showAddModel: widget.showAddModel,
    );

    _ModelMenuContent buildMenuContent({
      required double menuWidth,
      required double panelLeft,
      required double panelRight,
      double? maxHeight,
    }) {
      return _ModelMenuContent(
        colors: colors,
        typo: typo,
        resolvedId: widget.resolvedId,
        availableModels: widget.availableModels,
        disabledModelIds: widget.disabledModelIds,

        unsetLabel: widget.unsetLabel,
        showAddModel: widget.showAddModel,
        selectedEffort: widget.selectedEffort,
        maxHeight: maxHeight,
        modelMenuPanelLeft: panelLeft,
        modelMenuPanelRight: panelRight,
        hostMenuEntry: _menuEntry,
        tapRegionGroupId: this,
        // 自动弹出时输入焦点还在聊天输入框，不抢。
        autofocusSearch: !_openedByAuto,
        onSelect: (option) {
          _hideMenu();
          widget._emit(option);
        },
        onSelectWithEffort: widget._onSelectWithEffort == null
            ? null
            : (option, effort) {
                _hideMenu();
                widget._onSelectWithEffort!(option, effort);
              },

        onAddModel: () {
          _hideMenu();
          showAiProviderSettingsDialog(context);
        },
      );
    }

    _menuEntry = OverlayEntry(
      builder: (menuContext) {
        // compact：向上弹出、右对齐、固定宽度 320；空间不足时限高避免溢出裁切。
        // field：优先向下，下方不够则向上；宽度跟随触发器（不窄于 280）。
        if (_isCompact) {
          final menuWidth = compactMenuWidth;
          final panelLeft = _menuPanelLeft!;
          final panelRight = _menuPanelRight!;
          final gap = RevericSpacing.xs;
          final margin = RevericSpacing.sm;
          final spaceAbove = math.max(0.0, btnPos.dy - gap - margin);
          final maxHeight = math.min(desiredMenuHeight, spaceAbove);
          return Positioned(
            left: panelLeft,
            width: menuWidth,
            bottom: overlayBox.size.height - btnPos.dy + gap,
            child: TapRegion(
              groupId: this,
              consumeOutsideTaps: !_openedByAuto,
              onTapOutside: (_) => _hideMenu(),
              child: buildMenuContent(
                menuWidth: menuWidth,
                panelLeft: panelLeft,
                panelRight: panelRight,
                maxHeight: maxHeight,
              ),
            ),
          );
        }
        final menuWidth = renderBox.size.width < 280.0
            ? 280.0
            : renderBox.size.width;
        final panelLeft = btnPos.dx;
        final panelRight = btnPos.dx + menuWidth;
        _menuPanelLeft = panelLeft;
        _menuPanelRight = panelRight;
        final gap = RevericSpacing.xs;
        final margin = RevericSpacing.sm;
        final spaceBelow = math.max(
          0.0,
          overlayBox.size.height - btnBottom - gap - margin,
        );
        final spaceAbove = math.max(0.0, btnPos.dy - gap - margin);
        // 下方能放下，或下方空间不少于上方时向下；否则向上，避免贴底裁切。
        final openDown =
            spaceBelow >= desiredMenuHeight || spaceBelow >= spaceAbove;
        final maxHeight = math.min(
          desiredMenuHeight,
          openDown ? spaceBelow : spaceAbove,
        );
        return Positioned(
          left: panelLeft,
          width: menuWidth,
          top: openDown ? btnBottom + gap : null,
          bottom: openDown ? null : overlayBox.size.height - btnPos.dy + gap,
          child: TapRegion(
            groupId: this,
            consumeOutsideTaps: true,
            onTapOutside: (_) => _hideMenu(),
            child: buildMenuContent(
              menuWidth: menuWidth,
              panelLeft: panelLeft,
              panelRight: panelRight,
              maxHeight: maxHeight,
            ),
          ),
        );
      },
    );
    overlayState.insert(_menuEntry!);
    if (mounted) {
      setState(() {});
    }
    widget.onMenuVisibilityChanged?.call(true);
  }

  void _hideMenu({bool notify = true}) {
    final entry = _menuEntry;
    if (entry == null) {
      return;
    }
    _menuEntry = null;
    _openedByAuto = false;
    _menuPanelLeft = null;
    _menuPanelRight = null;
    entry.remove();
    if (notify && mounted) {
      setState(() {});
    }
    if (notify) {
      widget.onMenuVisibilityChanged?.call(false);
    }
  }
}

class _ModelMenuContent extends StatefulWidget {
  const _ModelMenuContent({
    required this.colors,
    required this.typo,
    required this.resolvedId,
    required this.availableModels,
    required this.disabledModelIds,

    required this.onSelect,

    required this.onAddModel,
    this.unsetLabel,
    this.showAddModel = true,
    this.selectedEffort,
    this.onSelectWithEffort,
    this.maxHeight,
    this.modelMenuPanelLeft,
    this.modelMenuPanelRight,
    this.hostMenuEntry,
    this.tapRegionGroupId,
    this.autofocusSearch = true,
  });

  /// 打开菜单时是否把焦点放进搜索框。
  final bool autofocusSearch;

  final RevericColors colors;
  final RevericTypography typo;
  final String resolvedId;
  final List<AiModelOption> availableModels;
  final Set<String> disabledModelIds;
  final ValueChanged<AiModelOption?> onSelect;

  final VoidCallback onAddModel;
  final String? unsetLabel;
  final bool showAddModel;

  /// 当前选中模型的 effort（推理模型才有）。
  final String? selectedEffort;

  /// 在 effort 子菜单中选择了 effort 后的回调。
  final void Function(AiModelOption, String)? onSelectWithEffort;

  /// Overlay 可用高度上限；为空则按内容估算高度。
  final double? maxHeight;

  /// 模型菜单面板在 overlay 中的左右边界，用于 effort flyout 定位。
  final double? modelMenuPanelLeft;
  final double? modelMenuPanelRight;

  /// 宿主模型菜单 OverlayEntry，effort 子菜单插入其上方以免被遮挡。
  final OverlayEntry? hostMenuEntry;

  /// 宿主菜单的 TapRegion 分组 id，透传给 effort flyout。
  final Object? tapRegionGroupId;

  @override
  State<_ModelMenuContent> createState() => _ModelMenuContentState();
}

class _ModelMenuContentState extends State<_ModelMenuContent> {
  /// 已 debounce、trim 并转小写的搜索词。
  String _query = '';

  bool _matches(AiModelOption option) =>
      _query.isEmpty ||
      option.displayModelName.toLowerCase().contains(_query) ||
      option.model.toLowerCase().contains(_query) ||
      option.providerDisplayName.toLowerCase().contains(_query);

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final typo = widget.typo;
    final resolvedId = widget.resolvedId;
    final unsetLabel = widget.unsetLabel;
    final showAddModel = widget.showAddModel;
    final maxHeight = widget.maxHeight;
    final onSelect = widget.onSelect;
    final availableModels = widget.availableModels.where(_matches).toList();
    const itemHeight = 56.0;
    const footerHeight = 45.0;
    // 搜索时只留匹配的模型，「未设置」项不参与。
    final hasUnset = unsetLabel != null && _query.isEmpty;
    final selectedIsUnset = hasUnset && (resolvedId.isEmpty);

    // 高度按完整列表估算，搜索过滤时面板不跳动。
    final desiredHeight = _estimateModelMenuHeight(
      modelCount: widget.availableModels.length,
      hasUnset: unsetLabel != null,
      showAddModel: showAddModel,
    );
    final height = maxHeight == null
        ? desiredHeight
        : math.min(desiredHeight, maxHeight);

    return Material(
      color: colors.canvas,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      clipBehavior: Clip.antiAlias,
      elevation: 8,
      shadowColor: Colors.black54,
      child: SizedBox(
        height: height,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.sm,
                RevericSpacing.sm,
                RevericSpacing.sm,
                0,
              ),
              child: RevericDebouncedSearchField(
                hint: context.t(LocaleKeys.commonSearch),
                autofocus: widget.autofocusSearch,
                height: RevericSizes.fieldHeightSm,
                onDebouncedChanged: (query) {
                  if (mounted) {
                    setState(() => _query = query);
                  }
                },
              ),
            ),
            Expanded(
              child: ListView(
                primary: false,
                padding: const EdgeInsets.symmetric(
                  vertical: RevericSpacing.xs,
                ),
                children: [
                  if (hasUnset)
                    SizedBox(
                      height: itemHeight,
                      child: _UnsetRow(
                        colors: colors,
                        typo: typo,
                        label: unsetLabel,
                        selected: selectedIsUnset,
                        onTap: () => onSelect(null),
                      ),
                    ),
                  for (final option in availableModels)
                    SizedBox(
                      height: itemHeight,
                      child: _ModelRow(
                        colors: colors,
                        typo: typo,
                        option: option,
                        selected: option.id == resolvedId,
                        disabled: widget.disabledModelIds.contains(option.id),

                        onTap: () => onSelect(option),
                        selectedEffort: _displayEffortFor(
                          option: option,
                          selected: option.id == resolvedId,
                          selectedEffort: widget.selectedEffort,
                        ),
                        onSelectWithEffort: widget.onSelectWithEffort,
                        panelLeft: widget.modelMenuPanelLeft,
                        panelRight: widget.modelMenuPanelRight,
                        hostMenuEntry: widget.hostMenuEntry,
                        tapRegionGroupId: widget.tapRegionGroupId,
                      ),
                    ),
                ],
              ),
            ),
            if (showAddModel) ...[
              Divider(height: 1, color: colors.border),
              InkWell(
                onTap: widget.onAddModel,
                child: SizedBox(
                  height: footerHeight - 1,
                  child: Center(
                    child: Text(
                      context.t(LocaleKeys.aiAddModel),
                      style: typo.ui.copyWith(color: colors.textMuted),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UnsetRow extends StatelessWidget {
  const _UnsetRow({
    required this.colors,
    required this.typo,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.lg),
        child: Row(
          children: [
            RevericIcon(
              RevericIcons.block_rounded,
              size: 18,
              color: selected ? colors.accent : colors.textSecondary,
            ),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Text(
                label,
                style: typo.ui.copyWith(
                  color: selected ? colors.accent : colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (selected)
              RevericIcon(
                RevericIcons.check_rounded,
                size: 18,
                color: colors.accent,
              ),
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.colors,
    required this.typo,
    required this.option,
    required this.selected,
    required this.disabled,

    required this.onTap,
    this.selectedEffort,
    this.onSelectWithEffort,
    this.panelLeft,
    this.panelRight,
    this.hostMenuEntry,
    this.tapRegionGroupId,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final AiModelOption option;
  final bool selected;
  final bool disabled;

  final VoidCallback onTap;

  /// 该模型当前展示的 effort（选中模型用 selectedEffort，其他用默认）。
  final String? selectedEffort;

  /// effort 选择回调（推理模型选中 effort 时调用）。
  final void Function(AiModelOption, String)? onSelectWithEffort;

  final double? panelLeft;
  final double? panelRight;
  final OverlayEntry? hostMenuEntry;

  /// 宿主菜单的 TapRegion 分组；flyout 加入同组，避免点击 flyout 被菜单
  /// 的 onTapOutside 判定为外部点击而吞掉。
  final Object? tapRegionGroupId;

  bool get _isReasoning =>
      option.reasoningEfforts != null && option.reasoningEfforts!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    // InkWell 包住整行，hover 高亮覆盖全宽；effort chip 的 hover flyout
    // 在行内叠加（点击 chip 仍走整行的选中逻辑）。
    return InkWell(
      onTap: disabled ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.lg),
        child: Row(
          children: [
            RevericIcon(
              providerModelIcon(option.providerId),
              size: 18,
              color: disabled
                  ? colors.textSubtle
                  : selected
                  ? colors.accent
                  : colors.textMuted,
            ),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    option.displayModelName,
                    style: typo.ui.copyWith(
                      color: disabled
                          ? colors.textSubtle
                          : selected
                          ? colors.accent
                          : colors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  Text(
                    option.providerDisplayName,
                    style: typo.uiTiny.copyWith(
                      color: disabled ? colors.textSubtle : colors.textMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
            ),

            // effort flyout 仅在调用方接管 effort 选择时渲染，
            // 避免未接线的面板出现无效的交互入口。
            if (_isReasoning &&
                selectedEffort != null &&
                onSelectWithEffort != null)
              _EffortSubmenuAnchor(
                efforts: option.reasoningEfforts!,
                selectedEffort: selectedEffort!,
                colors: colors,
                typo: typo,
                panelLeft: panelLeft,
                panelRight: panelRight,
                aboveEntry: hostMenuEntry,
                tapRegionGroupId: tapRegionGroupId,
                onSelect: (effort) => onSelectWithEffort!(option, effort),
                child: _EffortChipLabel(
                  colors: colors,
                  typo: typo,
                  effort: selectedEffort!,
                ),
              ),
            if (selected)
              Padding(
                padding: const EdgeInsets.only(left: RevericSpacing.sm),
                child: RevericIcon(
                  RevericIcons.check_rounded,
                  size: 18,
                  color: colors.accent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---- effort widgets (shared between trigger + menu) --------------------------

/// effort 药丸 — 紧凑触发器上显示当前选中的 effort 级别。
class _EffortPill extends StatelessWidget {
  const _EffortPill({required this.effort, required this.colors});
  final String effort;
  final RevericColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 1, 6, 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: colors.accentWarm.withValues(alpha: 0.14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(
            RevericIcons.lightning,
            size: 11,
            color: colors.accentWarm,
          ),
          const SizedBox(width: 3),
          Text(
            reasoningEffortLabelOf(context, effort),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              height: 1.4,
              color: colors.accentWarm,
            ),
          ),
        ],
      ),
    );
  }
}

/// effort 选择入口 — 模型行右侧的 effort 标签 + > 箭头（仅展示，交互由 [_EffortSubmenuAnchor] 处理）。
class _EffortChipLabel extends StatelessWidget {
  const _EffortChipLabel({
    required this.colors,
    required this.typo,
    required this.effort,
  });
  final RevericColors colors;
  final RevericTypography typo;
  final String effort;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: RevericSpacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            reasoningEffortLabelOf(context, effort),
            style: typo.uiTiny.copyWith(color: colors.textMuted),
          ),
          const SizedBox(width: 4),
          RevericIcon(
            RevericIcons.chevron_right,
            size: 14,
            color: colors.textSubtle,
          ),
        ],
      ),
    );
  }
}

/// hover 时通过独立 Overlay 展示 reasoning effort 子菜单，避免被 model selector 裁切遮挡。
class _EffortSubmenuAnchor extends StatefulWidget {
  const _EffortSubmenuAnchor({
    required this.efforts,
    required this.selectedEffort,
    required this.colors,
    required this.typo,
    required this.onSelect,
    required this.child,
    this.panelLeft,
    this.panelRight,
    this.aboveEntry,
    this.tapRegionGroupId,
  });

  static const menuWidth = 232.0;
  static const rowHeight = 52.0;

  final List<String> efforts;
  final String selectedEffort;
  final RevericColors colors;
  final RevericTypography typo;
  final ValueChanged<String> onSelect;
  final Widget child;

  /// 模型菜单面板左右边界；有值时 flyout 紧贴面板右侧（mockup 样式）。
  final double? panelLeft;
  final double? panelRight;

  /// 宿主菜单 OverlayEntry，子菜单插入其上方以免被遮挡。
  final OverlayEntry? aboveEntry;

  /// 宿主菜单的 TapRegion 分组 id；子菜单面板加入同组，
  /// 点击子菜单才不会被宿主菜单的 consumeOutsideTaps 吞掉。
  final Object? tapRegionGroupId;

  @override
  State<_EffortSubmenuAnchor> createState() => _EffortSubmenuAnchorState();
}

class _EffortSubmenuAnchorState extends State<_EffortSubmenuAnchor> {
  static const _hideDelay = Duration(milliseconds: 250);
  static const _margin = RevericSpacing.sm;

  final _anchorKey = GlobalKey();
  OverlayEntry? _entry;
  Timer? _hideTimer;

  @override
  void dispose() {
    _cancelHideTimer();
    _removeSubmenu();
    super.dispose();
  }

  void _cancelHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _scheduleHide() {
    _cancelHideTimer();
    _hideTimer = Timer(_hideDelay, _removeSubmenu);
  }

  bool _fitsOnScreen({
    required double left,
    required double top,
    required double menuWidth,
    required double menuHeight,
    required double screenWidth,
    required double screenHeight,
  }) {
    return left >= _margin &&
        top >= _margin &&
        left + menuWidth <= screenWidth - _margin &&
        top + menuHeight <= screenHeight - _margin;
  }

  double _clampTop({
    required double preferredTop,
    required double menuHeight,
    required double screenHeight,
  }) {
    var top = preferredTop;
    if (top + menuHeight > screenHeight - _margin) {
      top = screenHeight - _margin - menuHeight;
    }
    if (top < _margin) {
      top = _margin;
    }
    return top;
  }

  ({double left, double top}) _resolvePosition({
    required Offset anchorPos,
    required Size anchorSize,
    required double menuWidth,
    required double menuHeight,
    required double screenWidth,
    required double screenHeight,
  }) {
    final panelLeft = widget.panelLeft;
    final panelRight = widget.panelRight;
    final preferredTop = anchorPos.dy;

    if (panelLeft != null && panelRight != null) {
      final panelCandidates = <({double left, double top})>[
        (
          left: panelRight,
          top: _clampTop(
            preferredTop: preferredTop,
            menuHeight: menuHeight,
            screenHeight: screenHeight,
          ),
        ),
        (
          left: panelLeft - menuWidth,
          top: _clampTop(
            preferredTop: preferredTop,
            menuHeight: menuHeight,
            screenHeight: screenHeight,
          ),
        ),
      ];

      for (final candidate in panelCandidates) {
        if (_fitsOnScreen(
          left: candidate.left,
          top: candidate.top,
          menuWidth: menuWidth,
          menuHeight: menuHeight,
          screenWidth: screenWidth,
          screenHeight: screenHeight,
        )) {
          return candidate;
        }
      }

      // 面板 flyout 放不下时，仍保持贴面板外侧，只做边界 clamp。
      final rightTop = _clampTop(
        preferredTop: preferredTop,
        menuHeight: menuHeight,
        screenHeight: screenHeight,
      );
      if (panelRight + menuWidth <= screenWidth - _margin) {
        return (left: panelRight, top: rightTop);
      }
      return (
        left: (panelLeft - menuWidth).clamp(
          _margin,
          screenWidth - menuWidth - _margin,
        ),
        top: rightTop,
      );
    }

    final gap = RevericSpacing.xs;
    final candidates = <({double left, double top})>[
      (left: anchorPos.dx + anchorSize.width + gap, top: preferredTop),
      (left: anchorPos.dx - menuWidth - gap, top: preferredTop),
      (
        left: anchorPos.dx + anchorSize.width - menuWidth,
        top: anchorPos.dy - menuHeight - gap,
      ),
      (
        left: anchorPos.dx + anchorSize.width - menuWidth,
        top: anchorPos.dy + anchorSize.height + gap,
      ),
    ];

    for (final candidate in candidates) {
      final top = _clampTop(
        preferredTop: candidate.top,
        menuHeight: menuHeight,
        screenHeight: screenHeight,
      );
      if (_fitsOnScreen(
        left: candidate.left,
        top: top,
        menuWidth: menuWidth,
        menuHeight: menuHeight,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
      )) {
        return (left: candidate.left, top: top);
      }
    }

    var left = anchorPos.dx - menuWidth - gap;
    var top = _clampTop(
      preferredTop: anchorPos.dy - menuHeight - gap,
      menuHeight: menuHeight,
      screenHeight: screenHeight,
    );
    left = left.clamp(_margin, screenWidth - menuWidth - _margin);
    return (left: left, top: top);
  }

  void _showSubmenu() {
    if (_entry != null) {
      return;
    }
    final renderBox =
        _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayState = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    if (renderBox == null || overlayBox == null) {
      return;
    }

    final anchorPos = renderBox.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );
    final anchorSize = renderBox.size;
    final menuWidth = _EffortSubmenuAnchor.menuWidth;
    final menuHeight = widget.efforts.length * _EffortSubmenuAnchor.rowHeight;
    final screenWidth = overlayBox.size.width;
    final screenHeight = overlayBox.size.height;
    final position = _resolvePosition(
      anchorPos: anchorPos,
      anchorSize: anchorSize,
      menuWidth: menuWidth,
      menuHeight: menuHeight,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
    );

    // 只有 flyout 面板本身响应 hover/点击；anchor 与面板之间的间隙靠
    // [_hideDelay] 宽限期跨越。不要再铺「bridge」命中区 — 它会悬浮在
    // 菜单其他行上方，挡住其他行的 hover 且让 flyout 迟迟不收起。
    _entry = OverlayEntry(
      builder: (overlayContext) {
        Widget panel = _EffortSubmenuPanel(
          efforts: widget.efforts,
          selectedEffort: widget.selectedEffort,
          colors: widget.colors,
          typo: widget.typo,
          onSelect: (effort) {
            _removeSubmenu();
            widget.onSelect(effort);
          },
        );
        // 加入宿主菜单的 TapRegion 分组，点击子菜单不算「菜单外部」。
        if (widget.tapRegionGroupId case final groupId?) {
          panel = TapRegion(groupId: groupId, child: panel);
        }
        return Positioned(
          left: position.left,
          top: position.top,
          width: menuWidth,
          child: MouseRegion(
            onEnter: (_) => _cancelHideTimer(),
            onExit: (_) => _scheduleHide(),
            child: panel,
          ),
        );
      },
    );

    final aboveEntry = widget.aboveEntry;
    if (aboveEntry != null && aboveEntry.mounted) {
      overlayState.insert(_entry!, above: aboveEntry);
    } else {
      overlayState.insert(_entry!);
    }
    _cancelHideTimer();
  }

  void _removeSubmenu() {
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      key: _anchorKey,
      onEnter: (_) {
        _cancelHideTimer();
        _showSubmenu();
      },
      onExit: (_) => _scheduleHide(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
        child: widget.child,
      ),
    );
  }
}

class _EffortSubmenuPanel extends StatelessWidget {
  const _EffortSubmenuPanel({
    required this.efforts,
    required this.selectedEffort,
    required this.colors,
    required this.typo,
    required this.onSelect,
  });

  final List<String> efforts;
  final String selectedEffort;
  final RevericColors colors;
  final RevericTypography typo;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.canvas,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      elevation: 12,
      shadowColor: Colors.black54,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final effort in efforts)
            SizedBox(
              height: _EffortSubmenuAnchor.rowHeight,
              child: InkWell(
                onTap: () => onSelect(effort),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.lg,
                  ),
                  child: Row(
                    children: [
                      ReasoningEffortBars(
                        total: efforts.length,
                        level: efforts.indexOf(effort),
                      ),
                      const SizedBox(width: RevericSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              reasoningEffortLabelOf(context, effort),
                              style: typo.ui.copyWith(
                                color: effort == selectedEffort
                                    ? colors.accent
                                    : colors.textPrimary,
                              ),
                            ),
                            Text(
                              reasoningEffortHintOf(context, effort),
                              style: typo.uiTiny.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (effort == selectedEffort)
                        RevericIcon(
                          RevericIcons.check_rounded,
                          size: 16,
                          color: colors.accent,
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 模型不可用统一提示 — 展示在输入框/模型选择器上方，
/// 替代在模型选择菜单里逐个模型展示禁用原因。
class ModelsUnavailableNotice extends StatelessWidget {
  /// 创建 ModelsUnavailableNotice
  const ModelsUnavailableNotice({
    super.key,
    required this.reason,
    required this.colors,
    required this.typo,
  });

  /// 禁用原因文案
  final String reason;

  /// 主题颜色
  final RevericColors colors;

  /// 字体样式
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.warningText.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.warningText.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RevericIcon(
            RevericIcons.block_rounded,
            size: 14,
            color: colors.warningText,
          ),
          const SizedBox(width: RevericSpacing.xs),
          Expanded(
            child: Text(
              reason,
              style: typo.uiTiny.copyWith(color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

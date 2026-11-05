// 职责: 在图片输入区选择预设并保留用户提示词；预设分组、图标和名称也供节点工具栏复用。
//   入口放在输入框顶部工具行，选中后原位显示预设名称。
// 关联文件:
//   lib/desktop/features/production/image_composer.dart
//   lib/desktop/features/production/node_bar.dart
//   lib/desktop/features/production/popover.dart
//   lib/desktop/features/storyboard/edit_form.dart
//   lib/shared/models/production/view_presets.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/form.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../../shared/components/reveric_popover.dart';
import '../../../../shared/form/form.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/models/production/view_presets.dart';
import '../../../../shared/theme/theme.dart';
import '../../storyboard/edit_form.dart';
import '../popover.dart';

String imagePresetLabel(BuildContext context, ImageGenerationMethod method) =>
    context.t('${LocaleKeys.productionImagePresets}.${method.name}');

String imagePresetIcon(ImageGenerationMethod method) => switch (method) {
  ImageGenerationMethod.free => RevericIcons.image_outlined,
  ImageGenerationMethod.upscale => RevericIcons.auto_fix_high_outlined,
  ImageGenerationMethod.blocking_storyboard => RevericIcons.alt_route_outlined,
  ImageGenerationMethod.storyboard => RevericIcons.film_slate,
  ImageGenerationMethod.continuous_grid => RevericIcons.movie_outlined,
  ImageGenerationMethod.plot_grid => RevericIcons.category_outlined,
  ImageGenerationMethod.after_3s => RevericIcons.clock_clockwise,
  ImageGenerationMethod.before_5s => RevericIcons.history_outlined,
  ImageGenerationMethod.portrait_texture => RevericIcons.user_circle,
  ImageGenerationMethod.cinematic_light => RevericIcons.auto_fix_high_outlined,
  ImageGenerationMethod.panorama => RevericIcons.public,
  ImageGenerationMethod.multi_camera_grid =>
    RevericIcons.space_dashboard_outlined,
  ImageGenerationMethod.expression_grid => RevericIcons.smiley,
  ImageGenerationMethod.face_turnaround => RevericIcons.user_focus,
  ImageGenerationMethod.character_sheet => RevericIcons.person_outline,
  ImageGenerationMethod.character_turnaround => RevericIcons.user_square,
  ImageGenerationMethod.scene_sheet => RevericIcons.layers_outlined,
  ImageGenerationMethod.product_sheet => RevericIcons.cube,
};

/// 预设面板的两列分组：左列叙事与质感，右列空间与设定图。
const _columns = [
  [
    (
      'narrative',
      [
        ImageGenerationMethod.blocking_storyboard,
        ImageGenerationMethod.storyboard,
        ImageGenerationMethod.continuous_grid,
        ImageGenerationMethod.plot_grid,
        ImageGenerationMethod.after_3s,
        ImageGenerationMethod.before_5s,
      ],
    ),
    (
      'texture',
      [
        ImageGenerationMethod.portrait_texture,
        ImageGenerationMethod.cinematic_light,
      ],
    ),
  ],
  [
    (
      'space',
      [ImageGenerationMethod.panorama, ImageGenerationMethod.multi_camera_grid],
    ),
    (
      'sheet',
      [
        ImageGenerationMethod.expression_grid,
        ImageGenerationMethod.face_turnaround,
        ImageGenerationMethod.character_sheet,
        ImageGenerationMethod.character_turnaround,
        ImageGenerationMethod.scene_sheet,
        ImageGenerationMethod.product_sheet,
      ],
    ),
  ],
];

ImageGenerationPreset _preset(FormFieldsController<ShotField> form) =>
    form.getValue<ImageGenerationPreset>(ShotField.imagePreset)!;

/// 预设弹层；未选时的按钮和选中后的名称 pill 共用。
class _MethodPicker extends StatelessWidget {
  const _MethodPicker({required this.form, required this.trigger});
  final FormFieldsController<ShotField> form;
  final Widget Function(BuildContext context, bool open, VoidCallback toggle)
  trigger;

  @override
  Widget build(BuildContext context) => RevericPopover(
    up: true,
    trigger: trigger,
    panel: (context, close) => ProductionPopoverPanel(
      width: 480,
      padding: const EdgeInsets.all(RevericSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final column in _columns)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (group, methods) in column) ...[
                    _GroupTitle(group),
                    for (final method in methods)
                      _PresetTile(
                        method: method,
                        selected: _preset(form).method == method,
                        onTap: () {
                          close();
                          _select(form, method);
                        },
                      ),
                  ],
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

void _select(FormFieldsController<ShotField> form, ImageGenerationMethod next) {
  if (_preset(form).method == next) {
    return;
  }
  form.updateValue(
    ShotField.imagePreset,
    ImageGenerationPreset(method: next, complexity: _preset(form).complexity),
  );
  if (next == ImageGenerationMethod.panorama) {
    form.updateValue(ShotField.ratio, '2:1');
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.group);
  final String group;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      RevericSpacing.xs,
      RevericSpacing.xs,
      RevericSpacing.xs,
      RevericSpacing.xxs,
    ),
    child: Text(
      context.t('${LocaleKeys.productionImagePresetGroups}.$group'),
      style: RevericTheme.typographyOf(
        context,
      ).uiSmall.copyWith(color: RevericTheme.colorsOf(context).textMuted),
    ),
  );
}

/// 一行预设：底色方块里的图标 + 名称。
class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.method,
    required this.selected,
    required this.onTap,
  });
  final ImageGenerationMethod method;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return InkWell(
      onTap: onTap,
      hoverColor: colors.hover,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: Container(
        padding: const EdgeInsets.all(RevericSpacing.xs),
        decoration: BoxDecoration(
          color: selected ? colors.selected : null,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(RevericRadius.medium),
              ),
              child: RevericIcon(
                imagePresetIcon(method),
                size: 18,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            Expanded(
              child: Text(
                imagePresetLabel(context, method),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 输入框顶部工具行的预设入口：未选时是「预设」按钮；选中后显示预设名称，旁边带移除键。
class ProductionImageMethodButton extends HookWidget {
  const ProductionImageMethodButton({super.key});

  @override
  Widget build(BuildContext context) {
    final form = useFormContext<ShotField>(context);
    final method = useListenableSelector(form, () => _preset(form).method);
    if (method == ImageGenerationMethod.free) {
      return _MethodPicker(
        form: form,
        trigger: (context, open, toggle) => ProductionToolChip(
          icon: RevericIcons.category_outlined,
          label: context.t(LocaleKeys.productionImageMethod),
          tooltip: context.t(LocaleKeys.productionImageMethod),
          open: open,
          onTap: toggle,
        ),
      );
    }
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MethodPicker(
          form: form,
          trigger: (context, open, toggle) => ProductionPill(
            open: open,
            filled: true,
            onTap: toggle,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RevericIcon(
                  imagePresetIcon(method),
                  size: 16,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: RevericSpacing.xs),
                Text(
                  imagePresetLabel(context, method),
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(width: 5),
                ProductionCaret(open: open),
              ],
            ),
          ),
        ),
        ProductionToolButton(
          icon: RevericIcons.close,
          tooltip: context.t(LocaleKeys.commonRemove),
          onTap: () => _select(form, ImageGenerationMethod.free),
        ),
      ],
    );
  }
}

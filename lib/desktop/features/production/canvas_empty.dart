// 职责: 为独立画布提供上传剧本、写提示词和导入素材三个起点。
// 关联文件:
//   lib/desktop/features/production/region.dart
//   lib/desktop/features/canvas/widgets/glass.dart
//   lib/shared/theme/canvas_colors.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
import 'package:flutter/material.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/canvas_colors.dart';
import '../../../shared/theme/theme.dart';
import '../canvas/widgets/glass.dart';

class CanvasEmptyStart extends StatelessWidget {
  const CanvasEmptyStart({
    super.key,
    required this.onUpload,
    required this.onPrompt,
    required this.onImport,
  });
  final VoidCallback onUpload, onPrompt, onImport;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x4l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.t(LocaleKeys.productionCanvasStart),
              style: typo.heading2.copyWith(color: colors.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: RevericSpacing.sm),
            Text(
              context.t(LocaleKeys.productionCanvasStartHint),
              style: typo.ui.copyWith(color: colors.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: RevericSpacing.x5l),
            Wrap(
              spacing: RevericSpacing.lg,
              runSpacing: RevericSpacing.lg,
              alignment: WrapAlignment.center,
              children: [
                _StartTile(
                  key: const ValueKey('canvas-upload-script'),
                  icon: RevericIcons.file_text,
                  title: context.t(LocaleKeys.productionUploadScript),
                  hint: context.t(LocaleKeys.productionUploadScriptHint),
                  onTap: onUpload,
                ),
                _StartTile(
                  key: const ValueKey('canvas-write-prompt'),
                  icon: RevericIcons.pencil_simple,
                  title: context.t(LocaleKeys.productionWritePrompt),
                  hint: context.t(LocaleKeys.productionWritePromptHint),
                  onTap: onPrompt,
                ),
                _StartTile(
                  key: const ValueKey('canvas-import-media'),
                  icon: RevericIcons.upload,
                  title: context.t(LocaleKeys.productionImportMedia),
                  hint: context.t(LocaleKeys.productionImportMediaHint),
                  onTap: onImport,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 起点卡片：和画布节点同一套半透明底与圆角，悬停只加深描边和底色。
class _StartTile extends StatefulWidget {
  const _StartTile({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    required this.onTap,
  });
  final String icon, title, hint;
  final VoidCallback onTap;
  @override
  State<_StartTile> createState() => _StartTileState();
}

class _StartTileState extends State<_StartTile> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final radius = BorderRadius.circular(RevericRadius.canvasNode);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (value) => setState(() => _hovered = value),
        borderRadius: radius,
        hoverColor: Colors.transparent,
        child: AnimatedContainer(
          duration: CanvasMotion.hover,
          curve: CanvasMotion.curve,
          width: RevericSizes.productionStartTileWidth,
          padding: const EdgeInsets.all(RevericSpacing.x2l),
          decoration: BoxDecoration(
            color: _hovered
                ? canvasGlassFill(colors, raised: true)
                : canvasGlassFill(colors),
            borderRadius: radius,
            border: Border.all(
              color: canvasGlassBorder(colors, strong: _hovered),
            ),
            boxShadow: canvasGlassNodeShadows(colors, hovered: _hovered),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: RevericSpacing.x6l,
                height: RevericSpacing.x6l,
                decoration: BoxDecoration(
                  color: canvasNodeWell(colors),
                  borderRadius: BorderRadius.circular(RevericRadius.x2l),
                ),
                child: Center(
                  child: RevericIcon(
                    widget.icon,
                    size: 20,
                    color: colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: RevericSpacing.x2l),
              Text(
                widget.title,
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: RevericSpacing.xxs),
              Text(
                widget.hint,
                style: typo.uiSmall.copyWith(color: colors.textMuted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 职责: 在一次图片任务下展示候选图，提供独立预览与切换采用。
// 关联文件:
//   lib/desktop/features/production/image_history.dart
//   lib/desktop/features/production/node_card.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import 'node_card.dart';
import 'support.dart';

/// 候选少时并排一行，面板窄时折成两列，避免缩略图挤成一条。
const _candidateWideWidth = 480.0;

class ProductionImageCandidates extends StatelessWidget {
  const ProductionImageCandidates({
    super.key,
    required this.service,
    required this.task,
    required this.selected,
    required this.onAdopt,
  });
  final ProductionCanvasService service;
  final GenerationTask task;
  final String? selected;
  final Future<void> Function(String assetId) onAdopt;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      RevericSpacing.xs,
      RevericSpacing.xxs,
      RevericSpacing.xs,
      RevericSpacing.xs,
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final ids = task.resultAssetIds;
        final columns = constraints.maxWidth >= _candidateWideWidth
            ? ids.length.clamp(1, 4)
            : 2;
        final width =
            (constraints.maxWidth - RevericSpacing.xs * (columns - 1)) /
            columns;
        return Wrap(
          spacing: RevericSpacing.xs,
          runSpacing: RevericSpacing.xs,
          children: [
            for (final (index, id) in ids.indexed)
              SizedBox(
                width: width,
                child: _Candidate(
                  service: service,
                  assetId: id,
                  ordinal: index + 1,
                  onAdopt: selected == id ? null : () => onAdopt(id),
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// 单张候选：点图预览；采用中的描强调色边并挂徽标，其余悬停时浮出「改用这次」。
class _Candidate extends HookWidget {
  const _Candidate({
    required this.service,
    required this.assetId,
    required this.ordinal,
    required this.onAdopt,
  });
  final ProductionCanvasService service;
  final String assetId;
  final int ordinal;
  final Future<void> Function()? onAdopt;
  @override
  Widget build(BuildContext context) {
    final asset = useProductionAsset(service, assetId);
    final busy = useState(false);
    final hovered = useState(false);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final inUse = onAdopt == null;
    final radius = BorderRadius.circular(RevericRadius.large);
    return MouseRegion(
      onEnter: (_) => hovered.value = true,
      onExit: (_) => hovered.value = false,
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: radius,
              child: Semantics(
                label: context.t(
                  LocaleKeys.productionImageCandidate,
                  namedArgs: {'n': '$ordinal'},
                ),
                button: true,
                child: Material(
                  color: colors.surfaceDim,
                  child: InkWell(
                    onTap: asset == null
                        ? null
                        : () => productionRun(
                            context,
                            () => previewProductionAsset(
                              context,
                              service,
                              assetId,
                            ),
                          ),
                    child: ProductionAssetThumb(
                      service: service,
                      filePath: asset?.path,
                    ),
                  ),
                ),
              ),
            ),
            // 边框画在图片之上，选中态的强调色不会被缩略图盖住。
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(
                    color: inUse
                        ? colors.accent
                        : hovered.value
                        ? colors.border
                        : colors.borderSubtle,
                    width: inUse ? 2 : 1,
                  ),
                ),
              ),
            ),
            if (inUse)
              Positioned(
                left: RevericSpacing.xs,
                top: RevericSpacing.xs,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.xs,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.accent,
                    borderRadius: BorderRadius.circular(RevericRadius.capsule),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 3,
                    children: [
                      RevericIcon(
                        RevericIcons.seal_check,
                        size: 11,
                        color: colors.onAccent,
                      ),
                      Text(
                        context.t(LocaleKeys.productionResultsInUse),
                        style: typo.uiTinySemibold.copyWith(
                          color: colors.onAccent,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              // 底部渐暗衬底，保证浮出的按钮在亮图上也看得清。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 64,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: hovered.value || busy.value ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                          bottom: radius.bottomLeft,
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            colors.canvas.withValues(alpha: 0),
                            colors.canvas.withValues(alpha: 0.8),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: RevericSpacing.sm,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: hovered.value || busy.value ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: RevericButton.secondary(
                      key: ValueKey('image-candidate-adopt-$ordinal'),
                      label: context.t(LocaleKeys.productionResultsSwitch),
                      size: RevericButtonSize.compact,
                      loading: busy.value,
                      onPressed: busy.value
                          ? null
                          : () async {
                              busy.value = true;
                              await productionRun(context, onAdopt!);
                              if (context.mounted) {
                                busy.value = false;
                              }
                            },
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

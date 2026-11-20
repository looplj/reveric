// 职责: 提供全景节点的退出、重置、构图线和全屏操作。
// 关联文件:
//   lib/desktop/features/production/node_bar.dart
//   lib/shared/providers/production_panorama.dart
//   lib/shared/widgets/production/panorama/fullscreen.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../../shared/components/reveric_icon_button.dart';
import '../../../../shared/components/dialog_feedback.dart';
import '../../../../shared/services/production/panorama_service.dart';
import '../../../../shared/database/novel_content_database.dart';
import '../../../../shared/models/production/panorama.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/models/video/request.dart';
import '../../../../shared/providers/production_panorama.dart';
import '../../../../shared/services/production/canvas_service.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/widgets/production/panorama/fullscreen.dart';
import '../support.dart';

class ProductionPanoramaActions extends HookConsumerWidget {
  const ProductionPanoramaActions({
    super.key,
    required this.service,
    required this.node,
    required this.assetId,
    this.readOnly = false,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final String? assetId;
  final bool readOnly;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(
      productionPanoramaProvider((
        service: service,
        nodeId: node.id,
        readOnly: readOnly,
      )),
    );
    useListenable(controller);
    final capturing = useState(false);
    final captures = ref.watch(productionPanoramaServiceProvider(service));
    final persisted = PanoramaView.fromStyle(node.style)!;
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          controller.restore(persisted);
        }
      });
      return null;
    }, [controller, persisted]);
    final asset = useFuture(
      useMemoized(
        () => service.inputAsset(
          ProductionInput.node(node.id, VideoInputRole.reference_image),
        ),
        [service, node.id, assetId],
      ),
    );
    void capture(bool four) => productionRun(context, () async {
      capturing.value = true;
      final view = controller.view;
      final directions = four
          ? [
              LocaleKeys.productionViewPanoramaFront,
              LocaleKeys.productionViewPanoramaRight,
              LocaleKeys.productionViewPanoramaBack,
              LocaleKeys.productionViewPanoramaLeft,
            ]
          : [LocaleKeys.productionViewPanoramaCurrent];
      final requests = <PanoramaCaptureRequest>[
        for (final (index, direction) in directions.indexed)
          (
            view: four ? view.changed(yaw: index * 90.0) : view,
            name: context.t(
              LocaleKeys.productionViewPanoramaCaptureTitle,
              namedArgs: {'direction': context.t(direction)},
            ),
          ),
      ];
      try {
        final result = await captures.capture(node.id, requests);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: DialogToast(
                variant: result.failures.isEmpty
                    ? DialogToastVariant.success
                    : DialogToastVariant.warning,
                child: Text(
                  result.failures.isEmpty
                      ? context.t(
                          LocaleKeys.productionViewPanoramaCaptured,
                          namedArgs: {'count': '${result.nodes.length}'},
                        )
                      : context.t(
                          LocaleKeys.productionViewPanoramaCaptureFailed,
                          namedArgs: {
                            'names': result.failures.entries
                                .map(
                                  (entry) =>
                                      '${entry.key}: ${context.t('${LocaleKeys.productionViewPanoramaFailure}.${entry.value.stage.name}')}',
                                )
                                .join('; '),
                          },
                        ),
                ),
              ),
            ),
          );
        }
      } finally {
        if (context.mounted) {
          capturing.value = false;
        }
      }
    });
    Widget action(String icon, String key, VoidCallback? onPressed) =>
        RevericIconButton(
          icon: icon,
          tooltip: context.t(key),
          onPressed: capturing.value ? null : onPressed,
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!readOnly) ...[
          action(
            RevericIcons.image_outlined,
            LocaleKeys.productionViewPanoramaCaptureCurrent,
            asset.hasData && !capturing.value ? () => capture(false) : null,
          ),
          action(
            RevericIcons.space_dashboard_outlined,
            LocaleKeys.productionViewPanoramaCaptureFour,
            asset.hasData && !capturing.value ? () => capture(true) : null,
          ),
        ],
        action(
          RevericIcons.arrow_clockwise,
          LocaleKeys.productionViewPanoramaReset,
          controller.reset,
        ),
        action(
          RevericIcons.space_dashboard_outlined,
          LocaleKeys.productionViewPanoramaGrid,
          controller.toggleGrid,
        ),
        action(
          RevericIcons.arrows_out,
          LocaleKeys.productionViewPanoramaFullscreen,
          asset.hasData
              ? () => showPanoramaFullscreen(
                  context,
                  service.library.resolve(asset.data!),
                  controller,
                )
              : null,
        ),
        Tooltip(
          message: context.t(LocaleKeys.productionViewPanoramaKeys),
          child: const Padding(
            padding: EdgeInsets.all(RevericSpacing.sm),
            child: RevericIcon(RevericIcons.info_outline, size: 16),
          ),
        ),
        if (!readOnly)
          action(
            RevericIcons.visibility_off,
            LocaleKeys.productionViewPanoramaExit,
            () => productionRun(context, () async {
              await controller.stopSaving();
              await service.setPanoramaView(node.id, null);
            }),
          ),
      ],
    );
  }
}

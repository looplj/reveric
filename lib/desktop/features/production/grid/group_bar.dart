// 职责: 提供分镜组布局、清空与拼接，以及分组重命名、转换、解组和删除操作。
// 关联文件:
//   lib/desktop/features/production/node_bar.dart
//   lib/shared/services/production/group_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import '../history_region.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../../shared/components/reveric_button.dart';
import '../../../../shared/components/reveric_select.dart';
import '../../../../shared/components/reveric_checkbox.dart';
import '../../../../shared/models/production/settings.dart';
import 'spec_picker.dart';
import '../../../../shared/components/reveric_context_menu.dart';
import '../../../../shared/components/reveric_icon_button.dart';
import '../../../../shared/components/reveric_dialog.dart';
import '../../../../shared/components/reveric_text_field.dart';
import '../../../../shared/database/novel_content_database.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/services/production/canvas_service.dart';
import '../../../../shared/services/production/derived_placement.dart'
    show productionMediaAspect;
import '../../../../shared/services/production/grid_orchestrator.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../canvas/widgets/glass.dart';
import '../node_card.dart';
import '../support.dart';

/// 转换时使用资产记录的图片比例，不使用分镜组覆盖后的格子尺寸。
Future<Map<String, Rect>> productionGroupMemberRects(
  ProductionCanvasService service,
  String groupId,
) async {
  final rects = <String, Rect>{};
  for (final member in await service.groups.members(groupId)) {
    double? aspect;
    if (member.clipId case final id?) {
      aspect = productionAspect((await service.shots.getShot(id))?.ratio);
    } else if (member.mediaAssetId case final id?) {
      final asset = await service.requireAsset(id, type: 'image');
      aspect = productionMediaAspect(asset.content);
    }
    rects[member.id] =
        Offset(member.x, member.y) &
        productionNodeSize(member, aspect: aspect, mediaType: 'image');
  }
  return rects;
}

class ProductionGroupBar extends HookWidget {
  const ProductionGroupBar({
    super.key,
    required this.service,
    required this.node,
    this.onCreated,
    this.place,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final ValueChanged<CanvasNode>? onCreated;
  final ProductionNodePlacement Function(Size)? place;
  @override
  Widget build(BuildContext context) {
    final history = ProductionHistoryScope.maybeOf(context)?.history;
    final busy = useState(false);
    final layout = ProductionGroupLayout.fromStyle(node.style);
    final members = useStream(
      useMemoized(
        () => service
            .watchContent(node.canvasId)
            .map(
              (content) =>
                  content.nodes.where((n) => n.parentId == node.id).toList(),
            ),
        [service, node.id, node.canvasId],
      ),
    ).data;
    final imageMembers =
        useFuture(
          useMemoized(
            () async {
              if (members == null) {
                return false;
              }
              for (final member in members) {
                if (member.type == canvasNodeTypeImage) {
                  continue;
                }
                if (member.type != canvasNodeTypeMedia ||
                    member.mediaAssetId == null) {
                  return false;
                }
                final asset = await service.library.database.assetDao.getAsset(
                  member.mediaAssetId!,
                );
                if (asset?.type != 'image') {
                  return false;
                }
              }
              return true;
            },
            [
              service,
              members
                  ?.map((n) => '${n.id}:${n.type}:${n.mediaAssetId}')
                  .join('|'),
            ],
          ),
        ).data ==
        true;
    void run(Future<void> Function() action) =>
        productionRun(context, () async {
          if (busy.value) {
            return;
          }
          busy.value = true;
          try {
            await action();
          } finally {
            if (context.mounted) {
              busy.value = false;
            }
          }
        });
    Future<void> convert() async {
      final rects = await productionGroupMemberRects(service, node.id);
      if (layout is StoryboardGroupLayout) {
        await service.groups.toFree(
          node.id,
          rects.map((id, rect) => MapEntry(id, rect.size)),
          history: history,
        );
      } else {
        await service.groups.toStoryboard(node.id, rects, history: history);
      }
    }

    return Material(
      type: MaterialType.transparency,
      child: CanvasGlass(
        raised: true,
        padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.xs),
        child: SizedBox(
          height: 40,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (layout is StoryboardGroupLayout) ...[
                SizedBox(
                  width: 86,
                  child: RevericSelect<String>(
                    value: layout.ratio,
                    compact: true,
                    enabled: !busy.value,
                    items: [
                      for (final ratio in ProductionSettings.ratios)
                        RevericSelectItem(value: ratio, label: ratio),
                    ],
                    onChanged: (ratio) => run(
                      () => service.groups.setStoryboardLayout(
                        node.id,
                        layout.copyWith(ratio: ratio),
                        history: history,
                      ),
                    ),
                  ),
                ),
                ProductionGridSpecPicker(
                  label: '${layout.rows}×${layout.cols}',
                  minimum: (members?.length ?? 0).clamp(2, 25),
                  enabled: !busy.value && members != null,
                  onSelected: (spec) => run(
                    () => service.groups.setStoryboardLayout(
                      node.id,
                      layout.copyWith(rows: spec.rows, cols: spec.cols),
                      history: history,
                    ),
                  ),
                ),
                RevericCheckbox(
                  value: layout.numbered,
                  semanticLabel: context.t(LocaleKeys.productionGroupNumbered),
                  onChanged: busy.value
                      ? null
                      : (numbered) => run(
                          () => service.groups.setStoryboardLayout(
                            node.id,
                            layout.copyWith(numbered: numbered),
                            history: history,
                          ),
                        ),
                ),
                Text(
                  context.t(LocaleKeys.productionGroupNumbered),
                  style: RevericTheme.typographyOf(context).uiSmall,
                ),
                RevericButton.text(
                  label: context.t(LocaleKeys.commonClear),
                  size: RevericButtonSize.compact,
                  onPressed: busy.value || members?.isNotEmpty != true
                      ? null
                      : () => run(() async {
                          final confirmed = await showConfirmDialog(
                            context,
                            title: context.t(LocaleKeys.commonClear),
                            message: context.t(
                              LocaleKeys.productionGroupClearConfirm,
                              namedArgs: {'count': '${members!.length}'},
                            ),
                            confirmLabel: context.t(LocaleKeys.commonClear),
                            variant: ConfirmDialogVariant.error,
                          );
                          if (confirmed) {
                            await service.groups.clear(
                              node.id,
                              history: history,
                            );
                          }
                        }),
                ),
              ],
              RevericButton.text(
                label: context.t(LocaleKeys.commonRename),
                size: RevericButtonSize.compact,
                onPressed: busy.value
                    ? null
                    : () => run(() async {
                        final title = await showRevericDialog<String>(
                          context: context,
                          builder: (_) => _Rename(title: node.title),
                        );
                        if (title != null) {
                          await service.groups.rename(
                            node.id,
                            title,
                            history: history,
                          );
                        }
                      }),
              ),
              Tooltip(
                message: layout is FreeGroupLayout && !imageMembers
                    ? context.t(LocaleKeys.productionGroupImagesOnly)
                    : '',
                child: RevericButton.text(
                  label: context.t(
                    layout is StoryboardGroupLayout
                        ? LocaleKeys.productionGroupToFree
                        : LocaleKeys.productionGroupToStoryboard,
                  ),
                  size: RevericButtonSize.compact,
                  onPressed:
                      busy.value || (layout is FreeGroupLayout && !imageMembers)
                      ? null
                      : () => run(convert),
                ),
              ),
              RevericButton.text(
                label: context.t(LocaleKeys.productionGroupUngroup),
                size: RevericButtonSize.compact,
                onPressed: busy.value
                    ? null
                    : () => run(() async {
                        final rects = await productionGroupMemberRects(
                          service,
                          node.id,
                        );
                        await service.groups.ungroup(
                          node.id,
                          sizes: rects.map(
                            (id, rect) => MapEntry(id, rect.size),
                          ),
                          history: history,
                        );
                      }),
              ),
              if (layout is StoryboardGroupLayout)
                RevericButton.text(
                  label: context.t(LocaleKeys.productionGroupStitch),
                  size: RevericButtonSize.compact,
                  loading: busy.value,
                  onPressed: busy.value || place == null
                      ? null
                      : () => run(() async {
                          final colors = RevericTheme.colorsOf(context);
                          final title =
                              '${node.title.isEmpty ? context.t(LocaleKeys.productionGroupStoryboard) : node.title} · ${context.t(LocaleKeys.productionGroupStitch)}';
                          final result = await GridOrchestrator().stitch(
                            canvas: service,
                            groupId: node.id,
                            title: title,
                            background: colors.surfaceDim.toARGB32(),
                            foreground: colors.textPrimary.toARGB32(),
                            place: place!,
                          );
                          if (context.mounted) {
                            onCreated?.call(result);
                          }
                        }),
                ),
              Builder(
                builder: (anchor) => RevericIconButton(
                  icon: RevericIcons.more_horiz,
                  tooltip: context.t(LocaleKeys.commonMoreActions),
                  onPressed: busy.value
                      ? null
                      : () {
                          final box = anchor.findRenderObject()! as RenderBox;
                          showRevericContextMenu(
                            context: context,
                            position: box.localToGlobal(
                              Offset(0, box.size.height),
                            ),
                            entries: [
                              RevericMenuItem(
                                label: context.t(LocaleKeys.commonDelete),
                                icon: RevericIcons.delete,
                                onTap: () => run(() async {
                                  final count = (await service.groups.members(
                                    node.id,
                                  )).length;
                                  if (!context.mounted) {
                                    return;
                                  }
                                  final confirmed = await showConfirmDialog(
                                    context,
                                    title: context.t(LocaleKeys.commonDelete),
                                    message: context.t(
                                      LocaleKeys.productionGroupDeleteConfirm,
                                      namedArgs: {'count': '$count'},
                                    ),
                                    confirmLabel: context.t(
                                      LocaleKeys.commonDelete,
                                    ),
                                    variant: ConfirmDialogVariant.error,
                                  );
                                  if (confirmed) {
                                    await service.removeNode(
                                      node.id,
                                      history: history,
                                    );
                                  }
                                }),
                              ),
                            ],
                          );
                        },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Rename extends HookWidget {
  const _Rename({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(text: title);
    return RevericDialog(
      title: context.t(LocaleKeys.commonRename),
      content: RevericTextField(
        controller: controller,
        autofocus: true,
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        RevericButton.text(
          label: context.t(LocaleKeys.commonCancel),
          onPressed: () => Navigator.of(context).pop(),
        ),
        RevericButton.primary(
          label: context.t(LocaleKeys.commonSave),
          onPressed: () => Navigator.of(context).pop(controller.text),
        ),
      ],
    );
  }
}

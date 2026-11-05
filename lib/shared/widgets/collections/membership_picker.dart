// 职责: 展示集合三态归属列表，点击即时加入或移出，并允许新建集合。
// 关联文件:
//   lib/shared/widgets/collections/name_dialog.dart
//   lib/shared/widgets/collections/surface.dart
//   lib/shared/providers/novel_collection_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_checkbox.dart';
import '../../components/reveric_icon_button.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../providers/novel_providers.dart';
import '../../providers/novel_collection_providers.dart';
import '../../models/novel_collection.dart';
import '../../theme/theme.dart';
import 'name_dialog.dart';
import 'surface.dart';

Future<void> showCollectionMembership(
  BuildContext context, {
  required bool mobile,
  required Set<String> workIds,
  required String contentKind,
  Offset? position,
}) {
  final picker = CollectionMembershipPicker(
    mobile: mobile,
    workIds: workIds,
    contentKind: contentKind,
  );
  if (mobile) {
    return showCollectionSurface<void>(
      context,
      mobile: true,
      builder: (_) => picker,
    );
  }
  final theme = RevericTheme.of(context);
  final box = context.findRenderObject()! as RenderBox;
  final anchor = position ?? box.localToGlobal(Offset(0, box.size.height));
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.t(LocaleKeys.commonClose),
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, _, _) => RevericTheme(
      data: theme,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const margin = RevericSpacing.lg;
          final width = math.min(320.0, constraints.maxWidth - margin * 2);
          final height = math.min(360.0, constraints.maxHeight - margin * 2);
          final left = anchor.dx.clamp(
            margin,
            math.max(margin, constraints.maxWidth - width - margin),
          );
          final top = anchor.dy.clamp(
            margin,
            math.max(margin, constraints.maxHeight - height - margin),
          );
          return Stack(
            children: [
              Positioned(
                left: left.toDouble(),
                top: top.toDouble(),
                width: width,
                height: height,
                child: Material(
                  elevation: 8,
                  color: theme.colors.surface,
                  borderRadius: BorderRadius.circular(RevericRadius.large),
                  clipBehavior: Clip.antiAlias,
                  child: picker,
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class CollectionMembershipPicker extends HookConsumerWidget {
  const CollectionMembershipPicker({
    super.key,
    required this.mobile,
    required this.workIds,
    required this.contentKind,
  });
  final bool mobile;
  final Set<String> workIds;

  /// [workIds] 的作品类型；只列这一类的手动集合，新建的集合也归这一类。
  final String contentKind;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collections = ref.watch(novelCollectionsProvider);
    final memberships = ref.watch(
      collectionMembershipsProvider(collectionWorkIdsKey(workIds)),
    );
    final busy = useState(false);
    final error = useState(false);
    final content = SizedBox(
      height: 300,
      child: Column(
        children: [
          Expanded(
            child: collections.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(
                child: Text(context.t(LocaleKeys.libraryCollectionLoadFailed)),
              ),
              data: (all) {
                final list = all
                    .where((c) => c.manual && c.visibleIn(contentKind))
                    .toList();
                if (list.isEmpty) {
                  return Center(
                    child: Text(context.t(LocaleKeys.libraryCollectionNone)),
                  );
                }
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, index) {
                    final collection = list[index];
                    final checked = collectionMembership(
                      memberships.value?[collection.id] ?? {},
                      workIds,
                    );
                    Future<void> toggle() async {
                      if (busy.value) {
                        return;
                      }
                      busy.value = true;
                      error.value = false;
                      try {
                        await ref
                            .read(appDatabaseProvider)
                            .novelCollectionDao
                            .setMembership(
                              collection.id,
                              workIds,
                              included: checked != true,
                            );
                      } catch (_) {
                        if (context.mounted) {
                          error.value = true;
                        }
                      } finally {
                        if (context.mounted) {
                          busy.value = false;
                        }
                      }
                    }

                    return MergeSemantics(
                      child: ListTile(
                        onTap: busy.value || !memberships.hasValue
                            ? null
                            : toggle,
                        leading: RevericCheckbox(
                          value: checked == true,
                          indeterminate: checked == null,
                          onChanged: busy.value || !memberships.hasValue
                              ? null
                              : (_) => toggle(),
                        ),
                        title: Text(
                          collection.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (error.value || memberships.hasError)
            Text(
              context.t(LocaleKeys.libraryCollectionFailed),
              style: RevericTheme.typographyOf(context).uiSmall.copyWith(
                color: RevericTheme.colorsOf(context).deletionBorder,
              ),
            ),
          const Divider(),
          RevericButton.text(
            label: context.t(LocaleKeys.commonCreate),
            icon: RevericIcons.add,
            onPressed: busy.value
                ? null
                : () => showCollectionName(
                    context,
                    mobile: mobile,
                    contentKind: contentKind,
                    workIds: workIds,
                  ),
          ),
        ],
      ),
    );
    if (mobile) {
      return CollectionSurface(
        mobile: true,
        title: context.t(LocaleKeys.libraryCollectionAddTo),
        child: content,
      );
    }
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.sm),
      child: Column(
        children: [
          Row(
            children: [
              RevericIconButton(
                icon: RevericIcons.arrow_back,
                tooltip: context.t(LocaleKeys.commonClose),
                onPressed: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Text(
                  context.t(LocaleKeys.libraryCollectionAddTo),
                  style: RevericTheme.typographyOf(context).uiSemibold,
                ),
              ),
            ],
          ),
          Expanded(child: content),
        ],
      ),
    );
  }
}

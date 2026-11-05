// 职责: 展示集合空态图标、加载错误和从书架添加作品入口。
// 关联文件:
//   lib/shared/widgets/collections/location.dart
//   lib/shared/widgets/collections/work_picker.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_placeholder.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../theme/theme.dart';
import 'location.dart';
import 'work_picker.dart';

class CollectionEmpty extends StatelessWidget {
  const CollectionEmpty({super.key, required this.location});
  final CollectionLocation location;
  @override
  Widget build(BuildContext context) => Center(
    child: RevericPlaceholder.empty(
      icon: RevericIcons.stack,
      title: location.works.hasError
          ? context.t(
              location.current?.unavailableReason != null
                  ? LocaleKeys.libraryCollectionUnavailable
                  : LocaleKeys.libraryCollectionLoadFailed,
            )
          : null,
      description:
          location.works.hasError && location.current?.unavailableReason != null
          ? context.t(LocaleKeys.libraryCollectionUnsupportedHint)
          : null,
      action: location.current?.manual != true
          ? null
          : RevericButton.primary(
              label: context.t(LocaleKeys.libraryCollectionAddWorks),
              onPressed: () => showCollectionWorkPicker(
                context,
                mobile: location.mobile,
                collectionId: location.current!.id,
                contentKind: location.contentKind,
              ),
            ),
    ),
  );
}

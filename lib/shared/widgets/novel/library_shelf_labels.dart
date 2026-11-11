// 职责: 书架筛选/排序及作品更新时间的本地化文案，桌面与移动端共用。
// 关联文件:
//   lib/shared/models/novel.dart
//   lib/shared/models/content_status.dart
//   lib/shared/models/content_kind.dart
//   lib/desktop/widgets/home/all_works_header.dart
//   lib/mobile/features/library/filters.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json

import 'package:flutter/widgets.dart';

import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/content_kind.dart';
import '../../models/content_status.dart';
import '../../models/novel.dart';

String libraryStatusText(
  BuildContext context,
  String status, {
  String? contentKind,
}) {
  if (contentKind == contentKindCanvas) {
    return switch (status) {
      contentStatusArchived => context.t(LocaleKeys.libraryStatusArchived),
      contentStatusAbandoned => context.t(LocaleKeys.libraryStatusAbandoned),
      _ => context.t(LocaleKeys.libraryStatusActive),
    };
  }
  return switch (status) {
    contentStatusInProgress => context.t(LocaleKeys.libraryStatusInProgress),
    contentStatusFinished => context.t(LocaleKeys.libraryStatusFinished),
    contentStatusAbandoned => context.t(LocaleKeys.libraryStatusAbandoned),
    contentStatusArchived => context.t(LocaleKeys.libraryStatusArchived),
    _ => status,
  };
}

String librarySortText(BuildContext context, LibrarySortOrder order) {
  return context.t(switch (order) {
    LibrarySortOrder.updated => LocaleKeys.homeSortRecent,
    LibrarySortOrder.created => LocaleKeys.homeSortCreated,
    LibrarySortOrder.title => LocaleKeys.homeSortTitle,
    LibrarySortOrder.wordCount => LocaleKeys.homeSortWordCount,
  });
}

/// null 为「全部分类」，空串为「未分类」。
String libraryCategoryText(BuildContext context, String? category) {
  if (category == null) return context.t(LocaleKeys.homeFilterCategoryAll);
  if (category.isEmpty) return context.t(LocaleKeys.homeFilterUncategorized);
  return category;
}

String formatHomeNovelUpdatedAt(BuildContext context, DateTime when) {
  final now = DateTime.now();
  final date = DateTime(when.year, when.month, when.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(date).inDays;
  final hh = when.hour.toString().padLeft(2, '0');
  final mm = when.minute.toString().padLeft(2, '0');
  if (diff == 0) {
    return context.t(LocaleKeys.homeToday, namedArgs: {'time': '$hh:$mm'});
  }
  if (diff == 1) {
    return context.t(LocaleKeys.homeYesterday);
  }
  if (diff < 30) {
    return context.t(LocaleKeys.homeDaysAgo, namedArgs: {'count': '$diff'});
  }
  return '${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')}';
}

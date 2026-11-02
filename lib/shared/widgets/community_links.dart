// 职责: 打开 QQ 交流群、GitHub 仓库等社区外链并复制 QQ 群号，失败时向用户提示。
// 关联文件:
//   lib/shared/app_config.dart
//   lib/shared/components/dialog_feedback.dart
//   lib/shared/widgets/settings/about_settings_section.dart
//   lib/desktop/widgets/community_row.dart
//   lib/mobile/pages/settings_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_config.dart'
    show revericGitHubRepoUrl, revericQqGroupJoinUrl, revericQqGroupNumber;
import '../components/dialog_feedback.dart';
import '../localization/app_localization.dart';
import '../localization/locale_keys.dart';
import '../logger/app_logger.dart';

final _log = AppLogger.forModule('CommunityLinks');

Future<void> openQqGroup(BuildContext context) => openExternalLink(
  context,
  Uri.parse(revericQqGroupJoinUrl),
  LocaleKeys.settingsAboutQqOpenFailed,
);

Future<void> openGitHubRepo(BuildContext context) => openExternalLink(
  context,
  Uri.parse(revericGitHubRepoUrl),
  LocaleKeys.settingsAboutOpenRepositoryFailed,
);

Future<void> copyQqGroupNumber(BuildContext context) async {
  await Clipboard.setData(const ClipboardData(text: revericQqGroupNumber));
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: DialogToast(
        variant: DialogToastVariant.success,
        child: Text(context.t(LocaleKeys.commonCopied)),
      ),
    ),
  );
}

/// 用系统默认应用打开外链；打不开时记录日志并用 [failedKey] 提示用户。
Future<void> openExternalLink(
  BuildContext context,
  Uri uri,
  String failedKey,
) async {
  try {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (opened) {
      return;
    }
    _log.warning('URL launch returned false: $uri');
  } catch (error, stackTrace) {
    _log.error(
      'Failed to open URL: $uri',
      error: error,
      stackTrace: stackTrace,
    );
  }
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: DialogToast(
        variant: DialogToastVariant.error,
        child: Text(context.t(failedKey)),
      ),
    ),
  );
}

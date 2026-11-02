// 职责: 展示应用版本、更新检查、本地日志与诊断上传、QQ 群交流与开源署名入口，供桌面和移动端设置使用。
// 关联文件:
//   lib/shared/components/reveric_button.dart
//   lib/shared/providers/update_providers.dart
//   lib/shared/logger/log_manager.dart
//   lib/shared/widgets/settings/diagnostics_upload_button.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/hooks.md

import 'dart:io';
import 'diagnostics_upload_button.dart';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../components/reveric_button.dart';
import '../../app_config.dart'
    show
        appVersion,
        revericAttribution,
        revericGitHubRepoUrl,
        revericQqGroupJoinUrl,
        revericQqGroupNumber;
import '../../components/dialog_feedback.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/log_manager.dart';
import '../../logger/app_logger.dart';
import '../../providers/update_providers.dart';
import '../../services/update.dart';
import '../../theme/theme.dart';

final _log = AppLogger.forModule('AboutSettings');

/// 关于设置 section：版本、更新、本地日志与诊断上传、QQ 群交流和开源署名。
class AboutSettingsSection extends HookConsumerWidget {
  const AboutSettingsSection({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final updateResultAsync = ref.watch(latestReleaseProvider);
    final downloadState = ref.watch(updateDownloadProvider);

    final sectionGap = compact ? RevericSpacing.x3l : RevericSpacing.x4l;
    final descriptionGap = compact ? RevericSpacing.sm : RevericSpacing.md;
    final actionGap = compact ? RevericSpacing.md : RevericSpacing.lg;
    final supportsOpeningApplicationDirectory =
        !Platform.isAndroid && !Platform.isIOS;

    return SingleChildScrollView(
      padding: EdgeInsets.all(
        compact ? RevericSpacing.x3l : RevericSpacing.x4l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(context, typo, colors, LocaleKeys.settingsAbout),
          const SizedBox(height: RevericSpacing.x2l),
          _buildVersionRow(context, colors, typo),
          SizedBox(height: sectionGap),
          _buildUpdateSection(
            context,
            colors,
            typo,
            ref,
            updateResultAsync,
            downloadState,
          ),
          SizedBox(height: sectionGap),
          if (supportsOpeningApplicationDirectory) ...[
            _buildSectionTitle(
              context,
              typo,
              colors,
              LocaleKeys.settingsAboutOpenLogs,
            ),
            SizedBox(height: descriptionGap),
            Text(
              context.t(LocaleKeys.settingsAboutOpenLogsDescription),
              style: _descriptionStyle(typo, colors),
            ),
            SizedBox(height: actionGap),
            _buildOpenApplicationDirectoryButton(context, colors, typo),
            SizedBox(height: sectionGap),
          ],
          _buildSectionTitle(
            context,
            typo,
            colors,
            LocaleKeys.settingsAboutUploadLogs,
          ),
          SizedBox(height: descriptionGap),
          Text(
            context.t(LocaleKeys.settingsAboutUploadLogsDescription),
            style: _descriptionStyle(typo, colors),
          ),
          SizedBox(height: actionGap),
          const DiagnosticsUploadButton(),
          SizedBox(height: sectionGap),
          _buildSectionTitle(
            context,
            typo,
            colors,
            LocaleKeys.settingsAboutFeedback,
          ),
          SizedBox(height: descriptionGap),
          Text(
            context.t(LocaleKeys.settingsAboutFeedbackDescription),
            style: _descriptionStyle(typo, colors),
          ),
          SizedBox(height: actionGap),
          _buildExternalLinkButton(
            colors,
            typo,
            label:
                '${context.t(LocaleKeys.settingsAboutJoinQqGroup)} · $revericQqGroupNumber',
            onTap: () => _openExternalUrl(
              context,
              Uri.parse(revericQqGroupJoinUrl),
              LocaleKeys.settingsAboutQqOpenFailed,
            ),
          ),
          SizedBox(height: sectionGap),
          _buildSectionTitle(
            context,
            typo,
            colors,
            LocaleKeys.settingsAboutOpenSource,
          ),
          SizedBox(height: descriptionGap),
          Text(
            context.t(LocaleKeys.settingsAboutOpenSourceDescription),
            style: _descriptionStyle(typo, colors),
          ),
          SizedBox(height: descriptionGap),
          Text(
            revericAttribution,
            style: _descriptionStyle(
              typo,
              colors,
            ).copyWith(color: colors.textPrimary),
          ),
          SizedBox(height: actionGap),
          _buildExternalLinkButton(
            colors,
            typo,
            label: revericGitHubRepoUrl,
            onTap: () => _openExternalUrl(
              context,
              Uri.parse(revericGitHubRepoUrl),
              LocaleKeys.settingsAboutOpenRepositoryFailed,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(
    BuildContext context,
    RevericTypography typo,
    RevericColors colors,
    String labelKey,
  ) {
    return Text(context.t(labelKey), style: _sectionTitleStyle(typo, colors));
  }

  TextStyle _sectionTitleStyle(RevericTypography typo, RevericColors colors) {
    if (compact) {
      return typo.uiSemibold.copyWith(color: colors.textPrimary);
    }
    return typo.heading2.copyWith(color: colors.textPrimary);
  }

  TextStyle _descriptionStyle(RevericTypography typo, RevericColors colors) {
    if (compact) {
      return typo.uiSmall.copyWith(color: colors.textSecondary, height: 1.5);
    }
    return typo.ui.copyWith(color: colors.textSecondary);
  }

  Widget _buildVersionRow(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.lg,
        vertical: RevericSpacing.md,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          RevericIcon(RevericIcons.info, size: 20, color: colors.textSecondary),
          const SizedBox(width: RevericSpacing.md),
          Text(
            context.t(LocaleKeys.settingsAboutVersion),
            style: typo.ui.copyWith(color: colors.textPrimary),
          ),
          const Spacer(),
          Text(
            'v$appVersion',
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateSection(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
    WidgetRef ref,
    AsyncValue<UpdateCheckResult?> updateResultAsync,
    UpdateProgress downloadState,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(
          context,
          typo,
          colors,
          LocaleKeys.settingsAboutUpdates,
        ),
        SizedBox(height: compact ? RevericSpacing.sm : RevericSpacing.md),
        Text(
          context.t(LocaleKeys.settingsAboutUpdatesDescription),
          style: _descriptionStyle(typo, colors),
        ),
        SizedBox(height: compact ? RevericSpacing.md : RevericSpacing.lg),
        _buildUpdateActions(
          context,
          colors,
          typo,
          ref,
          updateResultAsync,
          downloadState,
        ),
      ],
    );
  }

  Widget _buildUpdateActions(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
    WidgetRef ref,
    AsyncValue<UpdateCheckResult?> updateResultAsync,
    UpdateProgress downloadState,
  ) {
    if (downloadState.state == UpdateDownloadState.downloading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: downloadState.progress,
                  backgroundColor: colors.border,
                  valueColor: AlwaysStoppedAnimation(colors.accent),
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              Text(
                '${(downloadState.progress != null ? (downloadState.progress! * 100).toInt() : 0)}%',
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.sm),
          Row(
            children: [
              Text(
                context.t(LocaleKeys.settingsAboutDownloadingProgress),
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
              const Spacer(),
              TextButton(
                onPressed: () =>
                    ref.read(updateDownloadProvider.notifier).cancelDownload(),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.sm,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  context.t(LocaleKeys.commonCancel),
                  style: typo.uiSmall.copyWith(color: colors.error),
                ),
              ),
            ],
          ),
        ],
      );
    }

    if (downloadState.state == UpdateDownloadState.applying) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.accent,
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.settingsAboutApplyingUpdate),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
        ],
      );
    }

    if (downloadState.state == UpdateDownloadState.downloaded) {
      return Row(
        children: [
          FilledButton.icon(
            onPressed: () => ref
                .read(updateDownloadProvider.notifier)
                .applyUpdateAndRestart(),
            icon: const RevericIcon(
              RevericIcons.system_update_outlined,
              size: 16,
            ),
            label: Text(
              context.t(
                Platform.isAndroid
                    ? LocaleKeys.settingsAboutInstallUpdate
                    : LocaleKeys.settingsAboutRestartToUpdate,
              ),
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          TextButton(
            onPressed: () => ref.read(updateDownloadProvider.notifier).clear(),
            child: Text(context.t(LocaleKeys.commonCancel)),
          ),
        ],
      );
    }

    if (downloadState.error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(RevericSpacing.md),
            decoration: BoxDecoration(
              color: colors.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(RevericRadius.medium),
            ),
            child: Row(
              children: [
                RevericIcon(
                  RevericIcons.warning_circle,
                  size: 18,
                  color: colors.error,
                ),
                const SizedBox(width: RevericSpacing.sm),
                Expanded(
                  child: Text(
                    _formatUpdateError(context, downloadState.error!),
                    style: typo.uiSmall.copyWith(color: colors.error),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: RevericSpacing.md),
          _buildCheckButton(ref),
        ],
      );
    }

    return updateResultAsync.when(
      data: (result) {
        if (result == null) {
          return _buildCheckButton(ref);
        }

        return switch (result) {
          UpdateAvailable(info: var info) => _buildUpdateAvailable(
            context,
            colors,
            typo,
            ref,
            info,
          ),
          UpdateUpToDate() => Wrap(
            spacing: RevericSpacing.md,
            runSpacing: RevericSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildUpToDate(context, colors, typo),
              _buildCheckButton(ref),
            ],
          ),
          UpdateCheckFailed(error: var error) => _buildCheckFailed(
            context,
            colors,
            typo,
            ref,
            error,
          ),
        };
      },
      loading: () => Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.accent,
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.settingsAboutCheckingUpdates),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
        ],
      ),
      error: (err, _) =>
          _buildCheckFailed(context, colors, typo, ref, err.toString()),
    );
  }

  Widget _buildCheckButton(WidgetRef ref) {
    return HookBuilder(
      builder: (context) {
        final isChecking = useState(false);
        return RevericButton.secondary(
          label: context.t(LocaleKeys.settingsAboutCheckForUpdates),
          icon: RevericIcons.arrows_clockwise,
          loading: isChecking.value,
          onPressed: () async {
            isChecking.value = true;
            try {
              await ref
                  .read(latestReleaseProvider.notifier)
                  .refresh(force: true);
            } finally {
              if (context.mounted) {
                isChecking.value = false;
              }
            }
          },
        );
      },
    );
  }

  Widget _buildUpToDate(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
  ) {
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.md),
      decoration: BoxDecoration(
        color: colors.additionBg,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(
            RevericIcons.check_circle,
            size: 18,
            color: colors.additionBorder,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.settingsAboutUpToDate),
            style: typo.uiSmall.copyWith(color: colors.additionBorder),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateAvailable(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
    WidgetRef ref,
    UpdateInfo info,
  ) {
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RevericIcon(
                RevericIcons.system_update_outlined,
                size: 20,
                color: colors.accent,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.settingsAboutUpdateAvailable),
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            'v${info.version}',
            style: (compact ? typo.uiSemibold : typo.heading2).copyWith(
              color: colors.accent,
              fontSize: compact ? null : 18,
            ),
          ),
          if (info.fileSize != null) ...[
            const SizedBox(height: RevericSpacing.xs),
            Text(
              _formatFileSize(info.fileSize!),
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ],
          const SizedBox(height: RevericSpacing.lg),
          Wrap(
            spacing: RevericSpacing.sm,
            runSpacing: RevericSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () async {
                  await ref
                      .read(updateDownloadProvider.notifier)
                      .startDownload();
                },
                icon: const RevericIcon(
                  RevericIcons.download_outlined,
                  size: 16,
                ),
                label: Text(context.t(LocaleKeys.settingsAboutDownloadUpdate)),
              ),
              _buildCheckButton(ref),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCheckFailed(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
    WidgetRef ref,
    String error,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(RevericSpacing.md),
          decoration: BoxDecoration(
            color: colors.error.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(RevericRadius.medium),
          ),
          child: Row(
            children: [
              RevericIcon(
                RevericIcons.warning_circle,
                size: 18,
                color: colors.error,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Text(
                  _formatUpdateError(
                    context,
                    error,
                    fallbackKey: LocaleKeys.settingsAboutCheckFailed,
                  ),
                  style: typo.uiSmall.copyWith(color: colors.error),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: RevericSpacing.md),
        _buildCheckButton(ref),
      ],
    );
  }

  String _formatUpdateError(
    BuildContext context,
    String error, {
    String fallbackKey = LocaleKeys.settingsAboutUpdateApplyFailed,
  }) {
    if (error.startsWith('settings.')) {
      return context.t(error);
    }
    return context.t(fallbackKey);
  }

  Widget _buildOpenApplicationDirectoryButton(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
  ) {
    return InkWell(
      onTap: () async {
        final success = await LogManager.instance.openApplicationDirectory();
        if (!success && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: DialogToast(
                variant: DialogToastVariant.error,
                child: Text(
                  context.t(LocaleKeys.settingsAboutOpenStorageFailed),
                ),
              ),
            ),
          );
        }
      },
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.lg,
          vertical: RevericSpacing.md,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceDim,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          children: [
            RevericIcon(
              RevericIcons.folder_outlined,
              size: 20,
              color: colors.textSecondary,
            ),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Text(
                context.t(LocaleKeys.settingsAboutOpenLogs),
                style: typo.ui.copyWith(color: colors.textPrimary),
              ),
            ),
            RevericIcon(
              RevericIcons.chevron_right,
              size: 16,
              color: colors.textSubtle,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExternalLinkButton(
    RevericColors colors,
    RevericTypography typo, {
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.lg,
          vertical: RevericSpacing.md,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceDim,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          children: [
            RevericIcon(
              RevericIcons.arrow_square_out,
              size: 20,
              color: colors.textSecondary,
            ),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Text(
                label,
                style: typo.ui.copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openExternalUrl(
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

  String _formatFileSize(int bytes) {
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    } else if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}

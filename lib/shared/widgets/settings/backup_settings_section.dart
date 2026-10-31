// 职责: 共享备份设置区 — 配置变更记录保留、桌面自动备份计划、立即备份与恢复；移动端改走系统另存面板。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/desktop/widgets/settings/settings_backup_section.dart
//   lib/mobile/pages/settings_page.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/services/backup_service.dart
//   lib/shared/widgets/settings/backup_restore_page.dart
//   lib/shared/widgets/settings/webdav_backup_settings.dart
//   lib/shared/widgets/settings/webdav_restore_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../components/reveric_button.dart';
import '../../components/reveric_select.dart';
import '../../components/reveric_text_field.dart';
import '../../database/app_database.dart' as app_db;
import '../../database/novel_content_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../providers/video_tasks.dart';
import '../../providers/production_images.dart';
import '../../providers/settings_providers.dart';
import '../../providers/webdav_backup_providers.dart';
import '../../services/backup_orchestrator.dart';
import '../../services/backup_service.dart';
import '../../theme/theme.dart';
import 'backup_restore_page.dart';
import 'webdav_backup_settings.dart';
import 'webdav_restore_page.dart';
import '../../components/reveric_dialog.dart';

final _log = AppLogger.forModule('Backup');

/// 备份配置区（变更记录保留 + 备份）。
class BackupSettingsSection extends HookConsumerWidget {
  const BackupSettingsSection({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final settingsAsync = ref.watch(appSettingsNotifierProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final backupService = ref.read(backupServiceProvider);

    final isBackingUp = useState(false);
    final isRestoring = useState(false);
    final backupMessage = useState<String?>(null);
    final backupError = useState<bool>(false);
    final pendingRestore = useState<_PendingRestore?>(null);
    final showWebDavRestore = useState(false);
    useEffect(() {
      return () {
        final pending = pendingRestore.value;
        if (pending != null) {
          unawaited(_deleteTemporaryRestore(pending));
        }
      };
    }, <Object?>[pendingRestore]);
    final restoreFeedback = _RestoreFeedback(
      isRestoring: isRestoring,
      message: backupMessage,
      isError: backupError,
    );

    final retentionController = useTextEditingController(text: '30');
    final settings = settingsAsync.asData?.value;
    final canRestoreWebDav = settings?.webDavBackupConfig.isConfigured == true;

    useEffect(() {
      if (settings != null) {
        retentionController.text = settings.changeRecordRetentionDays
            .toString();
      }
      return null;
    }, [settings?.changeRecordRetentionDays]);

    final sectionGap = compact ? RevericSpacing.x2l : RevericSpacing.x3l;
    final blockGap = compact ? RevericSpacing.xl : RevericSpacing.x2l;
    final descriptionGap = compact ? RevericSpacing.xs : RevericSpacing.sm;
    final supportsCustomDirectory = backupSupportsCustomDirectory();

    final restore = pendingRestore.value;
    if (restore != null) {
      return BackupRestorePage(
        preview: restore.preview,
        compact: compact,
        isRestoring: isRestoring.value,
        onBack: () {
          unawaited(_deleteTemporaryRestore(restore));
          pendingRestore.value = null;
        },
        onRestore: (selection) => _applyRestore(
          context,
          backupService,
          _RestoreExecution(pending: restore, selection: selection),
          restoreFeedback,
          pendingRestore,
        ),
      );
    }

    if (showWebDavRestore.value && settings != null) {
      return WebDavRestorePage(
        config: settings.webDavBackupConfig,
        service: ref.read(webDavBackupServiceProvider),
        compact: compact,
        onBack: () => showWebDavRestore.value = false,
        onDownloaded: (localPath) => _prepareDownloadedRestore(
          context,
          backupService,
          localPath,
          restoreFeedback,
          pendingRestore,
          showWebDavRestore,
        ),
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.all(
        compact ? RevericSpacing.x3l : RevericSpacing.x4l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.t(LocaleKeys.settingsBackup),
            style: _pageTitleStyle(typo, colors),
          ),
          SizedBox(height: descriptionGap),
          Text(
            context.t(LocaleKeys.settingsBackupPageDescription),
            style: _descriptionStyle(typo, colors),
          ),
          SizedBox(height: blockGap),
          _buildRetentionSection(
            context: context,
            retentionDays: settings?.changeRecordRetentionDays ?? 30,
            controller: retentionController,
            onChanged: (days) async {
              await notifier.setChangeRecordRetentionDays(days);
            },
          ),
          SizedBox(height: sectionGap),
          Text(
            context.t(LocaleKeys.settingsBackupSection),
            style: _sectionTitleStyle(typo, colors),
          ),
          SizedBox(height: descriptionGap),
          Text(
            context.t(
              supportsCustomDirectory
                  ? LocaleKeys.settingsBackupDescription
                  : LocaleKeys.settingsBackupDescriptionNativeSave,
            ),
            style: _descriptionStyle(typo, colors),
          ),
          SizedBox(height: blockGap),
          if (supportsCustomDirectory) ...[
            _buildSectionHeader(
              context: context,
              titleKey: LocaleKeys.settingsBackupDirectory,
              descriptionKey: LocaleKeys.settingsBackupDirectoryHint,
            ),
            const SizedBox(height: RevericSpacing.md),
            settingsAsync.when(
              data: (settings) => _buildDirectoryPicker(
                context: context,
                directory: settings.backupDirectory,
                onPick: () => _pickDirectory(notifier),
              ),
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),
            SizedBox(height: blockGap),
            settingsAsync.when(
              data: (settings) => _buildBackupScheduleSettings(
                context: context,
                settings: settings,
                notifier: notifier,
              ),
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),
          ] else
            _buildSectionHeader(
              context: context,
              titleKey: LocaleKeys.settingsBackupNativeSaveTitle,
              descriptionKey: LocaleKeys.settingsBackupNativeSaveHint,
            ),
          SizedBox(height: sectionGap),
          if (settings != null)
            WebDavBackupSettings(
              config: settings.webDavBackupConfig,
              compact: compact,
            ),
          SizedBox(height: blockGap),
          settingsAsync.when(
            data: (settings) => _buildLastBackupInfo(
              context: context,
              lastBackup: settings.lastBackupTime,
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          SizedBox(height: compact ? RevericSpacing.md : RevericSpacing.lg),
          Wrap(
            key: const ValueKey('backup_action_buttons'),
            spacing: RevericSpacing.md,
            runSpacing: RevericSpacing.md,
            children: [
              _buildBackupNowButton(
                context: context,
                isBackingUp: isBackingUp.value,
                isRestoring: isRestoring.value,
                canBackup:
                    settings != null &&
                    (!supportsCustomDirectory ||
                        settings.backupDirectory.isNotEmpty),
                onTap: () => _performBackup(
                  context,
                  ref,
                  notifier,
                  isBackingUp,
                  backupMessage,
                  backupError,
                ),
              ),
              Wrap(
                spacing: RevericSpacing.md,
                runSpacing: RevericSpacing.md,
                children: [
                  _buildRestoreButton(
                    context: context,
                    isRestoring: isRestoring.value,
                    isBackingUp: isBackingUp.value,
                    onTap: () => _prepareRestore(
                      context,
                      backupService,
                      restoreFeedback,
                      pendingRestore,
                    ),
                  ),
                  if (canRestoreWebDav)
                    _buildRestoreButton(
                      context: context,
                      isRestoring: isRestoring.value,
                      isBackingUp: isBackingUp.value,
                      webDav: true,
                      onTap: () {
                        backupMessage.value = null;
                        showWebDavRestore.value = true;
                      },
                    ),
                ],
              ),
            ],
          ),
          if (backupMessage.value != null) ...[
            const SizedBox(height: RevericSpacing.md),
            _buildMessageBanner(
              context: context,
              message: backupMessage.value!,
              isError: backupError.value,
            ),
          ],
        ],
      ),
    );
  }

  TextStyle _pageTitleStyle(RevericTypography typo, RevericColors colors) {
    if (compact) {
      return typo.uiSemibold.copyWith(color: colors.textPrimary);
    }
    return typo.heading2.copyWith(color: colors.textPrimary);
  }

  TextStyle _sectionTitleStyle(RevericTypography typo, RevericColors colors) {
    if (compact) {
      return typo.uiSemibold.copyWith(color: colors.textPrimary);
    }
    return typo.heading2.copyWith(color: colors.textPrimary);
  }

  TextStyle _descriptionStyle(RevericTypography typo, RevericColors colors) {
    if (compact) {
      return typo.uiSmall.copyWith(color: colors.textMuted, height: 1.5);
    }
    return typo.ui.copyWith(color: colors.textMuted);
  }

  Widget _buildRetentionSection({
    required BuildContext context,
    required int retentionDays,
    required TextEditingController controller,
    required ValueChanged<int> onChanged,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.settingsChangeRecordRetention),
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: RevericSpacing.md),
        SizedBox(
          width: 160,
          child: RevericTextField(
            key: const ValueKey('change_record_retention_days_field'),
            fieldKey: const ValueKey('change_record_retention_days_input'),
            controller: controller,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            fillColor: colors.surface,
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: RevericSpacing.lg),
              child: Center(
                widthFactor: 1,
                child: Text(
                  context.t(LocaleKeys.settingsChangeRecordRetentionDays),
                  style: typo.ui.copyWith(color: colors.textMuted),
                ),
              ),
            ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 0,
              minHeight: RevericSizes.fieldHeight,
            ),
            onSubmitted: (value) {
              final days = int.tryParse(value.trim());
              if (days != null) {
                final normalized = days.clamp(7, 365);
                controller.text = normalized.toString();
                onChanged(normalized);
              } else {
                controller.text = retentionDays.toString();
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader({
    required BuildContext context,
    required String titleKey,
    required String descriptionKey,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(titleKey),
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        if (descriptionKey.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.xs),
          Text(
            context.t(descriptionKey),
            style: typo.ui.copyWith(color: colors.textMuted),
          ),
        ],
      ],
    );
  }

  Widget _buildDirectoryPicker({
    required BuildContext context,
    required String directory,
    required VoidCallback onPick,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      constraints: const BoxConstraints(minHeight: RevericSizes.buttonHeight),
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.borderInput),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              directory.isEmpty
                  ? context.t(LocaleKeys.settingsBackupDirectoryHint)
                  : directory,
              style: typo.ui.copyWith(
                color: directory.isEmpty
                    ? colors.textMuted
                    : colors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: RevericSpacing.md),
          RevericButton.text(
            onPressed: onPick,
            label: context.t(LocaleKeys.settingsBackupSelectDirectory),
          ),
        ],
      ),
    );
  }

  Widget _buildFrequencySelector({
    required BuildContext context,
    required BackupFrequency frequency,
    required ValueChanged<BackupFrequency> onChanged,
  }) {
    return RevericSelect<BackupFrequency>(
      key: const ValueKey('backup_frequency_field'),
      label: context.t(LocaleKeys.settingsBackupFrequency),
      value: frequency,
      items: [
        for (final f in BackupFrequency.values)
          RevericSelectItem<BackupFrequency>(
            value: f,
            label: _frequencyLabel(context, f),
          ),
      ],
      onChanged: onChanged,
    );
  }

  Widget _buildBackupScheduleSettings({
    required BuildContext context,
    required AppSettings settings,
    required AppSettingsNotifier notifier,
  }) {
    final automatic = settings.backupFrequency != BackupFrequency.manual;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFrequencySelector(
          context: context,
          frequency: settings.backupFrequency,
          onChanged: notifier.setBackupFrequency,
        ),
        if (automatic) ...[
          const SizedBox(height: RevericSpacing.md),
          if (settings.backupFrequency == BackupFrequency.weekly) ...[
            _buildWeekdaySelector(
              context: context,
              weekdays: settings.backupWeekdays,
              onChanged: notifier.setBackupWeekdays,
            ),
            const SizedBox(height: RevericSpacing.md),
          ],
          if (settings.backupFrequency == BackupFrequency.monthly) ...[
            _buildDayOfMonthSelector(
              context: context,
              day: settings.backupDayOfMonth,
              onChanged: notifier.setBackupDayOfMonth,
            ),
            const SizedBox(height: RevericSpacing.md),
          ],
          _buildTimeSelector(
            context: context,
            hour: settings.backupHour,
            minute: settings.backupMinute,
            notifier: notifier,
          ),
        ],
      ],
    );
  }

  Widget _buildDayOfMonthSelector({
    required BuildContext context,
    required int day,
    required ValueChanged<int> onChanged,
  }) {
    return RevericSelect<int>(
      key: const ValueKey('backup_day_of_month_field'),
      label: context.t(LocaleKeys.settingsBackupDayOfMonth),
      value: day,
      items: [
        for (var value = 1; value <= 28; value += 1)
          RevericSelectItem<int>(value: value, label: value.toString()),
      ],
      onChanged: onChanged,
    );
  }

  Widget _buildWeekdaySelector({
    required BuildContext context,
    required List<int> weekdays,
    required ValueChanged<List<int>> onChanged,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final selected = weekdays.toSet();
    return Column(
      key: const ValueKey('backup_weekdays_field'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.settingsBackupWeekdays),
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: RevericSpacing.xs),
        Wrap(
          spacing: RevericSpacing.sm,
          runSpacing: RevericSpacing.sm,
          children: [
            for (
              var weekday = DateTime.monday;
              weekday <= DateTime.sunday;
              weekday += 1
            )
              FilterChip(
                selected: selected.contains(weekday),
                label: Text(_weekdayLabel(context, weekday)),
                onSelected: (isSelected) {
                  final next = selected.toSet();
                  if (isSelected) {
                    next.add(weekday);
                  } else if (next.length > 1) {
                    next.remove(weekday);
                  } else {
                    return;
                  }
                  final sorted = next.toList()..sort();
                  onChanged(sorted);
                },
                selectedColor: colors.selected,
                backgroundColor: colors.surfaceContainerHigh,
                checkmarkColor: colors.accent,
                labelStyle: typo.uiSmall.copyWith(
                  color: selected.contains(weekday)
                      ? colors.textPrimary
                      : colors.textSecondary,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.pill),
                  side: BorderSide(
                    color: selected.contains(weekday)
                        ? colors.accent
                        : colors.borderSubtle,
                  ),
                ),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildTimeSelector({
    required BuildContext context,
    required int hour,
    required int minute,
    required AppSettingsNotifier notifier,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.settingsBackupTime),
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: RevericSpacing.xs),
        Row(
          children: [
            Expanded(
              child: RevericSelect<int>(
                key: const ValueKey('backup_hour_field'),
                value: hour,
                items: [
                  for (var value = 0; value < 24; value += 1)
                    RevericSelectItem<int>(
                      value: value,
                      label: value.toString().padLeft(2, '0'),
                    ),
                ],
                onChanged: (value) {
                  notifier.setBackupTime(hour: value, minute: minute);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.sm,
              ),
              child: Text(
                ':',
                style: typo.uiSemibold.copyWith(color: colors.textMuted),
              ),
            ),
            Expanded(
              child: RevericSelect<int>(
                key: const ValueKey('backup_minute_field'),
                value: minute,
                items: [
                  for (var value = 0; value < 60; value += 1)
                    RevericSelectItem<int>(
                      value: value,
                      label: value.toString().padLeft(2, '0'),
                    ),
                ],
                onChanged: (value) {
                  notifier.setBackupTime(hour: hour, minute: value);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLastBackupInfo({
    required BuildContext context,
    required DateTime? lastBackup,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Row(
        children: [
          RevericIcon(
            RevericIcons.schedule_outlined,
            size: 18,
            color: colors.textMuted,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Text(
            '${context.t(LocaleKeys.settingsBackupLastBackup)}: ',
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
          Flexible(
            child: Text(
              lastBackup != null
                  ? DateFormat('yyyy-MM-dd HH:mm').format(lastBackup)
                  : context.t(LocaleKeys.settingsBackupNever),
              style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackupNowButton({
    required BuildContext context,
    required bool isBackingUp,
    required bool isRestoring,
    required bool canBackup,
    required VoidCallback onTap,
  }) {
    return RevericButton.primary(
      onPressed: (isBackingUp || isRestoring || !canBackup) ? null : onTap,
      loading: isBackingUp,
      icon: RevericIcons.download,
      label: context.t(LocaleKeys.settingsBackupNow),
    );
  }

  Widget _buildRestoreButton({
    required BuildContext context,
    required bool isRestoring,
    required bool isBackingUp,
    required VoidCallback onTap,
    bool webDav = false,
  }) {
    return RevericButton.secondary(
      key: ValueKey(webDav ? 'webdav_restore_button' : 'file_restore_button'),
      onPressed: (isRestoring || isBackingUp) ? null : onTap,
      loading: isRestoring,
      icon: webDav ? RevericIcons.download : RevericIcons.upload,
      label: context.t(
        webDav
            ? LocaleKeys.settingsWebDavRestore
            : LocaleKeys.settingsBackupRestore,
      ),
    );
  }

  Widget _buildMessageBanner({
    required BuildContext context,
    required String message,
    required bool isError,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final accent = isError ? colors.deletionBorder : colors.additionBorder;

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.md),
      decoration: BoxDecoration(
        color: isError ? colors.deletionBg : colors.additionBg,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
      child: Row(
        children: [
          RevericIcon(
            isError ? RevericIcons.error_outline : RevericIcons.check_circle,
            color: accent,
            size: 18,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(message, style: typo.uiSmall.copyWith(color: accent)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDirectory(AppSettingsNotifier notifier) async {
    final result = await getDirectoryPath();
    if (result != null) {
      await notifier.setBackupDirectory(result);
    }
  }

  Future<void> _performBackup(
    BuildContext context,
    WidgetRef ref,
    AppSettingsNotifier notifier,
    ValueNotifier<bool> isBackingUp,
    ValueNotifier<String?> message,
    ValueNotifier<bool> isError,
  ) async {
    _log.info('_performBackup started');
    isBackingUp.value = true;
    message.value = null;
    final supportsCustomDirectory = backupSupportsCustomDirectory();
    final successMessage = context.t(LocaleKeys.settingsBackupSuccess);
    final failureMessage = context.t(LocaleKeys.settingsBackupFailed);
    final directoryFailureMessage = context.t(
      LocaleKeys.settingsBackupFailedDirectoryUnavailable,
    );
    final windowsPathFailureMessage = context.t(
      LocaleKeys.settingsBackupFailedWindowsPathUnsupported,
    );
    final databaseFailureMessage = context.t(
      LocaleKeys.settingsBackupFailedDatabaseUnreadable,
    );
    final webDavFailureMessage = context.t(
      LocaleKeys.settingsBackupFailedWebDav,
    );

    final settings = ref.read(appSettingsProvider).asData?.value;
    if (settings == null) {
      isBackingUp.value = false;
      return;
    }

    _log.info(
      'Calling BackupOrchestrator, '
      'supportsCustomDirectory=$supportsCustomDirectory',
    );
    final stopwatch = Stopwatch()..start();
    final orchestrator = BackupOrchestrator(
      backupService: ref.read(backupServiceProvider),
      webDavBackupService: ref.read(webDavBackupServiceProvider),
    );
    final result = supportsCustomDirectory
        ? await orchestrator.createBackup(
            outputDirectory: settings.backupDirectory,
            webDavConfig: settings.webDavBackupConfig,
          )
        : await orchestrator.createTemporaryBackup(
            webDavConfig: settings.webDavBackupConfig,
          );
    stopwatch.stop();
    _log.info(
      'createBackup completed in ${stopwatch.elapsedMilliseconds}ms, '
      'success=${result.success}, failureReason=${result.failureReason}',
    );
    if (result.success) {
      if (!context.mounted) return;
      final successBanner = result.hasWarnings
          ? context.t(
              LocaleKeys.settingsBackupSuccessWithWarnings,
              namedArgs: {'count': result.warnings.length.toString()},
            )
          : successMessage;
      if (!supportsCustomDirectory) {
        // 移动端把生成好的 zip 交给系统另存面板，和作品导出一致。
        // Android 只有在系统回报了所选组件时才算 success，自定义 ROM 的分享面板
        // 通常不回报，所以这里不判断 share 结果，否则会把已保存误报成未保存。
        await _shareBackupFile(result.backupPath!);
      }
      await notifier.setLastBackupTime(DateTime.now());
      if (!context.mounted) return;
      message.value = successBanner;
      isError.value = false;
    } else {
      message.value = _backupFailureMessage(
        result.failureReason,
        fallback: failureMessage,
        directoryFailureMessage: directoryFailureMessage,
        windowsPathFailureMessage: windowsPathFailureMessage,
        databaseFailureMessage: databaseFailureMessage,
        webDavFailureMessage: webDavFailureMessage,
      );
      isError.value = true;
    }
    isBackingUp.value = false;
  }

  /// 通过系统另存/分享面板导出备份文件。
  ///
  /// 不返回是否保存成功：Android 只有在系统回报所选组件时才算 success，很多定制
  /// ROM 的分享面板不回报，`dismissed` 并不代表用户取消，据此判断会误报。
  Future<void> _shareBackupFile(String zipPath) async {
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(zipPath, mimeType: 'application/zip')],
          fileNameOverrides: [File(zipPath).uri.pathSegments.last],
        ),
      );
      _log.info('Save-a-copy sheet closed: ${result.status}');
    } catch (error, stackTrace) {
      _log.error(
        'Save-a-copy failed path=$zipPath',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _prepareDownloadedRestore(
    BuildContext context,
    BackupService backupService,
    String localPath,
    _RestoreFeedback feedback,
    ValueNotifier<_PendingRestore?> pendingRestore,
    ValueNotifier<bool> showWebDavRestore,
  ) async {
    feedback.start();
    try {
      final inspection = await backupService.inspectBackup(localPath);
      if (!context.mounted) {
        await _deleteFileIfPresent(localPath);
        return;
      }
      final preview = inspection.preview;
      if (!inspection.success || preview == null) {
        await _deleteFileIfPresent(localPath);
        if (!context.mounted) return;
        feedback.showError(
          _restoreFailureMessage(context, inspection.failureReason),
        );
        return;
      }
      showWebDavRestore.value = false;
      pendingRestore.value = _PendingRestore(
        filePath: localPath,
        preview: preview,
        temporary: true,
      );
    } finally {
      if (context.mounted) {
        feedback.stop();
      }
    }
  }

  Future<void> _prepareRestore(
    BuildContext context,
    BackupService backupService,
    _RestoreFeedback feedback,
    ValueNotifier<_PendingRestore?> pendingRestore,
  ) async {
    XFile? selectedFile;
    try {
      selectedFile = await openFile(
        acceptedTypeGroups: [
          // iOS 要求 type group 提供 UTI，否则 file_selector 抛 Invalid argument。
          const XTypeGroup(
            label: 'archives',
            extensions: ['zip'],
            uniformTypeIdentifiers: ['public.zip-archive'],
          ),
        ],
      );
    } catch (error, stackTrace) {
      _log.error(
        'Restore file selection failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!context.mounted) {
        return;
      }
      feedback.showError(context.t(LocaleKeys.settingsBackupRestoreFailed));
      return;
    }
    if (selectedFile == null || !context.mounted) {
      return;
    }

    feedback.start();
    try {
      final inspection = await backupService.inspectBackup(selectedFile.path);
      if (!context.mounted) {
        return;
      }
      final preview = inspection.preview;
      if (!inspection.success || preview == null) {
        feedback.showError(
          _restoreFailureMessage(context, inspection.failureReason),
        );
        return;
      }
      pendingRestore.value = _PendingRestore(
        filePath: selectedFile.path,
        preview: preview,
      );
    } finally {
      if (context.mounted) {
        feedback.stop();
      }
    }
  }

  Future<void> _applyRestore(
    BuildContext context,
    BackupService backupService,
    _RestoreExecution execution,
    _RestoreFeedback feedback,
    ValueNotifier<_PendingRestore?> pendingRestore,
  ) async {
    feedback.start();
    try {
      final restoreResult = await backupService.restoreFromZip(
        execution.pending.filePath,
        mode: execution.selection.mode,
        novelIds: execution.selection.novelIds,
        onBeforeFileRestore: () async {
          final mode = execution.selection.mode;
          _log.info('Restore: closing database executors mode=${mode.name}');
          if (mode == RestoreMode.fullReplacement) {
            final container = ProviderScope.containerOf(context, listen: false);
            if (container.exists(videoTaskServiceProvider)) {
              await (await container.read(
                videoTaskServiceProvider.future,
              )).shutdown();
            }
            if (container.exists(imageTaskServiceProvider)) {
              await container.read(imageTaskServiceProvider).shutdown();
            }
            await app_db.AppDatabase.closeCachedForFileReplacement();
            _log.info('Restore: main database executor closed');
          }
          await NovelContentDatabase.closeAllCachedForFileReplacement();
          _log.info('Restore: content database executors closed');
        },
      );
      if (!context.mounted) {
        return;
      }
      pendingRestore.value = null;
      if (restoreResult.cancelled) {
        return;
      }
      if (restoreResult.success) {
        feedback.showSuccess(
          context.t(LocaleKeys.settingsBackupRestoreSuccess),
        );
        // 移动端设置页很长，底部 banner 容易被忽略，而恢复后数据库文件已被替换，
        // 继续用旧进程操作会读到不一致的状态，因此用不可取消的弹窗强提示重启。
        if (_usesRestartDialog()) {
          await _showRestartRequiredDialog(context);
        }
      } else {
        feedback.showError(
          _restoreFailureMessage(
            context,
            restoreResult.failureReason,
            safetyBackupPath: restoreResult.safetyBackupPath,
            needsRestart: restoreResult.needsRestart,
          ),
        );
      }
    } finally {
      await _deleteTemporaryRestore(execution.pending);
      if (context.mounted) {
        feedback.stop();
      }
    }
  }

  /// 恢复成功后是否用弹窗强提示重启。
  ///
  /// 与 [backupSupportsCustomDirectory] 共用 `defaultTargetPlatform`，避免同一文件里
  /// 出现两套「是否移动端」的判定在测试中互相矛盾。
  bool _usesRestartDialog() {
    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
  }

  /// 恢复后数据库文件已被替换，必须重启进程才能读到一致的数据。
  ///
  /// 弹窗不可通过点击遮罩或返回键关闭，只能通过按钮离开，避免用户忽略后继续写入。
  Future<void> _showRestartRequiredDialog(BuildContext context) async {
    final colors = RevericTheme.colorsOf(context);
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;

    await showRevericDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: RevericDialog(
            key: const ValueKey('backup_restore_restart_dialog'),
            title: context.t(LocaleKeys.settingsBackupRestoreRestartTitle),
            leading: RevericIcon(
              RevericIcons.error_outline,
              color: colors.accent,
              size: 28,
            ),
            content: Text(
              context.t(LocaleKeys.settingsBackupRestoreRestartMessage),
            ),
            actions: [
              RevericButton.primary(
                key: const ValueKey('backup_restore_restart_action'),
                onPressed: () {
                  if (isAndroid) {
                    // Android 允许应用主动退出，用户重新打开即为干净进程。
                    SystemNavigator.pop();
                    return;
                  }
                  Navigator.of(dialogContext).pop();
                },
                label: context.t(
                  isAndroid
                      ? LocaleKeys.settingsBackupRestoreRestartExit
                      : LocaleKeys.settingsBackupRestoreRestartAcknowledge,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _restoreFailureMessage(
    BuildContext context,
    RestoreFailureReason? reason, {
    String? safetyBackupPath,
    bool needsRestart = false,
  }) {
    return switch (reason) {
      RestoreFailureReason.unsupportedBackup => context.t(
        LocaleKeys.settingsBackupRestoreFailedUnsupported,
      ),
      RestoreFailureReason.safetyBackupFailed => context.t(
        LocaleKeys.settingsBackupRestoreFailedSafetyBackup,
      ),
      RestoreFailureReason.novelTitleConflict => context.t(
        LocaleKeys.settingsBackupRestoreFailedTitleConflict,
      ),
      RestoreFailureReason.rollbackFailed => context.t(
        LocaleKeys.settingsBackupRestoreFailedRollback,
        namedArgs: {'path': safetyBackupPath ?? ''},
      ),
      RestoreFailureReason.applyFailed when needsRestart => context.t(
        LocaleKeys.settingsBackupRestoreFailedRolledBack,
      ),
      RestoreFailureReason.fileNotFound ||
      RestoreFailureReason.invalidBackup ||
      RestoreFailureReason.noNovelsSelected => context.t(
        LocaleKeys.settingsBackupRestoreInvalid,
      ),
      RestoreFailureReason.applyFailed ||
      null => context.t(LocaleKeys.settingsBackupRestoreFailed),
    };
  }

  String _frequencyLabel(BuildContext context, BackupFrequency f) {
    return switch (f) {
      BackupFrequency.manual => context.t(
        LocaleKeys.settingsBackupFrequencyManual,
      ),
      BackupFrequency.daily => context.t(
        LocaleKeys.settingsBackupFrequencyDaily,
      ),
      BackupFrequency.weekly => context.t(
        LocaleKeys.settingsBackupFrequencyWeekly,
      ),
      BackupFrequency.monthly => context.t(
        LocaleKeys.settingsBackupFrequencyMonthly,
      ),
    };
  }

  String _weekdayLabel(BuildContext context, int weekday) {
    final key = switch (weekday) {
      DateTime.tuesday => LocaleKeys.settingsBackupWeekdayTuesday,
      DateTime.wednesday => LocaleKeys.settingsBackupWeekdayWednesday,
      DateTime.thursday => LocaleKeys.settingsBackupWeekdayThursday,
      DateTime.friday => LocaleKeys.settingsBackupWeekdayFriday,
      DateTime.saturday => LocaleKeys.settingsBackupWeekdaySaturday,
      DateTime.sunday => LocaleKeys.settingsBackupWeekdaySunday,
      _ => LocaleKeys.settingsBackupWeekdayMonday,
    };
    return context.t(key);
  }

  String _backupFailureMessage(
    BackupFailureReason? reason, {
    required String fallback,
    required String directoryFailureMessage,
    required String windowsPathFailureMessage,
    required String databaseFailureMessage,
    required String webDavFailureMessage,
  }) {
    return switch (reason) {
      BackupFailureReason.outputDirectoryUnavailable => directoryFailureMessage,
      BackupFailureReason.sqlitePathUnsupportedOnWindows =>
        windowsPathFailureMessage,
      BackupFailureReason.sqliteUnreadable => databaseFailureMessage,
      BackupFailureReason.webDavUploadFailed => webDavFailureMessage,
      BackupFailureReason.unknown || null => fallback,
    };
  }
}

class _PendingRestore {
  const _PendingRestore({
    required this.filePath,
    required this.preview,
    this.temporary = false,
  });

  final String filePath;
  final BackupRestorePreview preview;
  final bool temporary;
}

Future<void> _deleteTemporaryRestore(_PendingRestore pending) {
  if (!pending.temporary) return Future<void>.value();
  return _deleteFileIfPresent(pending.filePath);
}

Future<void> _deleteFileIfPresent(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  } catch (error, stackTrace) {
    _log.error(
      'Failed to delete temporary restore file',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

class _RestoreExecution {
  const _RestoreExecution({required this.pending, required this.selection});

  final _PendingRestore pending;
  final BackupRestoreSelection selection;
}

class _RestoreFeedback {
  const _RestoreFeedback({
    required this.isRestoring,
    required this.message,
    required this.isError,
  });

  final ValueNotifier<bool> isRestoring;
  final ValueNotifier<String?> message;
  final ValueNotifier<bool> isError;

  void start() {
    isRestoring.value = true;
    message.value = null;
  }

  void stop() {
    isRestoring.value = false;
  }

  void showSuccess(String value) {
    message.value = value;
    isError.value = false;
  }

  void showError(String value) {
    message.value = value;
    isError.value = true;
  }
}

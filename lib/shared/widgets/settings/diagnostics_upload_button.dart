// 职责: 确认并上传当前日志及崩溃记录，展示上传结果。
// 关联文件:
//   lib/shared/services/diagnostics_upload_orchestrator.dart
//   lib/shared/providers/upload_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_dialog.dart';
import '../../components/dialog_feedback.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/log_manager.dart';
import '../../logger/app_logger.dart';
import '../../providers/upload_providers.dart';
import '../../services/diagnostics_upload_orchestrator.dart';

final _log = AppLogger.forModule('DiagnosticsUploadButton');

class DiagnosticsUploadButton extends HookConsumerWidget {
  const DiagnosticsUploadButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = useState(false);
    return RevericButton.secondary(
      label: context.t(
        busy.value
            ? LocaleKeys.settingsAboutUploadingLogs
            : LocaleKeys.settingsAboutUploadLogs,
      ),
      loading: busy.value,
      onPressed: () async {
        if (busy.value) {
          return;
        }
        final confirmed = await showRevericDialog<bool>(
          context: context,
          builder: (dialogContext) => RevericDialog.panel(
            title: Text(
              context.t(LocaleKeys.settingsAboutUploadLogsConfirmTitle),
            ),
            content: Text(
              context.t(LocaleKeys.settingsAboutUploadLogsConfirmDescription),
            ),
            actions: [
              RevericButton.secondary(
                label: context.t(LocaleKeys.commonCancel),
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              RevericButton.primary(
                label: context.t(LocaleKeys.settingsAboutUploadLogs),
                onPressed: () => Navigator.of(dialogContext).pop(true),
              ),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) {
          return;
        }
        busy.value = true;
        var success = false;
        try {
          final path = LogManager.instance.logFilePath;
          if (path == null) {
            throw StateError('Log path is unavailable');
          }
          final result = await DiagnosticsUploadOrchestrator().upload(
            logPath: path,
            uploadService: ref.read(anonymousUploadServiceProvider),
          );
          success = result.success;
        } catch (error, stackTrace) {
          _log.error(
            'Upload logs failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
        if (!context.mounted) {
          return;
        }
        busy.value = false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: DialogToast(
              variant: success
                  ? DialogToastVariant.success
                  : DialogToastVariant.error,
              child: Text(
                context.t(
                  success
                      ? LocaleKeys.settingsAboutUploadLogsSuccess
                      : LocaleKeys.settingsAboutUploadLogsFailed,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

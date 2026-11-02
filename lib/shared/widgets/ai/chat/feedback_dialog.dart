// 职责: 展示聊天诊断上传确认，并提交问题描述与当前会话记录。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/upload_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/i18n.md
//   .agents/rules/error-handling.md
import 'dart:io';
import 'dart:convert';
import '../../../providers/upload_providers.dart';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:reveric/shared/app_config.dart' show appVersion;
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/logger/app_logger.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import '../../../components/dialog_feedback.dart';
import '../../../components/reveric_dialog.dart';
import '../../../components/reveric_button.dart';
import '../../../components/reveric_text_field.dart';

final _log = AppLogger.forModule('AiChatFeedback');

Future<void> showAiChatFeedbackDialog({
  required BuildContext context,
  required WidgetRef ref,
  required AiChatSessionState sessionState,
  required String? novelId,
  required String? databasePath,
}) async {
  final uploaded = await showRevericDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return _AiChatFeedbackDialog(
        dialogContext: dialogContext,
        loadContext: () => _loadFeedbackContext(
          ref: ref,
          sessionState: sessionState,
          novelId: novelId,
          databasePath: databasePath,
        ),
        ref: ref,
      );
    },
  );
  if (uploaded != true || !context.mounted) {
    return;
  }
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: DialogToast(
            variant: DialogToastVariant.success,
            child: Text(context.t(LocaleKeys.aiFeedbackSuccess)),
          ),
        ),
      );
  });
}

class _AiChatFeedbackDialog extends StatefulWidget {
  const _AiChatFeedbackDialog({
    required this.dialogContext,
    required this.loadContext,
    required this.ref,
  });

  final BuildContext dialogContext;
  final Future<Map<String, dynamic>> Function() loadContext;
  final WidgetRef ref;

  @override
  State<_AiChatFeedbackDialog> createState() => _AiChatFeedbackDialogState();
}

class _AiChatFeedbackDialogState extends State<_AiChatFeedbackDialog> {
  late final TextEditingController _descriptionController;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    _descriptionController = TextEditingController();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _upload() async {
    if (_isUploading) {
      return;
    }
    setState(() => _isUploading = true);
    try {
      final service = widget.ref.read(anonymousUploadServiceProvider);
      final payload = {
        ...await widget.loadContext(),
        'description': _descriptionController.text.trim(),
        'app_version': appVersion,
        'platform': Platform.operatingSystem,
      };
      await service.upload(
        namespace: 'diagnostics',
        fileBytes: utf8.encode(jsonEncode(payload)),
        contentType: 'application/json',
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error, stackTrace) {
      _log.error(
        'Upload feedback failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _showToast(
          context.t(LocaleKeys.aiFeedbackFailed),
          DialogToastVariant.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  void _showToast(String message, DialogToastVariant variant) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: DialogToast(variant: variant, child: Text(message)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final dialogWidth =
        MediaQuery.sizeOf(context).width.clamp(280.0, 400.0) - 48;

    return RevericDialog.panel(
      title: Text(context.t(LocaleKeys.aiFeedbackTitle)),
      content: SizedBox(
        width: dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.t(LocaleKeys.aiFeedbackDescription),
              style: typo.body.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: RevericSpacing.lg),
            RevericTextField(
              controller: _descriptionController,
              enabled: !_isUploading,
              multiline: true,
              minLines: 3,
              maxLines: 6,
              hintText: context.t(LocaleKeys.aiFeedbackPlaceholder),
            ),
          ],
        ),
      ),
      width: dialogWidth + RevericSpacing.x4l * 2,
      actions: [
        RevericButton.secondary(
          label: context.t(LocaleKeys.commonCancel),
          onPressed: _isUploading
              ? null
              : () => Navigator.of(widget.dialogContext).pop(),
        ),
        RevericButton.primary(
          label: context.t(
            _isUploading
                ? LocaleKeys.aiFeedbackUploading
                : LocaleKeys.aiFeedbackUpload,
          ),
          loading: _isUploading,
          onPressed: _upload,
        ),
      ],
    );
  }
}

Future<Map<String, dynamic>> _loadFeedbackContext({
  required WidgetRef ref,
  required AiChatSessionState sessionState,
  required String? novelId,
  required String? databasePath,
}) async {
  final sessionId = sessionState.sessionId;
  if (sessionId == null ||
      sessionId.isEmpty ||
      isTemporaryAiChatSessionId(sessionId)) {
    return {
      'format_version': 2,
      'captured_at': DateTime.now().toUtc().toIso8601String(),
      'message_source': 'memory',
      'session_id': sessionId,
      'title': sessionState.title,
      'model': sessionState.model,
      'message_count': sessionState.messages.length,
      'messages': sessionState.messages
          .map((message) => message.toJson())
          .toList(),
      'sub_sessions': <Map<String, dynamic>>[],
      'session_count': 1,
      'total_message_count': sessionState.messages.length,
    };
  }
  if (novelId == null ||
      novelId.isEmpty ||
      databasePath == null ||
      databasePath.isEmpty) {
    throw StateError('Persisted feedback requires a work and database.');
  }
  final persistence = ref.read(
    aiSessionPersistenceServiceProvider(
      novelId: novelId,
      databasePath: databasePath,
    ),
  );
  final novelDatabase = ref.read(novelContentDatabaseProvider(databasePath));
  return persistence.loadFeedbackContext(
    sessionId: sessionId,
    novelDatabase: novelDatabase,
  );
}

// 职责: 为制作界面提供本地化输入用途、统一错误提示与媒体选择。
// 关联文件:
//   lib/desktop/features/production/composer.dart
//   lib/desktop/features/production/storage_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/video/request.dart';
import '../../../shared/models/audio/exception.dart';
import '../../../shared/models/production/media.dart';
import '../../../shared/models/video/task_result.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../asset/media_preview.dart';
import 'asset_picker.dart';
import 'certification.dart';
import 'storage_dialog.dart';
import '../../../shared/services/ai/assets/client.dart'
    show ProviderAssetException;
import '../../../shared/services/storyboard/service.dart';

final _log = AppLogger.forModule('Production');

/// 图片任务上游已受理、结果没取回时的提示与重试文案：有地址时重新下载，
/// 只有任务 ID 时重新获取；其他错误码返回 null。
({String error, String action})? productionImageRefetch(String? errorCode) =>
    switch (errorCode) {
      'download_failed' => (
        error: LocaleKeys.productionImageDownloadFailed,
        action: LocaleKeys.productionRetryDownload,
      ),
      'result_fetch_failed' => (
        error: LocaleKeys.productionImageFetchFailed,
        action: LocaleKeys.productionRetryFetch,
      ),
      _ => null,
    };

/// 画布上的指针拖拽手势：排除触摸板，双指滑动始终交给画布平移。
const productionPointerDragDevices = {
  PointerDeviceKind.mouse,
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

String productionRole(
  BuildContext context,
  VideoInputRole role, {
  VideoMode? mode,
  int? middleFrameIndex,
}) => role == VideoInputRole.middle_frame && middleFrameIndex != null
    ? context.t(
        mode == VideoMode.reference
            ? LocaleKeys.productionMiddleFrameReferenceNumber
            : LocaleKeys.productionMiddleFrameNumber,
        namedArgs: {'n': '$middleFrameIndex'},
      )
    : context.t(switch (role) {
        VideoInputRole.first_frame when mode == VideoMode.reference =>
          LocaleKeys.productionFirstFrameReference,
        VideoInputRole.last_frame when mode == VideoMode.reference =>
          LocaleKeys.productionLastFrameReference,
        VideoInputRole.first_frame => LocaleKeys.productionFirstFrame,
        VideoInputRole.last_frame => LocaleKeys.productionLastFrame,
        VideoInputRole.middle_frame when mode == VideoMode.reference =>
          LocaleKeys.productionMiddleFrameReference,
        VideoInputRole.middle_frame => LocaleKeys.productionMiddleFrame,
        VideoInputRole.reference_image => LocaleKeys.productionReferenceImage,
        VideoInputRole.reference_video => LocaleKeys.productionReferenceVideo,
        VideoInputRole.reference_audio => LocaleKeys.productionReferenceAudio,
      });
Future<void> productionRun(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error, stack) {
    if (error is! VideoException && error is! AudioException) {
      _log.error('UI operation failed', error: error, stackTrace: stack);
    }
    if (context.mounted &&
        error is VideoException &&
        error.field == 'reference_storage') {
      // 生成前已拦截过；提交途中才发现未配置时同样就地配置，配置后在结果里重试。
      await showReferenceStorageDialog(context);
      return;
    }
    final providerMessage = switch (error) {
      VideoException(:final providerMessage) ||
      AudioException(:final providerMessage) => providerMessage,
      _ => null,
    };
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            providerMessage ??
                context.t(switch (error) {
                  VideoException(messageKey: final key?) ||
                  AudioException(messageKey: final key?) => key,
                  VideoException(field: 'voice_mode') =>
                    LocaleKeys.productionVoiceMode,
                  VideoException(field: 'draft_expired') =>
                    LocaleKeys.productionDraftExpiredHint,
                  VideoException(field: 'draft_active_task') =>
                    LocaleKeys.productionDraftPendingHint,
                  VideoException(field: 'draft') =>
                    LocaleKeys.productionDraftUnavailable,
                  AudioException(code: 'audio_voice_required') =>
                    LocaleKeys.productionSpeechVoiceRequired,
                  AudioException(code: 'audio_output_unavailable') =>
                    LocaleKeys.productionAudioOutputUnavailable,
                  AudioException(code: 'audio_prompt_length') =>
                    LocaleKeys.productionAudioPromptLength,
                  AudioException(code: 'audio_reference_mixed') =>
                    LocaleKeys.productionAudioReferenceMixed,
                  AudioException(code: 'audio_reference_count') =>
                    LocaleKeys.productionAudioReferenceCount,
                  AudioException(code: 'audio_reference_size') =>
                    LocaleKeys.productionAudioReferenceSize,
                  AudioException(code: 'audio_reference_duration') =>
                    LocaleKeys.productionAudioReferenceDuration,
                  StoryboardException(code: 'audio_reference_format') ||
                  AudioException(
                    code: 'audio_reference_format',
                  ) => LocaleKeys.productionAudioReferenceFormat,
                  StoryboardException(code: 'style_missing') =>
                    LocaleKeys.productionStyleMissing,
                  StoryboardException(code: 'media_missing') =>
                    LocaleKeys.productionFileMissing,
                  MediaException(reason: MediaFailure.no_audio) =>
                    LocaleKeys.productionVideoNoAudio,
                  ProviderAssetException(:final code) =>
                    productionCertifyErrorKey(code),
                  _ => LocaleKeys.productionFailed,
                }),
          ),
        ),
      );
    }
  }
}

Future<AssetRow?> pickProductionAsset(
  BuildContext context,
  ProductionCanvasService service, {
  Set<String> types = const {'image', 'video', 'audio'},
  String? confirmLabel,
}) => showRevericDialog<AssetRow>(
  context: context,
  builder: (_) => ProductionAssetPicker(
    service: service,
    types: types,
    confirmLabel: confirmLabel,
  ),
);

/// 监听资产行；不存在或已删除时为 null。
AssetRow? useProductionAsset(
  ProductionCanvasService service,
  String? assetId,
) => useStream(
  useMemoized(
    () => assetId == null
        ? Stream<AssetRow?>.value(null)
        : service.library.database.assetDao.watchAsset(assetId),
    [service, assetId],
  ),
).data;

Future<void> previewProductionAsset(
  BuildContext context,
  ProductionCanvasService service,
  String assetId,
) async {
  final asset = await service.requireAsset(assetId);
  final file = await service.requireFile(asset.path!, type: asset.type);
  if (context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (_) => MediaPreviewDialog.file(
        path: file.path,
        type: file.type,
        name: file.name,
        autoplay: file.type == 'video',
      ),
    );
  }
}

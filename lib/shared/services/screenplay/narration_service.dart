// 职责: 持久化朗读配置，校验语音模型并完成生成、预测查询与音频下载。
// 关联文件:
//   lib/shared/providers/narration.dart
//   lib/shared/models/narration.dart
//   lib/shared/services/screenplay/narration_orchestrator.dart
//   lib/shared/services/production/audio_generate_orchestrator.dart

import 'dart:async';
import 'dart:convert';
import '../ai/audio/client.dart';
import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/audio/channels.dart';
import '../../models/ai_provider.dart';
import '../../models/audio/exception.dart';
import '../../models/audio/request.dart';
import '../../models/narration.dart';
import '../production/audio_generate_orchestrator.dart';
import 'narration_orchestrator.dart';

final _log = AppLogger.forModule('Narration');

class NarrationService {
  NarrationService({
    required this.database,
    required this.invoke,
    this.query,
    this.pollInterval = const Duration(seconds: 2),
  });
  final AppDatabase database;
  final ProductionAudioInvoke invoke;
  final ProductionAudioQuery? query;
  final Duration pollInterval;

  Future<NarrationSettings> load(String workId) async {
    final raw = await database.appStateDao.get('screenplay_narration:$workId');
    return raw == null
        ? NarrationSettings()
        : NarrationSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(String workId, NarrationSettings settings) async {
    await requireProvider(settings);
    if (settings.narrator.trim().isEmpty) {
      throw const AudioException('audio_voice_required');
    }
    try {
      await database.appStateDao.set(
        key: 'screenplay_narration:$workId',
        value: jsonEncode(settings.toJson()),
      );
    } catch (error, stack) {
      _log.error(
        '[DB] UPSERT app_states screenplay_narration:$workId',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<AiProvider> requireProvider(NarrationSettings settings) async {
    final provider = await database.aiProviderDao.getById(settings.providerId);
    if (provider == null ||
        !provider.enabled ||
        !provider.availableAudioModels.contains(settings.modelId) ||
        lookupAudioChannelModel(
              provider.type,
              settings.modelId,
            )?.capabilities.requiresVoice !=
            true) {
      throw const AudioException('invalid_config');
    }
    return provider;
  }

  Future<NarrationAudio> generate(
    NarrationSettings settings,
    NarrationSegment segment,
    Future<void> abort,
  ) async {
    var cancelled = false;
    unawaited(abort.then((_) => cancelled = true));
    final provider = await requireProvider(settings);
    if (cancelled) {
      throw const AudioException('cancelled');
    }
    final request = resolveAudioRequest(
      provider.type,
      AudioRequest(
        providerId: provider.id,
        modelId: settings.modelId,
        prompt: segment.text,
        originalPrompt: segment.text,
        parameters: AudioRequestDefaults(
          voice: ConfigValue(segment.voice),
          instructions: ConfigValue(segment.instructions),
        ),
      ),
    );
    var result = await invoke(provider, request, const [], abort);
    if (result.isPending) {
      if (query == null) {
        throw const AudioException('invalid_config');
      }
      result = await waitForAudioPrediction(
        query!,
        provider,
        result.providerTaskId!,
        abort,
        interval: pollInterval,
      );
    }
    if (cancelled) {
      throw const AudioException('cancelled');
    }
    final bytes = result.bytes.isNotEmpty
        ? result.bytes
        : result.url != null
        ? await downloadAudioOutput(result.url!, abortTrigger: abort)
        : result.bytes;
    if (cancelled) {
      throw const AudioException('cancelled');
    }
    if (bytes.isEmpty) {
      throw const AudioException('invalid_result');
    }
    return NarrationAudio(
      bytes,
      audioOutputFileFormat(
        request.parameters.responseFormat,
        mimeType: result.mimeType,
      ),
    );
  }
}

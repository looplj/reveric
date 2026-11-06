// 职责: 装配第三方音频提交、预测查询和应用启动恢复入口。
// 关联文件:
//   lib/shared/services/production/audio_service.dart
//   lib/shared/services/ai/audio/client.dart
//   lib/shared/providers/production_media.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/ai_provider.dart';
import '../models/audio/channels.dart';
import '../services/ai/audio/client.dart';
import '../services/ai/audio/seed.dart';
import '../services/ai/audio/moss.dart';
import '../services/ai/audio/minimax.dart';
import '../services/ai/audio/openrouter.dart';
import '../services/ai/new_api.dart';
import '../services/ai/audio/qwen.dart';
import '../services/ai/audio/atlascloud.dart';
import '../models/audio/exception.dart';
import '../services/production/audio_service.dart';
import '../services/production/audio_generate_orchestrator.dart';
import 'novel_providers.dart';
import 'production_media.dart';
import 'video_tasks.dart';

final productionAudioInvokeProvider = Provider<ProductionAudioInvoke>(
  (ref) => (provider, request, references, abortTrigger) async {
    final httpClient = provider.createProxyClient() ?? http.Client();
    try {
      final type = provider.type;
      final apiKey = provider.effectiveApiKey;
      final AudioClient client = switch (aiProviderTypeConfigFor(
        type,
      )?.audioProtocol) {
        AudioProtocol.moss_audio => MossAudioClient(httpClient, apiKey),
        AudioProtocol.new_api_speech => NewApiClient(
          provider,
        ).audio(httpClient, request.modelId),
        AudioProtocol.openrouter_speech => OpenRouterAudioClient(
          httpClient,
          apiKey,
          providerType: type,
        ),
        AudioProtocol.seed_audio => SeedAudioClient(
          httpClient,
          apiKey,
          providerType: type,
        ),
        AudioProtocol.minimax_music => MinimaxAudioClient(
          httpClient,
          apiKey,
          providerType: type,
          endpoint: Uri.parse(provider.effectiveBaseUrl),
        ),
        AudioProtocol.qwen_tts => QwenAudioClient(
          httpClient,
          apiKey,
          endpoint: qwenAudioEndpoint(
            provider.effectiveBaseUrl,
            modelId: request.modelId,
          ),
        ),
        AudioProtocol.atlascloud_audio => AtlasCloudAudioClient(
          httpClient,
          apiKey,
        ),
        null => throw const AudioException('invalid_config'),
      };
      return await client.generate(
        request,
        references: references,
        abortTrigger: abortTrigger,
      );
    } finally {
      httpClient.close();
    }
  },
);

final productionAudioQueryProvider = Provider<ProductionAudioQuery>(
  (ref) => (provider, predictionId, abortTrigger) async {
    if (provider.type != 'atlascloud') {
      throw const AudioException('invalid_config');
    }
    final transport = provider.createProxyClient() ?? http.Client();
    try {
      return await AtlasCloudAudioClient(
        transport,
        provider.effectiveApiKey,
      ).query(predictionId, abortTrigger: abortTrigger);
    } finally {
      transport.close();
    }
  },
);

final audioTaskServiceProvider = Provider<AudioTaskService>((ref) {
  final results = ref.watch(productionResultServiceProvider);
  final service = AudioTaskService(
    database: ref.watch(appDatabaseProvider),
    library: ref.watch(mediaLibraryServiceProvider),
    invoke: ref.watch(productionAudioInvokeProvider),
    query: ref.watch(productionAudioQueryProvider),
    download: (provider, url) => downloadAudioOutput(url, provider: provider),
    beforeCreate: results.beforeCreate,
    beforeSubmit: results.beforeSubmit,
    recoverSources: results.recover,
  );
  ref.onDispose(service.dispose);
  return service;
});
final audioTaskRecoveryProvider = FutureProvider<void>(
  (ref) => ref.watch(audioTaskServiceProvider).recover(),
);

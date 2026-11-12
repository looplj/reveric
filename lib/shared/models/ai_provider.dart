// 职责: 定义 AI 供应商类型、运行时配置、业务模型及 Drift AiProvider 扩展方法。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/localization/ai_provider_localization.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/zh-CN/provider.json

import 'dart:io';

import 'package:easy_localization/easy_localization.dart' show tr;
import 'package:http/io_client.dart';
import 'package:http/http.dart' as http;

import '../../third/form/flutter_hook_form.dart';
import '../database/app_database.dart';
import '../localization/locale_keys.dart';
import '../services/ai/codex/credentials.dart';
import '../services/proxy_client.dart';
import 'models_catalog.dart';
import 'audio/channels.dart';
import 'image/channels.dart';
import 'video/request.dart';

export '../database/app_database.dart'
    show AiProvider, AiProviders, AiProvidersCompanion;

// ==================== 枚举与配置类型 ====================

enum AiProviderType {
  openai,
  codex,
  openai_compatible,
  api88,
  apikey,
  infistar,
  ooki,
  openrouter,
  xai,
  anthropic,
  qwen,
  qwen_token_plan,
  gemini,
  deepseek,
  moonshot,
  zhipu,
  doubao,
  volcengine,
  minimax,
  metaso,
  agnes,
  atlascloud,
  purefox,
  purefox_media,
  moss,
}

enum ReasoningEffort { none, low, medium, high }

enum AiModelKind { chat, image, video, audio }

enum AiModelRole { planner, writer }

/// 渠道上的型号 ID 由谁决定。
enum ModelIdSource {
  /// 官方或聚合平台目录：渠道表即完整清单，只按精确 ID 查找能力。
  registered,

  /// 可能接入中转站，型号 ID 由对方任意命名：需要从 ID 中识别目录型号。
  open,
}

enum UploadProtocol {
  api88_media,
  minimax_files,
  purefox_uploads,
  atlascloud_media,
}

class AiProviderTypeConfig {
  final String displayName;
  final bool fixedBaseUrl;
  final bool usesNewApi;
  final ModelIdSource modelIdSource;
  final ImageProtocol? imageProtocol;
  final VideoProtocol? videoProtocol;
  final AudioProtocol? audioProtocol;
  final UploadProtocol? uploadProtocol;

  /// 不经过媒体协议的能力（chat）。
  final Set<AiModelKind> _textModelKinds;

  const AiProviderTypeConfig({
    required this.displayName,
    required this.modelIdSource,
    this._textModelKinds = const {},
    this.imageProtocol,
    this.videoProtocol,
    this.audioProtocol,
    this.uploadProtocol,
    this.fixedBaseUrl = false,
    this.usesNewApi = false,
  });

  Set<AiModelKind> get supportedModelKinds => {
    ..._textModelKinds,
    if (imageProtocol != null) AiModelKind.image,
    if (videoProtocol != null) AiModelKind.video,
    if (audioProtocol != null) AiModelKind.audio,
  };
}

const Set<AiModelKind> _chatOnlyKinds = {AiModelKind.chat};

const Map<AiProviderType, AiProviderTypeConfig> aiProviderTypeConfigs = {
  AiProviderType.moss: AiProviderTypeConfig(
    displayName: 'MOSS',
    modelIdSource: ModelIdSource.registered,
    imageProtocol: ImageProtocol.moss_image,
    audioProtocol: AudioProtocol.moss_audio,
    fixedBaseUrl: true,
  ),
  AiProviderType.atlascloud: AiProviderTypeConfig(
    displayName: 'AtlasCloud',
    uploadProtocol: UploadProtocol.atlascloud_media,
    modelIdSource: ModelIdSource.registered,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.atlascloud_image,
    videoProtocol: VideoProtocol.atlascloud_video,
    audioProtocol: AudioProtocol.atlascloud_audio,
    fixedBaseUrl: true,
  ),
  AiProviderType.openai: AiProviderTypeConfig(
    displayName: 'OpenAI',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.openai_images,
  ),
  AiProviderType.codex: AiProviderTypeConfig(
    displayName: 'Codex',
    modelIdSource: ModelIdSource.registered,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.codex_image,
    fixedBaseUrl: true,
  ),
  AiProviderType.openai_compatible: AiProviderTypeConfig(
    displayName: 'OpenAI Compatible',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.openai_images,
  ),
  AiProviderType.api88: AiProviderTypeConfig(
    displayName: '88API',
    uploadProtocol: UploadProtocol.api88_media,
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.new_api_images,
    videoProtocol: VideoProtocol.new_api_video,
    audioProtocol: AudioProtocol.new_api_speech,
    fixedBaseUrl: true,
    usesNewApi: true,
  ),
  AiProviderType.apikey: AiProviderTypeConfig(
    displayName: 'APIKEY.FAN',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    fixedBaseUrl: true,
    usesNewApi: true,
  ),
  AiProviderType.infistar: AiProviderTypeConfig(
    displayName: '无限星河',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    fixedBaseUrl: true,
    usesNewApi: true,
  ),
  AiProviderType.ooki: AiProviderTypeConfig(
    displayName: 'OOKiAPI',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.new_api_images,
    videoProtocol: VideoProtocol.new_api_video,
    audioProtocol: AudioProtocol.new_api_speech,
    fixedBaseUrl: true,
    usesNewApi: true,
  ),
  AiProviderType.openrouter: AiProviderTypeConfig(
    displayName: 'OpenRouter',
    modelIdSource: ModelIdSource.registered,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.openrouter_image,
    videoProtocol: VideoProtocol.openrouter_video,
    audioProtocol: AudioProtocol.openrouter_speech,
    fixedBaseUrl: true,
  ),
  AiProviderType.xai: AiProviderTypeConfig(
    displayName: 'xAI',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.openai_images,
  ),
  AiProviderType.anthropic: AiProviderTypeConfig(
    displayName: 'Anthropic',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
  ),
  AiProviderType.qwen: AiProviderTypeConfig(
    displayName: 'Qwen',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.qwen_image,
    videoProtocol: VideoProtocol.wan_video,
    audioProtocol: AudioProtocol.qwen_tts,
  ),
  AiProviderType.qwen_token_plan: AiProviderTypeConfig(
    displayName: 'Qwen Token Plan',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.qwen_image,
    videoProtocol: VideoProtocol.wan_video,
    audioProtocol: AudioProtocol.qwen_tts,
    fixedBaseUrl: true,
  ),
  AiProviderType.gemini: AiProviderTypeConfig(
    displayName: 'Gemini',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.gemini_image,
  ),
  AiProviderType.deepseek: AiProviderTypeConfig(
    displayName: 'DeepSeek',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
  ),
  AiProviderType.moonshot: AiProviderTypeConfig(
    displayName: 'Moonshot',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
  ),
  AiProviderType.zhipu: AiProviderTypeConfig(
    displayName: 'Zhipu',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
  ),
  AiProviderType.doubao: AiProviderTypeConfig(
    displayName: 'Doubao',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.ark_image,
    videoProtocol: VideoProtocol.ark_video,
  ),
  AiProviderType.volcengine: AiProviderTypeConfig(
    displayName: 'Volcengine',
    modelIdSource: ModelIdSource.registered,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.ark_image,
    videoProtocol: VideoProtocol.ark_video,
    audioProtocol: AudioProtocol.seed_audio,
    fixedBaseUrl: true,
  ),
  AiProviderType.metaso: AiProviderTypeConfig(
    displayName: 'METASO',
    uploadProtocol: UploadProtocol.minimax_files,
    modelIdSource: ModelIdSource.registered,
    videoProtocol: VideoProtocol.minimax_video_v2,
    fixedBaseUrl: true,
  ),
  AiProviderType.minimax: AiProviderTypeConfig(
    displayName: 'MiniMax',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    imageProtocol: ImageProtocol.minimax_image,
    videoProtocol: VideoProtocol.minimax_video_v2,
    audioProtocol: AudioProtocol.minimax_music,
  ),
  AiProviderType.agnes: AiProviderTypeConfig(
    displayName: 'Agnes',
    modelIdSource: ModelIdSource.open,
    imageProtocol: ImageProtocol.agnes_image,
    videoProtocol: VideoProtocol.agnes_video,
    fixedBaseUrl: true,
  ),
  AiProviderType.purefox: AiProviderTypeConfig(
    displayName: 'PureFox',
    modelIdSource: ModelIdSource.open,
    textModelKinds: _chatOnlyKinds,
    fixedBaseUrl: true,
  ),
  AiProviderType.purefox_media: AiProviderTypeConfig(
    uploadProtocol: UploadProtocol.purefox_uploads,
    displayName: 'PureFox Media',
    modelIdSource: ModelIdSource.registered,
    imageProtocol: ImageProtocol.purefox_media,
    videoProtocol: VideoProtocol.purefox_media,
    fixedBaseUrl: true,
  ),
};

/// 持久化的 provider 类型名对应的配置；已移除的类型返回 null。
AiProviderTypeConfig? aiProviderTypeConfigFor(String type) =>
    aiProviderTypeConfigs[AiProviderType.values.asNameMap()[type]];

final Map<AiProviderType, String> aiProviderTypeDisplayNames = {
  for (final entry in aiProviderTypeConfigs.entries)
    entry.key: entry.value.displayName,
};

final List<AiProviderType> customAiProviderTypes = List.unmodifiable(
  AiProviderType.values,
);

String aiProviderFixedBaseUrl(AiProviderType type) => switch (type) {
  AiProviderType.qwen_token_plan =>
    'https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1',
  AiProviderType.moss => 'https://api.mosi.cn/v1',
  AiProviderType.metaso => 'https://metaso.cn/api/minimax',
  AiProviderType.api88 => 'https://api.88api.ai/v1',
  AiProviderType.apikey => 'https://api.apikey.fan/v1',
  AiProviderType.infistar => 'https://infistar.cc/v1',
  AiProviderType.ooki => 'https://api.ookiapi.com/v1',
  AiProviderType.atlascloud => 'https://api.atlascloud.ai/v1',
  AiProviderType.agnes => agnesDefaultBaseUrl,
  AiProviderType.codex => 'https://chatgpt.com/backend-api/codex',
  AiProviderType.openrouter => 'https://openrouter.ai/api/v1',
  AiProviderType.volcengine => 'https://ark.cn-beijing.volces.com/api/v3',
  AiProviderType.purefox => 'https://purefox.org/v1',
  AiProviderType.purefox_media => 'https://img.purefox.org/v1',
  _ => '',
};

/// Codex 新配置的预设目录。
const codexPresetModels = <String>['gpt-6-astra', 'gpt-6-luna', 'gpt-6.1-sol'];

const codexPresetImageModels = <String>[
  'gpt-image-2.6-sunburst',
  'gpt-image-2.6-flare',
  'gpt-image-2.5-sunburst',
  'gpt-image-2.5-flare',
  'gpt-image-2',
];

/// MiniMax 没有公开的模型列表接口，「获取模型」使用这份目录。
const minimaxPresetChatModels = <String>[
  'MiniMax-M3',
  'MiniMax-M2.7',
  'MiniMax-M2.7-highspeed',
  'MiniMax-M2.5',
  'MiniMax-M2.5-highspeed',
  'MiniMax-M2.1',
];

/// MiniMax 聊天走官方 Anthropic 兼容入口（`<host>/anthropic`），思考内容以
/// thinking block 返回；视频、音频仍按原 Base URL 拼 `/v1/...`。
String minimaxAnthropicBaseUrl(String baseUrl) {
  var url = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  if (url.endsWith('/anthropic')) {
    return url;
  }
  if (url.endsWith('/v1')) {
    url = url.substring(0, url.length - 3);
  }
  return '$url/anthropic';
}

const agnesDefaultBaseUrl = 'https://apihub.agnes-ai.com/v1';

const qwenDefaultBaseUrl = 'https://maas.qianwenaiapi.com/compatible-mode/v1';

/// Only the previous fixed endpoint is replaced; custom proxy URLs remain intact.
String qwenBaseUrl(String value) {
  final trimmed = value.trim().replaceFirst(RegExp(r'/+$'), '');
  return trimmed.isEmpty ||
          trimmed == 'https://dashscope.aliyuncs.com/apps/anthropic'
      ? qwenDefaultBaseUrl
      : value;
}

// ==================== Builtin 默认值 ====================

final List<AiProvider> aiProviderBuiltinDefaults = [
  AiProvider(
    id: 'metaso',
    name: '秘塔科技',
    builtin: true,
    type: 'metaso',
    enabled: false,
    apiKey: '',
    baseUrl: aiProviderFixedBaseUrl(AiProviderType.metaso),
    models: const [],
    imageModels: const [],
    audioModels: const [],
    videoModels: const [
      'MiniMax-H3',
      'MiniMax-H3-priority',
      'seedance-2.0',
      'seedance-2.0-mini',
    ],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    id: 'api88',
    name: '88API',
    builtin: true,
    type: 'api88',
    enabled: false,
    apiKey: '',
    baseUrl: aiProviderFixedBaseUrl(AiProviderType.api88),
    models: const [],
    imageModels: const [],
    audioModels: const [],
    videoModels: const [],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    id: 'apikey',
    name: 'APIKEY.FAN',
    builtin: true,
    type: 'apikey',
    enabled: false,
    apiKey: '',
    baseUrl: aiProviderFixedBaseUrl(AiProviderType.apikey),
    models: const [],
    imageModels: const [],
    audioModels: const [],
    videoModels: const [],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: 'deepseek',
    name: 'DeepSeek',
    builtin: true,
    type: 'deepseek',
    enabled: false,
    apiKey: '',
    baseUrl: 'https://api.deepseek.com/v1',
    models: ['deepseek-v4-flash', 'deepseek-v4-pro'],
    imageModels: const [],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: 'doubao',
    name: 'Doubao',
    builtin: true,
    type: 'doubao',
    enabled: false,
    apiKey: '',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    models: [
      'doubao-seed-2-0-pro-260215',
      'doubao-seed-2-0-lite-260215',
      'deepseek-v3-2-251201',
    ],
    imageModels: imageModelsForProvider('doubao'),
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: 'moonshot',
    name: 'Moonshot',
    builtin: true,
    type: 'moonshot',
    enabled: false,
    apiKey: '',
    baseUrl: 'https://api.moonshot.cn/v1',
    models: ['kimi-k3', 'kimi-k2.6', 'kimi-k2.5'],
    imageModels: const [],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: 'zhipu',
    name: 'Zhipu',
    builtin: true,
    type: 'zhipu',
    enabled: false,
    apiKey: '',
    baseUrl: 'https://api.z.ai/api/paas/v4',
    models: [
      'glm-5v-turbo',
      'glm-5.1',
      'glm-5-turbo',
      'glm-5',
      'glm-4.7-flashx',
      'glm-4.7-flash',
      'glm-4.7',
    ],
    imageModels: const [],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: 'openai',
    name: 'OpenAI',
    builtin: true,
    type: 'openai',
    enabled: false,
    apiKey: '',
    baseUrl: 'https://api.openai.com/v1',
    models: [
      'gpt-5.4',
      'gpt-5.4-mini',
      'gpt-5.4-nano',
      'gpt-5.3-chat-latest',
      'gpt-5.3-codex',
      'o3',
      'o4-mini',
    ],
    imageModels: ['gpt-image-2'],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: 'gemini',
    name: 'Gemini',
    builtin: true,
    type: 'gemini',
    enabled: false,
    apiKey: '',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    models: [
      'gemini-4-carbon',
      'gemini-4-argon',
      'gemini-3.1-pro-preview',
      'gemini-3-flash-preview',
      'gemini-3.1-flash-lite-preview',
      'gemini-flash-latest',
      'gemini-2.5-pro',
      'gemini-2.5-flash',
    ],
    imageModels: ['gemini-3.1-flash-image-preview', 'gemini-2.5-flash-image'],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: 'anthropic',
    name: 'Anthropic',
    builtin: true,
    type: 'anthropic',
    enabled: false,
    apiKey: '',
    baseUrl: 'https://api.anthropic.com',
    models: [
      'claude-sonnet-4-5',
      'claude-sonnet-4-5-20250929',
      'claude-haiku-4-5',
      'claude-haiku-4-6',
      'claude-sonnet-4-6',
      'claude-opus-4-6',
      'claude-opus-4-7',
    ],
    imageModels: const [],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: 'purefox',
    name: 'PureFox',
    builtin: true,
    type: 'purefox',
    enabled: false,
    apiKey: '',
    baseUrl: aiProviderFixedBaseUrl(AiProviderType.purefox),
    models: const [],
    imageModels: const [],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: 'purefox_media',
    name: 'PureFox Media',
    builtin: true,
    type: 'purefox_media',
    enabled: false,
    apiKey: '',
    baseUrl: aiProviderFixedBaseUrl(AiProviderType.purefox_media),
    models: const [],
    imageModels: const [],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
  AiProvider(
    audioModels: const [],
    videoModels: const [],
    id: 'xai',
    name: 'xAI',
    builtin: true,
    type: 'xai',
    enabled: false,
    apiKey: '',
    baseUrl: 'https://api.x.ai/v1',
    models: [
      'grok-4.20-0309-reasoning',
      'grok-4.20-0309-non-reasoning',
      'grok-4.20-multi-agent-0309',
    ],
    imageModels: ['grok-2-image-1212'],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 512,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: _builtinEpoch,
    deletedAt: notDeletedSentinel,
  ),
];

final _builtinEpoch = DateTime(2024, 1, 1);

List<AiProvider> aiProviderDefaultBuiltins() {
  return aiProviderBuiltinDefaults
      .map((provider) => provider.copyWith())
      .toList();
}

String? aiProviderBuiltinDefaultBaseUrl(String id) {
  final match = aiProviderBuiltinById(id);
  return match?.baseUrl;
}

AiProvider? aiProviderBuiltinById(String id) {
  for (final provider in aiProviderBuiltinDefaults) {
    if (provider.id == id) return provider;
  }
  return null;
}

// ==================== Extension 方法 ====================

extension AiProviderX on AiProvider {
  bool get isTypeSupported =>
      AiProviderType.values.asNameMap().containsKey(type);

  AiProviderType get typeEnum =>
      AiProviderType.values.asNameMap()[type] ??
      (throw UnsupportedError('Unsupported AI provider type: $type'));

  bool get hasProxy => proxyUrl.trim().isNotEmpty;

  http.Client? createProxyClient() {
    final url = proxyUrl.trim();
    if (url.isEmpty) return null;

    final httpClient = HttpClient();
    configureHttpClientProxy(
      httpClient,
      Uri.parse(url),
      username: proxyUsername.trim(),
      password: proxyPassword.trim(),
    );
    return IOClient(httpClient);
  }

  ReasoningEffort? get reasoningEffortEnum => reasoningEffort != null
      ? ReasoningEffort.values.byName(reasoningEffort!)
      : null;

  AiProviderTypeConfig get typeConfig => aiProviderTypeConfigs[typeEnum]!;

  String get displayName => name;

  bool get isBuiltin => builtin;

  bool get canDelete => true;

  bool get isCodex => type == AiProviderType.codex.name;

  bool get isPlatformSupported =>
      !isCodex || CodexCredentials.supportedPlatform;

  /// 本机认证在每次请求前读取；配置校验只检查平台与必填设置。
  bool get hasCredentialConfiguration =>
      isCodex ? CodexCredentials.supportedPlatform : hasApiKey;

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  bool get hasBaseUrl => effectiveBaseUrl.trim().isNotEmpty;

  bool get hasModels =>
      availableModels.isNotEmpty ||
      availableImageModels.isNotEmpty ||
      availableVideoModels.isNotEmpty ||
      availableAudioModels.isNotEmpty;

  String? get enableValidationMessage {
    if (!isTypeSupported) {
      return tr(LocaleKeys.providerTypeUnsupported, namedArgs: {'type': type});
    }
    if (!isPlatformSupported) {
      return tr(LocaleKeys.settingsCodexDesktopOnly);
    }
    if (!hasCredentialConfiguration) return '请先填写 API Key，再启用提供商。';
    if (!hasBaseUrl) return '请先填写 Base URL，再启用提供商。';
    if (!hasModels) return '请先至少添加一个模型，再启用提供商。';
    return null;
  }

  String get effectiveBaseUrl => hasFixedBaseUrl
      ? fixedBaseUrl
      : typeEnum == AiProviderType.qwen
      ? qwenBaseUrl(baseUrl)
      : typeEnum == AiProviderType.minimax && baseUrl.trim().isEmpty
      ? 'https://api.minimax.cn'
      : baseUrl;

  bool get hasFixedBaseUrl => typeConfig.fixedBaseUrl;

  String get fixedBaseUrl => aiProviderFixedBaseUrl(typeEnum);

  String get effectiveApiKey => apiKey;

  List<String> get availableModels =>
      supportsModelKind(AiModelKind.chat) ? _normalizeModels(models) : const [];

  Set<AiModelKind> get supportedModelKinds => typeConfig.supportedModelKinds;

  bool supportsModelKind(AiModelKind kind) =>
      supportedModelKinds.contains(kind);

  List<String> get availableImageModels => supportsModelKind(AiModelKind.image)
      ? _normalizeModels(imageModels)
      : const [];

  List<String> get availableAudioModels => supportsModelKind(AiModelKind.audio)
      ? _normalizeModels(audioModels)
      : const [];

  List<String> get availableVideoModels => supportsModelKind(AiModelKind.video)
      ? _normalizeModels(videoModels)
      : const [];

  List<String> modelsForKind(AiModelKind kind) {
    if (!supportsModelKind(kind)) return const [];
    return switch (kind) {
      AiModelKind.chat => availableModels,
      AiModelKind.image => availableImageModels,
      AiModelKind.video => availableVideoModels,
      AiModelKind.audio => availableAudioModels,
    };
  }

  bool supportsModel(String? model, {AiModelKind kind = AiModelKind.chat}) {
    final normalized = model?.trim();
    final available = modelsForKind(kind);
    return normalized != null && available.contains(normalized);
  }

  bool get isValid =>
      isTypeSupported &&
      enabled &&
      hasCredentialConfiguration &&
      hasBaseUrl &&
      hasModels;
}

List<String> _normalizeModels(List<String> input) {
  return input
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList();
}

// ==================== 表单字段枚举 ====================

enum AiProviderFormField<T> implements FieldSchema {
  name<String>(validators: [RequiredValidator<String>(message: '请输入提供商名称')]),
  type<String>(validators: [RequiredValidator<String>()]),
  enabled<bool>(),
  apiKey<String>(
    validators: [RequiredValidator<String>(message: '请输入 API Key')],
  ),
  baseUrl<String>(
    validators: [RequiredValidator<String>(message: '请输入 Base URL')],
  ),
  models<String>(validators: [RequiredValidator<String>(message: '请至少添加一个模型')]),
  temperature<double>(),

  maxTurns<int>(),
  reasoningEffort<String?>(),
  proxyUrl<String>(),
  proxyUsername<String>(),
  proxyPassword<String>();

  const AiProviderFormField({this.validators});

  @override
  final List<Validator<dynamic>>? validators;
}

// ==================== AiModelOption ====================

/// 按偏好解析可用模型。
AiModelOption? resolveSelectableModelOption({
  required List<AiModelOption> options,
  String? preferredOptionId,
}) {
  if (options.isEmpty) {
    return null;
  }
  if (preferredOptionId != null) {
    for (final option in options) {
      if (option.id == preferredOptionId) {
        return option;
      }
    }
  }
  return options.first;
}

class AiModelOption {
  bool get supportsImageInput => lookupCatalogImageInput(model);
  final String providerId;
  final String providerDisplayName;
  final String model;
  final String? modelDisplayName;
  final AiModelKind kind;
  final bool isDefault;

  /// 该模型支持的 reasoning effort 级别（low→high 顺序）；null 表示非推理模型。
  final List<String>? reasoningEfforts;

  const AiModelOption({
    required this.providerId,
    required this.providerDisplayName,
    required this.model,
    required this.kind,
    this.modelDisplayName,
    this.isDefault = false,
    this.reasoningEfforts,
  });

  String get id => '$providerId::$model';

  /// 有配置的模型展示名时使用展示名，
  /// 否则沿用模型 id。
  String get displayModelName {
    final displayName = modelDisplayName?.trim();
    return displayName != null && displayName.isNotEmpty ? displayName : model;
  }
}

/// 推理模型的默认 effort：优先 `medium`，否则取列表中点，否则 null（非推理模型）。
/// model card 只给出支持的级别列表，没有显式默认值，这里按经验取中档。
String? defaultReasoningEffortFor(List<String>? efforts) {
  if (efforts == null || efforts.isEmpty) return null;
  if (efforts.contains('medium')) return 'medium';
  return efforts[efforts.length ~/ 2];
}

/// 从持久化 effort + 模型 capability 解析会话应使用的 reasoning effort。
///
/// [persistedEffort] 来自 `ai_chat_sessions.metadata.reasoning_effort`；
/// 缺失时，全局聊天默认模型优先使用其预设 effort；无效时回落到
/// [defaultReasoningEffortFor]。
String? resolveSessionReasoningEffort({
  required String? providerId,
  required String? model,
  String? persistedEffort,
  required AiSettings settings,
}) {
  if (providerId == null || model == null) {
    return null;
  }
  final option = settings.findModelOptionById(
    kind: AiModelKind.chat,
    optionId: '$providerId::$model',
  );
  final selectedEffort =
      persistedEffort ??
      (option?.id == settings.defaultChatModelId
          ? settings.defaultChatReasoningEffort
          : null);
  return reasoningEffortForOption(option, selectedEffort);
}

/// 用户为 [option] 选择的 effort；[selectedEffort] 缺失或对该模型无效时
/// 回落到默认档位，非推理模型返回 null。
String? reasoningEffortForOption(
  AiModelOption? option,
  String? selectedEffort,
) {
  final efforts = option?.reasoningEfforts;
  if (efforts == null || efforts.isEmpty) {
    return null;
  }
  if (selectedEffort != null && efforts.contains(selectedEffort)) {
    return selectedEffort;
  }
  return defaultReasoningEffortFor(efforts);
}

// ==================== AiSettings ====================

class AiSettings {
  final List<AiProvider> providers;
  final String? defaultChatModelId;
  final String? defaultChatReasoningEffort;
  final String? defaultImageModelId;
  final String? defaultPlannerModelId;
  final String? defaultWriterModelId;

  const AiSettings({
    this.providers = const [],
    this.defaultChatModelId,
    this.defaultChatReasoningEffort,
    this.defaultImageModelId,
    this.defaultPlannerModelId,
    this.defaultWriterModelId,
  });

  factory AiSettings.defaults() {
    return AiSettings(providers: mergeWithRequiredProviders(const []));
  }

  List<AiProvider> get enabledConfigs =>
      providers.where((provider) => provider.isValid).toList();

  List<AiProvider> get allConfigs => providers;

  AiProvider? findConfigById(String id) {
    for (final provider in providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  factory AiSettings.fromJson(Map<String, dynamic> json) {
    return AiSettings(
      defaultChatModelId: json['defaultChatModelId'] as String?,
      defaultChatReasoningEffort: json['defaultChatReasoningEffort'] as String?,
      defaultImageModelId: json['defaultImageModelId'] as String?,
      defaultPlannerModelId: json['defaultPlannerModelId'] as String?,
      defaultWriterModelId: json['defaultWriterModelId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (defaultChatModelId != null) 'defaultChatModelId': defaultChatModelId,
    if (defaultChatReasoningEffort != null)
      'defaultChatReasoningEffort': defaultChatReasoningEffort,
    if (defaultImageModelId != null) 'defaultImageModelId': defaultImageModelId,
    if (defaultPlannerModelId != null)
      'defaultPlannerModelId': defaultPlannerModelId,
    if (defaultWriterModelId != null)
      'defaultWriterModelId': defaultWriterModelId,
  };

  AiSettings copyWith({
    List<AiProvider>? providers,
    Object? defaultChatModelId = _sentinel,
    Object? defaultChatReasoningEffort = _sentinel,
    Object? defaultImageModelId = _sentinel,
    Object? defaultPlannerModelId = _sentinel,
    Object? defaultWriterModelId = _sentinel,
  }) {
    return AiSettings(
      providers: providers ?? this.providers,
      defaultChatModelId: defaultChatModelId == _sentinel
          ? this.defaultChatModelId
          : defaultChatModelId as String?,
      defaultChatReasoningEffort: defaultChatReasoningEffort == _sentinel
          ? this.defaultChatReasoningEffort
          : defaultChatReasoningEffort as String?,
      defaultImageModelId: defaultImageModelId == _sentinel
          ? this.defaultImageModelId
          : defaultImageModelId as String?,
      defaultPlannerModelId: defaultPlannerModelId == _sentinel
          ? this.defaultPlannerModelId
          : defaultPlannerModelId as String?,
      defaultWriterModelId: defaultWriterModelId == _sentinel
          ? this.defaultWriterModelId
          : defaultWriterModelId as String?,
    );
  }

  AiSettings updateConfig(AiProvider provider) {
    if (!provider.isTypeSupported) {
      throw UnsupportedError('Unsupported AI provider type: ${provider.type}');
    }
    final previous = findConfigById(provider.id);
    final nextProviders = List<AiProvider>.from(providers);
    final index = nextProviders.indexWhere((item) => item.id == provider.id);
    if (index >= 0) {
      nextProviders[index] = provider;
    } else {
      nextProviders.add(provider);
    }
    final updated = copyWith(
      providers: mergeWithRequiredProviders(nextProviders),
    );
    if (previous == null) {
      return updated;
    }
    // 只清理本次编辑明确移除的模型，不根据登录态、凭据或启用状态清理偏好。
    final removedModels = {
      AiModelKind.chat: _normalizeModels(
        previous.models,
      ).toSet().difference(_normalizeModels(provider.models).toSet()),
      AiModelKind.image: _normalizeModels(
        previous.imageModels,
      ).toSet().difference(_normalizeModels(provider.imageModels).toSet()),
    };
    return updated._clearDefaultSelectionsWhere((kind, optionId) {
      final prefix = '${provider.id}::';
      return optionId.startsWith(prefix) &&
          removedModels[kind]!.contains(optionId.substring(prefix.length));
    });
  }

  AiSettings addCustomConfig(AiProvider provider) {
    return updateConfig(
      provider.copyWith(
        builtin: false,
        models: provider.isCodex && provider.models.isEmpty
            ? codexPresetModels
            : provider.models,
        imageModels: provider.isCodex && provider.imageModels.isEmpty
            ? codexPresetImageModels
            : provider.imageModels.isEmpty
            ? imageModelsForProvider(provider.type)
            : provider.imageModels,
      ),
    );
  }

  AiSettings removeConfig(String id) {
    final provider = findConfigById(id);
    if (provider == null || !provider.canDelete) {
      return this;
    }
    return copyWith(
      providers: providers.where((item) => item.id != id).toList(),
    )._clearDefaultSelectionsWhere(
      (_, optionId) => optionId.startsWith('$id::'),
    );
  }

  AiProvider? findConfigForSelection({
    required String providerId,
    required String? model,
    AiModelKind kind = AiModelKind.chat,
  }) {
    final config = findConfigById(providerId);
    if (config == null || !config.isValid) return null;
    if (!config.supportsModel(model, kind: kind)) return null;
    return config;
  }

  List<AiModelOption> get availableModelOptions =>
      availableModelOptionsForKind(AiModelKind.chat);

  List<AiModelOption> availableModelOptionsForKind(AiModelKind kind) {
    final options = <AiModelOption>[];
    final selectedDefaultId = defaultOptionIdForKind(kind);
    for (final config in providers) {
      if (!config.isTypeSupported || !config.enabled) {
        continue;
      }
      if (!config.isValid) continue;
      for (final model in config.modelsForKind(kind)) {
        final efforts = normalizeReasoningEfforts(
          lookupCatalogReasoningEfforts(model),
        );
        options.add(
          AiModelOption(
            providerId: config.id,
            providerDisplayName: config.displayName,
            model: model,
            kind: kind,
            isDefault: '${config.id}::$model' == selectedDefaultId,
            reasoningEfforts: efforts,
          ),
        );
      }
    }
    return options;
  }

  AiModelOption? findModelOptionById({
    required AiModelKind kind,
    required String? optionId,
  }) {
    if (optionId == null || optionId.trim().isEmpty) return null;
    for (final option in availableModelOptionsForKind(kind)) {
      if (option.id == optionId) return option;
    }
    return null;
  }

  String? defaultOptionIdForKind(AiModelKind kind) => switch (kind) {
    AiModelKind.chat => defaultChatModelId,
    AiModelKind.image => defaultImageModelId,
    AiModelKind.video || AiModelKind.audio => null,
  };

  String? defaultOptionIdForRole(AiModelRole role) => switch (role) {
    AiModelRole.planner => defaultPlannerModelId,
    AiModelRole.writer => defaultWriterModelId,
  };

  AiSettings setDefaultOptionId(AiModelKind kind, String? optionId) {
    _validateDefaultSelection(kind, optionId);
    return switch (kind) {
      AiModelKind.chat => copyWith(
        defaultChatModelId: optionId,
        defaultChatReasoningEffort: optionId == null
            ? null
            : reasoningEffortForOption(
                findModelOptionById(kind: AiModelKind.chat, optionId: optionId),
                optionId == defaultChatModelId
                    ? defaultChatReasoningEffort
                    : null,
              ),
      ),
      AiModelKind.image => copyWith(defaultImageModelId: optionId),
      AiModelKind.video || AiModelKind.audio => throw UnsupportedError(
        'Video requests choose their model explicitly',
      ),
    };
  }

  AiSettings setDefaultOptionIdForRole(AiModelRole role, String? optionId) {
    _validateDefaultSelection(AiModelKind.chat, optionId);
    return switch (role) {
      AiModelRole.planner => copyWith(defaultPlannerModelId: optionId),
      AiModelRole.writer => copyWith(defaultWriterModelId: optionId),
    };
  }

  void _validateDefaultSelection(AiModelKind kind, String? optionId) {
    if (optionId == null) {
      return;
    }
    if (findModelOptionById(kind: kind, optionId: optionId) == null) {
      throw ArgumentError.value(optionId, 'optionId', 'Model is unavailable');
    }
  }

  AiSettings _clearDefaultSelectionsWhere(
    bool Function(AiModelKind kind, String optionId) removed,
  ) {
    String? keep(AiModelKind kind, String? optionId) =>
        optionId != null && removed(kind, optionId) ? null : optionId;
    final chatId = keep(AiModelKind.chat, defaultChatModelId);
    return copyWith(
      defaultChatModelId: chatId,
      defaultChatReasoningEffort: chatId == defaultChatModelId
          ? defaultChatReasoningEffort
          : null,
      defaultImageModelId: keep(AiModelKind.image, defaultImageModelId),
      defaultPlannerModelId: keep(AiModelKind.chat, defaultPlannerModelId),
      defaultWriterModelId: keep(AiModelKind.chat, defaultWriterModelId),
    );
  }

  static List<AiProvider> mergeWithRequiredProviders(List<AiProvider> input) {
    final byId = <String, AiProvider>{};
    for (final provider in aiProviderBuiltinDefaults) {
      if (!provider.canDelete) {
        byId[provider.id] = provider;
      }
    }
    for (final provider in input) {
      byId[provider.id] = provider;
    }
    final builtins = <AiProvider>[
      for (final provider in aiProviderBuiltinDefaults)
        if (byId.containsKey(provider.id)) byId[provider.id]!,
    ];
    final builtinIds = builtins.map((provider) => provider.id).toSet();
    final customs =
        byId.values
            .where((provider) => !builtinIds.contains(provider.id))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    return [...builtins, ...customs];
  }
}

const _sentinel = Object();

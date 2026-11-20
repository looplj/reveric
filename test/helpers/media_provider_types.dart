// 职责: 为媒体协议测试选出走该协议的代表 provider 类型，供按 provider 类型查找渠道能力的接口使用。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/models/audio/channels.dart
import 'package:reveric/shared/models/audio/channels.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/models/video/request.dart';

/// 原生协议选可接中转站的 provider，保持型号识别回退；聚合平台只认精确 ID。
String videoProviderType(VideoProtocol protocol) => switch (protocol) {
  VideoProtocol.new_api_video => 'api88',
  VideoProtocol.ark_video => 'doubao',
  VideoProtocol.minimax_video_v2 => 'minimax',
  VideoProtocol.wan_video => 'qwen',
  VideoProtocol.agnes_video => 'agnes',
  VideoProtocol.openrouter_video => 'openrouter',
  VideoProtocol.atlascloud_video => 'atlascloud',
  VideoProtocol.purefox_media => 'purefox_media',
};

String audioProviderType(AudioProtocol protocol) => switch (protocol) {
  AudioProtocol.moss_audio => 'moss',
  AudioProtocol.new_api_speech => 'api88',
  AudioProtocol.seed_audio => 'volcengine',
  AudioProtocol.minimax_music => 'minimax',
  AudioProtocol.openrouter_speech => 'openrouter',
  AudioProtocol.qwen_tts => 'qwen',
  AudioProtocol.atlascloud_audio => 'atlascloud',
};

String imageProviderType(ImageProtocol protocol) => switch (protocol) {
  ImageProtocol.moss_image => 'moss',
  ImageProtocol.new_api_images => 'api88',
  ImageProtocol.agnes_image => 'agnes',
  ImageProtocol.qwen_image => 'qwen',
  ImageProtocol.ark_image => 'doubao',
  ImageProtocol.openrouter_image => 'openrouter',
  ImageProtocol.atlascloud_image => 'atlascloud',
  ImageProtocol.openai_images => 'openai_compatible',
  ImageProtocol.codex_image => 'codex',
  ImageProtocol.gemini_image => 'gemini',
  ImageProtocol.purefox_media => 'purefox_media',
  ImageProtocol.minimax_image => 'minimax',
};

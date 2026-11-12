// 职责: 维护供应商公开品牌资源和渠道入口。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/widgets/settings/provider_overview.dart
//   lib/shared/widgets/settings/provider_logo.dart

const providerChannelUrls = {
  'metaso': 'https://metaso.cn/minimax-h3/?s=Reveric',
  'purefox': 'https://purefox.org/keys',
  'purefox_media': 'https://img.purefox.org/',
  'api88': 'https://88api.ai/sign-up?aff=5q8X',
  'apikey': 'https://apikey.fun/register?aff=axonhub',
  'infistar': 'https://infistar.cc/register?aff=FQHYXMMS&ref_source=link',
  'ooki': 'https://ookiapi.com/',
  'openai': 'https://platform.openai.com/api-keys',
  'openrouter': 'https://openrouter.ai/settings/keys',
  'xai': 'https://console.x.ai/',
  'anthropic': 'https://platform.claude.com/settings/keys',
  'qwen': 'https://platform.qianwenai.com/api-keys',
  'qwen_token_plan':
      'https://www.qianwenai.com/benefits/tokenplan?shareCode=subTask..12980046..10274..,subTask..12980046..10274..',
  'gemini': 'https://aistudio.google.com/apikey',
  'deepseek': 'https://platform.deepseek.com/api_keys',
  'moonshot': 'https://platform.kimi.com/console/api-keys',
  'zhipu': 'https://z.ai/manage-apikey/apikey-list',
  'doubao': 'https://console.volcengine.com/ark/region:cn-beijing/apiKey',
  'volcengine': 'https://console.volcengine.com/ark/region:cn-beijing/apiKey',
  'minimax': 'https://platform.minimax.io/console/access',
  'agnes': 'https://platform.agnes-ai.com/',
  'atlascloud': 'https://www.atlascloud.ai?ref=6MQKFA',
};

const providerLogoAssets = <String, String>{
  'openai': 'assets/icons/providers/openai.png',
  'openai_compatible': 'assets/icons/providers/openai.png',
  'anthropic': 'assets/icons/providers/anthropic.png',
  'deepseek': 'assets/icons/providers/deepseek.png',
  'qwen': 'assets/icons/providers/qwen.png',
  'qwen_token_plan': 'assets/icons/providers/qwen.png',
  'gemini': 'assets/icons/providers/gemini.png',
  'moonshot': 'assets/icons/providers/moonshot.png',
  'zhipu': 'assets/icons/providers/zhipu.svg',
  'doubao': 'assets/icons/providers/doubao.png',
  'volcengine': 'assets/icons/providers/volcengine.png',
  'minimax': 'assets/icons/providers/minimax.png',
  'openrouter': 'assets/icons/providers/openrouter.png',
  'xai': 'assets/icons/providers/xai.png',
  'agnes': 'assets/icons/providers/agnes.png',
  'atlascloud': 'assets/icons/providers/atlascloud.png',
  'api88': 'assets/icons/providers/api88.png',
  'apikey': 'assets/icons/providers/apikey.png',
  'infistar': 'assets/icons/providers/infistar.png',
  'ooki': 'assets/icons/providers/ooki.png',
  'metaso': 'assets/icons/providers/metaso.png',
  'purefox': 'assets/icons/providers/purefox.png',
  'purefox_media': 'assets/icons/providers/purefox_media.png',
};

String? providerLogoAsset(String type) =>
    providerLogoAssets[type == 'codex' ? 'openai' : type];

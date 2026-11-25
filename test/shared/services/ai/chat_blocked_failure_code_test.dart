// 职责: 验证聊天发送被模型配置阻止时的失败码归类。
// 关联文件:
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/shared/models/ai_provider.dart
// 遵循的 Rules:
//   .agents/rules/code-style.md

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/chat_turn_runner.dart';

void main() {
  group('classifyChatProviderBlock', () {
    const model = 'test-chat-model';
    final configured = aiProviderBuiltinById(
      'openai',
    )!.copyWith(enabled: true, apiKey: 'test-key', models: [model]);

    final cases = <ChatSendBlock, AiProvider?>{
      ChatSendBlock.provider_missing: null,
      ChatSendBlock.provider_disabled: configured.copyWith(enabled: false),
      ChatSendBlock.provider_unsupported: configured.copyWith(type: 'unknown'),
      ChatSendBlock.api_key_missing: configured.copyWith(apiKey: ''),
      ChatSendBlock.base_url_missing: configured.copyWith(baseUrl: ''),
      ChatSendBlock.model_unavailable: configured.copyWith(models: ['other']),
    };

    for (final MapEntry(key: block, value: provider) in cases.entries) {
      test('reports ${block.name} for the bound provider', () {
        expect(classifyChatProviderBlock(provider, model), block);
      });
    }
  });
}

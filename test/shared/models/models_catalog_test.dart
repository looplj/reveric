// 职责: 验证模型目录的长度、输入模态、本地匹配优先级与 reasoning effort 档位解析
// 关联文件:
//   lib/shared/models/models_catalog.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/agent/agent_config.dart
//   lib/shared/database/app_database.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/database/app_database.dart'
    show notDeletedSentinel;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/models_catalog.dart';

final _reasoningProvider = AiProvider(
  audioModels: const [],
  videoModels: const [],
  id: 'test-provider',
  name: 'Test Provider',
  builtin: false,
  type: 'anthropic',
  enabled: true,
  apiKey: 'test-key',
  baseUrl: 'https://example.invalid',
  models: const ['deepseek-v4-flash'],
  imageModels: const [],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026),
  deletedAt: notDeletedSentinel,
);

void main() {
  group('ModelCatalogMatcher', () {
    const family = ModelCatalogEntry(
      matches: ['sample-*'],
      modalities: ModelCatalogModalities(input: ['text', 'image']),
      limit: ModelCatalogLimit(context: 200000),
    );
    const specialized = ModelCatalogEntry(
      matches: ['sample-pro-*'],
      limit: ModelCatalogLimit(context: 1000000),
    );
    const exact = ModelCatalogEntry(
      matches: ['sample-exact-alias'],
      modalities: ModelCatalogModalities(input: ['text']),
      limit: ModelCatalogLimit(context: 128000),
    );

    test('精确 ID 和精确别名优先于通配，最长固定前缀优先且不依赖声明顺序', () {
      const entries = {
        'sample': family,
        'sample-pro': specialized,
        'sample-pro-small': exact,
      };
      for (final source in [
        entries,
        Map<String, ModelCatalogEntry>.fromEntries(
          entries.entries.toList().reversed,
        ),
      ]) {
        final matcher = ModelCatalogMatcher(source);
        expect(matcher.lookup('sample-pro-small'), same(exact));
        expect(matcher.lookup('sample-exact-alias'), same(exact));
        expect(matcher.lookup('sample-pro-20300101'), same(specialized));
        expect(matcher.lookup('sample-next'), same(family));
        expect(matcher.lookup('vendor/sample-pro-small:free'), same(exact));
        expect(matcher.lookup('sampleish'), isNull);
      }
    });

    test('无通配声明的 ID 不隐式继承前缀，也不自动剥离日期', () {
      final matcher = ModelCatalogMatcher(const {'strict': exact});
      expect(matcher.lookup('strict'), same(exact));
      expect(matcher.lookup('strict-20300101'), isNull);
      expect(matcher.lookup('strict-custom'), isNull);
    });

    test('中间通配采用完整匹配，相同前缀时较长的固定后缀优先', () {
      const reasoning = ModelCatalogEntry(matches: ['sample-*-reasoning']);
      const nonReasoning = ModelCatalogEntry(
        matches: ['sample-*-non-reasoning'],
      );
      final matcher = ModelCatalogMatcher(const {
        'reasoning': reasoning,
        'non-reasoning': nonReasoning,
      });
      expect(matcher.lookup('sample-0309-reasoning'), same(reasoning));
      expect(matcher.lookup('sample-0309-non-reasoning'), same(nonReasoning));
      expect(matcher.lookup('sample-0309-reasoning-extra'), isNull);
      expect(matcher.lookup('other-sample-0309-reasoning'), isNull);
    });

    test('重复匹配项与多个通配符在目录初始化时拒绝', () {
      expect(
        () =>
            ModelCatalogMatcher(const {'sample': family, 'duplicate': family}),
        throwsArgumentError,
      );
      expect(
        () => ModelCatalogMatcher(const {
          'sample': ModelCatalogEntry(matches: ['sample-*-*']),
        }),
        throwsArgumentError,
      );
    });
  });

  group('图片输入模态', () {
    test('所有已收录模型显式配置输入模态，防止遗漏退化为不支持图片', () {
      for (final entry in modelsCatalog.entries) {
        expect(entry.value.modalities?.input, isNotNull, reason: entry.key);
        expect(
          entry.value.modalities!.input,
          contains('text'),
          reason: entry.key,
        );
      }
    });

    test('已收录型号按自身能力配置，不依赖系列兜底', () {
      for (final model in [
        'o3',
        'o4-mini',
        'claude-opus-4-6',
        'claude-haiku-4-5-20251001',
        'gemini-4-carbon',
        'gemini-4-argon',
        'gemini-flash-latest',
        'qwen3.8-max',
        'qwen3.6-plus',
        'kimi-k2.5',
        'kimi-k2.7-code',
        'glm-5.3-flash',
        'glm-5v-turbo',
        'grok-4.7',
        'doubao-seed-2-1-pro-260915',
        'minimax-m3',
        'MiniMax-M3',
        'mimo-v2.6-pro',
      ]) {
        expect(lookupCatalogImageInput(model), isTrue, reason: model);
      }
      for (final model in [
        'deepseek-chat',
        'qwen3.7-max',
        'kimi-k2-thinking',
        'glm-5.2',
        'minimax-m2.7',
        'MiniMax-M2.7-highspeed',
        'mimo-v2.5-pro',
      ]) {
        expect(lookupCatalogImageInput(model), isFalse, reason: model);
      }
    });

    for (final family in ['sonnet', 'opus', 'fable']) {
      test('$family 从主版本 5 起兜底，支持 claude 前缀和未来版本', () {
        for (final prefix in ['', 'claude-']) {
          expect(lookupCatalogImageInput('$prefix$family-4-9'), isFalse);
          expect(lookupCatalogImageInput('$prefix$family-5'), isTrue);
          expect(lookupCatalogImageInput('$prefix$family-5-1'), isTrue);
          expect(lookupCatalogImageInput('$prefix$family-10.2'), isTrue);
        }
      });
    }

    for (final (family, minimum) in [
      ('gpt-', 5),
      ('gemini-', 3),
      ('kimi-', 3),
      ('kimi-k', 3),
    ]) {
      test('$family 从主版本 $minimum 起兜底，不受未来版本位数影响', () {
        expect(lookupCatalogImageInput('$family${minimum - 1}.9'), isFalse);
        expect(lookupCatalogImageInput('$family$minimum'), isTrue);
        expect(lookupCatalogImageInput('$family$minimum.1-preview'), isTrue);
        expect(lookupCatalogImageInput('${family}10-fast'), isTrue);
      });
    }

    test('供应商前缀和路由变体使用同一本地目录', () {
      expect(lookupCatalogImageInput('anthropic/claude-opus-5:free'), isTrue);
      expect(lookupCatalogImageInput('google/gemini-2.5-pro:free'), isTrue);
      expect(lookupCatalogImageInput('gpt-5:free'), isTrue);
      expect(lookupCatalogImageInput('moonshotai/kimi-k3'), isTrue);
      expect(lookupCatalogImageInput('openai/gpt-5:free'), isTrue);
      expect(lookupCatalogImageInput('claude-opus-5'), isTrue);
    });

    test('未知模型和非指定系列不支持图片，也不匹配未声明的前缀', () {
      for (final model in [
        'custom-model',
        'gemini-2.5-proish',
        'claude-haiku-5',
        'gpt-5abc',
        'gpt-50abc',
        'my-gpt-5',
        'claude-gpt-5',
        'sonnet-latest',
        'gemini-latest',
      ]) {
        expect(lookupCatalogImageInput(model), isFalse, reason: model);
      }
    });

    test('显式通配共享完整模型配置', () {
      const model = 'claude-haiku-4-5-20251001';
      expect(lookupCatalogImageInput(model), isTrue);
      expect(lookupCatalogLimit(model)?.context, 200000);
      expect(resolveReasoningBudget(model, 'high'), 32000);
      expect(lookupCatalogImageInput('claude-haiku-4-5'), isTrue);
      expect(lookupCatalogLimit('claude-haiku-4-5')?.context, 200000);
    });

    test('模型选项暴露非空的派生图片输入能力', () {
      const option = AiModelOption(
        providerId: 'test',
        providerDisplayName: 'Test',
        model: 'gpt-5',
        kind: AiModelKind.chat,
      );
      expect(option.supportsImageInput, isTrue);
    });
  });

  group('normalizeReasoningEfforts', () {
    test('仅 none（只能开关、无分级）归一化出 on 档，用户才有办法开启推理', () {
      expect(normalizeReasoningEfforts(['none']), ['none', 'on']);
    });

    test('有真实分级的列表不注入 on，并按强度升序排列', () {
      expect(normalizeReasoningEfforts(['none', 'high', 'max']), [
        'none',
        'high',
        'max',
      ]);
      expect(normalizeReasoningEfforts(['low', 'medium', 'high']), [
        'low',
        'medium',
        'high',
      ]);
    });

    test('目录乱序的档位按强度重排，low 不会落在 high 后面', () {
      expect(normalizeReasoningEfforts(['none', 'high', 'max', 'low']), [
        'none',
        'low',
        'high',
        'max',
      ]);
    });

    test('非推理模型（null / 空列表）不产生档位', () {
      expect(normalizeReasoningEfforts(null), isNull);
      expect(normalizeReasoningEfforts([]), isEmpty);
    });
  });

  group('resolveReasoningEffort', () {
    test('thinking 字段模型保留 none/on，client 才能发出 thinking 开关', () {
      // kimi-k2.5 在 catalog 中标记 useThinkingField。
      expect(resolveReasoningEffort('none', modelId: 'kimi-k2.5'), 'none');
      expect(resolveReasoningEffort('on', modelId: 'kimi-k2.5'), 'on');
    });

    test('非 thinking 字段模型的开关值映射为 null，不发送无效 reasoning_effort', () {
      expect(resolveReasoningEffort('none', modelId: 'gpt-5'), isNull);
      expect(resolveReasoningEffort('on', modelId: 'glm-5.1'), isNull);
    });

    test('真实级别原样透传', () {
      expect(resolveReasoningEffort('medium', modelId: 'gpt-5'), 'medium');
      expect(resolveReasoningEffort('max', modelId: 'claude-fable-5'), 'max');
    });
  });

  group('default chat reasoning effort', () {
    const optionId = 'test-provider::deepseek-v4-flash';

    test('round-trips in AI settings JSON and clears with the chat model', () {
      const settings = AiSettings(
        defaultChatModelId: optionId,
        defaultChatReasoningEffort: 'max',
      );

      final restored = AiSettings.fromJson(settings.toJson());
      expect(restored.defaultChatModelId, optionId);
      expect(restored.defaultChatReasoningEffort, 'max');

      final cleared = restored.setDefaultOptionId(AiModelKind.chat, null);
      expect(cleared.defaultChatModelId, isNull);
      expect(cleared.defaultChatReasoningEffort, isNull);
    });

    test(
      'new chat uses the global effort while persisted session effort wins',
      () {
        final settings = AiSettings(
          providers: [_reasoningProvider],
          defaultChatModelId: optionId,
          defaultChatReasoningEffort: 'max',
        );

        expect(
          resolveSessionReasoningEffort(
            providerId: 'test-provider',
            model: 'deepseek-v4-flash',
            settings: settings,
          ),
          'max',
        );
        expect(
          resolveSessionReasoningEffort(
            providerId: 'test-provider',
            model: 'deepseek-v4-flash',
            persistedEffort: 'none',
            settings: settings,
          ),
          'none',
        );
      },
    );

    test('selecting a chat model initializes its supported default effort', () {
      final settings = AiSettings(
        providers: [_reasoningProvider],
      ).setDefaultOptionId(AiModelKind.chat, optionId);

      expect(settings.defaultChatModelId, optionId);
      expect(settings.defaultChatReasoningEffort, 'high');
    });
  });

  test('Kimi K3 is selectable and uses standard reasoning_effort levels', () {
    final k3 = lookupCatalogLimit('kimi-k3')!;
    final moonshot = aiProviderBuiltinDefaults.singleWhere(
      (provider) => provider.id == 'moonshot',
    );

    expect(k3.context, 1000000);
    expect(k3.output, 1000000);
    expect(lookupCatalogReasoningEfforts('kimi-k3'), ['low', 'high', 'max']);
    expect(useThinkingField('kimi-k3'), isFalse);
    expect(resolveReasoningEffort('max', modelId: 'kimi-k3'), 'max');
    expect(moonshot.models, contains('kimi-k3'));
  });

  test(
    'GPT-5.6 and GPT-6+ share 560K defaults while older GPT-5 stays at 256K',
    () {
      for (final model in [
        'gpt-5.6',
        'gpt-5.6-sol',
        'gpt-6-astra',
        'gpt-6.1-sol',
        'gpt-6-sol',
        'gpt-6-luna',
        'gpt-6-next',
        'openai/gpt-7:free',
        'gpt-10.1-next',
      ]) {
        expect(lookupCatalogLimit(model)?.context, 560000, reason: model);
        expect(lookupCatalogLimit(model)?.output, 128000, reason: model);
      }
      for (final model in ['gpt-5', 'gpt-5.4', 'gpt-5.5']) {
        expect(lookupCatalogLimit(model)?.context, 256000, reason: model);
      }
      expect(lookupCatalogLimit('gpt-4'), isNull);
      expect(lookupCatalogLimit('gpt-60ish'), isNull);
    },
  );

  test('new model entries have rounded limits and supported effort levels', () {
    const cases = [
      (
        'gpt-6-astra',
        560000,
        128000,
        ['low', 'medium', 'high', 'xhigh', 'max'],
      ),
      ('deepseek-flash', 1000000, 384000, ['none', 'low', 'high', 'max']),
      ('qwen3.8-max', 1000000, 128000, ['low', 'medium', 'xhigh']),
      ('qwen3.8-flash', 1000000, 128000, ['low', 'medium', 'xhigh']),
      ('qwen3.7-flash', 1000000, 128000, ['low', 'medium', 'high']),
      ('glm-5.3', 1000000, 128000, ['low', 'high', 'max']),
      ('glm-5.3-flash', 1000000, 128000, ['low', 'high', 'max']),
      (
        'claude-opus-5',
        1000000,
        128000,
        ['low', 'medium', 'high', 'xhigh', 'max'],
      ),
      (
        'claude-fable-5-1',
        1000000,
        128000,
        ['low', 'medium', 'high', 'xhigh', 'max'],
      ),
      ('gemini-4-carbon', 1000000, 64000, ['low', 'medium', 'high']),
      ('gemini-4-argon-preview', 1000000, 64000, ['low', 'medium', 'high']),
    ];
    for (final (id, context, output, efforts) in cases) {
      expect(lookupCatalogLimit(id)?.context, context, reason: id);
      expect(lookupCatalogLimit(id)?.output, output, reason: id);
      expect(lookupCatalogReasoningEfforts(id), efforts, reason: id);
    }
    expect(useThinkingField('deepseek-flash'), isTrue);
    expect(lookupCatalogLimit('qwen3.8-max-0902')?.context, 1000000);
  });

  test(
    'free model aliases use the shared 200K configuration before family rules',
    () {
      for (final modelId in const [
        'glm-5.3-flash-free',
        'mimo-v2.5-free',
        'deepseek-v4-flash-free',
        'deepseek-v4.1-flash-free',
      ]) {
        expect(lookupCatalogLimit(modelId)?.context, 200000, reason: modelId);
        expect(lookupCatalogImageInput(modelId), isFalse, reason: modelId);
      }
    },
  );
}

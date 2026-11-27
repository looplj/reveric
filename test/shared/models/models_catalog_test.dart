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
  asrModels: const [],
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
  test(
    'retired chat models have no catalog capabilities or temperature rules',
    () {
      final matcher = ModelCatalogMatcher(modelsCatalog);
      for (final id in [
        'o1',
        'o3',
        'o3-mini',
        'o4-mini',
        'kimi-k2-instruct',
        'kimi-k2-thinking',
        'gpt-4',
        'gpt-4-turbo',
        'gpt-4o',
        'gpt-4.1',
      ]) {
        expect(matcher.lookup(id), isNull, reason: id);
        expect(
          lookupTemperatureSupport(id),
          ModelTemperatureSupport.adjustable,
          reason: id,
        );
        expect(
          aiProviderBuiltinDefaults.expand((provider) => provider.models),
          isNot(contains(id)),
        );
      }
    },
  );

  test('Gemini 4 shares limits and modalities while Hydrogen adds xhigh', () {
    final matcher = ModelCatalogMatcher(modelsCatalog);
    final carbon = matcher.lookup('gemini-4-carbon')!;
    expect(matcher.lookup('google/gemini-4-argon-preview:free'), same(carbon));
    for (final id in [
      'gemini-4-hydrogen',
      'GOOGLE/GEMINI-4-HYDROGEN-PREVIEW:free',
    ]) {
      final hydrogen = matcher.lookup(id)!;
      expect(hydrogen.limit, same(carbon.limit));
      expect(hydrogen.modalities, same(carbon.modalities));
      expect(lookupCatalogReasoningEfforts(id), [
        'low',
        'medium',
        'high',
        'xhigh',
      ]);
      expect(useThinkingLevel(id), isTrue);
      expect(supportsMultimodalToolResults(id), isTrue);
      expect(resolveReasoningBudget(id, 'high'), isNull);
      expect(resolveAgentMaxTokens(id), 48000);
    }
    expect(carbon.reasoningEfforts, ['low', 'medium', 'high']);
    expect(useThinkingLevel('gemini-3.8-flash'), isTrue);
    expect(useThinkingLevel('gemini-2.5-pro'), isFalse);
    expect(supportsMultimodalToolResults('gemini-3.8-flash'), isTrue);
    expect(supportsMultimodalToolResults('gemini-2.5-pro'), isFalse);
    expect(useThinkingLevel('claude-fable-5'), isFalse);
    expect(lookupCatalogReasoningEfforts('gemini-4-unknown'), isNull);
    expect(
      aiProviderBuiltinDefaults.firstWhere((p) => p.id == 'gemini').models,
      contains('gemini-4-hydrogen'),
    );
  });

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

    test('GPT-6 家族匹配带小版本的型号，专用配置优先', () {
      final matcher = ModelCatalogMatcher(modelsCatalog);
      for (final id in [
        'gpt-6-next',
        'gpt-6.2-next',
        'openai/GPT-6.2-NEXT:free',
      ]) {
        expect(matcher.lookup(id), same(modelsCatalog['gpt-6']), reason: id);
      }
      expect(
        matcher.lookup('gpt-6.1-sol-20261125'),
        same(modelsCatalog['gpt-6-astra']),
      );
      expect(matcher.lookup('gpt-60.2-next'), isNull);
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

    test(
      'unknown chat models offer all efforts and use the provider default',
      () {
        const unknownIds = ['custom-chat', 'openai/GPT-6.2-NEXT:free'];
        final settings = AiSettings(
          providers: [
            _reasoningProvider.copyWith(
              type: 'openai',
              models: [
                ...unknownIds,
                'gpt-6.2-sol',
                'grok-4.20-non-reasoning',
                'deepseek-v4-flash-free',
                'kimi-k2.5',
              ],
              imageModels: ['custom-image'],
            ),
          ],
        );
        final options = {
          for (final option in settings.availableModelOptions)
            option.model: option,
        };

        for (final id in unknownIds) {
          final option = options[id]!;
          expect(option.reasoningEfforts, [
            'none',
            'minimal',
            'low',
            'medium',
            'high',
            'xhigh',
            'max',
          ]);
          final defaultEffort = reasoningEffortForOption(option, null);
          expect(defaultEffort, 'none');
          expect(resolveReasoningEffort(defaultEffort, modelId: id), isNull);
          expect(
            resolveSessionReasoningEffort(
              providerId: option.providerId,
              model: id,
              persistedEffort: 'minimal',
              settings: settings,
            ),
            'minimal',
          );
        }

        expect(options['gpt-6.2-sol']!.reasoningEfforts, [
          'low',
          'medium',
          'high',
          'xhigh',
          'max',
        ]);
        expect(
          reasoningEffortForOption(options['gpt-6.2-sol'], null),
          'medium',
        );
        expect(options['grok-4.20-non-reasoning']!.reasoningEfforts, isNull);
        expect(options['deepseek-v4-flash-free']!.reasoningEfforts, isNull);
        expect(options['kimi-k2.5']!.reasoningEfforts, ['none', 'on']);
        expect(
          settings
              .availableModelOptionsForKind(AiModelKind.image)
              .single
              .reasoningEfforts,
          isNull,
        );
      },
    );

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
      (
        'openai/GPT-6.2-SOL-preview:free',
        1050000,
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

  test('request temperature combines provider opt-in and catalog aliases', () {
    const options = AgentConfig(temperature: 0.3);
    expect(options.requestTemperature('custom-model'), isNull);
    final enabled = options.copyWith(enableTemperature: true);
    expect(enabled.requestTemperature('custom-model'), 0.3);
    expect(
      enabled.requestTemperature('vendor/CLAUDE-OPUS-4-7-latest:free'),
      isNull,
    );
    expect(enabled.requestTemperature('deepseek-flash'), 0.3);
    expect(
      enabled
          .copyWith(reasoningEffort: 'high')
          .requestTemperature('deepseek-flash'),
      isNull,
    );
    expect(
      enabled
          .copyWith(reasoningEffort: 'high')
          .requestTemperature('deepseek-v4-flash-free'),
      0.3,
    );
  });

  group('resolveRequestTemperature', () {
    test('adjustable and unknown models keep the configured temperature', () {
      expect(
        resolveRequestTemperature(
          modelId: 'custom-chat-model',
          temperature: 0.7,
        ),
        0.7,
      );
      expect(resolveRequestTemperature(modelId: null, temperature: 0.7), 0.7);
      expect(
        resolveRequestTemperature(
          modelId: 'deepseek-chat',
          temperature: 0.2,
          reasoningEffort: 'high',
        ),
        0.2,
      );
      expect(
        resolveRequestTemperature(
          modelId: 'gemini-4-hydrogen',
          temperature: 0.4,
          reasoningEffort: 'high',
        ),
        0.4,
      );
    });

    test('fixed-sampling models omit temperature at every effort', () {
      for (final id in [
        'gpt-5',
        'gpt-5-mini',
        'gpt-6-astra',
        'gpt-6.2-sol',
        'gpt-6.2-next',
        'gpt-6-next',
        'kimi-k3',
        'kimi-k2.6',
        'kimi-k2.7-code',
        'deepseek-reasoner',
        'claude-opus-4-7',
        'anthropic/CLAUDE-OPUS-4-8-latest:free',
        'claude-sonnet-5',
        'claude-fable-5',
        'openai/gpt-6-sol',
        'gpt-6-luna',
      ]) {
        expect(
          resolveRequestTemperature(modelId: id, temperature: 0.7),
          isNull,
          reason: id,
        );
        expect(
          resolveRequestTemperature(
            modelId: id,
            temperature: 0.7,
            reasoningEffort: 'none',
          ),
          isNull,
          reason: id,
        );
      }
    });

    test('gpt-5.1 and later omit temperature only while reasoning', () {
      for (final id in [
        'gpt-5.1',
        'gpt-5.2',
        'gpt-5.4',
        'openai/gpt-5.6-sol',
      ]) {
        expect(
          resolveRequestTemperature(modelId: id, temperature: 0.7),
          0.7,
          reason: id,
        );
        expect(
          resolveRequestTemperature(
            modelId: id,
            temperature: 0.7,
            reasoningEffort: 'none',
          ),
          0.7,
          reason: id,
        );
        expect(
          resolveRequestTemperature(
            modelId: id,
            temperature: 0.7,
            reasoningEffort: 'medium',
          ),
          isNull,
          reason: id,
        );
      }
    });

    test('thinking models omit temperature only while thinking is on', () {
      for (final id in [
        'claude-sonnet-4-6',
        'deepseek-v4-flash',
        'qwen3.7-max',
        'doubao-seed-2-0-pro',
      ]) {
        expect(
          resolveRequestTemperature(modelId: id, temperature: 0.3),
          0.3,
          reason: id,
        );
        expect(
          resolveRequestTemperature(
            modelId: id,
            temperature: 0.3,
            reasoningEffort: 'none',
          ),
          0.3,
          reason: id,
        );
        expect(
          resolveRequestTemperature(
            modelId: id,
            temperature: 0.3,
            reasoningEffort: 'high',
          ),
          isNull,
          reason: id,
        );
        expect(
          resolveRequestTemperature(
            modelId: id,
            temperature: 0.3,
            reasoningEffort: 'on',
          ),
          isNull,
          reason: id,
        );
      }
    });

    test('a thinking budget without an effort still drops temperature', () {
      expect(
        resolveRequestTemperature(
          modelId: 'claude-haiku-4-5',
          temperature: 0.7,
          reasoningBudget: 2048,
        ),
        isNull,
      );
      expect(
        resolveRequestTemperature(
          modelId: 'claude-haiku-4-5',
          temperature: 0.7,
          reasoningEffort: 'none',
          reasoningBudget: 2048,
        ),
        0.7,
      );
    });
  });
}

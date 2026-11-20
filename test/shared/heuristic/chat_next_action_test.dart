// 职责: 测试下一步建议的白名单裁决、空态固定目录与当前回合建议提取 — 覆盖非法项丢弃、超额截断、空态目录过滤与跨 round 扫描。
// 关联文件:
//   lib/shared/heuristic/chat_next_action.dart
//   lib/shared/models/feature_id.dart
//   lib/shared/models/ai_chat_models.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/heuristic/chat_next_action.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/feature_id.dart';

const _fullEnv = ChatNextActionEnvironment(
  suggestionsEnabled: true,
  metadataReady: true,
  setupDone: true,
);

void main() {
  test(
    'attribution uses the initiating user turn across assistant rounds and replacements',
    () {
      const block = AiSuggestNextActionBlock(
        id: 'b1',
        callId: 'call1',
        suggestions: [],
      );
      final messages = [
        AiMessage.user(id: 'u1', content: 'hello'),
        AiMessage.assistant(id: 'a1', content: '', blocks: [block]),
        AiMessage.assistant(id: 'a2', content: 'done'),
      ];
      expect(latestSuggestNextActionTurn(messages), (
        block: block,
        userMessageId: 'u1',
      ));
      const replacement = AiSuggestNextActionBlock(
        id: 'b2',
        callId: 'call2',
        suggestions: [],
      );
      messages.add(
        AiMessage.assistant(id: 'a3', content: '', blocks: [replacement]),
      );
      expect(latestSuggestNextActionTurn(messages), (
        block: replacement,
        userMessageId: 'u1',
      ));
      messages.add(AiMessage.user(id: 'u2', content: 'next'));
      expect(latestSuggestNextActionTurn(messages), isNull);
      expect(
        latestSuggestNextActionTurn([
          AiMessage.assistant(id: 'orphan', content: '', blocks: [block]),
        ]),
        (block: block, userMessageId: null),
      );
    },
  );

  test(
    'prompt intents survive validation and persisted session restoration',
    () {
      for (final intent in ChatNextActionIntent.values) {
        final result = ChatNextActionArbiter.judge([
          {
            'kind': 'prompt',
            'intent': intent.name,
            'label': '建议',
            'prompt': '具体请求',
          },
        ]);
        expect(result.drops, isEmpty);
        final restored = deserializeChatNextAction(
          serializeChatNextAction(result.actions.single),
        )!;
        expect((restored.target as PromptActionTarget).intent, intent);
        expect((restored.target as PromptActionTarget).prompt, '具体请求');
      }
    },
  );

  test(
    'missing intent continues current chat; unknown intent cannot silently change destination',
    () {
      final legacy = {
        'id': 'legacy',
        'kind': 'prompt',
        'label': '继续',
        'prompt': '继续写',
      };
      expect(
        (deserializeChatNextAction(legacy)!.target as PromptActionTarget)
            .intent,
        ChatNextActionIntent.continue_chat,
      );
      expect(
        (ChatNextActionArbiter.judge([legacy]).actions.single.target
                as PromptActionTarget)
            .intent,
        ChatNextActionIntent.continue_chat,
      );
      for (final invalid in ['general', '', 1]) {
        final raw = {...legacy, 'intent': invalid};
        expect(
          ChatNextActionArbiter.judge([raw]).drops.single.reason,
          'unknown_intent',
        );
        expect(deserializeChatNextAction(raw), isNull);
      }
    },
  );

  group('ChatNextActionArbiter.judge', () {
    test('work navigation targets do not require a creation record', () {
      final result = ChatNextActionArbiter.judge([
        {'kind': 'work', 'label': '打开', 'work_id': 'old'},
        {
          'kind': 'work',
          'label': '继续',
          'work_id': 'new_work',
          'prompt': '  写第一集  ',
        },
        {'kind': 'work', 'label': '缺少作品 ID', 'work_id': ' '},
      ], allowFeatures: false);
      expect(result.actions, hasLength(2));
      final openTarget = result.actions.first.target as WorkActionTarget;
      expect(openTarget.workId, 'old');
      expect(openTarget.prompt, isNull);
      expect(result.drops.single.reason, 'missing_work_id');
      final restored = deserializeChatNextAction(
        serializeChatNextAction(result.actions.last),
      )!;
      final target = restored.target as WorkActionTarget;
      expect(target.workId, 'new_work');
      expect(target.prompt, '写第一集');
    });

    test('保留合法的 prompt 与 feature 建议', () {
      final result = ChatNextActionArbiter.judge([
        {'kind': 'prompt', 'label': '核对第 3 章时间线', 'prompt': '请核对第 3 章的时间线'},
        {
          'kind': 'feature',
          'label': '去圆桌聊聊',
          'feature': 'ai_council',
          'seed': '木匣该不该交代',
        },
      ]);

      expect(result.drops, isEmpty);
      expect(result.actions, hasLength(2));
      expect(
        result.actions.first.target,
        isA<PromptActionTarget>().having(
          (t) => t.prompt,
          'prompt',
          '请核对第 3 章的时间线',
        ),
      );
      expect(
        result.actions[1].target,
        isA<FeatureActionTarget>()
            .having((t) => t.feature, 'feature', FeatureId.ai_council)
            .having((t) => t.seedText, 'seed', '木匣该不该交代'),
      );
    });

    test('枚举外的 feature 被丢弃，其余照常挂', () {
      final result = ChatNextActionArbiter.judge([
        {'kind': 'feature', 'label': '去写作模式', 'feature': 'ai_chat'},
        {'kind': 'feature', 'label': '去小剧场', 'feature': 'ai_theater'},
      ]);

      expect(result.actions, hasLength(1));
      expect(result.actions.single.feature, FeatureId.ai_theater);
      expect(result.drops.single.reason, 'feature_not_whitelisted');
    });

    test('模型编造的功能名被丢弃', () {
      final result = ChatNextActionArbiter.judge([
        {'kind': 'feature', 'label': '去魔法工坊', 'feature': 'ai_magic_forge'},
      ]);

      expect(result.actions, isEmpty);
      expect(result.drops.single.reason, 'feature_not_whitelisted');
    });

    test('kind=prompt 缺 prompt → 该条丢弃', () {
      final result = ChatNextActionArbiter.judge([
        {'kind': 'prompt', 'label': '继续'},
      ]);

      expect(result.actions, isEmpty);
      expect(result.drops.single.reason, 'missing_prompt');
    });

    test('缺 label → 该条丢弃', () {
      final result = ChatNextActionArbiter.judge([
        {'kind': 'prompt', 'prompt': '写点什么'},
      ]);

      expect(result.actions, isEmpty);
      expect(result.drops.single.reason, 'missing_label');
    });

    test('未知 kind → 该条丢弃', () {
      final result = ChatNextActionArbiter.judge([
        {'kind': 'navigate', 'label': '去别处'},
      ]);

      expect(result.actions, isEmpty);
      expect(result.drops.single.reason, 'unknown_kind');
    });

    test('传 5 条 → 最多挂 3 条，其余记 drop', () {
      final result = ChatNextActionArbiter.judge([
        for (var i = 0; i < 5; i++)
          {'kind': 'prompt', 'label': '建议 $i', 'prompt': '提示词 $i'},
      ]);

      expect(result.actions, hasLength(chatNextActionMaxSuggestions));
      expect(result.drops, hasLength(2));
      expect(
        result.drops.map((d) => d.reason),
        everyElement('exceeds_max_suggestions'),
      );
    });

    test('有角色卡 → 角色扮演建议保留，seed 原样带走当角色名', () {
      final result = ChatNextActionArbiter.judge([
        {
          'kind': 'feature',
          'label': '和顾长戈聊两句',
          'feature': 'ai_roleplay',
          'seed': '顾长戈',
        },
      ]);

      expect(result.drops, isEmpty);
      expect(
        result.actions.single.target,
        isA<FeatureActionTarget>()
            .having((t) => t.feature, 'feature', FeatureId.ai_roleplay)
            .having((t) => t.seedText, 'seed', '顾长戈'),
      );
    });

    test('非对象项被丢弃', () {
      final result = ChatNextActionArbiter.judge(['去圆桌']);

      expect(result.actions, isEmpty);
      expect(result.drops.single.reason, 'not_an_object');
    });
  });

  group('resolveNextActionCharacterId', () {
    const characters = [
      (id: 'c1', name: '顾长戈'),
      (id: 'c2', name: '顾庭安'),
      (id: 'c3', name: ''),
    ];

    test('精确匹配（含首尾空白）', () {
      expect(resolveNextActionCharacterId(characters, ' 顾长戈 '), 'c1');
    });

    test('唯一包含匹配', () {
      expect(resolveNextActionCharacterId(characters, '顾长戈（主角）'), 'c1');
    });

    test('匹配到多个时不猜 —— 宁可停在选择器也不要进错角色', () {
      expect(resolveNextActionCharacterId(characters, '顾'), isNull);
    });

    test('空名角色不会吞掉任意 seed', () {
      expect(resolveNextActionCharacterId(characters, '沈砚'), isNull);
    });

    test('seed 为空或全空白 → null', () {
      expect(resolveNextActionCharacterId(characters, null), isNull);
      expect(resolveNextActionCharacterId(characters, '   '), isNull);
    });
  });

  group('emptyStateActions', () {
    test('默认包含 plan_today + council + theater，顺序稳定', () {
      final actions = emptyStateActions(
        _fullEnv.copyWith(metadataReady: false),
      );

      expect(actions.map((a) => a.id), [
        'plan_today',
        'goto_council',
        'goto_theater',
      ]);
    });

    test('无封面且元数据齐备 → 追加封面卡片', () {
      final actions = emptyStateActions(_fullEnv);

      expect(actions.map((a) => a.id), [
        'plan_today',
        'goto_council',
        'goto_theater',
        'goto_cover_studio',
      ]);
    });

    test('已有封面 → 不出现封面卡片', () {
      final actions = emptyStateActions(_fullEnv.copyWith(hasCover: true));

      expect(actions.map((a) => a.id), isNot(contains('goto_cover_studio')));
    });

    test('元数据未齐 / 还是草稿 → 不出现封面卡片', () {
      expect(
        emptyStateActions(
          _fullEnv.copyWith(metadataReady: false),
        ).map((a) => a.id),
        isNot(contains('goto_cover_studio')),
      );
      expect(
        emptyStateActions(_fullEnv.copyWith(setupDone: false)).map((a) => a.id),
        isNot(contains('goto_cover_studio')),
      );
    });

    test('开关关闭 → 整个空态推荐区为空', () {
      expect(
        emptyStateActions(_fullEnv.copyWith(suggestionsEnabled: false)),
        isEmpty,
      );
    });
  });

  group('序列化往返', () {
    test('prompt 建议往返后 target 不变', () {
      final original = ChatNextAction(
        id: 'suggest_prompt_0',
        label: '核对时间线',
        target: const PromptActionTarget('请核对第 3 章的时间线'),
      );

      final restored = deserializeChatNextAction(
        serializeChatNextAction(original),
      );

      expect(restored, isNotNull);
      expect(restored!.label, '核对时间线');
      expect(
        restored.target,
        isA<PromptActionTarget>().having(
          (t) => t.prompt,
          'prompt',
          '请核对第 3 章的时间线',
        ),
      );
    });

    test('feature 建议往返后 seed 不变', () {
      final original = ChatNextAction(
        id: 'suggest_feature_ai_theater_1',
        feature: FeatureId.ai_theater,
        label: '先演一遍',
        target: const FeatureActionTarget(
          FeatureId.ai_theater,
          seedText: '三舱对峙',
        ),
      );

      final restored = deserializeChatNextAction(
        serializeChatNextAction(original),
      );

      expect(restored, isNotNull);
      expect(
        restored!.target,
        isA<FeatureActionTarget>()
            .having((t) => t.feature, 'feature', FeatureId.ai_theater)
            .having((t) => t.seedText, 'seed', '三舱对峙'),
      );
    });

    test('历史块里出现白名单外的 feature → 反序列化为 null，不渲染', () {
      expect(
        deserializeChatNextAction({
          'id': 'x',
          'kind': 'feature',
          'label': '去写作',
          'feature': 'ai_chat',
        }),
        isNull,
      );
    });
  });

  group('当前回合建议提取', () {
    AiMessage suggestionMessage(String id, String callId) {
      return AiMessage.assistant(
        id: id,
        content: '',
        blocks: [
          AiSuggestNextActionBlock(
            id: 'suggest_$callId',
            callId: callId,
            suggestions: const [
              {'id': 's0', 'kind': 'prompt', 'label': '排大纲', 'prompt': '排大纲'},
            ],
          ),
        ],
      );
    }

    test('建议挂在前一 round、收尾正文另起一条 assistant 消息时仍能取到', () {
      // 一次 agent 回合按 round 拆成多条 assistant 消息，这是线上最常见的形态：
      // 模型调完 SuggestNextAction 后还会再说一句收尾话。
      final block = latestSuggestNextActionBlock([
        AiMessage.user(id: 'u1', content: '继续'),
        suggestionMessage('a1', 'call_1'),
        AiMessage.assistant(id: 'a2', content: '挂好了，三条建议在输入框上方。'),
      ]);

      expect(block, isNotNull);
      expect(block!.callId, 'call_1');
    });

    test('用户发出新消息后上一轮建议失效', () {
      final block = latestSuggestNextActionBlock([
        suggestionMessage('a1', 'call_1'),
        AiMessage.user(id: 'u2', content: '换个方向'),
        AiMessage.assistant(id: 'a2', content: '好的。'),
      ]);

      expect(block, isNull);
    });

    test('同一回合挂了两次时取最新一条', () {
      final block = latestSuggestNextActionBlock([
        AiMessage.user(id: 'u1', content: '继续'),
        suggestionMessage('a1', 'call_1'),
        suggestionMessage('a2', 'call_2'),
      ]);

      expect(block!.callId, 'call_2');
    });

    test('本轮没挂建议时返回 null', () {
      final block = latestSuggestNextActionBlock([
        AiMessage.user(id: 'u1', content: '继续'),
        AiMessage.assistant(id: 'a1', content: '写完了。'),
      ]);

      expect(block, isNull);
    });
  });
}

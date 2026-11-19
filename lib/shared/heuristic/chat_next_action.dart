// 职责: Chat 下一步建议的数据模型、白名单裁决、空态固定目录与当前回合建议提取
// 关联文件:
//   lib/shared/models/feature_id.dart
//   lib/shared/models/ai_chat_models.dart
//   lib/shared/services/ai/tools_suggest_next_action.dart
//   lib/shared/widgets/ai/chat/next_action_bar.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/heuristic.json
//   assets/translations/zh-CN/heuristic.json
import '../localization/locale_keys.dart';
import '../models/ai_chat_models.dart';
import '../models/feature_id.dart';

/// 模型可推荐的功能白名单。
///
/// 模型只能从这里选目标；schema 枚举与裁决器共用同一份，避免两处漂移。
/// monologue 结构上支持，暂不放开（见方案「已知妥协 3」）。
const List<FeatureId> chatNextActionFeatureWhitelist = [
  FeatureId.ai_council,
  FeatureId.ai_theater,
  FeatureId.ai_roleplay,
  FeatureId.ai_cover_studio,
];

/// SuggestNextAction schema 使用的固定 feature 枚举。
///
/// 工具契约不得随运行时状态变化；时机与是否该推由 prompt / skill 指引模型，
/// 客户端只做白名单形状校验，不做动态可达性裁剪。
const List<String> chatNextActionFeatureKeys = [
  'ai_council',
  'ai_theater',
  'ai_roleplay',
  'ai_cover_studio',
];

/// 建议点击后的去向。
sealed class ChatNextActionTarget {
  const ChatNextActionTarget();
}

/// 提示词建议的用途；未指定时继续当前对话。
enum ChatNextActionIntent {
  continue_chat,
  new_chat,
  continue_in_new_chat,
  agent_rule,
  agent_skill;

  static ChatNextActionIntent? parse(Object? value) {
    if (value == null) {
      return continue_chat;
    }
    for (final intent in values) {
      if (intent.name == value) {
        return intent;
      }
    }
    return null;
  }
}

/// 提示词类：点击后把 [prompt] 填入 composer，不自动发送。
final class PromptActionTarget extends ChatNextActionTarget {
  const PromptActionTarget(
    this.prompt, {
    this.intent = ChatNextActionIntent.continue_chat,
  });

  final String prompt;
  final ChatNextActionIntent intent;
}

/// 跳转类：点击后打开 [feature]，[seedText] 作为目标功能输入框的预填文本。
final class FeatureActionTarget extends ChatNextActionTarget {
  const FeatureActionTarget(this.feature, {this.seedText});

  final FeatureId feature;
  final String? seedText;
}

/// 打开新作品，或在新作品中预填后续任务。
final class WorkActionTarget extends ChatNextActionTarget {
  const WorkActionTarget(this.workId, {this.prompt});

  final String workId;
  final String? prompt;
}

/// 统一展示模型 — 模型产出的建议与空态固定目录共用。
class ChatNextAction {
  const ChatNextAction({
    required this.id,
    required this.label,
    required this.target,
    this.feature,
    this.subtitle,
    this.labelKey,
    this.subtitleKey,
  });

  final String id;

  /// 跳转类指向的功能；提示词类为 null。
  final FeatureId? feature;

  /// 展示文案。模型产出时是运行时内容（不参与 i18n）；
  /// 空态目录项这里留空，由 [labelKey] 在 UI 层求值。
  final String label;
  final String? subtitle;

  /// 空态目录项的 locale key；模型产出的建议恒为 null。
  final String? labelKey;
  final String? subtitleKey;

  final ChatNextActionTarget target;

  bool get isFeatureTarget => target is FeatureActionTarget;
}

/// 空态目录与工具开关共用的环境事实。
///
/// 模型建议不做动态可达性裁决；`hasCover` / `metadataReady` / `setupDone`
/// 只服务空态固定目录的封面项过滤。
class ChatNextActionEnvironment {
  const ChatNextActionEnvironment({
    this.suggestionsEnabled = true,
    this.hasCover = false,
    this.metadataReady = false,
    this.setupDone = false,
  });

  /// 用户是否在设置里开启了下一步建议。
  final bool suggestionsEnabled;

  /// 仅空态目录使用。
  final bool hasCover;
  final bool metadataReady;
  final bool setupDone;

  ChatNextActionEnvironment copyWith({
    bool? suggestionsEnabled,
    bool? hasCover,
    bool? metadataReady,
    bool? setupDone,
  }) {
    return ChatNextActionEnvironment(
      suggestionsEnabled: suggestionsEnabled ?? this.suggestionsEnabled,
      hasCover: hasCover ?? this.hasCover,
      metadataReady: metadataReady ?? this.metadataReady,
      setupDone: setupDone ?? this.setupDone,
    );
  }
}

/// 一条被丢弃的建议及其原因。
typedef ChatNextActionDrop = ({int index, String reason});

/// 裁决结果：保留项 + 丢弃原因。
typedef ChatNextActionJudgement = ({
  List<ChatNextAction> actions,
  List<ChatNextActionDrop> drops,
});

/// 单次工具调用最多挂多少条建议。
const int chatNextActionMaxSuggestions = 3;

/// 模型建议的白名单裁决器 —— 工具层与 UI 层共用同一份逻辑。
abstract final class ChatNextActionArbiter {
  /// 逐条校验模型给的 raw 建议，丢弃非法项，最多保留 3 条。
  ///
  /// 校验字段形状和功能白名单，作品是否可打开由导航入口检查。
  /// 调用方按 [ChatNextActionDrop] 记录丢弃原因。
  static ChatNextActionJudgement judge(
    List<dynamic> raw, {
    bool allowFeatures = true,
  }) {
    final actions = <ChatNextAction>[];
    final drops = <ChatNextActionDrop>[];

    for (var index = 0; index < raw.length; index++) {
      if (actions.length >= chatNextActionMaxSuggestions) {
        drops.add((index: index, reason: 'exceeds_max_suggestions'));
        continue;
      }
      final item = raw[index];
      if (item is! Map) {
        drops.add((index: index, reason: 'not_an_object'));
        continue;
      }
      final map = item.cast<dynamic, dynamic>();
      final kind = _string(map['kind']);
      final label = _string(map['label']);
      if (label.isEmpty) {
        drops.add((index: index, reason: 'missing_label'));
        continue;
      }

      switch (kind) {
        case 'prompt':
          final intent = ChatNextActionIntent.parse(map['intent']);
          if (intent == null) {
            drops.add((index: index, reason: 'unknown_intent'));
            continue;
          }
          final prompt = _string(map['prompt']);
          if (prompt.isEmpty) {
            drops.add((index: index, reason: 'missing_prompt'));
            continue;
          }
          actions.add(
            ChatNextAction(
              id: 'suggest_prompt_$index',
              label: label,
              target: PromptActionTarget(prompt, intent: intent),
            ),
          );
        case 'feature':
          if (!allowFeatures) {
            drops.add((index: index, reason: 'feature_navigation_unavailable'));
            continue;
          }
          final featureKey = _string(map['feature']);
          final feature = FeatureIdX.fromStorageKey(featureKey);
          if (feature == null ||
              !chatNextActionFeatureWhitelist.contains(feature)) {
            drops.add((index: index, reason: 'feature_not_whitelisted'));
            continue;
          }
          final seed = _string(map['seed']);
          actions.add(
            ChatNextAction(
              id: 'suggest_feature_${feature.storageKey}_$index',
              feature: feature,
              label: label,
              target: FeatureActionTarget(
                feature,
                seedText: seed.isEmpty ? null : seed,
              ),
            ),
          );
        case 'work':
          final workId = _string(map['work_id']);
          if (workId.isEmpty) {
            drops.add((index: index, reason: 'missing_work_id'));
            continue;
          }
          final prompt = _string(map['prompt']);
          actions.add(
            ChatNextAction(
              id: 'suggest_work_${workId}_$index',
              label: label,
              target: WorkActionTarget(
                workId,
                prompt: prompt.isEmpty ? null : prompt,
              ),
            ),
          );
        default:
          drops.add((index: index, reason: 'unknown_kind'));
      }
    }

    return (actions: actions, drops: drops);
  }
}

/// 空会话固定目录。
///
/// 空会话时一次模型调用都还没发生，建议只能来自客户端。这是唯一保留的本地逻辑，
/// 且是固定目录 + 简单可用性过滤，不是规则引擎。顺序稳定。
List<ChatNextAction> emptyStateActions(ChatNextActionEnvironment env) {
  if (!env.suggestionsEnabled) {
    return const [];
  }
  return [
    const ChatNextAction(
      id: 'plan_today',
      label: '',
      labelKey: LocaleKeys.aiAgentQuickOrchestratorPlanToday,
      subtitleKey: LocaleKeys.aiAgentQuickOrchestratorPlanTodaySub,
      // prompt 文案本身也是 locale key，由 UI 层求值后再填入 composer。
      target: PromptActionTarget(
        LocaleKeys.aiAgentQuickOrchestratorPlanTodayPrompt,
      ),
    ),
    const ChatNextAction(
      id: 'goto_council',
      feature: FeatureId.ai_council,
      label: '',
      labelKey: LocaleKeys.heuristicNextActionGotoCouncil,
      subtitleKey: LocaleKeys.heuristicNextActionGotoCouncilSub,
      target: FeatureActionTarget(FeatureId.ai_council),
    ),
    const ChatNextAction(
      id: 'goto_theater',
      feature: FeatureId.ai_theater,
      label: '',
      labelKey: LocaleKeys.heuristicNextActionGotoTheater,
      subtitleKey: LocaleKeys.heuristicNextActionGotoTheaterSub,
      target: FeatureActionTarget(FeatureId.ai_theater),
    ),
    if (!env.hasCover && env.metadataReady && env.setupDone)
      const ChatNextAction(
        id: 'goto_cover_studio',
        feature: FeatureId.ai_cover_studio,
        label: '',
        labelKey: LocaleKeys.heuristicNextActionGotoCover,
        subtitleKey: LocaleKeys.heuristicNextActionGotoCoverSub,
        target: FeatureActionTarget(FeatureId.ai_cover_studio),
      ),
  ];
}

/// 角色扮演建议的 `seed` 语义是**角色名**，不是自由文本 —— 角色扮演的入口参数是
/// `initialCharacterId`，跟圆桌的议题、小剧场的场景不是一回事。宿主拿到 seed 后
/// 用本函数解析成角色 id；解析不到就退回角色选择器，不要静默丢弃跳转。
///
/// 只做去空白的精确匹配和唯一包含匹配：模型给的名字来自它刚读过的角色卡，
/// 正常情况就是原样；模糊匹配到错的人比匹配不到更糟。
String? resolveNextActionCharacterId(
  Iterable<({String id, String name})> characters,
  String? seed,
) {
  final target = seed?.trim() ?? '';
  if (target.isEmpty) {
    return null;
  }
  for (final character in characters) {
    if (character.name.trim() == target) {
      return character.id;
    }
  }
  final contains = [
    for (final character in characters)
      if (character.name.trim().isNotEmpty &&
          (character.name.trim().contains(target) ||
              target.contains(character.name.trim())))
        character,
  ];
  return contains.length == 1 ? contains.single.id : null;
}

/// 取「当前回合」挂上的最新建议块；没有则返回 null。
///
/// 扫描边界是**最后一条 user 消息**，不是最后一条 assistant 消息：一次 agent 回合
/// 会按 round 拆成多条 assistant 消息（挂建议的工具轮一条、收尾正文又一条），只看
/// 末条会漏掉挂在前一 round 的建议；而扫过 user 消息又会让上一轮早已过期的建议
/// 重新出现。停在 user 消息处，两头都收得住 —— 用户一发新消息，建议自然失效。
///
/// 同一回合内挂了多次时取最新一条：后挂的覆盖先挂的。
AiSuggestNextActionBlock? latestSuggestNextActionBlock(
  List<AiMessage> messages,
) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (message.role == AiMessageRole.user) {
      return null;
    }
    if (message.role != AiMessageRole.assistant) {
      continue;
    }
    for (var j = message.blocks.length - 1; j >= 0; j--) {
      final block = message.blocks[j];
      if (block is AiSuggestNextActionBlock) {
        return block;
      }
    }
  }
  return null;
}

/// 与建议一起选择原始用户消息 ID，避免流式收尾或恢复会话改变统计轮次。
({AiSuggestNextActionBlock block, String? userMessageId})?
latestSuggestNextActionTurn(List<AiMessage> messages) {
  final block = latestSuggestNextActionBlock(messages);
  if (block == null) {
    return null;
  }
  for (final message in messages.reversed) {
    if (message.role == AiMessageRole.user) {
      return (block: block, userMessageId: message.id);
    }
  }
  return (block: block, userMessageId: null);
}

/// 裁决后的建议序列化形态 —— 存进 [AiSuggestNextActionBlock] 供会话恢复时重放。
Map<String, dynamic> serializeChatNextAction(ChatNextAction action) {
  return switch (action.target) {
    PromptActionTarget(:final prompt, :final intent) => {
      'id': action.id,
      'kind': 'prompt',
      'label': action.label,
      'prompt': prompt,
      'intent': intent.name,
    },
    FeatureActionTarget(:final feature, :final seedText) => {
      'id': action.id,
      'kind': 'feature',
      'label': action.label,
      'feature': feature.storageKey,
      'seed': ?seedText,
    },
    WorkActionTarget(:final workId, :final prompt) => {
      'id': action.id,
      'kind': 'work',
      'label': action.label,
      'work_id': workId,
      'prompt': ?prompt,
    },
  };
}

/// [serializeChatNextAction] 的逆过程 —— 会话恢复时把已裁决结果读回展示模型。
///
/// 已裁决数据不再二次裁决：历史块记录的是当时挂上去的内容，原样重放。
ChatNextAction? deserializeChatNextAction(Map<String, dynamic> json) {
  final id = json['id'] as String? ?? '';
  final label = json['label'] as String? ?? '';
  if (label.isEmpty) {
    return null;
  }
  switch (json['kind']) {
    case 'prompt':
      final intent = ChatNextActionIntent.parse(json['intent']);
      if (intent == null) {
        return null;
      }
      final prompt = json['prompt'] as String? ?? '';
      if (prompt.isEmpty) {
        return null;
      }
      return ChatNextAction(
        id: id,
        label: label,
        target: PromptActionTarget(prompt, intent: intent),
      );
    case 'feature':
      final feature = FeatureIdX.fromStorageKey(
        json['feature'] as String? ?? '',
      );
      if (feature == null ||
          !chatNextActionFeatureWhitelist.contains(feature)) {
        return null;
      }
      final seed = json['seed'] as String?;
      return ChatNextAction(
        id: id,
        feature: feature,
        label: label,
        target: FeatureActionTarget(
          feature,
          seedText: (seed == null || seed.isEmpty) ? null : seed,
        ),
      );
    case 'work':
      final workId = _string(json['work_id']);
      if (workId.isEmpty) {
        return null;
      }
      final prompt = _string(json['prompt']);
      return ChatNextAction(
        id: id,
        label: label,
        target: WorkActionTarget(
          workId,
          prompt: prompt.isEmpty ? null : prompt,
        ),
      );
  }
  return null;
}

String _string(Object? value) {
  if (value is String) {
    return value.trim();
  }
  return '';
}

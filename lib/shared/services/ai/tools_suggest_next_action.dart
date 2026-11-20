// 职责: SuggestNextAction 工具实现 — 校验模型建议白名单并挂载到会话
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/heuristic/chat_next_action.dart
//   lib/shared/services/ai/chat_turn_runner.dart
part of 'tools.dart';

const String suggestNextActionToolName = 'SuggestNextAction';

/// 已裁决建议的挂载回调。返回 void —— 不需要回传条数（方案 5.1）。
typedef SuggestNextActionCallback =
    void Function(String callId, List<Map<String, dynamic>> suggestions);

/// 输入 schema 是静态契约；不做按作品状态的动态枚举裁剪。
Map<String, dynamic> buildSuggestNextActionInputSchema() {
  return {
    'type': 'object',
    'properties': {
      'suggestions': {
        'type': 'array',
        'maxItems': chatNextActionMaxSuggestions,
        'description': '建议数组，最多 $chatNextActionMaxSuggestions 条。',
        'items': {
          'type': 'object',
          'properties': {
            'kind': {
              'type': 'string',
              'enum': ['prompt', 'feature', 'work'],
              'description': 'prompt 表示点击后把 prompt 填入输入框；feature 表示点击后跳转到指定功能。',
            },
            'label': {'type': 'string', 'description': '按钮文案，一行内说清用户点了会发生什么。'},
            'work_id': {'type': 'string'},
            'prompt': {
              'type': 'string',
              'description': 'kind=prompt 时必填，点击后填入输入框的文本。',
            },
            'intent': {
              'type': 'string',
              'enum': ChatNextActionIntent.values.map((e) => e.name).toList(),
              'description':
                  'kind=prompt 时可选，默认 continue_chat：继续当前对话；'
                  'new_chat：开启独立新对话；'
                  'continue_in_new_chat：开启新对话并延续当前对话；'
                  'agent_rule：在当前对话创建或修改长期规则；'
                  'agent_skill：在当前对话创建或修改可复用技能。',
            },
            'feature': {
              'type': 'string',
              'enum': chatNextActionFeatureKeys,
              'description': 'kind=feature 时必填，跳转目标。',
            },
            'seed': {
              'type': 'string',
              'description':
                  'kind=feature 时可选，作为目标输入框的预填文本：'
                  'ai_council 传议题、ai_theater 传场景；'
                  'ai_roleplay 传角色名（入口是「和谁演」而不是「演什么」），'
                  '进入后预选该角色卡。',
            },
          },
          'required': ['kind', 'label'],
        },
      },
    },
    'required': ['suggestions'],
  };
}

/// 契约级描述：只写工具做什么和跨字段约束。单字段的取值、必填与含义写在
/// [buildSuggestNextActionInputSchema] 的 `description` 里，两边不重复 ——
/// 参数说明跟着参数走，模型看到字段时就看到它的说明。
/// 调用时机写在 `orchestrator.md` 场景指引。
const String _suggestNextActionDescription =
    '''向用户挂载最多 $chatNextActionMaxSuggestions 条可点击的下一步建议，展示在输入框上方，用户可点可忽略。
本工具不等待用户操作，返回值里不包含用户的选择。

kind=prompt 时 prompt 必填；kind=feature 时 feature 必填、seed 可选。''';

mixin _AiToolManagerSuggestNextActionMixin on _AiToolManagerBase {
  /// 校验 → 裁决 → 挂块 → 立即返回。
  ///
  /// 同步返回，避免下一步建议阻塞当前回合。
  Map<String, dynamic> _handleSuggestNextAction(
    Map<String, dynamic> input,
    String callId,
  ) {
    final rawSuggestions = input['suggestions'];
    if (rawSuggestions is! List || rawSuggestions.isEmpty) {
      _log.warning(
        'SuggestNextAction requires a non-empty suggestions array callId=$callId',
      );
      return {
        'ok': false,
        'error_code': ToolErrorCode.invalid_argument.name,
        'error': 'Pass at least one suggestion in the suggestions array.',
      };
    }

    final judgement = ChatNextActionArbiter.judge(
      rawSuggestions,
      allowFeatures: contentKind != contentKindCanvas,
    );
    for (final drop in judgement.drops) {
      _log.warning(
        'SuggestNextAction suggestion dropped callId=$callId '
        'index=${drop.index} reason=${drop.reason}',
      );
    }
    final rejected = judgement.drops
        .map((drop) => 'suggestions[${drop.index}]: ${drop.reason}')
        .join(', ');
    final hint = 'Rejected suggestions: $rejected.';
    if (judgement.actions.isEmpty) {
      return {
        'ok': false,
        'error_code': ToolErrorCode.invalid_argument.name,
        'error': 'No suggestions were added.',
        'hint': hint,
      };
    }

    suggestNextActionCallback?.call(
      callId,
      judgement.actions.map(serializeChatNextAction).toList(),
    );
    return {'ok': true, if (rejected.isNotEmpty) 'hint': hint};
  }
}

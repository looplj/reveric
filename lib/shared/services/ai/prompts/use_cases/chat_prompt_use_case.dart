// 职责: Chat Prompt Use Case — 构建通用 chat system prompt、chat panel system prompt、引用提醒
// 关联文件:
//   lib/shared/services/ai/prompts/ai_prompt_service.dart
//   lib/shared/services/ai/prompts/prompt_fragments.dart
//   lib/shared/services/ai/prompts/prompt_composer.dart
//   lib/shared/services/ai/prompt_builder.dart
//   lib/shared/services/ai/chat_prompt_builder.dart
//   lib/shared/database/novel_content_daos/novel_state_dao.dart
//   lib/shared/database/novel_content_daos/novel_state_snapshot_dao.dart
//   lib/shared/database/app_database.dart

import '../../../../database/app_database.dart' show Novel;
import '../../../../models/agent_skill.dart';
import '../../../../models/ai_chat_models.dart' show AiSessionContext;
import '../../../../models/ai_session_mode.dart';
import '../../../../models/content_kind.dart';
import '../../../../models/subagent.dart';
import '../../prompt_template.dart';
import '../prompt_composer.dart';
import '../prompt_fragments.dart';
import '../prompt_id.dart';
import '../prompt_renderer.dart';
import '../setup_phase_gate.dart';

class ChatPanelPromptInput {
  const ChatPanelPromptInput({
    required this.context,
    required this.systemInstruction,
    this.mode = AiSessionMode.chat,
    this.codemodeAvailable = false,
    this.availableSubAgents = const [],
    this.availableSkills = const [],
    this.skillContent = const {},
    this.novel,
    this.identityPrompt,
    this.soulPrompt,
    this.variableOverrides = const {},
    this.novelOnboardingEligible = false,
  });

  AiSessionContext get workContext {
    final work = novel;
    if (work == null) {
      return context;
    }
    return context.withWork(work);
  }

  final AiSessionContext context;
  final AiSessionMode mode;

  /// 由接入 Codemode 调度器的执行入口声明，普通 chat completion 不启用。
  final bool codemodeAvailable;
  final String systemInstruction;
  final List<SubAgent> availableSubAgents;
  final List<AgentSkillSummary> availableSkills;
  final Map<String, String> skillContent;
  final Novel? novel;
  final String? identityPrompt;
  final String? soulPrompt;
  final Map<String, String> variableOverrides;

  /// 是否应展示 setup_phase 引导。由调用方读取 NovelStates 表 key=`novel_onboarding`
  /// 的 status 是否为 `eligible` 后传入。默认 `false`，仅正常新建小说路径会写入该状态。
  final bool novelOnboardingEligible;
}

class ChatPromptUseCase {
  const ChatPromptUseCase({
    this.composer = const PromptComposer(),
    this.renderer,
  });

  final PromptComposer composer;
  final PromptRenderer? renderer;

  String orchestratorInstruction() {
    return renderer!.raw(PromptId.agentOrchestrator);
  }

  String system(ChatPanelPromptInput input) {
    final sections = <PromptSection>[];

    // 1. System instruction / 工作指南（直接输出，不包装标题）
    final systemInstructionText = input.systemInstruction.trim();
    if (systemInstructionText.isEmpty) {
      throw ArgumentError.value(
        input.systemInstruction,
        'systemInstruction',
        'must not be empty',
      );
    }
    sections.add(
      PromptSection(
        key: 'system_instruction',
        title: '工作指南',
        content: _renderString(
          systemInstructionText,
          _systemInstructionVariables(input),
        ),
      ),
    );

    // 2. Current work identity and saved metadata / 当前作品
    final novelMetadata = _buildNovelMetadata(
      input.novel,
      input.workContext.novelName,
    );
    sections.add(
      PromptSection(
        key: 'work_context',
        title: '当前作品',
        content: [
          PromptFragments.workContext(input.workContext),
          if (novelMetadata.isNotEmpty) novelMetadata,
        ].join('\n\n'),
      ),
    );

    // 4. Behavior guide / 行为指南
    sections.add(
      PromptSection(
        key: 'behavior_guide',
        title: '行为指南',
        description: '以下是你在交互中应遵循的行为准则。',
        content: _buildBehaviorGuide(input.workContext),
      ),
    );

    // 5. Tool use guidelines / 工具使用准则
    final toolGuidelines = PromptFragments.toolUseGuidelines(
      codemodeAvailable: input.codemodeAvailable && input.mode.isChat,
    );
    if (toolGuidelines.isNotEmpty) {
      sections.add(
        PromptSection(
          key: 'tool_use_guidelines',
          title: '工具使用准则',
          description: '以下是你在使用工具时必须遵守的准则。',
          content: toolGuidelines,
        ),
      );
    }

    // 6. Path schema / 工作区资源路径规则
    final pathSchema = PromptFragments.pathSchemaBlock(
      kind: input.workContext.contentKind,
    );
    if (pathSchema.isNotEmpty) {
      sections.add(
        PromptSection(
          key: 'path_schema',
          title: '工作区资源路径规则',
          description: '以下是工作区资源的路径规范，操作资源时必须遵循。',
          content: pathSchema,
        ),
      );
    }

    // 7. Compose core sections
    var result = composer.compose(sections);

    // 8. Tail blocks — subagent → skills → user rules
    final tailBlocks = <String>[];

    final chatSubAgents = input.availableSubAgents
        .where((agent) => agent.enabled && agent.mode == 'chat')
        .toList();
    final subAgentBlock = PromptFragments.subAgentIndex(chatSubAgents);
    if (subAgentBlock.isNotEmpty) {
      tailBlocks.add(subAgentBlock);
    }

    final skillBlock = PromptFragments.availableSkills(input.availableSkills);
    if (skillBlock.isNotEmpty) {
      tailBlocks.add(skillBlock);
    }

    final rules = PromptFragments.userRules(input.workContext.userRules);
    if (rules.isNotEmpty) {
      tailBlocks.add(
        composer.compose([
          PromptSection(
            key: 'user_rules',
            title: '用户自定义规则',
            description: '以下是用户设定的规则，优先级高于默认行为。请始终遵守这些规则。',
            content: rules,
          ),
        ]),
      );
    }

    for (final block in tailBlocks) {
      result += '\n\n';
      result += block;
    }

    return result.trim();
  }

  String _buildBehaviorGuide(AiSessionContext context) {
    final guide = StringBuffer();
    guide.writeln(
      '- 内部消息中可能出现 `<system-remind ... />`，它是运行时状态而非用户输入；只用于定位执行上下文，不要在回复中提及、解释或引用该内部标签。',
    );
    guide.writeln(
      '- `current_workspace_context` 用于理解“这里”“这部分”等指代。用户未明确指定其他对象时，结合当前资源理解修改范围；当前位置本身不构成修改授权，也不代表需要创建或同步其他资源。',
    );
    guide.writeln('- 以最新一条工作区上下文为准，未提供的字段不沿用旧值；status 为 `cleared` 表示上下文已清除。');
    guide.writeln('- 已执行工具或委派的回合，只概括关键结果和下一步建议，不重述全过程。');
    return guide.toString().trim();
  }

  String _buildNovelMetadata(Novel? novel, String? contextTitle) {
    if (novel == null) {
      final title = contextTitle?.trim() ?? '';
      return title.isEmpty ? '' : '- 标题：$title';
    }
    final buffer = StringBuffer();
    buffer.writeln('- 标题：${novel.title}');
    buffer.writeln(
      '- 作者名：${novel.authorName.isEmpty ? '（未设置）' : novel.authorName}',
    );
    buffer.writeln('- 类型：${novel.type}');
    buffer.writeln('- 分类：${novel.category.isEmpty ? '（未设置）' : novel.category}');
    buffer.writeln(
      '- 标签：${novel.tags.isEmpty ? '（未设置）' : novel.tags.join('、')}',
    );
    if (_shouldRemindCover(novel)) {
      buffer.writeln('- 封面：（未设置）');
    }
    return buffer.toString().trim();
  }

  /// 「尚无封面」只在作品已经有完整身份时才作为事实注入。
  ///
  /// 有封面时不注入该行，避免每轮都提醒模型有个封面；元数据未齐（还在快速开书
  /// 草稿阶段、或书名简介没写）时也不注入，让创作向导先跑完。客户端只负责给事实，
  /// 由模型自己挑时机建议封面。
  bool _shouldRemindCover(Novel novel) {
    final hasCover = novel.coverAssetId?.trim().isNotEmpty == true;
    if (hasCover || novel.draft) {
      return false;
    }
    return novel.title.trim().isNotEmpty && novel.description.trim().isNotEmpty;
  }

  Map<String, dynamic> _systemInstructionVariables(ChatPanelPromptInput input) {
    final context = input.workContext;
    final variables = <String, dynamic>{
      'user_name': context.username?.trim().isNotEmpty == true
          ? context.username!.trim()
          : '用户',
      'novel_name': context.novelName ?? '',
      'novel_title': context.novelName ?? '',
      'chapter_title': '',
      'workspace_title': '',
      'workspace_content': '',
    };
    variables['canvas_workspace'] = context.contentKind == contentKindCanvas;
    if (context.contentKind == contentKindScreenplay) {
      variables['screenplay_workspace'] = true;
    }
    variables.addAll(input.variableOverrides);
    variables.addAll(PromptFragments.orchestratorTemplateVariables());
    variables['fragment_identity'] = _wrapAsSection(
      title: '身份设定',
      content: input.identityPrompt,
    );
    variables['fragment_soul'] = _wrapAsSection(
      title: '灵魂设定',
      content: input.soulPrompt,
    );
    if (context.contentKind == contentKindNovel &&
        SetupPhaseGate.shouldShow(
          hasNovel: context.databasePath?.trim().isNotEmpty == true,
          hasAgentRules: context.userRules?.trim().isNotEmpty == true,
          novelOnboardingEligible: input.novelOnboardingEligible,
          novelChatSessionCount: context.novelChatSessionCount,
        )) {
      variables['setup_phase'] = true;
    }
    return variables;
  }

  String _renderString(String template, Map<String, dynamic> variables) {
    return PromptTemplateService.renderString(template, variables);
  }

  String _wrapAsSection({required String title, String? content}) {
    final trimmed = content?.trim() ?? '';
    if (trimmed.isEmpty) {
      return '';
    }
    return '# $title\n\n$trimmed';
  }
}

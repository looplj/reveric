// 职责: 按当前作品上下文渲染 Agent 模板、公共片段与类型条件，并构建 SubAgent 任务提示词
// 关联文件:
//   lib/shared/services/ai/prompts/use_cases/chat_prompt_use_case.dart
//   lib/shared/services/ai/prompts/prompt_renderer.dart
//   lib/shared/services/ai/chat_prompt_builder.dart
//   lib/shared/services/ai/prompts/prompt_fragments.dart

import '../../../../models/agent_profile.dart';
import '../../../../models/ai_chat_models.dart' show AiSessionContext;
import '../../../../models/content_kind.dart';
import '../../../../models/subagent.dart';
import '../../prompt_template.dart';
import '../prompt_renderer.dart';
import '../prompt_fragments.dart';

class AgentPromptUseCase {
  const AgentPromptUseCase({this.renderer});

  final PromptRenderer? renderer;

  String renderPromptTemplate(
    String template, {
    required AiSessionContext context,
    Map<String, String> extraContext = const {},
    Map<String, String> variableOverrides = const {},
  }) {
    if (template.isEmpty) {
      return template;
    }
    final variables = <String, dynamic>{
      ...PromptFragments.agentTemplateVariables(),
      'novel_title':
          variableOverrides['novel_title'] ?? context.novelName ?? '',
      'novel_description': variableOverrides['novel_description'] ?? '',
      'novel_author_name':
          variableOverrides['novel_author_name']?.trim().isNotEmpty == true
          ? variableOverrides['novel_author_name']
          : '（未设置）',
      'chapter_title':
          variableOverrides['chapter_title'] ?? context.chapterTitle ?? '',
      'workspace_title':
          variableOverrides['workspace_title'] ?? context.workspaceTitle ?? '',
      'workspace_content':
          variableOverrides['workspace_content'] ??
          context.workspaceContent ??
          '',
    };
    variables.addAll(extraContext);
    variables['canvas_workspace'] = context.contentKind == contentKindCanvas;
    variables['screenplay_workspace'] =
        context.contentKind == contentKindScreenplay;
    if (renderer != null) {
      return renderer!.renderString(template, variables);
    }
    return PromptTemplateService.renderString(template, variables);
  }

  String buildSubAgentPrompt(
    SubAgent agent,
    String input, {
    AiSessionContext? context,
    AgentProfile? agentProfile,
    Map<String, String> extraContext = const {},
  }) {
    final agentCommand = '/${agent.name.replaceAll(' ', '_')}';
    final instruction = agentCommand.length < input.trim().length
        ? input.trim().substring(agentCommand.length).trim()
        : '';
    final buffer = StringBuffer();
    if (agentProfile != null) {
      buffer.writeln('你当前代表的上层 Agent 是「${agentProfile.name}」。');
      if (agentProfile.description.trim().isNotEmpty) {
        buffer.writeln('Agent 说明：${agentProfile.description.trim()}');
      }
      buffer.writeln('上层 Agent 的工作方式：');
      buffer.writeln(
        renderPromptTemplate(
          agentProfile.systemPrompt.trim(),
          context: context ?? const AiSessionContext(),
          extraContext: extraContext,
        ),
      );
      buffer.writeln();
      buffer.writeln('现在请调用并扮演以下内部 SubAgent 能力：');
    }
    buffer.writeln(
      renderPromptTemplate(
        agent.prompt,
        context: context ?? const AiSessionContext(),
        extraContext: extraContext,
      ),
    );
    if (instruction.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('附加要求：$instruction');
    }
    return buffer.toString().trim();
  }
}

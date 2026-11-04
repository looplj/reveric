// 职责: Task Prompt Use Case — 构建 workspace/cover 等一次性任务 prompt
// 关联文件:
//   lib/shared/services/ai/prompts.dart
//   lib/desktop/features/cover_studio/studio_page.dart

import '../../prompt_template.dart';
import '../prompt_id.dart';
import '../prompt_renderer.dart';

enum TaskPromptAction { summarize, expand, rewrite }

class TaskPromptUseCase {
  const TaskPromptUseCase({this.renderer});

  final PromptRenderer? renderer;

  String workspaceAction({
    required TaskPromptAction action,
    required String workspaceType,
    required String title,
    String? metaContent,
    String? content,
  }) {
    final vars = <String, dynamic>{
      'workspace_type': workspaceType,
      'title': title,
      switch (action) {
        TaskPromptAction.summarize => 'summarize',
        TaskPromptAction.expand => 'expand',
        TaskPromptAction.rewrite => 'rewrite',
      }: true,
    };
    _addIfNotEmpty(vars, 'meta_content', metaContent);
    _addIfNotEmpty(vars, 'content', content);
    return _render(PromptId.taskWorkspaceAction, vars);
  }

  String coverAnalysis({
    required String novelTitle,
    required String styleLabel,
    List<String> tags = const [],
  }) {
    final vars = <String, dynamic>{
      'novel_title': novelTitle,
      'style_label': styleLabel,
    };
    if (tags.isNotEmpty) {
      vars['tags'] = tags.join('、');
    }
    return _render(PromptId.taskCoverAnalysis, vars);
  }

  static void _addIfNotEmpty(
    Map<String, dynamic> vars,
    String key,
    String? value,
  ) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      vars[key] = trimmed;
    }
  }

  String _render(String promptId, [Map<String, dynamic> variables = const {}]) {
    final promptRenderer =
        renderer ?? PromptRenderer(templates: PromptTemplateService.instance);
    return promptRenderer.render(promptId, variables);
  }
}

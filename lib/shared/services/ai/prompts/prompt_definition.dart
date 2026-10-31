// 职责: Prompt 定义模型 — 描述 prompt 的 ID、类型、模板路径、归属和渲染约束。
// 关联文件:
//   lib/shared/services/ai/prompts/prompt_id.dart
//   lib/shared/services/ai/prompts/prompt_registry.dart

enum PromptKind { system, agent, task, title, utility }

class PromptDefinition {
  const PromptDefinition({
    required this.id,
    required this.kind,
    required this.owner,
    this.templatePath,
    this.inlineTemplate,
    this.variables = const [],
    this.customizable = false,
    this.requiresPathSchema = false,
  }) : assert(
         templatePath != null || inlineTemplate != null,
         'PromptDefinition requires either templatePath or inlineTemplate.',
       );

  final String id;
  final PromptKind kind;
  final String owner;
  final String? templatePath;
  final String? inlineTemplate;
  final List<String> variables;
  final bool customizable;
  final bool requiresPathSchema;

  bool get isAssetBacked => templatePath != null;
}

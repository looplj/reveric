// 职责: Prompt 渲染器 — 通过 PromptRegistry 解析 prompt 定义并统一渲染资产或内联模板。
// 关联文件:
//   lib/shared/services/ai/prompts/prompt_registry.dart
//   lib/shared/services/ai/prompt_template.dart

import '../prompt_template.dart';
import 'prompt_registry.dart';

class PromptRenderer {
  const PromptRenderer({required this._templates});

  final PromptTemplateService _templates;

  String raw(String promptId) {
    final definition = PromptRegistry.byId(promptId);
    final templatePath = definition.templatePath;
    if (templatePath != null) {
      return _templates.rawAsset(templatePath);
    }
    final inlineTemplate = definition.inlineTemplate;
    if (inlineTemplate == null) {
      throw StateError('Prompt has no renderable template: $promptId');
    }
    return inlineTemplate.trim();
  }

  String render(String promptId, [Map<String, dynamic> variables = const {}]) {
    final definition = PromptRegistry.byId(promptId);
    final templatePath = definition.templatePath;
    if (templatePath != null) {
      return _templates.renderAsset(templatePath, variables);
    }
    final inlineTemplate = definition.inlineTemplate;
    if (inlineTemplate == null) {
      throw StateError('Prompt has no renderable template: $promptId');
    }
    return PromptTemplateService.renderString(inlineTemplate, variables);
  }

  String renderString(
    String template, [
    Map<String, dynamic> variables = const {},
  ]) {
    return PromptTemplateService.renderString(template, variables);
  }
}

// 职责: AgentRule 模型导出、表单字段枚举、业务异常与扩展方法
// 关联文件:
//   lib/shared/database/novel_content_database.dart

import '../database/novel_content_database.dart';
import '../utils/utf16_safe_text.dart';
import '../../third/form/flutter_hook_form.dart';

export '../database/novel_content_database.dart'
    show AgentRule, AgentRules, AgentRulesCompanion;

const int agentRuleLongContentWarningThreshold = 10000;

enum AgentRuleEditFields implements FieldSchema {
  name(validators: [RequiredValidator()], initialValue: ''),
  content(validators: [RequiredValidator()], initialValue: ''),
  enabled(initialValue: true);

  const AgentRuleEditFields({this.validators, this.initialValue});

  final dynamic initialValue;

  @override
  final List<Validator<dynamic>>? validators;
}

class AgentRuleNameConflictException implements Exception {
  const AgentRuleNameConflictException(this.name);
  final String name;
  @override
  String toString() => 'AgentRule name conflict: "$name"';
}

extension AgentRuleX on AgentRule {
  bool get isEmpty => content.trim().isEmpty;

  String get summary => truncateUtf16Safe(content.trim(), 100);

  String toDebugString() =>
      'AgentRule(id: $id, name: $name, enabled: $enabled)';
}

extension AgentRuleListX on List<AgentRule> {
  List<AgentRule> get sorted =>
      [...this]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  List<AgentRule> get enabled => where((r) => r.enabled).toList();

  /// 启用规则按 sortOrder 格式化为 Markdown 列表，每条规则保留自身的段落；无启用规则时返回 null。
  String? formatForPrompt() {
    final rules = enabled.sorted;
    if (rules.isEmpty) {
      return null;
    }
    return rules
        .map((rule) {
          final lines = '${rule.name}：${rule.content.trim()}'.split(
            RegExp(r'\r?\n'),
          );
          return [
            '- ${lines.first}',
            for (final line in lines.skip(1)) line.isEmpty ? '' : '  $line',
          ].join('\n');
        })
        .join('\n');
  }
}

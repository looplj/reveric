// 职责: AgentSkill Markdown 导入解析器 — 从 SKILL.md 提取 YAML frontmatter
//   (name/when_to_use/description + metadata.category/tags)与 prompt body。
// 关联文件:
//   lib/shared/models/novel_agent_skill.dart
//   lib/shared/services/agent_skill_transfer.dart

import 'dart:convert';

import 'package:yaml/yaml.dart';

class AgentSkillImportParseResult {
  const AgentSkillImportParseResult({
    required this.name,
    this.whenToUse = '',
    this.category = '',
    this.tags = const [],
    required this.description,
    required this.body,
  });

  final String name;
  final String whenToUse;
  final String category;
  final List<String> tags;
  final String description;
  final String body;
}

class AgentSkillImportParser {
  /// Parses YAML frontmatter from an Agent Skills `SKILL.md`.
  ///
  /// Canonical format (Agent Skills spec + Reveric extensions):
  /// ```
  /// ---
  /// name: SkillName
  /// when_to_use: When to use this skill
  /// description: Skill description text
  /// metadata:
  ///   category: 扩写
  ///   tags: 节奏, 爽文
  /// ---
  /// <markdown body>
  /// ```
  ///
  /// Spec top-level fields: `name`, `description` (required). Reveric keeps
  /// top-level `when_to_use`. `category` / `tags` live under optional
  /// `metadata` (string → string).
  /// If `when_to_use` is missing or empty, it falls back to `description`.
  ///
  /// Returns `null` if no valid frontmatter is found.
  static AgentSkillImportParseResult? parse(
    String content, {
    bool installed = false,
  }) {
    final trimmed = content.trimLeft();
    if (!trimmed.startsWith('---\n') && !trimmed.startsWith('---\r\n')) {
      return null;
    }

    final headerEnd = trimmed.indexOf('\n');
    if (headerEnd < 0) {
      return null;
    }

    final frontmatterStart = headerEnd + 1;
    final closingMatch = RegExp(
      r'\n---\r?\n',
    ).firstMatch(trimmed.substring(frontmatterStart));
    if (closingMatch == null) {
      return null;
    }

    final frontmatterEnd = frontmatterStart + closingMatch.start;
    final bodyStart = frontmatterStart + closingMatch.end;
    final frontmatter = trimmed.substring(frontmatterStart, frontmatterEnd);
    final body = trimmed.substring(bodyStart);

    final Object? data;
    try {
      data = loadYaml(frontmatter);
    } on YamlException {
      return null;
    }
    if (data is! YamlMap) {
      return null;
    }
    String text(Object? value) =>
        value is String ? (installed ? value : value.trim()) : '';
    final name = text(data['name']).trim();
    final description = text(data['description']);
    if (name.isEmpty || (!installed && description.isEmpty)) {
      return null;
    }
    final whenToUse = text(data['when_to_use']);
    final metadata = data['metadata'];
    final category = metadata is YamlMap ? text(metadata['category']) : '';
    final tags = metadata is YamlMap ? metadata['tags'] : null;
    return AgentSkillImportParseResult(
      name: name,
      whenToUse: !installed && whenToUse.isEmpty ? description : whenToUse,
      category: category,
      tags: tags is YamlList
          ? tags
                .whereType<String>()
                .map((tag) => installed ? tag : tag.trim())
                .where((tag) => tag.isNotEmpty)
                .toList()
          : _parseStringList(text(tags)),
      description: description,
      body: installed && body.startsWith('\n')
          ? body.substring(1)
          : (installed ? body : body.trimLeft()),
    );
  }

  /// Serializes a skill to Agent Skills `SKILL.md` frontmatter + body.
  /// Round-trips with [parse]. Empty `when_to_use` / `metadata` omitted.
  /// Does not write `agent_scopes`.
  static String write({
    required String name,
    required String description,
    required String body,
    String whenToUse = '',
    String category = '',
    List<String> tags = const [],
    bool installed = false,
  }) {
    final lines = <String>['---', 'name: ${_escapeScalar(name)}'];
    if (whenToUse.isNotEmpty) {
      lines.add('when_to_use: ${_escapeScalar(whenToUse)}');
    }
    lines.add('description: ${_escapeScalar(description)}');
    if (category.isNotEmpty || tags.isNotEmpty) {
      lines.add('metadata:');
      if (category.isNotEmpty) {
        lines.add('  category: ${_escapeScalar(category)}');
      }
      if (tags.isNotEmpty) {
        final serialized = installed
            ? jsonEncode(tags)
            : _escapeScalar(tags.join(', '));
        lines.add('  tags: $serialized');
      }
    }
    lines.add('---');
    lines.add('');
    lines.add(body);
    return lines.join('\n');
  }

  /// Quote YAML-sensitive scalars while preserving the readable export format.
  static String _escapeScalar(String value) {
    try {
      if (!value.contains('\n') &&
          !value.contains('\r') &&
          loadYaml(value) == value) {
        return value;
      }
    } on YamlException {
      // JSON strings are also valid YAML quoted scalars.
    }
    return jsonEncode(value);
  }

  static List<String> _parseStringList(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == '[]') {
      return const <String>[];
    }

    final rawItems = trimmed.startsWith('[') && trimmed.endsWith(']')
        ? trimmed.substring(1, trimmed.length - 1).split(',')
        : trimmed.split(',');

    final items = rawItems
        .map((item) => item.trim())
        .map((item) {
          if (item.length >= 2 &&
              ((item.startsWith('"') && item.endsWith('"')) ||
                  (item.startsWith("'") && item.endsWith("'")))) {
            return item.substring(1, item.length - 1);
          }
          return item;
        })
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    return items;
  }
}

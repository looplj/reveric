// 职责: Bundled Control Skill 资源加载器 — 读取固定 Skill Bundle（主指令与可选
//   references）并解析 frontmatter，提供运行时默认 fallback。
// 关联文件:
//   lib/shared/services/agent_skill_import_parser.dart
//   lib/shared/models/agent_skill_reference.dart
//   assets/bundled_skills/setup/SKILL.md
//   assets/bundled_skills/setup/references/
//   assets/bundled_skills/management/SKILL.md
//   assets/bundled_skills/management/references/
//   assets/bundled_skills/canvas-composition/SKILL.md
//   assets/bundled_skills/story-continuity/references/relations.md
//   assets/bundled_skills/screenplay-tools/SKILL.md
// 遵循的 Rules:
//   .agents/rules/error-handling.md

import 'package:flutter/services.dart' show AssetBundle;

import '../app_config.dart';
import '../models/agent_skill_reference.dart';
import '../models/content_kind.dart';
import 'agent_skill_import_parser.dart';

/// 单个 Bundled Control Skill 的不可变快照。
///
/// 与 NovelAgentSkillModel 对齐:运行时默认 fallback 用,可被同名 NovelAgentSkill 覆盖。
/// `callName` 是运行时唯一标识(固定中文),`name` 来自 frontmatter(可与 callName 不同)。
class BundledControlSkill {
  const BundledControlSkill({
    required this.callName,
    required this.runCommand,
    required this.name,
    required this.whenToUse,
    required this.description,
    required this.prompt,
    required this.assetPath,
    this.references = const [],
    this.contentKinds = const {},
  });

  /// 运行时唯一标识,与 NovelAgentSkill.callName 对齐,用于 fallback 匹配。
  /// 固定值见 [bundledControlCallNames]。
  final String callName;

  /// 单一对应的 Run 命令名。无单一命令时为 null；完整映射见
  /// [bundledControlRunCommandToCallName]。
  final String? runCommand;

  /// 来自 frontmatter `name` 的展示名（可与 callName 不同）。
  final String name;

  /// 来自 frontmatter `when_to_use` 的触发条件。
  final String whenToUse;

  /// 来自 frontmatter `description` 的一句话说明。
  final String description;

  /// frontmatter 之后的完整 markdown body,作为 prompt 注入。
  final String prompt;

  /// asset 路径,用于调试与日志。
  final String assetPath;

  /// 内置只读附件，路径相对该 Skill root（`references/**`）。
  final List<AgentSkillReferenceFile> references;
  final Set<String> contentKinds;
  bool availableFor(String kind) =>
      contentKinds.isEmpty || contentKinds.contains(kind);
}

/// Bundled Control Skill 的固定 callName 集合。
const Set<String> bundledControlCallNames = {
  '创作向导',
  '系统管理',
  if (ideationCanvasEnabled) '画布构图指南',
  '剧本工具使用规范',
  '画布作品工具',
  '故事连续性维护',
  '媒体处理与剪辑',
};

/// Run 命令名到 callName 的固定映射。
///
/// 此映射中的命令由对应 bundled skill 独占完整操作说明，避免两份契约漂移。
/// Run 顶层 help 展示命令用途和 Skill 入口；定向 help 或缺少/错误 subcommand
/// 的返回值仅指引加载对应 Skill，不重复子命令及参数契约。
///
/// 管理命令共用「系统管理」，具体操作按需读取对应 reference。
/// `创作向导` 无对应 Run 命令，不在此映射中。
const Map<String, String> bundledControlRunCommandToCallName = {
  'agent-rules': '系统管理',
  'agent-skills': '系统管理',
  'subagents': '系统管理',
  'themes': '系统管理',
  'settings': '系统管理',
  'stagings': '剧本工具使用规范',
  'styles': '剧本工具使用规范',
  'production': '剧本工具使用规范',
  'editing': '媒体处理与剪辑',
  'ffmpeg': '媒体处理与剪辑',
  'files': '媒体处理与剪辑',
  'operations': '媒体处理与剪辑',
};

String? bundledControlSkillForRun(String command, {String? contentKind}) =>
    contentKind == contentKindCanvas &&
        const {'production', 'styles', 'stagings'}.contains(command)
    ? '画布作品工具'
    : bundledControlRunCommandToCallName[command];

class _BundledControlSkillSpec {
  const _BundledControlSkillSpec({
    required this.callName,
    required this.runCommand,
    required this.assetPath,
    this.referenceAssetPaths = const [],
    this.contentKinds = const {},
  });

  final String callName;
  final String? runCommand;
  final String assetPath;
  final List<String> referenceAssetPaths;
  final Set<String> contentKinds;
  bool availableFor(String kind) =>
      contentKinds.isEmpty || contentKinds.contains(kind);
}

/// Bundled Control Skill 的固定规格表。
///
/// callName / runCommand / assetPath 三元组在此硬编码,
/// frontmatter 的 name/when_to_use/description 与 body 在运行时从 asset 解析。
const List<_BundledControlSkillSpec> _bundledControlSkillSpecs = [
  _BundledControlSkillSpec(
    callName: '创作向导',
    contentKinds: {contentKindNovel},
    runCommand: null,
    assetPath: 'assets/bundled_skills/setup/SKILL.md',
    referenceAssetPaths: [
      'assets/bundled_skills/setup/references/original.md',
      'assets/bundled_skills/setup/references/fanfic.md',
      'assets/bundled_skills/setup/references/sequel.md',
      'assets/bundled_skills/setup/references/imitation.md',
    ],
  ),
  _BundledControlSkillSpec(
    callName: '系统管理',
    runCommand: null,
    assetPath: 'assets/bundled_skills/management/SKILL.md',
    referenceAssetPaths: [
      'assets/bundled_skills/management/references/agent-rules.md',
      'assets/bundled_skills/management/references/agent-skills.md',
      'assets/bundled_skills/management/references/skill-design.md',
      'assets/bundled_skills/management/references/subagents.md',
      'assets/bundled_skills/management/references/themes.md',
      'assets/bundled_skills/management/references/providers.md',
      'assets/bundled_skills/management/references/settings.md',
    ],
  ),
  // 画布使用通用资源工具；构图方法按场景附件加载。
  if (ideationCanvasEnabled)
    _BundledControlSkillSpec(
      callName: '画布构图指南',
      contentKinds: {contentKindNovel, contentKindScreenplay},
      runCommand: null,
      assetPath: 'assets/bundled_skills/canvas-composition/SKILL.md',
      referenceAssetPaths: [
        'assets/bundled_skills/canvas-composition/references/story-structure.md',
        'assets/bundled_skills/canvas-composition/references/branching-story.md',
        'assets/bundled_skills/canvas-composition/references/relationships.md',
        'assets/bundled_skills/canvas-composition/references/idea-board.md',
      ],
    ),
  _BundledControlSkillSpec(
    callName: '剧本工具使用规范',
    contentKinds: {contentKindScreenplay},
    runCommand: null,
    assetPath: 'assets/bundled_skills/screenplay-tools/SKILL.md',
    referenceAssetPaths: [
      'assets/bundled_skills/screenplay-tools/references/screenplay.md',
      'assets/bundled_skills/screenplay-tools/references/clips.md',
      'assets/bundled_skills/screenplay-tools/references/styles.md',
      'assets/bundled_skills/screenplay-tools/references/production-canvas.md',
      'assets/bundled_skills/screenplay-tools/references/stagings.md',
    ],
  ),
  _BundledControlSkillSpec(
    callName: '画布作品工具',
    contentKinds: {contentKindCanvas},
    runCommand: null,
    assetPath: 'assets/bundled_skills/canvas-work-tools/SKILL.md',
    referenceAssetPaths: [
      'assets/bundled_skills/canvas-work-tools/references/production-canvas.md',
      'assets/bundled_skills/canvas-work-tools/references/clips.md',
      'assets/bundled_skills/canvas-work-tools/references/styles.md',
      'assets/bundled_skills/screenplay-tools/references/stagings.md',
    ],
  ),
  _BundledControlSkillSpec(
    callName: '故事连续性维护',
    contentKinds: {contentKindNovel, contentKindScreenplay},
    runCommand: null,
    assetPath: 'assets/bundled_skills/story-continuity/SKILL.md',
    referenceAssetPaths: [
      'assets/bundled_skills/story-continuity/references/novel.md',
      'assets/bundled_skills/story-continuity/references/relations.md',
      'assets/bundled_skills/story-continuity/references/screenplay.md',
    ],
  ),
  _BundledControlSkillSpec(
    callName: '媒体处理与剪辑',
    runCommand: null,
    assetPath: 'assets/bundled_skills/media-editing/SKILL.md',
    referenceAssetPaths: [
      'assets/bundled_skills/media-editing/references/files.md',
      'assets/bundled_skills/media-editing/references/ffmpeg.md',
      'assets/bundled_skills/media-editing/references/editing.md',
      'assets/bundled_skills/media-editing/references/operations.md',
    ],
  ),
];

/// Bundled Control Skill 加载器。
///
/// 无状态:每次调用都重新读取 asset。失败时抛 [StateError](按 error-handling.md,
/// 不静默降级为空结果)。不持久化到 Drift / NovelContentDatabase。
class BundledControlSkillsLoader {
  const BundledControlSkillsLoader();

  /// 加载全部 Bundled Control Skill。
  ///
  /// 按 [_bundledControlSkillSpecs] 顺序返回。任意一个 asset 缺失或 frontmatter
  /// 解析失败时抛 [StateError],不返回部分结果。
  Future<List<BundledControlSkill>> loadAll(
    AssetBundle bundle, {
    String? contentKind,
  }) async {
    final results = <BundledControlSkill>[];
    for (final spec in _bundledControlSkillSpecs) {
      if (contentKind != null && !spec.availableFor(contentKind)) {
        continue;
      }
      results.add(await _loadOne(bundle, spec));
    }
    return results;
  }

  /// 按 callName 查找。callName 不在 [bundledControlCallNames] 中时返回 null。
  Future<BundledControlSkill?> findByCallName(
    AssetBundle bundle,
    String callName, {
    String? contentKind,
  }) async {
    final specIndex = _bundledControlSkillSpecs.indexWhere(
      (s) => s.callName == callName,
    );
    if (specIndex < 0) {
      return null;
    }
    final spec = _bundledControlSkillSpecs[specIndex];
    if (contentKind != null && !spec.availableFor(contentKind)) {
      return null;
    }
    return _loadOne(bundle, spec);
  }

  /// 按 Run 命令名查找。runCommand 不在 [bundledControlRunCommandToCallName]
  /// 中时返回 null(包括对 `创作向导` 查找任何 runCommand 都返回 null)。
  Future<BundledControlSkill?> findByRunCommand(
    AssetBundle bundle,
    String runCommand, {
    String? contentKind,
  }) async {
    final callName = bundledControlSkillForRun(
      runCommand,
      contentKind: contentKind,
    );
    if (callName == null) {
      return null;
    }
    return findByCallName(bundle, callName, contentKind: contentKind);
  }

  Future<BundledControlSkill> _loadOne(
    AssetBundle bundle,
    _BundledControlSkillSpec spec,
  ) async {
    final raw = await bundle.loadString(spec.assetPath);
    final parsed = AgentSkillImportParser.parse(raw);
    if (parsed == null) {
      throw StateError(
        'bundled control skill at ${spec.assetPath} missing valid frontmatter '
        '(name/description required)',
      );
    }
    return BundledControlSkill(
      callName: spec.callName,
      contentKinds: spec.contentKinds,
      runCommand: spec.runCommand,
      name: parsed.name,
      whenToUse: parsed.whenToUse,
      description: parsed.description,
      prompt: parsed.body,
      assetPath: spec.assetPath,
      references: await _loadReferences(bundle, spec),
    );
  }

  Future<List<AgentSkillReferenceFile>> _loadReferences(
    AssetBundle bundle,
    _BundledControlSkillSpec spec,
  ) async {
    final files = <AgentSkillReferenceFile>[];
    for (final assetPath in spec.referenceAssetPaths) {
      final markerIndex = assetPath.indexOf('/references/');
      if (markerIndex < 0) {
        throw StateError(
          'bundled control skill reference must be inside references/: '
          '$assetPath',
        );
      }
      final relativePath = assetPath.substring(markerIndex + 1);
      files.add(
        AgentSkillReferenceFile(
          path: relativePath,
          content: await _expandReferences(
            bundle,
            await bundle.loadString(assetPath),
          ),
        ),
      );
    }
    return AgentSkillReferences.normalizeOrThrow(files);
  }

  Future<String> _expandReferences(AssetBundle bundle, String content) async {
    final pattern = RegExp(r'<inline-ref\b([^>]*)>([\s\S]*?)</inline-ref>');
    final output = StringBuffer();
    var cursor = 0;
    for (final match in pattern.allMatches(content)) {
      output.write(content.substring(cursor, match.start));
      final attributes = <String, String>{};
      final attributePattern = RegExp(r'([a-z_]+)="([^"]*)"');
      for (final attribute in attributePattern.allMatches(match[1]!)) {
        if (attributes.containsKey(attribute[1])) {
          throw StateError('Duplicate inline-ref attribute: ${attribute[1]}');
        }
        attributes[attribute[1]!] = attribute[2]!;
      }
      if (match[1]!.replaceAll(attributePattern, '').trim().isNotEmpty ||
          attributes['type'] != 'reference' ||
          attributes.keys.any(
            (key) => !const {'type', 'skill', 'section'}.contains(key),
          )) {
        throw StateError('Invalid bundled inline-ref attributes');
      }
      final spec = _bundledControlSkillSpecs
          .where((spec) => spec.callName == attributes['skill'])
          .firstOrNull;
      if (spec == null) {
        throw StateError(
          'Unknown bundled inline-ref skill: ${attributes['skill']}',
        );
      }
      final path = match[2]!.trim();
      final asset = spec.referenceAssetPaths.where((asset) {
        final marker = asset.indexOf('/references/');
        return marker >= 0 && asset.substring(marker + 1) == path;
      }).firstOrNull;
      if (asset == null) {
        throw StateError(
          'Unregistered bundled inline-ref: ${spec.callName}/$path',
        );
      }
      final String source;
      try {
        source = await bundle.loadString(asset);
      } catch (error) {
        throw StateError('Missing bundled inline-ref asset: $asset ($error)');
      }
      final section = attributes['section'];
      final selected = section == null
          ? source
          : _referenceSection(source, section);
      if (selected.contains('<inline-ref')) {
        throw StateError('Nested bundled inline-ref: ${spec.callName}/$path');
      }
      output.write(selected);
      cursor = match.end;
    }
    output.write(content.substring(cursor));
    final expanded = output.toString();
    if (expanded.contains('<inline-ref')) {
      throw StateError('Invalid bundled inline-ref tag');
    }
    return expanded;
  }

  String _referenceSection(String content, String section) {
    final lines = content.split('\n');
    final selected = <String>[];
    var found = false;
    String? fence;
    for (final line in lines) {
      final codeFence = RegExp(r'^ {0,3}(`{3,}|~{3,})').firstMatch(line);
      if (codeFence != null) {
        final delimiter = codeFence[1]!;
        if (fence == null) {
          fence = delimiter;
        } else if (delimiter[0] == fence[0] &&
            delimiter.length >= fence.length) {
          fence = null;
        }
      } else if (fence == null) {
        final heading = RegExp(
          r'^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$',
        ).firstMatch(line);
        if (heading != null && heading[1]!.length <= 2) {
          if (found) {
            break;
          }
          if (heading[1] == '##' && heading[2] == section) {
            found = true;
          }
        }
      }
      if (found) {
        selected.add(line);
      }
    }
    if (!found) {
      throw StateError('Missing bundled inline-ref section: $section');
    }
    return selected.join('\n').trimRight();
  }
}

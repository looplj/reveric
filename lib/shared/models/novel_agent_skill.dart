// 职责: AgentSkill 应用全局可执行快照领域模型 —— 来源、追溯与执行状态。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/daos/novel_agent_skill_dao.dart
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/shared/models/agent_skill_reference.dart
// 遵循的 Rules:
//   .agents/rules/enum-naming.md

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'agent_skill_reference.dart';

const _unchanged = Object();

/// AgentSkill 安装来源类型。状态/分类枚举用 snake_case(见 enum-naming 规则)。
enum AgentSkillSourceKind {
  novelLocal,
  official,
  marketplace;

  String get dbValue {
    return switch (this) {
      AgentSkillSourceKind.novelLocal => 'novel_local',
      AgentSkillSourceKind.official => 'official',
      AgentSkillSourceKind.marketplace => 'marketplace',
    };
  }

  static AgentSkillSourceKind fromDbValue(String value) {
    return switch (value) {
      'official' => AgentSkillSourceKind.official,
      'marketplace' => AgentSkillSourceKind.marketplace,
      _ => AgentSkillSourceKind.novelLocal,
    };
  }

  /// 运行时该来源是否可执行(novel_local / official / marketplace
  /// 均可作为 NovelAgentSkill 来源执行;但可执行性最终由 NovelAgentSkill 行决定)。
  bool get isRemote =>
      this == AgentSkillSourceKind.official ||
      this == AgentSkillSourceKind.marketplace;
}

/// 应用全局可执行 AgentSkill 快照 —— name 全局唯一,即工具名。
class NovelAgentSkillModel {
  const NovelAgentSkillModel({
    required this.id,
    required this.sourceKind,
    required this.name,
    required this.description,
    required this.prompt,
    this.skillRoot,
    this.sourceListingPublicId,
    this.sourceVersion,
    this.sourceDisplayName,
    this.whenToUse = '',
    this.agentScopes = const [],
    this.category = '',
    this.tags = const [],
    this.references = const [],
    this.enabled = true,
    this.sortOrder = 0,
    this.executionBlockedReason,
    this.packageReadFailed = false,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? skillRoot;
  final AgentSkillSourceKind sourceKind;

  /// 目录来源追溯。本地重命名不修改这些字段。
  final String? sourceListingPublicId;
  final String? sourceVersion;
  final String? sourceDisplayName;

  /// 应用全局唯一,是 Agent tool 的有效名称。
  final String name;

  // ── 快照内容(安装时拷贝,升级确认后才覆盖)──────────────────────────
  final String whenToUse;
  final String description;
  final String prompt;
  final List<String> agentScopes;
  final String category;
  final List<String> tags;

  /// Agent Skills `references/` 附件（相对 path + content）。
  final List<AgentSkillReferenceFile> references;

  final bool enabled;
  final int sortOrder;

  /// 非 null 时运行时跳过执行,即使 enabled=true(用于紧急撤销)。
  final String? executionBlockedReason;
  final bool packageReadFailed;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 运行时可执行:启用且未被撤销阻止。
  bool get isExecutable =>
      enabled && executionBlockedReason == null && !packageReadFailed;

  NovelAgentSkillModel copyWith({
    String? id,
    String? skillRoot,
    AgentSkillSourceKind? sourceKind,
    String? sourceListingPublicId,
    String? sourceVersion,
    String? sourceDisplayName,
    String? name,
    String? whenToUse,
    String? description,
    String? prompt,
    List<String>? agentScopes,
    String? category,
    List<String>? tags,
    List<AgentSkillReferenceFile>? references,
    bool? enabled,
    int? sortOrder,
    Object? executionBlockedReason = _unchanged,
    bool? packageReadFailed,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return NovelAgentSkillModel(
      id: id ?? this.id,
      skillRoot: skillRoot ?? this.skillRoot,
      sourceKind: sourceKind ?? this.sourceKind,
      sourceListingPublicId:
          sourceListingPublicId ?? this.sourceListingPublicId,
      sourceVersion: sourceVersion ?? this.sourceVersion,
      sourceDisplayName: sourceDisplayName ?? this.sourceDisplayName,
      name: name ?? this.name,
      whenToUse: whenToUse ?? this.whenToUse,
      description: description ?? this.description,
      prompt: prompt ?? this.prompt,
      agentScopes: agentScopes ?? this.agentScopes,
      category: category ?? this.category,
      tags: tags ?? this.tags,
      references: references ?? this.references,
      enabled: enabled ?? this.enabled,
      sortOrder: sortOrder ?? this.sortOrder,
      executionBlockedReason: identical(executionBlockedReason, _unchanged)
          ? this.executionBlockedReason
          : executionBlockedReason as String?,
      packageReadFailed: packageReadFailed ?? this.packageReadFailed,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 升级时仅覆盖来源追溯与快照内容,保留 id/name/enabled/sortOrder。
  NovelAgentSkillModel withUpgradedSnapshot({
    String? sourceListingPublicId,
    required String sourceVersion,
    required String sourceDisplayName,
    required String whenToUse,
    required String description,
    required String prompt,
    required List<String> agentScopes,
    required String category,
    required List<String> tags,
    List<AgentSkillReferenceFile> references = const [],
    required DateTime updatedAt,
  }) {
    return copyWith(
      sourceListingPublicId: sourceListingPublicId,
      sourceVersion: sourceVersion,
      sourceDisplayName: sourceDisplayName,
      whenToUse: whenToUse,
      description: description,
      prompt: prompt,
      agentScopes: agentScopes,
      category: category,
      tags: tags,
      references: references,
      updatedAt: updatedAt,
    );
  }
}

/// 安装来源冲突时用户选择的解决方式。
enum SkillInstallResolution { overwrite, rename }

/// 安装技能的结果。
class SkillInstallResult {
  const SkillInstallResult({required this.installed, this.conflictWith});

  final NovelAgentSkillModel installed;
  final NovelAgentSkillModel? conflictWith;
}

/// 内容指纹 —— 「技能内容有没有变」的唯一判据，决定是否产生历史版本。
///
/// 只覆盖会被留档的内容字段与附件清单；`enabled` / `sortOrder` /
/// `executionBlockedReason` 与来源追溯字段刻意排除在外，因此启停、排序
/// 和转本地都不会产生一条内容重复的历史版本。
extension NovelAgentSkillContentHash on NovelAgentSkillModel {
  String get contentHash {
    // 用 NUL 分隔字段、SOH 分隔字段内的项，避免相邻字段拼接后撞出同一指纹。
    const fieldSeparator = '\u0000';
    const itemSeparator = '\u0001';
    final sortedReferences = [...references]
      ..sort((a, b) => a.path.compareTo(b.path));
    final parts = <String>[
      name,
      whenToUse,
      description,
      prompt,
      category,
      tags.join(itemSeparator),
      agentScopes.join(itemSeparator),
      for (final reference in sortedReferences)
        '${reference.path}$itemSeparator'
            '${agentSkillBlobHash(reference.content)}',
    ];
    return sha256.convert(utf8.encode(parts.join(fieldSeparator))).toString();
  }
}

/// 附件正文的内容寻址 key，与 `novel_agent_skill_blobs.sha256` 一致。
String agentSkillBlobHash(String content) {
  return sha256.convert(utf8.encode(content)).toString();
}

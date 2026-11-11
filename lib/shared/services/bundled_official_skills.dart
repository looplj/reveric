// 职责: Bundled Official Skill 资源加载器 — 读取官方目录技能及 references 并
//   组装为本地目录模型，供 listOfficial / getOfficial 离线读取。
// 关联文件:
//   lib/shared/services/agent_skill_import_parser.dart
//   lib/shared/services/agent_skill_catalog_service.dart
//   lib/shared/models/official_agent_skill.dart
//   lib/shared/models/agent_skill_reference.dart
//   assets/official_skills/
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md

import 'package:flutter/services.dart' show AssetBundle;

import '../models/agent_skill_reference.dart';
import 'agent_skill_import_parser.dart';
import '../models/official_agent_skill.dart';

/// 单条打包官方技能的规格。
///
/// 公开仅为让 `bundled_official_skills_test.dart` 校验 [contentHash] 与
/// [assetPath] 覆盖情况；业务代码只应通过 [BundledOfficialSkillsLoader] 读取。
class BundledOfficialSkillSpec {
  const BundledOfficialSkillSpec({
    required this.name,
    required this.assetPath,
    required this.version,
    required this.contentHash,
    required this.sortOrder,
    required this.updatedAt,
    this.badge,
    this.referenceAssetPaths = const [],
  });

  final String name;
  final String assetPath;
  final int version;

  /// 技能内容的 sha256（小写十六进制）。无附件时仅计算主文件；有附件时在
  /// 主文件字节后，按附件路径排序追加 NUL、完整 asset 路径、NUL、附件字节。
  ///
  /// 由测试校验主文件和附件是否与登记的指纹一致，不参与运行时逻辑。
  /// 是否递增 version 取决于实际发布状态，不能由 hash 变化推断。
  final String contentHash;

  /// 与主文件同目录的 references/** 资源；详情加载时读取，摘要不读取附件。
  final List<String> referenceAssetPaths;

  final int sortOrder;
  final String updatedAt;

  /// 卡片角标文案，null / 空表示无角标。
  ///
  /// 直接写中文字面量，不走 i18n：这批技能本身就是中文网文写作技能，且角标是
  /// 技能目录标记而非界面文案。改它不影响已安装内容，
  /// 因此不需要上调 [version]。全部挂上就失去了角标的意义，按需挑几个。
  final String? badge;
}

/// 官方目录技能的固定规格表，按 sortOrder 排列。
///
/// `listingId` 等于 `name`。version / updatedAt 在规格表中维护。
///
/// 版本维护遵循 `.agents/rules/agent-skills.md`「打包官方技能按发布状态维护版本」：
/// 先核对实际发布记录与标签代码；当前版本已发布才递增 version，未发布则合并修改并保留版本号。
/// 修改主文件或附件时都更新 contentHash 和 updatedAt。
/// 自动升级依赖 version 递增；保留版本号时须用 SQLite skill 同步 Debug 数据库
/// 中已有的官方安装快照与附件，并查询验证，不覆盖本地自定义内容。
const List<BundledOfficialSkillSpec> bundledOfficialSkillSpecs = [
  BundledOfficialSkillSpec(
    name: '章节节奏',
    assetPath: 'assets/official_skills/章节节奏.md',
    version: 1,
    contentHash:
        '40fc32d18111d872b0079ecda0690cced09a751a8a4a7fb53cea0751c7fe2c57',
    sortOrder: 0,
    updatedAt: '2026-10-22T12:14:19+08:00',
  ),
  BundledOfficialSkillSpec(
    name: '章节规划',
    assetPath: 'assets/official_skills/章节规划.md',
    version: 1,
    contentHash:
        '370ba4d54fc73c0de715c1164861c1f191103040a2b6152392f5c7643e571d29',
    sortOrder: 1,
    updatedAt: '2026-10-22T12:14:19+08:00',
  ),
  BundledOfficialSkillSpec(
    name: '章节写作',
    assetPath: 'assets/official_skills/章节写作.md',
    version: 1,
    contentHash:
        '26cc8ff3ebe92fa1055f60f157cbd6e33633231a8a6623d06079d61c6ef94484',
    sortOrder: 2,
    updatedAt: '2026-10-22T12:14:19+08:00',
  ),
  BundledOfficialSkillSpec(
    name: '角色一致性',
    assetPath: 'assets/official_skills/角色一致性.md',
    version: 1,
    contentHash:
        '44a9c801b589aa3b27b243e24589507515f602aa8b7fcffc7ace2cf081862b32',
    sortOrder: 3,
    updatedAt: '2026-10-22T12:14:19+08:00',
  ),
  BundledOfficialSkillSpec(
    name: '人设设计',
    assetPath: 'assets/official_skills/人设设计.md',
    version: 1,
    contentHash:
        'cd257e4ecad0366a9ee922a6e5d5e4699c04ff14132c9e65d444d0090d7a9ea4',
    sortOrder: 4,
    updatedAt: '2026-10-22T12:14:19+08:00',
  ),
  BundledOfficialSkillSpec(
    name: '黄金三章',
    assetPath: 'assets/official_skills/黄金三章.md',
    version: 1,
    contentHash:
        '8a49035aa304e7d7dd421fac51c3163cf7e41526b30fd2aab3e3d19329ce22bc',
    sortOrder: 5,
    updatedAt: '2026-10-22T12:14:19+08:00',
    badge: '推荐',
  ),
  BundledOfficialSkillSpec(
    name: '去AI味',
    assetPath: 'assets/official_skills/去AI味.md',
    version: 1,
    contentHash:
        '92f7706c2df73f4b17f677c905c7ce70caeae2963a1df49466df48bb1a6662c5',
    sortOrder: 6,
    updatedAt: '2026-10-22T12:14:19+08:00',
  ),
  BundledOfficialSkillSpec(
    name: '长篇连续性',
    assetPath: 'assets/official_skills/长篇连续性.md',
    version: 1,
    contentHash:
        'c5e3fbef29b03c95760fb9a4982648285dddcd5598e342b78c6a188cd1bb0ccf',
    sortOrder: 7,
    updatedAt: '2026-10-22T12:14:19+08:00',
  ),
  BundledOfficialSkillSpec(
    name: '设定一致性',
    assetPath: 'assets/official_skills/设定一致性.md',
    version: 1,
    contentHash:
        '0805b7161a204eb391d66d124fef4293f0b198f00988772f2b726fe3af929089',
    sortOrder: 8,
    updatedAt: '2026-10-22T12:14:19+08:00',
  ),
  BundledOfficialSkillSpec(
    name: '世界观设定',
    assetPath: 'assets/official_skills/世界观设定.md',
    version: 1,
    contentHash:
        'dbd8db8460a68f0a450b500781acb166c1a9225f25cbd56b5a6967fc712fe9be',
    sortOrder: 9,
    updatedAt: '2026-10-22T12:14:19+08:00',
  ),
  BundledOfficialSkillSpec(
    name: '剧本写作',
    assetPath: 'assets/official_skills/screenplay-writing/SKILL.md',
    referenceAssetPaths: [
      'assets/official_skills/screenplay-writing/references/adaptation.md',
      'assets/official_skills/screenplay-writing/references/dialogue.md',
      'assets/official_skills/screenplay-writing/references/duration-estimation.md',
      'assets/official_skills/screenplay-writing/references/episode-planning.md',
      'assets/official_skills/screenplay-writing/references/review.md',
      'assets/official_skills/screenplay-writing/references/scene-writing.md',
    ],
    version: 3,
    contentHash:
        '8860e7da186e009c9574e80637789cf522bd20613bfcd2bad0775f7de5178998',
    sortOrder: 10,
    updatedAt: '2026-11-12T01:32:00+08:00',
  ),
  BundledOfficialSkillSpec(
    name: '地图设计指南',
    assetPath: 'assets/official_skills/map-design/SKILL.md',
    referenceAssetPaths: [
      'assets/official_skills/map-design/references/cartography.md',
      'assets/official_skills/map-design/references/prompt-examples.md',
    ],
    version: 1,
    contentHash:
        '90d5b21aa57ac234f07f0cdb9a63bdf23cf083e52565a2effa932bcbc9c68111',
    sortOrder: 11,
    updatedAt: '2026-10-22T17:37:42+08:00',
  ),
  BundledOfficialSkillSpec(
    name: '剧本制片',
    assetPath: 'assets/official_skills/screenplay-production/SKILL.md',
    referenceAssetPaths: [
      'assets/official_skills/screenplay-production/references/character-design.md',
      'assets/official_skills/screenplay-production/references/image-recipes.md',
      'assets/official_skills/screenplay-production/references/image-references.md',
      'assets/official_skills/screenplay-production/references/kling-prompts.md',
      'assets/official_skills/screenplay-production/references/minimax-h3-prompts.md',
      'assets/official_skills/screenplay-production/references/model-capabilities.md',
      'assets/official_skills/screenplay-production/references/production.md',
      'assets/official_skills/screenplay-production/references/scene-example.md',
      'assets/official_skills/screenplay-production/references/seedance-prompts.md',
      'assets/official_skills/screenplay-production/references/shot-recipes.md',
      'assets/official_skills/screenplay-production/references/storyboard.md',
      'assets/official_skills/screenplay-production/references/troubleshooting.md',
      'assets/official_skills/screenplay-production/references/veo-prompts.md',
      'assets/official_skills/screenplay-production/references/video-prompts.md',
      'assets/official_skills/screenplay-production/references/wan-prompts.md',
    ],
    version: 5,
    contentHash:
        'afb6d7f8bb687c2a5128a663b63a2832698c0887ba77c1c6880e6b1fb408b865',
    sortOrder: 12,
    updatedAt: '2026-11-12T13:53:54+08:00',
  ),
];

/// 打包官方技能所在目录。测试用它检查规格表与目录是否漂移。
const bundledOfficialSkillsAssetDir = 'assets/official_skills';

/// Bundled Official Skill 加载器。
///
/// 无状态：每次调用都重新读取 asset。任意一个 asset 缺失或 frontmatter 解析
/// 失败时抛 [StateError]，不返回部分目录。
class BundledOfficialSkillsLoader {
  const BundledOfficialSkillsLoader();

  /// 返回全量官方目录摘要，顺序与 [bundledOfficialSkillSpecs] 一致。
  Future<OfficialAgentSkillCatalog> list(AssetBundle bundle) async {
    final skills = <OfficialAgentSkillSummary>[];
    for (final spec in bundledOfficialSkillSpecs) {
      skills.add(await _loadSummary(bundle, spec));
    }
    return OfficialAgentSkillCatalog(agentSkills: skills);
  }

  /// 按 `listingId`（即官方技能 name）返回完整可安装快照。
  /// 名称不在打包目录中时抛 [ArgumentError]。
  Future<OfficialAgentSkill> get(AssetBundle bundle, String listingId) async {
    final specIndex = bundledOfficialSkillSpecs.indexWhere(
      (spec) => spec.name == listingId,
    );
    if (specIndex < 0) {
      throw ArgumentError.value(
        listingId,
        'listingId',
        'No bundled official skill with this name',
      );
    }
    return _loadDetail(bundle, bundledOfficialSkillSpecs[specIndex]);
  }

  Future<OfficialAgentSkillSummary> _loadSummary(
    AssetBundle bundle,
    BundledOfficialSkillSpec spec,
  ) async {
    final parsed = await _parse(bundle, spec);
    return OfficialAgentSkillSummary(
      listingId: spec.name,
      name: parsed.name,
      description: parsed.description,
      category: parsed.category,
      tags: parsed.tags,
      badge: spec.badge,
      version: spec.version,
      updatedAt: spec.updatedAt,
    );
  }

  Future<OfficialAgentSkill> _loadDetail(
    AssetBundle bundle,
    BundledOfficialSkillSpec spec,
  ) async {
    final parsed = await _parse(bundle, spec);
    return OfficialAgentSkill(
      listingId: spec.name,
      name: parsed.name,
      description: parsed.description,
      category: parsed.category,
      tags: parsed.tags,
      badge: spec.badge,
      version: spec.version,
      updatedAt: spec.updatedAt,
      whenToUse: parsed.whenToUse,
      prompt: parsed.body,
      references: await _loadReferences(bundle, spec),
      sortOrder: spec.sortOrder,
    );
  }

  Future<List<AgentSkillReferenceFile>> _loadReferences(
    AssetBundle bundle,
    BundledOfficialSkillSpec spec,
  ) async {
    final root = spec.assetPath.substring(
      0,
      spec.assetPath.lastIndexOf('/') + 1,
    );
    final files = <AgentSkillReferenceFile>[];
    for (final assetPath in spec.referenceAssetPaths) {
      if (!assetPath.startsWith(root)) {
        throw StateError(
          'official skill reference is outside its root: $assetPath',
        );
      }
      final relativePath = assetPath.substring(root.length);
      if (!AgentSkillReferences.isValidRelativePath(relativePath)) {
        throw StateError('invalid official skill reference path: $assetPath');
      }
      files.add(
        AgentSkillReferenceFile(
          path: relativePath,
          content: await bundle.loadString(assetPath),
        ),
      );
    }
    return AgentSkillReferences.normalizeOrThrow(files);
  }

  Future<AgentSkillImportParseResult> _parse(
    AssetBundle bundle,
    BundledOfficialSkillSpec spec,
  ) async {
    final raw = await bundle.loadString(spec.assetPath);
    final parsed = AgentSkillImportParser.parse(raw);
    if (parsed == null) {
      throw StateError(
        'bundled official skill at ${spec.assetPath} missing valid frontmatter '
        '(name/description required)',
      );
    }
    if (parsed.name != spec.name) {
      throw StateError(
        'bundled official skill at ${spec.assetPath} name=${parsed.name} '
        'does not match spec name=${spec.name}',
      );
    }
    return parsed;
  }
}

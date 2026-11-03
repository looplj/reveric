// 职责: 小说工作区模型 — 定义工作区 section、选择状态与 AI 上下文引用路径映射。
// 关联文件:
//   lib/shared/services/ai/chat_prompt_builder.dart
//   lib/desktop/widgets/ai/chat/runtime.dart
//   lib/shared/widgets/ai/diff/recent_changes_log.dart
//   lib/shared/providers/workspace_navigation_provider.dart
//   lib/shared/services/canvas_service.dart

import '../app_config.dart';

extension NovelWorkspaceSectionX on NovelWorkspaceSection {
  bool get isReadOnly => switch (this) {
    NovelWorkspaceSection.overview ||
    NovelWorkspaceSection.entity_graph ||
    NovelWorkspaceSection.story_progress ||
    _ => false,
  };

  String get aiResourceType => switch (this) {
    NovelWorkspaceSection.chapters => 'chapters',
    NovelWorkspaceSection.characters => 'characters',
    NovelWorkspaceSection.lore => 'lore',
    NovelWorkspaceSection.outlines => 'outlines',
    NovelWorkspaceSection.materials => 'materials',
    NovelWorkspaceSection.skills => 'skills',
    NovelWorkspaceSection.items => 'items',
    NovelWorkspaceSection.factions => 'factions',
    NovelWorkspaceSection.creatures => 'creatures',
    NovelWorkspaceSection.foreshadowings => 'foreshadowing',
    NovelWorkspaceSection.novel_description => 'novel',
    NovelWorkspaceSection.overview => 'overview',
    NovelWorkspaceSection.maps => 'maps',
    NovelWorkspaceSection.canvas => 'canvas',
    NovelWorkspaceSection.entity_graph => 'entity_graph',
    NovelWorkspaceSection.story_progress => 'story_progress',
    NovelWorkspaceSection.screenplay_script => 'screenplay_scenes',
    // 大纲区编辑的是集大纲，itemId 是集 ID，不是场次 ID。
    NovelWorkspaceSection.screenplay_outline => 'screenplay_episodes',
    NovelWorkspaceSection.screenplay_scenes => 'screenplay_scenes',
    NovelWorkspaceSection.storyboard => 'production_clips',
  };

  String? aiResourcePath({String? itemId, String? title}) {
    if (this == NovelWorkspaceSection.novel_description) {
      return '/profile';
    }

    final screenplayItemId = itemId?.trim();
    final isScreenplayResource =
        this == NovelWorkspaceSection.screenplay_script ||
        this == NovelWorkspaceSection.screenplay_outline ||
        this == NovelWorkspaceSection.screenplay_scenes;
    if (isScreenplayResource &&
        screenplayItemId != null &&
        screenplayItemId.isNotEmpty) {
      final escaped = _escapeAiResourcePathSegment(screenplayItemId);
      return switch (this) {
        NovelWorkspaceSection.screenplay_script => '/scenes/$escaped/elements',
        NovelWorkspaceSection.screenplay_outline =>
          '/episodes/$escaped/outline',
        NovelWorkspaceSection.screenplay_scenes => '/scenes/$escaped',
        _ => null,
      };
    }

    // 文档按标题寻址；lore/materials 还支持多级名称路径。
    final isTitlePathResource =
        this == NovelWorkspaceSection.lore ||
        this == NovelWorkspaceSection.outlines ||
        this == NovelWorkspaceSection.materials;
    if (isTitlePathResource) {
      final titlePath = title?.trim();
      if (titlePath == null || titlePath.isEmpty) {
        return null;
      }
      return '/$aiResourceType/${_normalizeAiTitlePath(titlePath)}';
    }

    final idPathResources = {
      NovelWorkspaceSection.chapters,
      NovelWorkspaceSection.characters,
      NovelWorkspaceSection.foreshadowings,
      NovelWorkspaceSection.storyboard,
      NovelWorkspaceSection.skills,
      NovelWorkspaceSection.items,
      NovelWorkspaceSection.factions,
      NovelWorkspaceSection.creatures,
      // canvas 不在此列：AI 画布工具按 name 寻址（/canvas/{name}），id 拼出的
      // 路径永远解析不了；宿主侧须查库把 canvas id 换成 name（见
      // ChatSessionController._currentWorkspaceContext）。
    };
    if (!idPathResources.contains(this)) {
      return null;
    }

    final id = itemId?.trim();
    if (id == null || id.isEmpty) {
      return null;
    }
    return '/${this == NovelWorkspaceSection.storyboard ? 'clips' : aiResourceType}/${_escapeAiResourcePathSegment(id)}';
  }
}

/// AI resourceType 字符串反向映射到工作区 section（[NovelWorkspaceSectionX.aiResourceType] 的逆）。
/// 用于「最近改动」点击跳转：把改动记录的 resourceType 还原成工作区 section。未知值返回 null。
NovelWorkspaceSection? novelWorkspaceSectionFromAiResourceType(
  String resourceType,
) {
  return switch (resourceType) {
    'chapters' => NovelWorkspaceSection.chapters,
    'characters' => NovelWorkspaceSection.characters,
    // 'worldbuilding' 是改名前的存量 working change 的 resourceType。
    'lore' || 'worldbuilding' => NovelWorkspaceSection.lore,
    'outlines' => NovelWorkspaceSection.outlines,
    'materials' => NovelWorkspaceSection.materials,
    'skills' => NovelWorkspaceSection.skills,
    'items' => NovelWorkspaceSection.items,
    'factions' => NovelWorkspaceSection.factions,
    'creatures' => NovelWorkspaceSection.creatures,
    'foreshadowing' => NovelWorkspaceSection.foreshadowings,
    'novel' => NovelWorkspaceSection.novel_description,
    'maps' => NovelWorkspaceSection.maps,
    'canvas' => ideationCanvasEnabled ? NovelWorkspaceSection.canvas : null,
    'screenplay_scenes' => NovelWorkspaceSection.screenplay_scenes,
    'production_clips' => NovelWorkspaceSection.storyboard,
    'screenplay_episodes' => NovelWorkspaceSection.screenplay_outline,
    _ => null,
  };
}

String _escapeAiResourcePathSegment(String value) {
  return value.trim().replaceAll('/', '%2F');
}

String _normalizeAiTitlePath(String value) {
  return value
      .trim()
      .replaceAll(RegExp(r'/+'), '/')
      .replaceAll(RegExp(r'^/|/$'), '');
}

enum NovelWorkspaceSection {
  overview,
  maps,
  canvas,
  novel_description,
  // lore = 世界观设定文档区；DB 的 Documents.type 与 AI 工具路径（/lore）同名。
  lore,
  outlines,
  materials,
  characters,
  skills,
  items,
  factions,
  creatures,
  chapters,
  foreshadowings,
  entity_graph,
  story_progress,
  screenplay_script,
  screenplay_outline,
  screenplay_scenes,
  storyboard,
}

/// 「图鉴」聚合的四类条目 — 共用 Item 模型、共用一个侧栏入口与一套增删改回调。
/// 各自的 section 值保留不变（DB type 与 AI 工具路径依赖它们），
/// 合并只体现在导航与文案层。
const List<NovelWorkspaceSection> compendiumSections = [
  NovelWorkspaceSection.factions,
  NovelWorkspaceSection.creatures,
  NovelWorkspaceSection.items,
  NovelWorkspaceSection.skills,
];

bool isCompendiumSection(NovelWorkspaceSection section) {
  return compendiumSections.contains(section);
}

class WorkspaceSelection {
  const WorkspaceSelection({
    required this.section,
    this.itemId,
    this.isCreating = false,
    this.isViewingAllOutlines = false,
  });

  const WorkspaceSelection.overview()
    : section = NovelWorkspaceSection.overview,
      itemId = null,
      isCreating = false,
      isViewingAllOutlines = false;

  const WorkspaceSelection.creating({required this.section})
    : itemId = null,
      isCreating = true,
      isViewingAllOutlines = false;

  final NovelWorkspaceSection section;
  final String? itemId;
  final bool isCreating;
  final bool isViewingAllOutlines;

  WorkspaceSelection copyWith({
    NovelWorkspaceSection? section,
    String? itemId,
    bool clearItemId = false,
    bool? isCreating,
    bool? isViewingAllOutlines,
  }) {
    return WorkspaceSelection(
      section: section ?? this.section,
      itemId: clearItemId ? null : (itemId ?? this.itemId),
      isCreating: isCreating ?? this.isCreating,
      isViewingAllOutlines: isViewingAllOutlines ?? this.isViewingAllOutlines,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is WorkspaceSelection &&
            section == other.section &&
            itemId == other.itemId &&
            isCreating == other.isCreating &&
            isViewingAllOutlines == other.isViewingAllOutlines;
  }

  @override
  int get hashCode =>
      Object.hash(section, itemId, isCreating, isViewingAllOutlines);
}

/// 可拖放到 AI 输入框的上下文引用
///
/// - workspace / agent_rule：内容类引用，发送时注入「请自行读取」提醒。
/// - file：用户选择的本地文本附件，发送时直接把 [content] 注入本轮上下文。
/// - selection：用户从编辑器主动选中的文本快照，同样只注入本轮上下文。
/// - subagent / skill：由 `/` 命令面板选中生成的 chip。subagent 走软偏好提示；
///   skill 走「直接加载」——发送时把完整技能指令直接注入本轮上下文。
enum AiContextReferenceKind {
  workspace,
  agent_rule,
  file,
  selection,
  subagent,
  skill,
}

class AiContextReference {
  const AiContextReference({
    required this.section,
    required this.itemId,
    required this.label,
    this.kind = AiContextReferenceKind.workspace,
    this.path,
    this.content = '',
  });

  const AiContextReference.file({
    required this.itemId,
    required this.label,
    required this.content,
  }) : section = NovelWorkspaceSection.overview,
       kind = AiContextReferenceKind.file,
       path = null;

  const AiContextReference.selection({
    required this.itemId,
    required this.label,
    required this.content,
  }) : section = NovelWorkspaceSection.chapters,
       kind = AiContextReferenceKind.selection,
       path = null;

  final NovelWorkspaceSection section;
  final String itemId;
  final String label;
  final AiContextReferenceKind kind;
  final String? path;

  /// 仅 file / selection 使用。内容只进入聊天消息，不包含本地路径。
  final String content;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiContextReference &&
          kind == other.kind &&
          section == other.section &&
          itemId == other.itemId;

  @override
  int get hashCode => Object.hash(kind, section, itemId);
}

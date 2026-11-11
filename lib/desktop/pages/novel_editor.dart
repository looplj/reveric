// 职责: 桌面端小说编辑页 — 组织工作区、侧边栏、AI 聊天与封面工作流。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/shared/widgets/novel_open_boundary.dart
//   lib/desktop/widgets/ai/chat/panel.dart
//   lib/desktop/widgets/ai/feature_onboarding_dialog.dart
//   lib/desktop/widgets/novel_editor/collapsed_ai_panel.dart
//   lib/desktop/widgets/novel_editor/add_to_library_banner.dart
//   lib/desktop/widgets/novel_editor/novel_load_error_state.dart
//   lib/desktop/widgets/workspace/chapter_outline_window.dart
//   lib/shared/services/app_initialization.dart
//   lib/desktop/widgets/sidebar/sidebar.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/anonymous_reporting_providers.dart
//   lib/shared/services/ai/chat_session_controller.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/providers/ai_shortcut_action_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/zh-CN/tool.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/agent_shortcut.json
//   assets/translations/zh-CN/agent_shortcut.json
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
// 遵循的 Rules:
//   .agents/rules/json.md
//   .agents/rules/hooks.md
//
// =============================================================================
// 页面区域命名规范 (NovelEditorPage Layout Regions)
// =============================================================================
// 以下命名用于统一描述本页面的各个功能区域，防止沟通误解：
//
// ┌───────────────────────────────────────────────────────────────────────────────────┐
// │ TitleBarArea (DesktopWindowFrame 标题栏区域)                                        │
// ├───────────────────────────────────────────────────────────────────────────────────┤
// │                                                                                   │
// │  ┌─────┬───────────────┬─────────────────────────────────────┬───────────────────┐│
// │  │Rail │ Middle Column │ Main                                 │ Chat Panel        ││
// │  │48px │ (可折叠/展开)  │ (switch contentSelection, 11 种)      │ (4 种状态)        ││
// │  │     │               │                                     │                   ││
// │  │ icon│ ┌───────────┐ │ ┌──────────────────────────────┐   │ ┌───────────────┐ ││
// │  │ nav │ │NovelNav   │ │ │WorkspaceContentArea          │   │ │AiChatArea     │ ││
// │  │     │ │Area       │ │ │(NovelWorkspacePanel)         │   │ └───────────────┘ ││
// │  │     │ │(小说信息/  │ │ ├──────────────────────────────┤   │ 或               ││
// │  │     │ │ AI 会话)  │ │ │AgentProfileEditArea          │   │ ┌───────────────┐ ││
// │  │     │ ├───────────┤ │ ├──────────────────────────────┤   │ │CoverStudioArea│ ││
// │  │     │ │Workspace  │ │ │SubAgentEditArea / SkillEdit   │   │ └───────────────┘ ││
// │  │     │ │NavArea    │ │ │AgentRuleEditArea              │   │ 或               ││
// │  │     │ │(章节/角色/ │ │ ├──────────────────────────────┤   │ ┌───────────────┐ ││
// │  │     │ │ 世界观 等) │ │ │CouncilArea / MonologueArea  │   │ │CollapsedAiPanel│ ││
// │  │     │ │           │ │ │TheaterArea / RoleplayArea    │   │ └───────────────┘ ││
// │  │     │ │           │ │ ├──────────────────────────────┤   │ 或               ││
// │  │     │ │           │ │ │ExpandedChatArea              │   │ (沉浸聊天在 Main 时 ││
// │  │     │ │           │ │ │(占满 Main)                    │   │  不渲染侧边面板)    ││
// │  │     │ └───────────┘ │ └──────────────────────────────┘   │  取代)            ││
// │  └─────┴───────────────┴─────────────────────────────────────┴───────────────────┘│
// │                                                                                   │
// ├── FloatingOverlayArea (浮动叠加区) ───────────────────────────────────────────────┤
// │  - NovelEditorCollapsedSidebarBackButton：sidebar 折叠时浮在左上角，提供返回入口         │
// ├── ModalOverlayArea (模态浮层区) ───────────────────────────────────────────────────┤
// │  - NovelFormDialog / CreateFolderDialog / PendingChangesDetailDialog /             │
// │    ChangeHistoryDialog / AgentEditingBlockedDialog                                 │
// └───────────────────────────────────────────────────────────────────────────────────┘
//
// 区域说明：
// ─────────────────────────────────────────────────────────────────────────────
// 1. TitleBarArea (标题栏区)
//    - 位置：页面最顶部
//    - 职责：承载 macOS 红绿灯按钮避让、Windows/Linux 窗口控制按钮、拖拽移动区域
//    - 实现：由 DesktopWindowFrame 自动处理
//
// 2. Rail (侧栏窄轨区)
//    - 位置：页面最左侧，宽度 48px，始终可见
//    - 职责：工作区分类图标导航、智能体模式快捷入口、侧栏展开/折叠
//    - 实现：LeftSidebar._buildRail() (rail.dart)，内置 LeftSidebar 的 Stack 左层
//    - 注意：Rail 始终渲染，不受 sidebarCollapsed 影响
//
// 3. Middle Column (导航中栏区)
//    - 位置：Rail 右侧，宽度 = RevericSizes.sidebarWidth - rail 宽度，可折叠
//    - 职责：小说信息、工作区列表导航、AI 会话列表、智能体管理入口
//    - 子区域：
//      a) NovelNavArea (小说导航区) - 小说切换、AI 会话列表
//      b) WorkspaceNavArea (工作区导航区) - 章节/角色/世界观等分类列表
//    - 实现：LeftSidebar._buildPanel() (sections.dart)，内置 LeftSidebar 的 Stack 右层
//    - 折叠态：sidebarCollapsed = true 时通过 IgnorePointer 隐藏，动画控制宽度
//
// 4. Main (主内容区)
//    - 位置：Middle Column 与 Chat Panel 之间，通过 Expanded 占满剩余空间
//    - 职责：根据 contentSelection 切换显示对应编辑面板
//    - 子区域 (switch contentSelection)：
//      a) WorkspaceContentArea (工作区内容区) - NovelWorkspacePanel
//      b) SubAgentEditArea (子智能体编辑区) - SubAgentEditPanel
//      c) AgentRuleEditArea (规则编辑区) - AgentRuleEditPanel
//      d) CouncilArea (智能体议事区) - AgentCouncilPanel
//      e) MonologueArea (独白区) - MonologuePanel
//      f) TheaterArea (剧场区) - TheaterPanel
//      g) RoleplayArea (角色扮演区) - RoleplayPanel
//      h) ExpandedChatArea (AI 沉浸聊天区) - contentSelection 为沉浸聊天时占满 Main
//
// 5. Chat Panel (AI 聊天面板区)
//    - 位置：页面最右侧
//    - 职责：AI 聊天对话；封面工作台打开时整列隐藏
//    - 状态机 (按优先级)：
//      a) 沉浸聊天在 Main → 整列隐藏（被 ExpandedChatArea 取代）
//      b) _EditorCoverStudioSelection → Main CoverStudio（画布|设计师）；中栏挂生成记录
//      c) !aiPanelCollapsed → AiChatArea (AI 聊天面板)
//      d) 默认 → CollapsedAiPanelArea (折叠窄条)
//
// 6. FloatingOverlayArea (浮动叠加区)
//    - 位置：通过 Stack Positioned 叠加在主布局之上
//    - 职责：sidebar 折叠时的返回按钮
//    - 实现：NovelEditorCollapsedSidebarBackButton，sidebarCollapsed 时显示
//
// 7. ModalOverlayArea (模态浮层区)
//    - 位置：通过 showDialog / showGeneralDialog 覆盖整个页面
//    - 职责：编辑弹窗、确认弹窗、文件选择器
//    - 弹窗列表：
//      a) NovelFormDialog.edit() — 编辑小说详情
//      b) CreateFolderDialog — 创建文件夹时输入名称
//      c) PendingChangesDetailDialog — 查看待处理变更
//      d) ChangeHistoryDialog — 查看变更历史
//      e) AgentEditingBlockedDialog — 智能体编辑中离开确认
//      f) FilePicker — 封面/头像文件选择
// =============================================================================
import '../../shared/services/storyboard/service.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/components/dialog_feedback.dart';
import '../../shared/widgets/foreshadowing/position_links.dart';
import '../../shared/widgets/novel_open_boundary.dart';
import '../../shared/database/app_database.dart';
import '../../shared/database/novel_content_database.dart';
import '../../shared/heuristic/chat_next_action.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/ai_session_mode.dart';
import '../../shared/models/feature_id.dart';
import '../../shared/models/ai_shortcut_action.dart';
import '../../shared/providers/map_studio_controller.dart'
    show mapGenerationActivityCounter;
import '../../shared/models/agent_profile.dart';
import '../../shared/models/agent_rule.dart';
import '../../shared/models/novel_workspace.dart';
import '../../shared/models/novel_workspace_state.dart';
import '../../shared/models/subagent.dart';
import '../../shared/models/outline.dart';
import '../../shared/providers/ai_providers.dart'
    show
        AiChatCancelSource,
        aiChatRuntimeProvider,
        aiServiceAsyncProvider,
        isImageGenerationConfiguredProvider,
        isTemporaryAiChatSessionId;
import '../../shared/providers/cover_studio_providers.dart'
    show canOpenCoverStudioProvider;
import '../../shared/providers/map_agent_providers.dart';
import '../../shared/models/map_agent.dart';
import '../../shared/providers/maps_providers.dart'
    show mapsProvider, locationsProvider;
import '../../shared/providers/novel_providers.dart';
import '../../shared/providers/novel_workspace_state_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/providers/workspace_navigation_provider.dart';
import '../../shared/models/screenplay_workspace_state.dart';
import '../../shared/providers/screenplay_providers.dart';
import '../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../shared/services/ai/session_persistence.dart'
    show pickPreferredAiChatSession;
import '../../shared/services/ai/chat_session_controller.dart';
import '../../shared/services/app_initialization.dart'
    show appStateKeyChatOnboardingShown;
import '../../shared/services/novel_actions.dart';
import '../../shared/services/novel_content.dart' show NovelContentService;
import '../../shared/services/chapter_save.dart';
import '../../shared/services/working_overlay.dart';
import '../../shared/theme/theme.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/utils/ai_path_name_check.dart';
import '../../shared/utils/text_file_decoder.dart';
import '../../shared/widgets/app_background.dart';
import '../../shared/widgets/unsaved_changes_dialog.dart';
import '../../shared/components/resizable_pane_divider.dart';
import '../widgets/agent_management/agent_rule_edit_panel.dart';
import '../widgets/agent_management/agent_rules_grid_page.dart';
import '../widgets/ai/chat/panel.dart';
import '../widgets/ai/chat/expanded_chat_area.dart';
import '../widgets/ai/chat/floating.dart';
import '../../shared/providers/production_chat.dart';
import '../../shared/providers/production_view.dart';
import '../features/cover_studio/studio_page.dart';
import '../widgets/ai/feature_onboarding_dialog.dart';
import '../widgets/novel_editor/add_to_library_banner.dart';
import '../widgets/novel_editor/collapsed_ai_panel.dart';
import '../widgets/novel_editor/collapsed_sidebar_back_button.dart';
import '../widgets/novel_editor/novel_load_error_state.dart';
import '../widgets/novel_editor/novel_missing_state.dart';
import '../widgets/novel_editor/sidebar_divider.dart';
import '../widgets/novel_editor/step3_cover_overlay.dart';
import '../widgets/sidebar/collapsed_sidebar.dart';
import '../widgets/sidebar/rail_only.dart';
import '../widgets/desktop_window_frame.dart';
import '../widgets/desktop_save_shortcut.dart';
import '../widgets/history/change_history_panel.dart';
import '../widgets/history/resource_history_button.dart';
import '../widgets/sidebar/sidebar.dart';
import '../features/council/panel.dart';
import '../features/monologue/panel.dart';
import '../widgets/novel_form_dialog.dart';
import '../features/roleplay/panel.dart';
import '../features/theater/panel.dart';
import '../../shared/providers/ai_mode_processing.dart';
import '../../shared/models/canvas_ai_activity.dart';
import '../widgets/ai/chat/session_binding.dart';
import '../../shared/models/content_kind.dart';
import '../../shared/providers/agent_council_providers.dart';
import '../../shared/providers/canvas_providers.dart'
    show canvasAiActivityProvider;
import '../../shared/providers/monologue_providers.dart';
import '../../shared/providers/roleplay_providers.dart';
import '../../shared/providers/theater_providers.dart';
import '../widgets/workspace/chapter_outline_window.dart';
import '../features/reading/reading_window.dart';
import '../widgets/workspace/character_profile_editor_region.dart';
import '../widgets/workspace/novel_workspace_panel.dart';
import '../widgets/ai/diff/pending_changes_detail_dialog.dart';
import '../widgets/agent_management/subagent_edit_panel.dart';
import '../widgets/agent_management/agent_edit_save_contract.dart';
import 'workspace_editor_page.dart';
import '../../shared/components/reveric_dialog.dart';
import '../../shared/components/reveric_button.dart';
import '../../shared/utils/route_pop.dart';

part 'novel_editor_ai_area.dart';
part 'novel_editor_agent_editing.dart';
part 'novel_editor_agent_mode_area.dart';
part 'novel_editor_duplicate_title_validation.dart';
part 'novel_editor_content_selection.dart';
part 'novel_editor_support.dart';

final _log = AppLogger.forModule('NovelEditor');

class NovelEditorPage extends HookConsumerWidget {
  const NovelEditorPage({
    super.key,
    required this.novelId,
    this.initialSessionId,
    this.initialChatKickoffPrompt,
    this.initialChatKickoffTitle,
    this.openChatOnEntry = false,
  });

  final String novelId;
  final String? initialSessionId;

  /// 快速开书时携带的开场提示词：非空则进入后展开沉浸聊天并
  /// 自动发送该消息，触发创作向导引导用户完善设定。
  final String? initialChatKickoffPrompt;

  /// 开场会话标题，缺省为「快速开书」。
  final String? initialChatKickoffTitle;

  /// 新建小说进入时直接展开聊天，等待用户输入，不自动发送消息。
  final bool openChatOnEntry;
  static const Duration _autoSaveDelay = Duration(seconds: 2);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NovelOpenBoundary(
      novelId: novelId,
      child: HookConsumer(
        builder: (context, ref, _) => _buildContent(context, ref),
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final appBackgroundActive = ref.watch(appBackgroundActiveProvider);
    final persistedPaneLayout =
        ref.watch(novelEditorPaneLayoutProvider).asData?.value ??
        NovelEditorPaneLayout.defaults;
    final draggingPaneLayout = useState<NovelEditorPaneLayout?>(null);
    final novelAsync = ref.watch(novelProvider(novelId));
    final workspaceStateProvider = novelWorkspaceStateControllerProvider(
      novelId,
    );
    ref.watch(workspaceStateProvider.select((state) => state.selection));
    final isWorkspaceStateHydrated = ref.watch(
      workspaceStateProvider.select((state) => state.isHydrated),
    );
    final selection = ref.read(workspaceStateProvider.notifier);
    final isSavingEntry = useState(false);
    // 0 = 隐藏，1/2/3 = 面板步骤，4 = 页面级封面 overlay
    final chatOnboardingStep = useState(0);
    final coverThumbnailKey = useMemoized(() => GlobalKey(), []);
    // 顶部工具栏和 DesktopWindowFrame 的标题栏拖拽层重叠；
    // 将它注册为排除区域，避免双击 Save 等按钮时触发窗口最大化/还原。
    final workspaceHeaderToolbarKey = useMemoized(() => GlobalKey(), []);
    final coverMenuTrigger = useState(0);

    final chapterTitleController = useTextEditingController();
    final chapterOutlineController = useTextEditingController();
    final chapterOutlineWindowSession = useMemoized(
      () => ChapterOutlineWindowSession(
        titleController: chapterTitleController,
        outlineController: chapterOutlineController,
      ),
      [chapterTitleController, chapterOutlineController],
    );
    useEffect(() {
      return () {
        unawaited(chapterOutlineWindowSession.dispose());
      };
    }, [chapterOutlineWindowSession]);
    final readingWindowSession = useMemoized(ReadingWindowSession.new);
    useEffect(() {
      return () {
        unawaited(readingWindowSession.dispose());
      };
    }, [readingWindowSession]);
    final chapterContentController = useTextEditingController();
    final novelDescriptionController = useTextEditingController();
    final chapterNumber = useState<int?>(null);
    final entryTitleController = useTextEditingController();
    final entryContentController = useTextEditingController();
    final entryCategoryController = useTextEditingController();
    final characterEditorController = useMemoized(
      CharacterProfileEditorRegionController.new,
    );
    final itemPhotos = useState<List<String>>(const <String>[]);
    final isAddingItemPhoto = useState(false);
    final foreshadowSetupController = useTextEditingController();
    final foreshadowPayoffController = useTextEditingController();
    final chapterTitleFocusNode = useFocusNode();
    final chapterOutlineFocusNode = useFocusNode();
    final chapterContentFocusNode = useFocusNode();
    final novelDescriptionFocusNode = useFocusNode();
    final entryTitleFocusNode = useFocusNode();
    final entryContentFocusNode = useFocusNode();
    final entryCategoryFocusNode = useFocusNode();
    final foreshadowTitleFocusNode = useFocusNode();
    final foreshadowSetupFocusNode = useFocusNode();
    final foreshadowPayoffFocusNode = useFocusNode();

    final selectedStatus = useState(foreshadowingStatusPending);
    final foreshadowPositions = useState(emptyForeshadowingPositionIds);
    final outlineDraft = useState<OutlineDraft?>(null);
    final pendingOutlineDraft = useRef<OutlineDraft?>(null);
    // 挂载时读取一次待处理的工作区导航请求。
    // 初始 selection 直接落到请求的 section。
    final pendingNavRequest = useMemoized(
      () => ref.read(workspaceNavigationProvider),
    );
    // 离开 chapters 后无法再 saveChapter；关掉独立窗口，避免「能改但写不回」。
    useEffect(() {
      if (selection.value.section != NovelWorkspaceSection.chapters) {
        unawaited(chapterOutlineWindowSession.closeWindow());
      }
      return null;
    }, [selection.value.section, chapterOutlineWindowSession]);
    final chapterUndoSessionKey =
        selection.value.section == NovelWorkspaceSection.chapters
        ? selection.value.itemId
        : null;
    final chapterTitleUndoController = useMemoized(UndoHistoryController.new, [
      chapterUndoSessionKey,
    ]);
    final chapterOutlineUndoController = useMemoized(
      UndoHistoryController.new,
      [chapterUndoSessionKey],
    );
    final chapterContentUndoController = useMemoized(
      UndoHistoryController.new,
      [chapterUndoSessionKey],
    );
    useEffect(() => chapterTitleUndoController.dispose, [
      chapterTitleUndoController,
    ]);
    useEffect(() => chapterOutlineUndoController.dispose, [
      chapterOutlineUndoController,
    ]);
    useEffect(() => chapterContentUndoController.dispose, [
      chapterContentUndoController,
    ]);
    useEffect(() {
      if (pendingNavRequest != null) {
        // 延后到构建阶段之外写入；控制器会让显式导航覆盖仍在进行的数据库恢复。
        Future<void>(() {
          if (!context.mounted) {
            return;
          }
          selection.value = WorkspaceSelection(
            section: pendingNavRequest.section,
            itemId: pendingNavRequest.itemId,
          );
          ref.read(workspaceNavigationProvider.notifier).clear();
        });
      }
      return null;
    }, [pendingNavRequest, selection]);

    // 剧本正文区挂载时交回它的落盘函数；小说作品下始终为 null。
    final screenplaySceneFlush = useRef<Future<void> Function()?>(null);
    final createDraft = useState<_WorkspaceCreateDraft?>(null);
    final createDraftFieldError = useState<String?>(null);
    final entryTitleFieldError = useState<String?>(null);
    final sidebarCollapsed = useState(false);
    final aiPanelCollapsed = useState(openChatOnEntry);
    // 制片画布及剪辑、导演台使用聊天浮窗，右栏状态原样保留。
    final productionChat = ref.watch(productionChatProvider(novelId));
    final chatPanelKey = useMemoized(GlobalKey.new);
    final contentDatabasePath = useState<String?>(null);
    final initializedNovelId = useState<String?>(null);
    final autoSaveTimer = useRef<Timer?>(null);
    final chapterAutoSaveFeedback = useValueNotifier(0);
    final isSyncingControllerText = useRef(false);
    // 编辑器与正文列的同步基线：编辑器自己加载、保存或接受过的正文。同步 effect
    // 用它区分本地脏输入、保存回声与外部写入，避免 DB 回流覆盖正在编辑的内容。
    final lastSyncedChapterContent = useRef<String?>(null);
    final pendingLocalChapterId = useRef<String?>(null);
    final pendingLocalChapterContent = useRef<String?>(null);
    final pendingLocalChapterSaveToken = useRef<Object?>(null);
    final chapterSaveInFlight = useRef<Future<void>?>(null);
    final chapterSaveRequested = useRef(false);
    final chapterSaveAllowEmpty = useRef(false);
    final chapterSaveShowSuccess = useRef(false);
    final outlineSaveChain = useRef<Future<void>>(Future<void>.value());
    final loadedWorkspaceSection = useRef<NovelWorkspaceSection?>(null);
    final loadedWorkspaceItemId = useRef<String?>(null);
    final isApplyingCover = useState(false);
    final isAgentEditing = useState(false);
    final isModeRunning = useState(false);
    final allowLeaveWithRunningAgent = useState(false);
    final pendingCoverDraft = useState<AiChatDraftMessage?>(null);
    final pendingHandoffDraft = useState<AiChatHandoffDraft?>(null);
    final pendingShortcutDraft = useState<AiChatShortcutDraft?>(null);
    final contentSelection = useState<_EditorContentSelection>(
      openChatOnEntry
          ? const _EditorAiChatExpandedSelection()
          : const _EditorWorkspaceContentSelection(),
    );

    ref.listen(mapAgentHandoffProvider, (previous, next) {
      final activePath = contentDatabasePath.value;
      if (next == null ||
          activePath == null ||
          next.databasePath != activePath) {
        return;
      }
      final label = context.t(LocaleKeys.mapEditorAgentHandoffLabel);
      final prompt = buildMapAgentHandoffPrompt(
        styleId: next.styleId,
        styleWord: next.styleWord,
        subMapScale: next.subMapScale,
      );
      aiPanelCollapsed.value = false;
      pendingHandoffDraft.value = AiChatHandoffDraft(
        id: 'map_design_${DateTime.now().microsecondsSinceEpoch}',
        label: label,
        content: prompt,
        title: '${next.worldName} · $label',
        autoSend: true,
        references: [
          AiContextReference(
            section: NovelWorkspaceSection.maps,
            itemId: next.worldId,
            label: next.worldName,
            path: '/locations/${next.worldId}',
          ),
        ],
        initialText: prompt,
      );
    });

    // 地图生成期间拦截工作区页面/world 切换：生成挂在 autoDispose 的
    // MapStudioController 上，主区一旦离开 maps，它就失去唯一 watcher 被销毁，
    // 正在进行的生成随之中断（已发出的图片调用仍会计费）。
    bool isMapGenerationBlockingSwitch() {
      return selection.value.section == NovelWorkspaceSection.maps &&
          mapGenerationActivityCounter.value > 0;
    }

    void notifyMapGenerationBlocksSwitch() {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.t(LocaleKeys.mapEditorGenerationSwitchBlocked),
            ),
          ),
        );
      }
    }

    // 「最近改动」点击条目 → 跳转到工作区对应资源（切 selection + 主内容区回工作区）。
    ref.listen(workspaceNavigationProvider, (previous, next) async {
      if (next == null) {
        return;
      }
      ref.read(workspaceNavigationProvider.notifier).clear();
      // 最近改动/AI 导航同样不能在生成中抢走主区。
      if (isMapGenerationBlockingSwitch()) {
        notifyMapGenerationBlocksSwitch();
        return;
      }
      if (next.section == NovelWorkspaceSection.storyboard &&
          next.itemId != null) {
        try {
          await screenplaySceneFlush.value?.call();
          if (!context.mounted) {
            return;
          }
          final path = contentDatabasePath.value!;
          final shot = await StoryboardService(
            ref.read(novelContentDatabaseProvider(path)),
          ).getShot(next.itemId!);
          if (shot == null || !context.mounted) {
            return;
          }
          await ref
              .read(
                screenplayWorkspaceStateControllerProvider(
                  novelId,
                  path,
                ).notifier,
              )
              .openEpisodeOutline(shot.episodeId);
        } catch (error, stackTrace) {
          _log.error(
            'storyboard navigation failed',
            error: error,
            stackTrace: stackTrace,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.t(LocaleKeys.commonLoadFailed))),
            );
          }
          return;
        }
        if (!context.mounted) {
          return;
        }
      }
      if (next.section == NovelWorkspaceSection.screenplay_outline &&
          next.itemId != null) {
        try {
          await screenplaySceneFlush.value?.call();
          if (!context.mounted) {
            return;
          }
          await ref
              .read(
                screenplayWorkspaceStateControllerProvider(
                  novelId,
                  contentDatabasePath.value!,
                ).notifier,
              )
              .openEpisodeOutline(next.itemId!);
        } catch (error, stackTrace) {
          _log.error(
            'episode outline navigation failed',
            error: error,
            stackTrace: stackTrace,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.t(LocaleKeys.commonLoadFailed))),
            );
          }
          return;
        }
        if (!context.mounted) {
          return;
        }
      }
      selection.value = WorkspaceSelection(
        section: next.section,
        itemId: next.itemId,
      );
      contentSelection.value = const _EditorWorkspaceContentSelection();
    });

    final subAgentHasChanges = useState(false);
    final agentRuleHasChanges = useState(false);
    // 当前活动的 agent 编辑面板（rule/skill/subagent）注册的「保存」函数，
    // 供未保存变更拦截 dialog 的「保存」按钮调用；面板卸载时回传 null。
    final activeAgentPanelSave = useRef<Future<bool> Function()?>(null);
    final activeAgentPanelHasChanges = useRef<bool Function()?>(null);
    final activeAgentPanelIsBlankCreateDraft = useRef<bool Function()?>(null);

    // 性能优化：首屏只订阅必要 provider（chapters / workingChanges），
    // 其余 12 个 stream 订阅在第一帧渲染完成（导航转场已展开）后再触发，
    // 避免一次性创建 14 个 Drift watch 流导致跳转卡顿。
    final hydrated = useState(false);
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          hydrated.value = true;
        }
      });
      return null;
    }, const []);

    useEffect(
      () {
        final currentNovel = novelAsync.asData?.value;
        if (currentNovel == null ||
            initializedNovelId.value == currentNovel.id) {
          return null;
        }

        initializedNovelId.value = currentNovel.id;
        // 性能优化：当 novel 已经有 contentDatabasePath 时，
        // 直接复用，避免每次进入页面都重新打开 DB + 跑 seedDefaultWorkspace，
        // 这会在导航转场期占用 Drift 后台 isolate 造成卡顿。
        // 路径不存在的旧记录才走 ensureNovelContentDatabasePath 兜底。
        final existingPath = currentNovel.contentDatabasePath;
        if (existingPath != null && existingPath.isNotEmpty) {
          contentDatabasePath.value = existingPath;
          return null;
        }
        Future<void>(() async {
          final databasePath = await ref
              .read(novelActionsProvider)
              .ensureNovelContentDatabasePath(currentNovel);
          if (!context.mounted) {
            return;
          }
          contentDatabasePath.value = databasePath;
        });
        return null;
      },
      [
        novelAsync.asData?.value?.id,
        novelAsync.asData?.value?.contentDatabasePath,
      ],
    );

    final databasePath =
        contentDatabasePath.value ??
        novelAsync.asData?.value?.contentDatabasePath;

    // 剧本作品的季 / 集 / 场次选择 —— AI 面板要靠它定位当前上下文。
    // 小说作品下两个值恒为 null / false，不建订阅。
    final isScreenplayWork =
        novelAsync.asData?.value?.contentKind == contentKindScreenplay &&
        databasePath != null &&
        databasePath.isNotEmpty;
    final screenplayWorkspace = isScreenplayWork
        ? ref.watch(
            screenplayWorkspaceStateControllerProvider(novelId, databasePath),
          )
        : null;
    if (isScreenplayWork) {
      ref.listen(workspaceStateProvider.select((state) => state.selection), (
        previous,
        next,
      ) {
        // 剧本监听会在下一帧 build 前同步写回 selection，必须读取最新状态。
        final current = ref.read(
          screenplayWorkspaceStateControllerProvider(novelId, databasePath),
        );
        final reconciled = reconcileScreenplayWorkspaceSelection(
          selection: next,
          previousEpisodeId: current.episodeId,
          episodeId: current.episodeId,
          sceneId: current.sceneId,
        );
        if (reconciled != next) {
          selection.value = reconciled;
        }
      });
      ref.listen(
        screenplayWorkspaceStateControllerProvider(novelId, databasePath),
        (previous, next) {
          final reconciled = reconcileScreenplayWorkspaceSelection(
            selection: selection.value,
            previousEpisodeId: previous?.episodeId,
            episodeId: next.episodeId,
            sceneId: next.sceneId,
          );
          if (reconciled != selection.value) {
            selection.value = reconciled;
          }
        },
      );
    }
    final hasMultipleScreenplaySeasons = () {
      if (!isScreenplayWork) return false;
      final rootId = ref.watch(screenplayRootProvider(databasePath)).value?.id;
      if (rootId == null) return false;
      final seasons = ref
          .watch(screenplaySeasonsProvider(databasePath, rootId))
          .value;
      return (seasons?.length ?? 0) > 1;
    }();

    // AI 新建或要求打开画布 → 把它切进主内容区。用户刚让 AI 画图，不该还要
    // 自己去列表里找；画布是工作区的一个 section，不再单开路由页。
    ref.listen(canvasAiActivityProvider, (previous, next) {
      if (next == null || next.seq == previous?.seq) {
        return;
      }
      final opensCanvas =
          next.kind == CanvasAiActivityKind.create_canvas ||
          next.kind == CanvasAiActivityKind.open_canvas;
      if (!opensCanvas || databasePath == null) {
        return;
      }
      // 已经停在这张画布上就别再打断（AI 连续调用 open 是常见的）。
      if (selection.value.section == NovelWorkspaceSection.canvas &&
          selection.value.itemId == next.canvasId) {
        return;
      }
      selection.value = WorkspaceSelection(
        section: NovelWorkspaceSection.canvas,
        itemId: next.canvasId,
      );
      contentSelection.value = const _EditorWorkspaceContentSelection();
    });

    // 首屏关键 provider（默认 overview/chapters 视图渲染所需）。
    // 章节树只订阅元数据；正文按当前选中章节或搜索页按需读取。
    final chaptersAsync = databasePath == null
        ? const AsyncValue<List<Chapter>>.loading()
        : ref.watch(chapterTreeProvider(databasePath));
    final selectedChapterAsync =
        databasePath == null ||
            selection.value.section != NovelWorkspaceSection.chapters ||
            selection.value.itemId == null
        ? const AsyncValue<Chapter?>.data(null)
        : ref.watch(
            chapterContentByIdProvider(
              path: databasePath,
              chapterId: selection.value.itemId!,
            ),
          );
    final lastWrittenChapterAsync = databasePath == null
        ? const AsyncValue<Chapter?>.data(null)
        : ref.watch(lastWrittenChapterProvider(databasePath));
    // 次要 provider：等首帧渲染完后再订阅，避免一次性触发 12 个 Drift watch
    // 阻塞导航转场动画。
    final secondaryReady = databasePath != null && hydrated.value;
    final worldbuildingAsync = !secondaryReady
        ? const AsyncValue<List<Document>>.loading()
        : ref.watch(
            documentsProvider(path: databasePath, type: documentTypeLore),
          );
    final outlinesAsync = !secondaryReady
        ? const AsyncValue<List<OutlineDraft>>.loading()
        : ref.watch(outlinesProvider(databasePath));
    final materialsAsync = !secondaryReady
        ? const AsyncValue<List<Document>>.loading()
        : ref.watch(
            documentsProvider(path: databasePath, type: documentTypeMaterial),
          );
    final charactersAsync = !secondaryReady
        ? const AsyncValue<List<CharacterProfile>>.loading()
        : ref.watch(characterProfilesProvider(databasePath));
    final skillsAsync = !secondaryReady
        ? const AsyncValue<List<Item>>.loading()
        : ref.watch(itemsProvider(path: databasePath, type: 'skill'));
    final itemsAsync = !secondaryReady
        ? const AsyncValue<List<Item>>.loading()
        : ref.watch(itemsProvider(path: databasePath, type: 'item'));
    final factionsAsync = !secondaryReady
        ? const AsyncValue<List<Item>>.loading()
        : ref.watch(itemsProvider(path: databasePath, type: 'faction'));
    final creaturesAsync = !secondaryReady
        ? const AsyncValue<List<Item>>.loading()
        : ref.watch(itemsProvider(path: databasePath, type: 'creature'));
    final foreshadowingsAsync = !secondaryReady
        ? const AsyncValue<List<Foreshadowing>>.loading()
        : ref.watch(foreshadowingsProvider(databasePath));
    final mapsAsync = !secondaryReady
        ? const AsyncValue<List<NovelMap>>.loading()
        : ref.watch(mapsProvider(databasePath));
    final locationsAsync = !secondaryReady
        ? const AsyncValue<List<Location>>.loading()
        : ref.watch(locationsProvider(databasePath));
    final chapterSortDescending = ref.watch(chapterSortDescendingProvider);
    useEffect(
      () {
        if (!isWorkspaceStateHydrated) {
          return null;
        }
        final current = selection.value;
        Iterable<String>? availableItemIds;
        switch (current.section) {
          case NovelWorkspaceSection.chapters:
            final chapters = chaptersAsync.asData?.value;
            // 默认选章跟随侧栏排序；已有有效选择仍由 reconcile 保留。
            availableItemIds =
                (chapterSortDescending ? chapters?.reversed : chapters)?.map(
                  (chapter) => chapter.id,
                );
          case NovelWorkspaceSection.lore:
            availableItemIds = worldbuildingAsync.asData?.value.map(
              (entry) => entry.id,
            );
          case NovelWorkspaceSection.outlines:
            availableItemIds = outlinesAsync.asData?.value.map(
              (entry) => entry.documentId,
            );
          case NovelWorkspaceSection.materials:
            availableItemIds = materialsAsync.asData?.value.map(
              (entry) => entry.id,
            );
          case NovelWorkspaceSection.characters:
            availableItemIds = charactersAsync.asData?.value.map(
              (entry) => entry.id,
            );
          case NovelWorkspaceSection.skills:
            availableItemIds = skillsAsync.asData?.value.map(
              (entry) => entry.id,
            );
          case NovelWorkspaceSection.items:
            availableItemIds = itemsAsync.asData?.value.map(
              (entry) => entry.id,
            );
          case NovelWorkspaceSection.factions:
            availableItemIds = factionsAsync.asData?.value.map(
              (entry) => entry.id,
            );
          case NovelWorkspaceSection.creatures:
            availableItemIds = creaturesAsync.asData?.value.map(
              (entry) => entry.id,
            );
          case NovelWorkspaceSection.foreshadowings:
            availableItemIds = foreshadowingsAsync.asData?.value.map(
              (entry) => entry.id,
            );
          case NovelWorkspaceSection.maps:
            // Map 是地点的派生数据；导航使用地图所属地点的 id（顶层 world 或它的
            // 子地点），避免首次生成前后 selection 从地点 id 切换成 map id。
            final locations =
                locationsAsync.asData?.value ?? const <Location>[];
            final byId = {
              for (final location in locations) location.id: location,
            };
            bool underWorld(Location location) {
              final visited = <String>{};
              Location? current = location;
              while (current != null && visited.add(current.id)) {
                if (current.parentId == null) {
                  return current.type == locationTypeWorld;
                }
                current = byId[current.parentId];
              }
              return false;
            }

            availableItemIds = [
              for (final location in locations)
                if (underWorld(location)) location.id,
            ];
          case NovelWorkspaceSection.overview:
          case NovelWorkspaceSection.novel_description:
          case NovelWorkspaceSection.entity_graph:
          case NovelWorkspaceSection.story_progress:
          case NovelWorkspaceSection.canvas:
          case NovelWorkspaceSection.screenplay_script:
          case NovelWorkspaceSection.screenplay_outline:
          case NovelWorkspaceSection.storyboard:
          case NovelWorkspaceSection.screenplay_scenes:
            return null;
        }
        if (availableItemIds == null) {
          return null;
        }
        final repaired = reconcileWorkspaceSelection(
          selection: current,
          availableItemIds: availableItemIds,
          selectFirstWhenMissing:
              current.section == NovelWorkspaceSection.chapters ||
              current.section == NovelWorkspaceSection.maps,
        );
        if (repaired == current) {
          return null;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted && selection.value == current) {
            selection.value = repaired;
          }
        });
        return null;
      },
      [
        isWorkspaceStateHydrated,
        selection.value,
        chaptersAsync.asData?.value,
        chapterSortDescending,
        worldbuildingAsync.asData?.value,
        outlinesAsync.asData?.value,
        materialsAsync.asData?.value,
        charactersAsync.asData?.value,
        skillsAsync.asData?.value,
        itemsAsync.asData?.value,
        factionsAsync.asData?.value,
        creaturesAsync.asData?.value,
        foreshadowingsAsync.asData?.value,
        mapsAsync.asData?.value,
        locationsAsync.asData?.value,
      ],
    );
    final workingOverlayService = databasePath == null
        ? null
        : ref.watch(workingOverlayServiceProvider(databasePath));
    final activeAiSessionId = useState<String?>(null);
    final isCreatingAiChatSession = useRef(false);
    final nameAssistantAiService = ref
        .watch(aiServiceAsyncProvider(activeAiSessionId.value))
        .asData
        ?.value;

    void syncControllerText(
      TextEditingController controller,
      String nextText, {
      required FocusNode focusNode,
      bool force = false,
      bool acceptWhileFocused = false,
    }) {
      // 自动保存提交后 provider 会回流最新数据。若此时直接写入正在聚焦的
      // TextEditingController，会清掉 selection/composing region，打断中文输入法
      // 的组词状态；因此默认只有切换目标或输入框未聚焦时才同步外部文本。
      //
      // [acceptWhileFocused] 用于外部权威写入（如 AI 通过 working overlay 直接改写
      // 正文列）：即使输入框聚焦也回灌，但仍避开正在进行的 IME 组词，避免误触发上屏。
      if (controller.text == nextText) {
        return;
      }
      if (!force && focusNode.hasFocus) {
        if (!acceptWhileFocused || controller.value.isComposingRangeValid) {
          return;
        }
      }

      final selectionOffset = force
          ? nextText.length
          : controller.selection.baseOffset.clamp(0, nextText.length).toInt();
      isSyncingControllerText.value = true;
      try {
        controller.value = TextEditingValue(
          text: nextText,
          selection: TextSelection.collapsed(offset: selectionOffset),
        );
      } finally {
        isSyncingControllerText.value = false;
      }
    }

    Future<void> onPublishChapter(String chapterId, bool useChronicler) async {
      final path = databasePath;
      if (path == null) return;

      await ref
          .read(novelContentServiceProvider(path))
          .updateChapterStat(chapterId: chapterId, stat: chapterStatPublished);

      if (!useChronicler) return;

      try {
        final db = ref.read(novelContentDatabaseProvider(path));
        final chapter = await db.chapterDao.getById(chapterId);
        if (chapter == null || chapter.content.trim().isEmpty) return;

        if (!context.mounted) return;
        final chapterTitle = chapter.title?.isNotEmpty == true
            ? chapter.title!
            : chapter.isExtra
            ? context.t(LocaleKeys.workspaceExtra)
            : 'Chapter ${chapter.chapterNum ?? "?"}';
        final actionLabel = context.t(LocaleKeys.chapterRunChronicler);
        final chroniclerPrompt = context.t(
          LocaleKeys.chapterPublishChroniclerPrompt,
        );
        final draftSignal =
            '__handoff_draft__chapter_${chapterId}_${DateTime.now().microsecondsSinceEpoch}_$builtinAgentSlugOrchestrator';
        aiPanelCollapsed.value = false;
        activeAiSessionId.value = draftSignal;
        pendingHandoffDraft.value = AiChatHandoffDraft(
          id: draftSignal,
          label: actionLabel,
          content: chroniclerPrompt,
          title: '$chapterTitle · $actionLabel',
          references: [
            AiContextReference(
              section: NovelWorkspaceSection.chapters,
              itemId: chapterId,
              label: chapterTitle,
            ),
          ],
          initialText: chroniclerPrompt,
          autoSend: true,
        );
      } catch (e, stack) {
        _log.error('chronicler error: $e', error: e, stackTrace: stack);
      }
    }

    final aiSessionListLimit = useState(40);
    final isLoadingMoreAiChatSessions = useState(false);
    final lastAiChatSessionsPage =
        useRef<
          ({
            String novelId,
            String? databasePath,
            List<AiChatSession> sessions,
            bool hasMore,
          })?
        >(null);
    // AI 会话列表也延后订阅；首屏不需要它，避免阻塞导航转场。
    final aiChatSessionsPageAsync = !secondaryReady
        ? const AsyncValue<
            ({List<AiChatSession> sessions, bool hasMore})
          >.loading()
        : ref.watch(
            aiChatSessionsPageProvider(
              novelId: novelId,
              databasePath: databasePath,
              limit: aiSessionListLimit.value,
            ),
          );
    final currentAiChatSessionsPage = aiChatSessionsPageAsync.asData?.value;
    if (currentAiChatSessionsPage != null) {
      lastAiChatSessionsPage.value = (
        novelId: novelId,
        databasePath: databasePath,
        sessions: currentAiChatSessionsPage.sessions,
        hasMore: currentAiChatSessionsPage.hasMore,
      );
    }
    final cachedAiChatSessionsPage = lastAiChatSessionsPage.value;
    final retainedAiChatSessionsPage =
        cachedAiChatSessionsPage?.novelId == novelId &&
            cachedAiChatSessionsPage?.databasePath == databasePath
        ? cachedAiChatSessionsPage
        : null;
    final aiChatSessions =
        currentAiChatSessionsPage?.sessions ??
        retainedAiChatSessionsPage?.sessions ??
        const <AiChatSession>[];
    final hasMoreAiChatSessions =
        currentAiChatSessionsPage?.hasMore ??
        retainedAiChatSessionsPage?.hasMore ??
        false;
    // 当前 novel 在 `novel_states` 表中持久化的 active chat session id，
    // 用于在用户未显式选择会话时还原上次活跃会话。
    useEffect(() {
      aiSessionListLimit.value = 40;
      isLoadingMoreAiChatSessions.value = false;
      if (initialSessionId != null) {
        activeAiSessionId.value = initialSessionId;
      } else {
        activeAiSessionId.value = null;
      }
      return null;
    }, [novelId, databasePath]);
    final persistedActiveChatSession = !secondaryReady
        ? const AsyncValue<String?>.loading()
        : ref.watch(
            activeChatSessionIdProvider(
              novelId: novelId,
              databasePath: databasePath,
            ),
          );
    final chatPanelSessionId = useResolvedChatSession(
      novelId: novelId,
      databasePath: databasePath,
      ready: secondaryReady,
      selectedId: activeAiSessionId.value,
      persisted: persistedActiveChatSession,
    );
    Widget buildChatLoading() => Center(
      child: persistedActiveChatSession.hasError
          ? TextButton(
              onPressed: () => ref.invalidate(
                activeChatSessionIdProvider(
                  novelId: novelId,
                  databasePath: databasePath,
                ),
              ),
              child: Text(context.t(LocaleKeys.commonRetry)),
            )
          : const CircularProgressIndicator(),
    );

    Future<bool> commitPendingAiChangesBeforeNewChat() async {
      final sessionId = chatPanelSessionId ?? activeAiSessionId.value;
      final overlay = workingOverlayService;
      if (overlay == null ||
          sessionId == null ||
          sessionId.isEmpty ||
          isTemporaryAiChatSessionId(sessionId)) {
        return true;
      }
      try {
        await overlay.commitActiveAiChangesForSession(
          sessionId,
          message: 'history.commit_message.auto_commit_ai_changes',
        );
        return true;
      } catch (error, stackTrace) {
        _log.error(
          'prepare new chat session failed sessionId=$sessionId',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.aiRequestFailed))),
          );
        }
        return false;
      }
    }

    Future<bool> createNewAiChatSession() async {
      if (isCreatingAiChatSession.value) {
        return false;
      }
      isCreatingAiChatSession.value = true;
      try {
        if (!await commitPendingAiChangesBeforeNewChat() || !context.mounted) {
          return false;
        }
        final newSignal = '__new__${DateTime.now().microsecondsSinceEpoch}';
        activeAiSessionId.value = newSignal;
        return true;
      } finally {
        isCreatingAiChatSession.value = false;
      }
    }

    useEffect(() {
      if (aiChatSessionsPageAsync.hasValue ||
          aiChatSessionsPageAsync.hasError) {
        isLoadingMoreAiChatSessions.value = false;
      }
      return null;
    }, [aiChatSessionsPageAsync]);

    void loadMoreAiChatSessions() {
      if (isLoadingMoreAiChatSessions.value || !hasMoreAiChatSessions) {
        return;
      }
      isLoadingMoreAiChatSessions.value = true;
      aiSessionListLimit.value += 40;
    }

    Future<void> showPendingChangesDialog() async {
      final dbPath = databasePath;
      final activeChanges = dbPath == null
          ? const <WorkingChange>[]
          : (ref.read(workingChangesProvider(dbPath)).asData?.value ??
                    const <WorkingChange>[])
                .where(
                  (change) =>
                      change.status == workingChangeStatusActive &&
                      change.source == workingChangeSourceAi,
                )
                .toList();
      if (activeChanges.isEmpty) {
        return;
      }
      final path = databasePath;
      if (path == null) {
        return;
      }
      await PendingChangesDetailDialog.showFromChanges(
        context,
        databasePath: path,
        changes: activeChanges,
      );
    }

    String historyResourceLabel() {
      String lookupItemTitle(
        List<Document>? items,
        String itemId,
        String fallback,
      ) {
        if (items == null) {
          return fallback;
        }
        for (final entry in items) {
          if (entry.id == itemId) {
            return entry.title;
          }
        }
        return fallback;
      }

      String lookupOutlineTitle(
        List<OutlineDraft>? items,
        String itemId,
        String fallback,
      ) {
        if (items == null) {
          return fallback;
        }
        for (final entry in items) {
          if (entry.documentId == itemId) {
            return entry.title;
          }
        }
        return fallback;
      }

      String lookupSkillItemTitle(
        List<Item>? items,
        String itemId,
        String fallback,
      ) {
        if (items == null) {
          return fallback;
        }
        for (final entry in items) {
          if (entry.id == itemId) {
            return entry.title;
          }
        }
        return fallback;
      }

      final itemId = selection.value.itemId;
      if (itemId == null) {
        return context.t(sectionLocaleKey(selection.value.section));
      }
      switch (selection.value.section) {
        case NovelWorkspaceSection.chapters:
          Chapter? chapter;
          for (final entry
              in chaptersAsync.asData?.value ?? const <Chapter>[]) {
            if (entry.id == itemId) {
              chapter = entry;
              break;
            }
          }
          return chapter?.title?.trim().isNotEmpty == true
              ? chapter!.title!.trim()
              : context.t(LocaleKeys.workspaceChapters);
        case NovelWorkspaceSection.lore:
          return lookupItemTitle(
            worldbuildingAsync.asData?.value,
            itemId,
            context.t(LocaleKeys.workspaceLore),
          );
        case NovelWorkspaceSection.outlines:
          return lookupOutlineTitle(
            outlinesAsync.asData?.value,
            itemId,
            context.t(LocaleKeys.workspaceOutlines),
          );
        case NovelWorkspaceSection.materials:
          return lookupItemTitle(
            materialsAsync.asData?.value,
            itemId,
            context.t(LocaleKeys.workspaceMaterials),
          );
        case NovelWorkspaceSection.characters:
          for (final entry
              in charactersAsync.asData?.value ?? const <CharacterProfile>[]) {
            if (entry.id == itemId) {
              return entry.name;
            }
          }
          return context.t(LocaleKeys.workspaceCharacters);
        case NovelWorkspaceSection.skills:
          return lookupSkillItemTitle(
            skillsAsync.asData?.value,
            itemId,
            context.t(LocaleKeys.workspaceSkills),
          );
        case NovelWorkspaceSection.items:
          return lookupSkillItemTitle(
            itemsAsync.asData?.value,
            itemId,
            context.t(LocaleKeys.workspaceItems),
          );
        case NovelWorkspaceSection.factions:
          return lookupSkillItemTitle(
            factionsAsync.asData?.value,
            itemId,
            context.t(LocaleKeys.workspaceFactions),
          );
        case NovelWorkspaceSection.creatures:
          return lookupSkillItemTitle(
            creaturesAsync.asData?.value,
            itemId,
            context.t(LocaleKeys.workspaceCreatures),
          );
        case NovelWorkspaceSection.foreshadowings:
          for (final entry
              in foreshadowingsAsync.asData?.value ?? const <Foreshadowing>[]) {
            if (entry.id == itemId) {
              return entry.title;
            }
          }
          return context.t(LocaleKeys.workspaceForeshadowings);
        case NovelWorkspaceSection.overview:
        case NovelWorkspaceSection.maps:
        case NovelWorkspaceSection.novel_description:
        case NovelWorkspaceSection.entity_graph:
        case NovelWorkspaceSection.story_progress:
        case NovelWorkspaceSection.canvas:
        case NovelWorkspaceSection.screenplay_script:
        case NovelWorkspaceSection.screenplay_outline:
        case NovelWorkspaceSection.storyboard:
        case NovelWorkspaceSection.screenplay_scenes:
          return context.t(sectionLocaleKey(selection.value.section));
      }
    }

    Future<void> showHistoryDialog() async {
      final path = databasePath;
      if (path == null) {
        return;
      }
      final selectedResourceId = selection.value.itemId;
      if (selectedResourceId != null &&
          !selection.value.section.isReadOnly &&
          selection.value.section != NovelWorkspaceSection.novel_description) {
        await showResourceHistoryDialog(
          context,
          databasePath: path,
          resourceId: selectedResourceId,
          resourceLabel: historyResourceLabel(),
        );
        return;
      }
      await showRevericDialog<void>(
        context: context,
        builder: (dialogContext) {
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(RevericSpacing.x3l),
            child: SizedBox(
              width: 1080,
              height: 720,
              child: DialogFeedback(
                builder: (context) => ChangeHistoryPanel(
                  databasePath: path,
                  onClose: () => Navigator.of(dialogContext).pop(),
                ),
              ),
            ),
          );
        },
      );
    }

    Future<bool> saveNovelDetails(
      Novel novel, {
      required BuildContext feedbackContext,
      required String title,
      required String authorName,
      required String description,
      required String category,
      required String type,
      required String? sourceNovelId,
      required String? coverSourcePath,
      required bool removeCover,
      required List<String> tags,
    }) async {
      try {
        await ref
            .read(novelActionsProvider)
            .updateNovel(
              novel: novel,
              title: title,
              authorName: authorName,
              description: description,
              category: category,
              type: type,
              updateSourceNovel: true,
              sourceNovelId: sourceNovelId,
              coverSourcePath: coverSourcePath,
              removeCover: removeCover,
              tags: tags,
            );
        return true;
      } on NovelTitleConflictException catch (error) {
        if (!feedbackContext.mounted) {
          return false;
        }
        ScaffoldMessenger.of(feedbackContext).showSnackBar(
          SnackBar(
            content: Text(
              context.t(
                LocaleKeys.libraryDuplicateName,
                namedArgs: {'name': error.title},
              ),
            ),
          ),
        );
        return false;
      } catch (_) {
        if (!feedbackContext.mounted) {
          return false;
        }
        ScaffoldMessenger.of(feedbackContext).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.editorSaveNovelFailed))),
        );
        return false;
      }
    }

    void openEditNovelDialog(Novel novel) {
      showRevericDialog<void>(
        context: context,
        builder: (_) => DialogFeedback.scope(
          builder: (dialogContext) => NovelFormDialog.edit(
            novel: novel,
            onSubmit:
                ({
                  required title,
                  required authorName,
                  required description,
                  required category,
                  required type,
                  required contentKind,
                  required plannedEpisodeCount,
                  required sourceNovelId,
                  required coverSourcePath,
                  required removeCover,
                  required tags,
                }) => saveNovelDetails(
                  novel,
                  feedbackContext: dialogContext,
                  title: title,
                  authorName: authorName,
                  description: description,
                  category: category,
                  type: type,
                  sourceNovelId: sourceNovelId,
                  coverSourcePath: coverSourcePath,
                  removeCover: removeCover,
                  tags: tags,
                ),
          ),
        ),
      );
    }

    void triggerFeatureOnboarding(FeatureOnboardingType type) {
      unawaited(triggerFeatureOnboardingIfNeeded(context, ref, type));
    }

    void triggerWorkspaceOnboarding(WorkspaceSelection nextSelection) {
      if (nextSelection.section == NovelWorkspaceSection.outlines) {
        triggerFeatureOnboarding(FeatureOnboardingType.outline_craft);
      }
    }

    Future<String?> createChapter(Novel novel) async {
      final path = databasePath;
      if (path == null) {
        return null;
      }
      final service = ref.read(novelContentServiceProvider(path));
      final nextOrder = await service.getNextSiblingOrderAtRoot();
      return service.createChapter(siblingOrder: nextOrder, title: '');
    }

    Future<String?> createChapterInVolume(Novel novel, String volumeId) async {
      final path = databasePath;
      if (path == null) {
        return null;
      }
      final service = ref.read(novelContentServiceProvider(path));
      final nextOrder = await service.getNextSiblingOrderInVolume(volumeId);
      return service.createChapter(
        siblingOrder: nextOrder,
        parentId: volumeId,
        title: '',
      );
    }

    Future<String?> createVolume(Novel novel) async {
      final path = databasePath;
      if (path == null) {
        return null;
      }
      final colors = RevericTheme.colorsOf(context);
      final typo = RevericTheme.typographyOf(context);
      final controller = TextEditingController();

      final title = await showRevericDialog<String>(
        context: context,
        builder: (dialogContext) {
          return RevericDialog(
            title: context.t(LocaleKeys.workspaceNewVolume),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: context.t(LocaleKeys.workspaceNewVolumeHint),
                hintStyle: typo.ui.copyWith(color: colors.textMuted),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                  borderSide: BorderSide(color: colors.accent),
                ),
              ),
              style: typo.ui.copyWith(color: colors.textPrimary),
            ),
            actions: [
              RevericButton.secondary(
                label: context.t(LocaleKeys.commonCancel),
                onPressed: () => Navigator.of(dialogContext).pop(null),
              ),
              RevericButton.primary(
                label: context.t(LocaleKeys.commonCreate),
                onPressed: () {
                  Navigator.of(dialogContext).pop(controller.text.trim());
                },
              ),
            ],
          );
        },
      );

      if (title == null || title.isEmpty) {
        return null;
      }

      final service = ref.read(novelContentServiceProvider(path));
      return service.createVolume(title: title);
    }

    void showSaveSuccess() {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t(LocaleKeys.commonSaved))),
      );
    }

    Future<bool> saveChapterSnapshot({required bool skipEmptyContent}) async {
      final path = databasePath;
      final chapterId = selection.value.itemId;
      final overlay = workingOverlayService;
      if (path == null || chapterId == null || overlay == null) {
        return false;
      }
      // Autosave / Save 也可能发生在独立窗口 debounce 完成前。
      chapterOutlineWindowSession.flushDetachedOutlineSync();
      final selectedChapter = selectedChapterAsync.asData?.value;
      if (selectedChapter == null || selectedChapter.id != chapterId) {
        return false;
      }
      final title = chapterTitleController.text.trim();
      final outline = chapterOutlineController.text;
      final content = chapterContentController.text;
      if (skipEmptyContent && content.trim().isEmpty) {
        return false;
      }

      // 在 await 写库之前登记本地快照。Drift 的 watch stream 可能先于保存 Future
      // 完成而回流；同步 effect 可据此识别本地回声，避免重写正在输入的 controller。
      final saveToken = Object();
      pendingLocalChapterId.value = chapterId;
      pendingLocalChapterContent.value = content;
      pendingLocalChapterSaveToken.value = saveToken;
      try {
        await commitChapterManualSave(
          overlay,
          ref.read(novelContentServiceProvider(path)),
          chapterId: chapterId,
          newTitle: title,
          newOutline: outline,
          newContent: content,
        );
        // 即使 stream 晚于 Future 回流，也能通过同步基线识别为本地保存回声。
        lastSyncedChapterContent.value = content;
        return true;
      } finally {
        if (identical(pendingLocalChapterSaveToken.value, saveToken)) {
          pendingLocalChapterId.value = null;
          pendingLocalChapterContent.value = null;
          pendingLocalChapterSaveToken.value = null;
        }
      }
    }

    Future<void> saveChapter({
      bool skipEmptyContent = false,
      bool showSuccess = false,
    }) {
      // 高频自动保存合并为单飞队列：写入期间的新请求只保留一次，并在当前写入
      // 完成后读取最新 controller 快照，避免直接丢弃用户继续输入的内容。
      chapterSaveRequested.value = true;
      chapterSaveAllowEmpty.value =
          chapterSaveAllowEmpty.value || !skipEmptyContent;
      chapterSaveShowSuccess.value =
          chapterSaveShowSuccess.value || showSuccess;

      final activeSave = chapterSaveInFlight.value;
      if (activeSave != null) {
        return activeSave;
      }

      Future<void> runSaveQueue() async {
        try {
          while (chapterSaveRequested.value) {
            chapterSaveRequested.value = false;
            final allowEmpty = chapterSaveAllowEmpty.value;
            final shouldShowSuccess = chapterSaveShowSuccess.value;
            chapterSaveAllowEmpty.value = false;
            chapterSaveShowSuccess.value = false;

            final saved = await saveChapterSnapshot(
              skipEmptyContent: !allowEmpty,
            );
            if (saved && shouldShowSuccess) {
              showSaveSuccess();
            }
          }
        } finally {
          chapterSaveInFlight.value = null;
        }
      }

      final operation = runSaveQueue();
      chapterSaveInFlight.value = operation;
      return operation;
    }

    Future<void> saveNovelDescription({bool showSuccess = false}) async {
      final currentNovel = novelAsync.asData?.value;
      final overlay = workingOverlayService;
      if (currentNovel == null || overlay == null || isSavingEntry.value) {
        return;
      }
      final description = novelDescriptionController.text.trim();
      if (description == currentNovel.description) {
        return;
      }

      isSavingEntry.value = true;
      try {
        final change = await overlay.stageTextChange(
          resourcePath: '/profile/description',
          resourceType: 'novel',
          resourceId: currentNovel.id,
          field: 'description',
          oldText: currentNovel.description,
          newText: description,
          source: workingChangeSourceManual,
          summary: 'Update novel description',
        );
        await overlay.commitManualSave(
          manualChangeIds: [change.id],
          resourceScopes: const ['/profile/description'],
          manualMessage: 'history.commit_message.manual_novel_description_save',
        );
        if (showSuccess) {
          showSaveSuccess();
        }
      } finally {
        isSavingEntry.value = false;
      }
    }

    void initControllersForNewEntry(NovelWorkspaceSection section) {
      isSyncingControllerText.value = true;
      try {
        switch (section) {
          case NovelWorkspaceSection.characters:
            break;
          case NovelWorkspaceSection.foreshadowings:
            entryTitleController.text = '';
            foreshadowSetupController.text = '';
            foreshadowPayoffController.text = '';
            selectedStatus.value = foreshadowingStatusPlanted;
            foreshadowPositions.value = emptyForeshadowingPositionIds;
          case NovelWorkspaceSection.lore:
          case NovelWorkspaceSection.materials:
            entryTitleController.text = '';
            entryContentController.text = '';
            entryCategoryController.text = '';
          case NovelWorkspaceSection.skills:
          case NovelWorkspaceSection.items:
          case NovelWorkspaceSection.factions:
          case NovelWorkspaceSection.creatures:
            entryTitleController.text = '';
            entryContentController.text = '';
            entryCategoryController.text = '';
          default:
            break;
        }
      } finally {
        isSyncingControllerText.value = false;
      }
    }

    Future<void> createEntry(
      Novel novel, [
      NovelWorkspaceSection? targetSectionOverride,
    ]) async {
      final path = databasePath;
      final targetSection = targetSectionOverride ?? selection.value.section;
      if (path == null || targetSection.isReadOnly) {
        return;
      }

      final untitledName = context.t(LocaleKeys.commonUntitled);
      final service = ref.read(novelContentServiceProvider(path));
      String? parentId;
      if (selection.value.itemId != null && targetSectionOverride == null) {
        final currentDoc = await service.documentsService.getDocumentById(
          selection.value.itemId!,
        );
        if (currentDoc != null && currentDoc.isFolder) {
          parentId = currentDoc.id;
        }
      }

      // 延迟创建：不插 DB，进入新建模式
      switch (targetSection) {
        case NovelWorkspaceSection.characters:
        case NovelWorkspaceSection.foreshadowings:
        case NovelWorkspaceSection.skills:
        case NovelWorkspaceSection.items:
        case NovelWorkspaceSection.factions:
        case NovelWorkspaceSection.creatures:
        case NovelWorkspaceSection.lore:
        case NovelWorkspaceSection.materials:
          initControllersForNewEntry(targetSection);
          createDraft.value = _WorkspaceCreateDraft(
            section: targetSection,
            previousSelection: selection.value,
            parentId:
                targetSection == NovelWorkspaceSection.lore ||
                    targetSection == NovelWorkspaceSection.materials
                ? parentId
                : null,
          );
          createDraftFieldError.value = null;
          entryTitleFieldError.value = null;
          selection.value = WorkspaceSelection.creating(section: targetSection);
          triggerWorkspaceOnboarding(selection.value);
          return;
        default:
          break;
      }

      // 非延迟创建的实体保持原有逻辑
      String? createdId;
      NovelWorkspaceSection? createdSection;

      switch (targetSection) {
        case NovelWorkspaceSection.novel_description:
        case NovelWorkspaceSection.maps:
          // 地图工作台负责创建 world，并在生成或导入时延迟创建 Map。
          return;
        case NovelWorkspaceSection.outlines:
          createdId = await service.outlineService.createOutline(
            defaultTitle: untitledName,
          );
          createdSection = NovelWorkspaceSection.outlines;
        case NovelWorkspaceSection.chapters:
          createdId = await createChapter(novel);
          createdSection = NovelWorkspaceSection.chapters;
        default:
          return;
      }
      selection.value = WorkspaceSelection(
        section: createdSection,
        itemId: createdId,
      );
      triggerWorkspaceOnboarding(selection.value);
    }

    Future<void> createFolder(
      Novel novel, [
      NovelWorkspaceSection? targetSectionOverride,
    ]) async {
      final path = databasePath;
      final targetSection = targetSectionOverride ?? selection.value.section;
      if (path == null || targetSection.isReadOnly) {
        return;
      }

      final colors = RevericTheme.colorsOf(context);
      final typo = RevericTheme.typographyOf(context);
      final controller = TextEditingController();

      final folderName = await showRevericDialog<String>(
        context: context,
        builder: (dialogContext) {
          return RevericDialog(
            title: context.t(LocaleKeys.workspaceNewFolder),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: context.t(LocaleKeys.workspaceNewFolderHint),
                hintStyle: typo.ui.copyWith(color: colors.textMuted),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                  borderSide: BorderSide(color: colors.accent),
                ),
              ),
              style: typo.ui.copyWith(color: colors.textPrimary),
            ),
            actions: [
              RevericButton.secondary(
                label: context.t(LocaleKeys.commonCancel),
                onPressed: () => Navigator.of(dialogContext).pop(null),
              ),
              RevericButton.primary(
                label: context.t(LocaleKeys.commonCreate),
                onPressed: () {
                  final name = controller.text.trim();
                  Navigator.of(
                    dialogContext,
                  ).pop(name.isNotEmpty ? name : null);
                },
              ),
            ],
          );
        },
      );

      if (folderName == null) {
        return;
      }

      final service = ref.read(novelContentServiceProvider(path));
      String? createdId;
      NovelWorkspaceSection? createdSection;

      String? parentId;
      if (selection.value.itemId != null && targetSectionOverride == null) {
        final currentDoc = await service.documentsService.getDocumentById(
          selection.value.itemId!,
        );
        if (currentDoc != null && currentDoc.isFolder) {
          parentId = currentDoc.id;
        }
      }

      switch (targetSection) {
        case NovelWorkspaceSection.novel_description:
          return;
        case NovelWorkspaceSection.lore:
          createdId = await service.documentsService.createFolder(
            type: documentTypeLore,
            parentId: parentId,
            title: folderName,
          );
          createdSection = NovelWorkspaceSection.lore;
        case NovelWorkspaceSection.outlines:
          return;
        case NovelWorkspaceSection.materials:
          createdId = await service.documentsService.createFolder(
            type: documentTypeMaterial,
            parentId: parentId,
            title: folderName,
          );
          createdSection = NovelWorkspaceSection.materials;
        default:
          return;
      }
      selection.value = WorkspaceSelection(
        section: createdSection,
        itemId: createdId,
      );
    }

    Future<_DocumentImportSource?> pickDocumentImportSource() {
      return showModalBottomSheet<_DocumentImportSource>(
        context: context,
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(RevericRadius.x2l),
          ),
        ),
        builder: (sheetContext) {
          final sheetColors = RevericTheme.colorsOf(sheetContext);
          final typo = RevericTheme.typographyOf(sheetContext);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: RevericSpacing.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.x2l,
                      RevericSpacing.md,
                      RevericSpacing.x2l,
                      RevericSpacing.sm,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        context.t(LocaleKeys.workspaceImportFile),
                        style: typo.uiSemibold.copyWith(
                          color: sheetColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: RevericIcon(
                      RevericIcons.description_outlined,
                      size: 20,
                      color: sheetColors.accent,
                    ),
                    title: Text(
                      context.t(LocaleKeys.workspaceChooseFile),
                      style: typo.ui.copyWith(color: sheetColors.textPrimary),
                    ),
                    onTap: () {
                      Navigator.of(
                        sheetContext,
                      ).pop(_DocumentImportSource.file);
                    },
                  ),
                  ListTile(
                    leading: RevericIcon(
                      RevericIcons.folder_outlined,
                      size: 20,
                      color: sheetColors.accent,
                    ),
                    title: Text(
                      context.t(LocaleKeys.workspaceChooseDirectory),
                      style: typo.ui.copyWith(color: sheetColors.textPrimary),
                    ),
                    onTap: () {
                      Navigator.of(
                        sheetContext,
                      ).pop(_DocumentImportSource.directory);
                    },
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    Future<void> importEntry(String sectionName, String? parentId) async {
      final path = databasePath;
      if (path == null) return;

      final type = switch (sectionName) {
        'worldbuilding' => documentTypeLore,
        'material' => documentTypeMaterial,
        _ => sectionName,
      };
      if (type != documentTypeLore && type != documentTypeMaterial) {
        return;
      }

      final source = await pickDocumentImportSource();
      if (!context.mounted || source == null) return;

      final List<String> filePaths;
      final String? directoryPath;
      switch (source) {
        case _DocumentImportSource.file:
          final files = await openFiles(
            acceptedTypeGroups: const [
              XTypeGroup(label: 'text', extensions: ['txt', 'md', 'csv']),
            ],
          );
          filePaths = files.map((file) => file.path).toList(growable: false);
          directoryPath = null;
        case _DocumentImportSource.directory:
          filePaths = const [];
          directoryPath = await getDirectoryPath();
      }
      if (!context.mounted) return;
      if (filePaths.isEmpty && directoryPath == null) return;

      showRevericDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      try {
        final service = ref.read(novelContentServiceProvider(path));
        final importResult = switch (source) {
          _DocumentImportSource.file =>
            await service.documentsService.importFiles(
              type: type,
              filePaths: filePaths,
              parentId: parentId,
            ),
          _DocumentImportSource.directory => await (() async {
            final importDirectoryPath = directoryPath!;
            final dirName = _pathBaseName(importDirectoryPath);
            if (dirName.isEmpty) {
              return (imported: 0, skipped: 0);
            }
            final existing = await service.documentsService.getDocumentByTitle(
              type: type,
              title: dirName,
              parentId: parentId,
            );
            final rootFolderId = existing != null && existing.isFolder
                ? existing.id
                : await service.documentsService.createFolder(
                    type: type,
                    parentId: parentId,
                    title: dirName,
                  );
            return service.documentsService.importDirectory(
              type: type,
              directoryPath: importDirectoryPath,
              parentId: rootFolderId,
            );
          })(),
        };

        if (!context.mounted) return;
        ref.invalidate(documentsProvider(path: path, type: type));

        final message = importResult.skipped > 0
            ? context.t(
                LocaleKeys.workspaceImportResultWithSkipped,
                namedArgs: {
                  'count': '${importResult.imported}',
                  'skipped': '${importResult.skipped}',
                },
              )
            : context.t(
                LocaleKeys.workspaceImportResult,
                namedArgs: {'count': '${importResult.imported}'},
              );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      } finally {
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      }
    }

    Future<void> importOutline() async {
      final path = databasePath;
      if (path == null) {
        return;
      }

      final files = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'text', extensions: ['txt', 'md', 'csv']),
        ],
      );
      if (!context.mounted || files.isEmpty) {
        return;
      }

      showRevericDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      try {
        final service = ref.read(novelContentServiceProvider(path));
        // 多文件导入完成后打开第一个大纲，其余按顺序保留在列表中。
        final fallbackTitle = context.t(LocaleKeys.workspaceNewOutline);
        String? firstOutlineId;
        for (final file in files) {
          final title = _textFileTitle(file.name);
          final outlineTitle = title.isEmpty ? fallbackTitle : title;
          final content = decodeImportedTextBytes(await file.readAsBytes());
          final outlineId = await service.outlineService.importOutline(
            title: outlineTitle,
            content: content,
          );
          firstOutlineId ??= outlineId;
        }
        if (!context.mounted || firstOutlineId == null) {
          return;
        }
        ref.invalidate(outlinesProvider(path));
        if (contentSelection.value is _EditorAiChatExpandedSelection) {
          aiPanelCollapsed.value = false;
        }
        contentSelection.value = const _EditorWorkspaceContentSelection();
        selection.value = WorkspaceSelection(
          section: NovelWorkspaceSection.outlines,
          itemId: firstOutlineId,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.t(
                LocaleKeys.workspaceImportResult,
                namedArgs: {'count': '${files.length}'},
              ),
            ),
          ),
        );
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.workspaceImportFailed)),
            ),
          );
        }
      } finally {
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      }
    }

    String requiredFieldError() {
      return context.t(LocaleKeys.formRequired);
    }

    Future<String?> duplicateTitleFieldError({
      required NovelContentService service,
      required NovelWorkspaceSection section,
      required String title,
      String? parentId,
      String? excludeId,
    }) async {
      return _duplicateTitleFieldError(
        context: context,
        service: service,
        section: section,
        title: title,
        parentId: parentId,
        excludeId: excludeId,
        skillEntries: skillsAsync.asData?.value ?? const <Item>[],
        items: itemsAsync.asData?.value ?? const <Item>[],
        factionEntries: factionsAsync.asData?.value ?? const <Item>[],
        creatureEntries: creaturesAsync.asData?.value ?? const <Item>[],
        foreshadowings:
            foreshadowingsAsync.asData?.value ?? const <Foreshadowing>[],
      );
    }

    Future<bool> saveNewEntry(NovelContentService service) async {
      final section = selection.value.section;
      late final String newId;
      switch (section) {
        case NovelWorkspaceSection.characters:
          final savedId = await characterEditorController.save();
          if (savedId == null) {
            return false;
          }
          newId = savedId;
        case NovelWorkspaceSection.foreshadowings:
          final title = entryTitleController.text.trim();
          if (title.isEmpty) {
            createDraftFieldError.value = requiredFieldError();
            foreshadowTitleFocusNode.requestFocus();
            return false;
          }
          final duplicateError = await duplicateTitleFieldError(
            service: service,
            section: section,
            title: title,
          );
          if (duplicateError != null) {
            createDraftFieldError.value = duplicateError;
            foreshadowTitleFocusNode.requestFocus();
            return false;
          }
          final positions = foreshadowPositions.value;
          newId = await service.createForeshadowing(
            title: title,
            setup: foreshadowSetupController.text,
            payoff: foreshadowPayoffController.text,
            status: selectedStatus.value,
            setupChapterId: positions.setupChapterId,
            payoffChapterId: positions.payoffChapterId,
            setupSceneId: positions.setupSceneId,
            payoffSceneId: positions.payoffSceneId,
          );
        case NovelWorkspaceSection.lore:
        case NovelWorkspaceSection.materials:
          final title = entryTitleController.text.trim();
          if (title.isEmpty) {
            createDraftFieldError.value = requiredFieldError();
            entryTitleFocusNode.requestFocus();
            return false;
          }
          final docType = section == NovelWorkspaceSection.lore
              ? documentTypeLore
              : documentTypeMaterial;
          final parentId = createDraft.value?.parentId;
          final duplicateError = await duplicateTitleFieldError(
            service: service,
            section: section,
            title: title,
            parentId: parentId,
          );
          if (duplicateError != null) {
            createDraftFieldError.value = duplicateError;
            entryTitleFocusNode.requestFocus();
            return false;
          }
          newId = await service.documentsService.createDocument(
            type: docType,
            parentId: parentId,
            title: title,
            content: entryContentController.text,
            category: entryCategoryController.text,
          );
        case NovelWorkspaceSection.skills:
        case NovelWorkspaceSection.items:
        case NovelWorkspaceSection.factions:
        case NovelWorkspaceSection.creatures:
          final title = entryTitleController.text.trim();
          if (title.isEmpty) {
            createDraftFieldError.value = requiredFieldError();
            entryTitleFocusNode.requestFocus();
            return false;
          }
          final itemType = switch (section) {
            NovelWorkspaceSection.skills => 'skill',
            NovelWorkspaceSection.items => 'item',
            NovelWorkspaceSection.factions => 'faction',
            NovelWorkspaceSection.creatures => 'creature',
            _ => '',
          };
          final duplicateError = await duplicateTitleFieldError(
            service: service,
            section: section,
            title: title,
          );
          if (duplicateError != null) {
            createDraftFieldError.value = duplicateError;
            entryTitleFocusNode.requestFocus();
            return false;
          }
          newId = await service.createItem(
            type: itemType,
            title: title,
            content: entryContentController.text,
            category: entryCategoryController.text,
          );
          if (itemPhotos.value.isNotEmpty) {
            await service.updateItemPhotos(
              entryId: newId,
              assetIds: itemPhotos.value,
            );
          }
        default:
          return false;
      }
      createDraft.value = null;
      createDraftFieldError.value = null;
      selection.value = WorkspaceSelection(section: section, itemId: newId);
      return true;
    }

    /// 返回是否真正落盘。标题含 AI 路径结构字符时拦截：错误写进
    /// entryTitleFieldError（大纲编辑器标题行下方内联展示），不保存也不报成功。
    /// 自动保存与手动保存都经此处，保证标题问题一定有 UI 反馈。
    Future<bool> queueOutlineDraftSave(OutlineDraft draft) {
      final path = databasePath;
      if (path == null) {
        return Future<bool>.value(false);
      }
      final structuralError = _aiPathStructuralCharFieldError(
        context,
        section: NovelWorkspaceSection.outlines,
        title: draft.title.trim(),
      );
      if (structuralError != null) {
        entryTitleFieldError.value = structuralError;
        return Future<bool>.value(false);
      }
      entryTitleFieldError.value = null;
      final service = ref.read(novelContentServiceProvider(path));
      final previousSave = outlineSaveChain.value.catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _log.error(
          'outlines UPDATE previous save failed: '
          'documentId=${draft.documentId} error=$error',
          error: error,
          stackTrace: stackTrace,
        );
      });
      final nextSave = previousSave.then((_) async {
        try {
          await service.outlineService.saveOutline(draft);
          // The service may canonicalize a duplicate title. Acknowledge this
          // saved snapshot by identity, never by comparing the input text.
          if (context.mounted && identical(pendingOutlineDraft.value, draft)) {
            final stored = await service.outlineService.getByDocumentId(
              draft.documentId,
            );
            if (context.mounted &&
                identical(pendingOutlineDraft.value, draft) &&
                identical(outlineDraft.value, draft)) {
              pendingOutlineDraft.value = null;
              outlineDraft.value = stored;
            }
          }
        } catch (error, stackTrace) {
          _log.error(
            'outlines UPDATE save failed: '
            'documentId=${draft.documentId} error=$error',
            error: error,
            stackTrace: stackTrace,
          );
          rethrow;
        }
      });
      outlineSaveChain.value = nextSave;
      return nextSave.then((_) => true);
    }

    Future<void> saveEntry({bool showSuccess = false}) async {
      final path = databasePath;
      final overlay = workingOverlayService;
      if (path == null ||
          overlay == null ||
          isSavingEntry.value ||
          selection.value.section.isReadOnly) {
        return;
      }

      final service = ref.read(novelContentServiceProvider(path));

      if (selection.value.isCreating) {
        isSavingEntry.value = true;
        try {
          final saved = await saveNewEntry(service);
          if (saved && showSuccess) {
            showSaveSuccess();
          }
        } finally {
          isSavingEntry.value = false;
        }
        return;
      }

      final entryId = selection.value.itemId;
      if (entryId == null) {
        return;
      }
      if (selection.value.section == NovelWorkspaceSection.novel_description) {
        await saveNovelDescription(showSuccess: showSuccess);
        return;
      }
      if (selection.value.section == NovelWorkspaceSection.characters) {
        isSavingEntry.value = true;
        try {
          await characterEditorController.save(showSuccess: showSuccess);
        } finally {
          isSavingEntry.value = false;
        }
        return;
      }

      isSavingEntry.value = true;
      entryTitleFieldError.value = null;
      try {
        switch (selection.value.section) {
          case NovelWorkspaceSection.novel_description:
            return;
          case NovelWorkspaceSection.outlines:
            final draft = outlineDraft.value;
            if (draft == null) {
              return;
            }
            final saved = await queueOutlineDraftSave(draft);
            if (saved && showSuccess) {
              showSaveSuccess();
            }
            return;
          case NovelWorkspaceSection.lore:
          case NovelWorkspaceSection.materials:
            final existing = await service.documentsService.getDocumentById(
              entryId,
            );
            if (existing == null) return;
            final changeIds = <String>[];
            final nextTitle = entryTitleController.text.trim();
            final nextContent = entryContentController.text;
            final nextCategory = entryCategoryController.text;
            final resourcePathBase = switch (selection.value.section) {
              NovelWorkspaceSection.lore => '/lore/$entryId',
              NovelWorkspaceSection.outlines => '/outlines/$entryId',
              NovelWorkspaceSection.materials => '/materials/$entryId',
              _ => '',
            };
            if (existing.title != nextTitle) {
              final duplicateError = await duplicateTitleFieldError(
                service: service,
                section: selection.value.section,
                title: nextTitle,
                parentId: existing.parentId,
                excludeId: entryId,
              );
              if (duplicateError != null) {
                entryTitleFieldError.value = duplicateError;
                entryTitleFocusNode.requestFocus();
                return;
              }
              final change = await overlay.stageTextChange(
                resourcePath: '$resourcePathBase/title',
                resourceType: selection.value.section.aiResourceType,
                resourceId: entryId,
                field: 'title',
                oldText: existing.title,
                newText: nextTitle,
                source: workingChangeSourceManual,
                summary: 'Update entry title',
              );
              changeIds.add(change.id);
            }
            if (existing.content != nextContent) {
              final change = await overlay.stageTextChange(
                resourcePath: '$resourcePathBase/content',
                resourceType: selection.value.section.aiResourceType,
                resourceId: entryId,
                field: 'content',
                oldText: existing.content,
                newText: nextContent,
                source: workingChangeSourceManual,
                summary: 'Update entry content',
              );
              changeIds.add(change.id);
            }
            if (existing.category != nextCategory) {
              final change = await overlay.stageTextChange(
                resourcePath: '$resourcePathBase/category',
                resourceType: selection.value.section.aiResourceType,
                resourceId: entryId,
                field: 'category',
                oldText: existing.category,
                newText: nextCategory,
                source: workingChangeSourceManual,
                summary: 'Update entry category',
              );
              changeIds.add(change.id);
            }
            if (changeIds.isNotEmpty) {
              await overlay.commitManualSave(
                manualChangeIds: changeIds,
                resourceScopes: [resourcePathBase],
                manualMessage: 'history.commit_message.manual_entry_save',
              );
            }
            if (showSuccess) {
              showSaveSuccess();
            }
            return;
          case NovelWorkspaceSection.skills:
          case NovelWorkspaceSection.items:
          case NovelWorkspaceSection.factions:
          case NovelWorkspaceSection.creatures:
            final existing = await service.getItemById(entryId);
            if (existing == null) return;
            final changeIds = <String>[];
            final nextTitle = entryTitleController.text.trim();
            final nextContent = entryContentController.text;
            final nextCategory = entryCategoryController.text;
            final resourcePathBase = switch (selection.value.section) {
              NovelWorkspaceSection.lore => '/lore/$entryId',
              NovelWorkspaceSection.outlines => '/outlines/$entryId',
              NovelWorkspaceSection.materials => '/materials/$entryId',
              NovelWorkspaceSection.skills => '/skills/$entryId',
              NovelWorkspaceSection.items => '/items/$entryId',
              NovelWorkspaceSection.factions => '/factions/$entryId',
              NovelWorkspaceSection.creatures => '/creatures/$entryId',
              _ => '',
            };
            if (existing.title != nextTitle) {
              final duplicateError = await duplicateTitleFieldError(
                service: service,
                section: selection.value.section,
                title: nextTitle,
                excludeId: entryId,
              );
              if (duplicateError != null) {
                entryTitleFieldError.value = duplicateError;
                entryTitleFocusNode.requestFocus();
                return;
              }
              final change = await overlay.stageTextChange(
                resourcePath: '$resourcePathBase/title',
                resourceType: selection.value.section.aiResourceType,
                resourceId: entryId,
                field: 'title',
                oldText: existing.title,
                newText: nextTitle,
                source: workingChangeSourceManual,
                summary: 'Update entry title',
              );
              changeIds.add(change.id);
            }
            if (existing.content != nextContent) {
              final change = await overlay.stageTextChange(
                resourcePath: '$resourcePathBase/content',
                resourceType: selection.value.section.aiResourceType,
                resourceId: entryId,
                field: 'content',
                oldText: existing.content,
                newText: nextContent,
                source: workingChangeSourceManual,
                summary: 'Update entry content',
              );
              changeIds.add(change.id);
            }
            if (existing.category != nextCategory) {
              final change = await overlay.stageTextChange(
                resourcePath: '$resourcePathBase/category',
                resourceType: selection.value.section.aiResourceType,
                resourceId: entryId,
                field: 'category',
                oldText: existing.category,
                newText: nextCategory,
                source: workingChangeSourceManual,
                summary: 'Update entry category',
              );
              changeIds.add(change.id);
            }
            if (changeIds.isNotEmpty) {
              await overlay.commitManualSave(
                manualChangeIds: changeIds,
                resourceScopes: [resourcePathBase],
                manualMessage: 'history.commit_message.manual_entry_save',
              );
            }
            if (showSuccess) {
              showSaveSuccess();
            }
            return;
          case NovelWorkspaceSection.characters:
            return;
          case NovelWorkspaceSection.foreshadowings:
            final existing = await service.getForeshadowingById(entryId);
            if (existing == null) return;
            final changeIds = <String>[];
            final title = entryTitleController.text.trim();
            final setup = foreshadowSetupController.text;
            final payoff = foreshadowPayoffController.text;
            final status = selectedStatus.value;
            final existingPositions = foreshadowingPositionFields(
              foreshadowingPositionIdsOf(existing),
            );
            final nextPositions = foreshadowingPositionFields(
              foreshadowPositions.value,
            );
            final specs = [
              ('title', existing.title, title),
              ('setup', existing.setup, setup),
              ('payoff', existing.payoff, payoff),
              ('status', existing.status, status),
              // overlay 逐字段回放位置；先清后设，避免章节 / 场次短暂同时存在。
              for (final clearing in [true, false])
                for (final field in nextPositions.keys)
                  if ((nextPositions[field] == null) == clearing)
                    (
                      field,
                      existingPositions[field] ?? '',
                      nextPositions[field] ?? '',
                    ),
            ];
            for (final spec in specs) {
              if (spec.$2 == spec.$3) continue;
              if (spec.$1 == 'title') {
                final duplicateError = await duplicateTitleFieldError(
                  service: service,
                  section: selection.value.section,
                  title: title,
                  excludeId: entryId,
                );
                if (duplicateError != null) {
                  entryTitleFieldError.value = duplicateError;
                  foreshadowTitleFocusNode.requestFocus();
                  return;
                }
              }
              final change = await overlay.stageTextChange(
                resourcePath: '/foreshadowing/$entryId/${spec.$1}',
                resourceType: 'foreshadowing',
                resourceId: entryId,
                field: spec.$1,
                oldText: spec.$2,
                newText: spec.$3,
                source: workingChangeSourceManual,
                summary: 'Update foreshadowing ${spec.$1}',
              );
              changeIds.add(change.id);
            }
            if (changeIds.isNotEmpty) {
              await overlay.commitManualSave(
                manualChangeIds: changeIds,
                resourceScopes: ['/foreshadowing/$entryId'],
                manualMessage:
                    'history.commit_message.manual_foreshadowing_save',
              );
            }
            if (showSuccess) {
              showSaveSuccess();
            }
            return;
          default:
        }
      } finally {
        isSavingEntry.value = false;
      }
    }

    /// [sourcePath] 是手动选择的文件，[assetId] 是封面工作台的生成结果，二选一。
    Future<void> updateNovelCover(
      Novel novel, {
      String? sourcePath,
      String? assetId,
      bool showSuccess = false,
    }) async {
      if (isApplyingCover.value) {
        return;
      }
      isApplyingCover.value = true;
      try {
        await ref
            .read(novelActionsProvider)
            .updateNovel(
              novel: novel,
              title: novel.title,
              description: novel.description,
              coverSourcePath: sourcePath,
              coverAssetId: assetId,
              removeCover: false,
              tags: novel.tags,
            );
        if (!context.mounted) {
          return;
        }
        if (showSuccess) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.editorGeneratedCoverApplied)),
            ),
          );
        }
      } catch (_) {
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.editorSaveNovelFailed))),
        );
      } finally {
        isApplyingCover.value = false;
      }
    }

    Future<void> pickAndUploadCover(Novel novel) async {
      final result = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'images',
            extensions: ['png', 'jpg', 'jpeg', 'webp'],
          ),
        ],
      );
      final path = result?.path;
      if (!context.mounted || path == null) {
        return;
      }
      await updateNovelCover(novel, sourcePath: path);
    }

    Future<String?> saveImageToNovelDir(
      String sourcePath, {
      required String kind,
    }) async {
      final purpose = switch (kind) {
        'avatar' => AssetPurpose.avatar,
        'photo' || 'item_photo' => AssetPurpose.photo,
        _ => throw ArgumentError.value(kind, 'kind'),
      };
      final asset = await ref
          .read(imageLibraryServiceProvider)
          .importFile(sourcePath, novelId: novelId, purpose: purpose);
      return asset.id;
    }

    Future<void> saveCharacterAvatar(
      String characterId,
      String avatarAssetId,
    ) async {
      final dbPath =
          contentDatabasePath.value ??
          novelAsync.asData?.value?.contentDatabasePath;
      if (dbPath == null) return;
      try {
        await ref
            .read(novelContentServiceProvider(dbPath))
            .updateCharacterAvatarAndPhotos(
              entryId: characterId,
              avatarAssetId: avatarAssetId,
            );
      } catch (e, s) {
        _log.error('saveCharacterAvatar FAILED: $e', error: e, stackTrace: s);
      }
    }

    Future<void> saveItemPhotos(String itemId, List<String> photos) async {
      final dbPath =
          contentDatabasePath.value ??
          novelAsync.asData?.value?.contentDatabasePath;
      if (dbPath == null) return;
      try {
        await ref
            .read(novelContentServiceProvider(dbPath))
            .updateItemPhotos(entryId: itemId, assetIds: photos);
      } catch (e, s) {
        _log.error('saveItemPhotos FAILED: $e', error: e, stackTrace: s);
      }
    }

    Future<void> addItemPhoto() async {
      final itemId = selection.value.itemId;
      if (itemId == null && !selection.value.isCreating) {
        return;
      }
      final files = await openFiles(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'images',
            extensions: ['png', 'jpg', 'jpeg', 'webp'],
          ),
        ],
      );
      if (!context.mounted || files.isEmpty) return;

      isAddingItemPhoto.value = true;
      try {
        for (final file in files) {
          final savedPath = await saveImageToNovelDir(
            file.path,
            kind: 'item_photo',
          );
          if (savedPath != null) {
            itemPhotos.value = [...itemPhotos.value, savedPath];
          }
        }
        if (itemId != null) {
          await saveItemPhotos(itemId, itemPhotos.value);
        }
      } finally {
        if (context.mounted) {
          isAddingItemPhoto.value = false;
        }
      }
    }

    Future<void> removeItemPhoto(String path) async {
      final itemId = selection.value.itemId;
      itemPhotos.value = itemPhotos.value.where((p) => p != path).toList();
      // 只移除作品引用，图片资产保留在图片库中；物理清理由单独的清理任务处理。
      if (itemId != null) {
        await saveItemPhotos(itemId, itemPhotos.value);
      }
    }

    Future<void> addItemPhotoFromAsset(String assetId, String itemId) async {
      final dbPath =
          contentDatabasePath.value ??
          novelAsync.asData?.value?.contentDatabasePath;
      if (dbPath == null) {
        throw StateError('Novel content database is unavailable');
      }
      final service = ref.read(novelContentServiceProvider(dbPath));
      await service.addItemPhotos(itemId, [assetId]);
      if (selection.value.section == NovelWorkspaceSection.items &&
          selection.value.itemId == itemId) {
        itemPhotos.value = (await service.getItemById(
          itemId,
        ))!.photos!.map((photo) => photo.assetId).toList();
      }
    }

    Future<void> generateItemPhoto(String prompt, String itemId) async {
      final text = 'Item photo: $prompt';
      aiPanelCollapsed.value = false;
      pendingHandoffDraft.value = AiChatHandoffDraft(
        id: 'item_photo_${DateTime.now().microsecondsSinceEpoch}',
        label: context.t(LocaleKeys.toolNameGeneratePhoto),
        content: text,
        title: context.t(LocaleKeys.toolNameGeneratePhoto),
        autoSend: true,
        references: [
          AiContextReference(
            section: selection.value.section,
            itemId: itemId,
            label: entryTitleController.text,
          ),
        ],
        initialText: text,
      );
    }

    AiContextReference? shortcutReferenceForSelection() {
      final itemId = selection.value.itemId;
      switch (selection.value.section) {
        case NovelWorkspaceSection.novel_description:
          return AiContextReference(
            section: NovelWorkspaceSection.novel_description,
            itemId: novelId,
            label: novelAsync.asData?.value?.title ?? '',
          );
        case NovelWorkspaceSection.outlines:
          if (itemId == null) {
            return null;
          }
          final title = outlineDraft.value?.title.trim() ?? '';
          return AiContextReference(
            section: NovelWorkspaceSection.outlines,
            itemId: itemId,
            label: title,
          );
        case NovelWorkspaceSection.chapters:
        case NovelWorkspaceSection.lore:
        case NovelWorkspaceSection.materials:
        case NovelWorkspaceSection.characters:
        case NovelWorkspaceSection.skills:
        case NovelWorkspaceSection.items:
        case NovelWorkspaceSection.factions:
        case NovelWorkspaceSection.creatures:
        case NovelWorkspaceSection.foreshadowings:
          if (itemId == null) {
            return null;
          }
          final label = switch (selection.value.section) {
            NovelWorkspaceSection.chapters =>
              chapterTitleController.text.trim(),
            NovelWorkspaceSection.characters =>
              characterEditorController.snapshot?.name ?? '',
            NovelWorkspaceSection.foreshadowings =>
              entryTitleController.text.trim(),
            _ => entryTitleController.text.trim(),
          };
          return AiContextReference(
            section: selection.value.section,
            itemId: itemId,
            label: label,
          );
        case NovelWorkspaceSection.overview:
        case NovelWorkspaceSection.maps:
        case NovelWorkspaceSection.entity_graph:
        case NovelWorkspaceSection.story_progress:
        case NovelWorkspaceSection.canvas:
        case NovelWorkspaceSection.screenplay_script:
        case NovelWorkspaceSection.screenplay_outline:
        case NovelWorkspaceSection.storyboard:
        case NovelWorkspaceSection.screenplay_scenes:
          return null;
      }
    }

    void runShortcutAction(AiShortcutActionDefinition action) {
      final reference = shortcutReferenceForSelection();
      if (contentSelection.value is _EditorAiChatExpandedSelection) {
        aiPanelCollapsed.value = false;
      }
      contentSelection.value = const _EditorWorkspaceContentSelection();
      aiPanelCollapsed.value = false;
      pendingShortcutDraft.value = AiChatShortcutDraft(
        id: 'shortcut_${action.id}_${DateTime.now().microsecondsSinceEpoch}',
        text: action.prompt,
        autoSend: action.autoSend,
        references: reference == null
            ? const <AiContextReference>[]
            : <AiContextReference>[reference],
      );
    }

    void addChapterSelectionToChat(String selectedText) {
      final chapterId = selection.value.itemId;
      if (chapterId == null || selectedText.trim().isEmpty) {
        return;
      }
      final signal =
          'chapter_selection_${DateTime.now().microsecondsSinceEpoch}';
      final chapterTitle = chapterTitleController.text.trim();
      contentSelection.value = const _EditorWorkspaceContentSelection();
      aiPanelCollapsed.value = false;
      pendingShortcutDraft.value = AiChatShortcutDraft(
        id: signal,
        text: '',
        references: [
          AiContextReference.selection(
            itemId: '${chapterId}_$signal',
            label: chapterTitle.isEmpty
                ? context.t(LocaleKeys.aiContextSelection)
                : chapterTitle,
            content: selectedText,
          ),
        ],
      );
    }

    Future<void> setCharacterAvatar(String assetId, String characterId) =>
        saveCharacterAvatar(characterId, assetId);

    Future<void> handleAddPhotoFromAsset(
      String assetId, {
      String? characterId,
      String? itemId,
    }) async {
      try {
        if (characterId != null && characterId.isNotEmpty) {
          final dbPath =
              contentDatabasePath.value ??
              novelAsync.asData?.value?.contentDatabasePath;
          if (dbPath == null) {
            throw StateError('Novel content database is unavailable');
          }
          await ref
              .read(novelContentServiceProvider(dbPath))
              .addCharacterPhotos(characterId, [assetId]);
        } else if (itemId != null && itemId.isNotEmpty) {
          await addItemPhotoFromAsset(assetId, itemId);
        }
      } catch (error, stackTrace) {
        _log.error(
          'Apply generated photo failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      }
    }

    String characterLabel(String characterId) {
      return charactersAsync.asData?.value
              .where((character) => character.id == characterId)
              .firstOrNull
              ?.name ??
          '';
    }

    Future<void> generateCharacterAvatar(
      String prompt,
      String characterId,
    ) async {
      aiPanelCollapsed.value = false;
      pendingHandoffDraft.value = AiChatHandoffDraft(
        id: 'char_avatar_${DateTime.now().microsecondsSinceEpoch}',
        label: context.t(LocaleKeys.toolNameGenerateAvatar),
        content: prompt,
        title: context.t(LocaleKeys.toolNameGenerateAvatar),
        autoSend: true,
        references: [
          AiContextReference(
            section: NovelWorkspaceSection.characters,
            itemId: characterId,
            label: characterLabel(characterId),
          ),
        ],
        initialText: prompt,
      );
    }

    Future<void> generateCharacterPhoto(
      String prompt,
      String characterId,
    ) async {
      aiPanelCollapsed.value = false;
      pendingHandoffDraft.value = AiChatHandoffDraft(
        id: 'char_photo_${DateTime.now().microsecondsSinceEpoch}',
        label: context.t(LocaleKeys.toolNameGeneratePhoto),
        content: prompt,
        title: context.t(LocaleKeys.toolNameGeneratePhoto),
        autoSend: true,
        references: [
          AiContextReference(
            section: NovelWorkspaceSection.characters,
            itemId: characterId,
            label: characterLabel(characterId),
          ),
        ],
        initialText: prompt,
      );
    }

    Future<void> saveCurrentSelection({
      bool skipEmptyContent = false,
      bool showSuccess = false,
    }) async {
      if (selection.value.section.isReadOnly) {
        return;
      }
      switch (selection.value.section) {
        case NovelWorkspaceSection.novel_description:
          await saveNovelDescription(showSuccess: showSuccess);
          return;
        case NovelWorkspaceSection.chapters:
          await saveChapter(
            skipEmptyContent: skipEmptyContent,
            showSuccess: showSuccess,
          );
          return;
        case NovelWorkspaceSection.lore:
        case NovelWorkspaceSection.outlines:
        case NovelWorkspaceSection.materials:
        case NovelWorkspaceSection.characters:
        case NovelWorkspaceSection.skills:
        case NovelWorkspaceSection.items:
        case NovelWorkspaceSection.factions:
        case NovelWorkspaceSection.creatures:
        case NovelWorkspaceSection.foreshadowings:
          await saveEntry(showSuccess: showSuccess);
          return;
        default:
          return;
      }
    }

    Future<void> saveDesktopContent() async {
      final activePanelSave = activeAgentPanelSave.value;
      if (activePanelSave != null) {
        await activePanelSave();
        return;
      }
      // 主区展示规则列表 / 封面工坊 / 会议等没有保存动作的页面时，Cmd+S 不该回头把
      // 已经不在树上的工作区条目按旧快照再写一遍，更不该弹「已保存」。
      if (contentSelection.value is! _EditorWorkspaceContentSelection) {
        return;
      }
      final sceneFlush = screenplaySceneFlush.value;
      if (sceneFlush != null) {
        await sceneFlush();
        return;
      }
      await saveCurrentSelection(showSuccess: true);
    }

    String? currentAiWorkspaceTitle() {
      if (selection.value.section.isReadOnly) return null;
      final currentNovel = novelAsync.asData?.value;
      switch (selection.value.section) {
        case NovelWorkspaceSection.lore:
        case NovelWorkspaceSection.materials:
        case NovelWorkspaceSection.skills:
        case NovelWorkspaceSection.items:
        case NovelWorkspaceSection.factions:
        case NovelWorkspaceSection.creatures:
          final title = entryTitleController.text.trim();
          return title.isEmpty ? null : title;
        case NovelWorkspaceSection.outlines:
          final title = outlineDraft.value?.title.trim() ?? '';
          return title.isEmpty ? null : title;
        case NovelWorkspaceSection.characters:
          final name = characterEditorController.snapshot?.name ?? '';
          return name.isEmpty ? null : name;
        case NovelWorkspaceSection.foreshadowings:
          final title = entryTitleController.text.trim();
          return title.isEmpty ? null : title;
        case NovelWorkspaceSection.chapters:
          final title = chapterTitleController.text.trim();
          return title.isEmpty ? null : title;
        case NovelWorkspaceSection.novel_description:
          return currentNovel?.title;
        default:
          return null;
      }
    }

    String? currentAiWorkspaceContent() {
      if (selection.value.section.isReadOnly) return null;
      switch (selection.value.section) {
        case NovelWorkspaceSection.lore:
        case NovelWorkspaceSection.materials:
        case NovelWorkspaceSection.skills:
        case NovelWorkspaceSection.items:
        case NovelWorkspaceSection.factions:
        case NovelWorkspaceSection.creatures:
          return entryContentController.text;
        case NovelWorkspaceSection.outlines:
          return outlineDraft.value?.toDocumentContent() ?? '';
        case NovelWorkspaceSection.characters:
          return characterEditorController.snapshot?.biography;
        case NovelWorkspaceSection.foreshadowings:
          return [
            if (foreshadowSetupController.text.trim().isNotEmpty)
              '${context.t(LocaleKeys.commonSetup)}：${foreshadowSetupController.text.trim()}',
            if (foreshadowPayoffController.text.trim().isNotEmpty)
              '${context.t(LocaleKeys.commonPayoff)}：${foreshadowPayoffController.text.trim()}',
          ].join('\n\n');
        case NovelWorkspaceSection.chapters:
          return chapterContentController.text;
        case NovelWorkspaceSection.novel_description:
          return novelDescriptionController.text;
        default:
          return null;
      }
    }

    String? currentAiWorkspaceMetaTitle(BuildContext context) {
      return context.t(sectionLocaleKey(selection.value.section));
    }

    String? currentAiWorkspaceMetaContent() {
      final currentNovel = novelAsync.asData?.value;
      return switch (selection.value.section) {
        NovelWorkspaceSection.novel_description => currentNovel?.title,
        NovelWorkspaceSection.characters => [
          if ((characterEditorController.snapshot?.role ?? '')
              .trim()
              .isNotEmpty)
            '${context.t(LocaleKeys.commonRole)}: ${characterEditorController.snapshot!.role.trim()}',
          if ((characterEditorController.snapshot?.gender ?? '')
              .trim()
              .isNotEmpty)
            '${context.t(LocaleKeys.commonGender)}: ${characterEditorController.snapshot!.gender.trim()}',
        ].join('\n'),
        NovelWorkspaceSection.foreshadowings =>
          '${context.t(LocaleKeys.commonStatus)}: ${selectedStatus.value}',
        _ => null,
      };
    }

    Future<void> applyAiWorkspaceContent(String content) async {
      if (selection.value.section.isReadOnly) return;
      switch (selection.value.section) {
        case NovelWorkspaceSection.lore:
        case NovelWorkspaceSection.materials:
        case NovelWorkspaceSection.skills:
        case NovelWorkspaceSection.items:
        case NovelWorkspaceSection.factions:
        case NovelWorkspaceSection.creatures:
          entryContentController.text = content;
          await saveEntry();
          return;
        case NovelWorkspaceSection.outlines:
          final draft = outlineDraft.value;
          if (draft == null) {
            return;
          }
          final nextDraft = draft.copyWith(content: content);
          outlineDraft.value = nextDraft;
          pendingOutlineDraft.value = nextDraft;
          await saveEntry();
          return;
        case NovelWorkspaceSection.characters:
          await characterEditorController.replaceBiographyAndSave(content);
          return;
        case NovelWorkspaceSection.foreshadowings:
          foreshadowSetupController.text = content;
          await saveEntry();
          return;
        case NovelWorkspaceSection.chapters:
          chapterContentController.text = content;
          await saveChapter();
          return;
        case NovelWorkspaceSection.novel_description:
          novelDescriptionController.text = content;
          await saveNovelDescription();
          return;
        default:
          return;
      }
    }

    Future<void> runAutoSave({required bool showFeedback}) async {
      final scheduledSection = selection.value.section;
      final scheduledItemId = selection.value.itemId;
      final scheduledChapter = selectedChapterAsync.asData?.value;
      final shouldShowChapterFeedback =
          showFeedback &&
          scheduledSection == NovelWorkspaceSection.chapters &&
          scheduledChapter?.id == scheduledItemId &&
          chapterContentController.text.trim().isNotEmpty &&
          (chapterTitleController.text.trim() != scheduledChapter?.title ||
              chapterOutlineController.text != scheduledChapter?.outline ||
              chapterContentController.text != scheduledChapter?.content);
      await saveCurrentSelection(skipEmptyContent: true);
      if (!shouldShowChapterFeedback || !context.mounted) {
        return;
      }
      final currentSelection = selection.value;
      if (currentSelection.section == scheduledSection &&
          currentSelection.itemId == scheduledItemId) {
        chapterAutoSaveFeedback.value += 1;
      }
    }

    void scheduleAutoSave() {
      if (isSyncingControllerText.value) {
        return;
      }
      if (selection.value.isCreating) {
        return;
      }
      autoSaveTimer.value?.cancel();
      autoSaveTimer.value = Timer(_autoSaveDelay, () {
        autoSaveTimer.value = null;
        unawaited(runAutoSave(showFeedback: true));
      });
    }

    bool outlineBeatsChanged(OutlineDraft? previous, OutlineDraft next) {
      if (previous == null || previous.beats.length != next.beats.length) {
        return true;
      }
      for (var index = 0; index < next.beats.length; index++) {
        final oldBeat = previous.beats[index];
        final nextBeat = next.beats[index];
        if (oldBeat.id != nextBeat.id ||
            oldBeat.title != nextBeat.title ||
            oldBeat.content != nextBeat.content ||
            oldBeat.status != nextBeat.status ||
            oldBeat.chapterCount != nextBeat.chapterCount ||
            oldBeat.sortOrder != nextBeat.sortOrder) {
          return true;
        }
      }
      return false;
    }

    void flushAutoSave() {
      if (selection.value.isCreating) {
        return;
      }
      final hadPendingAutoSave = autoSaveTimer.value != null;
      autoSaveTimer.value?.cancel();
      autoSaveTimer.value = null;
      unawaited(runAutoSave(showFeedback: hadPendingAutoSave));
    }

    Future<_AiProcessingExitDecision?> showAiProcessingExitDialog() {
      return showRevericDialog<_AiProcessingExitDecision>(
        context: context,
        builder: (dialogContext) => RevericDialog(
          title: context.t(LocaleKeys.editorAiProcessingExitTitle),
          content: Text(context.t(LocaleKeys.editorAiProcessingExitMessage)),
          actions: [
            RevericButton.secondary(
              label: context.t(LocaleKeys.commonCancel),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            RevericButton.text(
              label: context.t(LocaleKeys.commonPause),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_AiProcessingExitDecision.pause),
            ),
            RevericButton.primary(
              label: context.t(LocaleKeys.commonContinueInBackground),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_AiProcessingExitDecision.background),
            ),
          ],
        ),
      );
    }

    void clearProcessingToken(AiSessionMode mode, String? sessionId) {
      if (sessionId == null ||
          sessionId.isEmpty ||
          sessionId.startsWith('__new__') ||
          sessionId.startsWith('__handoff_draft__')) {
        return;
      }
      ref
          .read(aiModeProcessingTrackerProvider.notifier)
          .setProcessing(
            mode: mode,
            sessionId: sessionId,
            processing: false,
            notifyOnComplete: false,
          );
    }

    Future<void> pauseActiveAiSession() async {
      final chatSessionId = chatPanelSessionId ?? activeAiSessionId.value;
      if (chatSessionId != null &&
          chatSessionId.isNotEmpty &&
          !chatSessionId.startsWith('__new__') &&
          !chatSessionId.startsWith('__handoff_draft__')) {
        await ref
            .read(aiChatRuntimeProvider(chatSessionId).notifier)
            .stopAll(source: AiChatCancelSource.exitPause);
      }

      switch (contentSelection.value) {
        case _EditorAgentCouncilSelection(:final sessionId):
          ref
              .read(agentCouncilRuntimeProvider(sessionId).notifier)
              .cancelOrchestrator();
          clearProcessingToken(AiSessionMode.council, sessionId);
        case _EditorMonologueSelection(:final sessionId):
          ref
              .read(monologueRuntimeProvider(sessionId).notifier)
              .cancelOrchestrator();
          clearProcessingToken(AiSessionMode.monologue, sessionId);
        case _EditorTheaterSelection(:final sessionId):
          ref
              .read(theaterRuntimeProvider(sessionId).notifier)
              .cancelOrchestrator();
          clearProcessingToken(AiSessionMode.theater, sessionId);
        case _EditorRoleplaySelection(:final sessionId):
          ref
              .read(roleplayRuntimeProvider(sessionId).notifier)
              .cancelOrchestrator();
          clearProcessingToken(AiSessionMode.roleplay, sessionId);
        case _EditorWorkspaceContentSelection() ||
            _EditorCoverStudioSelection() ||
            _EditorAiChatExpandedSelection() ||
            _EditorSubAgentSelection() ||
            _EditorAgentRuleSelection() ||
            _EditorAgentRulesListSelection():
          break;
      }
    }

    bool hasUnsavedChanges() {
      return switch (contentSelection.value) {
        _EditorSubAgentSelection() => subAgentHasChanges.value,
        _EditorAgentRuleSelection() =>
          activeAgentPanelHasChanges.value?.call() ?? agentRuleHasChanges.value,
        _ => false,
      };
    }

    bool isBlankCreateDraftSelection() {
      return switch (contentSelection.value) {
        _EditorAgentRuleSelection(:final rule) =>
          rule.id.startsWith('__new__') &&
              (activeAgentPanelIsBlankCreateDraft.value?.call() ?? false),
        _ => false,
      };
    }

    void clearActiveAgentHasChanges() {
      switch (contentSelection.value) {
        case _EditorSubAgentSelection():
          subAgentHasChanges.value = false;
        case _EditorAgentRuleSelection():
          agentRuleHasChanges.value = false;
        default:
          break;
      }
    }

    Future<UnsavedChangesDecision?> showAgentUnsavedChangesDialog() {
      return showUnsavedChangesDialog(
        context: context,
        titleKey: LocaleKeys.editorUnsavedChangesTitle,
        messageKey: LocaleKeys.editorUnsavedChangesMessage,
      );
    }

    /// 返回 true 表示「拦截」（不允许离开）；false 表示放行。
    Future<bool> guardUnsavedChanges() async {
      if (isBlankCreateDraftSelection()) {
        clearActiveAgentHasChanges();
        return false;
      }
      if (!hasUnsavedChanges()) {
        return false;
      }
      final decision = await showAgentUnsavedChangesDialog();
      switch (decision) {
        case null:
          return true; // 取消：留在当前面板
        case UnsavedChangesDecision.discard:
          clearActiveAgentHasChanges();
          return false; // 放弃变更后放行
        case UnsavedChangesDecision.save:
          final save = activeAgentPanelSave.value;
          final saved = save != null && await save();
          if (!saved) {
            return true; // 校验失败/冲突：保持在当前面板
          }
          clearActiveAgentHasChanges();
          return false;
      }
    }

    bool createDraftHasContent() {
      final draft = createDraft.value;
      if (draft == null) {
        return false;
      }
      return switch (draft.section) {
        NovelWorkspaceSection.characters =>
          characterEditorController.hasDraftContent,
        NovelWorkspaceSection.foreshadowings =>
          entryTitleController.text.trim().isNotEmpty ||
              foreshadowSetupController.text.trim().isNotEmpty ||
              foreshadowPayoffController.text.trim().isNotEmpty ||
              selectedStatus.value != foreshadowingStatusPlanted ||
              foreshadowPositions.value != emptyForeshadowingPositionIds,
        NovelWorkspaceSection.lore || NovelWorkspaceSection.materials =>
          entryTitleController.text.trim().isNotEmpty ||
              entryContentController.text.trim().isNotEmpty ||
              entryCategoryController.text.trim().isNotEmpty,
        NovelWorkspaceSection.items ||
        NovelWorkspaceSection.skills ||
        NovelWorkspaceSection.factions ||
        NovelWorkspaceSection.creatures =>
          entryTitleController.text.trim().isNotEmpty ||
              entryContentController.text.trim().isNotEmpty ||
              entryCategoryController.text.trim().isNotEmpty ||
              itemPhotos.value.isNotEmpty,
        _ => false,
      };
    }

    void discardCreateDraft() {
      final draft = createDraft.value;
      final fallback = WorkspaceSelection(section: selection.value.section);
      createDraft.value = null;
      createDraftFieldError.value = null;
      itemPhotos.value = const <String>[];
      selection.value = draft?.previousSelection ?? fallback;
    }

    Future<UnsavedChangesDecision?> showCreateDraftExitDialog() {
      return showUnsavedChangesDialog(
        context: context,
        titleKey: LocaleKeys.workspaceCreateDraftUnsavedTitle,
        messageKey: LocaleKeys.workspaceCreateDraftUnsavedMessage,
      );
    }

    Future<bool> prepareWorkspaceTransition() async {
      if (isMapGenerationBlockingSwitch()) {
        notifyMapGenerationBlocksSwitch();
        return false;
      }
      if (await guardUnsavedChanges()) {
        return false;
      }
      // 主区不是工作区时（智能体规则 / 封面工坊 / 圆桌会议等），工作区面板已经不在
      // 树上，controller 里只剩离开那一刻的快照——它在离开时就已经落过盘。此时再走
      // 一遍保存既是无效写，也会把这期间 AI 后台对同一章节/条目的改动覆盖回旧内容；
      // 人物编辑区更会因为 binding 已卸载而恒判「保存失败」，把所有导航静默拦死。
      if (contentSelection.value is! _EditorWorkspaceContentSelection) {
        return true;
      }
      // 切走前把独立窗口里未 debounce 的大纲灌回主 controller，再走章节保存。
      if (selection.value.section == NovelWorkspaceSection.chapters) {
        chapterOutlineWindowSession.flushDetachedOutlineSync();
      }
      // 剧本正文自己管落盘，走的是区域挂载时交回来的 flush，不经章节保存链。
      final sceneFlush = screenplaySceneFlush.value;
      if (sceneFlush != null) {
        try {
          await sceneFlush();
        } catch (error, stackTrace) {
          _log.error(
            'screenplay scene flush failed',
            error: error,
            stackTrace: stackTrace,
          );
          return false;
        }
      }
      if (!selection.value.isCreating) {
        if (selection.value.section == NovelWorkspaceSection.outlines) {
          final draft = outlineDraft.value;
          if (draft != null) {
            autoSaveTimer.value?.cancel();
            autoSaveTimer.value = null;
            return queueOutlineDraftSave(draft);
          }
        }
        if (selection.value.section == NovelWorkspaceSection.characters) {
          final flushed = await characterEditorController.flushBeforeTransition(
            selectedItemId: selection.value.itemId,
          );
          if (!flushed) {
            // 拦截本身没有任何 UI 反馈，用户只会看到「点了没反应」，留日志便于定位。
            _log.warning(
              'workspace transition blocked by character flush '
              'itemId=${selection.value.itemId}',
            );
          }
          return flushed;
        }
        await saveCurrentSelection();
        return true;
      }
      if (!createDraftHasContent()) {
        discardCreateDraft();
        return true;
      }
      final decision = await showCreateDraftExitDialog();
      if (decision == null) {
        return false;
      }
      if (decision == UnsavedChangesDecision.discard) {
        discardCreateDraft();
        return true;
      }
      final path = databasePath;
      if (path == null || isSavingEntry.value) {
        return false;
      }
      isSavingEntry.value = true;
      try {
        return await saveNewEntry(ref.read(novelContentServiceProvider(path)));
      } finally {
        isSavingEntry.value = false;
      }
    }

    Future<void> handleProcessingExit() async {
      final decision = await showAiProcessingExitDialog();
      if (decision == null) {
        return;
      }
      if (decision == _AiProcessingExitDecision.pause) {
        await pauseActiveAiSession();
        isAgentEditing.value = false;
        isModeRunning.value = false;
      }
      final canLeave = await prepareWorkspaceTransition();
      if (!canLeave) {
        return;
      }
      allowLeaveWithRunningAgent.value = true;
      await Future<void>.delayed(Duration.zero);
      if (context.mounted) {
        popIfRouteCurrent(context);
      }
    }

    void showWorkspaceContent() {
      final wasExpandedChat =
          contentSelection.value is _EditorAiChatExpandedSelection;
      if (wasExpandedChat) {
        // 离开 Main 沉浸区后，右侧保留完整 Chat Panel（不收成窄条）。
        aiPanelCollapsed.value = false;
      }
      contentSelection.value = const _EditorWorkspaceContentSelection();
    }

    void openExpandedChat() {
      contentSelection.value = const _EditorAiChatExpandedSelection();
      aiPanelCollapsed.value = true;
    }

    /// 用户手动展开沉浸聊天：和侧栏入口一样属于「离开工作区」，必须先落盘再换主区。
    /// 首帧自动展开（快速开书）直接用 [openExpandedChat]——那时工作区
    /// 还没有任何编辑，也不该在 build 阶段弹未保存对话框。
    Future<void> expandChatFromPanel() async {
      if (!await prepareWorkspaceTransition()) {
        return;
      }
      openExpandedChat();
    }

    // 携带开场想法进入：首帧展开沉浸聊天并自动发送开场提示，
    // 触发创作向导引导用户完善设定。只执行一次。
    // 文案在 build 阶段取（context.t 走 Localizations），不能在 useEffect 回调里取，
    // 否则触发「Cannot listen to inherited widgets inside HookState.initState」。
    final kickoffPrompt = initialChatKickoffPrompt?.trim();
    final hasKickoff = kickoffPrompt != null && kickoffPrompt.isNotEmpty;
    final kickoffLabel = hasKickoff
        ? initialChatKickoffTitle ?? context.t(LocaleKeys.libraryQuickStart)
        : '';
    final kickoffTitle = kickoffLabel;
    useEffect(() {
      final prompt = kickoffPrompt;
      if (prompt == null || prompt.isEmpty) {
        return null;
      }
      openExpandedChat();
      final draftSignal =
          '__handoff_draft__kickoff_${DateTime.now().microsecondsSinceEpoch}_$builtinAgentSlugOrchestrator';
      activeAiSessionId.value = draftSignal;
      pendingHandoffDraft.value = AiChatHandoffDraft(
        id: draftSignal,
        label: kickoffLabel,
        content: prompt,
        title: kickoffTitle,
        initialText: prompt,
        autoSend: true,
      );
      return null;
    }, const []);

    // 快速开书进入：加载到 draft 作品时首帧展开沉浸聊天，让用户直接和创作向导对话，
    // 而不是停在空工作区。开场消息由上方 kickoff 消费，重开草稿不重复发送。
    // draft 由 novelAsync 异步加载，用 deps 触发（不能用 const []，否则首帧还没数据）。
    final isQuickStartDraftEntry = novelAsync.asData?.value?.draft ?? false;
    useEffect(() {
      if (isQuickStartDraftEntry) {
        openExpandedChat();
      }
      return null;
    }, [isQuickStartDraftEntry]);

    void openAgentMode(_EditorContentSelection selection) {
      aiPanelCollapsed.value = false;
      contentSelection.value = selection;
    }

    /// chat 里点了跳转类下一步建议：切 Main 区域到目标功能，seed 预填目标输入框。
    ///
    /// 白名单外的 [FeatureId] 到不了这里（schema 枚举 + 裁决器双层拦截），
    /// 真出现了只记日志，不改变界面。
    Future<void> openFeatureFromChatGuarded(
      FeatureId feature,
      String? seedText,
    ) async {
      // chat 里的功能跳转同样会把工作区从主区换走，和侧栏入口走一样的落盘流程。
      if (!await prepareWorkspaceTransition()) {
        return;
      }
      switch (feature) {
        case FeatureId.ai_council:
          openAgentMode(_EditorAgentCouncilSelection(initialTopic: seedText));
        case FeatureId.ai_theater:
          openAgentMode(_EditorTheaterSelection(initialScene: seedText));
        case FeatureId.ai_roleplay:
          // 角色扮演的 seed 是角色名，不是自由文本：解析成 id 直接进入对话。
          // 解析不到时仍然跳转，让用户在选择器里自己挑，不要吞掉这次跳转。
          openAgentMode(
            _EditorRoleplaySelection(
              initialCharacterId: resolveNextActionCharacterId(
                (charactersAsync.asData?.value ?? const <CharacterProfile>[])
                    .map((c) => (id: c.id, name: c.name)),
                seedText,
              ),
            ),
          );
        case FeatureId.ai_cover_studio:
          contentSelection.value = const _EditorCoverStudioSelection();
        default:
          _log.warning(
            'openFeatureFromChat ignored unsupported feature=${feature.name}',
          );
      }
    }

    void openFeatureFromChat(FeatureId feature, String? seedText) {
      unawaited(openFeatureFromChatGuarded(feature, seedText));
    }

    Future<void> openSessionReference(
      String sessionId,
      AiSessionMode mode,
    ) async {
      final source = await ref
          .read(appDatabaseProvider)
          .aiChatSessionDao
          .getById(sessionId, novelId: novelId);
      if (!context.mounted) {
        return;
      }
      if (source == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.aiChatSourceUnavailable)),
          ),
        );
        return;
      }

      if (await guardUnsavedChanges()) {
        return;
      }
      aiPanelCollapsed.value = false;
      switch (mode) {
        case AiSessionMode.chat:
          activeAiSessionId.value = sessionId;
        case AiSessionMode.council:
          contentSelection.value = _EditorAgentCouncilSelection(
            sessionId: sessionId,
          );
        case AiSessionMode.monologue:
          contentSelection.value = _EditorMonologueSelection(
            sessionId: sessionId,
          );
        case AiSessionMode.theater:
          contentSelection.value = _EditorTheaterSelection(
            sessionId: sessionId,
          );
        case AiSessionMode.roleplay:
          contentSelection.value = _EditorRoleplaySelection(
            sessionId: sessionId,
          );
      }
    }

    void cancelSubAgentEdit() {
      showWorkspaceContent();
      subAgentHasChanges.value = false;
    }

    Future<void> leaveEditorPage() async {
      final canLeave = await prepareWorkspaceTransition();
      if (!canLeave) {
        return;
      }
      if (context.mounted) {
        popIfRouteCurrent(context);
      }
    }

    Future<void> attemptLeaveEditorPage() async {
      if (isAgentEditing.value || isModeRunning.value) {
        await handleProcessingExit();
        return;
      }
      await leaveEditorPage();
    }

    Future<void> switchToNovel(String novelId) async {
      final canSwitch = await prepareWorkspaceTransition();
      if (!canSwitch) {
        return;
      }
      if (context.mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => WorkspaceEditorPage(novelId: novelId),
          ),
        );
      }
    }

    useEffect(() {
      final currentNovel = novelAsync.asData?.value;
      if (currentNovel == null) {
        return null;
      }
      syncControllerText(
        novelDescriptionController,
        currentNovel.description,
        focusNode: novelDescriptionFocusNode,
      );
      return null;
    }, [novelAsync.asData?.value?.description, novelAsync.asData?.value?.id]);

    useEffect(
      () {
        final chapters = chaptersAsync.asData?.value;
        if (chapters == null || chapters.isEmpty) {
          return null;
        }
        final current = selection.value;
        if (current.section == NovelWorkspaceSection.chapters &&
            current.itemId != null &&
            chapters.any((chapter) => chapter.id == current.itemId)) {
          final targetChanged =
              loadedWorkspaceSection.value != current.section ||
              loadedWorkspaceItemId.value != current.itemId;
          final selectedChapterMeta = chapters.firstWhere(
            (chapter) => chapter.id == current.itemId,
          );
          final selectedChapter = selectedChapterAsync.asData?.value;
          if (selectedChapter == null ||
              selectedChapter.id != selectedChapterMeta.id) {
            return null;
          }
          final nextTitle = selectedChapter.title ?? '';
          final nextOutline = selectedChapter.outline;
          final nextContent = selectedChapter.content;
          syncControllerText(
            chapterTitleController,
            nextTitle,
            focusNode: chapterTitleFocusNode,
            force: targetChanged,
          );
          syncControllerText(
            chapterOutlineController,
            nextOutline,
            focusNode: chapterOutlineFocusNode,
            force: targetChanged,
          );
          final pendingSaveContent =
              pendingLocalChapterId.value == current.itemId
              ? pendingLocalChapterContent.value
              : null;
          final shouldApplyContent = shouldApplyChapterContentStreamValue(
            incomingContent: nextContent,
            controllerContent: chapterContentController.text,
            lastSyncedContent: lastSyncedChapterContent.value,
            pendingLocalSaveContent: pendingSaveContent,
            targetChanged: targetChanged,
          );
          if (shouldApplyContent) {
            syncControllerText(
              chapterContentController,
              nextContent,
              focusNode: chapterContentFocusNode,
              force: targetChanged,
              acceptWhileFocused: true,
            );
          }
          // 只把实际接收的外部正文或本地保存回声推进为同步基线。编辑器有未保存
          // 输入时，外部写入不覆盖 controller，也不能冒充它已经接受过的内容。
          if (chapterContentController.text == nextContent ||
              nextContent == pendingSaveContent) {
            lastSyncedChapterContent.value = nextContent;
          }
          chapterNumber.value =
              selectedChapterMeta.chapterNum ?? selectedChapter.chapterNum;
          loadedWorkspaceSection.value = current.section;
          loadedWorkspaceItemId.value = current.itemId;
          return null;
        }
        return null;
      },
      [
        chaptersAsync.asData?.value,
        selectedChapterAsync.asData?.value,
        outlinesAsync.asData?.value,
        selection.value.section,
        selection.value.itemId,
      ],
    );

    useEffect(
      () {
        final section = selection.value.section;
        final itemId = selection.value.itemId;
        if (itemId == null) {
          if (section == NovelWorkspaceSection.outlines) {
            outlineDraft.value = null;
          }
          return null;
        }

        final targetChanged =
            loadedWorkspaceSection.value != section ||
            loadedWorkspaceItemId.value != itemId;
        if (targetChanged) {
          entryTitleFieldError.value = null;
        }
        var didLoadWorkspaceTarget = false;

        void syncEntryTextFields({
          required String title,
          required String content,
          String category = '',
        }) {
          syncControllerText(
            entryTitleController,
            title,
            focusNode: entryTitleFocusNode,
            force: targetChanged,
          );
          syncControllerText(
            entryContentController,
            content,
            focusNode: entryContentFocusNode,
            force: targetChanged,
          );
          syncControllerText(
            entryCategoryController,
            category,
            focusNode: entryCategoryFocusNode,
            force: targetChanged,
          );
          didLoadWorkspaceTarget = true;
        }

        if (section == NovelWorkspaceSection.lore) {
          final item = worldbuildingAsync.asData?.value
              .where((entry) => entry.id == itemId)
              .firstOrNull;
          if (item != null) {
            syncEntryTextFields(
              title: item.title,
              content: item.content,
              category: item.category,
            );
          }
        } else if (section == NovelWorkspaceSection.outlines) {
          final item = outlinesAsync.asData?.value
              .where((entry) => entry.documentId == itemId)
              .firstOrNull;
          if (item != null) {
            if (targetChanged || pendingOutlineDraft.value == null) {
              outlineDraft.value = item;
              pendingOutlineDraft.value = null;
            }
            didLoadWorkspaceTarget = true;
          }
        } else if (section == NovelWorkspaceSection.materials) {
          final item = materialsAsync.asData?.value
              .where((entry) => entry.id == itemId)
              .firstOrNull;
          if (item != null) {
            syncEntryTextFields(
              title: item.title,
              content: item.content,
              category: item.category,
            );
          }
        } else if (isCompendiumSection(section)) {
          final entries = switch (section) {
            NovelWorkspaceSection.skills => skillsAsync,
            NovelWorkspaceSection.items => itemsAsync,
            NovelWorkspaceSection.factions => factionsAsync,
            _ => creaturesAsync,
          };
          final item = entries.asData?.value
              .where((entry) => entry.id == itemId)
              .firstOrNull;
          if (item != null) {
            syncEntryTextFields(
              title: item.title,
              content: item.content,
              category: item.category,
            );
            itemPhotos.value =
                item.photos?.map((photo) => photo.assetId).toList() ??
                const <String>[];
          }
        } else if (section == NovelWorkspaceSection.foreshadowings) {
          final item = foreshadowingsAsync.asData?.value
              .where((entry) => entry.id == itemId)
              .firstOrNull;
          if (item != null) {
            syncControllerText(
              entryTitleController,
              item.title,
              focusNode: foreshadowTitleFocusNode,
              force: targetChanged,
            );
            syncControllerText(
              foreshadowSetupController,
              item.setup,
              focusNode: foreshadowSetupFocusNode,
              force: targetChanged,
            );
            syncControllerText(
              foreshadowPayoffController,
              item.payoff,
              focusNode: foreshadowPayoffFocusNode,
              force: targetChanged,
            );
            selectedStatus.value = item.status;
            foreshadowPositions.value = foreshadowingPositionIdsOf(item);
            didLoadWorkspaceTarget = true;
          }
        }
        if (didLoadWorkspaceTarget) {
          loadedWorkspaceSection.value = section;
          loadedWorkspaceItemId.value = itemId;
        }
        return null;
      },
      [
        selection.value.section,
        selection.value.itemId,
        worldbuildingAsync.asData?.value,
        outlinesAsync.asData?.value,
        materialsAsync.asData?.value,
        skillsAsync.asData?.value,
        itemsAsync.asData?.value,
        factionsAsync.asData?.value,
        creaturesAsync.asData?.value,
        foreshadowingsAsync.asData?.value,
      ],
    );

    // 自动保存：监听所有文本控制器变化
    useOnListenableChange(novelDescriptionController, scheduleAutoSave);
    useOnListenableChange(chapterTitleController, scheduleAutoSave);
    useOnListenableChange(chapterOutlineController, scheduleAutoSave);
    useOnListenableChange(chapterContentController, scheduleAutoSave);
    useOnListenableChange(entryTitleController, () {
      createDraftFieldError.value = null;
      entryTitleFieldError.value = null;
      scheduleAutoSave();
    });
    useOnListenableChange(entryContentController, scheduleAutoSave);
    useOnListenableChange(entryCategoryController, scheduleAutoSave);
    useOnListenableChange(foreshadowSetupController, scheduleAutoSave);
    useOnListenableChange(foreshadowPayoffController, scheduleAutoSave);

    // 清理自动保存定时器
    final outlineServiceForExit = databasePath == null
        ? null
        : ref.watch(novelContentServiceProvider(databasePath)).outlineService;
    useEffect(
      () => () {
        autoSaveTimer.value?.cancel();
        final draft = pendingOutlineDraft.value;
        if (draft != null && outlineServiceForExit != null) {
          unawaited(
            outlineSaveChain.value
                .then((_) => outlineServiceForExit.saveOutline(draft))
                .catchError((Object error, StackTrace stackTrace) {
                  _log.error(
                    'Outline exit save failed id=${draft.documentId}',
                    error: error,
                    stackTrace: stackTrace,
                  );
                }),
          );
        }
      },
      [outlineServiceForExit],
    );

    useEffect(() {
      void listener(FocusNode focusNode) {
        if (!focusNode.hasFocus) {
          flushAutoSave();
        }
      }

      final focusNodes = <FocusNode>[
        novelDescriptionFocusNode,
        chapterTitleFocusNode,
        chapterOutlineFocusNode,
        chapterContentFocusNode,
        entryTitleFocusNode,
        entryContentFocusNode,
        foreshadowTitleFocusNode,
        foreshadowSetupFocusNode,
        foreshadowPayoffFocusNode,
      ];
      for (final focusNode in focusNodes) {
        focusNode.addListener(() => listener(focusNode));
      }

      return () {
        // Focus nodes are disposed by hooks; listeners are dropped with them.
      };
    }, const []);

    useEffect(() {
      if (databasePath == null) return null;
      Future<void>(() async {
        if (!context.mounted) {
          return;
        }
        await triggerFeatureOnboardingIfNeeded(
          context,
          ref,
          FeatureOnboardingType.feature_usage,
        );
        if (!context.mounted) {
          return;
        }
        final db = ref.read(appDatabaseProvider);
        final alreadyShown = await db.appStateDao.has(
          appStateKeyChatOnboardingShown,
        );
        if (!alreadyShown &&
            context.mounted &&
            !shouldAutoCollapseAiPanelForWorkspaceSection(
              selection.value.section,
            )) {
          chatOnboardingStep.value = 1;
          aiPanelCollapsed.value = false;
        }
      });
      return null;
    }, [databasePath]);

    final activeCouncilSessionId = switch (contentSelection.value) {
      _EditorAgentCouncilSelection(:final sessionId) => sessionId,
      _ => null,
    };
    final activeTheaterSessionId = switch (contentSelection.value) {
      _EditorTheaterSelection(:final sessionId) => sessionId,
      _ => null,
    };
    final activeMonologueSessionId = switch (contentSelection.value) {
      _EditorMonologueSelection(:final sessionId) => sessionId,
      _ => null,
    };
    final activeRoleplaySessionId = switch (contentSelection.value) {
      _EditorRoleplaySelection(:final sessionId) => sessionId,
      _ => null,
    };
    bool isSessionProcessing(AiSessionMode mode, String? sessionId) {
      if (sessionId == null ||
          sessionId.isEmpty ||
          sessionId.startsWith('__new__') ||
          sessionId.startsWith('__handoff_draft__')) {
        return false;
      }
      return ref.watch(
        aiSessionProcessingProvider(mode: mode, sessionId: sessionId),
      );
    }

    final isActiveModeProcessing =
        isSessionProcessing(
          AiSessionMode.chat,
          chatPanelSessionId ?? activeAiSessionId.value,
        ) ||
        isSessionProcessing(AiSessionMode.council, activeCouncilSessionId) ||
        isSessionProcessing(
          AiSessionMode.monologue,
          activeMonologueSessionId,
        ) ||
        isSessionProcessing(AiSessionMode.theater, activeTheaterSessionId) ||
        isSessionProcessing(AiSessionMode.roleplay, activeRoleplaySessionId);

    useEffect(() {
      isModeRunning.value = isActiveModeProcessing;
      return null;
    }, [isActiveModeProcessing]);

    // 进入关系图谱或地图工作台时自动关闭右侧 chat panel，释放更多屏幕空间。
    useEffect(() {
      if (shouldAutoCollapseAiPanelForWorkspaceSection(
        selection.value.section,
      )) {
        aiPanelCollapsed.value = true;
      }
      return null;
    }, [selection.value.section]);

    final canPop =
        allowLeaveWithRunningAgent.value ||
        (!isAgentEditing.value && !isActiveModeProcessing);

    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || canPop) {
          return;
        }
        unawaited(handleProcessingExit());
      },
      child: Scaffold(
        backgroundColor: appScaffoldBackgroundColor(
          colors,
          ref.watch(appBackgroundActiveProvider),
        ),
        // =============================================================================
        // TitleBarArea (标题栏区)
        // 职责：承载 macOS 红绿灯避让、Windows/Linux 窗口控制按钮、拖拽移动区域
        // 实现：DesktopWindowFrame 统一处理，页面自身不额外注入标题栏按钮
        // =============================================================================
        body: DesktopSaveShortcut(
          onSave: saveDesktopContent,
          child: DesktopWindowFrame(
            titleBarGestureExclusionKeys: [workspaceHeaderToolbarKey],
            child: Builder(
              builder: (context) {
                if (novelAsync.isLoading) {
                  return Center(
                    child: CircularProgressIndicator(
                      color: RevericTheme.colorsOf(context).accent,
                    ),
                  );
                }
                if (novelAsync.hasError) {
                  return NovelEditorLoadErrorState(
                    message: 'Failed to load novel',
                    detail: novelAsync.error.toString(),
                  );
                }
                final novel = novelAsync.asData?.value;
                if (novel == null) {
                  return NovelEditorMissingState(
                    onBack: () {
                      unawaited(attemptLeaveEditorPage());
                    },
                  );
                }
                if (databasePath == null) {
                  return Center(
                    child: CircularProgressIndicator(color: colors.accent),
                  );
                }
                if (!isWorkspaceStateHydrated) {
                  return Center(
                    child: CircularProgressIndicator(color: colors.accent),
                  );
                }

                final chapters =
                    chaptersAsync.asData?.value ?? const <Chapter>[];
                final lastWrittenChapter =
                    lastWrittenChapterAsync.asData?.value;
                final worldbuildingEntries =
                    worldbuildingAsync.asData?.value ?? const <Document>[];
                final outlineEntries =
                    outlinesAsync.asData?.value ?? const <OutlineDraft>[];
                final materialEntries =
                    materialsAsync.asData?.value ?? const <Document>[];
                final characterProfiles =
                    charactersAsync.asData?.value ?? const <CharacterProfile>[];
                final skillEntries =
                    skillsAsync.asData?.value ?? const <Item>[];
                final items = itemsAsync.asData?.value ?? const <Item>[];
                final factionEntries =
                    factionsAsync.asData?.value ?? const <Item>[];
                final creatureEntries =
                    creaturesAsync.asData?.value ?? const <Item>[];
                final foreshadowings =
                    foreshadowingsAsync.asData?.value ??
                    const <Foreshadowing>[];
                final maps = mapsAsync.asData?.value ?? const <NovelMap>[];
                final locations =
                    locationsAsync.asData?.value ?? const <Location>[];

                final selectedWorkspaceChapter =
                    selection.value.section == NovelWorkspaceSection.chapters &&
                        selection.value.itemId != null
                    ? chapters
                          .where(
                            (chapter) => chapter.id == selection.value.itemId,
                          )
                          .firstOrNull
                    : null;
                final selectedChapterId =
                    selectedWorkspaceChapter?.isChapter == true
                    ? selectedWorkspaceChapter!.id
                    : null;
                final chapterTitle = selectedChapterId != null
                    ? chapterTitleController.text
                    : null;
                final isExpandedChatInMain =
                    contentSelection.value is _EditorAiChatExpandedSelection;
                final isCoverStudioActive =
                    contentSelection.value is _EditorCoverStudioSelection;
                // 制片画布和子页面共用浮窗；右栏和浮窗
                // 不会同帧同时挂载同一个 chatPanelKey。
                final isChatFloating =
                    selection.value.section ==
                        NovelWorkspaceSection.storyboard &&
                    contentSelection.value
                        is _EditorWorkspaceContentSelection &&
                    (productionChat.canvas ||
                        ref.watch(productionSubpageProvider(databasePath)) !=
                            null);
                final mainHeaderTrailingInset = isChatFloating
                    ? DesktopWindowFrame.trailingInset
                    : aiPanelCollapsed.value &&
                          !isCoverStudioActive &&
                          !isExpandedChatInMain
                    ? (DesktopWindowFrame.trailingInset -
                              NovelEditorCollapsedAiPanel.width)
                          .clamp(0.0, double.infinity)
                          .toDouble()
                    : 0.0;

                Future<void> createWorkspaceEntry() async {
                  final canCreate = await prepareWorkspaceTransition();
                  if (!canCreate) {
                    return;
                  }
                  await createEntry(novel);
                }

                void navigateToChapter(String chapterId) {
                  unawaited(() async {
                    final canNavigate = await prepareWorkspaceTransition();
                    if (!canNavigate) {
                      return;
                    }
                    showWorkspaceContent();
                    final nextSelection = WorkspaceSelection(
                      section: NovelWorkspaceSection.chapters,
                      itemId: chapterId,
                    );
                    selection.value = nextSelection;
                    triggerWorkspaceOnboarding(nextSelection);
                  }());
                }

                void openEntityGraph() {
                  unawaited(() async {
                    final canNavigate = await prepareWorkspaceTransition();
                    if (!canNavigate) {
                      return;
                    }
                    showWorkspaceContent();
                    final nextSelection = WorkspaceSelection(
                      section: NovelWorkspaceSection.entity_graph,
                    );
                    selection.value = nextSelection;
                    triggerWorkspaceOnboarding(nextSelection);
                  }());
                }

                final characterEditor = CharacterProfileEditorRegion(
                  databasePath: databasePath,
                  selection: selection.value,
                  novel: novel,
                  controller: characterEditorController,
                  nameAssistantAiService: nameAssistantAiService,
                  host: CharacterProfileEditorRegionHost(
                    onCreateCharacter: () {
                      unawaited(createWorkspaceEntry());
                    },
                    onSavingChanged: (saving) {
                      if (context.mounted && isSavingEntry.value != saving) {
                        isSavingEntry.value = saving;
                      }
                    },
                    onGenerateAvatar: generateCharacterAvatar,
                    onGeneratePhoto: generateCharacterPhoto,
                    onNavigateToChapter: navigateToChapter,
                    onOpenEntityGraph: openEntityGraph,
                  ),
                );

                final productionChatNotifier = ref.read(
                  productionChatProvider(novelId).notifier,
                );
                Widget buildChatPanel({
                  required bool floating,
                }) => _buildAiChatPanel(
                  context,
                  key: chatPanelKey,
                  floating: floating,
                  onClose: floating
                      ? () => productionChatNotifier.setOpen(false)
                      : () => aiPanelCollapsed.value = true,
                  novel: novel,
                  selection: selection.value,
                  screenplayWorkspace: screenplayWorkspace,
                  hasMultipleSeasons: hasMultipleScreenplaySeasons,
                  chapterTitleController: chapterTitleController,
                  chapterNumber: chapterNumber,
                  databasePath: databasePath,
                  selectedChapterId: selectedChapterId,
                  onExpandChat: () => unawaited(expandChatFromPanel()),
                  onRequestNewSession: createNewAiChatSession,
                  activeAiSessionId: activeAiSessionId,
                  resolvedActiveAiSessionId: chatPanelSessionId,
                  loading: buildChatLoading,
                  pendingCoverDraft: pendingCoverDraft,
                  pendingHandoffDraft: pendingHandoffDraft,
                  pendingShortcutDraft: pendingShortcutDraft,
                  isAgentEditing: isAgentEditing,
                  currentAiWorkspaceTitle: currentAiWorkspaceTitle,
                  currentAiWorkspaceContent: currentAiWorkspaceContent,
                  currentAiWorkspaceMetaTitle: currentAiWorkspaceMetaTitle,
                  currentAiWorkspaceMetaContent: currentAiWorkspaceMetaContent,
                  applyAiWorkspaceContent: applyAiWorkspaceContent,
                  onSetAsAvatar: setCharacterAvatar,
                  onAddPhoto: handleAddPhotoFromAsset,
                  onOpenSessionReference: openSessionReference,

                  onOpenFeature: openFeatureFromChat,
                  chatOnboardingStep: chatOnboardingStep.value,
                  onAdvanceChatOnboarding: () {
                    if (chatOnboardingStep.value < 3) {
                      chatOnboardingStep.value = chatOnboardingStep.value + 1;
                    }
                  },
                  onDismissChatOnboarding: () {
                    chatOnboardingStep.value = 0;
                    unawaited(() async {
                      final db = ref.read(appDatabaseProvider);
                      await db.appStateDao.set(
                        key: appStateKeyChatOnboardingShown,
                        value: DateTime.now().toIso8601String(),
                      );
                    }());
                  },
                );

                final workspaceContent = NovelWorkspacePanel(
                  productionChat: isChatFloating
                      ? FloatingAiChat(
                          open: productionChat.open,
                          onOpenChanged: productionChatNotifier.setOpen,
                          sessionId: chatPanelSessionId,
                          panel: buildChatPanel(floating: true),
                        )
                      : null,
                  onContinueWriting: (prompt) {
                    aiPanelCollapsed.value = false;
                    pendingHandoffDraft.value = AiChatHandoffDraft(
                      id: 'continue_writing_${DateTime.now().microsecondsSinceEpoch}',
                      label: prompt,
                      title: prompt,
                      content: prompt,
                      initialText: prompt,
                      autoSend: true,
                    );
                  },
                  novel: novel,
                  selection: selection.value,
                  onProductionPrompt:
                      (
                        prompt, {
                        files = const [],
                        send = false,
                        model,
                        effort,
                      }) {
                        if (isChatFloating) {
                          productionChatNotifier.setOpen(true);
                        } else {
                          aiPanelCollapsed.value = false;
                        }
                        // 文本节点输入框选了模型：用它新开对话并直接发送。
                        if (model != null) {
                          pendingHandoffDraft.value = AiChatHandoffDraft(
                            id: 'production_text_${DateTime.now().microsecondsSinceEpoch}',
                            label: '',
                            title: '',
                            content: prompt,
                            initialText: prompt,
                            providerId: model.providerId,
                            model: model.model,
                            reasoningEffort: effort,
                            autoSend: true,
                            files: files,
                          );
                          return;
                        }
                        if (files.isEmpty) {
                          pendingShortcutDraft.value = AiChatShortcutDraft(
                            id: 'production_${DateTime.now().microsecondsSinceEpoch}',
                            text: prompt,
                            autoSend: send,
                          );
                          return;
                        }
                        // 带图的请求来自导演台识图：新开会话并直接发送，不打断正在进行的对话。
                        final title = context.t(
                          LocaleKeys.directorRecognizeTitle,
                        );
                        pendingHandoffDraft.value = AiChatHandoffDraft(
                          id: 'scene_recognition_${DateTime.now().microsecondsSinceEpoch}',
                          label: title,
                          title: title,
                          content: prompt,
                          initialText: prompt,
                          autoSend: true,
                          files: files,
                        );
                      },
                  onRegisterScreenplaySceneFlush: (flush) {
                    screenplaySceneFlush.value = flush;
                  },
                  chapters: chapters,
                  selectedChapterDetails: selectedChapterAsync.asData?.value,
                  lastWrittenChapter: lastWrittenChapter,
                  worldbuildingEntries: worldbuildingEntries,
                  outlineEntries: outlineEntries,
                  selectedOutline: outlineDraft.value,
                  materialEntries: materialEntries,
                  characterProfiles: characterProfiles,
                  skillEntries: skillEntries,
                  items: items,
                  factionEntries: factionEntries,
                  creatureEntries: creatureEntries,
                  locations: locations,
                  foreshadowings: foreshadowings,
                  chapterTitleController: chapterTitleController,
                  chapterOutlineController: chapterOutlineController,
                  chapterOutlineWindowSession: chapterOutlineWindowSession,
                  readingWindowSession: readingWindowSession,
                  chapterContentController: chapterContentController,
                  chapterTitleUndoController: chapterTitleUndoController,
                  chapterOutlineUndoController: chapterOutlineUndoController,
                  chapterContentUndoController: chapterContentUndoController,
                  novelDescriptionController: novelDescriptionController,
                  entryTitleController: entryTitleController,
                  entryContentController: entryContentController,
                  entryCategoryController: entryCategoryController,
                  characterEditor: characterEditor,
                  foreshadowSetupController: foreshadowSetupController,
                  foreshadowPayoffController: foreshadowPayoffController,
                  chapterTitleFocusNode: chapterTitleFocusNode,
                  chapterOutlineFocusNode: chapterOutlineFocusNode,
                  chapterContentFocusNode: chapterContentFocusNode,
                  novelDescriptionFocusNode: novelDescriptionFocusNode,
                  entryTitleFocusNode: entryTitleFocusNode,
                  entryContentFocusNode: entryContentFocusNode,
                  entryCategoryFocusNode: entryCategoryFocusNode,
                  foreshadowTitleFocusNode: foreshadowTitleFocusNode,
                  foreshadowSetupFocusNode: foreshadowSetupFocusNode,
                  foreshadowPayoffFocusNode: foreshadowPayoffFocusNode,
                  chapterAutoSaveFeedback: chapterAutoSaveFeedback,
                  isSavingEntry: isSavingEntry.value,
                  selectedStatus: selectedStatus.value,
                  foreshadowPositions: foreshadowPositions.value,
                  createFieldError: createDraftFieldError.value,
                  entryTitleFieldError: entryTitleFieldError.value,
                  headerLeadingInset: sidebarCollapsed.value
                      ? CollapsedSidebar.contentLeadingInset
                      : 0.0,
                  headerGestureExclusionKey: workspaceHeaderToolbarKey,
                  headerTrailingInset: mainHeaderTrailingInset,
                  // 离开编辑页的返回只保留一个入口：
                  // 展开 + 有中栏 → LeftSidebar；rail-only（概览）→ 本 header；
                  // 折叠 macOS → 浮动按钮；折叠 Windows → 工作区 header。
                  onBack:
                      shouldShowWorkspaceHeaderBack(
                        section: selection.value.section,
                        sidebarCollapsed: sidebarCollapsed.value,
                        isWindows: Platform.isWindows,
                      )
                      ? () {
                          unawaited(attemptLeaveEditorPage());
                        }
                      : null,
                  onSelectionChanged: (nextSelection) async {
                    final canSwitch = await prepareWorkspaceTransition();
                    if (!canSwitch) {
                      return;
                    }
                    entryTitleFieldError.value = null;
                    selection.value = nextSelection;
                    triggerWorkspaceOnboarding(nextSelection);
                  },
                  onCreateEntry: createWorkspaceEntry,
                  onOutlineChanged: (draft) {
                    final previous = outlineDraft.value;
                    outlineDraft.value = draft;
                    pendingOutlineDraft.value = draft;
                    if (outlineBeatsChanged(previous, draft)) {
                      autoSaveTimer.value?.cancel();
                      autoSaveTimer.value = null;
                      unawaited(queueOutlineDraftSave(draft));
                      return;
                    }
                    scheduleAutoSave();
                  },
                  onSaveChapter: () => saveChapter(showSuccess: true),
                  onSaveEntry: () => saveEntry(showSuccess: true),
                  onDiscardCreateDraft: discardCreateDraft,
                  onStatusChanged: (value) {
                    selectedStatus.value = value;
                    scheduleAutoSave();
                  },
                  onForeshadowPositionsChanged: (value) {
                    foreshadowPositions.value = value;
                    scheduleAutoSave();
                  },
                  onOpenCoverStudio: () {
                    unawaited(() async {
                      // 与侧栏封面入口一致：离开工作区前先落盘。
                      if (!await prepareWorkspaceTransition()) {
                        return;
                      }
                      contentSelection.value =
                          const _EditorCoverStudioSelection();
                      aiPanelCollapsed.value = true;
                    }());
                  },
                  onUploadCover: () {
                    unawaited(pickAndUploadCover(novel));
                  },
                  coverThumbnailKey: coverThumbnailKey,
                  coverMenuTrigger: coverMenuTrigger,
                  onEditNovel: () => openEditNovelDialog(novel),
                  canOpenCoverStudio: ref.watch(canOpenCoverStudioProvider),
                  isImageGenerationConfigured: ref.watch(
                    isImageGenerationConfiguredProvider,
                  ),
                  itemPhotos: itemPhotos.value,
                  isItemPhotoAdding: isAddingItemPhoto.value,
                  onAddItemPhoto: addItemPhoto,
                  onRemoveItemPhoto: removeItemPhoto,
                  onGenerateItemPhoto: generateItemPhoto,
                  onViewPendingChanges: showPendingChangesDialog,
                  onViewHistory: showHistoryDialog,
                  databasePath: databasePath,
                  nameAssistantAiService: nameAssistantAiService,
                  editorFontFamily: ref.watch(editorFontFamilyProvider),
                  editorFontSize: ref.watch(editorFontSizeProvider),
                  onNavigateToChapter: navigateToChapter,
                  onRunShortcutAction: runShortcutAction,
                  onAddChapterSelectionToChat: addChapterSelectionToChat,
                );
                final mainContent = switch (contentSelection.value) {
                  _EditorSubAgentSelection(:final agent) => SubAgentEditPanel(
                    agent: agent,
                    novelId: novelId,
                    headerLeadingInset: sidebarCollapsed.value
                        ? CollapsedSidebar.contentLeadingInset
                        : 0.0,
                    headerTrailingInset: mainHeaderTrailingInset,
                    headerGestureExclusionKey: workspaceHeaderToolbarKey,
                    readOnly: false,
                    onSaved: () {
                      showWorkspaceContent();
                      subAgentHasChanges.value = false;
                    },
                    onCancel: cancelSubAgentEdit,
                    onHasChangesChanged: (hasChanges) {
                      subAgentHasChanges.value = hasChanges;
                    },
                    onRegisterSave: (save) => activeAgentPanelSave.value = save,
                  ),
                  _EditorAgentRulesListSelection() => AgentRulesGridPage(
                    databasePath: databasePath,
                    headerGestureExclusionKey: workspaceHeaderToolbarKey,
                    onBack: () {
                      unawaited(attemptLeaveEditorPage());
                    },
                    onOpen: (rule) async {
                      final canSwitch = await prepareWorkspaceTransition();
                      if (!canSwitch) {
                        return;
                      }
                      contentSelection.value = _EditorAgentRuleSelection(rule);
                    },
                    onCreate: () async {
                      final canSwitch = await prepareWorkspaceTransition();
                      if (!canSwitch) {
                        return;
                      }
                      contentSelection.value = _EditorAgentRuleSelection(
                        newAgentRuleDraft(),
                      );
                    },
                  ),
                  _EditorAgentRuleSelection(:final rule) => AgentRuleEditPanel(
                    rule: rule,
                    databasePath: databasePath,
                    headerLeadingInset: sidebarCollapsed.value
                        ? CollapsedSidebar.contentLeadingInset
                        : 0.0,
                    headerTrailingInset: mainHeaderTrailingInset,
                    headerGestureExclusionKey: workspaceHeaderToolbarKey,
                    onBack: () async {
                      if (await prepareWorkspaceTransition()) {
                        contentSelection.value =
                            const _EditorAgentRulesListSelection();
                      }
                    },
                    onSaved: () {
                      contentSelection.value =
                          const _EditorAgentRulesListSelection();
                      agentRuleHasChanges.value = false;
                    },
                    onCancel: () {
                      contentSelection.value =
                          const _EditorAgentRulesListSelection();
                      agentRuleHasChanges.value = false;
                    },
                    onHasChangesChanged: (hasChanges) {
                      agentRuleHasChanges.value = hasChanges;
                    },
                    onRegisterSave: (save) => activeAgentPanelSave.value = save,
                    onRegisterHasChanges: (hasChanges) =>
                        activeAgentPanelHasChanges.value = hasChanges,
                    onRegisterIsBlankCreateDraft: (isBlank) =>
                        activeAgentPanelIsBlankCreateDraft.value = isBlank,
                    onSaveRule: (draft) => _saveAgentRuleEditDraft(
                      ref: ref,
                      databasePath: databasePath,
                      draft: draft,
                    ),
                    onRuleSaved: (savedRule) {
                      contentSelection.value = _EditorAgentRuleSelection(
                        savedRule,
                      );
                      agentRuleHasChanges.value = false;
                    },
                  ),
                  _EditorAgentCouncilSelection() ||
                  _EditorMonologueSelection() ||
                  _EditorTheaterSelection() ||
                  _EditorRoleplaySelection() => _buildAgentModeArea(
                    selection: contentSelection.value,
                    novel: novel,
                    chapterTitle: chapterTitle,
                    databasePath: databasePath,
                    currentAiWorkspaceContent: currentAiWorkspaceContent,
                    actions: _AgentModeActions(
                      showWorkspaceContent: showWorkspaceContent,
                      aiPanelCollapsed: aiPanelCollapsed,
                      activeAiSessionId: activeAiSessionId,
                      pendingHandoffDraft: pendingHandoffDraft,
                      contentSelection: contentSelection,
                    ),
                  ),
                  _EditorAiChatExpandedSelection() => Consumer(
                    builder: (context, ref, _) {
                      // pendingAiChanges 只在 expanded chat（编辑器不挂载）使用，
                      // 在此局部订阅 workingChanges，避免顶层 NovelEditorPage 因工具
                      // 写入而整体重建、连坐 ChapterEditor。
                      final currentSessionId = activeAiSessionId.value;
                      final pendingAiChanges =
                          (ref
                              .watch(
                                sessionChangesProvider(
                                  databasePath,
                                  currentSessionId,
                                ),
                              )
                              .asData
                              ?.value ??
                          const <WorkingChange>[]);
                      if (chatPanelSessionId == null) {
                        return buildChatLoading();
                      }
                      return ExpandedChatArea(
                        onCollapse: showWorkspaceContent,
                        novel: novel,
                        // 快速开书草稿：输入框提示用户直接说想写什么。
                        composerHint: novel.draft
                            ? context.t(LocaleKeys.libraryQuickStartChatHint)
                            : null,
                        chapterId: selectedChapterId,
                        chapterTitle: chapterTitle,
                        chapterNumber: selectedChapterId != null
                            ? chapterNumber.value
                            : null,
                        databasePath: databasePath,
                        workspaceSection: selection.value.section,
                        workspaceItemId: selection.value.itemId,
                        workspaceTitle: currentAiWorkspaceTitle(),
                        workspaceContent: currentAiWorkspaceContent(),
                        workspaceMetaTitle: currentAiWorkspaceMetaTitle(
                          context,
                        ),
                        workspaceMetaContent: currentAiWorkspaceMetaContent(),
                        onApplyGeneratedContent:
                            selection.value.section.isReadOnly
                            ? null
                            : applyAiWorkspaceContent,
                        onSetAsAvatar: setCharacterAvatar,
                        onAddPhoto: handleAddPhotoFromAsset,
                        activeSessionId: chatPanelSessionId,
                        draftMessage: pendingCoverDraft.value,
                        handoffDraft: pendingHandoffDraft.value,
                        onRequestHandoff: (draft) =>
                            pendingHandoffDraft.value = draft,
                        shortcutDraft: pendingShortcutDraft.value,
                        onHandoffDraftConsumed: (id) {
                          if (pendingHandoffDraft.value?.id == id) {
                            pendingHandoffDraft.value = null;
                          }
                        },
                        onShortcutDraftConsumed: (id) {
                          if (pendingShortcutDraft.value?.id == id) {
                            pendingShortcutDraft.value = null;
                          }
                        },
                        onRequestNewSession: () async {
                          await createNewAiChatSession();
                        },
                        onEditingStateChanged: (isEditing) {
                          isAgentEditing.value = isEditing;
                        },
                        onSessionRestored: (sessionId) {
                          activeAiSessionId.value = sessionId;
                        },
                        onActiveSessionIdChanged: (sessionId) async {
                          activeAiSessionId.value = sessionId;
                        },
                        onOpenSessionReference: openSessionReference,

                        onOpenFeature: openFeatureFromChat,
                        // agent turn 未完成时不展示待处理变更摘要，等本轮结束再显示。
                        pendingAiChanges: isAgentEditing.value
                            ? const <WorkingChange>[]
                            : pendingAiChanges,
                      );
                    },
                  ),
                  _EditorCoverStudioSelection() => CoverStudio(
                    novel: novel,
                    databasePath: databasePath,
                    onApply: (assetId) async {
                      await updateNovelCover(
                        novel,
                        assetId: assetId,
                        showSuccess: true,
                      );
                    },
                  ),
                  _EditorWorkspaceContentSelection() => workspaceContent,
                };

                // Anchor 挂在编辑页级：Main 切到 AI 沉浸/Agent 等时 NovelWorkspacePanel
                // 会卸掉；若 Window 宿主跟着卸掉，独立窗口只剩最后一帧、无法交互。
                return ChapterOutlineWindowAnchor(
                  session: chapterOutlineWindowSession,
                  child: Stack(
                    children: [
                      // 原著阅读窗口不依附具体区域，只需一个常驻宿主。
                      ReadingWindowAnchor(
                        session: readingWindowSession,
                        child: const SizedBox.shrink(),
                      ),
                      // 页面主布局区 (Page Layout Area)
                      // 四栏布局：Rail | Middle Column | Main | Chat Panel
                      // =============================================================================
                      LayoutBuilder(
                        builder: (context, constraints) {
                          const minimumRailWidth = 96.0;
                          const maximumRailWidth = 220.0;
                          const minimumMiddleColumnWidth = 180.0;
                          const maximumSidebarWidth = 560.0;
                          const minimumAiPanelWidth = 280.0;
                          const maximumAiPanelWidth = 560.0;
                          const minimumMainWidth = 480.0;

                          double clampWidth(
                            double value, {
                            required double minimum,
                            required double maximum,
                          }) {
                            final resolvedMaximum = maximum < minimum
                                ? minimum
                                : maximum;
                            return value
                                .clamp(minimum, resolvedMaximum)
                                .toDouble();
                          }

                          final layout =
                              draggingPaneLayout.value ?? persistedPaneLayout;
                          final isRailOnly = _isRailOnlySidebarWidth(
                            selection.value,
                            contentSelection.value,
                          );
                          final isAiPanelResizable =
                              !isExpandedChatInMain &&
                              !isCoverStudioActive &&
                              !isChatFloating &&
                              !aiPanelCollapsed.value;
                          final requestedRailWidth = clampWidth(
                            layout.railWidth,
                            minimum: minimumRailWidth,
                            maximum: maximumRailWidth,
                          );
                          final requestedSidebarWidth = isRailOnly
                              ? requestedRailWidth
                              : clampWidth(
                                  layout.sidebarWidth,
                                  minimum:
                                      requestedRailWidth +
                                      minimumMiddleColumnWidth +
                                      ResizablePaneDivider.width,
                                  maximum: maximumSidebarWidth,
                                );
                          final outerDividerWidth = sidebarCollapsed.value
                              ? RevericSizes.dividerThickness
                              : ResizablePaneDivider.width;
                          final aiPanelWidth = isAiPanelResizable
                              ? clampWidth(
                                  layout.aiPanelWidth,
                                  minimum: minimumAiPanelWidth,
                                  maximum: maximumAiPanelWidth,
                                )
                              : 0.0;
                          final visibleAiAreaWidth =
                              isExpandedChatInMain || isChatFloating
                              ? 0.0
                              : isAiPanelResizable
                              ? aiPanelWidth + ResizablePaneDivider.width
                              : NovelEditorCollapsedAiPanel.width;
                          final maximumSidebarForWindow =
                              constraints.maxWidth -
                              visibleAiAreaWidth -
                              outerDividerWidth -
                              minimumMainWidth;
                          final sidebarWidth = sidebarCollapsed.value
                              ? CollapsedSidebar.width
                              : clampWidth(
                                  requestedSidebarWidth,
                                  minimum: isRailOnly
                                      ? minimumRailWidth
                                      : requestedRailWidth +
                                            minimumMiddleColumnWidth +
                                            ResizablePaneDivider.width,
                                  maximum: maximumSidebarForWindow,
                                );
                          final railWidth = isRailOnly
                              ? clampWidth(
                                  requestedRailWidth,
                                  minimum: minimumRailWidth,
                                  maximum: sidebarWidth,
                                )
                              : clampWidth(
                                  requestedRailWidth,
                                  minimum: minimumRailWidth,
                                  maximum:
                                      sidebarWidth -
                                      minimumMiddleColumnWidth -
                                      ResizablePaneDivider.width,
                                );

                          void updateDraggingLayout(
                            NovelEditorPaneLayout next,
                          ) {
                            draggingPaneLayout.value = next;
                          }

                          void persistDraggingLayout() {
                            final next = draggingPaneLayout.value;
                            if (next == null) {
                              return;
                            }
                            draggingPaneLayout.value = null;
                            unawaited(
                              ref
                                  .read(novelEditorPaneLayoutProvider.notifier)
                                  .save(next),
                            );
                          }

                          void resizeRail(double delta) {
                            final current =
                                draggingPaneLayout.value ?? persistedPaneLayout;
                            final maximum = isRailOnly
                                ? sidebarWidth
                                : sidebarWidth -
                                      minimumMiddleColumnWidth -
                                      ResizablePaneDivider.width;
                            updateDraggingLayout(
                              current.copyWith(
                                railWidth: clampWidth(
                                  current.railWidth + delta,
                                  minimum: minimumRailWidth,
                                  maximum: maximum,
                                ),
                              ),
                            );
                          }

                          void resizeSidebar(double delta) {
                            final current =
                                draggingPaneLayout.value ?? persistedPaneLayout;
                            if (isRailOnly) {
                              resizeRail(delta);
                              return;
                            }
                            updateDraggingLayout(
                              current.copyWith(
                                sidebarWidth: clampWidth(
                                  current.sidebarWidth + delta,
                                  minimum:
                                      railWidth +
                                      minimumMiddleColumnWidth +
                                      ResizablePaneDivider.width,
                                  maximum: maximumSidebarForWindow,
                                ),
                              ),
                            );
                          }

                          void resizeAiPanel(double delta) {
                            final current =
                                draggingPaneLayout.value ?? persistedPaneLayout;
                            final maximum =
                                constraints.maxWidth -
                                sidebarWidth -
                                outerDividerWidth -
                                minimumMainWidth -
                                ResizablePaneDivider.width;
                            updateDraggingLayout(
                              current.copyWith(
                                aiPanelWidth: clampWidth(
                                  current.aiPanelWidth - delta,
                                  minimum: minimumAiPanelWidth,
                                  maximum: maximum,
                                ),
                              ),
                            );
                          }

                          // Drag 期间必须瞬时贴合目标宽度。AnimatedSize 不能用
                          // Duration.zero：零时长 controller 会在 performLayout
                          // 内同步通知 listener 并 markNeedsLayout，触发框架断言。
                          final sidebarDividerLink = LayerLink();
                          final aiDividerLink = LayerLink();
                          final aiArea = _buildAiArea(
                            selection: selection.value,
                            contentSelection: contentSelection.value,
                            aiPanelCollapsed: aiPanelCollapsed,
                            isExpandedChatInMain: isExpandedChatInMain,
                            isChatFloating: isChatFloating,
                            panelWidth: aiPanelWidth,
                            buildLeadingDivider: () =>
                                ResizablePaneDividerAnchor(link: aiDividerLink),
                            buildChatPanel: () =>
                                buildChatPanel(floating: false),
                          );
                          final sizedAiArea = draggingPaneLayout.value != null
                              ? aiArea
                              : AnimatedSize(
                                  duration: _aiAreaMotionDuration,
                                  reverseDuration: _aiAreaCollapseDuration,
                                  curve: Curves.easeOutCubic,
                                  alignment: Alignment.centerRight,
                                  clipBehavior: Clip.hardEdge,
                                  child: aiArea,
                                );

                          final panes = Row(
                            children: [
                              // ─────────────────────────────────────────────────────────────────────────────
                              // Rail + Middle Column (侧栏窄轨 + 导航中栏)
                              // Rail: 48px 窄轨，始终可见，图标导航 + 展开/折叠按钮
                              // Middle Column: 可折叠，NovelNavArea + WorkspaceNavArea
                              // 状态：sidebarCollapsed 时 Middle Column 隐藏 (IgnorePointer + 动画缩窄)
                              // ─────────────────────────────────────────────────────────────────────────────
                              AnimatedContainer(
                                duration: draggingPaneLayout.value == null
                                    ? const Duration(milliseconds: 200)
                                    : Duration.zero,
                                curve: Curves.easeInOut,
                                width: sidebarWidth,
                                clipBehavior: Clip.hardEdge,
                                decoration: BoxDecoration(
                                  color: appSidebarBackgroundColor(
                                    colors,
                                    appBackgroundActive,
                                  ),
                                ),
                                // ───────────────────────────────────────────────────────────────────────────
                                // LeftSidebar (左侧导航)
                                // 包含：NovelNavArea (小说导航)、WorkspaceNavArea (工作区导航)、SubAgentArea (智能体)
                                // 折叠态仅构建 rail，避免动画期间继续 layout/paint 右侧 panel。
                                // ───────────────────────────────────────────────────────────────────────────
                                child: LeftSidebar(
                                  onBack: () {
                                    unawaited(attemptLeaveEditorPage());
                                  },
                                  isCollapsed: sidebarCollapsed.value,
                                  expandedRailWidth: railWidth,
                                  sidebarWidth: sidebarWidth,
                                  onRailWidthDragUpdate: resizeRail,
                                  onRailWidthDragEnd: persistDraggingLayout,
                                  novelTitle: novel.title,
                                  coverAssetId: novel.coverAssetId,
                                  currentNovelId: novel.id,
                                  databasePath: databasePath,
                                  contentKind: novel.contentKind,
                                  onPrepareWorkspaceTransition:
                                      prepareWorkspaceTransition,
                                  selection: selection.value,
                                  onOpenCoverStudio: () {
                                    unawaited(() async {
                                      final canSwitch =
                                          await prepareWorkspaceTransition();
                                      if (!canSwitch) {
                                        return;
                                      }
                                      contentSelection.value =
                                          const _EditorCoverStudioSelection();
                                      aiPanelCollapsed.value = true;
                                    }());
                                  },
                                  isCoverStudioActive: isCoverStudioActive,
                                  chapters: chapters,
                                  worldbuildingEntries: worldbuildingEntries,
                                  outlineEntries: outlineEntries,
                                  materialEntries: materialEntries,
                                  characterProfiles: characterProfiles,
                                  skillEntries: skillEntries,
                                  items: items,
                                  factionEntries: factionEntries,
                                  creatureEntries: creatureEntries,
                                  foreshadowings: foreshadowings,
                                  maps: maps,
                                  locations: locations,
                                  onSelect: (nextSelection) async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    showWorkspaceContent();
                                    selection.value = nextSelection;
                                    if (nextSelection.section ==
                                        NovelWorkspaceSection.entity_graph) {
                                      aiPanelCollapsed.value = true;
                                    }
                                    triggerWorkspaceOnboarding(nextSelection);
                                  },
                                  onEditDetails: () =>
                                      openEditNovelDialog(novel),
                                  onCreateChapter: () async {
                                    final canCreate =
                                        await prepareWorkspaceTransition();
                                    if (!canCreate) {
                                      return;
                                    }
                                    showWorkspaceContent();
                                    final createdId = await createChapter(
                                      novel,
                                    );
                                    if (createdId != null) {
                                      selection.value = WorkspaceSelection(
                                        section: NovelWorkspaceSection.chapters,
                                        itemId: createdId,
                                      );
                                      triggerWorkspaceOnboarding(
                                        selection.value,
                                      );
                                    }
                                  },
                                  onCreateVolume: () async {
                                    final canCreate =
                                        await prepareWorkspaceTransition();
                                    if (!canCreate) {
                                      return;
                                    }
                                    showWorkspaceContent();
                                    final createdId = await createVolume(novel);
                                    if (createdId != null) {
                                      selection.value = WorkspaceSelection(
                                        section: NovelWorkspaceSection.chapters,
                                        itemId: createdId,
                                      );
                                      triggerWorkspaceOnboarding(
                                        selection.value,
                                      );
                                    }
                                  },
                                  onCreateChapterInVolume: (volumeId) async {
                                    final canCreate =
                                        await prepareWorkspaceTransition();
                                    if (!canCreate) {
                                      return;
                                    }
                                    showWorkspaceContent();
                                    final createdId =
                                        await createChapterInVolume(
                                          novel,
                                          volumeId,
                                        );
                                    if (createdId != null) {
                                      selection.value = WorkspaceSelection(
                                        section: NovelWorkspaceSection.chapters,
                                        itemId: createdId,
                                      );
                                      triggerWorkspaceOnboarding(
                                        selection.value,
                                      );
                                    }
                                  },
                                  onCollapse: () =>
                                      sidebarCollapsed.value = true,
                                  onExpand: () =>
                                      sidebarCollapsed.value = false,
                                  onSwitchNovel: (selectedNovel) {
                                    unawaited(switchToNovel(selectedNovel.id));
                                  },
                                  onCreateFolder: (section) async {
                                    final canCreate =
                                        await prepareWorkspaceTransition();
                                    if (!canCreate) {
                                      return;
                                    }
                                    showWorkspaceContent();
                                    await createFolder(novel, section);
                                  },
                                  onCreateDocument: (section) async {
                                    final canCreate =
                                        await prepareWorkspaceTransition();
                                    if (!canCreate) {
                                      return;
                                    }
                                    showWorkspaceContent();
                                    await createEntry(novel, section);
                                  },
                                  onImportOutline: importOutline,
                                  onImportDocument: (section, parentId) async {
                                    final type = switch (section) {
                                      NovelWorkspaceSection.lore =>
                                        documentTypeLore,
                                      NovelWorkspaceSection.materials =>
                                        documentTypeMaterial,
                                      _ => null,
                                    };
                                    if (type == null) return;
                                    await importEntry(type, parentId);
                                  },
                                  onCreateFolderInParent: (parentId) async {
                                    final canCreate =
                                        await prepareWorkspaceTransition();
                                    if (!canCreate) {
                                      return;
                                    }
                                    showWorkspaceContent();
                                    selection.value = WorkspaceSelection(
                                      section: selection.value.section,
                                      itemId: parentId,
                                    );
                                    await createFolder(novel);
                                  },
                                  onCreateDocumentInParent: (parentId) async {
                                    final canCreate =
                                        await prepareWorkspaceTransition();
                                    if (!canCreate) {
                                      return;
                                    }
                                    showWorkspaceContent();
                                    selection.value = WorkspaceSelection(
                                      section: selection.value.section,
                                      itemId: parentId,
                                    );
                                    await createEntry(novel);
                                  },
                                  onDeleteDocument: (documentId) async {
                                    final path = databasePath;

                                    final service = ref.read(
                                      novelContentServiceProvider(path),
                                    );
                                    final doc = await service.documentsService
                                        .getDocumentById(documentId);

                                    if (doc != null && doc.isFolder) {
                                      await service.documentsService
                                          .deleteDocumentRecursive(documentId);
                                    } else {
                                      await service.documentsService
                                          .deleteDocument(documentId);
                                    }

                                    if (!context.mounted) {
                                      return;
                                    }
                                    if (selection.value.itemId == documentId) {
                                      selection.value = WorkspaceSelection(
                                        section: selection.value.section,
                                      );
                                    }
                                  },
                                  onRenameDocument:
                                      (documentId, newTitle, {category}) async {
                                        final path = databasePath;

                                        final service = ref.read(
                                          novelContentServiceProvider(path),
                                        );
                                        final doc = await service
                                            .documentsService
                                            .getDocumentById(documentId);

                                        if (doc == null) {
                                          return;
                                        }
                                        try {
                                          await service.documentsService
                                              .updateDocument(
                                                id: documentId,
                                                title: newTitle,
                                                content: doc.content,
                                                category: category,
                                              );
                                        } on ArgumentError {
                                          rethrow;
                                        } catch (error, stackTrace) {
                                          _log.error(
                                            '[DB] table=documents op=UPDATE '
                                            'id=$documentId',
                                            error: error,
                                            stackTrace: stackTrace,
                                          );
                                          rethrow;
                                        }
                                        if (!context.mounted) {
                                          return;
                                        }
                                        if (selection.value.itemId !=
                                            documentId) {
                                          return;
                                        }
                                        isSyncingControllerText.value = true;
                                        try {
                                          entryTitleController.text = newTitle;
                                          if (category != null) {
                                            entryCategoryController.text =
                                                category;
                                          }
                                        } finally {
                                          isSyncingControllerText.value = false;
                                        }
                                      },
                                  onDeleteItem: (section, itemId) async {
                                    final path = databasePath;
                                    final service = ref.read(
                                      novelContentServiceProvider(path),
                                    );
                                    // 侧边栏中通过 onDeleteItem 删除的 section 必须在这里显式分派。
                                    // 新增 workspace 页面若复用 onDeleteItem，必须补充对应 case；
                                    // 文档、章节、地图地点分别走 onDeleteDocument/onDeleteChapter/地图删除回调。
                                    switch (section) {
                                      case NovelWorkspaceSection.outlines:
                                        await service.outlineService
                                            .deleteOutline(itemId);
                                        if (!context.mounted) {
                                          return;
                                        }
                                        if (selection.value.itemId == itemId) {
                                          outlineDraft.value = null;
                                          selection.value = WorkspaceSelection(
                                            section: section,
                                          );
                                        }
                                      case NovelWorkspaceSection.characters:
                                        await service.deleteCharacterProfile(
                                          itemId,
                                        );
                                        if (!context.mounted) {
                                          return;
                                        }
                                        if (selection.value.itemId == itemId) {
                                          selection.value = WorkspaceSelection(
                                            section: section,
                                          );
                                        }
                                      case NovelWorkspaceSection.foreshadowings:
                                        await service.deleteForeshadowing(
                                          itemId,
                                        );
                                        if (!context.mounted) {
                                          return;
                                        }
                                        if (selection.value.itemId == itemId) {
                                          selection.value = WorkspaceSelection(
                                            section: section,
                                          );
                                        }
                                      case NovelWorkspaceSection.skills:
                                      case NovelWorkspaceSection.items:
                                      case NovelWorkspaceSection.factions:
                                      case NovelWorkspaceSection.creatures:
                                        await service.deleteItem(itemId);
                                        if (!context.mounted) {
                                          return;
                                        }
                                        if (selection.value.itemId == itemId) {
                                          selection.value = WorkspaceSelection(
                                            section: section,
                                          );
                                        }
                                      default:
                                    }
                                  },
                                  onDeleteChapter: (chapterId) async {
                                    final path = databasePath;
                                    final service = ref.read(
                                      novelContentServiceProvider(path),
                                    );
                                    final deletingIds = {
                                      chapterId,
                                      for (final chapter in chapters)
                                        if (chapter.parentId == chapterId)
                                          chapter.id,
                                    };
                                    await service.deleteChapter(chapterId);
                                    if (!context.mounted) {
                                      return;
                                    }
                                    if (deletingIds.contains(
                                      selection.value.itemId,
                                    )) {
                                      // 删除当前打开的章节后，选中视觉上顶替其位置的邻章，
                                      // 而不是跳到列表首章。倒序时顶替位置的是「上一章」，
                                      // 正序时是「下一章」；该侧找不到再退到另一侧。
                                      final descending = ref.read(
                                        chapterSortDescendingProvider,
                                      );
                                      final deletedIndex = chapters.indexWhere(
                                        (c) => c.id == chapterId,
                                      );
                                      Chapter? neighbor;
                                      if (deletedIndex != -1) {
                                        final forward = descending ? -1 : 1;
                                        for (final step in [
                                          forward,
                                          -forward,
                                        ]) {
                                          for (
                                            var i = deletedIndex + step;
                                            i >= 0 && i < chapters.length;
                                            i += step
                                          ) {
                                            if (!deletingIds.contains(
                                              chapters[i].id,
                                            )) {
                                              neighbor = chapters[i];
                                              break;
                                            }
                                          }
                                          if (neighbor != null) {
                                            break;
                                          }
                                        }
                                      }
                                      neighbor ??= chapters
                                          .where(
                                            (c) => !deletingIds.contains(c.id),
                                          )
                                          .firstOrNull;
                                      selection.value = neighbor == null
                                          ? const WorkspaceSelection(
                                              section: NovelWorkspaceSection
                                                  .chapters,
                                            )
                                          : WorkspaceSelection(
                                              section: NovelWorkspaceSection
                                                  .chapters,
                                              itemId: neighbor.id,
                                            );
                                    }
                                  },
                                  onMoveToVolume: (chapterId, volumeId) async {
                                    final path = databasePath;
                                    await ref
                                        .read(novelContentServiceProvider(path))
                                        .moveToVolume(chapterId, volumeId);
                                  },
                                  onUpdateChapterStat: (chapterId, stat) async {
                                    final path = databasePath;
                                    await ref
                                        .read(novelContentServiceProvider(path))
                                        .updateChapterStat(
                                          chapterId: chapterId,
                                          stat: stat,
                                        );
                                  },
                                  onPublishChapter: onPublishChapter,
                                  aiChatSessions: aiChatSessions,
                                  activeAiChatSessionId: chatPanelSessionId,
                                  hasMoreAiChatSessions: hasMoreAiChatSessions,
                                  isLoadingMoreAiChatSessions:
                                      isLoadingMoreAiChatSessions.value,
                                  onLoadMoreAiChatSessions:
                                      loadMoreAiChatSessions,
                                  onSelectAiChatSession: (sessionId) async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    activeAiSessionId.value = sessionId;
                                    openExpandedChat();
                                  },
                                  onContinueAiChatSession: (sessionId) {
                                    aiPanelCollapsed.value = false;
                                    pendingHandoffDraft.value =
                                        AiChatHandoffDraft.continuationRequest(
                                          sessionId,
                                        );
                                  },
                                  onCreateAiChatSession: () async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    if (!await createNewAiChatSession()) {
                                      return;
                                    }
                                    openExpandedChat();
                                  },
                                  onDeleteAiChatSession: (sessionId) async {
                                    await ref
                                        .read(
                                          aiSessionPersistenceServiceProvider(
                                            novelId: novelId,
                                            databasePath: databasePath,
                                          ),
                                        )
                                        .deleteSession(sessionId);
                                    if (chatPanelSessionId == sessionId ||
                                        activeAiSessionId.value == sessionId) {
                                      final remainingSessions = aiChatSessions
                                          .where(
                                            (session) =>
                                                session.id != sessionId,
                                          );
                                      activeAiSessionId.value =
                                          pickPreferredAiChatSession(
                                            remainingSessions,
                                          )?.id;
                                    }
                                  },
                                  onSelectSubAgent: (SubAgent agent) async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    contentSelection.value =
                                        _EditorSubAgentSelection(agent);
                                  },
                                  selectedSubAgentId: switch (contentSelection
                                      .value) {
                                    _EditorSubAgentSelection(:final agent) =>
                                      agent.id,
                                    _ => null,
                                  },
                                  onShowAgentRules: () async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    contentSelection.value =
                                        const _EditorAgentRulesListSelection();
                                  },
                                  onOpenAgentCouncil: () async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    openAgentMode(
                                      const _EditorAgentCouncilSelection(),
                                    );
                                  },
                                  onOpenCouncilWithSession: (sessionId) async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    openAgentMode(
                                      _EditorAgentCouncilSelection(
                                        sessionId: sessionId,
                                      ),
                                    );
                                  },
                                  onOpenMonologue: () async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    openAgentMode(
                                      const _EditorMonologueSelection(),
                                    );
                                  },
                                  onOpenMonologueWithSession:
                                      (sessionId) async {
                                        final canSwitch =
                                            await prepareWorkspaceTransition();
                                        if (!canSwitch) {
                                          return;
                                        }
                                        openAgentMode(
                                          _EditorMonologueSelection(
                                            sessionId: sessionId,
                                          ),
                                        );
                                      },
                                  onOpenTheater: () async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    openAgentMode(
                                      const _EditorTheaterSelection(),
                                    );
                                  },
                                  onOpenTheaterWithSession: (sessionId) async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    openAgentMode(
                                      _EditorTheaterSelection(
                                        sessionId: sessionId,
                                      ),
                                    );
                                  },
                                  onOpenRoleplay: () async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    openAgentMode(
                                      const _EditorRoleplaySelection(),
                                    );
                                  },
                                  onOpenRoleplayWithSession: (sessionId) async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    openAgentMode(
                                      _EditorRoleplaySelection(
                                        sessionId: sessionId,
                                      ),
                                    );
                                  },
                                  onOpenMonologueWithId: (characterId) async {
                                    final canSwitch =
                                        await prepareWorkspaceTransition();
                                    if (!canSwitch) {
                                      return;
                                    }
                                    openAgentMode(
                                      _EditorMonologueSelection(
                                        initialCharacterId: characterId,
                                      ),
                                    );
                                  },
                                  isWorkspaceContentActive:
                                      contentSelection.value
                                          is _EditorWorkspaceContentSelection,
                                  isAgentCouncilActive:
                                      contentSelection.value
                                          is _EditorAgentCouncilSelection,
                                  isAiChatExpandedActive:
                                      contentSelection.value
                                          is _EditorAiChatExpandedSelection,
                                  isMonologueActive:
                                      contentSelection.value
                                          is _EditorMonologueSelection,
                                  isTheaterActive:
                                      contentSelection.value
                                          is _EditorTheaterSelection,
                                  isRoleplayActive:
                                      contentSelection.value
                                          is _EditorRoleplaySelection,
                                  isAgentRulesActive:
                                      switch (contentSelection.value) {
                                        _EditorAgentRulesListSelection() ||
                                        _EditorAgentRuleSelection() => true,
                                        _ => false,
                                      },
                                  activeCouncilSessionId:
                                      activeCouncilSessionId,
                                  activeTheaterSessionId:
                                      activeTheaterSessionId,
                                  activeMonologueSessionId:
                                      activeMonologueSessionId,
                                  activeRoleplaySessionId:
                                      activeRoleplaySessionId,
                                ),
                              ),
                              // ─────────────────────────────────────────────────────────────────────────────
                              // 侧边栏与主内容分隔线
                              // ─────────────────────────────────────────────────────────────────────────────
                              if (sidebarCollapsed.value)
                                NovelEditorSidebarDivider(skipTopInset: true)
                              else
                                ResizablePaneDividerAnchor(
                                  link: sidebarDividerLink,
                                ),
                              // ─────────────────────────────────────────────────────────────────────────────
                              // Main (主内容区)
                              // 职责：switch(contentSelection) 显示 11 种编辑面板之一
                              // 子区域：WorkspaceContentArea / AgentProfileEditArea / SubAgentEditArea /
                              //        SkillEditArea / AgentRuleEditArea / CouncilArea / MonologueArea /
                              //        TheaterArea / RoleplayArea / ExpandedChatArea
                              // ─────────────────────────────────────────────────────────────────────────────
                              Expanded(
                                child: RepaintBoundary(child: mainContent),
                              ),
                              // ─────────────────────────────────────────────────────────────────────────────
                              // Chat Panel (AI 聊天面板区)
                              // 职责：AI 聊天、折叠窄条；封面工作台在 Main 中展示
                              // 状态：按优先级: ExpandedChatArea 在 Main→整列隐藏 >
                              //       CoverStudioSelection→Main CoverStudio > !aiPanelCollapsed→AiChatPanel >
                              //       默认→NovelEditorCollapsedAiPanel
                              // ─────────────────────────────────────────────────────────────────────────────
                              RepaintBoundary(child: sizedAiArea),
                            ],
                          );
                          return Stack(
                            children: [
                              panes,
                              if (!sidebarCollapsed.value)
                                ResizablePaneDivider(
                                  link: sidebarDividerLink,
                                  onDragUpdate: resizeSidebar,
                                  onDragEnd: persistDraggingLayout,
                                ),
                              if (isAiPanelResizable)
                                ResizablePaneDivider(
                                  link: aiDividerLink,
                                  onDragUpdate: resizeAiPanel,
                                  onDragEnd: persistDraggingLayout,
                                ),
                            ],
                          );
                        },
                      ),
                      if (sidebarCollapsed.value && !Platform.isWindows)
                        Positioned(
                          left:
                              DesktopWindowFrame.sidebarLeadingInset +
                              RevericSpacing.sm,
                          top: DesktopWindowFrame.captionSafeTopInset,
                          height: DesktopWindowFrame.titleBarHeight,
                          child: NovelEditorCollapsedSidebarBackButton(
                            onTap: () {
                              unawaited(attemptLeaveEditorPage());
                            },
                          ),
                        ),
                      // 快速开书草稿：顶部悬浮「加入书架」条，清 draft 后作品才进书库。
                      if (novel.draft)
                        Positioned(
                          top:
                              DesktopWindowFrame.titleBarHeight +
                              RevericSpacing.md,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: NovelEditorAddToLibraryBanner(
                              onAdd: () async {
                                final messenger = ScaffoldMessenger.of(context);
                                final container = ProviderScope.containerOf(
                                  context,
                                  listen: false,
                                );
                                final chatSessionId = activeAiSessionId.value;
                                try {
                                  await ref
                                      .read(novelActionsProvider)
                                      .clearNovelDraft(novel.id);
                                } on NovelTitleConflictException catch (error) {
                                  if (!context.mounted) {
                                    return;
                                  }
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        context.t(
                                          LocaleKeys.libraryDuplicateName,
                                          namedArgs: {'name': error.title},
                                        ),
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                // 人手点「加入书架」AI 看不到，投一条 cleared remind
                                // 让创作向导知道草稿已入库、无需再问加入书架。
                                if (chatSessionId != null &&
                                    !isTemporaryAiChatSessionId(
                                      chatSessionId,
                                    )) {
                                  deliverSystemRemindToSession(
                                    container,
                                    chatSessionId,
                                    novelDraftRemindCleared,
                                    kind: novelDraftRemindKind,
                                  );
                                }
                                if (!context.mounted) {
                                  return;
                                }
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      context.t(
                                        LocaleKeys.libraryAddedToLibrary,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      NovelEditorStep3CoverOverlay(
                        onboardingStep: chatOnboardingStep.value,
                        thumbnailKey: coverThumbnailKey,
                        onDismiss: () {
                          chatOnboardingStep.value = 0;
                          contentSelection.value =
                              const _EditorCoverStudioSelection();
                          aiPanelCollapsed.value = true;
                          unawaited(() async {
                            final db = ref.read(appDatabaseProvider);
                            await db.appStateDao.set(
                              key: appStateKeyChatOnboardingShown,
                              value: DateTime.now().toIso8601String(),
                            );
                          }());
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

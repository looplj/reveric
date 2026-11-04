// 职责: AiClient 的配置对象 — 将 20+ 构造函数参数聚合为一个结构化配置
// 关联文件:
//   lib/shared/services/ai/chat.dart

import 'package:flutter/foundation.dart';

import '../../models/ai_chat_models.dart';
import '../../models/ai_provider.dart';
import '../../models/ai_session_mode.dart';
import '../../models/content_kind.dart';
import '../../models/agent_skill.dart';
import '../../models/subagent.dart';
import '../novel_content.dart';
import '../working_overlay.dart';
import 'tools.dart';

/// 流式响应中断原因
enum AiInterruptReason { cancel, steering }

/// [AiClient] 的构造配置。
///
/// 替代旧有的 20+ 命名参数构造函数，所有可选字段默认为 null。
class AiServiceConfig {
  final AiProvider provider;
  final String chatModel;
  final NovelContentService? novelContentService;
  final WorkingOverlayService? workingOverlayService;
  final AiSessionContext? sessionContext;
  final AiNovelReader? novelReader;
  final AiNovelWriter? novelWriter;
  final AiNovelDraftClearer? novelDraftClearer;
  final CrossWorkAccess? crossWorkAccess;
  final Future<List<AiProvider>> Function()? providerReader;
  final AiToolCallRequestedCallback? onToolCallRequested;
  final AiToolEventCallback? onToolStarted;
  final AiToolEventCallback? onToolFinished;
  final AiToolShouldExecuteCallback? shouldExecuteTool;
  final AiInterruptReason? Function()? interruptReason;
  final AiImageGenerationCallback? imageGenerationCallback;
  final AiImageEditCallback? imageEditCallback;
  final AiCreateLocationCallback? createLocationCallback;
  final List<SubAgent> Function()? subAgentListProvider;
  final ValueNotifier<AiSessionMode>? sessionModeNotifier;
  final AiAskUserCallback? askUserCallback;

  /// 已裁决的下一步建议挂载回调。为 null 时 SuggestNextAction 不注册也不下发。
  final SuggestNextActionCallback? suggestNextActionCallback;

  final AiThemesCommandCallback? themesCommandCallback;
  final AiSubagentsCommandCallback? subagentsCommandCallback;
  final AiSessionsCommandCallback? sessionsCommandCallback;
  final String? sessionId;
  final String? sourceSessionId;
  final String contentKind;
  final String? workId;
  final String? sourceNovelId;
  final String? currentSeasonId;
  final String? currentEpisodeId;

  /// 按名称异步加载技能完整指令的回调。
  final Future<AgentSkillLoadResult?> Function(String name)? skillLoader;

  /// 上报画布操作的回调(由 ai_providers.dart / chat_turn_runner.dart 注入
  /// riverpod canvasAiActivityProvider)。画布 UI 靠它跟随镜头与显示状态条。
  final AiCanvasActivityReporter? canvasActivityReporter;

  /// AiProviderInitializer 做免费态兜底；参数名保留兼容性，null 时按既有行为不拦截。

  const AiServiceConfig({
    required this.provider,
    required this.chatModel,
    this.novelContentService,
    this.workingOverlayService,
    this.sessionContext,
    this.novelReader,
    this.novelWriter,
    this.novelDraftClearer,
    this.crossWorkAccess,
    this.providerReader,
    this.onToolCallRequested,
    this.onToolStarted,
    this.onToolFinished,
    this.shouldExecuteTool,
    this.interruptReason,
    this.imageGenerationCallback,
    this.imageEditCallback,
    this.createLocationCallback,
    this.subAgentListProvider,
    this.sessionModeNotifier,
    this.askUserCallback,
    this.suggestNextActionCallback,

    this.themesCommandCallback,
    this.subagentsCommandCallback,
    this.sessionsCommandCallback,
    this.sessionId,
    this.sourceSessionId,
    this.contentKind = contentKindNovel,
    this.workId,
    this.sourceNovelId,
    this.currentSeasonId,
    this.currentEpisodeId,
    this.skillLoader,
    this.canvasActivityReporter,
  });
}

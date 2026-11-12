// 职责: AI 工具卡片文案与路径描述工具 — 负责语义动作动词、语义优先级、本地化路径与头部摘要生成。
// 关联文件:
//   lib/shared/widgets/ai/tool_activity_group.dart
//   lib/shared/widgets/ai/tools/run_command_parser.dart
//   lib/shared/widgets/ai/tools/tool_resource_resolver.dart
//   lib/shared/services/ai/tools.dart
//   lib/shared/models/agent_skill.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/settings.json
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/zh-CN/provider.json
//   assets/translations/en/ai.json
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/zh-CN/tool.json
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
import 'package:flutter/widgets.dart';

import 'package:reveric/shared/agent/client.dart'
    show toolCallIncompleteErrorCode;
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/entity_graph/labels.dart';
import 'package:reveric/shared/models/agent_skill.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/ai/tool_result_payloads.dart';
import 'package:reveric/shared/services/ai/run_command_parser.dart';
import 'tool_resource_resolver.dart';
import 'plugin_tool_display.dart';

/// 返回工具调用的语义动作动词（本地化）。
/// 例如 "Looking up"、"Writing to"、"Editing"。
String toolActionVerb(BuildContext context, AiToolCallBlock block) {
  if (isPluginToolBlock(block)) {
    return pluginToolTitle(context, block);
  }
  final toolName = block.toolName;
  if (isRelationCreateBlock(block)) {
    return context.t(LocaleKeys.toolActionCreatingRelation);
  }
  final key = switch (toolName) {
    'Read' => LocaleKeys.toolActionReading,
    'Write' => LocaleKeys.toolActionWriting,
    'Remove' => LocaleKeys.toolActionRemoving,
    'Edit' || 'EditOutline' || 'EditBeat' => LocaleKeys.toolActionEditing,
    'Replace' => LocaleKeys.toolActionReplacing,
    'Search' => LocaleKeys.toolActionSearching,
    'Create' ||
    'CreateChapter' ||
    'CreateCharacter' ||
    'CreateForeshadowing' ||
    'CreateLocation' ||
    'CreateBeat' ||
    'CreateOutline' ||
    'CreateVolume' => LocaleKeys.toolActionCreating,
    'WebSearch' => LocaleKeys.toolActionWebSearching,
    'WebFetch' => LocaleKeys.toolActionWebFetching,
    'GraphSearch' => LocaleKeys.toolActionSearching,
    'Glob' => LocaleKeys.toolActionGlobbing,
    'Grep' => LocaleKeys.toolActionGrepping,
    'AskUser' => LocaleKeys.toolActionAsking,
    'SpawnAgent' => LocaleKeys.toolActionSpawningAgent,
    'GenerateAvatar' => LocaleKeys.toolActionGeneratingAvatar,
    'GeneratePhoto' => LocaleKeys.toolActionGeneratingPhoto,
    'TodoWrite' => LocaleKeys.toolActionUpdatingTasks,
    'AgentSkill' => LocaleKeys.toolActionLoadingSkill,
    'ForkAgent' => LocaleKeys.toolActionForkingAgent,
    'Run' => _runActionVerbKey(ParsedRunCommand.fromBlock(block)),
    _ => null,
  };
  if (key != null) {
    return context.t(key);
  }
  if (toolName == 'Run') {
    return localizedToolCallTitle(context, block);
  }
  return localizedToolName(context, toolName);
}

String localizedToolCallTitle(BuildContext context, AiToolCallBlock block) {
  if (isPluginToolBlock(block)) {
    return pluginToolTitle(context, block);
  }
  if (block.toolName != 'Run') {
    return localizedToolName(context, block.toolName);
  }
  final parsed = ParsedRunCommand.fromBlock(block);
  final actionKey = _runActionVerbKey(parsed);
  if (actionKey != null) {
    return context.t(actionKey);
  }
  return switch (parsed?.topLevel) {
    'settings' => context.t(LocaleKeys.settingsTitle),
    'assets' => context.t(LocaleKeys.toolRunAssets),
    'mcp' => context.t(LocaleKeys.toolRunMcp),
    'providers' => context.t(LocaleKeys.toolRunProviders),
    'stagings' => context.t(LocaleKeys.toolRunDirector),
    'agent-skills' => context.t(LocaleKeys.toolRunAgentSkills),
    'themes' => context.t(LocaleKeys.toolRunThemes),
    'agent-rules' => context.t(LocaleKeys.toolRunAgentRules),
    'subagents' => context.t(LocaleKeys.toolRunSubagents),
    'sessions' => context.t(LocaleKeys.toolRunSessions),
    'novel' => context.t(LocaleKeys.toolRunNovel),
    'help' => context.t(LocaleKeys.toolRunHelp),
    'map' => context.t(LocaleKeys.toolRunMap),
    'character' || 'item' => context.t(LocaleKeys.toolRunImage),
    'notify' => context.t(LocaleKeys.toolRunNotify),
    _ => localizedToolName(context, 'Run'),
  };
}

const _runActionKeys = <(String, String), String>{
  ('settings', 'open'): LocaleKeys.commonOpen,
  ('production', 'capture-panorama'):
      LocaleKeys.toolRunProductionCapturePanorama,
  ('production', 'derive-view'): LocaleKeys.toolRunProductionDeriveView,
  ('production', 'image-preset'): LocaleKeys.toolRunProductionImagePreset,
  ('production', 'split-grid'): LocaleKeys.productionGridSplit,
  ('production', 'capture-frame'): LocaleKeys.productionCaptureFrame,
  ('production', 'separate-audio'): LocaleKeys.productionSeparateAudio,
  ('production', 'mute-video'): LocaleKeys.productionMute,
  ('production', 'trim-video'): LocaleKeys.productionTrim,
  ('files', 'list'): LocaleKeys.toolRunFilesList,
  ('files', 'read-text'): LocaleKeys.toolRunFilesReadText,
  ('files', 'view-image'): LocaleKeys.toolRunViewImage,
  ('files', 'read-video-metadata'): LocaleKeys.toolRunFilesReadVideoMetadata,
  ('files', 'read-audio-metadata'): LocaleKeys.toolRunFilesReadAudioMetadata,
  ('files', 'remove'): LocaleKeys.commonDelete,
  ('editing', 'list'): LocaleKeys.toolRunEditingList,
  ('editing', 'create'): LocaleKeys.commonCreate,
  ('editing', 'read'): LocaleKeys.toolRunEditingRead,
  ('editing', 'apply'): LocaleKeys.toolRunEditingApply,
  ('editing', 'undo'): LocaleKeys.commonUndo,
  ('editing', 'redo'): LocaleKeys.commonRedo,
  ('editing', 'preview'): LocaleKeys.toolRunEditingPreview,
  ('editing', 'frames'): LocaleKeys.toolRunEditingFrames,
  ('editing', 'cleanup'): LocaleKeys.commonDelete,
  ('editing', 'export'): LocaleKeys.toolRunEditingExport,
  ('operations', 'list'): LocaleKeys.toolRunOperationsList,
  ('operations', 'read'): LocaleKeys.toolRunOperationsRead,
  ('operations', 'wait'): LocaleKeys.toolRunOperationsWait,
  ('operations', 'cancel'): LocaleKeys.commonCancel,
  ('ffmpeg', 'capabilities'): LocaleKeys.toolRunFfmpegCapabilities,
  ('ffmpeg', 'probe'): LocaleKeys.toolRunFfmpegProbe,
  ('ffmpeg', 'frames'): LocaleKeys.toolRunFfmpegFrames,
  ('ffmpeg', 'execute'): LocaleKeys.toolRunFfmpegExecute,
  ('assets', 'list'): LocaleKeys.toolRunAssetsList,
  ('assets', 'read'): LocaleKeys.toolRunAssetsRead,
  ('assets', 'view-image'): LocaleKeys.toolRunViewImage,
  ('mcp', 'list'): LocaleKeys.toolRunMcpList,
  ('mcp', 'search'): LocaleKeys.toolRunMcpSearch,
  ('mcp', 'describe'): LocaleKeys.toolRunMcpDescribe,
  ('mcp', 'call'): LocaleKeys.toolRunMcpCall,
  ('providers', 'list'): LocaleKeys.toolRunProvidersList,
  ('providers', 'read'): LocaleKeys.toolRunProvidersRead,
  ('providers', 'models'): LocaleKeys.toolRunProvidersModels,
  ('stagings', 'schema'): LocaleKeys.toolRunDirectorSchema,
  ('stagings', 'presets'): LocaleKeys.toolRunDirectorPresets,
  ('stagings', 'sample'): LocaleKeys.toolRunDirectorSample,
  ('stagings', 'list'): LocaleKeys.toolRunDirectorList,
  ('stagings', 'read'): LocaleKeys.toolRunDirectorRead,
  ('stagings', 'create'): LocaleKeys.toolRunDirectorCreate,
  ('stagings', 'apply'): LocaleKeys.toolRunDirectorApply,
  ('stagings', 'write'): LocaleKeys.toolRunDirectorApply,
  ('stagings', 'restore'): LocaleKeys.toolRunDirectorRestore,
  ('stagings', 'remove'): LocaleKeys.toolRunDirectorRemove,
  ('stagings', 'preview'): LocaleKeys.toolRunDirectorPreview,
  ('stagings', 'output'): LocaleKeys.toolRunDirectorOutput,
  ('stagings', 'frames'): LocaleKeys.toolRunDirectorFrames,

  ('themes', 'list'): LocaleKeys.toolRunThemesList,
  ('themes', 'read'): LocaleKeys.toolRunThemesRead,
  ('themes', 'create'): LocaleKeys.toolRunThemesCreate,
  ('themes', 'update'): LocaleKeys.toolRunThemesUpdate,
  ('themes', 'apply'): LocaleKeys.toolRunThemesApply,
  ('themes', 'delete'): LocaleKeys.toolRunThemesDelete,
  ('agent-skills', 'list'): LocaleKeys.toolRunAgentSkillsList,
  ('agent-skills', 'create'): LocaleKeys.toolRunAgentSkillsCreate,
  ('agent-skills', 'update'): LocaleKeys.toolRunAgentSkillsUpdate,
  ('agent-skills', 'delete'): LocaleKeys.toolRunAgentSkillsDelete,
  ('agent-skills', 'search'): LocaleKeys.toolRunAgentSkillsSearch,
  ('agent-skills', 'get'): LocaleKeys.toolRunAgentSkillsGet,
  ('agent-skills', 'install'): LocaleKeys.toolRunAgentSkillsInstall,
  ('agent-skills', 'reference-list'):
      LocaleKeys.toolRunAgentSkillsReferenceList,
  ('agent-skills', 'reference-get'): LocaleKeys.toolRunAgentSkillsReferenceGet,
  ('agent-skills', 'reference-create'):
      LocaleKeys.toolRunAgentSkillsReferenceCreate,
  ('agent-skills', 'reference-update'):
      LocaleKeys.toolRunAgentSkillsReferenceUpdate,
  ('agent-skills', 'reference-move'):
      LocaleKeys.toolRunAgentSkillsReferenceMove,
  ('agent-skills', 'reference-delete'):
      LocaleKeys.toolRunAgentSkillsReferenceDelete,
  ('agent-rules', 'list'): LocaleKeys.toolRunAgentRulesList,
  ('agent-rules', 'read'): LocaleKeys.toolRunAgentRulesRead,
  ('agent-rules', 'create'): LocaleKeys.toolRunAgentRulesCreate,
  ('agent-rules', 'update'): LocaleKeys.toolRunAgentRulesUpdate,
  ('agent-rules', 'delete'): LocaleKeys.toolRunAgentRulesDelete,
  ('subagents', 'list'): LocaleKeys.toolRunSubagentsList,
  ('subagents', 'create'): LocaleKeys.toolRunSubagentsCreate,
  ('subagents', 'update'): LocaleKeys.toolRunSubagentsUpdate,
  ('subagents', 'delete'): LocaleKeys.toolRunSubagentsDelete,
  ('sessions', 'search'): LocaleKeys.toolRunSessionsSearch,
  ('sessions', 'list'): LocaleKeys.toolRunSessionsList,
  ('sessions', 'read'): LocaleKeys.toolRunSessionsRead,
  ('sessions', 'get'): LocaleKeys.toolRunSessionsGet,
  ('novel', 'add-to-library'): LocaleKeys.toolRunNovelAddToLibrary,
  ('map', 'draft'): LocaleKeys.toolRunMapDraft,
  ('notify', 'progress'): LocaleKeys.toolRunNotifyProgress,
  ('notify', 'question'): LocaleKeys.toolRunNotifyQuestion,
  ('notify', 'complete'): LocaleKeys.toolRunNotifyComplete,
  ('notify', 'error'): LocaleKeys.toolRunNotifyError,
  ('character', 'generate-avatar'): LocaleKeys.toolRunImageCharacterAvatar,
  ('character', 'generate-photo'): LocaleKeys.toolRunImageCharacterPhoto,
  ('item', 'generate-photo'): LocaleKeys.toolRunImageItemPhoto,
};

String? localizedRunCommandAction(
  BuildContext context,
  String? command,
  String? action,
) {
  final key = _runActionKeys[(command, action)];
  return key == null ? null : context.t(key);
}

String? _runActionVerbKey(ParsedRunCommand? parsed) {
  if (parsed == null) {
    return null;
  }
  if (parsed.topLevel == 'help' ||
      parsed.topLevel == '--help' ||
      parsed.subcommand == '--help') {
    return LocaleKeys.toolRunViewHelp;
  }
  return _runActionKeys[(parsed.topLevel, parsed.subcommand)];
}

String localizedToolName(BuildContext context, String toolName) {
  final key = switch (toolName) {
    'Codemode' => LocaleKeys.toolNameCodemode,
    'Read' => LocaleKeys.toolNameRead,
    'Write' => LocaleKeys.toolNameWrite,
    'Remove' => LocaleKeys.toolNameRemove,
    'Edit' => LocaleKeys.toolNameEdit,
    'Replace' => LocaleKeys.toolNameReplace,
    'EditOutline' => LocaleKeys.toolNameEditOutline,
    'Search' => LocaleKeys.toolNameSearch,
    'Glob' => LocaleKeys.toolNameGlob,
    'Grep' => LocaleKeys.toolNameGrep,
    'GraphSearch' => LocaleKeys.toolNameGraphSearch,
    'Create' => LocaleKeys.toolNameCreate,
    'CreateChapter' => LocaleKeys.toolNameCreateChapter,
    'CreateOutline' => LocaleKeys.toolNameCreateOutline,
    'CreateBeat' => LocaleKeys.toolNameCreateBeat,
    'EditBeat' => LocaleKeys.toolNameEditBeat,
    'CreateVolume' => LocaleKeys.toolNameCreateVolume,
    'CreateCharacter' => LocaleKeys.toolNameCreateCharacter,
    'CreateForeshadowing' => LocaleKeys.toolNameCreateForeshadowing,
    'CreateLocation' => LocaleKeys.toolNameCreateLocation,
    'GenerateAvatar' => LocaleKeys.toolNameGenerateAvatar,
    'GeneratePhoto' => LocaleKeys.toolNameGeneratePhoto,
    'Run' => LocaleKeys.toolNameRun,
    'WebSearch' => LocaleKeys.toolNameWebSearch,
    'WebFetch' => LocaleKeys.toolNameWebFetch,
    'AskUser' => LocaleKeys.toolNameAskUser,
    'TodoWrite' => LocaleKeys.toolNameTodoWrite,
    'AgentSkill' => LocaleKeys.toolNameSkill,
    'SpawnAgent' => LocaleKeys.toolNameSpawnAgent,
    'SendAgentMessage' => LocaleKeys.toolNameSendAgentMessage,
    'StopAgent' => LocaleKeys.toolNameStopAgent,
    'ForkAgent' => LocaleKeys.toolNameForkAgent,
    'CreateTask' => LocaleKeys.toolNameCreateTask,
    'ListTasks' => LocaleKeys.toolNameListTasks,
    _ => null,
  };
  return key != null ? context.t(key) : toolName;
}

/// 该 block 是否在创建实体关系（`Create` + path 的 collection 为 `relations`）。
///
/// 关系创建从专用 CreateRelation 工具并入统一 Create 后，工具名不再能区分它，
/// 判据变成「Create 到 /relations」。关系卡片要显示 source → target 端点标签，
/// 与其他 Create 的资源名标签不同，因此需要这个谓词。
bool isRelationCreateBlock(AiToolCallBlock block) {
  if (block.toolName != 'Create') {
    return false;
  }
  final path = (block.arguments['path'] as String?)?.trim() ?? '';
  return path.isNotEmpty && parseAiToolPath(path).collection == 'relations';
}

/// 关系创建的 source_id / target_id 在 fields 里（Create 的入参形状）。
String relationCreateArg(AiToolCallBlock block, String key) {
  final fields = block.arguments['fields'];
  if (fields is Map) {
    final value = fields[key];
    if (value is String) {
      return value.trim();
    }
  }
  return (block.arguments[key] as String? ?? '').trim();
}

String? toolPrimaryPath(AiToolCallBlock block) {
  if (block.source == 'mcp') {
    return null;
  }
  final rawArgPath = block.arguments['path'];
  final argPath = rawArgPath is String ? rawArgPath.trim() : null;
  if (block.toolName == 'Read' &&
      argPath != null &&
      argPath.isNotEmpty &&
      _isListingQueryPath(argPath)) {
    return argPath;
  }
  final selfPath = toolResultResourcePath(block.result);
  if (selfPath != null && selfPath.isNotEmpty) {
    return selfPath;
  }
  final targetPath = block.targetPath?.trim();
  if (targetPath != null && targetPath.isNotEmpty) {
    return targetPath;
  }
  if (argPath != null && argPath.isNotEmpty) {
    return argPath;
  }
  return null;
}

bool shouldUseResolvedResourceForToolCard(AiToolCallBlock block) {
  if (block.source == 'mcp') {
    return false;
  }
  // old_text 不匹配等可恢复失败不会让资源失效，仍应显示用户可读名称。
  // 只有目标确实不存在时才禁用解析结果，避免删除后短暂显示陈旧名称。
  final errorCode = block.result?['error_code']?.toString().trim();
  return errorCode != 'not_found';
}

AiToolCallStatus aiDisplayStatus(AiToolCallBlock block) {
  return aiToolOperationDisplayBlock(block).status;
}

/// 普通模式不暴露一般工具失败标志；需要用户感知的特例由调用方显式放行。
bool shouldShowAiToolStatus(
  AiToolCallStatus status, {
  required bool debugMode,
}) {
  return debugMode || status != AiToolCallStatus.error;
}

bool isIncompleteAiToolCall(AiToolCallBlock block) {
  return block.result?['error_code'] == toolCallIncompleteErrorCode;
}

bool _isListingQueryPath(String path) {
  final parsed = parseAiToolPath(path);
  return parsed.hasQuery && !parsed.hasId;
}

String? toolResultResourcePath(Map<String, dynamic>? result) {
  // 工具结果的 path 可能是业务数据（如导演台运动路径对象），只认字符串资源路径。
  final path = result?['path'];
  if (path is! String) return null;
  final trimmed = path.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String collectionLabel(BuildContext context, String collection) {
  final key = switch (collection) {
    'novel' => LocaleKeys.workspaceNovelOverview,
    'chapters' => LocaleKeys.workspaceChapters,
    'volumes' => LocaleKeys.workspaceVolume,
    'characters' => LocaleKeys.workspaceCharacters,
    'lore' || 'worldbuilding' => LocaleKeys.workspaceLore,
    'outlines' => LocaleKeys.workspaceOutlines,
    'materials' => LocaleKeys.workspaceMaterials,
    'skills' => LocaleKeys.workspaceSkills,
    'items' => LocaleKeys.workspaceItems,
    'factions' => LocaleKeys.workspaceFactions,
    'foreshadowing' => LocaleKeys.workspaceForeshadowings,
    'relations' => LocaleKeys.workspaceRelations,
    'beats' => LocaleKeys.workspaceOutlineTimelineTitle,
    _ => null,
  };
  return key == null ? collection : context.t(key);
}

String fieldLabel(BuildContext context, String field) {
  // 统一走 aiToolFieldLabel，字段映射只维护一份（见 tool_resource_resolver.dart）。
  return aiToolFieldLabel(context, field);
}

/// 返回语义化的卡片头部摘要文案（动词 + 目标）。
/// 例如 "Looking up Chapter 3"、"Editing Iren Vell"。
String? toolHeaderSubtitle(
  BuildContext context,
  AiToolCallBlock block,
  AiToolResolvedResource? resource, {
  ToolRelationEndpointLabels? relationEndpoints,
}) {
  if (isPluginToolBlock(block)) {
    final title = pluginToolTitle(context, block),
        summary = pluginToolSummary(block);
    return summary == null ? title : '$title $summary';
  }
  if (block.toolName == 'Codemode') {
    return codemodeActivitySummary(context, block);
  }
  final verb = toolActionVerb(context, block);
  // 关系创建走 Create /relations，按工具名分不出来，先于 switch 判定。
  if (isRelationCreateBlock(block)) {
    final sourceId = relationCreateArg(block, 'source_id');
    final targetId = relationCreateArg(block, 'target_id');
    final endpoints = relationEndpointsLabel(
      sourceId: sourceId,
      targetId: targetId,
      sourceLabel: relationEndpoints?.source,
      targetLabel: relationEndpoints?.target,
    );
    if (endpoints != null && endpoints.isNotEmpty) {
      return '$verb $endpoints';
    }
    if (sourceId.isNotEmpty) {
      return '$verb $sourceId';
    }
    return verb;
  }
  switch (block.toolName) {
    case 'Run':
      return _runHeaderSubtitle(context, block, verb);
    case 'Read':
      final target = _readTargetLabel(context, block, resource);
      if (target == null || target.isEmpty) return null;
      return '$verb $target';
    case 'Write':
    case 'Remove':
    case 'Edit':
    case 'EditOutline':
      final target =
          resource?.displayLabel(context) ??
          localizedToolPathLabel(context, toolPrimaryPath(block) ?? '');
      if (target.isEmpty) return null;
      return '$verb $target';
    case 'Replace':
      final pattern = (block.arguments['pattern'] as String? ?? '').trim();
      final replacement = (block.arguments['replacement'] as String? ?? '')
          .trim();
      final matchedFields =
          block.result?['matched_fields'] ?? block.result?['applied_fields'];
      final fieldsSuffix = matchedFields is int ? ' ($matchedFields)' : '';
      if (pattern.isEmpty) {
        return verb;
      }
      return replacement.isEmpty
          ? '$verb "$pattern"$fieldsSuffix'
          : '$verb "$pattern" → "$replacement"$fieldsSuffix';
    case 'Search':
      final query = (block.arguments['query'] as String? ?? '').trim();
      if (query.isEmpty) return null;
      return '$verb "$query"';
    case 'Glob':
      final pattern = (block.arguments['pattern'] as String? ?? '').trim();
      if (pattern.isEmpty) return null;
      return '$verb ${localizeGlobPattern(context, pattern)}';
    case 'Grep':
      final pattern = (block.arguments['pattern'] as String? ?? '').trim();
      if (pattern.isEmpty) {
        final target =
            resource?.displayLabel(context) ?? toolPrimaryPath(block);
        if (target == null || target.isEmpty) return null;
        return '$verb $target';
      }
      return '$verb "$pattern"';
    case 'GraphSearch':
      final entityType = graphSearchTypeFromInput(block.arguments);
      final entityId = graphSearchIdFromInput(block.arguments);
      final depth = block.arguments['depth'] as int? ?? 1;
      if (entityType.isEmpty || entityId.isEmpty) {
        return verb;
      }
      return '$verb ${graphSearchEntityLabel(context, entityType, entityId, depth: depth)}';
    case 'WebSearch':
      final query = (block.arguments['query'] as String? ?? '').trim();
      if (query.isEmpty) return localizedToolName(context, block.toolName);
      return '$verb "$query"';
    case 'WebFetch':
      final url = (block.arguments['url'] as String? ?? '').trim();
      if (url.isEmpty) return null;
      return '$verb $url';
    case 'Create':
      final title = _createFieldsTitle(block);
      if (title != null && title.isNotEmpty) {
        return '$verb $title';
      }
      final path = (block.arguments['path'] as String? ?? '').trim();
      if (path.isNotEmpty) {
        return '$verb ${localizedToolPathLabel(context, path)}';
      }
      return verb;
    case 'CreateChapter':
      final title = (block.arguments['title'] as String? ?? '').trim();
      if (title.isNotEmpty) return '$verb $title';
      final resourceLabel = resource?.displayLabel(context);
      if (resourceLabel != null && resourceLabel.isNotEmpty) {
        return '$verb $resourceLabel';
      }
      return verb;
    case 'CreateCharacter':
      final name = (block.arguments['name'] as String? ?? '').trim();
      if (name.isNotEmpty) return '$verb $name';
      final resourceLabel = resource?.displayLabel(context);
      if (resourceLabel != null && resourceLabel.isNotEmpty) {
        return '$verb $resourceLabel';
      }
      return verb;
    case 'CreateForeshadowing':
      final title = (block.arguments['title'] as String? ?? '').trim();
      if (title.isNotEmpty) return '$verb $title';
      return verb;
    case 'CreateLocation':
      final name = (block.result?['name'] ?? block.arguments['name'] ?? '')
          .toString()
          .trim();
      if (name.isNotEmpty) return '$verb $name';
      return verb;
    case 'CreateOutline':
      final title = (block.arguments['title'] as String? ?? '').trim();
      if (title.isNotEmpty) return '$verb $title';
      return verb;
    case 'CreateBeat':
      final outlineTitle = (block.arguments['outline_title'] as String? ?? '')
          .trim();
      final beatTitle = (block.arguments['title'] as String? ?? '').trim();
      if (outlineTitle.isNotEmpty && beatTitle.isNotEmpty) {
        return '$verb $beatTitle @ $outlineTitle';
      }
      if (outlineTitle.isNotEmpty) return '$verb $outlineTitle';
      if (beatTitle.isNotEmpty) return '$verb $beatTitle';
      return verb;
    case 'CreateVolume':
      final title = (block.arguments['title'] as String? ?? '').trim();
      if (title.isNotEmpty) return '$verb $title';
      return verb;
    case 'EditBeat':
      final outlineTitle = (block.arguments['outline_title'] as String? ?? '')
          .trim();
      final beatIndex = block.arguments['beat_index'];
      if (outlineTitle.isNotEmpty && beatIndex != null) {
        final beatLabel = context.t(
          LocaleKeys.toolBeatIndexFmt,
          namedArgs: {'index': '$beatIndex'},
        );
        return '$verb $beatLabel @ $outlineTitle';
      }
      if (outlineTitle.isNotEmpty) return '$verb $outlineTitle';
      return verb;
    case 'ForkAgent':
      return verb;
    case 'AgentSkill':
      final skillName = agentSkillNameFromInput(block.arguments);
      if (skillName.isNotEmpty) {
        return '$verb $skillName';
      }
      return verb;
    case 'SpawnAgent':
      final agentName =
          ((block.arguments['name'] as String?)?.trim().isNotEmpty == true
          ? (block.arguments['name'] as String).trim()
          : (block.arguments['agent_name'] as String? ?? '').trim());
      // 子 agent 实际使用的模型（仅配置了自定义模型时由 SpawnAgent 结果带出）。
      final model = (block.metadata?['sub_agent_model'] as String? ?? '')
          .trim();
      final base = agentName.isNotEmpty ? '$verb $agentName' : verb;
      return model.isNotEmpty ? '$base · $model' : base;
    case 'TodoWrite':
      final items = block.result?['items'] as List?;
      if (items != null && items.isNotEmpty) {
        return '$verb (${items.length})';
      }
      return verb;
    default:
      final target =
          resource?.displayLabel(context) ??
          localizedToolPathLabel(context, toolPrimaryPath(block) ?? '');
      if (target.isEmpty) return null;
      return '$verb $target';
  }
}

String? _createFieldsTitle(AiToolCallBlock block) {
  final fields = block.arguments['fields'];
  if (fields is! Map) {
    return null;
  }
  for (final key in ['title', 'name']) {
    final value = (fields[key] as String?)?.trim() ?? '';
    if (value.isNotEmpty) {
      return value;
    }
  }
  return null;
}

String? toolRowTarget(
  BuildContext context,
  AiToolCallBlock block,
  AiToolResolvedResource? resource, {
  ToolRelationEndpointLabels? relationEndpoints,
}) {
  if (isPluginToolBlock(block)) {
    return pluginToolSummary(block);
  }
  if (block.toolName == 'Codemode') {
    return codemodeActivitySummary(context, block);
  }
  // 同 toolHeaderSubtitle：关系创建按 Create + /relations 判定，先于 switch。
  if (isRelationCreateBlock(block)) {
    return relationEndpointsLabel(
      sourceId: relationCreateArg(block, 'source_id'),
      targetId: relationCreateArg(block, 'target_id'),
      sourceLabel: relationEndpoints?.source,
      targetLabel: relationEndpoints?.target,
    );
  }
  switch (block.toolName) {
    case 'Run':
      return _runRowTarget(context, block);
    case 'Read':
      return _readTargetLabel(context, block, resource);
    case 'Write':
    case 'Remove':
    case 'Edit':
    case 'EditOutline':
      final resolved = resource?.displayLabel(context);
      if (resolved != null && resolved.isNotEmpty) {
        return resolved;
      }
      final path = toolPrimaryPath(block);
      return path == null ? null : localizedToolPathLabel(context, path);
    case 'Replace':
      final pattern = (block.arguments['pattern'] as String? ?? '').trim();
      final replacement = (block.arguments['replacement'] as String? ?? '')
          .trim();
      if (pattern.isEmpty) {
        return null;
      }
      final matchedFields =
          block.result?['matched_fields'] ?? block.result?['applied_fields'];
      final fieldsSuffix = matchedFields is int ? ' ($matchedFields)' : '';
      return replacement.isEmpty
          ? '$pattern$fieldsSuffix'
          : '$pattern → $replacement$fieldsSuffix';
    case 'Search':
      final query = (block.arguments['query'] as String? ?? '').trim();
      return query.isEmpty ? null : query;
    case 'Glob':
      final pattern = (block.arguments['pattern'] as String? ?? '').trim();
      return pattern.isEmpty ? null : localizeGlobPattern(context, pattern);
    case 'Grep':
      final pattern = (block.arguments['pattern'] as String? ?? '').trim();
      if (pattern.isNotEmpty) {
        return pattern;
      }
      return resource?.displayLabel(context) ??
          localizedToolPathLabel(context, toolPrimaryPath(block) ?? '');
    case 'GraphSearch':
      final entityType = graphSearchTypeFromInput(block.arguments);
      final entityId = graphSearchIdFromInput(block.arguments);
      final depth = block.arguments['depth'] as int? ?? 1;
      if (entityType.isEmpty || entityId.isEmpty) {
        return null;
      }
      return graphSearchEntityLabel(
        context,
        entityType,
        entityId,
        depth: depth,
      );
    case 'WebSearch':
      final query = (block.arguments['query'] as String? ?? '').trim();
      return query.isEmpty ? null : query;
    case 'WebFetch':
      final url = (block.arguments['url'] as String? ?? '').trim();
      return url.isEmpty ? null : url;
    case 'Create':
      final title = _createFieldsTitle(block);
      if (title != null && title.isNotEmpty) {
        return title;
      }
      final path = (block.arguments['path'] as String? ?? '').trim();
      return path.isEmpty ? null : localizedToolPathLabel(context, path);
    case 'CreateChapter':
      final title = (block.arguments['title'] as String? ?? '').trim();
      final resourceLabel = resource?.displayLabel(context);
      return title.isNotEmpty ? title : resourceLabel;
    case 'CreateCharacter':
      final name = (block.arguments['name'] as String? ?? '').trim();
      final resourceLabel = resource?.displayLabel(context);
      return name.isNotEmpty ? name : resourceLabel;
    case 'CreateForeshadowing':
      final title = (block.arguments['title'] as String? ?? '').trim();
      return title.isEmpty ? null : title;
    case 'CreateLocation':
      final name = (block.result?['name'] ?? block.arguments['name'] ?? '')
          .toString()
          .trim();
      return name.isEmpty ? null : name;
    case 'CreateOutline':
      final title = (block.arguments['title'] as String? ?? '').trim();
      return title.isEmpty ? null : title;
    case 'CreateBeat':
      final outlineTitle = (block.arguments['outline_title'] as String? ?? '')
          .trim();
      final beatTitle = (block.arguments['title'] as String? ?? '').trim();
      if (outlineTitle.isNotEmpty && beatTitle.isNotEmpty) {
        return '$beatTitle @ $outlineTitle';
      }
      if (outlineTitle.isNotEmpty) return outlineTitle;
      if (beatTitle.isNotEmpty) return beatTitle;
      return null;
    case 'CreateVolume':
      final title = (block.arguments['title'] as String? ?? '').trim();
      return title.isEmpty ? null : title;
    case 'EditBeat':
      final outlineTitle = (block.arguments['outline_title'] as String? ?? '')
          .trim();
      final beatIndex = block.arguments['beat_index'];
      if (outlineTitle.isNotEmpty && beatIndex != null) {
        final beatLabel = context.t(
          LocaleKeys.toolBeatIndexFmt,
          namedArgs: {'index': '$beatIndex'},
        );
        return '$beatLabel @ $outlineTitle';
      }
      if (outlineTitle.isNotEmpty) return outlineTitle;
      return null;
    case 'AgentSkill':
      final skillName = agentSkillNameFromInput(block.arguments);
      if (skillName.isNotEmpty) {
        return skillName;
      }
      return null;
    case 'SpawnAgent':
      final agentName =
          ((block.arguments['name'] as String?)?.trim().isNotEmpty == true
          ? (block.arguments['name'] as String).trim()
          : (block.arguments['agent_name'] as String? ?? '').trim());
      final model = (block.metadata?['sub_agent_model'] as String? ?? '')
          .trim();
      if (agentName.isEmpty) return null;
      return model.isNotEmpty ? '$agentName · $model' : agentName;
    case 'TodoWrite':
      final items = block.result?['items'] as List?;
      if (items != null && items.isNotEmpty) {
        return '(${items.length})';
      }
      return null;
    case 'ForkAgent':
      return null;
    default:
      final resolved = resource?.displayLabel(context);
      if (resolved != null && resolved.isNotEmpty) {
        return resolved;
      }
      final path = toolPrimaryPath(block);
      return path == null ? null : localizedToolPathLabel(context, path);
  }
}

String? _readTargetLabel(
  BuildContext context,
  AiToolCallBlock block,
  AiToolResolvedResource? resource,
) {
  if (resource?.isListing == true || resource?.ordinals.isNotEmpty == true) {
    return resource!.displayLabel(context);
  }
  final path = toolPrimaryPath(block);
  if (path != null && _isCollectionListingPath(path)) {
    return localizedToolPathLabel(context, path, collectionAsList: true);
  }
  final resolved = resource?.displayLabel(context);
  if (resolved != null && resolved.isNotEmpty) {
    return resolved;
  }
  return path == null ? null : localizedToolPathLabel(context, path);
}

bool _isCollectionListingPath(String path) {
  final parsed = parseAiToolPath(path);
  return parsed.collection.isNotEmpty &&
      parsed.collection != 'novel' &&
      !parsed.hasId;
}

String? _runReferenceTarget(AiToolCallBlock block, ParsedRunCommand parsed) {
  if (parsed.subcommand == 'reference-list') {
    return runSkillNameFromBlock(block, parsed);
  }
  final reference = block.result?['reference'];
  final path =
      (reference is Map ? reference['path']?.toString() : null) ??
      parsed.option('path');
  final newPath = parsed.option('new_path');
  if (parsed.subcommand == 'reference-move' &&
      path != null &&
      newPath != null) {
    return '$path → $newPath';
  }
  return path ?? runSkillNameFromBlock(block, parsed);
}

String? _runRowTarget(BuildContext context, AiToolCallBlock block) {
  final parsed = ParsedRunCommand.fromBlock(block);
  final topLevel = parsed?.topLevel;
  if (topLevel == 'settings') {
    final section = parsed?.option('section');
    final key = switch (section) {
      'general' => LocaleKeys.settingsGeneral,
      'appearance' => LocaleKeys.settingsAppearance,
      'editor' => LocaleKeys.settingsFonts,
      'reading' => LocaleKeys.settingsReading,
      'ai_agents' => LocaleKeys.settingsAiAgents,
      'providers' => LocaleKeys.providerTitle,
      'usage' => LocaleKeys.settingsUsage,
      'mcp' => LocaleKeys.settingsMcp,
      'plugins' => LocaleKeys.settingsPlugins,
      'backup' => LocaleKeys.settingsBackup,
      'trash' => LocaleKeys.settingsTrash,
      'about' => LocaleKeys.settingsAbout,
      'remote' => LocaleKeys.settingsRemote,
      'storage' => LocaleKeys.settingsStorage,
      _ => LocaleKeys.settingsTitle,
    };
    return context.t(key);
  }
  if (topLevel == 'mcp') {
    return switch (parsed?.subcommand) {
      'list' => parsed?.option('server'),
      'search' => parsed?.option('query'),
      'describe' || 'call' => parsed?.option('name'),
      _ => null,
    };
  }
  if (topLevel == 'files') {
    return parsed?.option('path');
  }
  if (topLevel == 'providers') {
    final entries = block.result?['entries'];
    if (entries is List) {
      return context.t(
        LocaleKeys.toolResultCountFmt,
        namedArgs: {'count': '${entries.length}'},
      );
    }
    return block.result?['name'] as String?;
  }
  if (topLevel == 'editing') {
    return parsed?.option('output_path') ??
        block.result?['title'] as String? ??
        parsed?.option('title');
  }
  if (topLevel == 'operations' ||
      topLevel == 'ffmpeg' ||
      topLevel == 'production') {
    final target = block.result?['target_label'] as String?;
    return target?.isNotEmpty == true ? target : null;
  }
  if (topLevel == 'assets' || topLevel == 'stagings') {
    final entries = block.result?['entries'];
    if (parsed?.subcommand == 'list' && entries is List) {
      return context.t(
        LocaleKeys.toolResultCountFmt,
        namedArgs: {'count': '${entries.length}'},
      );
    }
    for (final value in [
      block.result?['title'],
      block.result?['name'],
      parsed?.option('title'),
      parsed?.option('search'),
      parsed?.option('staging_id'),
      parsed?.option('asset_id'),
    ]) {
      final label = value?.toString().trim() ?? '';
      if (label.isNotEmpty) {
        return label;
      }
    }
    return null;
  }
  if (topLevel == 'map') {
    return null;
  }
  if (topLevel == 'notify') {
    final content = parsed?.option('content')?.trim() ?? '';
    return content.isEmpty ? null : content;
  }
  if (topLevel == 'agent-skills') {
    final subcommand = parsed?.subcommand;
    if (subcommand?.startsWith('reference-') ?? false) {
      return _runReferenceTarget(block, parsed!);
    }
    if (subcommand == 'list') {
      final entries = block.result?['entries'];
      if (entries is List && entries.isNotEmpty) {
        return context.t(
          LocaleKeys.toolRunSkillsCountFmt,
          namedArgs: {'count': '${entries.length}'},
        );
      }
      return null;
    }
    if (subcommand == 'delete') {
      final id =
          block.result?['deleted_id']?.toString().trim() ??
          parsed?.option('id') ??
          '';
      return id.isEmpty ? null : id;
    }
    if (subcommand == 'search') {
      final query = parsed?.option('query') ?? '';
      return query.isEmpty ? null : query;
    }
    final name = runSkillNameFromBlock(block, parsed);
    if (name != null && name.isNotEmpty) {
      return name;
    }
    final sourceId = parsed?.option('source_id');
    if (sourceId != null && sourceId.isNotEmpty) {
      return sourceId;
    }
    return null;
  }
  if (topLevel == 'themes') {
    if (parsed?.subcommand == 'list') {
      return null;
    }
    for (final value in [
      block.result?['name'],
      parsed?.option('name'),
      parsed?.option('id'),
      block.result?['id'],
    ]) {
      final label = value?.toString().trim() ?? '';
      if (label.isNotEmpty) {
        return label;
      }
    }
    return null;
  }
  if (topLevel == 'subagents') {
    final subcommand = parsed?.subcommand;
    if (subcommand == 'list') {
      final entries = block.result?['entries'];
      if (entries is List && entries.isNotEmpty) {
        return context.t(
          LocaleKeys.toolRunSubagentsCountFmt,
          namedArgs: {'count': '${entries.length}'},
        );
      }
      return null;
    }
    if (subcommand == 'delete') {
      final id =
          block.result?['deleted_id']?.toString().trim() ??
          parsed?.option('id') ??
          '';
      return id.isEmpty ? null : id;
    }
    final name = runSubagentNameFromBlock(block, parsed);
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return null;
  }
  if (topLevel == 'agent-rules') {
    final subcommand = parsed?.subcommand;
    if (subcommand == 'list') {
      final rules = block.result?['rules'];
      final count = block.result?['count'];
      final resolvedCount = count is int
          ? count
          : count is num
          ? count.toInt()
          : rules is List
          ? rules.length
          : 0;
      if (resolvedCount > 0) {
        return context.t(
          LocaleKeys.toolRunRulesCountFmt,
          namedArgs: {'count': '$resolvedCount'},
        );
      }
      return null;
    }
    final name = runRuleNameFromBlock(block, parsed);
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return null;
  }
  if (topLevel == 'sessions') {
    final target =
        parsed?.option('query') ??
        parsed?.option('id') ??
        parsed?.option('session_id');
    return target == null || target.isEmpty ? null : target;
  }
  if (topLevel == 'novel') {
    return null;
  }
  if (topLevel == 'help') {
    return localizedRunHelpTopic(context, parsed?.subcommand);
  }
  if (topLevel == 'image') {
    return parsed?.option('character') ?? parsed?.option('item');
  }
  return ParsedRunCommand.commandLabelFromBlock(block);
}

String? _runHeaderSubtitle(
  BuildContext context,
  AiToolCallBlock block,
  String verb,
) {
  final parsed = ParsedRunCommand.fromBlock(block);
  final topLevel = parsed?.topLevel;
  if (topLevel == 'map') {
    return verb;
  }
  if (topLevel == 'notify') {
    return verb;
  }
  if (topLevel == 'agent-skills') {
    final subcommand = parsed?.subcommand;
    if (subcommand?.startsWith('reference-') ?? false) {
      final target = _runReferenceTarget(block, parsed!);
      return target == null ? verb : '$verb $target';
    }
    if (subcommand == 'list') {
      final entries = block.result?['entries'];
      if (entries is List && entries.isNotEmpty) {
        return context.t(
          LocaleKeys.toolRunSkillsCountFmt,
          namedArgs: {'count': '${entries.length}'},
        );
      }
      return verb;
    }
    if (subcommand == 'delete') {
      final id =
          block.result?['deleted_id']?.toString().trim() ??
          parsed?.option('id') ??
          '';
      if (id.isNotEmpty) {
        return '$verb $id';
      }
      return verb;
    }
    if (subcommand == 'search') {
      final query = parsed?.option('query') ?? '';
      if (query.isNotEmpty) {
        return '$verb "$query"';
      }
      return verb;
    }
    final name = runSkillNameFromBlock(block, parsed);
    if (name != null && name.isNotEmpty) {
      return '$verb $name';
    }
    final sourceId = parsed?.option('source_id');
    if (sourceId != null && sourceId.isNotEmpty) {
      return '$verb $sourceId';
    }
    return verb;
  }
  if (topLevel == 'subagents') {
    final subcommand = parsed?.subcommand;
    if (subcommand == 'list') {
      final entries = block.result?['entries'];
      if (entries is List && entries.isNotEmpty) {
        return context.t(
          LocaleKeys.toolRunSubagentsCountFmt,
          namedArgs: {'count': '${entries.length}'},
        );
      }
      return verb;
    }
    if (subcommand == 'delete') {
      final id =
          block.result?['deleted_id']?.toString().trim() ??
          parsed?.option('id') ??
          '';
      if (id.isNotEmpty) {
        return '$verb $id';
      }
      return verb;
    }
    final name = runSubagentNameFromBlock(block, parsed);
    if (name != null && name.isNotEmpty) {
      return '$verb $name';
    }
    return verb;
  }
  if (topLevel == 'agent-rules') {
    final subcommand = parsed?.subcommand;
    if (subcommand == 'list') {
      final rules = block.result?['rules'];
      final count = block.result?['count'];
      final resolvedCount = count is int
          ? count
          : count is num
          ? count.toInt()
          : rules is List
          ? rules.length
          : 0;
      if (resolvedCount > 0) {
        return context.t(
          LocaleKeys.toolRunRulesCountFmt,
          namedArgs: {'count': '$resolvedCount'},
        );
      }
      return verb;
    }
    final name = runRuleNameFromBlock(block, parsed);
    if (name != null && name.isNotEmpty) {
      return '$verb $name';
    }
    return verb;
  }
  if (topLevel == 'sessions') {
    final data = block.result?['data'];
    final items = data is Map ? data['items'] : null;
    if (items is List) {
      return '$verb · ${context.t(LocaleKeys.toolResultCountFmt, namedArgs: {'count': '${items.length}'})}';
    }
    final target =
        parsed?.option('query') ??
        parsed?.option('id') ??
        parsed?.option('session_id');
    return target == null || target.isEmpty ? verb : '$verb $target';
  }
  if (topLevel == 'novel') {
    return verb;
  }
  if (topLevel == 'help') {
    final topic = localizedRunHelpTopic(context, parsed?.subcommand);
    if (topic != null && topic.isNotEmpty) {
      return '$verb $topic';
    }
    return verb;
  }
  if (_runActionVerbKey(parsed) != null) {
    final target = _runRowTarget(context, block);
    return target == null ? verb : '$verb $target';
  }
  final commandLabel = ParsedRunCommand.commandLabelFromBlock(block);
  if (commandLabel != null && commandLabel.isNotEmpty) {
    return commandLabel;
  }
  return verb;
}

/// 将 Run `help` 子命令主题映射为本地化名称。
String? localizedRunHelpTopic(BuildContext context, String? topic) {
  final value = topic?.trim() ?? '';
  if (value.isEmpty) {
    return null;
  }
  return switch (value) {
    'settings' => context.t(LocaleKeys.settingsTitle),
    'mcp' => context.t(LocaleKeys.toolRunMcp),
    'providers' => context.t(LocaleKeys.toolRunProviders),
    'agent-skills' => context.t(LocaleKeys.toolRunAgentSkills),
    'themes' => context.t(LocaleKeys.toolRunThemes),
    'agent-rules' => context.t(LocaleKeys.toolRunAgentRules),
    'subagents' => context.t(LocaleKeys.toolRunSubagents),
    'sessions' => context.t(LocaleKeys.toolRunSessions),
    'novel' => context.t(LocaleKeys.toolRunNovel),
    'map' => context.t(LocaleKeys.toolRunMap),
    'character' => context.t(LocaleKeys.toolRunHelpCharacterImage),
    'item' => context.t(LocaleKeys.toolRunHelpItemImage),
    'notify' => context.t(LocaleKeys.toolRunNotify),
    'help' => context.t(LocaleKeys.toolRunHelp),
    _ => value,
  };
}

String graphSearchEntityLabel(
  BuildContext context,
  String entityType,
  String entityId, {
  int? depth,
}) {
  if (entityId.isEmpty) {
    return '';
  }
  final typeLabel = entityType.isEmpty
      ? entityType
      : localizeEntityNodeTypeName(context, entityType);
  final target = '$typeLabel($entityId)';
  if (depth == null) {
    return target;
  }
  final depthLabel = context.t(
    LocaleKeys.toolDepthFmt,
    namedArgs: {'depth': '$depth'},
  );
  return '$target $depthLabel';
}

String? relationEndpointsLabel({
  required String sourceId,
  required String targetId,
  String? sourceLabel,
  String? targetLabel,
}) {
  final source =
      (sourceLabel?.trim().isNotEmpty == true ? sourceLabel! : sourceId).trim();
  final target =
      (targetLabel?.trim().isNotEmpty == true ? targetLabel! : targetId).trim();
  if (source.isEmpty && target.isEmpty) {
    return null;
  }
  if (source.isNotEmpty && target.isNotEmpty) {
    return '$source → $target';
  }
  return source.isNotEmpty ? source : target;
}

/// A running script has no known total; only settled calls are counted.
String codemodeActivitySummary(BuildContext context, AiToolCallBlock block) {
  final completed = block.nestedCalls
      .where((call) => call.status == AiNestedToolStatus.success)
      .length;
  final count = block.result?['completed_count'] is int
      ? block.result!['completed_count'] as int
      : completed;
  final failed = block.result?['failed_count'] is int
      ? block.result!['failed_count'] as int
      : 0;
  final key = switch (block.status) {
    AiToolCallStatus.pending ||
    AiToolCallStatus.running => LocaleKeys.aiCodemodeRunning,
    AiToolCallStatus.cancelled => LocaleKeys.aiCodemodeStopped,
    AiToolCallStatus.error ||
    AiToolCallStatus.rejected => LocaleKeys.aiCodemodeFailed,
    AiToolCallStatus.success =>
      failed > 0 ? LocaleKeys.aiCodemodePartial : LocaleKeys.aiCodemodeDone,
  };
  return context.t(key, namedArgs: {'count': '$count', 'failed': '$failed'});
}

String? codemodeFailureSummary(BuildContext context, AiToolCallBlock block) {
  if (block.toolName != 'Codemode' ||
      (block.status != AiToolCallStatus.error &&
          block.status != AiToolCallStatus.rejected)) {
    return null;
  }
  final key = switch (block.result?['error_code']) {
    'codemode_invalid_input' ||
    'codemode_script_error' => LocaleKeys.aiCodemodeErrorScript,
    'codemode_timeout' => LocaleKeys.aiCodemodeErrorTimeout,
    'codemode_memory_limit' ||
    'codemode_resource_limit' => LocaleKeys.aiCodemodeErrorLimit,
    'codemode_tool_forbidden' => LocaleKeys.aiCodemodeErrorForbidden,
    'codemode_busy' => LocaleKeys.aiCodemodeErrorBusy,
    _ => LocaleKeys.aiCodemodeErrorRuntime,
  };
  return context.t(key);
}

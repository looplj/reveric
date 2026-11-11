// 职责: Prompt 通用片段 — 生成环境、用户规则、路径规则、工具使用准则等无副作用文本片段。
// 关联文件:
//   lib/shared/services/ai/prompts/prompt_composer.dart
//   lib/shared/services/ai/tools.dart
//   lib/shared/models/ai_chat_models.dart

import '../../../models/agent_skill.dart';
import '../../../models/ai_chat_models.dart';
import '../../../models/subagent.dart';
import '../../../models/content_kind.dart';
import '../../../models/novel_type.dart';
import '../tools.dart' show pathSchema, pathSchemaFieldNotes;
import 'prompt_composer.dart';
import '../prompt_template.dart';

abstract final class PromptFragments {
  static Map<String, dynamic> orchestratorTemplateVariables() {
    return {
      'fragment_core_rules': _rawFragment(PromptFragmentPaths.coreRules),
      'fragment_chapter_reading_boundary': _rawFragment(
        PromptFragmentPaths.chapterReadingBoundary,
      ),
      'fragment_prose_quality_baseline': _rawFragment(
        PromptFragmentPaths.proseQualityBaseline,
      ),
      'fragment_writing_craft': _rawFragment(PromptFragmentPaths.writingCraft),
      'fragment_scene_reading_boundary': _rawFragment(
        PromptFragmentPaths.sceneReadingBoundary,
      ),
      'fragment_screenplay_craft': _rawFragment(
        PromptFragmentPaths.screenplayCraft,
      ),
    };
  }

  static Map<String, dynamic> agentTemplateVariables() {
    return {
      'fragment_chapter_reading_boundary': _rawFragment(
        PromptFragmentPaths.chapterReadingBoundary,
      ),
      'fragment_prose_quality_baseline': _rawFragment(
        PromptFragmentPaths.proseQualityBaseline,
      ),
      'fragment_writing_craft': _rawFragment(PromptFragmentPaths.writingCraft),
      'fragment_scene_reading_boundary': _rawFragment(
        PromptFragmentPaths.sceneReadingBoundary,
      ),
      'fragment_screenplay_craft': _rawFragment(
        PromptFragmentPaths.screenplayCraft,
      ),
    };
  }

  static String _rawFragment(String path) {
    if (!PromptTemplateService.isInitialized) {
      return '';
    }
    return PromptTemplateService.instance.rawAsset(path);
  }

  static String pathSchemaBlock({String kind = contentKindNovel}) {
    final buffer = StringBuffer();
    buffer.write(pathSchema(kind: kind));
    final fieldNotes = pathSchemaFieldNotes(kind: kind);
    if (fieldNotes.isNotEmpty) {
      buffer.writeln();
      buffer.writeln();
      buffer.writeln(
        '字段（未标类型为 string；* 为创建必需；readonly 不可传入写操作；nullable 表示可为空）：',
      );
      buffer.write(fieldNotes);
    }
    return buffer.toString().trim();
  }

  static String toolUseGuidelines({bool codemodeAvailable = false}) {
    final buffer = StringBuffer();
    buffer.writeln(
      '需补查以往对话时，使用 Run sessions，用法见 Run help sessions。按需读取相关内容；来源不明确时再询问，查不到时如实说明。',
    );
    buffer.writeln('- 需要读取、创建、修改或删除项目内容时，必须优先调用对应工具，不要只用文字声称已完成。');
    if (codemodeAvailable) {
      buffer.writeln(
        '- 需要组合多次工具调用、根据前一步结果继续操作，或用代码筛选、计算和整理返回结果时，优先使用 Codemode，只输出后续判断所需的信息。单次简单调用直接使用对应工具。',
      );
      buffer.writeln(
        '- 同一响应内的多个直接工具调用不能依赖彼此的结果。依赖调用可在 Codemode 脚本内 await 后继续；需要理解新内容或作出创作判断时，先返回相关材料，再决定后续操作。',
      );
    } else {
      buffer.writeln(
        '- 同一响应内的多个工具调用不能依赖彼此的结果。需要先拿到路径或 ID 时，本轮只调用 listing/query，收到结果后下一轮再操作。',
      );
    }
    buffer.writeln(
      '- 工具返回失败、报错或 skipped 时，不要直接跳过原任务，也不要把失败当作完成。先阅读错误原因和 hint。',
    );
    buffer.writeln('- 禁止用相同参数重试超过 2 次；not_found 后禁止原样重试。');
    buffer.writeln(
      '- 如果失败来自参数、路径、ID、上下文缺失或前置资源不存在，优先执行 hint 建议的查询，必要时用 Read / Glob / Grep / GraphSearch 查明实际状态，按返回的 path 修正参数或补齐前置步骤后重试。',
    );
    buffer.writeln(
      '- 如果目标需要特定工具（例如创建资源必须用 Create），工具失败后应围绕该工具或其前置条件继续解决，不能改用纯文本预览替代真实写入。',
    );
    return buffer.toString().trim();
  }

  /// 当前调用的作品身份，不随工具权限、persona 或跨作品读取目标变化。
  static String workContext(AiSessionContext context) {
    final workId = context.workId?.trim();
    if (workId == null || workId.isEmpty) {
      if ((context.databasePath?.trim().isNotEmpty ?? false) ||
          context.sourceNovelId != null ||
          context.workspacePath != null) {
        throw StateError('Bound work context is missing workId.');
      }
      return '未绑定作品';
    }
    if (!context.hasExplicitContentKind ||
        !const {
          contentKindNovel,
          contentKindScreenplay,
          contentKindCanvas,
        }.contains(context.contentKind)) {
      throw StateError('Bound work context requires an explicit contentKind.');
    }
    final root = '/works/$workId';
    if (context.workspacePath != null && context.workspacePath != root) {
      throw StateError('Work context root does not match workId.');
    }
    final sourceId = context.sourceNovelId?.trim();
    if (sourceId != null && sourceId.isEmpty) {
      throw StateError('Work context sourceNovelId must not be empty.');
    }
    final sourcePathLabel = switch (context.workType) {
      novelTypeAdaptation => '改编原作工作路径',
      novelTypeSequel => '前作工作路径',
      novelTypeFanfic => '同人原作工作路径',
      novelTypeDerivative => '二创来源工作路径',
      _ => '原作工作路径',
    };
    return [
      '当前作品类型：${context.contentKind == contentKindCanvas
          ? '画布'
          : context.contentKind == contentKindNovel
          ? '小说'
          : '剧本'}',
      '当前作品工作路径：$root',
      if (sourceId != null) '$sourcePathLabel：/works/$sourceId',
    ].join('\n');
  }

  static String userRules(String? rawRules) {
    final trimmed = rawRules?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return '';
    }

    final rules = trimmed
        .split(RegExp(r'\r?\n'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    if (rules.isEmpty) {
      return '';
    }

    return rules.map((rule) => '<user_rule>$rule</user_rule>').join('\n');
  }

  /// 与 orchestrator 尾部相同的「用户自定义规则」整块；无规则时返回空串。
  static String userRulesSection(String? rawRules) {
    final rules = userRules(rawRules);
    if (rules.isEmpty) {
      return '';
    }
    return const PromptComposer().compose([
      PromptSection(
        key: 'user_rules',
        title: '用户自定义规则',
        description: '以下是用户设定的规则，优先级高于默认行为。请始终遵守这些规则。',
        content: rules,
      ),
    ]);
  }

  static String availableSkills(List<AgentSkillSummary> skills) {
    if (skills.isEmpty) {
      return '';
    }
    final buffer = StringBuffer();
    buffer.writeln('# 可用 AgentSkills');
    buffer.writeln();
    buffer.writeln(
      '开始任务前，检查 <available_agent_skills> 中的 <when_to_use>；若有明确匹配当前任务或子任务的技能，先调用 AgentSkill 加载并遵循其指令，再执行对应工作。多个技能分别覆盖不同任务环节时，按需加载；没有匹配技能时直接执行任务。',
    );
    buffer.writeln('若当前上下文已有同名技能的完整指令，直接遵循，不要重复加载。');
    buffer.writeln();
    buffer.writeln('### Available skills');
    buffer.writeln();
    buffer.writeln('<available_agent_skills>');
    for (final skill in skills) {
      buffer.writeln('  <agent_skill>');
      buffer.writeln('    <name>${skill.name}</name>');
      final hint = skill.whenToUse.trim();
      final whenToUse = hint.isNotEmpty ? hint : skill.description.trim();
      if (whenToUse.isNotEmpty) {
        buffer.writeln('    <when_to_use>$whenToUse</when_to_use>');
      }
      buffer.writeln('  </agent_skill>');
    }
    buffer.writeln('</available_agent_skills>');
    return buffer.toString().trim();
  }

  static String subAgentIndex(List<SubAgent> agents) {
    if (agents.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.writeln('# 可内部调用的 SubAgent');
    buffer.writeln('以下 subagent 可通过 SpawnAgent 工具调用。');
    buffer.writeln();
    buffer.writeln('### Available subagents');
    buffer.writeln();
    buffer.writeln('<available_subagents>');
    for (final agent in agents) {
      buffer.writeln('  <subagent>');
      buffer.writeln('    <name>${agent.name}</name>');
      final desc = agent.description.trim();
      if (desc.isNotEmpty) {
        buffer.writeln('    <description>$desc</description>');
      }
      buffer.writeln('  </subagent>');
    }
    buffer.writeln('</available_subagents>');
    buffer.writeln();
    buffer.writeln('委派判断原则：');
    buffer.writeln('1. 按任务职责、输入范围与用户明确要求选择最匹配的 SubAgent。');
    buffer.writeln('2. 委派时带上必要的 path / ID / 字段路径，避免子任务靠猜测定位资源。');
    buffer.writeln('3. 用户自定义了承担同类职责的 SubAgent 时同样要用上，不要因为名字不同就忽略它。');
    return buffer.toString().trim();
  }
}

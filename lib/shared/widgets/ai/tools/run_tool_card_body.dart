// 职责: Run 工具卡片体 — 展示 agent-skills、agent-rules、subagents 等子命令的参数摘要与结果预览。
// 关联文件:
//   lib/shared/services/ai/run_command_parser.dart
//   lib/shared/widgets/ai/tools/tool_card_common.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/tool.json
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
import 'package:flutter/material.dart';

import 'package:reveric/shared/components/reveric_spinner.dart';
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/services/ai/run_command_parser.dart';
import 'package:reveric/shared/services/ai/tool_result_payloads.dart';
import 'tool_card_common.dart';
import 'tool_card_descriptor.dart';

/// Run 命令参数尚未解析出子命令时的 loading 占位（不展示「运行命令」卡片）。
class RunCommandLoadingBody extends StatelessWidget {
  const RunCommandLoadingBody({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: RevericSpinner(strokeWidth: 2, color: colors.accent),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.toolRunning),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

class RunToolCardBody extends StatelessWidget {
  const RunToolCardBody({super.key, required this.block});

  final AiToolCallBlock block;

  @override
  Widget build(BuildContext context) {
    final parsed = ParsedRunCommand.fromBlock(block);
    final topLevel = parsed?.topLevel;
    if (topLevel == 'agent-skills') {
      return _AgentSkillsRunCardBody(block: block, parsed: parsed);
    }
    if (topLevel == 'agent-rules') {
      return _AgentRulesRunCardBody(block: block, parsed: parsed);
    }
    if (topLevel == 'subagents') {
      return _SubagentsRunCardBody(block: block, parsed: parsed);
    }
    if (topLevel == 'map' && parsed?.subcommand == 'draft') {
      return _MapRunCardBody(block: block, parsed: parsed!);
    }
    return _GenericRunCardBody(block: block, parsed: parsed);
  }
}

class _MapRunCardBody extends StatelessWidget {
  const _MapRunCardBody({required this.block, required this.parsed});

  final AiToolCallBlock block;
  final ParsedRunCommand parsed;

  @override
  Widget build(BuildContext context) {
    final specs = <String>[];
    final style = parsed.option('style');
    final resolution = parsed.option('resolution');
    final quality = parsed.option('quality');
    if (style != null) specs.add(_localizedMapStyle(context, style));
    if (resolution != null) specs.add(resolution.toUpperCase());
    if (quality != null) specs.add(_localizedMapQuality(context, quality));
    final prompt = parsed.option('prompt');
    final succeeded =
        block.status == AiToolCallStatus.success &&
        aiToolResultStatus(block.result) == AiToolCallStatus.success;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: specs),
        if (prompt != null) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolRunMapPrompt),
            text: prompt,
            maxLines: 6,
          ),
        ],
        if (succeeded) ...[
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.toolRunMapReady),
            style: RevericTheme.typographyOf(
              context,
            ).uiSmall.copyWith(color: RevericTheme.colorsOf(context).success),
          ),
        ],
      ],
    );
  }
}

String _localizedMapStyle(BuildContext context, String value) {
  final key = switch (value) {
    'parchment' => LocaleKeys.toolRunMapStyleParchment,
    'inkmap' => LocaleKeys.toolRunMapStyleInkmap,
    'engraving' => LocaleKeys.toolRunMapStyleEngraving,
    'realistic' => LocaleKeys.toolRunMapStyleRealistic,
    'woodcut' => LocaleKeys.toolRunMapStyleWoodcut,
    'watercolor' => LocaleKeys.toolRunMapStyleWatercolor,
    'atlas' => LocaleKeys.toolRunMapStyleAtlas,
    _ => null,
  };
  return key == null ? value : context.t(key);
}

String _localizedMapQuality(BuildContext context, String value) {
  final key = switch (value) {
    'low' => LocaleKeys.toolRunMapQualityLow,
    'medium' => LocaleKeys.toolRunMapQualityMedium,
    'high' => LocaleKeys.toolRunMapQualityHigh,
    _ => null,
  };
  return key == null ? value : context.t(key);
}

class _AgentSkillsRunCardBody extends StatelessWidget {
  const _AgentSkillsRunCardBody({required this.block, required this.parsed});

  final AiToolCallBlock block;
  final ParsedRunCommand? parsed;

  @override
  Widget build(BuildContext context) {
    final subcommand = parsed?.subcommand;
    if (subcommand == 'list') {
      return _buildListBody(context);
    }
    if (subcommand == 'delete') {
      return _buildDeleteBody(context);
    }
    if (subcommand == 'search') {
      return _buildSearchBody(context);
    }
    if (subcommand == 'get' || subcommand == 'install') {
      return _buildCatalogBody(context);
    }
    return _buildMutationBody(context);
  }

  Widget _buildListBody(BuildContext context) {
    final entries = block.result?['entries'];
    final skillNames = <String>[];
    if (entries is List) {
      for (final entry in entries) {
        if (entry is! Map) {
          continue;
        }
        final name = entry['name']?.toString().trim() ?? '';
        if (name.isNotEmpty) {
          skillNames.add(name);
        }
      }
    }

    final scope = (block.result?['scope'] ?? parsed?.option('scope'))
        ?.toString()
        .trim();
    final chips = <String>[
      if (scope != null && scope.isNotEmpty)
        context.t(
          LocaleKeys.toolRunScopeFmt,
          namedArgs: {'scope': _localizedSkillScope(context, scope)},
        ),
      if (skillNames.isNotEmpty)
        context.t(
          LocaleKeys.toolRunSkillsCountFmt,
          namedArgs: {'count': '${skillNames.length}'},
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (skillNames.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolInfoChips(items: skillNames.take(8).toList(growable: false)),
        ],
      ],
    );
  }

  Widget _buildDeleteBody(BuildContext context) {
    final deletedId =
        block.result?['deleted_id']?.toString().trim() ??
        parsed?.option('id') ??
        '';
    return AiToolKeyValueList(
      entries: [
        if (deletedId.isNotEmpty) (context.t(LocaleKeys.toolTarget), deletedId),
      ],
    );
  }

  Widget _buildSearchBody(BuildContext context) {
    final query =
        block.result?['query']?.toString().trim() ??
        parsed?.option('query') ??
        '';
    final source =
        block.result?['source']?.toString().trim() ?? parsed?.option('source');
    final entries = block.result?['entries'];
    final total = block.result?['total'];
    final count = total is int
        ? total
        : total is num
        ? total.toInt()
        : entries is List
        ? entries.length
        : null;
    final chips = <String>[
      if (query.isNotEmpty) '"$query"',
      if (source != null && source.isNotEmpty)
        _localizedSkillSource(context, source),
      if (count != null && count > 0)
        context.t(
          LocaleKeys.toolResultCountFmt,
          namedArgs: {'count': '$count'},
        ),
    ];
    return AiToolInfoChips(items: chips);
  }

  Widget _buildCatalogBody(BuildContext context) {
    final name = runSkillNameFromBlock(block, parsed);
    final source =
        block.result?['source']?.toString().trim() ?? parsed?.option('source');
    final sourceId =
        block.result?['source_id']?.toString().trim() ??
        parsed?.option('source_id');
    final chips = <String>[
      if (name != null && name.isNotEmpty) name,
      if (source != null && source.isNotEmpty)
        _localizedSkillSource(context, source),
      if ((name == null || name.isEmpty) &&
          sourceId != null &&
          sourceId.isNotEmpty)
        sourceId,
    ];
    final preview =
        block.result?['description']?.toString().trim() ??
        block.result?['when_to_use']?.toString().trim() ??
        parsed?.option('description');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (preview != null && preview.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolPreview),
            text: preview,
            maxLines: 6,
          ),
        ],
      ],
    );
  }

  Widget _buildMutationBody(BuildContext context) {
    final name = runSkillNameFromBlock(block, parsed);
    final scope =
        (block.result?['skill'] is Map
            ? (block.result!['skill'] as Map)['scope']
            : null) ??
        parsed?.option('scope');
    final scopeText = scope?.toString().trim();
    final chips = <String>[
      if (name != null && name.isNotEmpty) name,
      if (scopeText != null && scopeText.isNotEmpty)
        context.t(
          LocaleKeys.toolRunScopeFmt,
          namedArgs: {'scope': _localizedSkillScope(context, scopeText)},
        ),
    ];

    final preview =
        parsed?.option('prompt') ??
        parsed?.option('description') ??
        _skillField(block, 'prompt') ??
        _skillField(block, 'description');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (preview != null && preview.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolPreview),
            text: preview,
            maxLines: 6,
          ),
        ],
      ],
    );
  }

  String? _skillField(AiToolCallBlock block, String field) {
    final skill = block.result?['skill'];
    if (skill is! Map) {
      return null;
    }
    final value = skill[field]?.toString().trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }
}

class _SubagentsRunCardBody extends StatelessWidget {
  const _SubagentsRunCardBody({required this.block, required this.parsed});

  final AiToolCallBlock block;
  final ParsedRunCommand? parsed;

  @override
  Widget build(BuildContext context) {
    final subcommand = parsed?.subcommand;
    if (subcommand == 'list') {
      return _buildListBody(context);
    }
    if (subcommand == 'delete') {
      return _buildDeleteBody(context);
    }
    return _buildMutationBody(context);
  }

  Widget _buildListBody(BuildContext context) {
    final entries = block.result?['entries'];
    final names = <String>[];
    if (entries is List) {
      for (final entry in entries) {
        if (entry is! Map) {
          continue;
        }
        final name = entry['name']?.toString().trim() ?? '';
        if (name.isNotEmpty) {
          names.add(name);
        }
      }
    }

    final chips = <String>[
      if (names.isNotEmpty)
        context.t(
          LocaleKeys.toolRunSubagentsCountFmt,
          namedArgs: {'count': '${names.length}'},
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (names.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolInfoChips(items: names.take(8).toList(growable: false)),
        ],
      ],
    );
  }

  Widget _buildDeleteBody(BuildContext context) {
    final deletedId =
        block.result?['deleted_id']?.toString().trim() ??
        parsed?.option('id') ??
        '';
    return AiToolKeyValueList(
      entries: [
        if (deletedId.isNotEmpty) (context.t(LocaleKeys.toolTarget), deletedId),
      ],
    );
  }

  Widget _buildMutationBody(BuildContext context) {
    final name = runSubagentNameFromBlock(block, parsed);
    final chips = <String>[if (name != null && name.isNotEmpty) name];

    final preview =
        parsed?.option('prompt') ??
        parsed?.option('description') ??
        _subagentField(block, 'prompt') ??
        _subagentField(block, 'description');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (preview != null && preview.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolPreview),
            text: preview,
            maxLines: 6,
          ),
        ],
      ],
    );
  }

  String? _subagentField(AiToolCallBlock block, String field) {
    final subagent = block.result?['subagent'];
    if (subagent is! Map) {
      return null;
    }
    final value = subagent[field]?.toString().trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }
}

class _AgentRulesRunCardBody extends StatelessWidget {
  const _AgentRulesRunCardBody({required this.block, required this.parsed});

  final AiToolCallBlock block;
  final ParsedRunCommand? parsed;

  @override
  Widget build(BuildContext context) {
    final subcommand = parsed?.subcommand;
    if (subcommand == 'list') {
      return _buildListBody(context);
    }
    if (subcommand == 'delete') {
      return _buildDeleteBody(context);
    }
    return _buildMutationBody(context);
  }

  Widget _buildListBody(BuildContext context) {
    final rules = block.result?['rules'];
    final ruleNames = <String>[];
    if (rules is List) {
      for (final entry in rules) {
        if (entry is! Map) {
          continue;
        }
        final name = entry['name']?.toString().trim() ?? '';
        if (name.isNotEmpty) {
          ruleNames.add(name);
        }
      }
    }
    final count = block.result?['count'];
    final resolvedCount = count is int
        ? count
        : count is num
        ? count.toInt()
        : ruleNames.length;
    final chips = <String>[
      if (resolvedCount > 0)
        context.t(
          LocaleKeys.toolRunRulesAvailableFmt,
          namedArgs: {'count': '$resolvedCount'},
        )
      else
        context.t(LocaleKeys.toolRunRulesEmpty),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (ruleNames.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolInfoChips(items: ruleNames.take(8).toList(growable: false)),
        ],
      ],
    );
  }

  Widget _buildDeleteBody(BuildContext context) {
    final deletedName = runRuleNameFromBlock(block, parsed) ?? '';
    return AiToolKeyValueList(
      entries: [
        if (deletedName.isNotEmpty)
          (context.t(LocaleKeys.toolRunDeletedRule), deletedName),
      ],
    );
  }

  Widget _buildMutationBody(BuildContext context) {
    final name = runRuleNameFromBlock(block, parsed);
    final newName = parsed?.option('new-name');
    final preview = runRuleContentFromBlock(block, parsed);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolKeyValueList(
          entries: [
            if (name != null && name.isNotEmpty)
              (context.t(LocaleKeys.toolRunRuleName), name),
            if (newName != null && newName.isNotEmpty)
              (context.t(LocaleKeys.toolRunRuleNewName), newName),
          ],
        ),
        if (preview != null && preview.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolRunRuleContent),
            text: preview,
            maxLines: 6,
          ),
        ],
      ],
    );
  }
}

class _GenericRunCardBody extends StatelessWidget {
  const _GenericRunCardBody({required this.block, required this.parsed});

  final AiToolCallBlock block;
  final ParsedRunCommand? parsed;

  @override
  Widget build(BuildContext context) {
    final target = toolRowTarget(context, block, null);
    final output = block.result?['output']?.toString().trim();
    final chips = <String>[if (target != null && target.isNotEmpty) target];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiToolInfoChips(items: chips),
        if (output != null && output.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          AiToolPreviewBlock(
            label: context.t(LocaleKeys.toolExecutionResult),
            text: output,
            monospace: true,
            maxLines: 8,
          ),
        ],
      ],
    );
  }
}

String _localizedSkillScope(BuildContext context, String scope) {
  return switch (scope) {
    'global' => context.t(LocaleKeys.agentSkillGlobal),
    'novel' => context.t(LocaleKeys.agentSkillNovel),
    _ => scope,
  };
}

String _localizedSkillSource(BuildContext context, String source) {
  return switch (source) {
    'library' => context.t(LocaleKeys.agentSkillSourceLibrary),
    'official' => context.t(LocaleKeys.agentSkillSourceOfficial),
    'marketplace' => context.t(LocaleKeys.agentSkillSourceMarketplace),
    _ => source,
  };
}

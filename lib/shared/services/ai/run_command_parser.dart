// 职责: Run 工具命令解析 — 解析结构化 command/subcommand/options、判断 UI 展示阶段与图片子命令映射。
// 关联文件:
//   lib/desktop/widgets/ai/tools/run_tool_card_body.dart
//   lib/desktop/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/models/ai_message_block.dart
import '../../models/ai_message_block.dart';

/// Run 命令在 UI 上是否已能展示具体子命令卡片（而非 loading）。
enum RunCommandUiPhase { pending, awaitingSubcommand, ready }

class RunCommandUiResolution {
  const RunCommandUiResolution({
    required this.phase,
    this.parsed,
    this.imageToolName,
  });

  final RunCommandUiPhase phase;
  final ParsedRunCommand? parsed;

  /// 当 [phase] 为 [RunCommandUiPhase.ready] 且为人物 / 物品生图命令时的专用图片工具名。
  final String? imageToolName;

  bool get isReady => phase == RunCommandUiPhase.ready;
}

RunCommandUiResolution resolveRunCommandUi(Map<String, dynamic> arguments) {
  final parsed = ParsedRunCommand.fromArguments(arguments);
  final topLevel = parsed.topLevel;
  if (topLevel == null || topLevel.isEmpty) {
    return RunCommandUiResolution(
      phase: RunCommandUiPhase.pending,
      parsed: parsed,
    );
  }
  if (topLevel == 'help') {
    if ((parsed.subcommand ?? '').isEmpty) {
      return RunCommandUiResolution(
        phase: RunCommandUiPhase.awaitingSubcommand,
        parsed: parsed,
      );
    }
    return RunCommandUiResolution(
      phase: RunCommandUiPhase.ready,
      parsed: parsed,
    );
  }
  if (topLevel == 'character' || topLevel == 'item') {
    final sub = parsed.subcommand?.trim() ?? '';
    if (sub.isEmpty) {
      return RunCommandUiResolution(
        phase: RunCommandUiPhase.awaitingSubcommand,
        parsed: parsed,
      );
    }
    return RunCommandUiResolution(
      phase: RunCommandUiPhase.ready,
      parsed: parsed,
      imageToolName: switch ('$topLevel $sub') {
        'character generate-avatar' => 'GenerateAvatar',
        'character generate-photo' || 'item generate-photo' => 'GeneratePhoto',
        _ => null,
      },
    );
  }
  const needsSubcommand = {
    'debug',
    'agent-skills',
    'subagents',
    'themes',
    'agent-rules',
    'sessions',
    'map',
  };
  if (needsSubcommand.contains(topLevel)) {
    final sub = parsed.subcommand?.trim() ?? '';
    if (sub.isEmpty) {
      return RunCommandUiResolution(
        phase: RunCommandUiPhase.awaitingSubcommand,
        parsed: parsed,
      );
    }
    return RunCommandUiResolution(
      phase: RunCommandUiPhase.ready,
      parsed: parsed,
    );
  }
  return RunCommandUiResolution(phase: RunCommandUiPhase.ready, parsed: parsed);
}

String? imageToolNameForRunArguments(Map<String, dynamic> arguments) {
  return resolveRunCommandUi(arguments).imageToolName;
}

bool isRunToolCallReadyForDisplay(AiToolCallBlock block) {
  if (block.toolName != 'Run') {
    return true;
  }
  // 已终态的 Run（例如 SubAgent 落库后）可能缺少 arguments.command；
  // 不应再展示流式「准备中 / 执行中」占位。
  if (block.status == AiToolCallStatus.success ||
      block.status == AiToolCallStatus.error ||
      block.status == AiToolCallStatus.rejected ||
      block.status == AiToolCallStatus.cancelled) {
    return true;
  }
  return resolveRunCommandUi(block.arguments).isReady;
}

class ParsedRunCommand {
  const ParsedRunCommand({
    this.topLevel,
    this.subcommand,
    this.options = const {},
  });

  final String? topLevel;
  final String? subcommand;
  final Map<String, dynamic> options;

  static ParsedRunCommand? fromBlock(AiToolCallBlock block) {
    final parsed = fromArguments(block.arguments);
    if (parsed.topLevel == null) {
      final resultCommand = block.result?['command']?.toString().trim() ?? '';
      if (resultCommand.isEmpty) {
        return null;
      }
      final parts = resultCommand.split(RegExp(r'\s+'));
      return ParsedRunCommand(
        topLevel: parts.isNotEmpty ? parts.first : null,
        subcommand: parts.length > 1 ? parts[1] : null,
      );
    }
    return parsed;
  }

  static ParsedRunCommand fromArguments(Map<String, dynamic> arguments) {
    final command = arguments['command']?.toString().trim();
    if (command == null || command.isEmpty) {
      return const ParsedRunCommand();
    }
    final subcommand = arguments['subcommand']?.toString().trim();
    final rawOptions = arguments['options'];
    final options = rawOptions is Map
        ? Map<String, dynamic>.from(rawOptions)
        : const <String, dynamic>{};
    return ParsedRunCommand(
      topLevel: command,
      subcommand: subcommand == null || subcommand.isEmpty ? null : subcommand,
      options: options,
    );
  }

  static ParsedRunCommand parse(
    String command, {
    Map<String, dynamic>? options,
  }) {
    final parts = command
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) {
      return const ParsedRunCommand();
    }
    if (parts.length > 2) {
      return ParsedRunCommand(topLevel: command);
    }
    if (parts.first == 'help') {
      return ParsedRunCommand(
        topLevel: 'help',
        subcommand: parts.length > 1 ? parts[1] : null,
        options: options ?? const {},
      );
    }
    return ParsedRunCommand(
      topLevel: parts.first,
      subcommand: parts.length > 1 ? parts[1] : null,
      options: options ?? const {},
    );
  }

  String? option(String name) {
    final value = options[name]?.toString().trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  static String? commandLabelFromBlock(AiToolCallBlock block) {
    final resultCommand = block.result?['command']?.toString().trim() ?? '';
    if (resultCommand.isNotEmpty) {
      return resultCommand;
    }
    final parsed = fromBlock(block);
    if (parsed?.topLevel == null) {
      return null;
    }
    final parts = <String>[parsed!.topLevel!];
    if (parsed.subcommand != null && parsed.subcommand!.isNotEmpty) {
      parts.add(parsed.subcommand!);
    }
    return parts.join(' ');
  }
}

String? runSkillNameFromBlock(AiToolCallBlock block, ParsedRunCommand? parsed) {
  final skill = block.result?['skill'];
  if (skill is Map) {
    final name = skill['name']?.toString().trim();
    if (name != null && name.isNotEmpty) {
      return name;
    }
  }
  final resultName = block.result?['name']?.toString().trim();
  if (resultName != null && resultName.isNotEmpty) {
    return resultName;
  }
  return parsed?.option('name');
}

String? runSubagentNameFromBlock(
  AiToolCallBlock block,
  ParsedRunCommand? parsed,
) {
  final subagent = block.result?['subagent'];
  if (subagent is Map) {
    final name = subagent['name']?.toString().trim();
    if (name != null && name.isNotEmpty) {
      return name;
    }
  }
  return parsed?.option('name');
}

String? runRuleNameFromBlock(AiToolCallBlock block, ParsedRunCommand? parsed) {
  final resultName = block.result?['name']?.toString().trim();
  if (resultName != null && resultName.isNotEmpty) {
    return resultName;
  }
  return parsed?.option('name');
}

String? runRuleContentFromBlock(
  AiToolCallBlock block,
  ParsedRunCommand? parsed,
) {
  return parsed?.option('content');
}

// 职责: 展示批量处理摘要，展开子调用时才解析完整详情，脚本与输出按需展开。
// 关联文件:
//   lib/shared/widgets/ai/agent_round_detail_dialog.dart
//   lib/shared/widgets/ai/tool_activity_group.dart
//   lib/shared/models/ai_nested_tool_call.dart
//   lib/shared/services/debug/codemode_replay_orchestrator.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../agent/agent_run_state.dart';
import '../../../components/reveric_button.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/ai_message_block.dart';
import '../../../providers/canvas_providers.dart';
import '../../../providers/codemode_provider.dart';
import '../../../providers/novel_providers.dart';
import '../../../providers/settings_providers.dart';
import '../../../services/debug/codemode_replay_orchestrator.dart';
import '../../../theme/theme.dart';
import '../agent_round_detail_dialog.dart';
import '../tool_activity_group.dart';
import 'tool_card_descriptor.dart';
import 'codemode_row_summary.dart';

Future<void> showCodemodeDetail(
  BuildContext context, {
  required AiToolCallBlock block,
  String? databasePath,
  String? novelId,
}) => AgentRoundDetailDialog.show(
  context,
  runState: AgentRunState(
    agentId: block.callId,
    agentName: localizedToolName(context, block.toolName),
    round: 0,
    blocks: const [],
    isComplete:
        block.status != AiToolCallStatus.pending &&
        block.status != AiToolCallStatus.running,
  ),
  title: localizedToolName(context, block.toolName),
  databasePath: databasePath,
  novelId: novelId,
  scrollContentBuilder: (controller) => AiToolStepList.codemode(
    block: block,
    databasePath: databasePath,
    novelId: novelId,
    scrollController: controller,
    footer: _CodemodeScript(block: block, databasePath: databasePath),
  ),
);

/// 折叠列表只提取行头字段；正文与完整结果仍在展开时解析。
List<AiToolCallBlock> codemodeNestedBlocks(AiToolCallBlock block) => [
  for (final call in block.nestedCalls)
    AiToolCallBlock(
      id: '${block.id}/${call.callId}',
      callId: call.callId,
      toolName: call.toolName,
      arguments: codemodeRowArguments(call),
      status: switch (call.status) {
        AiNestedToolStatus.running => AiToolCallStatus.running,
        AiNestedToolStatus.success => AiToolCallStatus.success,
        AiNestedToolStatus.error => AiToolCallStatus.error,
        AiNestedToolStatus.cancelled => AiToolCallStatus.cancelled,
        AiNestedToolStatus.rejected => AiToolCallStatus.rejected,
      },
      targetPath: call.targetPath,
      metadata: call.source == 'mcp'
          ? {
              'tool_source': 'mcp',
              'mcp_server': call.server,
              'mcp_tool': call.remoteToolName,
              'execution_state': call.executionState,
              'source_session_id': call.sourceSessionId,
              'parent_call_id': call.parentCallId,
            }
          : null,
      result: codemodeRowResult(call),
    ),
];

/// 仅由展开行调用。旧记录中无法解码的截断结果仍按原文展示。
AiToolCallBlock codemodeNestedDetails(
  AiToolCallBlock summary,
  AiNestedToolCall call,
) {
  final arguments = call.argumentsPreview;
  final result = call.resultPreview;
  return summary.copyWith(
    arguments: _decode(arguments) ?? const {},
    result: result.isEmpty ? null : _decode(result) ?? {'output': result},
  );
}

Map<String, dynamic>? _decode(String preview) {
  try {
    final value = jsonDecode(preview);
    return value is Map<String, dynamic> ? value : null;
  } on FormatException {
    return null;
  }
}

class _CodemodeScript extends HookConsumerWidget {
  const _CodemodeScript({required this.block, this.databasePath});
  final AiToolCallBlock block;
  final String? databasePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = useState(false);
    final debugMode = ref.watch(appDebugModeProvider);
    final failure = debugMode
        ? block.errorMessage ?? codemodeFailureSummary(context, block)
        : null;
    final code = block.arguments['code'];
    final path = databasePath;
    final canReplay =
        debugMode &&
        path != null &&
        code is String &&
        code.isNotEmpty &&
        block.status != AiToolCallStatus.pending &&
        block.status != AiToolCallStatus.running;
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    String display(Object? value) => value is String
        ? value
        : const JsonEncoder.withIndent('  ').convert(value);
    final result = block.result;
    final output = !expanded.value
        ? ''
        : [
            if (result?['output'] case final List lines) ...lines.map(display),
            if (result != null && result.containsKey('return_value'))
              display(result['return_value']),
          ].join('\n');
    Widget panel(String text) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(RevericSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.large),
      ),
      child: SelectableText(
        text,
        style: typo.mono.copyWith(color: colors.textPrimary),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (failure != null)
          Container(
            margin: const EdgeInsets.only(bottom: RevericSpacing.sm),
            padding: const EdgeInsets.all(RevericSpacing.sm),
            decoration: BoxDecoration(
              color: colors.deletionBg,
              borderRadius: BorderRadius.circular(RevericRadius.medium),
            ),
            child: Text(
              failure,
              style: typo.uiSmall.copyWith(color: colors.deletionBorder),
            ),
          ),
        Semantics(
          expanded: expanded.value,
          child: InkWell(
            onTap: () => expanded.value = !expanded.value,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Text(
                    context.t(LocaleKeys.aiCodemodeSource),
                    style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                  ),
                  const Spacer(),
                  RevericIcon(
                    expanded.value
                        ? RevericIcons.expand_less_rounded
                        : RevericIcons.expand_more_rounded,
                    size: 15,
                    color: colors.textSubtle,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (canReplay)
          Align(
            alignment: Alignment.centerRight,
            child: RevericButton.text(
              label: context.t(LocaleKeys.aiCodemodeRerun),
              icon: RevericIcons.arrow_clockwise,
              size: RevericButtonSize.compact,
              onPressed: () => _replay(context, databasePath: path, code: code),
            ),
          ),
        if (expanded.value) ...[
          panel('${block.arguments['code'] ?? ''}'),
          if (output.isNotEmpty) ...[
            const SizedBox(height: RevericSpacing.md),
            Text(
              context.t(LocaleKeys.aiCodemodeOutput),
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: RevericSpacing.xs),
            panel(output),
          ],
        ],
      ],
    );
  }
}

/// 调试重放：关掉弹窗让画布露出来，再把脚本在当前作品里跑一遍，结果用 SnackBar 报。
///
/// 弹窗关闭后本组件已卸载，依赖的 autoDispose provider 由这里显式 listen 持有，
/// 跑完再释放；同名资源已存在等冲突按脚本自身的失败处理，不做清理。
Future<void> _replay(
  BuildContext context, {
  required String databasePath,
  required String code,
}) async {
  final container = ProviderScope.containerOf(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  // SnackBar 文案用 messenger 自己的 context 取：弹窗的 context 马上就卸载了。
  final messageContext = messenger?.context;
  Navigator.of(context).pop();

  final contentLease = container.listen(
    novelContentServiceProvider(databasePath),
    (_, _) {},
  );
  final overlayLease = container.listen(
    workingOverlayServiceProvider(databasePath),
    (_, _) {},
  );
  try {
    final result = await CodemodeReplayOrchestrator().run(
      code: code,
      contentService: contentLease.read(),
      workingOverlayService: overlayLease.read(),
      scheduler: container.read(codemodeSchedulerProvider),
      providerReader: () async => (await container.read(
        appSettingsProvider.future,
      )).aiSettings.providers,

      canvasActivityReporter: (activity) =>
          container.read(canvasAiActivityProvider.notifier).report(activity),
    );
    if (messenger == null ||
        messageContext == null ||
        !messageContext.mounted) {
      return;
    }
    final summary = AiToolCallBlock(
      id: 'debug_replay',
      callId: 'debug_replay',
      toolName: 'Codemode',
      arguments: {'code': code},
      status: result['ok'] == false
          ? AiToolCallStatus.error
          : AiToolCallStatus.success,
      result: result,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          codemodeFailureSummary(messageContext, summary) ??
              codemodeActivitySummary(messageContext, summary),
        ),
      ),
    );
  } finally {
    contentLease.close();
    overlayLease.close();
  }
}

// 职责: 展示冻结工具请求摘要与详情弹窗，按用户选择批准一次或保存作用域规则，并供运行条定位到卡片。
// 关联文件:
//   lib/shared/agent/tool_approval.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/widgets/ai/tool_permission_controls.dart
//   lib/shared/widgets/ai/tool_operation_activity.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../agent/tool_approval.dart';
import '../../logger/app_logger.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_dialog.dart';
import '../../components/reveric_icon_button.dart';
import '../../components/reveric_select.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../providers/ai_providers.dart';
import '../../theme/theme.dart';
import 'tools/tool_card_descriptor.dart';
import 'tool_permission_controls.dart';

final _log = AppLogger.forModule('ToolApproval');

/// 卡片左侧图标方块的边长；详情、提示与错误行按它缩进，和标题左边对齐。
const _tileSize = 32.0;
const _textIndent = _tileSize + RevericSpacing.md;

/// 一行摘要最多取的事实条数；完整事实在详情弹窗里。
const _briefFacts = 3;
const _briefFactMaxLength = 32;

/// 把承载审批卡的消息滚进构建范围；参数为审批 id 与审批卡挂靠的工具调用 id。
typedef ToolApprovalRevealer =
    Future<void> Function(String approvalId, String hostCallId);

/// 待审批卡的锚点：运行条据此滚到卡片并短暂高亮。
class ToolApprovalLocator {
  final _anchors = <String, GlobalKey>{};
  final _revealers = <ToolApprovalRevealer>{};
  final focused = ValueNotifier<String?>(null);
  Timer? _focusTimer;

  /// 懒加载的消息列表注册揭示器：卡片所在消息不在构建范围时由列表先滚过去。
  void addRevealer(ToolApprovalRevealer revealer) => _revealers.add(revealer);

  void removeRevealer(ToolApprovalRevealer revealer) =>
      _revealers.remove(revealer);

  /// 同一审批可能在多个聊天视图里各有一张卡；最后挂载的那张作为定位目标。
  void register(String approvalId, GlobalKey key) => _anchors[approvalId] = key;

  void release(String approvalId, GlobalKey key) {
    if (identical(_anchors[approvalId], key)) {
      _anchors.remove(approvalId);
    }
  }

  void locate(String approvalId, {required String hostCallId}) {
    if (focus(approvalId)) {
      return;
    }
    for (final reveal in _revealers.toList()) {
      unawaited(reveal(approvalId, hostCallId));
    }
  }

  /// 卡片已挂载时滚到卡片并高亮；未挂载返回 false。
  bool focus(String approvalId) {
    final target = _anchors[approvalId]?.currentContext;
    if (target == null) {
      return false;
    }
    unawaited(
      Scrollable.ensureVisible(
        target,
        alignment: 0.5,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      ),
    );
    focused.value = approvalId;
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 1600), () {
      focused.value = null;
    });
    return true;
  }

  void dispose() {
    _focusTimer?.cancel();
    focused.dispose();
  }
}

final toolApprovalLocatorProvider = Provider<ToolApprovalLocator>((ref) {
  final locator = ToolApprovalLocator();
  ref.onDispose(locator.dispose);
  return locator;
});

class ToolApprovalCard extends HookConsumerWidget {
  const ToolApprovalCard({super.key, required this.request});
  final AiToolApprovalRequest request;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = useState(-1);
    final typography = RevericTheme.typographyOf(context);
    final colors = RevericTheme.colorsOf(context);
    final controller = ref.watch(aiToolApprovalControllerProvider);
    final locator = ref.watch(toolApprovalLocatorProvider);
    final focused = useValueListenable(locator.focused) == request.approvalId;
    final anchor = useMemoized(GlobalKey.new);
    useEffect(() {
      locator.register(request.approvalId, anchor);
      return () => locator.release(request.approvalId, anchor);
    }, [request.approvalId]);
    Future<void> resolve(bool allow) async {
      final scopes = request.permissionContext.scopes;
      try {
        await controller.resolve(
          request,
          allow: allow,
          scope: allow && selection.value >= 0 ? scopes[selection.value] : null,
        );
      } catch (error, stackTrace) {
        _log.error(
          'saving approval rule failed approval=${request.approvalId}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    final facts = _facts(context, request.arguments);
    final brief = _brief(facts, request);
    final busy = request.resolving;
    final danger = _isDestructive(request.action);
    Future<void> openDetails() async {
      final allow = await showRevericDialog<bool>(
        context: context,
        builder: (_) => _ToolApprovalDetailsDialog(
          request: request,
          facts: facts,
          selection: selection,
        ),
      );
      if (allow != null) {
        await resolve(allow);
      }
    }

    final indented = const EdgeInsets.only(
      left: _textIndent,
      top: RevericSpacing.sm,
    );
    return KeyedSubtree(
      key: anchor,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: RevericSpacing.sm),
        padding: const EdgeInsets.fromLTRB(
          RevericSpacing.md,
          RevericSpacing.md,
          RevericSpacing.md,
          RevericSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.large),
          border: Border.all(
            color: focused ? colors.accent : colors.borderSubtle,
          ),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: colors.accent.withValues(alpha: 0.18),
                    spreadRadius: 3,
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ActionTile(action: request.action),
                const SizedBox(width: RevericSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        toolPermissionActionLabel(context, request.action),
                        style: typography.uiSemibold.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      Text(
                        request.targetLabel ?? request.targetPath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typography.uiSmall.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      if (facts.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(
                            top: RevericSpacing.xxs,
                          ),
                          child: Row(
                            children: [
                              if (brief.isNotEmpty) ...[
                                Flexible(
                                  child: Text(
                                    brief,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: typography.uiTiny.copyWith(
                                      color: colors.textMuted,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: RevericSpacing.sm),
                              ],
                              InkWell(
                                onTap: openDetails,
                                borderRadius: BorderRadius.circular(
                                  RevericRadius.small,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      context.t(LocaleKeys.aiApprovalDetails),
                                      style: typography.uiTinySemibold.copyWith(
                                        color: colors.textSecondary,
                                      ),
                                    ),
                                    RevericIcon(
                                      RevericIcons.caret_right,
                                      size: 10,
                                      color: colors.textSecondary,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (_disclosure(request.action) case final key?)
              Padding(
                padding: indented,
                child: Text(
                  context.t(key),
                  style: typography.uiTiny.copyWith(color: colors.textMuted),
                ),
              ),
            if (request.saveFailed)
              Padding(padding: indented, child: const _SaveFailedNotice()),
            Padding(
              padding: const EdgeInsets.only(top: RevericSpacing.md),
              child: Divider(height: 1, color: colors.borderSubtle),
            ),
            const SizedBox(height: RevericSpacing.sm),
            _DecisionBar(
              request: request,
              selection: selection,
              busy: busy,
              danger: danger,
              onDecide: resolve,
            ),
          ],
        ),
      ),
    );
  }
}

/// 删除类能力的审批用危险色，其余保持中性。
bool _isDestructive(String action) => action == 'files.remove';

/// 读文件会把文件信息或内容交给模型，审批时提前说明。
String? _disclosure(String action) =>
    action == 'files.read' ? LocaleKeys.aiPermissionFileDisclosure : null;

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.action});
  final String action;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final danger = _isDestructive(action);
    return Container(
      width: _tileSize,
      height: _tileSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: danger ? colors.deletionBg : colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
      child: RevericIcon(
        toolPermissionActionIcon(action),
        size: 16,
        color: danger ? colors.deletionBorder : colors.textSecondary,
      ),
    );
  }
}

class _SaveFailedNotice extends StatelessWidget {
  const _SaveFailedNotice();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typography = RevericTheme.typographyOf(context);
    return Row(
      children: [
        RevericIcon(
          RevericIcons.warning_circle,
          size: 13,
          color: colors.warningText,
        ),
        const SizedBox(width: RevericSpacing.xs),
        Expanded(
          child: Text(
            context.t(LocaleKeys.aiPermissionSaveFailed),
            style: typography.uiTinySemibold.copyWith(
              color: colors.warningText,
            ),
          ),
        ),
      ],
    );
  }
}

/// 适用范围 + 拒绝 / 允许；卡片和详情弹窗共用同一个范围选择。
class _DecisionBar extends StatelessWidget {
  const _DecisionBar({
    required this.request,
    required this.selection,
    required this.busy,
    required this.danger,
    required this.onDecide,
  });
  final AiToolApprovalRequest request;
  final ValueNotifier<int> selection;
  final bool busy, danger;
  final ValueChanged<bool> onDecide;

  @override
  Widget build(BuildContext context) {
    final scopes = request.permissionContext.scopes;
    final allowLabel = context.t(LocaleKeys.aiPermissionAllow);
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: IntrinsicWidth(
              child: ValueListenableBuilder(
                valueListenable: selection,
                builder: (context, value, _) => ToolPermissionSelector<int>(
                  value: value,
                  compact: true,
                  menuWidth: 176,
                  items: [
                    RevericSelectItem(
                      value: -1,
                      label: context.t(LocaleKeys.aiPermissionOnce),
                    ),
                    for (var index = 0; index < scopes.length; index++)
                      RevericSelectItem(
                        value: index,
                        label: context.t(
                          LocaleKeys.aiPermissionScopeAlways,
                          namedArgs: {
                            'scope': toolPermissionScopeLabel(
                              context,
                              scopes[index].type,
                            ),
                          },
                        ),
                      ),
                  ],
                  onChanged: busy ? null : (value) => selection.value = value,
                ),
              ),
            ),
          ),
        ),
        RevericButton.text(
          label: context.t(LocaleKeys.aiPermissionDeny),
          size: RevericButtonSize.compact,
          onPressed: busy ? null : () => onDecide(false),
        ),
        const SizedBox(width: RevericSpacing.xs),
        danger
            ? RevericButton.danger(
                label: allowLabel,
                size: RevericButtonSize.compact,
                loading: busy,
                onPressed: busy ? null : () => onDecide(true),
              )
            : RevericButton.primary(
                label: allowLabel,
                size: RevericButtonSize.compact,
                loading: busy,
                onPressed: busy ? null : () => onDecide(true),
              ),
      ],
    );
  }
}

/// 冻结请求的完整事实。弹窗只负责查看和选择，返回 true / false 由卡片执行决定；
/// 请求在别处被处理或取消时自行关闭。
class _ToolApprovalDetailsDialog extends HookWidget {
  const _ToolApprovalDetailsDialog({
    required this.request,
    required this.facts,
    required this.selection,
  });
  final AiToolApprovalRequest request;
  final List<_Fact> facts;
  final ValueNotifier<int> selection;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typography = RevericTheme.typographyOf(context);
    useEffect(() {
      var live = true;
      unawaited(
        request.decision.then((_) {
          // 弹窗自己按下允许/拒绝后仍在退出动画中，此时已不是栈顶；
          // 再 pop 会关掉下面的页面。
          if (live &&
              context.mounted &&
              ModalRoute.of(context)?.isCurrent == true) {
            Navigator.of(context).pop();
          }
        }),
      );
      return () => live = false;
    }, [request]);
    // 列表与长文本占整宽独立成节，短值留在顶部按行对齐。
    bool isSection(_Fact fact) => fact.value is List || _isLongText(fact.value);
    final scalars = [
      for (final fact in facts)
        // 已登记的开关只在开启时出现，整行写字段名。
        if (!isSection(fact) && (fact.value != false || !fact.known)) fact,
    ];
    final sections = [
      for (final fact in facts)
        if (isSection(fact)) fact,
    ];
    final danger = _isDestructive(request.action);
    final muted = typography.uiTiny.copyWith(color: colors.textMuted);
    final mono = typography.mono.copyWith(
      fontSize: typography.uiTiny.fontSize,
      height: 1.6,
      color: colors.textSecondary,
    );
    return RevericDialog.panel(
      width: _dialogWidth,
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ActionTile(action: request.action),
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  toolPermissionActionLabel(context, request.action),
                  style: typography.uiSemibold.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                SelectableText(
                  request.targetLabel ?? request.targetPath,
                  style: typography.uiSmall.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          RevericIconButton(
            icon: RevericIcons.close,
            tooltip: context.t(LocaleKeys.commonClose),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final fact in scalars)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: fact.value == true && fact.known
                          ? Text(
                              fact.label,
                              style: typography.uiSmall.copyWith(
                                color: colors.textPrimary,
                              ),
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: _factLabelWidth,
                                  child: Text(
                                    fact.label,
                                    style: typography.uiSmall.copyWith(
                                      color: colors.textMuted,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: RevericSpacing.md),
                                Expanded(
                                  child: SelectableText(
                                    _factText(fact.value),
                                    style: typography.uiSmall.copyWith(
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  for (final fact in sections) ...[
                    const SizedBox(height: RevericSpacing.lg),
                    Text(
                      fact.label,
                      style: typography.uiTinySemibold.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                    const SizedBox(height: RevericSpacing.xs),
                    if (fact.value case final String text)
                      _FactBox(
                        child: SelectableText(
                          text,
                          style: typography.uiSmall.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      )
                    else
                      _FactList(
                        fact: fact,
                        danger: danger,
                        style: mono,
                        countStyle: muted,
                      ),
                  ],
                  if (_disclosure(request.action) case final key?) ...[
                    const SizedBox(height: RevericSpacing.lg),
                    Text(context.t(key), style: muted),
                  ],
                  if (request.saveFailed) ...[
                    const SizedBox(height: RevericSpacing.sm),
                    const _SaveFailedNotice(),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: RevericSpacing.lg),
          Divider(height: 1, color: colors.borderSubtle),
          const SizedBox(height: RevericSpacing.md),
          _DecisionBar(
            request: request,
            selection: selection,
            busy: false,
            danger: danger,
            onDecide: (allow) => Navigator.of(context).pop(allow),
          ),
        ],
      ),
    );
  }
}

const _dialogWidth = 520.0;
const _factLabelWidth = 120.0;

/// 超过这个长度或含换行的文本（如提示词）不再挤在标签右侧。
const _longTextLength = 80;

bool _isLongText(Object? value) =>
    value is String && (value.length > _longTextLength || value.contains('\n'));

/// 长文本的限高滚动框，避免单个字段撑满整个弹窗。
class _FactBox extends StatelessWidget {
  const _FactBox({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.sm,
        ),
        child: child,
      ),
    );
  }
}

/// 列表事实：命令参数拼成一段，路径每行一项，文件夹汇总带数量。
class _FactList extends StatelessWidget {
  const _FactList({
    required this.fact,
    required this.danger,
    required this.style,
    required this.countStyle,
  });
  final _Fact fact;
  final bool danger;
  final TextStyle style, countStyle;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final items = fact.value as List;
    if (fact.key == 'args') {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceDim,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
        ),
        child: SelectableText(items.map(_factText).join(' '), style: style),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        border: Border.all(
          color: danger
              ? colors.deletionBorder.withValues(alpha: 0.25)
              : colors.borderSubtle,
        ),
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xxs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.md,
                  vertical: 2,
                ),
                child: switch (item) {
                  {'path': final String path, 'count': final int count} => Row(
                    children: [
                      Expanded(
                        child: Text(
                          path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
                      const SizedBox(width: RevericSpacing.md),
                      Text(
                        context.t(
                          LocaleKeys.aiApprovalItemCount,
                          namedArgs: {'count': '$count'},
                        ),
                        style: countStyle,
                      ),
                    ],
                  ),
                  _ => Text(
                    _factText(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                },
              ),
          ],
        ),
      ),
    );
  }
}

typedef _Fact = ({String key, String label, bool known, Object? value});

List<_Fact> _facts(BuildContext context, Map<String, dynamic> arguments) => [
  for (final MapEntry(:key, :value) in arguments.entries)
    switch (_factLabelKey(key)) {
      final String labelKey => (
        key: key,
        label: context.t(labelKey),
        known: true,
        value: value,
      ),
      null => (key: key, label: key, known: false, value: value),
    },
];

/// 一行摘要：短文本原样，数字带上字段名，开启的开关只写字段名；列表和未登记的
/// 数字、开关只在详情里看。与对象重复的文本不再出现。
String _brief(List<_Fact> facts, AiToolApprovalRequest request) => facts
    .map(
      (fact) => switch (fact.value) {
        final String text
            when text.length <= _briefFactMaxLength &&
                text != request.targetPath &&
                text != request.targetLabel =>
          text,
        final num number when fact.known => '${fact.label} $number',
        true when fact.known => fact.label,
        _ => null,
      },
    )
    .nonNulls
    .take(_briefFacts)
    .join(' · ');

/// 常见事实字段的显示名；未登记的字段返回 null，原样显示 key。
String? _factLabelKey(String key) => switch (key) {
  'model' => LocaleKeys.aiApprovalFactModel,
  'ratio' => LocaleKeys.aiApprovalFactRatio,
  'resolution' || 'size' => LocaleKeys.aiApprovalFactSize,
  'duration' => LocaleKeys.aiApprovalFactDuration,
  'audio' => LocaleKeys.aiApprovalFactAudio,
  'references' || 'image' => LocaleKeys.aiApprovalFactReferences,
  'prompt' => LocaleKeys.aiApprovalFactPrompt,
  'path' || 'inputs' => LocaleKeys.aiApprovalFactPath,
  'input_file_count' => LocaleKeys.aiApprovalFactInputFileCount,
  'input_directory_count' => LocaleKeys.aiApprovalFactInputDirectoryCount,
  'input_directories' => LocaleKeys.aiApprovalFactInputDirectories,
  'input_directories_preview' =>
    LocaleKeys.aiApprovalFactInputDirectoriesPreview,
  'mode' => LocaleKeys.aiApprovalFactMode,
  'matched_count' => LocaleKeys.aiApprovalFactMatchedCount,
  'recursive' => LocaleKeys.aiApprovalFactRecursive,
  'folders' => LocaleKeys.aiApprovalFactFolders,
  'folder_count' => LocaleKeys.aiApprovalFactFolderCount,
  'args' => LocaleKeys.aiApprovalFactArgs,
  _ => null,
};

String _factText(Object? value) => switch (value) {
  String() => value,
  num() || bool() => '$value',
  null => '',
  _ => jsonEncode(value),
};

/// 已处理审批的运行：一行轻量回执，不再有操作按钮。
class ToolOperationReceipt extends StatelessWidget {
  const ToolOperationReceipt({
    super.key,
    required this.capability,
    required this.title,
    required this.target,
    required this.state,
    required this.stateIcon,
    required this.stateColor,
  });
  final String? capability;
  final String title, target, state, stateIcon;
  final Color stateColor;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typography = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.xxs,
      ),
      child: Row(
        children: [
          RevericIcon(
            toolPermissionActionIcon(capability),
            size: 12,
            color: colors.textMuted,
          ),
          const SizedBox(width: RevericSpacing.xs),
          Text(
            title,
            style: typography.uiSmall.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(width: RevericSpacing.xs),
          Expanded(
            child: Text(
              target,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typography.uiSmall.copyWith(color: colors.textMuted),
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          RevericIcon(stateIcon, size: 11, color: stateColor),
          const SizedBox(width: RevericSpacing.xxs),
          Text(state, style: typography.uiTiny.copyWith(color: stateColor)),
        ],
      ),
    );
  }
}

/// 一个运行在消息流与运行条里的标题、对象和状态，二者共用一套映射。
({String title, String target, String state, String icon, Color color})
describeToolOperation(
  BuildContext context,
  ({
    String? capability,
    String kind,
    String target,
    String status,
    Map<String, dynamic>? result,
  })
  run,
) {
  final colors = RevericTheme.colorsOf(context);
  final errorCode = run.result?['error_code'];
  final (stateKey, icon, color) = switch (run.status) {
    'waiting_approval' => (
      LocaleKeys.aiOperationWaitingApproval,
      RevericIcons.shield_check,
      colors.accentWarm,
    ),
    'queued' => (
      LocaleKeys.aiOperationQueued,
      RevericIcons.circle_notch,
      colors.textMuted,
    ),
    'running' => (
      LocaleKeys.aiOperationRunning,
      RevericIcons.circle_notch,
      colors.accent,
    ),
    'cancelling' => (
      LocaleKeys.aiOperationCancelling,
      RevericIcons.circle_notch,
      colors.textMuted,
    ),
    'completed' => (
      LocaleKeys.aiOperationCompleted,
      RevericIcons.check,
      colors.additionBorder,
    ),
    'cancelled' => (
      LocaleKeys.aiOperationCancelled,
      RevericIcons.close,
      colors.textSubtle,
    ),
    'interrupted' => (
      LocaleKeys.aiOperationInterrupted,
      RevericIcons.warning,
      colors.warningText,
    ),
    _ when errorCode == 'permission_denied' => (
      LocaleKeys.aiPermissionDenied,
      RevericIcons.block_outlined,
      colors.deletionBorder,
    ),
    _ when errorCode == 'conflict' => (
      LocaleKeys.aiOperationConflict,
      RevericIcons.warning,
      colors.warningText,
    ),
    _ => (
      LocaleKeys.aiOperationFailed,
      RevericIcons.warning_circle,
      colors.warningText,
    ),
  };
  final capability = run.capability;
  final kind = run.kind.split('.');
  // 导演后台任务沿用 director.output 标识，用户操作文案复用 stagings output。
  final action = run.kind == 'director.output'
      ? localizedRunCommandAction(context, 'stagings', 'output')
      : kind.length == 2
      ? localizedRunCommandAction(context, kind.first, kind.last)
      : null;
  return (
    title:
        action ??
        (capability == null
            ? run.kind
            : toolPermissionActionLabel(context, capability)),
    target:
        (run.kind.startsWith('editing.') &&
                run.target.startsWith('/editings/')) ||
            (run.kind == 'director.output' &&
                run.target.startsWith('director/')) ||
            (run.kind.startsWith('ffmpeg.') &&
                run.target == run.kind.replaceFirst('.', '/'))
        ? ''
        : run.target,
    state: context.t(stateKey),
    icon: icon,
    color: color,
  );
}

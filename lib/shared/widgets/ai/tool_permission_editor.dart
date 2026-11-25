// 职责: 编辑工具权限四层规则（桌面为能力 × 范围矩阵），展示生效结果与来源并恢复继承。
// 关联文件:
//   lib/shared/providers/tool_permissions.dart
//   lib/shared/models/tool_permission.dart
//   lib/shared/widgets/ai/tool_permission_controls.dart
//   lib/shared/components/reveric_dialog.dart
//   lib/mobile/widgets/sheet.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../mobile/widgets/sheet.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_dialog.dart';
import '../../components/reveric_select.dart';
import '../../database/app_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/tool_permission.dart';
import '../../providers/tool_permissions.dart';
import '../../theme/theme.dart';
import 'tool_permission_controls.dart';

const _inherit = 'inherit';
const _matrixWidth = 860.0;
const _capabilityColumnWidth = 132.0;
const _listSelectorWidth = 160.0;

bool _isMobile(BuildContext context) => switch (Theme.of(context).platform) {
  TargetPlatform.android || TargetPlatform.iOS => true,
  _ => false,
};

/// 打开「助手权限」：桌面为弹窗矩阵，移动端为底部弹层。
Future<void> showToolPermissionEditor(
  BuildContext context,
  ToolPermissionContext permissionContext,
) {
  final title = context.t(LocaleKeys.aiPermissionsTitle);
  if (_isMobile(context)) {
    return showMobileSheet<void>(
      context: context,
      builder: (sheetContext) => MobileSheetScaffold(
        header: MobileSheetHeader.closable(
          title: title,
          onClose: () => Navigator.of(sheetContext).pop(),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(RevericSpacing.lg),
          child: ToolPermissionEditor(permissionContext: permissionContext),
        ),
      ),
    );
  }
  return showRevericDialog<void>(
    context: context,
    builder: (dialogContext) => RevericDialog(
      title: title,
      leading: const RevericIcon(RevericIcons.shield_check, size: 16),
      width: _matrixWidth,
      content: ToolPermissionEditor(permissionContext: permissionContext),
      actions: [
        RevericButton.secondary(
          label: dialogContext.t(LocaleKeys.commonClose),
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
    ),
  );
}

class ToolPermissionEditor extends HookConsumerWidget {
  const ToolPermissionEditor({super.key, required this.permissionContext});
  final ToolPermissionContext permissionContext;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scopes = permissionContext.scopes;
    final selection = useState(scopes.first);
    final snapshots = [
      for (final entry in scopes) ref.watch(toolPermissionRulesProvider(entry)),
    ];
    final typography = RevericTheme.typographyOf(context);
    if (snapshots.any((snapshot) => snapshot.hasError)) {
      return Text(
        context.t(LocaleKeys.aiPermissionLoadFailed),
        style: typography.ui,
      );
    }
    if (snapshots.any((snapshot) => !snapshot.hasValue)) {
      return Text(
        context.t(LocaleKeys.aiPermissionLoading),
        style: typography.ui,
      );
    }
    final rules = _PermissionRules({
      for (var index = 0; index < scopes.length; index++)
        scopes[index]: snapshots[index].requireValue,
    });
    if (!_isMobile(context)) {
      if (scopes.length == 1) {
        return _PermissionList(scope: scopes.single, rules: rules);
      }
      return _PermissionMatrix(scopes: scopes, rules: rules);
    }
    final scope = scopes.contains(selection.value)
        ? selection.value
        : scopes.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ToolPermissionSelector<ToolPermissionScope>(
          value: scope,
          label: context.t(LocaleKeys.aiPermissionScope),
          items: [
            for (final entry in scopes)
              RevericSelectItem(
                value: entry,
                label: toolPermissionScopeLabel(context, entry.type),
              ),
          ],
          onChanged: (value) => selection.value = value,
        ),
        for (final action in toolPermissionActions.where(
          (action) => action != shellExecutePermission,
        ))
          Padding(
            padding: const EdgeInsets.only(top: RevericSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _RuleCell(
                  key: ValueKey('${scope.type.name}/$action'),
                  action: action,
                  scope: scope,
                  current: rules.current(scope, action),
                  label: toolPermissionActionLabel(context, action),
                ),
                const SizedBox(height: RevericSpacing.xxs),
                _EffectiveText(effective: rules.effective(action)),
              ],
            ),
          ),
      ],
    );
  }
}

class _PermissionRules {
  const _PermissionRules(this.byScope);

  /// 按 会话 → 分集 → 作品 → 全局 排列。
  final Map<ToolPermissionScope, List<ToolPermissionRule>> byScope;

  ToolPermissionDecision? current(ToolPermissionScope scope, String action) =>
      byScope[scope]!
          .where((rule) => rule.action == action)
          .firstOrNull
          ?.decision;

  /// 第一条匹配规则决定结果；都没有则是默认的每次询问。
  (ToolPermissionDecision, ToolPermissionScope?) effective(String action) {
    for (final entry in byScope.entries) {
      final decision = current(entry.key, action);
      if (decision != null) {
        return (decision, entry.key);
      }
    }
    return (ToolPermissionDecision.ask, null);
  }
}

/// 桌面：能力 × 范围。单元格选「跟随上级」= 恢复继承。
class _PermissionMatrix extends StatelessWidget {
  const _PermissionMatrix({required this.scopes, required this.rules});
  final List<ToolPermissionScope> scopes;
  final _PermissionRules rules;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typography = RevericTheme.typographyOf(context);
    final headStyle = typography.uiTinySemibold.copyWith(
      color: colors.textMuted,
    );
    final rowBorder = BorderSide(color: colors.borderSubtle);
    Widget cell(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: RevericSpacing.md,
      ),
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
    final actions = toolPermissionActions.toList();
    return Table(
      columnWidths: const {0: FixedColumnWidth(_capabilityColumnWidth)},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          decoration: BoxDecoration(border: Border(bottom: rowBorder)),
          children: [
            const SizedBox.shrink(),
            for (final scope in scopes)
              cell(
                Text(
                  toolPermissionScopeLabel(context, scope.type),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: headStyle,
                ),
              ),
            cell(
              Text(
                context.t(LocaleKeys.aiPermissionEffectiveColumn),
                style: headStyle,
              ),
            ),
          ],
        ),
        for (var index = 0; index < actions.length; index++)
          TableRow(
            decoration: index == actions.length - 1
                ? null
                : BoxDecoration(border: Border(bottom: rowBorder)),
            children: [
              cell(
                Row(
                  children: [
                    RevericIcon(
                      toolPermissionActionIcon(actions[index]),
                      size: 14,
                      color: colors.textPrimary,
                    ),
                    const SizedBox(width: RevericSpacing.xs),
                    Flexible(
                      child: Text(
                        toolPermissionActionLabel(context, actions[index]),
                        style: typography.uiSmallSemibold.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              for (final scope in scopes)
                cell(
                  _RuleCell(
                    key: ValueKey('${scope.type.name}/${actions[index]}'),
                    action: actions[index],
                    scope: scope,
                    current: rules.current(scope, actions[index]),
                  ),
                ),
              cell(_EffectiveText(effective: rules.effective(actions[index]))),
            ],
          ),
      ],
    );
  }
}

/// 桌面单范围（设置页的全局规则）：每项能力一行，不需要「结果」列。
class _PermissionList extends StatelessWidget {
  const _PermissionList({required this.scope, required this.rules});
  final ToolPermissionScope scope;
  final _PermissionRules rules;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typography = RevericTheme.typographyOf(context);
    final actions = toolPermissionActions.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < actions.length; index++) ...[
          if (index > 0)
            Divider(height: 1, thickness: 1, color: colors.borderSubtle),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
            child: Row(
              children: [
                RevericIcon(
                  toolPermissionActionIcon(actions[index]),
                  size: 16,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: RevericSpacing.sm),
                Expanded(
                  child: Text(
                    toolPermissionActionLabel(context, actions[index]),
                    style: typography.uiSemibold.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: RevericSpacing.lg),
                SizedBox(
                  width: _listSelectorWidth,
                  child: _RuleCell(
                    key: ValueKey('${scope.type.name}/${actions[index]}'),
                    action: actions[index],
                    scope: scope,
                    current: rules.current(scope, actions[index]),
                    collapseDefault: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 一个范围上的一条规则；保存失败时保留原值并提示。
class _RuleCell extends HookConsumerWidget {
  const _RuleCell({
    super.key,
    required this.action,
    required this.scope,
    required this.current,
    this.label,
    this.collapseDefault = false,
  });
  final String action;
  final ToolPermissionScope scope;
  final ToolPermissionDecision? current;
  final String? label;

  /// 没有上级可继承时，「每次询问」即默认：不单列默认项，选它就清除规则。
  final bool collapseDefault;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = useState(false);
    final failed = useState(false);
    final colors = RevericTheme.colorsOf(context);
    final typography = RevericTheme.typographyOf(context);
    final global = scope.type == ToolPermissionScopeType.global;
    final selector = ToolPermissionSelector<String>(
      value:
          current?.name ??
          (collapseDefault ? ToolPermissionDecision.ask.name : _inherit),
      label: label,
      compact: label == null && !collapseDefault,
      menuWidth: label == null && !collapseDefault ? 132 : null,
      items: [
        if (!collapseDefault)
          RevericSelectItem(
            value: _inherit,
            label: context.t(
              global
                  ? LocaleKeys.aiPermissionDefault
                  : LocaleKeys.aiPermissionInherit,
            ),
          ),
        for (final decision in ToolPermissionDecision.values)
          RevericSelectItem(
            value: decision.name,
            label: toolPermissionDecisionLabel(context, decision),
            color: _decisionColor(colors, decision),
          ),
      ],
      onChanged: busy.value
          ? null
          : (value) async {
              busy.value = true;
              failed.value = false;
              try {
                await ref
                    .read(toolPermissionServiceProvider)
                    .setRule(
                      action,
                      scope,
                      value == _inherit ||
                              (collapseDefault &&
                                  value == ToolPermissionDecision.ask.name)
                          ? null
                          : ToolPermissionDecision.values.byName(value),
                    );
              } catch (_) {
                if (context.mounted) {
                  failed.value = true;
                }
              } finally {
                if (context.mounted) {
                  busy.value = false;
                }
              }
            },
    );
    if (!failed.value) {
      return selector;
    }
    final error = context.t(LocaleKeys.aiPermissionSaveFailed);
    if (label == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: selector),
          Tooltip(
            message: error,
            child: RevericIcon(
              RevericIcons.warning_circle,
              size: 13,
              color: colors.warningText,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        selector,
        Text(
          error,
          style: typography.uiSmall.copyWith(color: colors.warningText),
        ),
      ],
    );
  }
}

Color? _decisionColor(RevericColors colors, ToolPermissionDecision decision) =>
    switch (decision) {
      ToolPermissionDecision.allow => colors.additionBorder,
      ToolPermissionDecision.deny => colors.deletionBorder,
      ToolPermissionDecision.ask => null,
    };

/// 生效结果 + 来源范围。
class _EffectiveText extends StatelessWidget {
  const _EffectiveText({required this.effective});
  final (ToolPermissionDecision, ToolPermissionScope?) effective;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typography = RevericTheme.typographyOf(context);
    final (decision, source) = effective;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          toolPermissionDecisionLabel(context, decision),
          style: typography.uiSmallSemibold.copyWith(
            color: _decisionColor(colors, decision) ?? colors.textPrimary,
          ),
        ),
        Text(
          source == null
              ? context.t(LocaleKeys.aiPermissionDefault)
              : toolPermissionScopeLabel(context, source.type),
          style: typography.uiTiny.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

// 职责: Reveric 通用搜索输入 — 搜索框组件、自持 debounce 的回调式变体与防抖搜索状态 hook，供各列表/管理页复用。
// 关联文件:
//   lib/shared/theme/theme.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/hooks.md
//   .agents/rules/search-debounce.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../theme/theme.dart';

/// 搜索输入态 + debounce 后的查询，供列表页复用，避免重复样板。
///
/// 返回的 [query] 是去空格、转小写、debounce 后的查询值；输入为空时立即返回空串
/// 并视为未过滤（[active] 为 false）。过滤逻辑仍由调用方负责。
typedef DebouncedSearch = ({
  TextEditingController controller,
  String query,
  bool active,
});

DebouncedSearch useDebouncedSearch({
  Duration delay = const Duration(milliseconds: 250),
}) {
  final controller = useTextEditingController();
  final value = useValueListenable(controller);
  final raw = value.text.trim().toLowerCase();
  final debounced = useDebounced(raw, delay);
  final query = raw.isEmpty ? '' : (debounced ?? '');
  return (controller: controller, query: query, active: query.isNotEmpty);
}

/// 自持 controller 的 debounce 搜索框：输入稳定后回调 [onDebouncedChanged]。
///
/// 给父级是 `State`（调不了 hook）的场景用；父级本身是 HookWidget 时直接
/// [useDebouncedSearch] + [RevericSearchField]，不要多包一层。
///
/// 回调值与 [useDebouncedSearch] 同口径：去空格、转小写。清空输入立即回调空串，
/// 不等 debounce。[initialQuery] 只用于首帧回填输入框，本身不会触发回调。
class RevericDebouncedSearchField extends HookWidget {
  const RevericDebouncedSearchField({
    super.key,
    required this.hint,
    required this.onDebouncedChanged,
    this.initialQuery = '',
    this.debounce = const Duration(milliseconds: 250),
    this.height = RevericSizes.fieldHeight,
    this.autofocus = false,
    this.radius = RevericRadius.large,
    this.fillColor,
  });

  final String hint;
  final ValueChanged<String> onDebouncedChanged;
  final String initialQuery;
  final Duration debounce;
  final double height;
  final bool autofocus;
  final double radius;
  final Color? fillColor;

  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(text: initialQuery);
    final value = useValueListenable(controller);
    final raw = value.text.trim().toLowerCase();
    final debounced = useDebounced(raw, debounce);
    // 清空立即生效，不等 debounce；非空时 null 表示 debounce 还没落定。
    final query = raw.isEmpty ? '' : debounced;

    // 回调 prop 每帧都是新闭包，放进 keys 会让 effect 每帧重跑。
    final notify = useRef(onDebouncedChanged);
    notify.value = onDebouncedChanged;
    // 种上 initialQuery：首帧不回调，免得把父级已有的 query 冲成空串。
    final emitted = useRef(initialQuery.trim().toLowerCase());

    useEffect(() {
      if (query == null || query == emitted.value) return null;
      emitted.value = query;
      // 父级通常是 State：effect 仍在 build 帧内，同步 setState 会触发断言。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) notify.value(query);
      });
      return null;
    }, [query]);

    return RevericSearchField(
      controller: controller,
      hint: hint,
      height: height,
      autofocus: autofocus,
      radius: radius,
      fillColor: fillColor,
    );
  }
}

/// 通用搜索框：搜索前缀图标 + 输入后出现的清除按钮。
///
/// 仅负责输入与展示；debounce / 过滤由调用方持有（通常配合 [useDebouncedSearch]）。
/// 内部监听 [controller]，因此清除按钮的出现/消失不依赖父级重建。
class RevericSearchField extends StatelessWidget {
  const RevericSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.height = RevericSizes.fieldHeight,
    this.autofocus = false,
    this.radius = RevericRadius.large,
    this.fillColor,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.enabled = true,
    this.highlightWhenFilled = false,
    this.outlined = true,
  });

  final TextEditingController controller;
  final String hint;
  final double height;
  final bool autofocus;
  final double radius;
  final Color? fillColor;

  /// false 时不画边框和填充色，给弹层头部这类自带外框的搜索行用。
  final bool outlined;

  /// 每次按键都会触发，给「输入即切页」这类即时副作用用。
  /// 参与结果计算的 query 必须走 debounce，不要接在这里。
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final bool enabled;

  /// 有内容时边框换成强调色，提示列表正被搜索收窄。
  final bool highlightWhenFilled;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return SizedBox(
      height: height,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final hasText = controller.text.isNotEmpty;
          return TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            onSubmitted: onSubmitted,
            autofocus: autofocus,
            onChanged: onChanged,
            textAlignVertical: TextAlignVertical.center,
            style: typo.uiSmall.copyWith(color: colors.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: typo.uiSmall.copyWith(color: colors.textSubtle),
              prefixIcon: Padding(
                padding: const EdgeInsets.only(
                  left: RevericSpacing.sm,
                  right: RevericSpacing.xs,
                ),
                child: RevericIcon(
                  RevericIcons.search,
                  size: 14,
                  color: colors.textMuted,
                ),
              ),
              // InputDecorator 的边框盒按内容高度自算，外层 SizedBox 只会留白不会
              // 撑开它；把前后缀图标钉成 height 才能让边框和 RevericSelect 等高。
              prefixIconConstraints: BoxConstraints(
                minWidth: 28,
                minHeight: height,
              ),
              suffixIconConstraints: BoxConstraints.tightFor(
                width: 28,
                height: height,
              ),
              suffixIcon: !hasText
                  ? null
                  : InkWell(
                      borderRadius: BorderRadius.circular(radius),
                      onTap: enabled ? controller.clear : null,
                      child: Center(
                        child: RevericIcon(
                          RevericIcons.close,
                          size: 12,
                          color: colors.textMuted,
                        ),
                      ),
                    ),
              filled: outlined,
              fillColor: outlined
                  ? fillColor ?? colors.surfaceContainerHigh
                  : null,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.sm,
              ),
              border: !outlined
                  ? InputBorder.none
                  : OutlineInputBorder(
                      borderRadius: BorderRadius.circular(radius),
                      borderSide: BorderSide(color: colors.borderInput),
                    ),
              enabledBorder: !outlined
                  ? InputBorder.none
                  : OutlineInputBorder(
                      borderRadius: BorderRadius.circular(radius),
                      borderSide: BorderSide(
                        color: highlightWhenFilled && hasText
                            ? colors.accent
                            : colors.borderInput,
                      ),
                    ),
              focusedBorder: !outlined
                  ? InputBorder.none
                  : OutlineInputBorder(
                      borderRadius: BorderRadius.circular(radius),
                      borderSide: BorderSide(color: colors.accent),
                    ),
            ),
          );
        },
      ),
    );
  }
}

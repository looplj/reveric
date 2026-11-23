// 职责: 展示移动端作品编辑页的横向分区切换条，支持选中高亮动效与自动滚入视口。
// 关联文件:
//   lib/mobile/pages/novel_editor_page.dart
//   lib/mobile/features/screenplay/editor_page.dart
//   lib/shared/components/horizontal_wheel_scroll.dart
//   lib/shared/theme/theme.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../shared/components/horizontal_wheel_scroll.dart';
import '../../shared/theme/theme.dart';

class MobileSectionChips extends HookWidget {
  const MobileSectionChips({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final scrollController = useScrollController();
    final chipKeys = useMemoized(
      () => List.generate(labels.length, (_) => GlobalKey()),
      [labels.length],
    );

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (selectedIndex < 0 || selectedIndex >= chipKeys.length) {
          return;
        }
        final chipContext = chipKeys[selectedIndex].currentContext;
        if (chipContext != null) {
          Scrollable.ensureVisible(
            chipContext,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOutCubic,
            alignment: 0.5,
          );
        }
      });
      return null;
    }, [selectedIndex, labels.length]);

    return SizedBox(
      height: 42,
      child: HorizontalWheelScroll(
        controller: scrollController,
        builder: (context, controller) => ListView.separated(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.xl,
            0,
            RevericSpacing.xl,
            RevericSpacing.lg,
          ),
          itemCount: labels.length,
          separatorBuilder: (_, _) => const SizedBox(width: RevericSpacing.xs),
          itemBuilder: (context, index) {
            final isActive = index == selectedIndex;
            return InkWell(
              key: chipKeys[index],
              onTap: () => onSelect(index),
              borderRadius: BorderRadius.circular(RevericRadius.pill),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOutCubic,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.xl,
                ),
                decoration: BoxDecoration(
                  color: isActive ? colors.accent : colors.surface,
                  borderRadius: BorderRadius.circular(RevericRadius.pill),
                  border: Border.all(
                    color: isActive ? colors.accent : colors.borderSubtle,
                  ),
                ),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOutCubic,
                  style: typo.uiSmallSemibold.copyWith(
                    color: isActive ? colors.onAccent : colors.textSecondary,
                  ),
                  child: Text(labels[index]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

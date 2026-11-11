// 职责: 展示并更新剧本全局风格（顶栏 chip）或节点的独立风格（输入框底栏 pill）。
// 关联文件:
//   lib/desktop/features/production/style_picker.dart
//   lib/desktop/features/production/style_thumb.dart
//   lib/desktop/features/production/popover.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/components/reveric_popover.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/production/style.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import 'popover.dart';
import 'style_picker.dart';
import 'style_thumb.dart';
import 'support.dart';

typedef _StyleState = ({
  ProductionStyleChoice choice,
  ProductionStyleLook look,
  ProductionStyleLook screenplay,
  bool ready,
  Future<void> Function(ProductionStyleChoice next) save,
});

/// 把风格引用（null / `none` / `preset:<slug>` / 自定义风格 ID）解析成名称和缩略图。
ProductionStyleLook _lookOf(
  BuildContext context,
  String? ref,
  List<ProductionStyleRow> styles,
) {
  final missing = (
    label: context.t(LocaleKeys.productionStyleMissing),
    kind: ProductionStyleThumbKind.missing,
    seed: '',
  );
  if (ref == null || ref == 'none') {
    return (
      label: context.t(LocaleKeys.productionStyleNone),
      kind: ProductionStyleThumbKind.none,
      seed: '',
    );
  }
  if (ProductionStyleChoice.fromStored(ref) case PresetProductionStyle(
    :final presetId,
  )) {
    final preset = productionStylePreset(presetId);
    return preset == null
        ? missing
        : (
            label: preset.name,
            kind: ProductionStyleThumbKind.preset,
            seed: preset.id,
          );
  }
  final style = styles.where((row) => row.id == ref).firstOrNull;
  return style == null
      ? missing
      : (label: style.name, kind: ProductionStyleThumbKind.custom, seed: ref);
}

_StyleState _useStyle(
  BuildContext context,
  ProductionCanvasService service,
  String? clipId,
) {
  final screenplay = useStream(
    useMemoized(() => service.db.screenplayDao.watchRoot(), [service]),
  );
  final clip = useStream(
    useMemoized(
      () => (service.db.select(
        service.db.productionClips,
      )..where((t) => t.id.equals(clipId ?? ''))).watchSingleOrNull(),
      [service, clipId],
    ),
  );
  final styles = useStream(
    useMemoized(
      () => service.library.database.productionStyleDao.watchStyles(),
      [service],
    ),
  );
  final busy = useState(false);
  final screenplayRef = screenplay.data?.styleId;
  final choice = clipId == null
      ? ProductionStyleChoice.fromScreenplay(screenplayRef)
      : ProductionStyleChoice.fromStored(clip.data?.styleSelection);
  final rows = styles.data ?? const <ProductionStyleRow>[];
  Future<void> save(ProductionStyleChoice next) async {
    busy.value = true;
    try {
      if (clipId == null) {
        await service.setScreenplayStyle(
          next is NoProductionStyle ? null : next.stored,
        );
      } else {
        await service.setClipStyle(clipId, next);
      }
    } finally {
      if (context.mounted) {
        busy.value = false;
      }
    }
  }

  return (
    choice: choice,
    look: _lookOf(
      context,
      choice is InheritedProductionStyle ? screenplayRef : choice.stored,
      rows,
    ),
    screenplay: _lookOf(context, screenplayRef, rows),
    ready:
        !busy.value &&
        screenplay.hasData &&
        styles.hasData &&
        (clipId == null || clip.hasData),
    save: save,
  );
}

/// 节点卡片 meta 行末尾的风格名：只有节点单独设置了风格才返回，跟随剧本时为 null。
String? useProductionStyleNote(
  BuildContext context,
  ProductionCanvasService service,
  String? styleSelection,
) {
  final choice = ProductionStyleChoice.fromStored(styleSelection);
  final styleId = choice is CustomProductionStyle ? choice.styleId : null;
  final style = useFuture(
    useMemoized(
      () => styleId == null
          ? Future.value()
          : service.library.database.productionStyleDao.getStyle(styleId),
      [service, styleId],
    ),
  );
  return switch (choice) {
    InheritedProductionStyle() => null,
    NoProductionStyle() => context.t(LocaleKeys.productionStyleNone),
    PresetProductionStyle(:final presetId) =>
      productionStylePreset(presetId)?.name ??
          context.t(LocaleKeys.productionStyleMissing),
    CustomProductionStyle() =>
      style.data?.name ??
          (style.connectionState == ConnectionState.done
              ? context.t(LocaleKeys.productionStyleMissing)
              : null),
  };
}

/// 风格 pill 和它展开的风格库弹层；选中后先收起弹层再保存。
class _StylePopover extends StatelessWidget {
  const _StylePopover({
    required this.service,
    required this.style,
    required this.forNode,
    required this.trigger,
  });
  final ProductionCanvasService service;
  final _StyleState style;
  final bool forNode;
  final Widget Function(BuildContext context, bool open, VoidCallback? toggle)
  trigger;

  @override
  Widget build(BuildContext context) => RevericPopover(
    up: forNode,
    alignEnd: !forNode,
    trigger: (context, open, toggle) =>
        trigger(context, open, style.ready || open ? toggle : null),
    panel: (_, close) => ProductionStylePicker(
      service: service,
      value: style.choice,
      screenplay: forNode ? style.screenplay : null,
      onClose: close,
      onPick: (next) {
        close();
        productionRun(context, () => style.save(next));
      },
    ),
  );
}

/// 顶栏的剧本全局风格：缩略图 + 名称 ▾。清空在风格库里选「无风格」。
class ProductionScreenplayStyle extends HookWidget {
  const ProductionScreenplayStyle({super.key, required this.service});
  final ProductionCanvasService service;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final style = _useStyle(context, service, null);
    // 顶栏把控件放进 Flexible。这层 Row 让 chip 保持内容宽度，长名称仍能截断。
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: _StylePopover(
            service: service,
            style: style,
            forNode: false,
            trigger: (context, open, toggle) => ProductionPill(
              open: open,
              tooltip: context.t(LocaleKeys.productionStyleScreenplayHint),
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.xxs,
                0,
                RevericSpacing.sm,
                0,
              ),
              onTap: toggle,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProductionStyleThumb(
                    kind: style.look.kind,
                    seed: style.look.seed,
                    size: 22,
                    radius: 11,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Text(
                        style.look.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSmall.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  ProductionCaret(open: open, size: 11),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 输入框底栏的节点风格：缩略图 + 名称；跟随剧本时名称后带「剧本」小标。
class ProductionStylePill extends HookWidget {
  const ProductionStylePill({
    super.key,
    required this.service,
    required this.clipId,
  });
  final ProductionCanvasService service;
  final String clipId;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final style = _useStyle(context, service, clipId);
    final inherited = style.choice is InheritedProductionStyle;
    return _StylePopover(
      service: service,
      style: style,
      forNode: true,
      trigger: (context, open, toggle) => ProductionPill(
        open: open,
        tooltip: context.t(
          inherited
              ? LocaleKeys.productionStyleInheritHint
              : LocaleKeys.productionStyleOwnHint,
        ),
        onTap: toggle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProductionStyleThumb(
              kind: style.look.kind,
              seed: style.look.seed,
              size: 18,
              radius: RevericRadius.small,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 112),
                child: Text(
                  style.look.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSmall.copyWith(color: colors.textPrimary),
                ),
              ),
            ),
            if (inherited) ...[
              const SizedBox(width: 5),
              Flexible(
                child: Container(
                  height: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(RevericRadius.small),
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      context.t(LocaleKeys.productionStyleScreenplayTag),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 5),
            ProductionCaret(open: open),
          ],
        ),
      ),
    );
  }
}

// 职责: 「分辨率、比例与复杂度」弹层本体（含音频生成与本次提交的样片选项），以及用它的节点输入框 pill 和顶栏剧本制作设置 chip。
// 关联文件:
//   lib/desktop/features/production/popover.dart
//   lib/desktop/features/production/region.dart
//   lib/shared/models/production/settings.dart
//   lib/shared/providers/storyboard.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_popover.dart';
import '../../../shared/components/reveric_switch.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/image/channels.dart';
import '../../../shared/models/production/settings.dart';
import '../../../shared/providers/storyboard.dart';
import '../../../shared/services/ai/video/draft.dart';
import '../../../shared/theme/theme.dart';
import 'popover.dart';
import 'support.dart';

typedef ProductionSpecChange =
    void Function({String? ratio, String? resolution});

String productionRatioLabel(BuildContext context, String ratio) =>
    ratio == 'adaptive' ? context.t(LocaleKeys.directorAspectAuto) : ratio;

/// 存储和模型能力用小写（720p），界面统一显示大写（720P）。
String productionResolutionLabel(String resolution) => resolution.toUpperCase();

String productionComplexityLabel(BuildContext context, String level) =>
    switch (imageComplexityLabelKey(level)) {
      final key? => context.t(key),
      _ => level,
    };

/// 按比例画的小框；比例不可解析（如自适应）时画正方形。
class ProductionRatioBox extends StatelessWidget {
  const ProductionRatioBox({super.key, required this.ratio, this.scale = 1});
  final String ratio;
  final double scale;

  static const _boxes = {
    '16:9': Size(22, 13),
    '21:9': Size(24, 10),
    '9:16': Size(13, 22),
    '4:3': Size(20, 15),
    '3:4': Size(15, 20),
    '1:1': Size(17, 17),
  };

  static Size _size(String ratio) {
    if (_boxes[ratio] case final size?) {
      return size;
    }
    final parts = ratio.split(':').map(double.tryParse).toList();
    if (parts.length != 2 || parts.any((p) => p == null || p <= 0)) {
      return _boxes['1:1']!;
    }
    final r = parts[0]! / parts[1]!;
    return r >= 1
        ? Size(22, (22 / r).clamp(8, 22))
        : Size((22 * r).clamp(8, 22), 22);
  }

  @override
  Widget build(BuildContext context) {
    final size = _size(ratio) * scale;
    return Container(
      width: size.width,
      height: size.height,
      decoration: BoxDecoration(
        border: Border.all(
          color:
              DefaultTextStyle.of(context).style.color ??
              RevericTheme.colorsOf(context).textSecondary,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

class ProductionSpecPanel extends StatelessWidget {
  const ProductionSpecPanel({
    super.key,
    required this.ratios,
    required this.resolutions,
    required this.ratio,
    required this.resolution,
    required this.onChanged,
    this.complexities = const [],
    this.complexity,
    this.onComplexity,
    this.note,
    this.sample,
    this.audio,
    this.onAudio,
    this.onSample,
  });
  final List<String> ratios;
  final List<String> resolutions;
  final String ratio;
  final String resolution;
  final ProductionSpecChange onChanged;
  final List<String> complexities;
  final String? complexity;
  final ValueChanged<String>? onComplexity;
  final bool? audio;
  final ValueChanged<bool>? onAudio;
  final String? note;

  /// 模型支持样片时不为 null：分辨率末尾多一个「样片」，与分辨率互斥；
  /// 只是这次提交的选项，选回任一分辨率即取消，不改保存的分辨率。
  final bool? sample;
  final ValueChanged<bool>? onSample;

  static const _padding = EdgeInsets.fromLTRB(
    RevericSpacing.xl,
    RevericSpacing.lg,
    RevericSpacing.xl,
    RevericSpacing.xl,
  );

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final cell =
        (RevericSizes.productionSpecWidth -
            _padding.horizontal -
            2 -
            RevericSpacing.sm * 3) /
        4;
    Widget title(String key) => Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
      child: Text(
        context.t(key),
        style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
      ),
    );
    Widget option({
      required bool selected,
      required VoidCallback onTap,
      required double height,
      required Widget child,
    }) {
      final radius = BorderRadius.circular(RevericRadius.large);
      return Material(
        color: selected
            ? Color.alphaBlend(
                colors.accent.withValues(alpha: .16),
                colors.surface,
              )
            : colors.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? colors.accent : colors.surfaceContainer,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          hoverColor: colors.surfaceContainerHigh,
          child: SizedBox(
            height: height,
            child: DefaultTextStyle.merge(
              style: typo.uiSmallSemibold.copyWith(
                color: selected ? colors.textPrimary : colors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              child: child,
            ),
          ),
        ),
      );
    }

    return ProductionPopoverPanel(
      width: RevericSizes.productionSpecWidth,
      radius: RevericRadius.pill,
      padding: _padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title(LocaleKeys.productionSpecResolution),
          Row(
            children: [
              for (var i = 0; i < resolutions.length; i++) ...[
                if (i > 0) const SizedBox(width: RevericSpacing.sm),
                Expanded(
                  child: option(
                    selected: sample != true && resolutions[i] == resolution,
                    height: 34,
                    onTap: () {
                      onChanged(resolution: resolutions[i]);
                      if (sample == true) {
                        onSample?.call(false);
                      }
                    },
                    child: Center(
                      child: Text(productionResolutionLabel(resolutions[i])),
                    ),
                  ),
                ),
              ],
              if (sample != null) ...[
                const SizedBox(width: RevericSpacing.sm),
                Expanded(
                  child: Tooltip(
                    message: context.t(LocaleKeys.productionDraftHint),
                    child: option(
                      selected: sample!,
                      height: 34,
                      onTap: () => onSample?.call(true),
                      child: Center(
                        child: Text(
                          context.t(LocaleKeys.productionSampleOption),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          title(LocaleKeys.productionSpecRatio),
          Wrap(
            spacing: RevericSpacing.sm,
            runSpacing: RevericSpacing.sm,
            children: [
              for (final value in ratios)
                SizedBox(
                  width: cell,
                  child: option(
                    selected: value == ratio,
                    height: 64,
                    onTap: () => onChanged(ratio: value),
                    child: Stack(
                      children: [
                        Center(
                          child: Builder(
                            builder: (context) => Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ProductionRatioBox(ratio: value),
                                const SizedBox(height: RevericSpacing.xs),
                                Text(productionRatioLabel(context, value)),
                              ],
                            ),
                          ),
                        ),
                        if (value == ratio)
                          Positioned(
                            top: RevericSpacing.xs,
                            right: RevericSpacing.xs,
                            child: RevericIcon(
                              RevericIcons.check,
                              size: 12,
                              color: colors.accent,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (complexities.isNotEmpty) ...[
            const SizedBox(height: RevericSpacing.lg),
            title(LocaleKeys.commonComplexity),
            Row(
              children: [
                for (var i = 0; i < complexities.length; i++) ...[
                  if (i > 0) const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: option(
                      selected: complexities[i] == complexity,
                      height: 34,
                      onTap: () => onComplexity?.call(complexities[i]),
                      child: Center(
                        child: Text(
                          productionComplexityLabel(context, complexities[i]),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (audio != null) ...[
            const SizedBox(height: RevericSpacing.lg),
            MergeSemantics(
              child: Material(
                color: colors.surfaceContainer,
                borderRadius: BorderRadius.circular(RevericRadius.large),
                child: InkWell(
                  onTap: onAudio == null ? null : () => onAudio!(!audio!),
                  borderRadius: BorderRadius.circular(RevericRadius.large),
                  hoverColor: colors.surfaceContainerHigh,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.md,
                      RevericSpacing.sm,
                      RevericSpacing.xs,
                      RevericSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        RevericIcon(
                          audio!
                              ? RevericIcons.speaker_high
                              : RevericIcons.speaker_slash,
                          size: 16,
                          color: audio! ? colors.accent : colors.textMuted,
                        ),
                        const SizedBox(width: RevericSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.t(LocaleKeys.productionGenerateAudio),
                                style: typo.uiSmallSemibold.copyWith(
                                  color: colors.textPrimary,
                                ),
                              ),
                              Text(
                                context.t(
                                  LocaleKeys.productionGenerateAudioHint,
                                ),
                                style: typo.uiTiny.copyWith(
                                  color: colors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        RevericSwitch(value: audio!, onChanged: onAudio),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (note != null) ...[
            const SizedBox(height: RevericSpacing.lg),
            Text(note!, style: typo.uiTiny.copyWith(color: colors.textMuted)),
          ],
        ],
      ),
    );
  }
}

/// 节点输入框底栏的「比例 · 分辨率」pill；可选项来自当前模型的能力。
/// [sample] 不为 null 时可选样片，选中后 pill 写「480P 样片」，和实际提交的一致。
class ProductionSpecPill extends StatelessWidget {
  const ProductionSpecPill({
    super.key,
    required this.ratios,
    required this.resolutions,
    required this.ratio,
    required this.resolution,
    required this.onChanged,
    this.complexities = const [],
    this.complexity,
    this.onComplexity,
    this.sample,
    this.audio,
    this.onAudio,
  });
  final List<String> ratios;
  final List<String> resolutions;
  final String ratio;
  final String resolution;
  final ProductionSpecChange onChanged;
  final List<String> complexities;
  final String? complexity;
  final ValueChanged<String>? onComplexity;
  final bool? audio;
  final ValueChanged<bool>? onAudio;
  final ValueNotifier<bool>? sample;
  @override
  Widget build(BuildContext context) {
    final sample = this.sample;
    if (sample == null) {
      return _build(context, null);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: sample,
      builder: (context, on, _) => _build(context, on),
    );
  }

  Widget _build(BuildContext context, bool? sampleOn) {
    final typo = RevericTheme.typographyOf(context);
    final colors = RevericTheme.colorsOf(context);
    return RevericPopover(
      up: true,
      trigger: (context, open, toggle) => ProductionPill(
        open: open,
        onTap: ratios.isEmpty && resolutions.isEmpty && complexities.isEmpty
            ? null
            : toggle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${productionRatioLabel(context, ratio)} · '
              '${sampleOn == true ? context.t(LocaleKeys.productionSampleSpec, namedArgs: {'resolution': productionResolutionLabel(videoDraftResolution)}) : productionResolutionLabel(resolution)}'
              '${complexity == null ? '' : ' · ${productionComplexityLabel(context, complexity!)}'}'
              '${audio == null ? '' : ' · '}',
              style: typo.uiSmall.copyWith(
                color: colors.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (audio case final on?)
              Tooltip(
                message: context.t(
                  on
                      ? LocaleKeys.productionAudioOn
                      : LocaleKeys.productionAudioOff,
                ),
                child: RevericIcon(
                  on ? RevericIcons.speaker_high : RevericIcons.speaker_slash,
                  size: 14,
                  color: on ? colors.textPrimary : colors.textMuted,
                ),
              ),
            const SizedBox(width: 5),
            ProductionCaret(open: open),
          ],
        ),
      ),
      panel: (context, close) => ProductionSpecPanel(
        ratios: ratios,
        resolutions: resolutions,
        ratio: ratio,
        resolution: resolution,
        complexities: complexities,
        complexity: complexity,
        onComplexity: onComplexity,
        onChanged: onChanged,
        sample: sampleOn,
        audio: audio,
        onAudio: onAudio,
        onSample: sample == null ? null : (on) => sample!.value = on,
      ),
    );
  }
}

/// 顶栏的剧本制作设置：比例框 + 「9:16 · 720p」▾，整部剧共用，不受某个模型限制。
class ProductionSpecChip extends ConsumerWidget {
  const ProductionSpecChip({
    super.key,
    required this.path,
    required this.episodeId,
  });
  final String path;
  final String episodeId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final settings = ref
        .watch(episodeProductionProvider(path, episodeId))
        .value;
    if (settings == null) {
      return const SizedBox.shrink();
    }
    void change({String? ratio, String? resolution}) => productionRun(
      context,
      () => ref.read(storyboardServiceProvider(path)).saveSettings({
        'ratio': ?ratio,
        'resolution': ?resolution,
      }),
    );
    return RevericPopover(
      alignEnd: true,
      trigger: (context, open, toggle) => ProductionPill(
        open: open,
        tooltip: context.t(LocaleKeys.productionSpecTooltip),
        padding: const EdgeInsets.fromLTRB(
          RevericSpacing.xs,
          0,
          RevericSpacing.sm,
          0,
        ),
        onTap: toggle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 22,
              child: Center(
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: colors.textSecondary),
                  child: ProductionRatioBox(ratio: settings.ratio, scale: .7),
                ),
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            Text(
              '${settings.ratio} · '
              '${productionResolutionLabel(settings.resolution)}',
              style: typo.uiSmall.copyWith(
                color: colors.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            ProductionCaret(open: open, size: 11),
          ],
        ),
      ),
      panel: (context, close) => ProductionSpecPanel(
        ratios: ProductionSettings.ratios,
        resolutions: ProductionSettings.resolutions,
        ratio: settings.ratio,
        resolution: settings.resolution,
        onChanged: change,
        note: context.t(LocaleKeys.productionSpecNote),
      ),
    );
  }
}

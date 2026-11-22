// 职责: 为封面与地图工作室编辑未登记图片模型的质量和像素尺寸（预置 Chip + 就地自定义输入）。
// 关联文件:
//   lib/shared/models/image/choices.dart
//   lib/shared/widgets/cover_studio/sections.dart
//   lib/shared/widgets/map/map_generate_fields.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../components/reveric_text_field.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/image/choices.dart';
import '../../theme/theme.dart';
import '../../utils/text_input_composing.dart';

/// 常见质量预置值；原始值直接透传给渠道协议。
const studioCustomImageQualityPresets = <String>['low', 'medium', 'high'];

/// 尺寸预置项：[value] 为发往模型的 `WxH`，[label] 为界面展示文案。
class StudioImageSizePreset {
  const StudioImageSizePreset({required this.value, required this.label});

  final String value;
  final String label;
}

/// 不同工作室的常见出图比例与像素场景。
enum StudioImageParameterScene {
  cover([
    StudioImageSizePreset(value: '1024x1536', label: '2:3 · 1024×1536'),
    StudioImageSizePreset(value: '768x1024', label: '3:4 · 768×1024'),
    StudioImageSizePreset(value: '1024x1024', label: '1:1 · 1024×1024'),
    StudioImageSizePreset(value: '1536x1024', label: '3:2 · 1536×1024'),
  ]),
  map([
    StudioImageSizePreset(value: '1792x1024', label: '16:9 · 1792×1024'),
    StudioImageSizePreset(value: '1536x1024', label: '3:2 · 1536×1024'),
    StudioImageSizePreset(value: '1024x1024', label: '1:1 · 1024×1024'),
    StudioImageSizePreset(value: '1024x1536', label: '2:3 · 1024×1536'),
  ]);

  const StudioImageParameterScene(this.sizePresets);

  final List<StudioImageSizePreset> sizePresets;
}

class StudioImageCustomParameters extends HookWidget {
  const StudioImageCustomParameters({
    super.key,
    required this.parameters,
    required this.enabled,
    required this.onChanged,
    this.scene = StudioImageParameterScene.cover,
    this.showSectionIcons = false,
    this.touchTargets = false,
    this.sectionSpacing = RevericSpacing.lg,
  });

  final CustomImageParameters parameters;
  final bool enabled;
  final ValueChanged<CustomImageParameters> onChanged;
  final StudioImageParameterScene scene;

  /// 封面设计师小节带图标前缀；地图面板只展示纯文字小节标题。
  final bool showSectionIcons;

  /// 移动端触控增高；同时也会根据运行平台自动启用。
  final bool touchTargets;
  final double sectionSpacing;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final mobile =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    final useTouchTarget = touchTargets || mobile;
    final sizePresets = scene.sizePresets;
    final sizePresetValues = useMemoized(
      () => {for (final preset in sizePresets) preset.value},
      [scene],
    );

    final initialQualityCustom =
        parameters.quality != null &&
        !studioCustomImageQualityPresets.contains(parameters.quality);
    final initialSizeCustom =
        parameters.size != null && !sizePresetValues.contains(parameters.size);
    final initialDimensions = initialSizeCustom
        ? _splitDimensions(parameters.size)
        : (width: '', height: '');

    final qualityCustomOpen = useState(initialQualityCustom);
    final sizeCustomOpen = useState(initialSizeCustom);
    final qualityController = useTextEditingController(
      text: initialQualityCustom ? parameters.quality ?? '' : '',
    );
    final qualityFocusNode = useFocusNode();
    final widthController = useTextEditingController(
      text: initialDimensions.width,
    );
    final heightController = useTextEditingController(
      text: initialDimensions.height,
    );
    final widthFocusNode = useFocusNode();
    final sizeErrorKey = useState<String?>(
      initialSizeCustom
          ? _validateDimensions(
              initialDimensions.width,
              initialDimensions.height,
            ).errorKey
          : null,
    );

    // 区分本组件输入引发的回流与外部状态变更（如封面历史批次恢复 / 新建重置）。
    final lastEmittedRef = useRef<CustomImageParameters>(parameters);
    final syncingRef = useRef(false);

    useEffect(() {
      final previous = lastEmittedRef.value;
      final qualityChanged = parameters.quality != previous.quality;
      final sizeChanged = parameters.size != previous.size;
      lastEmittedRef.value = parameters;
      if (!qualityChanged && !sizeChanged) {
        return null;
      }
      var active = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!active) {
          return;
        }
        if (qualityChanged) {
          final isCustom =
              parameters.quality != null &&
              !studioCustomImageQualityPresets.contains(parameters.quality);
          syncingRef.value = true;
          qualityController.text = isCustom ? parameters.quality! : '';
          syncingRef.value = false;
          qualityCustomOpen.value = isCustom;
        }
        if (sizeChanged) {
          final isCustom =
              parameters.size != null &&
              !sizePresetValues.contains(parameters.size);
          final dims = isCustom
              ? _splitDimensions(parameters.size)
              : (width: '', height: '');
          syncingRef.value = true;
          widthController.text = dims.width;
          heightController.text = dims.height;
          syncingRef.value = false;
          sizeCustomOpen.value = isCustom;
          sizeErrorKey.value = isCustom
              ? _validateDimensions(dims.width, dims.height).errorKey
              : null;
        }
      });
      return () => active = false;
    }, [parameters.quality, parameters.size, sizePresetValues]);

    void emit(CustomImageParameters next) {
      lastEmittedRef.value = next;
      onChanged(next);
    }

    void selectQualityPreset(String? quality) {
      qualityCustomOpen.value = false;
      emit((quality: quality, size: parameters.size));
    }

    void openCustomQuality() {
      final wasOpen = qualityCustomOpen.value;
      qualityCustomOpen.value = true;
      if (!wasOpen) {
        final raw = qualityController.text.trim();
        emit((quality: raw.isEmpty ? null : raw, size: parameters.size));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && qualityFocusNode.canRequestFocus) {
          qualityFocusNode.requestFocus();
        }
      });
    }

    void onQualityTextChanged(String _) {
      if (syncingRef.value || isTextInputComposing(qualityController)) {
        return;
      }
      final trimmed = qualityController.text.trim();
      emit((quality: trimmed.isEmpty ? null : trimmed, size: parameters.size));
    }

    void selectSizePreset(String? size) {
      sizeCustomOpen.value = false;
      sizeErrorKey.value = null;
      emit((quality: parameters.quality, size: size));
    }

    void openCustomSize() {
      final wasOpen = sizeCustomOpen.value;
      if (!wasOpen &&
          parameters.size != null &&
          sizePresetValues.contains(parameters.size)) {
        // 从预置尺寸切到自定义时预填该宽高，便于在此基础上微调。
        final dims = _splitDimensions(parameters.size);
        syncingRef.value = true;
        widthController.text = dims.width;
        heightController.text = dims.height;
        syncingRef.value = false;
      }
      sizeCustomOpen.value = true;
      final evaluation = _validateDimensions(
        widthController.text,
        heightController.text,
      );
      sizeErrorKey.value = evaluation.errorKey;
      if (!wasOpen) {
        emit((quality: parameters.quality, size: evaluation.sizeValue));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && widthFocusNode.canRequestFocus) {
          widthFocusNode.requestFocus();
        }
      });
    }

    void onSizeTextChanged(String _) {
      if (syncingRef.value ||
          isTextInputComposing(widthController) ||
          isTextInputComposing(heightController)) {
        return;
      }
      final evaluation = _validateDimensions(
        widthController.text,
        heightController.text,
      );
      if (sizeErrorKey.value != evaluation.errorKey) {
        sizeErrorKey.value = evaluation.errorKey;
      }
      emit((quality: parameters.quality, size: evaluation.sizeValue));
    }

    final defaultLabel = context.t(LocaleKeys.commonDefault);
    final customLabel = context.t(LocaleKeys.commonCustom);
    final chipSpacing = showSectionIcons ? 6.0 : RevericSpacing.sm;
    final isPillChip = !showSectionIcons;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          key: const ValueKey('studio_image_quality_section'),
          icon: showSectionIcons ? RevericIcons.auto_awesome : null,
          label: context.t(LocaleKeys.editorCoverQuality),
        ),
        Wrap(
          spacing: chipSpacing,
          runSpacing: chipSpacing,
          children: [
            _OptionChip(
              key: const ValueKey('studio_image_quality_default'),
              label: defaultLabel,
              selected: !qualityCustomOpen.value && parameters.quality == null,
              enabled: enabled,
              pill: isPillChip,
              touchTarget: useTouchTarget,
              onTap: () => selectQualityPreset(null),
            ),
            for (final preset in studioCustomImageQualityPresets)
              _OptionChip(
                key: ValueKey('studio_image_quality_$preset'),
                label: preset,
                selected:
                    !qualityCustomOpen.value && parameters.quality == preset,
                enabled: enabled,
                pill: isPillChip,
                touchTarget: useTouchTarget,
                onTap: () => selectQualityPreset(preset),
              ),
            _OptionChip(
              key: const ValueKey('studio_image_quality_custom'),
              label: customLabel,
              selected: qualityCustomOpen.value,
              enabled: enabled,
              pill: isPillChip,
              touchTarget: useTouchTarget,
              onTap: openCustomQuality,
            ),
          ],
        ),
        if (qualityCustomOpen.value) ...[
          const SizedBox(height: RevericSpacing.sm),
          RevericTextField(
            fieldKey: const ValueKey('studio_image_custom_quality_input'),
            controller: qualityController,
            focusNode: qualityFocusNode,
            enabled: enabled,
            hintText: context.t(LocaleKeys.editorImageQualityCustomHint),
            autocorrect: false,
            enableSuggestions: false,
            onChanged: onQualityTextChanged,
          ),
        ],
        SizedBox(height: sectionSpacing),
        _SectionHeader(
          key: const ValueKey('studio_image_size_section'),
          icon: showSectionIcons ? RevericIcons.open_in_full_rounded : null,
          label: context.t(LocaleKeys.editorImageSize),
        ),
        Wrap(
          spacing: chipSpacing,
          runSpacing: chipSpacing,
          children: [
            _OptionChip(
              key: const ValueKey('studio_image_size_default'),
              label: defaultLabel,
              selected: !sizeCustomOpen.value && parameters.size == null,
              enabled: enabled,
              pill: isPillChip,
              touchTarget: useTouchTarget,
              onTap: () => selectSizePreset(null),
            ),
            for (final preset in sizePresets)
              _OptionChip(
                key: ValueKey('studio_image_size_${preset.value}'),
                label: preset.label,
                selected:
                    !sizeCustomOpen.value && parameters.size == preset.value,
                enabled: enabled,
                pill: isPillChip,
                touchTarget: useTouchTarget,
                onTap: () => selectSizePreset(preset.value),
              ),
            _OptionChip(
              key: const ValueKey('studio_image_size_custom'),
              label: customLabel,
              selected: sizeCustomOpen.value,
              enabled: enabled,
              pill: isPillChip,
              touchTarget: useTouchTarget,
              onTap: openCustomSize,
            ),
          ],
        ),
        if (sizeCustomOpen.value) ...[
          const SizedBox(height: RevericSpacing.sm),
          Row(
            children: [
              Expanded(
                child: RevericTextField(
                  fieldKey: const ValueKey('studio_image_custom_width_input'),
                  controller: widthController,
                  focusNode: widthFocusNode,
                  enabled: enabled,
                  hintText: context.t(LocaleKeys.editorImageWidth),
                  keyboardType: TextInputType.number,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: onSizeTextChanged,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.sm,
                ),
                child: Text(
                  '×',
                  style: typo.ui.copyWith(color: colors.textMuted),
                ),
              ),
              Expanded(
                child: RevericTextField(
                  fieldKey: const ValueKey('studio_image_custom_height_input'),
                  controller: heightController,
                  enabled: enabled,
                  hintText: context.t(LocaleKeys.editorImageHeight),
                  keyboardType: TextInputType.number,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: onSizeTextChanged,
                ),
              ),
            ],
          ),
          if (sizeErrorKey.value case final errorKey?) ...[
            const SizedBox(height: RevericSpacing.xs),
            Text(
              context.t(errorKey),
              style: typo.uiTiny.copyWith(color: colors.error),
            ),
          ],
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, this.icon, required this.label});

  final String? icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    if (icon == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
        child: Text(
          label,
          style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
      child: Row(
        children: [
          RevericIcon(icon!, size: 14, color: colors.accent),
          const SizedBox(width: RevericSpacing.xs),
          Expanded(
            child: Text(
              label,
              style: typo.uiSemibold.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.pill,
    required this.touchTarget,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final bool pill;
  final bool touchTarget;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final radius = BorderRadius.circular(pill ? 999 : RevericRadius.small);
    final foreground = !enabled
        ? colors.textSubtle
        : selected
        ? colors.accent
        : colors.textSecondary;
    final horizontalPadding = touchTarget
        ? RevericSpacing.lg
        : RevericSpacing.md;
    final verticalPadding = touchTarget
        ? RevericSpacing.sm
        : (pill ? 5.0 : RevericSpacing.xs);
    final textStyle = (pill ? typo.uiSmall : typo.uiTiny).copyWith(
      color: foreground,
    );

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Material(
        color: selected
            ? colors.accent.withValues(alpha: pill ? 0.12 : 0.14)
            : colors.surface,
        borderRadius: radius,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: radius,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: selected ? colors.accent : colors.border,
              ),
            ),
            child: Text(label, style: textStyle),
          ),
        ),
      ),
    );
  }
}

({String width, String height}) _splitDimensions(String? size) {
  if (size == null || size.isEmpty) {
    return (width: '', height: '');
  }
  final parts = size.split('x');
  return (
    width: parts.first.trim(),
    height: parts.length > 1 ? parts[1].trim() : '',
  );
}

({String? sizeValue, String? errorKey}) _validateDimensions(
  String rawWidth,
  String rawHeight,
) {
  final widthText = rawWidth.trim();
  final heightText = rawHeight.trim();
  if (widthText.isEmpty && heightText.isEmpty) {
    return (sizeValue: null, errorKey: null);
  }
  final width = _positivePixels(widthText);
  final height = _positivePixels(heightText);
  if ((widthText.isNotEmpty && width == null) ||
      (heightText.isNotEmpty && height == null)) {
    // 保留非空非法值以阻断生成校验，避免静默回退成默认尺寸发出请求。
    return (
      sizeValue: '${widthText}x$heightText',
      errorKey: LocaleKeys.editorImageDimensionPositive,
    );
  }
  if (width == null || height == null) {
    return (
      sizeValue: '${widthText}x$heightText',
      errorKey: LocaleKeys.editorImageDimensionsIncomplete,
    );
  }
  return (sizeValue: '${width}x$height', errorKey: null);
}

int? _positivePixels(String text) {
  if (!RegExp(r'^[0-9]+$').hasMatch(text)) {
    return null;
  }
  final pixels = int.tryParse(text);
  return pixels != null && pixels > 0 ? pixels : null;
}

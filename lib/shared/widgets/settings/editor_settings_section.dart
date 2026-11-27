// 职责: 共享编辑器设置区 — 字体、排版、桌面 minimap、实体识别与行标记配置。
// 关联文件:
//   lib/shared/widgets/settings/settings_section_widgets.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/providers/system_font_providers.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/theme/theme.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_color_picker_dialog.dart';
import '../../components/reveric_input_decoration.dart';
import '../../components/reveric_inputs.dart';
import '../../components/reveric_select.dart';
import '../../components/reveric_switch.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../providers/settings_providers.dart';
import '../../providers/system_font_providers.dart';
import '../../theme/theme.dart';
import 'settings_section_widgets.dart';

const _customFontValue = '__custom_font__';

/// 编辑器设置 section：字体 + 实体样式 + 自动排版 + 行样式。
class EditorSettingsSection extends StatelessWidget {
  const EditorSettingsSection({super.key, this.showMinimapSetting = false});

  /// 桌面端展示 minimap 开关；移动端设置页保持隐藏。
  final bool showMinimapSetting;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _EditorFontsSection(showMinimapSetting: showMinimapSetting),
          const SizedBox(height: RevericSpacing.x4l),
          const _EditorEntityStyleSection(),
          const SizedBox(height: RevericSpacing.x4l),
          const _EditorFormatSection(),
          const SizedBox(height: RevericSpacing.x4l),
          const _EditorLineSection(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fonts section
// ---------------------------------------------------------------------------

class _EditorFontsSection extends HookConsumerWidget {
  const _EditorFontsSection({required this.showMinimapSetting});

  final bool showMinimapSetting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentFont = ref.watch(editorFontFamilyProvider);
    final currentSize = ref.watch(editorFontSizeProvider);
    final fontColorHex = ref.watch(editorFontColorHexProvider);
    final fontColor = ref.watch(editorFontColorProvider);
    final colors = RevericTheme.colorsOf(context);
    final currentLetterSpacing = ref.watch(editorLetterSpacingProvider);
    final currentLineHeight = ref.watch(editorLineHeightProvider);
    final minimapEnabled = ref.watch(editorMinimapEnabledProvider);
    final dialogueHighlightEnabled = ref.watch(
      editorDialogueHighlightEnabledProvider,
    );
    final settingsAsync = ref.watch(appSettingsProvider);
    final language = settingsAsync.maybeWhen(
      data: (settings) => settings.language,
      orElse: () => 'zh_CN',
    );
    final fontFamiliesAsync = ref.watch(systemFontFamiliesProvider);
    final systemFontFamilies = fontFamiliesAsync.hasValue
        ? fontFamiliesAsync.value ?? const <String>[]
        : const <String>[];
    final fontFamilies = [
      ...AppSettings.bundledFontFamilies,
      ...systemFontFamilies.where(
        (font) => !AppSettings.bundledFontFamilies.contains(font),
      ),
    ];
    final notifier = ref.read(appSettingsProvider.notifier);
    final controller = useTextEditingController(text: currentFont);
    final showCustomInput = useState(false);
    final isFontListLoaded = fontFamiliesAsync.hasValue;
    final isCustom = isFontListLoaded && !fontFamilies.contains(currentFont);
    final shouldShowCustomInput = isCustom || showCustomInput.value;
    final selectedFontValue = isCustom ? _customFontValue : currentFont;
    final usesDefaultTypography =
        currentFont == AppSettings.defaultFontFamilyForLanguage(language) &&
        currentSize == AppSettings.defaultEditorFontSize &&
        fontColorHex.isEmpty &&
        currentLetterSpacing == AppSettings.defaultEditorLetterSpacing &&
        currentLineHeight == AppSettings.defaultEditorLineHeight;

    useEffect(() {
      showCustomInput.value = isCustom;
      if (controller.text != currentFont) {
        controller.value = controller.value.copyWith(
          text: currentFont,
          selection: TextSelection.collapsed(offset: currentFont.length),
          composing: TextRange.empty,
        );
      }
      return null;
    }, [currentFont, isCustom]);

    return SettingsSection(
      titleKey: LocaleKeys.settingsFontsSection,
      descriptionKey: LocaleKeys.settingsFontsDescription,
      trailing: usesDefaultTypography
          ? null
          : _ResetTypographyButton(onPressed: notifier.resetEditorTypography),
      child: SettingsCard(
        children: [
          _EditorPreview(
            fontFamily: currentFont,
            fontSize: currentSize,
            fontColor: fontColor,
            letterSpacing: currentLetterSpacing,
            lineHeight: currentLineHeight,
          ),
          if (showMinimapSetting) ...[
            const SettingsRowDivider(),
            SettingsRow(
              labelKey: LocaleKeys.settingsEditorMinimap,
              descriptionKey: LocaleKeys.settingsEditorMinimapDescription,
              child: Align(
                alignment: Alignment.centerLeft,
                child: RevericSwitch(
                  value: minimapEnabled,
                  onChanged: notifier.setEditorMinimapEnabled,
                ),
              ),
            ),
          ],
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorLineNumbers,
            descriptionKey: LocaleKeys.settingsEditorLineNumbersDescription,
            child: Align(
              alignment: Alignment.centerLeft,
              child: RevericSwitch(
                value: ref.watch(editorLineNumbersEnabledProvider),
                onChanged: ref
                    .read(appSettingsProvider.notifier)
                    .setEditorLineNumbersEnabled,
              ),
            ),
          ),
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorDialogueHighlight,
            descriptionKey:
                LocaleKeys.settingsEditorDialogueHighlightDescription,
            child: Align(
              alignment: Alignment.centerLeft,
              child: RevericSwitch(
                value: dialogueHighlightEnabled,
                onChanged: settingsAsync.asData == null
                    ? null
                    : notifier.setEditorDialogueHighlightEnabled,
              ),
            ),
          ),
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorHighlightColor,
            descriptionKey: LocaleKeys.settingsEditorHighlightColorDescription,
            child: _ColorPickerField(
              colorHex: ref.watch(editorHighlightColorHexProvider),
              presets: _presetHighlightColors,
              enabled: settingsAsync.asData != null,
              allowEmpty: true,
              fallbackColor: colors.editorHighlightBackground,
              hintText: '#AARRGGBB',
              onChanged: notifier.setEditorHighlightColorHex,
            ),
          ),
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorFont,
            descriptionKey: LocaleKeys.settingsEditorFontDescription,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RevericSelect<String>(
                  value: selectedFontValue,
                  placeholder: currentFont,
                  items: [
                    for (final font in fontFamilies)
                      RevericSelectItem(value: font, label: font),
                    RevericSelectItem(
                      value: _customFontValue,
                      label: context.t(LocaleKeys.settingsAddCustomProvider),
                    ),
                  ],
                  enabled: !fontFamiliesAsync.isLoading,
                  onChanged: (font) {
                    if (font == _customFontValue) {
                      showCustomInput.value = true;
                      return;
                    }
                    showCustomInput.value = false;
                    notifier.setEditorFontFamily(font);
                    controller.text = font;
                  },
                ),
                _buildFontListStatus(context, fontFamiliesAsync),
                if (shouldShowCustomInput) ...[
                  const SizedBox(height: RevericSpacing.sm),
                  RevericInlineActionInput(
                    controller: controller,
                    hintText: isCustom
                        ? currentFont
                        : context.t(LocaleKeys.settingsEditorFont),
                    actionLabel: context.t(LocaleKeys.commonSave),
                    onActionPressed: () {
                      final text = controller.text.trim();
                      if (text.isNotEmpty) {
                        showCustomInput.value = true;
                        notifier.setEditorFontFamily(text);
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorFontSize,
            descriptionKey: LocaleKeys.settingsEditorFontSizeDescription,
            child: _MetricSlider(
              value: currentSize.toDouble(),
              min: 10,
              max: 32,
              divisions: 22,
              valueLabel: '$currentSize',
              onChanged: (v) => notifier.setEditorFontSize(v.round()),
            ),
          ),
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorFontColor,
            descriptionKey: LocaleKeys.settingsEditorFontColorDescription,
            child: _ColorPickerField(
              colorHex: fontColorHex,
              presets: _presetEntityTextColors,
              enableAlpha: false,
              enabled: settingsAsync.hasValue,
              allowEmpty: true,
              fallbackColor: colors.textPrimary,
              hintText: '#RRGGBB',
              onChanged: notifier.setEditorFontColorHex,
            ),
          ),
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorLetterSpacing,
            descriptionKey: LocaleKeys.settingsEditorLetterSpacingDescription,
            child: _MetricSlider(
              value: currentLetterSpacing,
              min: 0,
              max: 4,
              divisions: 40,
              valueLabel: currentLetterSpacing.toStringAsFixed(1),
              onChanged: notifier.setEditorLetterSpacing,
            ),
          ),
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorLineHeight,
            descriptionKey: LocaleKeys.settingsEditorLineHeightDescription,
            child: _MetricSlider(
              value: currentLineHeight,
              min: 1.2,
              max: 2.4,
              divisions: 24,
              valueLabel: currentLineHeight.toStringAsFixed(2),
              onChanged: notifier.setEditorLineHeight,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Entity recognition section
// ---------------------------------------------------------------------------

class _EditorEntityStyleSection extends ConsumerWidget {
  const _EditorEntityStyleSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final recognitionReady = settingsAsync.hasValue;
    final recognitionEnabled =
        settingsAsync.asData?.value.editorEntityRecognitionEnabled ?? false;
    final italic = ref.watch(editorEntityItalicProvider);
    final bold = ref.watch(editorEntityBoldProvider);
    final underline = ref.watch(editorEntityUnderlineProvider);
    final highlight = ref.watch(editorEntityHighlightProvider);
    final highlightColorHex = ref.watch(editorEntityHighlightColorHexProvider);
    final textColorHex = ref.watch(editorEntityTextColorHexProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final colors = RevericTheme.colorsOf(context);

    return SettingsSection(
      titleKey: LocaleKeys.settingsEditorEntityStyle,
      descriptionKey: LocaleKeys.settingsEditorEntityStyleDescription,
      trailing: RevericSwitch(
        value: recognitionEnabled,
        onChanged: recognitionReady
            ? notifier.setEditorEntityRecognitionEnabled
            : null,
      ),
      child: SettingsCard(
        children: [
          Wrap(
            spacing: RevericSpacing.sm,
            runSpacing: RevericSpacing.sm,
            children: [
              _ToggleChip(
                label: context.t(LocaleKeys.settingsEditorEntityItalic),
                isSelected: italic,
                enabled: recognitionReady && recognitionEnabled,
                onTap: () => notifier.setEditorEntityItalic(!italic),
              ),
              _ToggleChip(
                label: context.t(LocaleKeys.settingsEditorEntityBold),
                isSelected: bold,
                enabled: recognitionReady && recognitionEnabled,
                onTap: () => notifier.setEditorEntityBold(!bold),
              ),
              _ToggleChip(
                label: context.t(LocaleKeys.settingsEditorEntityUnderline),
                isSelected: underline,
                enabled: recognitionReady && recognitionEnabled,
                onTap: () => notifier.setEditorEntityUnderline(!underline),
              ),
              _ToggleChip(
                label: context.t(LocaleKeys.settingsEditorEntityHighlight),
                isSelected: highlight,
                enabled: recognitionReady && recognitionEnabled,
                onTap: () => notifier.setEditorEntityHighlight(!highlight),
              ),
            ],
          ),
          if (highlight) ...[
            const SettingsRowDivider(),
            SettingsRow(
              labelKey: LocaleKeys.settingsEditorEntityHighlightColor,
              child: _ColorPickerField(
                colorHex: highlightColorHex,
                presets: _presetHighlightColors,
                enableAlpha: true,
                enabled: recognitionReady && recognitionEnabled,
                hintText: '#33FFD54F',
                onChanged: notifier.setEditorEntityHighlightColorHex,
              ),
            ),
          ],
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorEntityTextColor,
            descriptionKey: LocaleKeys.settingsEditorEntityTextColorDescription,
            child: _ColorPickerField(
              colorHex: textColorHex,
              presets: _presetEntityTextColors,
              enableAlpha: false,
              enabled: recognitionReady && recognitionEnabled,
              allowEmpty: true,
              fallbackColor: colors.textPrimary,
              hintText: '#RRGGBB',
              onChanged: notifier.setEditorEntityTextColorHex,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Line section
// ---------------------------------------------------------------------------

class _EditorLineSection extends ConsumerWidget {
  const _EditorLineSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(editorLineEnabledProvider);
    final style = ref.watch(editorLineStyleProvider);
    final colorHex = ref.watch(editorLineColorHexProvider);
    final notifier = ref.read(appSettingsProvider.notifier);

    return SettingsSection(
      titleKey: LocaleKeys.settingsEditorLine,
      descriptionKey: LocaleKeys.settingsEditorLineDescription,
      trailing: RevericSwitch(
        value: enabled,
        onChanged: notifier.setEditorLineEnabled,
      ),
      child: SettingsCard(
        children: [
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorLineStyle,
            child: _LineStyleSelector(
              value: style,
              enabled: enabled,
              onChanged: notifier.setEditorLineStyle,
            ),
          ),
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorLineColor,
            child: _ColorPickerField(
              colorHex: colorHex,
              presets: _presetLineColors,
              enableAlpha: true,
              hintText: '#FFFF0000',
              enabled: enabled,
              onChanged: notifier.setEditorLineColorHex,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Auto format section
// ---------------------------------------------------------------------------

class _EditorFormatSection extends ConsumerWidget {
  const _EditorFormatSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indentCount = ref.watch(editorFormatIndentCountProvider);
    final paragraphSpacing = ref.watch(editorFormatParagraphSpacingProvider);
    final allowSpaces = ref.watch(editorFormatAllowSpacesProvider);
    final notifier = ref.read(appSettingsProvider.notifier);

    return SettingsSection(
      titleKey: LocaleKeys.settingsEditorFormat,
      descriptionKey: LocaleKeys.settingsEditorFormatDescription,
      child: SettingsCard(
        children: [
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorFormatIndentCount,
            descriptionKey:
                LocaleKeys.settingsEditorFormatIndentCountDescription,
            child: _MetricSlider(
              value: indentCount.toDouble(),
              min: 0,
              max: 8,
              divisions: 8,
              valueLabel: '$indentCount',
              onChanged: (v) => notifier.setEditorFormatIndentCount(v.round()),
            ),
          ),
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorFormatParagraphSpacing,
            descriptionKey:
                LocaleKeys.settingsEditorFormatParagraphSpacingDescription,
            child: _ParagraphSpacingSelector(
              value: paragraphSpacing,
              onChanged: notifier.setEditorFormatParagraphSpacing,
            ),
          ),
          const SettingsRowDivider(),
          SettingsRow(
            labelKey: LocaleKeys.settingsEditorFormatAllowSpaces,
            descriptionKey:
                LocaleKeys.settingsEditorFormatAllowSpacesDescription,
            child: Align(
              alignment: Alignment.centerLeft,
              child: RevericSwitch(
                value: allowSpaces,
                onChanged: notifier.setEditorFormatAllowSpaces,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ParagraphSpacingSelector extends StatelessWidget {
  const _ParagraphSpacingSelector({
    required this.value,
    required this.onChanged,
  });

  final EditorParagraphSpacing value;
  final ValueChanged<EditorParagraphSpacing> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: RevericSpacing.sm,
      runSpacing: RevericSpacing.sm,
      children: [
        _ToggleChip(
          label: context.t(LocaleKeys.settingsEditorFormatParagraphSpacingNone),
          isSelected: value == EditorParagraphSpacing.none,
          onTap: () => onChanged(EditorParagraphSpacing.none),
        ),
        _ToggleChip(
          label: context.t(
            LocaleKeys.settingsEditorFormatParagraphSpacingOneBlankLine,
          ),
          isSelected: value == EditorParagraphSpacing.one_blank_line,
          onTap: () => onChanged(EditorParagraphSpacing.one_blank_line),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Reusable controls
// ---------------------------------------------------------------------------

class _ResetTypographyButton extends StatelessWidget {
  const _ResetTypographyButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: const RevericIcon(RevericIcons.undo, size: 14),
      label: Text(context.t(LocaleKeys.commonReset)),
    );
  }
}

class _EditorPreview extends StatelessWidget {
  const _EditorPreview({
    required this.fontFamily,
    required this.fontSize,
    this.fontColor,
    required this.letterSpacing,
    required this.lineHeight,
  });

  final String fontFamily;
  final int fontSize;
  final Color? fontColor;
  final double letterSpacing;
  final double lineHeight;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: RevericSpacing.md),
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The quick brown fox jumps over the lazy dog.',
            style: typo.body.copyWith(
              color: fontColor ?? colors.textPrimary,
              fontFamily: fontFamily,
              fontSize: fontSize.toDouble(),
              height: lineHeight,
              letterSpacing: letterSpacing,
            ),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            '秋风萧瑟天气凉,草木摇落露为霜。',
            style: typo.body.copyWith(
              color: fontColor ?? colors.textPrimary,
              fontFamily: fontFamily,
              fontSize: fontSize.toDouble(),
              height: lineHeight,
              letterSpacing: letterSpacing,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  const _ToggleChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final disabled = !enabled;
    final bg = isSelected ? colors.selected : Colors.transparent;
    final borderColor = isSelected ? colors.accent : colors.borderSubtle;
    final textColor = disabled
        ? colors.textMuted
        : (isSelected ? colors.textPrimary : colors.textSecondary);

    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: InkWell(
          onTap: disabled ? null : onTap,
          hoverColor: colors.hover,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          child: Container(
            padding: const EdgeInsets.symmetric(
              vertical: RevericSpacing.sm,
              horizontal: RevericSpacing.lg,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(RevericRadius.medium),
              border: Border.all(color: borderColor),
            ),
            child: Text(
              label,
              style: typo.uiSmall.copyWith(
                color: textColor,
                fontWeight: isSelected ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricSlider extends StatelessWidget {
  const _MetricSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      children: [
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              divisions: divisions,
              activeColor: colors.accent,
              inactiveColor: colors.border,
              onChanged: onChanged,
            ),
          ),
        ),
        const SizedBox(width: RevericSpacing.md),
        Container(
          constraints: const BoxConstraints(minWidth: 48),
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(RevericRadius.small),
            border: Border.all(color: colors.border),
          ),
          alignment: Alignment.center,
          child: Text(
            valueLabel,
            style: typo.uiSmallSemibold.copyWith(color: colors.accent),
          ),
        ),
      ],
    );
  }
}

class _LineStyleSelector extends StatelessWidget {
  const _LineStyleSelector({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final EditorLineStyle value;
  final ValueChanged<EditorLineStyle> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final styles = EditorLineStyle.values;
    String labelOf(EditorLineStyle s) => switch (s) {
      EditorLineStyle.solid => context.t(
        LocaleKeys.settingsEditorLineStyleSolid,
      ),
      EditorLineStyle.sparseDashed => context.t(
        LocaleKeys.settingsEditorLineStyleSparseDashed,
      ),
      EditorLineStyle.denseDashed => context.t(
        LocaleKeys.settingsEditorLineStyleDenseDashed,
      ),
    };

    return Wrap(
      spacing: RevericSpacing.sm,
      runSpacing: RevericSpacing.sm,
      children: [
        for (final s in styles)
          _ToggleChip(
            label: labelOf(s),
            isSelected: s == value,
            enabled: enabled,
            onTap: () => onChanged(s),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Color picker field
// ---------------------------------------------------------------------------

class _ColorPickerField extends HookWidget {
  const _ColorPickerField({
    required this.colorHex,
    required this.presets,
    required this.hintText,
    required this.onChanged,
    this.enableAlpha = true,
    this.enabled = true,
    this.allowEmpty = false,
    this.fallbackColor,
  });

  final String colorHex;
  final List<String> presets;
  final String hintText;
  final bool enableAlpha;
  final bool enabled;
  final bool allowEmpty;
  final Color? fallbackColor;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final controller = useTextEditingController(text: colorHex);
    final normalizedColorHex = _normalizeColorHexOrNull(colorHex);
    final resolvedColor = normalizedColorHex == null
        ? fallbackColor ?? colors.textPrimary
        : _parseHexColor(normalizedColorHex);

    useEffect(() {
      if (controller.text != colorHex) {
        controller.value = controller.value.copyWith(
          text: colorHex,
          selection: TextSelection.collapsed(offset: colorHex.length),
          composing: TextRange.empty,
        );
      }
      return null;
    }, [colorHex]);

    Future<void> openPicker() async {
      final picked = await showRevericColorPickerDialog(
        context: context,
        initialColor: resolvedColor,
        enableAlpha: enableAlpha,
      );
      if (picked != null) {
        onChanged(_colorToHex(picked, includeAlpha: enableAlpha));
      }
    }

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: IgnorePointer(
        ignoring: !enabled,
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, child) {
            final normalized = _normalizeColorHexOrNull(value.text);
            final hasInput = value.text.trim().isNotEmpty;
            final showError = hasInput && normalized == null;

            void commit() {
              if (allowEmpty && !hasInput && colorHex.isNotEmpty) {
                onChanged('');
                return;
              }
              if (normalized != null && normalized != colorHex) {
                onChanged(normalized);
              }
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _ColorPreviewButton(
                      color: resolvedColor,
                      onTap: openPicker,
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    Expanded(
                      child: SizedBox(
                        height: RevericSizes.buttonHeight,
                        child: TextField(
                          controller: controller,
                          textAlignVertical: TextAlignVertical.center,
                          style: typo.ui.copyWith(color: colors.textPrimary),
                          decoration: revericInputDecoration(
                            context,
                            hintText: hintText,
                            fillColor: colors.surfaceDim,
                            radius: RevericRadius.medium,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: RevericSpacing.md,
                            ),
                          ),
                          onSubmitted: (_) => commit(),
                          onEditingComplete: commit,
                        ),
                      ),
                    ),
                  ],
                ),
                if (showError) ...[
                  const SizedBox(height: RevericSpacing.xs),
                  Text(
                    context.t(LocaleKeys.settingsEditorColorInvalid),
                    style: typo.uiSmall.copyWith(color: colors.warningText),
                  ),
                ],
                if (presets.isNotEmpty) ...[
                  const SizedBox(height: RevericSpacing.sm),
                  _ColorSwatches(
                    selectedHex: colorHex,
                    colors: presets,
                    onSelected: onChanged,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ColorPreviewButton extends StatelessWidget {
  const _ColorPreviewButton({required this.color, required this.onTap});

  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final themeColors = RevericTheme.colorsOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: Container(
        width: RevericSizes.buttonHeight,
        height: RevericSizes.buttonHeight,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          border: Border.all(color: themeColors.borderInput),
        ),
      ),
    );
  }
}

class _ColorSwatches extends StatelessWidget {
  const _ColorSwatches({
    required this.selectedHex,
    required this.colors,
    required this.onSelected,
  });

  final String selectedHex;
  final List<String> colors;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final themeColors = RevericTheme.colorsOf(context);
    return Wrap(
      spacing: RevericSpacing.sm,
      runSpacing: RevericSpacing.sm,
      children: [
        for (final hex in colors)
          GestureDetector(
            onTap: () => onSelected(hex),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: _parseHexColor(hex),
                shape: BoxShape.circle,
                border: Border.all(
                  color: selectedHex == hex
                      ? themeColors.accent
                      : themeColors.borderSubtle,
                  width: selectedHex == hex ? 2.5 : 1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

const _presetLineColors = [
  '#FFFF0000',
  '#FF0000FF',
  '#FF00AA00',
  '#FFFF8800',
  '#FF8800FF',
  '#FF00CCCC',
  '#FFCCCC00',
  '#FFFF4488',
  '#FF444444',
  '#FF888888',
  '#FF000000',
  '#FFAA5500',
];

const _presetHighlightColors = [
  '#33FFD54F',
  '#33FF8A65',
  '#334FC3F7',
  '#3381C784',
  '#33BA68C8',
  '#33F06292',
  '#33A1887F',
  '#335C6BC0',
];

const _presetEntityTextColors = [
  '#B42318',
  '#B54708',
  '#175CD3',
  '#027A48',
  '#6941C6',
  '#C11574',
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _colorToHex(Color color, {bool includeAlpha = true}) {
  final value = color.toARGB32();
  if (includeAlpha) {
    return '#${value.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }
  final rgb = value & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

Color _parseHexColor(String hex) {
  var v = hex.replaceFirst('#', '');
  if (v.length == 6) {
    v = 'FF$v';
  }
  if (v.length != 8) {
    return const Color(0xFF000000);
  }
  return Color(int.parse(v, radix: 16));
}

String? _normalizeColorHexOrNull(String value) {
  final text = value.trim();
  final match = RegExp(r'^#?([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').firstMatch(text);
  if (match == null) {
    return null;
  }
  return '#${match.group(1)!.toUpperCase()}';
}

Widget _buildFontListStatus(
  BuildContext context,
  AsyncValue<List<String>> fontFamiliesAsync,
) {
  final colors = RevericTheme.colorsOf(context);
  final typo = RevericTheme.typographyOf(context);
  final message = fontFamiliesAsync.when(
    data: (fonts) {
      if (fonts.isEmpty) {
        return context.t(LocaleKeys.settingsEditorFontsUnavailable);
      }
      return null;
    },
    error: (error, stackTrace) =>
        context.t(LocaleKeys.settingsEditorFontsUnavailable),
    loading: () => context.t(LocaleKeys.settingsEditorFontsLoading),
  );
  if (message == null) {
    return const SizedBox.shrink();
  }
  return Padding(
    padding: const EdgeInsets.only(top: RevericSpacing.xs),
    child: Text(message, style: typo.uiSmall.copyWith(color: colors.textMuted)),
  );
}

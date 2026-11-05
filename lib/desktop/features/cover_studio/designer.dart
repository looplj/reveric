// 职责: 桌面封面工作台第四列 — 设计师面板外壳，串起各参数区块并挂上生成脚。
// 关联文件:
//   lib/shared/providers/cover_studio_providers.dart
//   lib/shared/widgets/cover_studio/sections.dart
//   lib/shared/widgets/cover_studio/generate_footer.dart
//   lib/desktop/widgets/desktop_window_frame.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/desktop-window-frame.md
//   .agents/rules/form.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/i18n.md

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/cover_studio_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/app_background.dart';
import '../../../shared/widgets/cover_studio/brief_section.dart';
import '../../../shared/widgets/cover_studio/generate_footer.dart';
import '../../../shared/widgets/cover_studio/reference_section.dart';
import '../../../shared/widgets/cover_studio/sections.dart';
import '../../../third/form/flutter_hook_form.dart';
import '../../widgets/desktop_window_frame.dart';

class CoverStudioDesigner extends ConsumerWidget {
  const CoverStudioDesigner({
    super.key,
    required this.novel,
    required this.databasePath,
    required this.libraryAssets,
    required this.form,
    required this.promptController,
    required this.onGenerate,
    required this.onReadBrief,
    required this.onAppendPrompt,
  });

  final Novel novel;
  final String? databasePath;
  final List<AssetRow> libraryAssets;
  final FormFieldsController<CoverStudioField> form;
  final TextEditingController promptController;
  final VoidCallback onGenerate;
  final VoidCallback onReadBrief;
  final ValueChanged<String> onAppendPrompt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final state = ref.watch(coverStudioControllerProvider(novel.id));
    final path = databasePath;
    final chrome = appChromeBackgroundColor(
      colors,
      ref.watch(appBackgroundActiveProvider),
      colors.surfaceContainerHigh,
    );

    return ColoredBox(
      color: chrome,
      child: Column(
        children: [
          const _Header(),
          Divider(height: 1, color: colors.border),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text(
                state.error!.localeKey != null
                    ? context.t(state.error!.localeKey!)
                    : state.error!.text ?? '',
                style: typo.uiTiny.copyWith(color: colors.error),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: HookedForm(
                form: form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CoverWorkSection(novel: novel, databasePath: path),
                    const SizedBox(height: RevericSpacing.x3l),
                    CoverPromptSection(
                      field: HookedFormField<CoverStudioField, String>(
                        fieldHook: CoverStudioField.prompt,
                        builder: (value, onChanged, error) => RevericTextField(
                          controller: promptController,
                          multiline: true,
                          minLines: 4,
                          maxLines: 8,
                          hintText: context.t(LocaleKeys.editorCoverPromptHint),
                          errorText: error,
                          // 提示词偏长，用小号字塞进窄面板。
                          style: typo.uiSmall.copyWith(height: 1.5),
                        ),
                      ),
                      synopsis: novel.description,
                      onAppend: onAppendPrompt,
                    ),
                    const SizedBox(height: RevericSpacing.x3l),
                    CoverReferenceSection(
                      novelId: novel.id,
                      libraryAssets: libraryAssets,
                      pickImagePaths: _pickReferenceFiles,
                    ),
                    const SizedBox(height: RevericSpacing.x3l),
                    CoverQualitySection(novelId: novel.id),
                    const SizedBox(height: RevericSpacing.x3l),
                    CoverComplexitySection(novelId: novel.id),
                    CoverResolutionSection(novelId: novel.id),
                    const SizedBox(height: RevericSpacing.x3l),
                    CoverRatioSection(novelId: novel.id),
                    const SizedBox(height: RevericSpacing.x3l),
                    CoverAdvancedSection(
                      novelId: novel.id,
                      children: [
                        CoverStyleSection(onAppend: onAppendPrompt),
                        CoverPaletteSection(onAppend: onAppendPrompt),
                        CoverCompositionSection(onAppend: onAppendPrompt),
                        if (path != null) ...[
                          CoverBriefSection(
                            databasePath: path,
                            onRead: onReadBrief,
                            onAppend: onAppendPrompt,
                          ),
                          CoverInspirationSection(
                            databasePath: path,
                            onAppend: onAppendPrompt,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
            child: CoverGenerateFooter(
              novelId: novel.id,
              onGenerate: onGenerate,
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面走系统文件对话框选参考图；移动端那份走相册，所以选图这一步由两端各自注入。
Future<List<String>> _pickReferenceFiles() async {
  final files = await openFiles(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'images',
        extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
      ),
    ],
  );
  return [for (final file in files) file.path];
}

/// 与聊天面板标题栏同一套窗口避让：Windows 上先让出 caption，再画 48px 标题行；
/// 其它平台标题行与系统按钮同行，右侧加上 [DesktopWindowFrame.trailingInset]。
class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final topInset = DesktopWindowFrame.captionSafeTopInset;
    final trailingInset = topInset == 0
        ? DesktopWindowFrame.trailingInset
        : 0.0;
    final chrome = appChromeBackgroundColor(
      colors,
      ref.watch(appBackgroundActiveProvider),
      colors.surfaceContainerHigh,
    );

    return ColoredBox(
      color: chrome,
      child: SizedBox(
        height: DesktopWindowFrame.titleBarHeight + topInset,
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: SizedBox(
            height: DesktopWindowFrame.titleBarHeight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                RevericSpacing.x2l,
                0,
                RevericSpacing.lg + trailingInset,
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  RevericIcon(
                    RevericIcons.palette_outlined,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: Text(
                      context.t(LocaleKeys.editorCoverDesigner),
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

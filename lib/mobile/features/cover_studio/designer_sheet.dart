// 职责: 移动端封面设计师抽屉 — 提示词与全部出图参数，底部挂共享生成脚。
// 关联文件:
//   lib/mobile/features/cover_studio/studio_page.dart
//   lib/shared/widgets/cover_studio/sections.dart
//   lib/shared/widgets/cover_studio/reference_section.dart
//   lib/shared/widgets/cover_studio/generate_footer.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/form.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/i18n.md

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/cover_studio_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/cover_studio/brief_section.dart';
import '../../../shared/widgets/cover_studio/generate_footer.dart';
import '../../../shared/widgets/cover_studio/reference_section.dart';
import '../../../shared/widgets/cover_studio/sections.dart';
import '../../../third/form/flutter_hook_form.dart';

/// 拉起设计师抽屉。
///
/// [promptController] 与 [form] 都归页面所有 —— 抽屉是另一条 route、另一棵
/// element 树，但闭包捕获的是同一个 controller 实例，所以页面上的
/// `ref.listen(draftSeq / promptRestore)` 回填照常生效，关掉抽屉也不会丢字。
Future<void> openMobileCoverDesignerSheet(
  BuildContext context, {
  required Novel novel,
  required String? databasePath,
  required List<AssetRow> libraryAssets,
  required FormFieldsController<CoverStudioField> form,
  required TextEditingController promptController,
  required VoidCallback onGenerate,
  required VoidCallback onReadBrief,
  required ValueChanged<String> onAppendPrompt,
}) {
  final colors = RevericTheme.colorsOf(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: colors.surface,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    builder: (sheetContext) {
      return _DesignerSheet(
        novel: novel,
        databasePath: databasePath,
        libraryAssets: libraryAssets,
        form: form,
        promptController: promptController,
        // 出图过程中抽屉挡着画布，而且生成脚会在按钮与进度条之间换结构；
        // 先关抽屉再发起，作者能立刻看到画面在长出来。
        onGenerate: () {
          Navigator.of(sheetContext).pop();
          onGenerate();
        },
        onReadBrief: onReadBrief,
        onAppendPrompt: onAppendPrompt,
      );
    },
  );
}

class _DesignerSheet extends ConsumerWidget {
  const _DesignerSheet({
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

    return Padding(
      // 键盘顶上来时让开，否则提示词输入框被压在下面看不见。
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          // 抽屉不铺满整屏：留一条画布在上面，作者知道自己没离开工作台。
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.x2l,
                  0,
                  RevericSpacing.x2l,
                  RevericSpacing.md,
                ),
                child: Row(
                  children: [
                    Text(
                      context.t(LocaleKeys.editorCoverDesigner),
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    RevericSpacing.x2l,
                    0,
                    RevericSpacing.x2l,
                    RevericSpacing.sm,
                  ),
                  child: Text(
                    state.error!.localeKey != null
                        ? context.t(state.error!.localeKey!)
                        : state.error!.text ?? '',
                    style: typo.uiTiny.copyWith(color: colors.error),
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    RevericSpacing.x2l,
                    0,
                    RevericSpacing.x2l,
                    RevericSpacing.x2l,
                  ),
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
                            builder: (value, onChanged, error) =>
                                RevericTextField(
                                  controller: promptController,
                                  multiline: true,
                                  minLines: 4,
                                  maxLines: 8,
                                  hintText: context.t(
                                    LocaleKeys.editorCoverPromptHint,
                                  ),
                                  errorText: error,
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
                          pickImagePaths: _pickReferenceImages,
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
              Divider(height: 1, color: colors.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.x2l,
                  RevericSpacing.md,
                  RevericSpacing.x2l,
                  RevericSpacing.x2l,
                ),
                child: CoverGenerateFooter(
                  novelId: novel.id,
                  onGenerate: onGenerate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 移动端从相册选参考图；桌面那份走系统文件对话框。
Future<List<String>> _pickReferenceImages() async {
  final picked = await ImagePicker().pickMultiImage();
  return [for (final file in picked) file.path];
}

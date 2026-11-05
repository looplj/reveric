// 职责: 剧本导入前选择源文件并编辑交给 AI 的改编提示词。
// 关联文件:
//   lib/shared/widgets/quick_start_idea.dart
//   lib/shared/services/screenplay_import.dart
//   lib/desktop/pages/home.dart
//   lib/mobile/pages/library_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/file-access.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../components/reveric_text_field.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../services/screenplay_import.dart';
import '../../theme/theme.dart';
import '../quick_start_idea.dart';

const double _dialogMaxWidth = 480;

const screenplayImportDefaultPrompt = '帮我把这份文件改编为剧本。';

class ScreenplayImportRequest {
  const ScreenplayImportRequest({required this.source, required this.prompt});

  /// 已读入内存的原文，导入时整份存为资料供 AI 分段读取。
  final ScreenplaySource source;
  final String prompt;
}

Future<ScreenplayImportRequest?> showScreenplayImport(
  BuildContext context, {
  required bool mobile,
}) {
  final colors = RevericTheme.colorsOf(context);
  if (mobile) {
    return showModalBottomSheet<ScreenplayImportRequest>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: colors.surface,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.75,
            ),
            child: const SingleChildScrollView(
              child: _ImportForm(mobile: true),
            ),
          ),
        ),
      ),
    );
  }
  return showDialog<ScreenplayImportRequest>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _dialogMaxWidth),
        child: const SingleChildScrollView(child: _ImportForm(mobile: false)),
      ),
    ),
  );
}

class _ImportForm extends HookWidget {
  const _ImportForm({required this.mobile});

  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final controller = useTextEditingController(
      text: screenplayImportDefaultPrompt,
    );
    final file = useState<ScreenplaySource?>(null);
    final failure = useState<ScreenplaySourceFailure?>(null);
    final picking = useState(false);
    final submitted = useRef(false);
    final hasPrompt = useListenableSelector(
      controller,
      () => controller.text.trim().isNotEmpty,
    );
    final canSubmit = hasPrompt && file.value != null && !picking.value;

    void close() => Navigator.of(context).maybePop();

    Future<void> pick() async {
      picking.value = true;
      try {
        final picked = await pickScreenplaySource();
        if (!context.mounted || picked == null) {
          return;
        }
        file.value = picked;
        failure.value = null;
      } on ScreenplaySourceException catch (error) {
        if (!context.mounted) {
          return;
        }
        file.value = null;
        failure.value = error.failure;
      } finally {
        if (context.mounted) {
          picking.value = false;
        }
      }
    }

    void submit() {
      final picked = file.value;
      final prompt = controller.text.trim();
      if (picked == null || prompt.isEmpty || submitted.value) {
        return;
      }
      submitted.value = true;
      Navigator.of(
        context,
      ).pop(ScreenplayImportRequest(source: picked, prompt: prompt));
    }

    final error = failure.value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PromptDialogHeader(
          title: context.t(LocaleKeys.libraryImportScreenplay),
          subtitle: context.t(LocaleKeys.libraryImportScreenplayHelp),
          icon: RevericIcons.upload,
          onClose: close,
        ),
        Divider(
          height: RevericSizes.dividerThickness,
          color: colors.borderSubtle,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x3l,
            RevericSpacing.x3l,
            RevericSpacing.x3l,
            RevericSpacing.x2l,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                onPressed: picking.value ? null : pick,
                icon: const RevericIcon(RevericIcons.upload, size: 16),
                label: Text(
                  file.value?.fileName ??
                      context.t(LocaleKeys.commonSelectFile),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: RevericSpacing.sm),
                Text(
                  context.t(screenplaySourceFailureLocaleKey(error)),
                  style: typo.uiSmall.copyWith(color: colors.error),
                ),
              ],
              const SizedBox(height: RevericSpacing.lg),
              RevericTextField(
                controller: controller,
                multiline: true,
                minLines: 3,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
              ),
            ],
          ),
        ),
        Divider(
          height: RevericSizes.dividerThickness,
          color: colors.borderSubtle,
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            RevericSpacing.x3l,
            RevericSpacing.lg,
            RevericSpacing.x3l,
            // 移动端底部留出 home indicator 的空间。
            mobile ? RevericSpacing.x5l : RevericSpacing.x3l,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: close,
                child: Text(context.t(LocaleKeys.commonCancel)),
              ),
              const SizedBox(width: RevericSpacing.sm),
              FilledButton(
                onPressed: canSubmit ? submit : null,
                child: Text(context.t(LocaleKeys.commonImport)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// 职责: 在片段行内编辑提示词，并保护尚未保存的提示词输入。
// 关联文件:
//   lib/desktop/features/production/edit_session.dart
//   lib/shared/providers/storyboard.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/storyboard.dart';
import '../../../shared/services/storyboard/edit_orchestrator.dart';
import '../../../shared/theme/theme.dart';
import '../production/edit_session.dart';
import '../production/prompt_controller.dart';
import '../production/prompt_field.dart';

final _log = AppLogger.forModule('Storyboard');

class InlineShotEditor extends HookConsumerWidget {
  const InlineShotEditor({
    super.key,
    required this.path,
    required this.novelId,
    required this.shot,
    required this.session,
    required this.onProduce,
  });
  final String path;
  final String novelId;
  final ProductionClipRow shot;
  final ProductionEditSession session;
  final VoidCallback onProduce;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prompt = useMemoized(() => ProductionPromptController(shot.prompt), [
      shot.id,
    ]);
    final baseline = useRef(shot.prompt);
    final service = ref.watch(
      storyboardServiceProvider(path, novelId: novelId),
    );
    final overlay = ref.watch(
      workOverlayServiceProvider((path: path, novelId: novelId)),
    );
    useEffect(() => prompt.dispose, [prompt]);
    useEffect(() {
      if (prompt.source == baseline.value && baseline.value != shot.prompt) {
        prompt.text = prompt.encode(shot.prompt);
        baseline.value = shot.prompt;
      }
      return null;
    }, [shot.prompt]);
    prompt.inputIds = shot.inputs.map((input) => input.id).toSet();
    // 提示词自动保存：停手片刻后写入；离开前（切视图、点别的片段）先把没写完的立刻写掉。
    final pending = useRef<Timer?>(null);
    final writing = useRef<Future<bool>?>(null);
    Future<bool> save() async {
      pending.value?.cancel();
      while (writing.value != null) {
        await writing.value;
      }
      final source = prompt.source;
      if (source == baseline.value) {
        return true;
      }
      Future<bool> run() async {
        try {
          await StoryboardEditOrchestrator().save(
            service: service,
            overlay: overlay,
            shotId: shot.id,
            values: {'prompt': source},
          );
          baseline.value = source;
          return true;
        } catch (error, stack) {
          _log.error('Prompt autosave failed', error: error, stackTrace: stack);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.t(LocaleKeys.productionFailed))),
            );
          }
          return false;
        }
      }

      final task = run();
      writing.value = task;
      try {
        return await task;
      } finally {
        writing.value = null;
      }
    }

    useEffect(() {
      void schedule() {
        if (prompt.source == baseline.value) {
          return;
        }
        pending.value?.cancel();
        pending.value = Timer(const Duration(milliseconds: 600), save);
      }

      prompt.addListener(schedule);
      return () {
        prompt.removeListener(schedule);
        pending.value?.cancel();
      };
    }, [prompt]);

    Future<bool> leave() => save();

    session.guards[shot.id] = leave;
    useEffect(
      () => () {
        session.guards.remove(shot.id);
      },
      [session, shot.id],
    );
    return ProductionPromptField(
      controller: prompt,
      onReference: onProduce,
      maxLines: null,
      contentPadding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
    );
  }
}

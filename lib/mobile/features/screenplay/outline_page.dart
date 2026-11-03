// 职责: 移动端剧本大纲 — 编辑当前集大纲正文（Logline/Synopsis/Theme/Arcs），维护当前集的结构规划。
// 关联文件:
//   lib/mobile/features/screenplay/editor_page.dart
//   lib/shared/services/document_save_coordinator.dart
//   lib/shared/services/screenplay_outline_save.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/providers/screenplay_workspace_state_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart'
    show ScreenplayEpisodeRow;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/services/document_save_coordinator.dart';
import '../../../shared/services/screenplay_outline_save.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/md/reveric_markdown_editor.dart';
import 'support.dart';

class MobileScreenplayOutlinePage extends HookConsumerWidget {
  const MobileScreenplayOutlinePage({
    super.key,
    required this.novel,
    required this.registerFlush,
  });

  final Novel novel;

  /// 大纲编辑器挂载时交回它的落盘函数，宿主在切走前调用；卸载时传 null。
  final ValueChanged<Future<void> Function()?> registerFlush;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = novel.contentDatabasePath!;
    final provider = screenplayWorkspaceStateControllerProvider(novel.id, path);
    final workspace = ref.watch(provider);
    final episodeId = workspace.episodeId;

    // 没有选中集时编辑器不挂载，确保宿主拿不到过期的 flush。
    final registerFlushRef = useRef(registerFlush);
    registerFlushRef.value = registerFlush;
    useEffect(() {
      if (episodeId == null) {
        registerFlushRef.value(null);
      }
      return null;
    }, [episodeId]);

    if (episodeId == null) {
      return MobileScreenplayEmpty(
        icon: RevericIcons.edit_note_outlined,
        label: context.t(LocaleKeys.screenplayNoOutline),
      );
    }
    final episode = ref.watch(screenplayEpisodeProvider(path, episodeId)).value;
    if (episode == null) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(RevericSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MobileScreenplayCard(
            child: _MobileOutlineDocEditor(
              key: ValueKey(episode.id),
              novel: novel,
              episode: episode,
              registerFlush: registerFlush,
            ),
          ),
        ],
      ),
    );
  }
}

/// 当前集大纲正文的编辑区 —— debounce 自动保存，切集 / 切分区前由宿主 flush。
class _MobileOutlineDocEditor extends HookConsumerWidget {
  const _MobileOutlineDocEditor({
    super.key,
    required this.novel,
    required this.episode,
    required this.registerFlush,
  });

  final Novel novel;
  final ScreenplayEpisodeRow episode;
  final ValueChanged<Future<void> Function()?> registerFlush;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = novel.contentDatabasePath!;
    final overlay = ref.read(workingOverlayServiceProvider(path));
    final database = ref.read(novelContentDatabaseProvider(path));
    final controller = useTextEditingController(text: episode.outline);
    final focusNode = useFocusNode();
    final coordinator = useMemoized(
      // 走 overlay 而不是直接 updateEpisodeOutline：手动保存要进修改历史，
      // 并顺带提交同一集上仍待审阅的 AI 改动。列写入由 apply-on-stage 完成。
      () => DocumentSaveCoordinator<String>(
        save: (text) => commitEpisodeOutlineManualSave(
          overlay,
          database,
          episodeId: episode.id,
          newOutline: text,
        ),
      ),
      [episode.id],
    );
    // 卸载前把 debounce 里的尾巴写掉；正常切换由宿主的 flush 提前兜住。
    useEffect(() {
      return () {
        unawaited(coordinator.flush().onError((_, _) {}));
        coordinator.dispose();
      };
    }, [coordinator]);
    // 先更新基线，外部同步触发 controller listener 时才不会被当作手动输入。
    final outlineRef = useRef(episode.outline);
    outlineRef.value = episode.outline;
    // 本地有未落盘的编辑或正在组词时不接受外部值：AI 的写入落在 debounce 中间
    // 会盖掉正在输入的内容。用户这次保存会把 AI 那条改动一起提交进历史，
    // 不会丢。
    useEffect(() {
      if (coordinator.isDirty ||
          coordinator.isSaving ||
          controller.value.composing.isValid) {
        return null;
      }
      if (controller.text != episode.outline) {
        controller.text = episode.outline;
      }
      return null;
    }, [episode.id, episode.outline]);

    useOnListenableChange(controller, () {
      if (controller.text != outlineRef.value) {
        coordinator.schedule(controller.text);
      }
    });

    final registerFlushRef = useRef(registerFlush);
    registerFlushRef.value = registerFlush;
    useEffect(() {
      registerFlushRef.value(coordinator.flush);
      return () => registerFlushRef.value(null);
    }, [coordinator]);

    return RevericMarkdownEditor(
      controller: controller,
      focusNode: focusNode,
      hintText: context.t(LocaleKeys.screenplayOutlineHint),
      autoHeight: true,
      minHeight: 400,
    );
  }
}

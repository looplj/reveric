// 职责: 承载剧本和小说朗读的配置加载、音色设置与播放界面。
// 关联文件:
//   lib/desktop/features/narration/setup.dart
//   lib/desktop/features/narration/playback.dart
//   lib/shared/providers/narration.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/components/reveric_placeholder.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/narration.dart';
import '../../../shared/providers/narration.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/services/screenplay/narration_service.dart';
import '../../../shared/theme/theme.dart';
import 'playback.dart';
import 'setup.dart';

final _log = AppLogger.forModule('Narration');

Future<void> showNovelNarration(
  BuildContext context, {
  required String workId,
  required String databasePath,
  required String text,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  return showRevericDialog<void>(
    context: context,
    // 独立阅读窗口关闭时，其 Navigator 一并释放朗读会话。
    useRootNavigator: false,
    builder: (_) => UncontrolledProviderScope(
      container: container,
      child: NarrationDialog(
        workId: workId,
        source: NovelNarrationSource(text),
        novelDatabasePath: databasePath,
      ),
    ),
  );
}

class NarrationDialog extends HookConsumerWidget {
  const NarrationDialog({
    super.key,
    required this.workId,
    required this.source,
    this.novelDatabasePath,
  });
  final String workId;
  final NarrationInput source;
  final String? novelDatabasePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(narrationServiceProvider);
    final scope = source is NovelNarrationSource
        ? NarrationSettingsScope.novel
        : NarrationSettingsScope.screenplay;
    final path = novelDatabasePath;
    final characterProvider = path == null
        ? null
        : characterProfilesProvider(path);
    final profiles = characterProvider == null
        ? null
        : ref.watch(characterProvider.future);
    final revision = useState(0);
    final loaded = useFuture(
      useMemoized(() async {
        final settings = service.load(workId, scope: scope);
        final input = source;
        if (input is! NovelNarrationSource || profiles == null) {
          return (settings: await settings, source: input);
        }
        final (saved, characters) = await (settings, profiles).wait;
        return (
          settings: saved,
          source: NovelNarrationSource(
            input.text,
            characters: characters.map(
              (profile) => (
                id: profile.id,
                name: profile.name,
                aliases: profile.aliases,
              ),
            ),
          ),
        );
      }, [service, workId, scope, source, profiles, revision.value]),
    );
    final plan = useState<NarrationPlan?>(null);
    final settings = useRef<NarrationSettings?>(null);
    useEffect(() {
      if (loaded.hasError) {
        _log.error(
          'configuration load failed',
          error: loaded.error,
          stackTrace: loaded.stackTrace,
        );
      }
      return null;
    }, [loaded.error, loaded.stackTrace]);
    return RevericDialog.panel(
      width: RevericSizes.screenplayPageMaxWidth,
      title: Row(
        children: [
          Expanded(child: Text(context.t(LocaleKeys.narrationTitle))),
          RevericIconButton(
            icon: RevericIcons.close,
            tooltip: context.t(LocaleKeys.commonClose),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      content: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: loaded.hasError
            ? Center(
                child: RevericPlaceholder.error(
                  title: context.t(LocaleKeys.narrationFailed),
                  action: RevericButton.secondary(
                    label: context.t(LocaleKeys.commonRetry),
                    onPressed: () {
                      if (characterProvider != null) {
                        ref.invalidate(characterProvider);
                      }
                      revision.value++;
                    },
                  ),
                ),
              )
            : !loaded.hasData
            ? const Center(child: CircularProgressIndicator())
            : plan.value == null
            ? NarrationSetup(
                workId: workId,
                source: loaded.data!.source,
                scope: scope,
                initial: settings.value ?? loaded.data!.settings,
                onStart: (next) {
                  settings.value = next.settings;
                  plan.value = next;
                },
              )
            : NarrationPlayback(
                source: loaded.data!.source,
                plan: plan.value!,
                onBack: () => plan.value = null,
              ),
      ),
    );
  }
}

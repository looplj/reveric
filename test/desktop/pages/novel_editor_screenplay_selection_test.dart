// 职责: 验证桌面剧本选择同步及制片导航等待区域离开检查。
// 关联文件:
//   lib/desktop/pages/novel_editor.dart
//   lib/shared/providers/novel_workspace_state_provider.dart
//   lib/shared/providers/screenplay_workspace_state_provider.dart
//   lib/shared/services/screenplay_service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/state-management.md

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/pages/novel_editor.dart';
import 'package:reveric/desktop/widgets/workspace/novel_workspace_panel.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/novel_workspace.dart';
import 'package:reveric/shared/models/novel_workspace_state.dart';
import 'package:reveric/shared/models/screenplay_workspace_state.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/novel_workspace_state_provider.dart';
import 'package:reveric/shared/providers/screenplay_workspace_state_provider.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/ai/prompt_template.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/providers/workspace_navigation_provider.dart';
import 'package:reveric/shared/providers/production_media.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/widgets/screenplay/director_shell.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/novel_type.dart';

const _workId = 'screenplay-selection-test';
const _path = 'memory:desktop-screenplay-selection';

void main() {
  late Directory supportRoot;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    // 页头的深度任务按钮会读取应用目录，需要先初始化存储路径。
    supportRoot = await Directory.systemTemp.createTemp(
      'screenplay-selection-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => supportRoot.path,
        );
    await RevericPaths.initialize();
    await PromptTemplateService.loadAll();
    for (final font in {
      'LXGWWenKai': 'LXGWWenKai',
      'Georgia': 'LXGWWenKai',
      'Literata': 'Literata',
    }.entries) {
      await (FontLoader(
            font.key,
          )..addFont(rootBundle.load('assets/fonts/${font.value}-Regular.ttf')))
          .load();
    }
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await supportRoot.delete(recursive: true);
  });
  setUp(() => rootBundle.clear());

  for (final section in [
    NovelWorkspaceSection.screenplay_outline,
    NovelWorkspaceSection.screenplay_script,
    NovelWorkspaceSection.screenplay_scenes,
    NovelWorkspaceSection.storyboard,
  ]) {
    testWidgets(
      section == NovelWorkspaceSection.storyboard
          ? 'clip navigation requests preserve workspace until the registered leave guard succeeds'
          : '${section.name} keeps the new selection before and after rebuild',
      (tester) async {
        final appDb = AppDatabase.forTest(NativeDatabase.memory());
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        addTearDown(() async {
          await db.close();
          await appDb.close();
        });
        final service = ScreenplayService(db);
        final initial = await service.createInitialStructure();
        final root = (await db.screenplayDao.getRoot())!;
        final episodeB = await service.createEpisode(
          seasonId: initial.seasonId,
        );
        final sceneA = await service.createScene(
          screenplayId: root.id,
          episodeId: initial.episodeId,
        );
        final sceneB = await service.createScene(
          screenplayId: root.id,
          episodeId: initial.episodeId,
        );
        final isOutline = section == NovelWorkspaceSection.screenplay_outline;
        final isProduction = section == NovelWorkspaceSection.storyboard;
        String? oldClipId;
        String? newClipId;
        String? newClipScene;
        if (isProduction) {
          final clips = StoryboardService(db);
          oldClipId = (await clips.create(sceneA)).id;
          newClipScene = await service.createScene(
            screenplayId: root.id,
            episodeId: episodeB,
          );
          newClipId = (await clips.create(newClipScene)).id;
        }
        final initialState = ScreenplayWorkspaceState(
          section: isOutline
              ? ScreenplayWorkspaceSection.outline
              : section == NovelWorkspaceSection.screenplay_script
              ? ScreenplayWorkspaceSection.script
              : ScreenplayWorkspaceSection.scenes,
          seasonId: initial.seasonId,
          episodeId: initial.episodeId,
          sceneId: sceneA,
          isHydrated: true,
        );
        final oldItemId = isProduction
            ? oldClipId!
            : isOutline
            ? initial.episodeId
            : sceneA;
        final newItemId = isProduction
            ? newClipId!
            : isOutline
            ? episodeB
            : sceneB;
        await appDb.novelDao.create(
          id: _workId,
          title: 'Screenplay',
          description: '',
          contentKind: contentKindScreenplay,
          contentDatabasePath: _path,
          type: section == NovelWorkspaceSection.screenplay_script
              ? novelTypeAdaptation
              : null,
        );
        await appDb.appStateDao.set(
          key: screenplayWorkspaceAppStateKey(_workId),
          value: jsonEncode(initialState.toJson()),
        );
        await appDb.appStateDao.set(
          key: novelWorkspaceAppStateKey(_workId),
          value: jsonEncode(
            NovelWorkspaceStateData(
              selection: WorkspaceSelection(
                section: section,
                itemId: oldItemId,
              ),
              isHydrated: true,
            ).toJson(),
          ),
        );
        await tester.binding.setSurfaceSize(const Size(1800, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appDatabaseProvider.overrideWithValue(appDb),
              if (isProduction)
                mediaLibraryServiceProvider.overrideWithValue(
                  MediaLibraryService(
                    appDb,
                    MediaService(FfmpegRunner()),
                    Directory.systemTemp,
                  ),
                ),
              appSettingsDatabaseProvider.overrideWithValue(appDb),
              novelContentDatabaseProvider(_path).overrideWithValue(db),
            ],
            child: EasyLocalization(
              supportedLocales: const [Locale('zh', 'CN')],
              path: 'assets/translations',
              assetLoader: const MergingAssetLoader(),
              fallbackLocale: const Locale('zh', 'CN'),
              startLocale: const Locale('zh', 'CN'),
              child: Builder(
                builder: (context) => MaterialApp(
                  localizationsDelegates: context.localizationDelegates,
                  supportedLocales: context.supportedLocales,
                  locale: context.locale,
                  theme: RevericThemeData.reveric.toThemeData(),
                  builder: (context, child) => RevericTheme(
                    data: RevericThemeData.reveric,
                    child: child!,
                  ),
                  home: const NovelEditorPage(novelId: _workId),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NovelWorkspacePanel), findsOneWidget);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(NovelEditorPage)),
        );
        final workspaceProvider = novelWorkspaceStateControllerProvider(
          _workId,
        );
        final screenplayProvider = screenplayWorkspaceStateControllerProvider(
          _workId,
          _path,
        );
        if (isProduction) {
          final beforeWorkspace = container.read(screenplayProvider);
          final beforeSelection = container.read(workspaceProvider).selection;
          final beforeTarget = tester
              .widget<ScreenplayDirectorShell>(
                find.byType(ScreenplayDirectorShell),
              )
              .navigationTarget;
          var flushCalls = 0;
          Future<void> Function() guard = () async {};
          tester
              .widget<NovelWorkspacePanel>(find.byType(NovelWorkspacePanel))
              .onRegisterScreenplaySceneFlush!(() {
            flushCalls++;
            return guard();
          });
          void request() => container
              .read(workspaceNavigationProvider.notifier)
              .request(
                WorkspaceNavigationRequest(
                  section: NovelWorkspaceSection.storyboard,
                  itemId: newItemId,
                ),
              );
          void expectUnchanged() {
            expect(container.read(screenplayProvider), beforeWorkspace);
            expect(
              container.read(workspaceProvider).selection,
              beforeSelection,
            );
            expect(
              tester
                  .widget<ScreenplayDirectorShell>(
                    find.byType(ScreenplayDirectorShell),
                  )
                  .navigationTarget,
              beforeTarget,
            );
          }

          final cancelled = Completer<void>();
          guard = () => cancelled.future;
          request();
          await tester.pump();
          expect(flushCalls, 1);
          expectUnchanged();
          cancelled.completeError(StateError('Stay in the current editor'));
          await tester.pumpAndSettle();
          expectUnchanged();
          guard = () async {
            throw StateError('Save failed or export still active');
          };
          request();
          await tester.pumpAndSettle();
          expect(flushCalls, 2);
          expectUnchanged();
          final saved = Completer<void>();
          guard = () => saved.future;
          request();
          await tester.pump();
          expect(flushCalls, 3);
          expectUnchanged();
          saved.complete();
          await tester.pumpAndSettle();
          expect(container.read(screenplayProvider).episodeId, episodeB);
          expect(container.read(workspaceProvider).selection.itemId, newItemId);
          expect(
            tester
                .widget<ScreenplayDirectorShell>(
                  find.byType(ScreenplayDirectorShell),
                )
                .navigationTarget,
            // 制片页聚焦目标片段后，第二栏的场次跟随它所在的场。
            (episodeB, newClipScene, newItemId),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          return;
        }
        if (section == NovelWorkspaceSection.screenplay_script) {
          // 有原著时页头才提供「查看原著」入口。
          final viewSource = find.byTooltip(
            tr(LocaleKeys.screenplayViewSource),
          );
          expect(viewSource, findsNothing);
          await appDb.novelDao.create(
            id: 'screenplay-selection-source',
            title: 'Source',
            description: '',
            contentDatabasePath: 'memory:screenplay-selection-source',
          );
          await appDb.novelDao.updateSourceNovel(
            id: _workId,
            sourceNovelId: 'screenplay-selection-source',
          );
          await tester.pumpAndSettle();
          expect(viewSource, findsOneWidget);
        }
        (String?, String?) selections() {
          final screenplay = container.read(screenplayProvider);
          return (
            isOutline ? screenplay.episodeId : screenplay.sceneId,
            container.read(workspaceProvider).selection.itemId,
          );
        }

        expect(selections(), (oldItemId, oldItemId));
        final current = container.read(screenplayProvider);
        container
            .read(screenplayProvider.notifier)
            .update(
              isOutline
                  ? current.copyWith(episodeId: episodeB, clearSceneId: true)
                  : current.copyWith(sceneId: sceneB),
            );
        // Capture both states without yielding: the old build's listeners are
        // still installed until pump runs the next frame.
        final beforePump = selections();
        await tester.pump();
        final afterPump = selections();
        expect(beforePump, (newItemId, newItemId));
        expect(afterPump, (newItemId, newItemId));
        await tester.pumpAndSettle();
        expect(selections(), (newItemId, newItemId));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}

// 职责: 验证原声分离按钮的锁定、内容类型、持久化与单步撤销，以及文字锚点九宫格的定位提交。
// 关联文件:
//   lib/desktop/features/editing/inspector.dart
//   lib/shared/services/editing/session.dart
//   lib/shared/services/editing/commands.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
import 'dart:io';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/desktop/features/editing/controller.dart';
import 'package:reveric/desktop/features/editing/inspector.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/editing/document.dart';
import 'package:reveric/shared/services/editing/commands.dart';
import 'package:reveric/shared/services/editing/service.dart';
import 'package:reveric/shared/services/editing/session.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import '../../../shared/production/editing/commands_test.dart' show fixture;

class _InspectorProjects extends EditingService {
  _InspectorProjects(super.database, super.library);
  @override
  Future<void> verify(EditingDocument doc, MediaCancellation token) async {}
}

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    for (final locale in [const Locale('en'), const Locale('zh', 'CN')]) {
      testWidgets('detach locks, saves and undoes on $platform / $locale', (
        tester,
      ) async {
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        final app = AppDatabase.forTest(NativeDatabase.memory());
        final projects = _InspectorProjects(
          db,
          MediaLibraryService(
            app,
            MediaService(FfmpegRunner()),
            Directory.systemTemp,
          ),
        );
        final session = EditingSession(projects, 'editing');
        final controller = EditingController(session);
        try {
          final emptyDialogue = EditingCommands.removeTrack(fixture(), 'A1');
          final initial = emptyDialogue.copyWith(
            tracks: [
              for (final track in emptyDialogue.tracks)
                track.main ? track.copyWith(locked: true) : track,
            ],
          );
          await db.editingDao.create('editing', 'Test', initial);
          await session.load();
          session.select('m2');
          await tester.pumpWidget(
            EasyLocalization(
              supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
              path: 'assets/translations',
              assetLoader: const MergingAssetLoader(),
              startLocale: locale,
              fallbackLocale: const Locale('en'),
              saveLocale: false,
              child: Builder(
                builder: (context) => MaterialApp(
                  localizationsDelegates: context.localizationDelegates,
                  supportedLocales: context.supportedLocales,
                  locale: context.locale,
                  theme: RevericThemeData.reveric.toThemeData().copyWith(
                    platform: platform,
                  ),
                  home: RevericTheme(
                    data: RevericThemeData.reveric,
                    child: Scaffold(
                      body: Align(
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: 280,
                          child: ListenableBuilder(
                            listenable: session,
                            builder: (_, _) => EditingInspector(
                              controller: controller,
                              title: 'Test',
                              spec: '16:9',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final button = find.byKey(const ValueKey('editing-detach-audio'));
          expect(button, findsOneWidget);
          expect(tester.widget<RevericButton>(button).onPressed, isNull);
          expect(
            find.text(locale.languageCode == 'en' ? 'Detach audio' : '分离音频'),
            findsOneWidget,
          );
          final doc = session.document!;
          session.commit(
            EditingCommands.updateTrack(
              doc,
              doc.mainTrack.copyWith(locked: false),
            ),
          );
          await tester.pumpAndSettle();
          final before = session.document!.toJson();
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(button, findsNothing);
          final originalAudio = locale.languageCode == 'en'
              ? 'Original audio'
              : '原声';
          expect(find.text(originalAudio), findsNothing);
          expect(session.document!.tracks.length, initial.tracks.length + 1);
          expect(
            (session.document!.mainClips[1].content as EditingVideoContent)
                .audioDetached,
            true,
          );
          expect(
            (await db.editingDao.get('editing'))!.document.toJson(),
            session.document!.toJson(),
          );
          session.undo();
          await tester.pumpAndSettle();
          expect(session.document!.toJson(), before);
          expect(button, findsOneWidget);
          expect(find.text(originalAudio), findsOneWidget);
          session.redo();
          await tester.pumpAndSettle();
          expect(button, findsNothing);
          session.select(session.document!.clips.last.id);
          await tester.pumpAndSettle();
          expect(button, findsNothing);
          session.select('sub');
          await tester.pumpAndSettle();
          expect(button, findsNothing);
          final corner = find.byKey(const ValueKey('editing-anchor-2-0'));
          await tester.ensureVisible(corner);
          await tester.pumpAndSettle();
          await tester.tap(corner);
          await tester.pumpAndSettle();
          final text =
              session.document!.clips.singleWhere((c) => c.id == 'sub').content
                  as EditingTextContent;
          expect(text.transform.toJson(), {
            'scale': 1.0,
            'x': .94,
            'y': .09,
            'anchor_x': 1.0,
            'anchor_y': 0.0,
          });
          expect(
            (await db.editingDao.get('editing'))!.document.toJson(),
            session.document!.toJson(),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          controller.dispose();
          session.dispose();
          await tester.runAsync(() async {
            await db.close();
            await app.close();
          });
        }
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  }
}

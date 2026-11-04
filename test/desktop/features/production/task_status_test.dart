// 职责: 验证后台错误在画布和分镜表共同展示、关闭后跨挂载保留，以及重试后重新提醒。
// 关联文件:
//   lib/desktop/features/production/task_status.dart
//   lib/shared/services/storyboard/service.dart
//   lib/shared/services/production/image_service.dart
import 'package:reveric/shared/models/generation/task.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/production/task_status.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget wrap(Widget child) => EasyLocalization(
  supportedLocales: const [Locale('en')],
  path: 'assets/translations',
  assetLoader: const MergingAssetLoader(),
  startLocale: const Locale('en'),
  fallbackLocale: const Locale('en'),
  child: Builder(
    builder: (context) => MaterialApp(
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: RevericThemeData.reveric.toThemeData(),
      home: RevericTheme(
        data: RevericThemeData.reveric,
        child: Scaffold(body: child),
      ),
    ),
  ),
);

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  testWidgets(
    'adopted sample stays marked while its final generates and follows result switching',
    (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final appDb = app.AppDatabase.forTest(NativeDatabase.memory());
      final shots = StoryboardService(db);
      final episode = (await ScreenplayService(
        db,
      ).createInitialStructure()).episodeId;
      final clip = await shots.createVideo(episode);
      Future<void> adopt(String assetId) =>
          (db.update(
            db.productionClips,
          )..where((t) => t.id.equals(clip.id))).write(
            ProductionClipsCompanion(
              adoptedAssetId: Value(assetId),
              lastAppliedGenerationTaskId: const Value('hd'),
            ),
          );
      await adopt('draft-asset');
      for (final id in ['draft', 'hd']) {
        await appDb
            .into(appDb.generationTasks)
            .insert(
              app.GenerationTasksCompanion.insert(
                id: id,
                novelId: 'work',
                sourceType: 'production_clip',
                sourceId: clip.id,
                providerId: 'p',
                providerType: 'atlascloud',
                modelId: 'bytedance/seedance-2.5',
                kind: GenerationKind.video,
                status: id == 'draft'
                    ? GenerationTaskStatus.completed
                    : GenerationTaskStatus.running,
                draft: Value(id == 'draft'),
                draftTaskId: Value(id == 'hd' ? 'draft' : null),
                resultAssetId: Value(id == 'draft' ? 'draft-asset' : null),
                requestJson: VideoGenerationRequest(
                  VideoRequest(
                    modelId: 'bytedance/seedance-2.5',
                    prompt: 'bird',
                    mode: VideoMode.text,
                    resolution: id == 'draft' ? '480p' : '1080p',
                    ratio: '16:9',
                  ),
                ),
              ),
            );
      }
      await tester.pumpWidget(
        wrap(
          Column(
            children: [
              for (final floating in [false, true])
                ProductionTaskStatus(
                  shots: shots,
                  database: appDb,
                  novelId: 'work',
                  clipId: clip.id,
                  floating: floating,
                ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sample · 480P'), findsNWidgets(2));
      expect(find.text('Final in progress'), findsNWidgets(2));
      await (appDb.update(
        appDb.generationTasks,
      )..where((t) => t.id.equals('hd'))).write(
        const app.GenerationTasksCompanion(
          status: Value(GenerationTaskStatus.completed),
          resultAssetId: Value('hd-asset'),
        ),
      );
      await adopt('hd-asset');
      await tester.pumpAndSettle();
      expect(find.text('Sample · 480P'), findsNothing);
      expect(find.text('Final in progress'), findsNothing);
      await adopt('draft-asset');
      await tester.pumpAndSettle();
      expect(find.text('Sample · 480P'), findsNWidgets(2));
      await adopt('imported-asset');
      await tester.pumpAndSettle();
      expect(find.text('Sample · 480P'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await appDb.close();
      await db.close();
    },
  );

  testWidgets('every in-flight stage reads as generating', (tester) async {
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    final appDb = app.AppDatabase.forTest(NativeDatabase.memory());
    final shots = StoryboardService(db);
    final episode = (await ScreenplayService(
      db,
    ).createInitialStructure()).episodeId;
    final clip = await shots.createVideo(episode);
    await appDb
        .into(appDb.generationTasks)
        .insert(
          app.GenerationTasksCompanion.insert(
            id: 'task',
            novelId: 'work',
            sourceType: 'production_clip',
            sourceId: clip.id,
            providerId: 'p',
            providerType: 'doubao',
            modelId: 'm',
            kind: GenerationKind.video,
            status: GenerationTaskStatus.uploading,
            requestJson: VideoGenerationRequest(
              const VideoRequest(
                modelId: 'm',
                prompt: 'prompt',
                mode: VideoMode.text,
                resolution: '720p',
                ratio: '9:16',
              ),
              inputs: [],
            ),
          ),
        );
    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            for (final floating in [false, true])
              ProductionTaskStatus(
                shots: shots,
                database: appDb,
                novelId: 'work',
                clipId: clip.id,
                floating: floating,
              ),
          ],
        ),
      ),
    );
    for (final status in [
      GenerationTaskStatus.uploading,
      GenerationTaskStatus.submitting,
      GenerationTaskStatus.running,
      GenerationTaskStatus.saving,
    ]) {
      await (appDb.update(appDb.generationTasks)
            ..where((t) => t.id.equals('task')))
          .write(app.GenerationTasksCompanion(status: Value(status)));
      await tester.pumpAndSettle();
      expect(find.text('Generating'), findsNWidgets(2), reason: status.name);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await appDb.close();
    await db.close();
  });

  for (final kind in ['image', 'video']) {
    testWidgets(
      '$kind error dismissal survives revisiting and background updates',
      (tester) async {
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        final appDb = app.AppDatabase.forTest(NativeDatabase.memory());
        final service = StoryboardService(db);
        final episode = (await ScreenplayService(
          db,
        ).createInitialStructure()).episodeId;
        final clip = kind == 'image'
            ? await service.createImage(episode)
            : await service.createVideo(episode);
        await db
            .update(db.productionClips)
            .write(
              const ProductionClipsCompanion(
                adoptedAssetId: Value('adopted-result'),
              ),
            );
        if (kind == 'image') {
          await appDb
              .into(appDb.generationTasks)
              .insert(
                app.GenerationTasksCompanion.insert(
                  id: 'task',
                  status: GenerationTaskStatus.values.byName('failed'),
                  errorCode: const Value('generation_failed'),
                  kind: GenerationKind.image,
                  novelId: 'work',
                  sourceType: 'production_clip',
                  sourceId: clip.id,
                  requestJson: ImageGenerationRequest(
                    ProductionImageRequest(
                      providerId: 'p',
                      modelId: 'm',
                      originalPrompt: 'prompt',
                      prompt: 'prompt',
                      ratio: '1:1',
                      resolution: '1K',
                      size: null,
                    ),
                  ),
                  providerId: 'p',
                  providerType: 'openai',
                  modelId: 'm',
                ),
              );
        } else {
          await appDb
              .into(appDb.generationTasks)
              .insert(
                app.GenerationTasksCompanion.insert(
                  id: 'task',
                  novelId: 'work',
                  sourceType: 'production_clip',
                  sourceId: clip.id,
                  providerId: 'p',
                  providerType: 'doubao',
                  modelId: 'm',
                  status: GenerationTaskStatus.failed,
                  errorCode: const Value('rejected'),
                  requestJson: VideoGenerationRequest(
                    const VideoRequest(
                      modelId: 'm',
                      prompt: 'prompt',
                      mode: VideoMode.text,
                      resolution: '720p',
                      ratio: '9:16',
                    ),
                    inputs: [],
                  ),
                  kind: GenerationKind.video,
                ),
              );
        }
        Widget feedback() => wrap(
          Column(
            children: [
              for (final compact in [false, true])
                ProductionTaskStatus(
                  shots: service,
                  database: appDb,
                  novelId: 'work',
                  clipId: clip.id,
                  compact: compact,
                ),
            ],
          ),
        );
        await tester.pumpWidget(feedback());
        await tester.pumpAndSettle();
        expect(find.text('Adopted'), findsNWidgets(2));
        expect(find.text('Generation failed'), findsNWidgets(2));
        await tester.tap(
          find.byTooltip('Dismiss · this run stays in Results').first,
        );
        await tester.pumpAndSettle();
        expect(find.text('Generation failed'), findsNothing);
        expect((await service.getShot(clip.id))!.errorDismissed, isTrue);
        expect(
          (await service.getShot(clip.id))!.adoptedAssetId,
          'adopted-result',
        );
        // Replaying the same failure only changes the task, not its dismissed feedback.
        if (kind == 'image') {
          await appDb
              .update(appDb.generationTasks)
              .write(
                app.GenerationTasksCompanion(updatedAt: Value(DateTime.now())),
              );
          expect(
            (await appDb.select(appDb.generationTasks).getSingle()).status.name,
            'failed',
          );
        } else {
          await appDb.generationTaskDao.transition(
            'task',
            {GenerationTaskStatus.failed},
            const app.GenerationTasksCompanion(
              status: Value(GenerationTaskStatus.failed),
            ),
          );
          expect(
            (await appDb.generationTaskDao.getById('task'))!.status,
            GenerationTaskStatus.failed,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        rootBundle.clear();
        await tester.pumpWidget(feedback());
        await tester.pumpAndSettle();
        expect(find.text('Generation failed'), findsNothing);
        expect(find.text('Adopted'), findsNWidgets(2));
        // The explicit retry path resets the flag before executing the same task again.
        await service.setErrorDismissed(clip.id, false);
        await tester.pumpAndSettle();
        expect(find.text('Generation failed'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        await appDb.close();
      },
    );
  }

  // 生成失败打开「结果」看原因；结果已生成只差保存时只重新保存，不重新提交。
  for (final (kind, status, errorCode, label, action) in [
    ('audio', 'action_required', 'unavailable', 'Action required', 'See why'),
    (
      'audio',
      'action_required',
      'result_save_failed',
      'Could not save result',
      'Save again',
    ),
    ('image', 'failed', 'generation_failed', 'Generation failed', 'See why'),
    (
      'image',
      'action_required',
      'result_save_failed',
      'Could not save result',
      'Save again',
    ),
    ('video', 'failed', 'rejected', 'Generation failed', 'See why'),
    (
      'video',
      'action_required',
      'authentication',
      'Action required',
      'See why',
    ),
    (
      'video',
      'action_required',
      'asset_registration_failed',
      'Could not save result',
      'Save again',
    ),
    (
      'video',
      'saving',
      'download_failed',
      'Could not save result',
      'Save again',
    ),
  ]) {
    testWidgets('$kind $status offers "$action"', (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final appDb = app.AppDatabase.forTest(NativeDatabase.memory());
      final service = StoryboardService(db);
      final episode = (await ScreenplayService(
        db,
      ).createInitialStructure()).episodeId;
      final clip = switch (kind) {
        'audio' => await service.createAudio(episode),
        'image' => await service.createImage(episode),
        _ => await service.createVideo(episode),
      };
      if (kind == 'audio') {
        await appDb
            .into(appDb.generationTasks)
            .insert(
              app.GenerationTasksCompanion.insert(
                id: 'task',
                kind: GenerationKind.audio,
                novelId: 'work',
                sourceType: 'production_clip',
                sourceId: clip.id,
                providerId: 'p',
                providerType: 'atlascloud',
                modelId: 'bytedance/seed-audio-1.0',
                providerTaskId: const Value('prediction'),
                status: GenerationTaskStatus.action_required,
                errorCode: Value(errorCode),
                outputUrl: Value(
                  errorCode == 'result_save_failed'
                      ? 'https://cdn.example/audio.wav'
                      : null,
                ),
                requestJson: AudioGenerationRequest(
                  AudioRequest(
                    providerId: 'p',
                    modelId: 'bytedance/seed-audio-1.0',
                    prompt: 'Hello',
                    originalPrompt: 'Hello',
                  ),
                ),
              ),
            );
      } else if (kind == 'image') {
        await appDb
            .into(appDb.generationTasks)
            .insert(
              app.GenerationTasksCompanion.insert(
                id: 'task',
                status: GenerationTaskStatus.values.byName(status),
                errorCode: Value(errorCode),
                kind: GenerationKind.image,
                novelId: 'work',
                sourceType: 'production_clip',
                sourceId: clip.id,
                requestJson: ImageGenerationRequest(
                  ProductionImageRequest(
                    providerId: 'p',
                    modelId: 'm',
                    originalPrompt: 'prompt',
                    prompt: 'prompt',
                    ratio: '1:1',
                    resolution: '1K',
                    size: null,
                  ),
                ),
                providerId: 'p',
                providerType: 'openai',
                modelId: 'm',
              ),
            );
      } else {
        await appDb
            .into(appDb.generationTasks)
            .insert(
              app.GenerationTasksCompanion.insert(
                id: 'task',
                novelId: 'work',
                sourceType: 'production_clip',
                sourceId: clip.id,
                providerId: 'p',
                providerType: 'doubao',
                modelId: 'm',
                status: GenerationTaskStatus.values.byName(status),
                errorCode: Value(errorCode),
                requestJson: VideoGenerationRequest(
                  const VideoRequest(
                    modelId: 'm',
                    prompt: 'prompt',
                    mode: VideoMode.text,
                    resolution: '720p',
                    ratio: '9:16',
                  ),
                  inputs: [],
                ),
                kind: GenerationKind.video,
              ),
            );
      }
      final opened = <String>[];
      final retried = <ProductionSaveRetry>[];
      await tester.pumpWidget(
        wrap(
          ProductionTaskStatus(
            shots: service,
            database: appDb,
            novelId: 'work',
            clipId: clip.id,
            compact: true,
            actions: ProductionTaskActions(
              openResults: (id) async => opened.add(id),
              retrySave: (task) async => retried.add(task),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      if (action == 'See why') {
        expect(opened, [clip.id]);
        expect(retried, isEmpty);
      } else {
        expect(opened, isEmpty);
        expect(retried, [
          (taskId: 'task', status: status, image: kind != 'video'),
        ]);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.close();
      await appDb.close();
    });
  }
}

// 职责: 验证文本输入、删除及撤销的事务边界、提示词展开和生成请求快照隔离。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/generate_orchestrator.dart
//   lib/shared/services/production/image_generate_orchestrator.dart
//   lib/shared/services/production/audio_generate_orchestrator.dart
import 'dart:io';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/storyboard/prompt.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/ai/video/task_service.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/object_storage/service.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/canvas_history.dart';
import 'package:reveric/shared/services/production/generate_orchestrator.dart';
import 'package:reveric/shared/services/production/image_generate_orchestrator.dart';
import 'package:reveric/shared/services/production/audio_generate_orchestrator.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';

void main() {
  for (final kind in [contentKindScreenplay, contentKindCanvas]) {
    group('text inputs in $kind', () {
      late NovelContentDatabase db;
      late app.AppDatabase main;
      late ProductionCanvasService canvas;
      late String canvasId, episodeId;
      setUp(() async {
        db = NovelContentDatabase.forTest(NativeDatabase.memory());
        main = app.AppDatabase.forTest(NativeDatabase.memory());
        if (kind == contentKindCanvas) {
          await ScreenplayService(db).createCanvasStructure();
          episodeId = '';
        } else {
          episodeId = (await ScreenplayService(
            db,
          ).createInitialStructure()).episodeId;
        }
        canvas = ProductionCanvasService(
          StoryboardService(db, contentKind: kind),
          MediaLibraryService(
            main,
            MediaService(FfmpegRunner()),
            Directory.systemTemp,
          ),
          'work',
        );
        canvasId = (await canvas.ensureCanvas(episodeId)).id;
        for (final p in [
          ('video', 'doubao', 'doubao-seedance-2-0-260128'),
          ('image', 'openai', 'gpt-image-2'),
          ('audio', 'volcengine', 'seed-audio-1.0'),
        ]) {
          await main
              .into(main.aiProviders)
              .insert(
                app.AiProvidersCompanion.insert(
                  id: p.$1,
                  name: p.$1,
                  type: p.$2,
                  enabled: const Value(true),
                  apiKey: const Value('test'),
                  videoModels: Value(p.$1 == 'video' ? [p.$3] : const []),
                  imageModels: Value(p.$1 == 'image' ? [p.$3] : const []),
                  audioModels: Value(p.$1 == 'audio' ? [p.$3] : const []),
                ),
              );
        }
      });
      tearDown(() async {
        await db.close();
        await main.close();
      });

      test(
        'text is stored as node content and one edit reverses as one step',
        () async {
          final history = CanvasHistory(canvas.shots, canvasId);
          addTearDown(history.dispose);
          final text = await canvas.addText(
            canvasId,
            title: 'Note',
            content: 'Initial',
            history: history,
          );
          expect(text.refType, isNull);
          expect(text.refId, isNull);
          expect(text.content, 'Initial');
          await canvas.updateText(
            text.id,
            title: 'Style',
            content: 'Changed',
            history: history,
          );
          expect(history.undoCount, 2);
          await history.undo();
          expect((await canvas.requireNode(text.id)).content, 'Initial');
          await history.redo();
          expect((await canvas.requireNode(text.id)).content, 'Changed');
          final input = ProductionInput.text(text.id);
          expect(ProductionInput.fromJson(input.toJson()).roleName, 'prompt');
          expect(await canvas.inputName(input), 'Style');
          expect(() => input.role, throwsStateError);
          expect(
            () => ProductionInput.fromJson({
              ...input.toJson(),
              'ref_type': 'asset',
            }),
            throwsFormatException,
          );
        },
      );

      test(
        'text deletion cleans only its ordered inputs and repeated tags, undo/redo restores them',
        () async {
          final a = await canvas.addText(canvasId, content: 'A');
          final b = await canvas.addText(canvasId, content: 'B');
          final source = await canvas.addImage(canvasId);
          final target = await canvas.addImage(canvasId);
          final inputA = ProductionInput.text(a.id);
          final inputB = ProductionInput.text(b.id);
          final media = ProductionInput.node(
            source.id,
            VideoInputRole.reference_image,
          );
          final original =
              '  Lead\n${StoryboardPrompt.reference(inputA.id, 'A')} + ${StoryboardPrompt.reference(inputB.id, 'B')} / ${StoryboardPrompt.reference(inputA.id, 'Again')} ${StoryboardPrompt.reference(media.id, 'Picture')} tail  ';
          await canvas.shots.restoreInputs(
            target.clipId!,
            [inputB, inputA, media].map((input) => input.toJson()).toList(),
          );
          await (db.update(
            db.productionClips,
          )..where((t) => t.id.equals(target.clipId!))).write(
            ProductionClipsCompanion(
              prompt: Value(original),
              modelId: const Value('untouched-model'),
              providerId: const Value('untouched-provider'),
            ),
          );
          final history = CanvasHistory(canvas.shots, canvasId);
          addTearDown(history.dispose);
          await canvas.removeNode(a.id, history: history);
          final removed = await canvas.shots.getShot(target.clipId!);
          final cleaned =
              '  Lead\n + ${StoryboardPrompt.reference(inputB.id, 'B')} /  ${StoryboardPrompt.reference(media.id, 'Picture')} tail  ';
          expect(removed!.prompt, cleaned);
          expect(removed.inputs.map((input) => input.id), [
            inputB.id,
            media.id,
          ]);
          expect(removed.modelId, 'untouched-model');
          expect(removed.providerId, 'untouched-provider');
          expect(
            (await canvas.content(
              canvasId,
            )).edges.where((edge) => edge.sourceNodeId == a.id),
            isEmpty,
          );
          for (var i = 0; i < 2; i++) {
            await history.undo();
            expect((await canvas.requireNode(a.id)).content, 'A');
            final restored = (await canvas.shots.getShot(target.clipId!))!;
            expect(restored.prompt, original);
            expect(restored.inputs.map((input) => input.id), [
              inputB.id,
              inputA.id,
              media.id,
            ]);
            expect(restored.modelId, 'untouched-model');
            expect(
              (await canvas.content(
                canvasId,
              )).edges.where((edge) => edge.sourceNodeId == a.id),
              hasLength(1),
            );
            await history.redo();
            expect(await db.canvasDao.getNodeById(a.id), isNull);
            expect(
              (await canvas.shots.getShot(target.clipId!))!.prompt,
              cleaned,
            );
          }
        },
      );

      for (final restore in ['undo', 'redo']) {
        test(
          'newer prompt edits reject deletion $restore without losing those edits',
          () async {
            final text = await canvas.addText(canvasId);
            final target = await canvas.addAudio(canvasId);
            final input = ProductionInput.text(text.id);
            await canvas.shots.restoreInputs(target.clipId!, [input.toJson()]);
            await (db.update(
              db.productionClips,
            )..where((t) => t.id.equals(target.clipId!))).write(
              ProductionClipsCompanion(
                prompt: Value(
                  'Before ${StoryboardPrompt.reference(input.id, 'Note')} after',
                ),
              ),
            );
            final history = CanvasHistory(canvas.shots, canvasId);
            addTearDown(history.dispose);
            await canvas.removeNode(text.id, history: history);
            if (restore == 'redo') {
              await history.undo();
            }
            await (db.update(
              db.productionClips,
            )..where((t) => t.id.equals(target.clipId!))).write(
              const ProductionClipsCompanion(prompt: Value('New AI prompt')),
            );
            await expectLater(
              restore == 'undo' ? history.undo() : history.redo(),
              throwsA(isA<CanvasHistoryConflict>()),
            );
            expect(
              (await canvas.shots.getShot(target.clipId!))!.prompt,
              'New AI prompt',
            );
            expect(
              (await canvas.shots.getShot(target.clipId!))!.inputs,
              restore == 'undo' ? isEmpty : hasLength(1),
            );
            expect(
              await db.canvasDao.getNodeById(text.id),
              restore == 'undo' ? isNull : isNotNull,
            );
          },
        );
      }

      test(
        'untagged text input deletion preserves prompt bytes and restores the input',
        () async {
          final text = await canvas.addText(canvasId);
          final target = await canvas.addImage(canvasId);
          final input = ProductionInput.text(text.id);
          const prompt = '  Existing prompt\nwithout a ref tag  ';
          await canvas.shots.restoreInputs(target.clipId!, [input.toJson()]);
          await (db.update(db.productionClips)
                ..where((t) => t.id.equals(target.clipId!)))
              .write(const ProductionClipsCompanion(prompt: Value(prompt)));
          final history = CanvasHistory(canvas.shots, canvasId);
          addTearDown(history.dispose);
          await canvas.removeNode(text.id, history: history);
          expect((await canvas.shots.getShot(target.clipId!))!.prompt, prompt);
          expect((await canvas.shots.getShot(target.clipId!))!.inputs, isEmpty);
          await history.undo();
          expect((await canvas.shots.getShot(target.clipId!))!.prompt, prompt);
          expect(
            (await canvas.shots.getShot(target.clipId!))!.inputs.single.id,
            input.id,
          );
        },
      );

      test(
        'removing a canvas clears deleted text references from retained clips',
        () async {
          final text = await canvas.addText(canvasId);
          final target = await canvas.addImage(canvasId);
          final input = ProductionInput.text(text.id);
          await canvas.shots.restoreInputs(target.clipId!, [input.toJson()]);
          await (db.update(
            db.productionClips,
          )..where((t) => t.id.equals(target.clipId!))).write(
            ProductionClipsCompanion(
              prompt: Value(
                'Prefix ${StoryboardPrompt.reference(input.id, 'Note')} suffix',
              ),
            ),
          );
          await canvas.removeCanvas(canvasId);
          final clip = (await canvas.shots.getShot(target.clipId!))!;
          expect(clip.inputs, isEmpty);
          expect(clip.prompt, 'Prefix  suffix');
          expect(await db.canvasDao.getNodeById(text.id), isNull);
          expect(await db.canvasDao.getCanvasById(canvasId), isNull);
        },
      );

      test(
        'text delete failure rolls back downstream prompt and inputs with the node',
        () async {
          final text = await canvas.addText(canvasId);
          final target = await canvas.addImage(canvasId);
          final input = ProductionInput.text(text.id);
          final prompt =
              'Prefix ${StoryboardPrompt.reference(input.id, 'Text')} suffix';
          await canvas.shots.restoreInputs(target.clipId!, [input.toJson()]);
          await (db.update(db.productionClips)
                ..where((t) => t.id.equals(target.clipId!)))
              .write(ProductionClipsCompanion(prompt: Value(prompt)));
          final history = CanvasHistory(canvas.shots, canvasId);
          addTearDown(history.dispose);
          await expectLater(
            db.runWithInterceptor(
              () => canvas.removeNode(text.id, history: history),
              interceptor: _RejectTextNodeDelete(),
            ),
            throwsStateError,
          );
          expect((await canvas.shots.getShot(target.clipId!))!.prompt, prompt);
          expect(
            (await canvas.shots.getShot(target.clipId!))!.inputs.single.id,
            input.id,
          );
          expect(await db.canvasDao.getNodeById(text.id), isNotNull);
          expect(history.canUndo, false);
        },
      );

      test(
        'batch text and group deletion restores external references and members together',
        () async {
          final a = await canvas.addText(canvasId);
          final b = await canvas.addText(canvasId);
          final member = await canvas.addImage(canvasId);
          final group = await canvas.createStoryboardGroup(
            canvasId,
            layout: const StoryboardGroupLayout(cols: 2, rows: 2),
            origin: Offset.zero,
            memberIds: [member.id],
          );
          final target = await canvas.addImage(canvasId);
          final inputs = [
            ProductionInput.text(a.id),
            ProductionInput.text(b.id),
          ];
          final prompt = inputs
              .map((input) => StoryboardPrompt.reference(input.id, 'Note'))
              .join(' | ');
          await canvas.shots.restoreInputs(
            target.clipId!,
            inputs.map((input) => input.toJson()).toList(),
          );
          await (db.update(db.productionClips)
                ..where((t) => t.id.equals(target.clipId!)))
              .write(ProductionClipsCompanion(prompt: Value(prompt)));
          final history = CanvasHistory(canvas.shots, canvasId);
          addTearDown(history.dispose);
          await canvas.removeNodes(canvasId, {
            group.id,
            member.id,
            a.id,
            b.id,
          }, history: history);
          expect((await canvas.shots.getShot(target.clipId!))!.prompt, ' | ');
          expect((await canvas.shots.getShot(target.clipId!))!.inputs, isEmpty);
          await history.undo();
          expect((await canvas.requireNode(member.id)).parentId, group.id);
          expect((await canvas.shots.getShot(target.clipId!))!.prompt, prompt);
          expect(
            (await canvas.shots.getShot(
              target.clipId!,
            ))!.inputs.map((input) => input.id),
            inputs.map((input) => input.id),
          );
          await history.redo();
          expect(await db.canvasDao.getNodeById(member.id), isNull);
          expect((await canvas.shots.getShot(target.clipId!))!.prompt, ' | ');
        },
      );

      test(
        'history rejects mixing normal prompt writes into text cleanup',
        () async {
          final text = await canvas.addText(canvasId);
          final target = await canvas.addImage(canvasId);
          final input = ProductionInput.text(text.id);
          final prompt = StoryboardPrompt.reference(input.id, 'Note');
          await canvas.shots.restoreInputs(target.clipId!, [input.toJson()]);
          await (db.update(db.productionClips)
                ..where((t) => t.id.equals(target.clipId!)))
              .write(ProductionClipsCompanion(prompt: Value(prompt)));
          final history = CanvasHistory(canvas.shots, canvasId);
          addTearDown(history.dispose);
          await expectLater(
            history.record(
              'mixed',
              nodeIds: [text.id],
              action: () async {
                await canvas.removeNode(text.id);
                await (db.update(
                  db.productionClips,
                )..where((t) => t.id.equals(target.clipId!))).write(
                  const ProductionClipsCompanion(
                    prompt: Value('Unrelated rewrite'),
                  ),
                );
              },
            ),
            throwsStateError,
          );
          expect((await canvas.shots.getShot(target.clipId!))!.prompt, prompt);
          expect(await db.canvasDao.getNodeById(text.id), isNotNull);
          expect(history.canUndo, false);
        },
      );

      test(
        'three request snapshots expand tags and exclude every text input from media',
        () async {
          final a = await canvas.addText(
            canvasId,
            title: 'Actor',
            content: 'A literal <ref is not a nested input>',
          );
          final b = await canvas.addText(
            canvasId,
            title: 'Style',
            content: 'B style',
          );
          final empty = await canvas.addText(canvasId);
          final c = await canvas.addText(
            canvasId,
            title: 'Scene',
            content: 'C scene',
          );
          final inputs = [
            ProductionInput.text(b.id),
            ProductionInput.text(a.id),
            ProductionInput.text(empty.id),
            ProductionInput.text(c.id),
          ];
          final source =
              'Lead ${StoryboardPrompt.reference(inputs[1].id, 'Actor')} + ${StoryboardPrompt.reference(inputs[1].id, 'Actor')} ${StoryboardPrompt.reference(inputs[2].id, 'Empty')} tail';
          const expected =
              'B style\nC scene\nLead A literal <ref is not a nested input> + A literal <ref is not a nested input>  tail';
          for (final type in ['video', 'image', 'audio']) {
            final clip = switch (type) {
              'video' => await canvas.shots.createVideo(
                episodeId,
                values: {'duration_ms': 6000},
              ),
              'image' => await canvas.shots.createImage(episodeId),
              _ => await canvas.shots.createAudio(episodeId),
            };
            final node = await canvas.shots.ensureClipNode(clip.id);
            final model = switch (type) {
              'video' => 'doubao-seedance-2-0-260128',
              'image' => 'gpt-image-2',
              _ => 'seed-audio-1.0',
            };
            await canvas.shots.apply(clip.id, {
              ...canvas.shots.snapshot(clip),
              'prompt': source,
              'provider_id': type,
              'model_id': model,
              if (type == 'image') 'resolution': '2K',
            });
            await canvas.shots.restoreInputs(
              clip.id,
              inputs.map((i) => i.toJson()).toList(),
            );
            if (type == 'video') {
              final snapshot = await ProductionGenerateOrchestrator().preview(
                canvas,
                node.id,
              );
              expect(snapshot.request.prompt, expected);
              expect(snapshot.request.originalPrompt, expected);
              expect(snapshot.inputs, isEmpty);
              final jobs = VideoTaskService(
                database: main,
                rootDirectory: Directory.systemTemp,
                references: ReferenceStorageService(
                  database: main,
                  storage: ObjectStorageService(database: main),
                  probe: (_) =>
                      throw StateError('Text cannot require reference probing'),
                ),
                probeResult: (_) =>
                    throw StateError('No network generation expected'),
              );
              addTearDown(jobs.shutdown);
              final taskId = await jobs.create(
                providerId: snapshot.providerId,
                novelId: 'work',
                sourceType: snapshot.sourceType,
                sourceId: snapshot.sourceId,
                request: snapshot.request,
                inputs: snapshot.inputs,
              );
              await canvas.updateText(
                a.id,
                title: 'Actor',
                content: 'new content',
              );
              expect(snapshot.request.prompt, expected);
              final stored = (await jobs.getTask(taskId))!;
              expect(stored.videoRequest.prompt, expected);
              expect(stored.videoInputs, isEmpty);
              expect(
                (await ProductionGenerateOrchestrator().preview(
                  canvas,
                  node.id,
                )).request.prompt,
                contains('new content'),
              );
              await canvas.updateText(
                a.id,
                title: 'Actor',
                content: 'A literal <ref is not a nested input>',
              );
            } else if (type == 'image') {
              final snapshot = await ProductionImageGenerateOrchestrator()
                  .preview(canvas, node.id);
              expect(snapshot.request.prompt, expected);
              expect(snapshot.request.references, isEmpty);
              expect(snapshot.request.originalPrompt, expected);
            } else {
              final snapshot = await ProductionAudioGenerateOrchestrator()
                  .preview(canvas, node.id);
              expect(snapshot.request.prompt, expected);
              expect(snapshot.request.references, isEmpty);
              expect(snapshot.request.originalPrompt, expected);
            }
          }
        },
      );

      test(
        'unreferenced text alone is a prompt and does not use image quota',
        () async {
          final node = await canvas.addImage(canvasId);
          final clip = (await canvas.shots.getShot(node.clipId!))!;
          final text = [
            for (var i = 0; i < 20; i++)
              await canvas.addText(canvasId, content: 'Line $i'),
          ];
          await canvas.shots.apply(clip.id, {
            ...canvas.shots.snapshot(clip),
            'provider_id': 'image',
            'model_id': 'gpt-image-2',
            'resolution': '2K',
          });
          await canvas.shots.restoreInputs(
            clip.id,
            text.map((node) => ProductionInput.text(node.id).toJson()).toList(),
          );
          final request = (await ProductionImageGenerateOrchestrator().preview(
            canvas,
            node.id,
          )).request;
          expect(request.references, isEmpty);
          expect(
            request.prompt,
            [for (var i = 0; i < 20; i++) 'Line $i'].join('\n'),
          );
        },
      );

      test(
        'text role cannot refer to a media node or be used as a media role',
        () async {
          final target = await canvas.addImage(canvasId);
          final source = await canvas.addImage(canvasId);
          final text = await canvas.addText(canvasId, content: 'Text');
          await expectLater(
            canvas.shots.restoreInputs(target.clipId!, [
              ProductionInput.text(source.id).toJson(),
            ]),
            throwsA(isA<StoryboardException>()),
          );
          await expectLater(
            canvas.shots.restoreInputs(target.clipId!, [
              ProductionInput.node(
                text.id,
                VideoInputRole.reference_image,
              ).toJson(),
            ]),
            throwsA(isA<StoryboardException>()),
          );
        },
      );
      test('renaming a node writes the title its card shows', () async {
        final image = await canvas.addImage(canvasId);
        await canvas.renameNode(image.id, 'Key art');
        expect(await canvas.nodeTitle(image.id), 'Key art');
        expect((await canvas.shots.getShot(image.clipId!))!.title, 'Key art');

        final director = await canvas.addDirector(canvasId, 'Blocking');
        await canvas.renameNode(director.id, 'Doorway');
        final staging = (await db.screenplayDao.getStaging(
          director.stagingId!,
        ))!;
        expect(staging.title, 'Doorway');
        expect(staging.document!['title'], 'Doorway');

        // 剪辑节点只存在于画布作品。
        if (kind == contentKindCanvas) {
          final editing = await canvas.addEditing(canvasId, title: 'Cut A');
          await canvas.renameNode(editing.id, 'Cut B');
          expect((await db.editingDao.get(editing.editingId!))!.title, 'Cut B');
          expect(await canvas.nodeTitle(editing.id), 'Cut B');
        }
        // 节点自身的标题记一步撤销。
        final note = await canvas.addText(canvasId, title: 'Note');
        final history = CanvasHistory(canvas.shots, canvasId);
        await canvas.renameNode(note.id, 'Brief', history: history);
        expect(await canvas.nodeTitle(note.id), 'Brief');
        await history.undo();
        expect(await canvas.nodeTitle(note.id), 'Note');
      });
    });
  }
}

class _RejectTextNodeDelete extends QueryInterceptor {
  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('UPDATE "canvas_nodes"')) {
      throw StateError('Text delete failed');
    }
    return executor.runUpdate(statement, args);
  }
}

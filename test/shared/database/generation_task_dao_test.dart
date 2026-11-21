// 职责: 验证生成任务来源隔离、草稿关系、类型校验与取消/完成竞争下的原子结果登记。
// 关联文件:
//   lib/shared/database/daos/generation_task_dao.dart
//   lib/shared/models/generation/task.dart
import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/models/audio/request.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTest(NativeDatabase.memory()));
  tearDown(() => db.close());

  GenerationTasksCompanion task(
    String id, {
    String novel = 'work',
    String sourceType = 'production_clip',
    String sourceId = 'same-id',
    GenerationKind kind = GenerationKind.image,
    GenerationTaskStatus status = GenerationTaskStatus.running,
  }) => GenerationTasksCompanion.insert(
    id: id,
    kind: kind,
    novelId: novel,
    sourceType: sourceType,
    sourceId: sourceId,
    providerId: 'provider',
    providerType: 'openai',
    modelId: 'model',
    status: status,
    path: status == GenerationTaskStatus.saving
        ? const Value('images/result.png')
        : const Value.absent(),
    requestJson: switch (kind) {
      GenerationKind.image => ImageGenerationRequest(
        ProductionImageRequest(
          providerId: 'provider',
          modelId: 'model',
          originalPrompt: 'body',
          prompt: 'body',
          ratio: '1:1',
          resolution: '1K',
          size: null,
        ),
      ),
      GenerationKind.audio => AudioGenerationRequest(
        AudioRequest(
          providerId: 'provider',
          modelId: 'model',
          prompt: 'body',
          originalPrompt: 'body',
        ),
      ),
      GenerationKind.video => VideoGenerationRequest(
        const VideoRequest(
          modelId: 'model',
          prompt: 'body',
          mode: VideoMode.text,
          resolution: '720p',
          ratio: '9:16',
        ),
      ),
      GenerationKind.transcription => TranscriptionGenerationRequest(
        modelId: 'model',
        assetId: sourceId,
        audioOffsetUs: 0,
        channelFingerprint: 'fixture',
      ),
    },
  );

  for (final kind in GenerationKind.values) {
    for (final state in ['running', 'saving', 'output_retry']) {
      test('$kind cancellation respects the $state output boundary', () async {
        final status = switch (state) {
          'saving' => GenerationTaskStatus.saving,
          'output_retry' => GenerationTaskStatus.action_required,
          _ => GenerationTaskStatus.running,
        };
        await db.generationTaskDao.create(
          task('cancel-boundary', kind: kind, status: status).copyWith(
            outputUrl: state == 'output_retry'
                ? const Value('https://output.test/result')
                : const Value.absent(),
          ),
        );
        final allowed = kind == GenerationKind.image || state == 'running';
        expect(
          await db.generationTaskDao.requestCancellation('cancel-boundary'),
          allowed,
        );
        final stored = (await db.generationTaskDao.getById('cancel-boundary'))!;
        expect(stored.status, status);
        expect(stored.cancelRequestedAt != null, allowed);
      });
    }
    test(
      '$kind blocks concurrent attempts with independent task IDs',
      () async {
        Future<Object> create(String id) async {
          try {
            await db.generationTaskDao.create(task(id, kind: kind));
            return id;
          } catch (error) {
            return error;
          }
        }

        final results = await Future.wait([create('one'), create('two')]);
        expect(results.whereType<String>(), hasLength(1));
        expect(results.whereType<VideoException>(), hasLength(1));
        expect(
          results.whereType<VideoException>().single.field,
          'source_active_task',
        );
        expect(await db.select(db.generationTasks).get(), hasLength(1));
        await db.generationTaskDao.create(
          task('other-clip', kind: kind, sourceId: 'other'),
        );
        expect(await db.select(db.generationTasks).get(), hasLength(2));
      },
    );
  }

  Future<AssetRow> register(String id, {bool video = false}) async {
    await db.assetDao.insertAsset(
      AssetsCompanion.insert(
        id: id,
        type: video ? 'video' : 'image',
        purpose: 'production',
        novelId: const Value('work'),
        path: const Value('images/result.png'),
        content: Value(
          video
              ? const VideoAssetContent(mimeType: 'video/mp4')
              : const ImageAssetContent(mimeType: 'image/png'),
        ),
      ),
    );
    return (await db.assetDao.getAsset(id))!;
  }

  Future<void> completeDraft({bool draft = true, bool video = false}) async {
    await db.generationTaskDao.create(
      task(
        'draft',
        status: GenerationTaskStatus.saving,
        kind: video ? GenerationKind.video : GenerationKind.image,
      ).copyWith(draft: Value(draft)),
    );
    await db.generationTaskDao.completeResult(
      'draft',
      () => register('preview', video: video),
    );
  }

  test(
    'draft and completion keep separate identities and result assets',
    () async {
      await completeDraft();
      await db.generationTaskDao.create(
        task(
          'final',
          status: GenerationTaskStatus.saving,
        ).copyWith(draftTaskId: const Value('draft')),
      );
      await db.generationTaskDao.completeResult(
        'final',
        () => register('final'),
      );
      final draft = (await db.generationTaskDao.getById('draft'))!;
      final completed = (await db.generationTaskDao.getById('final'))!;
      expect(draft.draft, isTrue);
      expect(draft.draftTaskId, isNull);
      expect(draft.resultAssetId, 'preview');
      expect(completed.draft, isFalse);
      expect(completed.draftTaskId, draft.id);
      expect(completed.resultAssetId, 'final');
      expect(completed.status, GenerationTaskStatus.completed);
      await db.generationTaskDao.create(
        task('another-final').copyWith(draftTaskId: const Value('draft')),
      );
      expect(
        (await db.generationTaskDao.getById('another-final'))!.draftTaskId,
        draft.id,
      );
    },
  );

  for (final source in ['missing', 'running', 'ordinary', 'deleted']) {
    test('cannot complete a $source draft', () async {
      if (source == 'running') {
        await db.generationTaskDao.create(
          task('draft').copyWith(draft: const Value(true)),
        );
      } else if (source != 'missing') {
        await completeDraft(draft: source != 'ordinary');
        if (source == 'deleted') {
          await db.generationTaskDao.transition('draft', {
            GenerationTaskStatus.completed,
          }, GenerationTasksCompanion(deletedAt: Value(DateTime.now())));
        }
      }
      await expectLater(
        db.generationTaskDao.create(
          task('final').copyWith(draftTaskId: const Value('draft')),
        ),
        throwsArgumentError,
      );
      expect(await db.generationTaskDao.getById('final'), isNull);
    });
  }

  test(
    'draft completion cannot change source, provider, model or kind',
    () async {
      await completeDraft(video: true);
      final completion = task(
        'final',
        kind: GenerationKind.video,
      ).copyWith(draftTaskId: const Value('draft'));
      for (final invalid in [
        task('final').copyWith(draftTaskId: const Value('draft')),
        completion.copyWith(novelId: const Value('other-work')),
        completion.copyWith(sourceType: const Value('other-type')),
        completion.copyWith(sourceId: const Value('other-clip')),
        completion.copyWith(providerId: const Value('other-provider')),
        completion.copyWith(providerType: const Value('other-type')),
        completion.copyWith(
          modelId: const Value('other-model'),
          requestJson: Value(
            VideoGenerationRequest(
              const VideoRequest(
                modelId: 'other-model',
                prompt: 'body',
                mode: VideoMode.text,
                resolution: '720p',
                ratio: '9:16',
              ),
            ),
          ),
        ),
        completion.copyWith(draft: const Value(true)),
        completion.copyWith(draftTaskId: const Value('final')),
      ]) {
        await expectLater(
          db.generationTaskDao.create(invalid),
          throwsArgumentError,
        );
      }
      expect(await db.generationTaskDao.getById('final'), isNull);
      await db.generationTaskDao.create(completion);
      expect(
        (await db.generationTaskDao.getById('final'))!.draftTaskId,
        'draft',
      );
    },
  );

  test(
    'draft identity and relationship cannot change after creation',
    () async {
      await completeDraft();
      await db.generationTaskDao.create(
        task('final').copyWith(draftTaskId: const Value('draft')),
      );
      await expectLater(
        db.generationTaskDao.transition('draft', {
          GenerationTaskStatus.completed,
        }, const GenerationTasksCompanion(draft: Value(false))),
        throwsArgumentError,
      );
      await expectLater(
        db.generationTaskDao.transition('final', {
          GenerationTaskStatus.running,
        }, const GenerationTasksCompanion(draftTaskId: Value(null))),
        throwsArgumentError,
      );
      expect((await db.generationTaskDao.getById('draft'))!.draft, isTrue);
      expect(
        (await db.generationTaskDao.getById('final'))!.draftTaskId,
        'draft',
      );
    },
  );

  test(
    'all three source fields isolate history and duplicate submission',
    () async {
      await db.generationTaskDao.create(task('one'));
      await db.generationTaskDao.create(task('other-work', novel: 'other'));
      await db.generationTaskDao.create(
        task('other-type', sourceType: 'canvas_node'),
      );
      await db.generationTaskDao.create(task('other-id', sourceId: 'another'));
      await expectLater(
        db.generationTaskDao.create(task('duplicate')),
        throwsA(isA<VideoException>()),
      );
      final rows = await db.generationTaskDao
          .watchSource(
            novelId: 'work',
            sourceType: 'production_clip',
            sourceId: 'same-id',
          )
          .first;
      expect(rows.map((row) => row.id), ['one']);
      await db.generationTaskDao.transition(
        'one',
        {GenerationTaskStatus.running},
        const GenerationTasksCompanion(
          status: Value(GenerationTaskStatus.failed),
        ),
      );
      await db.generationTaskDao.create(task('redo'));
      expect(
        (await db.generationTaskDao
                .watchSource(
                  novelId: 'work',
                  sourceType: 'production_clip',
                  sourceId: 'same-id',
                )
                .first)
            .map((row) => row.id),
        ['redo', 'one'],
      );
    },
  );

  test(
    'requests must match kind, model and provider; completion requires registration',
    () async {
      await expectLater(
        db.generationTaskDao.create(
          task('kind').copyWith(kind: const Value(GenerationKind.video)),
        ),
        throwsArgumentError,
      );
      await expectLater(
        db.generationTaskDao.create(
          task('model').copyWith(modelId: const Value('different')),
        ),
        throwsArgumentError,
      );
      await expectLater(
        db.generationTaskDao.create(
          task('provider').copyWith(providerId: const Value('different')),
        ),
        throwsArgumentError,
      );
      await db.generationTaskDao.create(task('one'));
      await expectLater(
        db.generationTaskDao.transition(
          'one',
          {GenerationTaskStatus.running},
          const GenerationTasksCompanion(
            status: Value(GenerationTaskStatus.completed),
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(
        db.generationTaskDao.transition('one', {
          GenerationTaskStatus.running,
        }, const GenerationTasksCompanion(sourceId: Value('changed'))),
        throwsArgumentError,
      );
      expect(
        (await db.generationTaskDao.getById('one'))!.status,
        GenerationTaskStatus.running,
      );
    },
  );

  test(
    'failed result registration rolls back asset and task; retry completes exactly once',
    () async {
      await db.generationTaskDao.create(
        task('one', status: GenerationTaskStatus.saving),
      );
      await expectLater(
        db.generationTaskDao.completeResult('one', () async {
          await register('asset');
          throw StateError('interruption after insert');
        }),
        throwsStateError,
      );
      expect(await db.assetDao.getAsset('asset'), isNull);
      final pending = (await db.generationTaskDao.getById('one'))!;
      expect(pending.status, GenerationTaskStatus.saving);
      expect(pending.resultAssetId, isNull);
      var calls = 0;
      Future<AssetRow> save() {
        calls++;
        return register('asset');
      }

      expect(
        await Future.wait([
          db.generationTaskDao.completeResult('one', save),
          db.generationTaskDao.completeResult('one', save),
        ]),
        ['asset', 'asset'],
      );
      expect(calls, 1);
      final completed = (await db.generationTaskDao.getById('one'))!;
      expect(completed.status, GenerationTaskStatus.completed);
      expect(completed.completedAt, isNotNull);
      expect(completed.resultAssetId, 'asset');
    },
  );

  test(
    'cancellation wins before registration and late output creates no asset',
    () async {
      await db.generationTaskDao.create(
        task('one', status: GenerationTaskStatus.saving),
      );
      await db.generationTaskDao.transition(
        'one',
        {GenerationTaskStatus.saving},
        const GenerationTasksCompanion(
          status: Value(GenerationTaskStatus.cancelled),
        ),
      );
      expect(
        await db.generationTaskDao.completeResult(
          'one',
          () => register('late'),
        ),
        isNull,
      );
      expect(await db.assetDao.getAsset('late'), isNull);
      expect(
        (await db.generationTaskDao.getById('one'))!.status,
        GenerationTaskStatus.cancelled,
      );
    },
  );

  test(
    'recovery isolates execution kinds and preserves type-specific blocking',
    () async {
      await db.generationTaskDao.create(
        task('image', status: GenerationTaskStatus.action_required),
      );
      await db.generationTaskDao.create(task('image-redo'));
      await db.generationTaskDao.create(
        task(
          'video',
          sourceId: 'video',
          kind: GenerationKind.video,
          status: GenerationTaskStatus.running,
        ),
      );
      await expectLater(
        db.generationTaskDao.create(
          task('video-redo', sourceId: 'video', kind: GenerationKind.video),
        ),
        throwsA(isA<VideoException>()),
      );
      expect(
        (await db.generationTaskDao.recoverable(
          kind: GenerationKind.image,
        )).map((row) => row.id).toSet(),
        {'image', 'image-redo'},
      );
      expect(
        (await db.generationTaskDao.recoverable(
          kind: GenerationKind.video,
        )).map((row) => row.id),
        ['video'],
      );
    },
  );

  test(
    'uncertain video submission allows a new task and preserves history',
    () async {
      await db.generationTaskDao.create(
        task(
          'uncertain',
          kind: GenerationKind.video,
          status: GenerationTaskStatus.submission_unknown,
        ),
      );
      await db.generationTaskDao.ensureSourceAvailable(
        'work',
        'production_clip',
        'same-id',
      );
      await db.generationTaskDao.create(
        task(
          'redo',
          kind: GenerationKind.video,
          status: GenerationTaskStatus.prepared,
        ),
      );
      final history = await db.generationTaskDao
          .watchSource(
            novelId: 'work',
            sourceType: 'production_clip',
            sourceId: 'same-id',
          )
          .first;
      expect(history.map((row) => row.id), ['redo', 'uncertain']);
      expect(history.last.status, GenerationTaskStatus.submission_unknown);
      await expectLater(
        db.generationTaskDao.create(
          task('duplicate', kind: GenerationKind.video),
        ),
        throwsA(isA<VideoException>()),
      );
    },
  );

  for (final status in [
    GenerationTaskStatus.uploading,
    GenerationTaskStatus.submitting,
    GenerationTaskStatus.running,
    GenerationTaskStatus.saving,
  ]) {
    test('active video $status still prevents duplicate submission', () async {
      await db.generationTaskDao.create(
        task('active', kind: GenerationKind.video, status: status),
      );
      await expectLater(
        db.generationTaskDao.create(
          task('duplicate', kind: GenerationKind.video),
        ),
        throwsA(isA<VideoException>()),
      );
    });
  }
}

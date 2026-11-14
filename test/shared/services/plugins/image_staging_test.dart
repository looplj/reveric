// 职责: 验证图片暂存确认前后及数据库写入前后的崩溃恢复，不凭未确认文件推断成功。
// 关联文件:
//   lib/shared/services/ai/image/staging.dart
//   lib/shared/services/plugins/media_files.dart
//   lib/shared/services/production/image_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/database/app_database.dart' as db;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/generation/task.dart';
import 'package:reveric/shared/models/generation/provider_result.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/services/ai/image/output.dart';
import 'package:reveric/shared/services/plugins/files.dart';
import 'package:reveric/shared/services/plugins/media_files.dart';
import 'package:reveric/shared/services/production/image_service.dart';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late db.AppDatabase database;
  late ImageTaskService jobs;
  final provider = aiProviderBuiltinById('openai')!.copyWith(id: 'images');
  final png = img.encodePng(
    img.Image(width: 2, height: 2)..setPixelRgb(0, 0, 255, 0, 0),
  );
  ImageTaskService service() => ImageTaskService(
    database: database,
    images: buildImageLibraryService(database),
    invoke: (_, _, _, _, _, cancellation) async =>
        throw StateError('No submission during recovery'),
    beforeCreate: (_, _, _) async {},
    beforeSubmit: (_) async {},
    recoverSources: () async {},
  );
  Future<void> task(String id) => database.generationTaskDao.create(
    db.GenerationTasksCompanion.insert(
      id: id,
      kind: GenerationKind.image,
      novelId: 'novel',
      sourceType: 'production_clip',
      sourceId: id,
      providerId: provider.id,
      providerType: provider.type,
      modelId: 'old-model',
      requestJson: ImageGenerationRequest(
        ProductionImageRequest(
          providerId: provider.id,
          modelId: 'old-model',
          originalPrompt: 'original',
          prompt: 'final',
          ratio: 'auto',
          resolution: 'auto',
          size: null,
        ),
      ),
      status: GenerationTaskStatus.running,
    ),
  );
  PluginMediaFiles store(String taskId) => PluginMediaFiles(
    directory: Directory('${RevericPaths.fileWorkspaceParent}/file_workspaces'),
    scope: PluginFileScope(
      pluginId: provider.type,
      providerId: provider.id,
      taskId: taskId,
    ),
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('image-staging-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await RevericPaths.initialize();
    database = db.AppDatabase.forTest(
      NativeDatabase(File('${root.path}/tasks.sqlite')),
    );
    await database.aiProviderDao.upsert(provider);
    jobs = service();
  });
  tearDown(() async {
    await jobs.shutdown();
    await database.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });
  test(
    'ownership before bytes and complete unconfirmed bytes both require reconciliation',
    () async {
      await task('before-bytes');
      await task('unconfirmed');
      final missing = store('before-bytes');
      final missingOutput =
          ProviderOutput.fromJson(await missing.stage(png))
              as ProviderFileOutput;
      // Simulate a crash after ownership write but before output bytes reach disk.
      await missing.output(missingOutput.handle).delete();
      final pending = store('unconfirmed');
      final output =
          ProviderOutput.fromJson(await pending.stage(png))
              as ProviderFileOutput;
      await jobs.recover();
      for (final id in ['before-bytes', 'unconfirmed']) {
        final row = await jobs.requireRun(id);
        expect(row.status, GenerationTaskStatus.action_required);
        expect(row.errorCode, 'unconfirmed_output');
      }
      expect(await pending.output(output.handle).exists(), isTrue);
      expect(await database.select(database.assets).get(), isEmpty);
    },
  );
  test(
    'confirmed receipt before DB commit restores ordered candidates after disk reopen and registers once',
    () async {
      await task('confirmed');
      final files = store('confirmed');
      final first =
          ProviderOutput.fromJson(await files.stage(png)) as ProviderFileOutput;
      final secondBytes = img.encodePng(
        img.Image(width: 2, height: 2)..setPixelRgb(0, 0, 0, 255, 0),
      );
      final second =
          ProviderOutput.fromJson(await files.stage(secondBytes))
              as ProviderFileOutput;
      final context = ImageOutputContext(provider, files: files);
      await context.confirm(ProviderSucceeded([first, second]));
      // Crash before the task callback can persist any candidate receipt.
      expect((await jobs.requireRun('confirmed')).imageOutputs, isNull);
      await jobs.shutdown();
      await database.close();
      database = db.AppDatabase.forTest(
        NativeDatabase(File('${root.path}/tasks.sqlite')),
      );
      jobs = service();
      await jobs.recover();
      final row = await jobs.requireRun('confirmed');
      expect(row.status, GenerationTaskStatus.completed);
      expect(row.imageOutputs!.items, hasLength(2));
      final assets = [
        for (final output in row.imageOutputs!.items)
          (await database.assetDao.getAsset(output.assetId!))!,
      ];
      expect(
        await File(RevericPaths.resolveStored(assets[0].path)!).readAsBytes(),
        png,
      );
      expect(
        await File(RevericPaths.resolveStored(assets[1].path)!).readAsBytes(),
        secondBytes,
      );
      expect(await files.output(first.handle).exists(), isFalse);
      expect(
        await File('${files.directory.path}/${first.handle}.json').exists(),
        isFalse,
      );
      await jobs.shutdown();
      jobs = service();
      await jobs.recover();
      expect(await database.select(database.assets).get(), hasLength(2));
    },
  );
  for (final corruption in ['hash', 'owner', 'path']) {
    test(
      'confirmed $corruption mismatch retains files and never imports them',
      () async {
        await task('invalid');
        final files = store('invalid');
        final output =
            ProviderOutput.fromJson(await files.stage(png))
                as ProviderFileOutput;
        await ImageOutputContext(
          provider,
          files: files,
        ).confirm(ProviderSucceeded([output]));
        final recordFile = File(
          '${files.directory.path}/${output.handle}.json',
        );
        final record =
            jsonDecode(await recordFile.readAsString()) as Map<String, dynamic>;
        if (corruption == 'hash') {
          await files.output(output.handle).writeAsBytes([1, 2, 3]);
        } else if (corruption == 'owner') {
          record['providerId'] = 'other-instance';
          await recordFile.writeAsString(jsonEncode(record));
        } else {
          record['path'] = '${root.path}/outside.png';
          await File(record['path'] as String).writeAsBytes(png);
          await recordFile.writeAsString(jsonEncode(record));
        }
        await jobs.recover();
        final row = await jobs.requireRun('invalid');
        expect(row.status, GenerationTaskStatus.action_required);
        expect(row.errorCode, 'invalid_staged_output');
        expect(await files.output(output.handle).exists(), isTrue);
        expect(await database.select(database.assets).get(), isEmpty);
      },
    );
  }
}

// 职责: 验证地点照片的工具契约、读写校验、路径归一化和完整撤回。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/ai/tools_write.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/services/maps_service.dart

import 'dart:io';
import 'package:drift/native.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/resource_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NovelContentDatabase db;
  late AppDatabase appDb;
  late NovelContentService content;
  late WorkingOverlayService overlay;
  late AiToolManager tools;
  late Directory support;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    support = await Directory.systemTemp.createTemp('location-photos-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => support.path);
    await RevericPaths.initialize();
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    for (final id in [
      'images/a.png',
      'images/b.png',
      'images/c.png',
      'images/portrait.png',
    ]) {
      await appDb.assetDao.insertAsset(
        AssetsCompanion.insert(
          id: id,
          type: 'image',
          purpose: 'upload',
          path: Value(id),
          content: const Value(ImageAssetContent(mimeType: 'image/png')),
        ),
      );
    }
    content = NovelContentService(
      db,
      imageLibraryService: buildImageLibraryService(appDb),
    );
    overlay = WorkingOverlayService(
      db,
      content,
      novelActionsService: NovelActionsService(appDb),
    );
    tools = AiToolManager(content, workingOverlayService: overlay)
      ..registerAllTools();
  });
  tearDown(() async {
    tools.dispose();
    await db.close();
    await appDb.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await support.delete(recursive: true);
  });

  test(
    'locations and characters expose the same photo Read/Write shapes',
    () async {
      final location = resourceContractTreeForTesting('/_schema/locations');
      final character = resourceContractTreeForTesting('/_schema/characters');
      final photo = location['fields']['photos'];
      expect(photo['read_path'], isTrue);
      expect(photo['write_path'], isTrue);
      expect(
        photo['write_value'],
        character['fields']['photos']['write_value'],
      );
      final operations = (location['operation_contracts'] as List).cast<Map>();
      expect(
        operations.where(
          (op) => op['tool'] == 'Write' && op['field'] == 'photos',
        ),
        hasLength(1),
      );
      final write = operations.singleWhere(
        (op) => op['tool'] == 'Write' && op['target'] == 'resource',
      );
      expect(write['input']['properties']['photos']['type'], 'array');
    },
  );

  for (final fieldPath in [true, false]) {
    test(
      '${fieldPath ? 'field' : 'resource'} Write reads, renames, reorders and rolls back photos',
      () async {
        final id = await content.locationsService.createLocation(
          name: 'World',
          type: locationTypeWorld,
        );
        const before = [
          SubjectPhoto(assetId: 'images/a.png', name: '白天'),
          SubjectPhoto(assetId: 'images/b.png', name: '夜景'),
        ];
        await content.locationsService.updateLocation(id: id, photos: before);
        final file = File(p.join(support.path, 'images', 'b.png'));
        await file.parent.create(recursive: true);
        await file.writeAsBytes([1, 2, 3]);
        final value = [
          {'name': ' 夜景 ', 'asset_id': 'images/b.png'},
          {'asset_id': 'images/a.png', 'name': ''},
          {'asset_id': 'images/c.png', 'name': '夜景'},
        ];
        final result = await tools.executeTool(
          name: 'Write',
          input: {
            'path': fieldPath ? 'locations/$id/photos' : 'locations/$id',
            if (fieldPath)
              'value': value
            else
              'fields': {'photos': value, 'description': '城门'},
          },
        );
        expect(result['updated'], isTrue, reason: '$result');
        final expected = [
          {'asset_id': 'images/b.png', 'name': '夜景'},
          {'asset_id': 'images/a.png', 'name': ''},
          {'asset_id': 'images/c.png', 'name': '夜景'},
        ];
        final read = await tools.executeTool(
          name: 'Read',
          input: {'path': 'locations/$id'},
        );
        final field = await tools.executeTool(
          name: 'Read',
          input: {'path': 'locations/$id/photos'},
        );
        expect(read['photos'], expected);
        expect(field['value'], expected);
        final active = (await db.workingChangeDao.getByResource(
          'locations/$id/photos',
        )).single;
        expect(
          (await overlay.resolveFieldReviews([
            active,
          ])).single.isStructuredField,
          isTrue,
        );
        expect(
          await overlay.rejectWorkingChange(active.id),
          RollbackChangeResult.rolledBack,
        );
        expect(
          (await content.locationsService.getLocationById(id))!.photos,
          before,
        );

        final clear = await tools.executeTool(
          name: 'Write',
          input: {'path': 'locations/$id/photos', 'value': []},
        );
        expect(clear['updated'], isTrue);
        expect(
          (await content.locationsService.getLocationById(id))!.photos,
          isEmpty,
        );
        expect(await file.readAsBytes(), [1, 2, 3]);
        final cleared = (await db.workingChangeDao.getByResource(
          'locations/$id/photos',
        )).singleWhere((change) => change.status == workingChangeStatusActive);
        await overlay.commitWorkingChanges(
          [cleared.id],
          source: workingChangeSourceAi,
          message: 'Clear photos',
        );
        final review = (await overlay.resolveFieldReviews([
          (await overlay.getWorkingChangeById(cleared.id))!,
        ])).single;
        expect((await overlay.rollbackFields([review])).skipped, 0);
        expect(
          (await content.locationsService.getLocationById(id))!.photos,
          before,
        );
      },
    );
  }

  test(
    'photo-only Write preserves the hierarchy of a parentless UI location',
    () async {
      final id = await content.locationsService.createLocation(
        name: 'Existing',
      );
      final result = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'locations/$id/photos',
          'value': [
            {'asset_id': 'images/a.png', 'name': ''},
          ],
        },
      );
      expect(result['updated'], isTrue, reason: '$result');
      final row = (await content.locationsService.getLocationById(id))!;
      expect(row.type, locationTypeGeneric);
      expect(row.parentId, isNull);
      expect(row.photos, const [SubjectPhoto(assetId: 'images/a.png')]);
    },
  );

  test('invalid photo arrays never partially write other fields', () async {
    final id = await content.locationsService.createLocation(
      name: 'Original',
      type: locationTypeWorld,
    );
    for (final invalid in <Object>[
      ['images/a.png'],
      [
        {'asset_id': 'images/a.png'},
      ],
      [
        {'name': 'missing path'},
      ],
      [
        {'path': ' ', 'name': ''},
      ],
      [
        {'asset_id': 'images/a.png', 'name': []},
      ],
    ]) {
      final result = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'locations/$id',
          'fields': {'name': 'Changed', 'photos': invalid},
        },
      );
      expect(result['error_code'], 'invalid_argument', reason: '$result');
      final row = (await content.locationsService.getLocationById(id))!;
      expect(row.name, 'Original');
      expect(row.photos, isNull);
      expect(await db.select(db.workingChanges).get(), isEmpty);
    }
  });

  test(
    'a duplicate location name rolls back the photo write in the same request',
    () async {
      final id = await content.locationsService.createLocation(
        name: 'Original',
        type: locationTypeWorld,
      );
      await content.locationsService.createLocation(
        name: 'Taken',
        type: locationTypeWorld,
      );
      final result = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'locations/$id',
          'fields': {
            'photos': [
              {'asset_id': 'images/a.png', 'name': '夜景'},
            ],
            'name': 'Taken',
          },
        },
      );
      expect(result['error_code'], 'already_exists');
      final row = (await content.locationsService.getLocationById(id))!;
      expect(row.photos, isNull);
      expect(row.name, 'Original');
      expect(await db.select(db.workingChanges).get(), isEmpty);
    },
  );
}

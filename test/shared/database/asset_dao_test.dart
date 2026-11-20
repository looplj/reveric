// 职责: 验证图片 DAO 与其他媒体资产隔离。
// 关联文件:
//   lib/shared/database/daos/asset_dao.dart
//   lib/shared/database/daos/image_asset_dao.dart
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/production/asset_content.dart';

void main() {
  test('image DAO excludes non-image IDs, hashes and list entries', () async {
    final db = AppDatabase.forTest(NativeDatabase.memory());
    try {
      await db.assetDao.insertAsset(
        AssetsCompanion.insert(
          id: 'video',
          type: 'video',
          purpose: 'general',
          path: const Value('video.mp4'),
          content: const Value(VideoAssetContent(mimeType: 'video/mp4')),
          sha256: const Value('same'),
        ),
      );
      expect(await db.imageAssetDao.getAsset('video'), isNull);
      expect(await db.imageAssetDao.watchAssets().first, isEmpty);
      expect(
        (await db.assetDao.watchAssets(type: 'video').first).single.id,
        'video',
      );
      await expectLater(
        db.assetDao.insertAsset(
          AssetsCompanion.insert(
            id: 'invalid',
            type: 'audio',
            purpose: 'cover',
            batchId: const Value('batch'),
            path: const Value('audio.wav'),
            content: const Value(AudioAssetContent(mimeType: 'audio/wav')),
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(
        db.assetDao.insertAsset(
          AssetsCompanion.insert(id: 'empty', type: 'image', purpose: 'cover'),
        ),
        throwsArgumentError,
      );
    } finally {
      await db.close();
    }
  });

  test('latest image is the newest live image owned by the work', () async {
    final db = AppDatabase.forTest(NativeDatabase.memory());
    try {
      Future<void> insert(
        String id, {
        String type = 'image',
        String? novelId = 'work',
        required DateTime at,
      }) => db.assetDao.insertAsset(
        AssetsCompanion.insert(
          id: id,
          type: type,
          purpose: 'production.generated',
          novelId: Value(novelId),
          path: Value('file_workspaces/work/$id'),
          content: Value(
            type == 'image'
                ? const ImageAssetContent(mimeType: 'image/png')
                : const VideoAssetContent(mimeType: 'video/mp4'),
          ),
          createdAt: Value(at),
        ),
      );
      final base = DateTime(2026);
      expect(await db.assetDao.watchLatestImage('work').first, isNull);
      await insert('old', at: base);
      await insert('newest', at: base.add(const Duration(minutes: 1)));
      await insert(
        'video',
        type: 'video',
        at: base.add(const Duration(minutes: 2)),
      );
      await insert(
        'shared',
        novelId: null,
        at: base.add(const Duration(minutes: 3)),
      );
      expect((await db.assetDao.watchLatestImage('work').first)?.id, 'newest');
      await db.assetDao.softDeleteAsset('newest');
      expect((await db.assetDao.watchLatestImage('work').first)?.id, 'old');
    } finally {
      await db.close();
    }
  });
}

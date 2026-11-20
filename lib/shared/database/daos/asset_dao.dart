// 职责: 校验、去重查询与软删除统一媒体资产，提供按作品及类型筛选的资产流。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/daos/image_asset_dao.dart
//   lib/shared/services/ai/video/task_service.dart

import 'package:drift/drift.dart';

import '../../logger/app_logger.dart';
import '../../models/production/asset_content.dart';
import '../app_database.dart';

part 'asset_dao.drift.dart';

final _log = AppLogger.forModule('AssetDao');

@DriftAccessor(tables: [Assets])
class AssetDao extends DatabaseAccessor<AppDatabase> with _$AssetDaoMixin {
  AssetDao(super.db);

  /// [inLibrary] 为 true 时只列用户收进素材库的资产。
  Stream<List<AssetRow>> watchAssets({
    String? novelId,
    String? type,
    bool inLibrary = false,
  }) {
    final query = select(assets)
      ..where((t) => t.deletedAt.equals(notDeletedSentinel))
      ..orderBy([
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.id),
      ]);
    if (novelId != null) {
      query.where((t) => t.novelId.equals(novelId) | t.novelId.isNull());
    }
    if (type != null) {
      query.where((t) => t.type.equals(type));
    }
    if (inLibrary) {
      query.where((t) => t.inLibrary.equals(true));
    }
    return query.watch();
  }

  /// 作品自己最近入库的一张图片；画布没设封面时拿它当预览。不含跨作品共享资产。
  Stream<AssetRow?> watchLatestImage(String novelId) =>
      (select(assets)
            ..where(
              (t) =>
                  t.novelId.equals(novelId) &
                  t.type.equals('image') &
                  t.path.isNotNull() &
                  t.deletedAt.equals(notDeletedSentinel),
            )
            ..orderBy([
              (t) => OrderingTerm.desc(t.createdAt),
              (t) => OrderingTerm.desc(t.id),
            ])
            ..limit(1))
          .watchSingleOrNull();

  /// 单个资产；不存在或已软删除时为 null。
  Stream<AssetRow?> watchAsset(String id) =>
      (select(assets)..where(
            (t) => t.id.equals(id) & t.deletedAt.equals(notDeletedSentinel),
          ))
          .watchSingleOrNull();

  Future<AssetRow?> getAsset(String id) =>
      (select(assets)..where(
            (t) => t.id.equals(id) & t.deletedAt.equals(notDeletedSentinel),
          ))
          .getSingleOrNull();

  Future<void> insertAsset(AssetsCompanion asset) async {
    validate(asset);
    try {
      await into(assets).insert(asset);
    } catch (error, stack) {
      _log.error(
        '[DB] assets INSERT id=${asset.id.value}',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// 同一作品内同字节的资产；给出 [purpose] 时只找该业务场景的那条。
  Future<AssetRow?> findByHash(
    String hash,
    String type,
    String novelId, {
    String? purpose,
  }) =>
      (select(assets)
            ..where(
              (t) =>
                  t.sha256.equals(hash) &
                  t.type.equals(type) &
                  t.novelId.equals(novelId) &
                  (purpose == null
                      ? const Constant(true)
                      : t.purpose.equals(purpose)) &
                  t.deletedAt.equals(notDeletedSentinel),
            )
            ..limit(1))
          .getSingleOrNull();

  /// 同作品同类型里已有同名资产时，在扩展名前补「 (2)」「 (3)」…直到不重名。
  Future<String> uniqueName(String novelId, String type, String name) async {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    final taken = {
      for (final row
          in await (selectOnly(assets)
                ..addColumns([assets.name])
                ..where(
                  assets.novelId.equals(novelId) &
                      assets.type.equals(type) &
                      assets.deletedAt.equals(notDeletedSentinel),
                ))
              .get())
        row.read(assets.name),
    };
    var candidate = name;
    for (var n = 2; taken.contains(candidate); n++) {
      candidate = '$stem ($n)$extension';
    }
    return candidate;
  }

  Future<void> softDeleteAsset(String id) async {
    try {
      await (update(assets)..where((t) => t.id.equals(id))).write(
        AssetsCompanion(
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stack) {
      _log.error(
        '[DB] assets UPDATE soft-delete id=$id',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<void> setFavorite(String id, bool favorite) async {
    try {
      await (update(assets)..where(
            (t) => t.id.equals(id) & t.deletedAt.equals(notDeletedSentinel),
          ))
          .write(
            AssetsCompanion(
              favorite: Value(favorite),
              updatedAt: Value(DateTime.now()),
            ),
          );
    } catch (error, stack) {
      _log.error(
        '[DB] assets UPDATE favorite id=$id',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<void> setInLibrary(String id, bool inLibrary) async {
    try {
      await (update(assets)..where(
            (t) => t.id.equals(id) & t.deletedAt.equals(notDeletedSentinel),
          ))
          .write(
            AssetsCompanion(
              inLibrary: Value(inLibrary),
              updatedAt: Value(DateTime.now()),
            ),
          );
    } catch (error, stack) {
      _log.error(
        '[DB] assets UPDATE in_library id=$id',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// 导演台导出按操作落到固定路径，续跑时按路径找回已登记的资产。
  Future<AssetRow?> findByPath(String path) =>
      (select(assets)..where(
            (t) => t.path.equals(path) & t.deletedAt.equals(notDeletedSentinel),
          ))
          .getSingleOrNull();

  static void validate(AssetsCompanion asset) {
    if (!asset.type.present || !fileAssetTypes.contains(asset.type.value)) {
      throw ArgumentError('Unsupported asset type');
    }
    if (!asset.path.present ||
        asset.path.value?.trim().isNotEmpty != true ||
        asset.content.value is! MediaAssetContent ||
        (asset.content.value as MediaAssetContent).mimeType
                ?.trim()
                .isNotEmpty !=
            true) {
      throw ArgumentError('Media assets require path and mime type');
    }
    final content = asset.content.value;
    if (content != null) {
      if (content.kind != asset.type.value) {
        throw ArgumentError('Asset content type mismatch');
      }
      AssetContent.fromJson(content.toJson());
    }
    if (asset.type.value != 'image' &&
        asset.batchId.present &&
        asset.batchId.value != null) {
      throw ArgumentError('Non-image assets cannot join an image batch');
    }
  }
}

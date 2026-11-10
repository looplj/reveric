// 职责: 按用途读写渠道素材记录，并为认证 UI 提供隔离的状态查询。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/models/provider_asset.dart
//   lib/shared/services/ai/assets/certification.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
import 'package:drift/drift.dart';
import '../../logger/app_logger.dart';
import '../../models/provider_asset.dart';
import '../../utils/random_id.dart';
import '../app_database.dart';
part 'provider_asset_dao.drift.dart';

final _log = AppLogger.forModule('ProviderAssetDao');

@DriftAccessor(tables: [ProviderAssets])
class ProviderAssetDao extends DatabaseAccessor<AppDatabase>
    with _$ProviderAssetDaoMixin {
  ProviderAssetDao(super.db);

  SimpleSelectStatement<$ProviderAssetsTable, ProviderAsset> _live() =>
      select(providerAssets)
        ..where((t) => t.deletedAt.equals(notDeletedSentinel));

  Future<ProviderAsset?> find(
    String assetId,
    String providerId, {
    ProviderAssetKind kind = ProviderAssetKind.certification,
  }) =>
      (_live()..where(
            (t) =>
                t.assetId.equals(assetId) &
                t.providerId.equals(providerId) &
                t.kind.equalsValue(kind),
          ))
          .getSingleOrNull();

  Stream<List<ProviderAsset>> watchByAssets(Iterable<String> assetIds) =>
      (_live()..where(
            (t) =>
                t.assetId.isIn(assetIds) &
                t.kind.equalsValue(ProviderAssetKind.certification),
          ))
          .watch();

  Future<List<ProviderAsset>> processing({
    ProviderAssetKind kind = ProviderAssetKind.certification,
  }) =>
      (_live()..where(
            (t) =>
                t.status.equalsValue(ProviderAssetStatus.processing) &
                t.kind.equalsValue(kind),
          ))
          .get();

  /// 开始一次操作：同一素材、渠道和用途复用原行，并清掉上次结果。
  Future<ProviderAsset> start(
    String assetId,
    String providerId, {
    ProviderAssetKind kind = ProviderAssetKind.certification,
    String? contextHash,
  }) async {
    try {
      return await transaction(() async {
        final current = await find(assetId, providerId, kind: kind);
        if (current == null) {
          return into(providerAssets).insertReturning(
            ProviderAssetsCompanion.insert(
              id: buildRandomId('provider_asset'),
              assetId: assetId,
              providerId: providerId,
              kind: Value(kind),
              contextHash: Value(contextHash),
              status: ProviderAssetStatus.processing,
            ),
          );
        }
        await (update(
          providerAssets,
        )..where((t) => t.id.equals(current.id))).write(
          ProviderAssetsCompanion(
            remoteId: const Value(null),
            contextHash: Value(contextHash),
            remoteUrl: const Value(null),
            expiresAt: const Value(null),
            remoteTaskId: const Value(null),
            remoteGroupId: const Value(null),
            status: const Value(ProviderAssetStatus.processing),
            errorCode: const Value(null),
            errorMessage: const Value(null),
            updatedAt: Value(DateTime.now()),
          ),
        );
        return (await find(assetId, providerId, kind: kind))!;
      });
    } catch (error, stack) {
      _log.error(
        '[DB] table=provider_assets op=INSERT,UPDATE asset=$assetId provider=$providerId',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<void> write(String id, ProviderAssetsCompanion values) async {
    try {
      await (update(providerAssets)..where((t) => t.id.equals(id))).write(
        values.copyWith(updatedAt: Value(DateTime.now())),
      );
    } catch (error, stack) {
      _log.error(
        '[DB] table=provider_assets op=UPDATE id=$id',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }
}

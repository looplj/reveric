// 职责: 把用户选中的本地图片认证进渠道私域素材库，记录状态并在后台轮询到出结果。
// 关联文件:
//   lib/shared/services/ai/assets/volcengine.dart
//   lib/shared/services/ai/assets/atlascloud.dart
//   lib/shared/database/daos/provider_asset_dao.dart
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/models/provider_asset.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../../../database/app_database.dart';
import '../../../logger/app_logger.dart';
import '../../../models/ai_provider.dart';
import '../../../models/production/media.dart';
import '../../../models/provider_asset.dart';
import '../../../models/video/request.dart';
import '../video/reference_storage_service.dart';
import 'atlascloud.dart';
import 'client.dart';
import 'volcengine.dart';

final _log = AppLogger.forModule('ProviderAssets');

/// 渠道是否支持私域素材认证，且已填好所需凭据：火山用 AK/SK，AtlasCloud 用 API Key。
bool providerSupportsAssetCertification(AiProvider provider) =>
    switch (AiProviderType.values.asNameMap()[provider.type]) {
      AiProviderType.volcengine =>
        (provider.accessKeyId?.trim().isNotEmpty ?? false) &&
            (provider.secretAccessKey?.trim().isNotEmpty ?? false),
      AiProviderType.atlascloud => provider.apiKey.trim().isNotEmpty,
      _ => false,
    };

/// 火山与 AtlasCloud 素材库对单张图片的要求一致；不满足的图片不发请求。
const providerAssetImageMimeTypes = {
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/bmp',
  'image/tiff',
  'image/gif',
  'image/heic',
  'image/heif',
};
const providerAssetImageMaxBytes = 30 * 1024 * 1024;

class ProviderAssetService {
  ProviderAssetService({
    required this.database,
    required this.references,
    required this.probe,
    http.Client Function(AiProvider)? transport,
    this.pollDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
  }) : transport =
           transport ??
           ((provider) => provider.createProxyClient() ?? http.Client());

  final AppDatabase database;
  final ReferenceStorageService references;
  final Future<MediaInfo> Function(String path) probe;
  final http.Client Function(AiProvider) transport;

  /// 依次使用的轮询间隔，用完后停在最后一个。
  final List<Duration> pollDelays;
  final _polling = <String>{};
  bool _disposed = false;

  /// 认证一张图片：先本地校验，再上传、提交到渠道；提交成功后转入后台轮询。
  Future<void> certify({
    required String assetId,
    required String providerId,
    required File file,
    required String mimeType,
    required String name,
  }) async {
    final provider = await database.aiProviderDao.getById(providerId);
    if (provider == null ||
        !provider.enabled ||
        !providerSupportsAssetCertification(provider)) {
      throw const ProviderAssetException('configuration_required');
    }
    await _validateImage(file, mimeType);
    final row = await database.providerAssetDao.start(assetId, providerId);
    final client = _client(provider);
    try {
      final reference = await references.ensure(
        VideoInput(
          role: VideoInputRole.reference_image,
          assetId: assetId,
          mimeType: mimeType,
        ),
        file,
      );
      final submission = await client.submit(
        url: Uri.parse(reference.url),
        name: name,
      );
      await database.providerAssetDao.write(
        row.id,
        ProviderAssetsCompanion(
          remoteId: Value(submission.remoteId),
          remoteTaskId: Value(submission.remoteTaskId),
          remoteGroupId: Value(submission.remoteGroupId),
        ),
      );
    } catch (error, stack) {
      _log.error(
        'certify asset=$assetId provider=$providerId',
        error: error,
        stackTrace: stack,
      );
      await _fail(row.id, error);
      rethrow;
    } finally {
      client.close();
    }
    unawaited(_poll(row.id));
  }

  /// 启动时接着轮询上次没出结果的记录；还没提交到渠道就中断的记录判为失败。
  Future<void> resume() async {
    for (final row in await database.providerAssetDao.processing()) {
      if (row.remoteId == null) {
        await database.providerAssetDao.write(
          row.id,
          const ProviderAssetsCompanion(
            status: Value(ProviderAssetStatus.failed),
            errorCode: Value('interrupted'),
          ),
        );
      } else {
        unawaited(_poll(row.id));
      }
    }
  }

  void dispose() {
    _disposed = true;
  }

  Future<void> _poll(String id) async {
    if (!_polling.add(id)) {
      return;
    }
    try {
      for (var attempt = 0; !_disposed; attempt++) {
        await Future<void>.delayed(
          pollDelays[attempt.clamp(0, pollDelays.length - 1)],
        );
        if (_disposed) {
          return;
        }
        final row = await (database.select(
          database.providerAssets,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (row == null ||
            row.deletedAt != notDeletedSentinel ||
            row.status != ProviderAssetStatus.processing ||
            row.remoteId == null) {
          return;
        }
        final provider = await database.aiProviderDao.getById(row.providerId);
        if (provider == null || !providerSupportsAssetCertification(provider)) {
          await _fail(
            id,
            const ProviderAssetException('configuration_required'),
          );
          return;
        }
        final client = _client(provider);
        try {
          final remote = await client.state(row.remoteTaskId ?? row.remoteId!);
          if (remote.status != ProviderAssetStatus.processing) {
            await database.providerAssetDao.write(
              id,
              ProviderAssetsCompanion(
                status: Value(remote.status),
                errorCode: Value(remote.errorCode),
                errorMessage: Value(remote.errorMessage),
              ),
            );
            return;
          }
        } catch (error, stack) {
          // 网络抖动不改状态，下一轮继续查。
          _log.warning('poll asset=${row.remoteId} error=$error\n$stack');
        } finally {
          client.close();
        }
      }
    } finally {
      _polling.remove(id);
    }
  }

  Future<void> _validateImage(File file, String mimeType) async {
    if (!providerAssetImageMimeTypes.contains(mimeType)) {
      throw const ProviderAssetException('invalid_format');
    }
    if (await file.length() >= providerAssetImageMaxBytes) {
      throw const ProviderAssetException('invalid_size');
    }
    final info = await probe(file.path);
    final width = info.width;
    final height = info.height;
    if (width == null ||
        height == null ||
        width <= 300 ||
        width >= 6000 ||
        height <= 300 ||
        height >= 6000) {
      throw const ProviderAssetException('invalid_dimensions');
    }
    final ratio = width / height;
    if (ratio <= .4 || ratio >= 2.5) {
      throw const ProviderAssetException('invalid_ratio');
    }
  }

  Future<void> _fail(String id, Object error) =>
      database.providerAssetDao.write(
        id,
        ProviderAssetsCompanion(
          status: const Value(ProviderAssetStatus.failed),
          errorCode: Value(
            error is ProviderAssetException ? error.code : 'unknown',
          ),
          errorMessage: Value(
            error is ProviderAssetException ? error.message : '$error',
          ),
        ),
      );

  ProviderAssetClient _client(AiProvider provider) =>
      provider.type == AiProviderType.atlascloud.name
      ? AtlasCloudAssetClient(
          httpClient: transport(provider),
          apiKey: provider.apiKey.trim(),
        )
      : VolcengineAssetClient(
          httpClient: transport(provider),
          accessKeyId: provider.accessKeyId!.trim(),
          secretAccessKey: provider.secretAccessKey!.trim(),
          projectName: switch (provider.assetProjectName?.trim()) {
            final name? when name.isNotEmpty => name,
            _ => 'default',
          },
        );
}

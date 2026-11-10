// 职责: 准备本地参考素材的元数据，优先 OSS、其次渠道上传，图片／音频最后使用 Base64，并合并重复上传。
// 关联文件:
//   lib/shared/providers/video_tasks.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart
//   lib/shared/models/production/media.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json

import 'dart:io';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import '../../../database/app_database.dart';
import '../../../logger/app_logger.dart';
import '../../../models/ai_provider.dart';
import '../../../models/provider_asset.dart';
import '../../../models/object_storage_config.dart';
import '../../object_storage/service.dart';
import '../uploads/api88.dart';
import '../uploads/atlascloud.dart';
import '../uploads/minimax.dart';
import '../uploads/purefox.dart';
import 'package:crypto/crypto.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/production/media.dart';
import '../../../models/video/request.dart';
import '../../../models/video/channels.dart';
import '../../../models/video/task_result.dart';

typedef ReferenceUploadResult = ({String url, DateTime? expiresAt});
typedef ReferenceUploader =
    Future<ReferenceUploadResult> Function({
      required File file,
      required String sha256,
      required String mimeType,
      required int fileSize,
    });

final _log = AppLogger.forModule('ReferenceStorage');

class ReferenceStorageService {
  ReferenceStorageService({
    required this.probe,
    required this.database,
    required this.storage,
    this.uploadClient,
  });
  final AppDatabase database;
  final ObjectStorageService storage;
  final http.Client Function(AiProvider)? uploadClient;
  final _clients = <http.Client>{};
  final _uploads = <String, Future<ReferenceUploadResult>>{};
  final _uploadContexts = <String, String>{};
  bool _disposed = false;
  Future<void>? _startup;

  void dispose() {
    _disposed = true;
    for (final client in _clients) {
      client.close();
    }
  }

  Future<void> resume() => _startup ??= (() async {
    for (final row in await database.providerAssetDao.processing(
      kind: ProviderAssetKind.upload,
    )) {
      await database.providerAssetDao.write(
        row.id,
        const ProviderAssetsCompanion(
          status: Value(ProviderAssetStatus.failed),
          errorCode: Value('interrupted'),
        ),
      );
    }
  })();

  static String _contextHash(AiProvider provider, String mime) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            provider.typeConfig.uploadProtocol?.name,
            provider.effectiveBaseUrl.replaceFirst(RegExp(r'/+$'), ''),
            sha256.convert(utf8.encode(provider.effectiveApiKey)).toString(),
            mime,
          ]),
        ),
      )
      .toString();

  Future<ReferenceUploadResult?> cached(
    AiProvider provider,
    VideoInput input,
  ) async {
    if (provider.typeConfig.uploadProtocol == null) {
      return null;
    }
    final row = await database.providerAssetDao.find(
      input.assetId,
      provider.id,
      kind: ProviderAssetKind.upload,
    );
    if (row == null ||
        row.status != ProviderAssetStatus.active ||
        row.contextHash != _contextHash(provider, input.mimeType) ||
        (row.remoteUrl == null && row.remoteId == null)) {
      return null;
    }
    if (row.expiresAt != null && !row.expiresAt!.isAfter(DateTime.now())) {
      await database.providerAssetDao.write(
        row.id,
        const ProviderAssetsCompanion(
          status: Value(ProviderAssetStatus.failed),
          errorCode: Value('expired'),
        ),
      );
      return null;
    }
    final String url;
    if (provider.typeConfig.uploadProtocol == UploadProtocol.minimax_files &&
        row.remoteId != null) {
      url = 'mm_file://${row.remoteId}';
    } else if (provider.typeConfig.uploadProtocol ==
            UploadProtocol.purefox_uploads &&
        row.remoteId != null) {
      url = row.remoteId!;
    } else if (row.remoteUrl != null) {
      url = row.remoteUrl!;
    } else {
      return null;
    }
    final result = (url: url, expiresAt: row.expiresAt);
    _validateResult(
      result,
      allowPurefoxKey:
          provider.typeConfig.uploadProtocol == UploadProtocol.purefox_uploads,
    );
    if (provider.typeConfig.uploadProtocol == UploadProtocol.atlascloud_media) {
      if (_disposed) {
        throw StateError('Reference storage disposed');
      }
      final client =
          uploadClient?.call(provider) ??
          provider.createProxyClient() ??
          http.Client();
      _clients.add(client);
      try {
        if (!await AtlasCloudUploadOrchestrator().isAvailable(url, client)) {
          await database.providerAssetDao.write(
            row.id,
            const ProviderAssetsCompanion(
              status: Value(ProviderAssetStatus.failed),
              errorCode: Value('expired'),
            ),
          );
          return null;
        }
      } finally {
        _clients.remove(client);
        client.close();
      }
    }
    return result;
  }

  Future<({String key, ReferenceUploader upload})?> _storageTarget() async {
    final ObjectStorageConfig config;
    try {
      config = await storage.load();
    } on FormatException {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'reference_storage',
        messageKey: LocaleKeys.productionReferenceStorageInvalid,
      );
    }
    if (config.isEmpty) {
      return null;
    }
    if (config.validate() != null) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'reference_storage',
        messageKey: LocaleKeys.productionReferenceStorageInvalid,
      );
    }
    return (
      key: sha256.convert(utf8.encode(config.normalized().encode())).toString(),
      upload:
          ({
            required file,
            required sha256,
            required mimeType,
            required fileSize,
          }) async {
            final result = await storage.upload(
              config,
              file: file,
              sha256: sha256,
              mimeType: mimeType,
              fileSize: fileSize,
            );
            return (url: result.url.toString(), expiresAt: result.expiresAt);
          },
    );
  }

  /// [providerId] 为空时只检查 OSS；渠道已删除时按无渠道处理。
  Future<bool> preflight({
    String? providerId,
    List<VideoInput> inputs = const [],
    String? modelId,
  }) async {
    final provider = providerId == null
        ? null
        : await database.aiProviderDao.getById(providerId);
    if (provider != null &&
        lookupVideoChannelModel(
              provider.type,
              modelId,
            )?.protocolOptions.supportsProviderAssets ==
            true) {
      final pending = <VideoInput>[];
      for (final input in inputs) {
        final asset = await database.providerAssetDao.find(
          input.assetId,
          provider.id,
        );
        if (asset?.status != ProviderAssetStatus.active ||
            asset?.remoteId == null) {
          pending.add(input);
        }
      }
      if (inputs.isNotEmpty && pending.isEmpty) {
        return true;
      }
      inputs = pending;
    }
    if (await _storageTarget() != null) {
      return true;
    }
    if (provider == null) {
      return false;
    }
    if (provider.effectiveApiKey.trim().isEmpty) {
      throw const VideoException(
        VideoErrorCode.authentication,
        field: 'reference_upload',
      );
    }
    return provider.typeConfig.uploadProtocol != null ||
        (inputs.isNotEmpty && inputs.every(_canInline));
  }

  bool _canInline(VideoInput input) =>
      input.role.kind != VideoMediaKind.video &&
      input.mimeType.startsWith('${input.role.kind.name}/');

  /// 固定整组参考的 OSS 配置，并在发送任何文件前检查每个输入的路径。
  /// 调用方已探测过媒体信息，这里直接复用，不再重复探测。
  Future<List<VideoReference>> prepare(
    List<(VideoInput, File, VideoMediaInfo)> inputs, {
    required AiProvider provider,
  }) async {
    if (inputs.isEmpty) {
      return [];
    }
    final target = await _storageTarget();
    if (target == null && provider.typeConfig.uploadProtocol == null) {
      var encodedSize = 0;
      for (final (input, file, _) in inputs) {
        if (!_canInline(input)) {
          throw _storageRequired();
        }
        encodedSize += ((await file.length() + 2) ~/ 3) * 4;
      }
      if (encodedSize > videoInlineRequestMaxBytes) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'file_size',
        );
      }
    }
    if (target == null && provider.typeConfig.uploadProtocol != null) {
      for (final (input, file, _) in inputs) {
        _validateUpload(provider, input.mimeType, await file.length());
      }
    }
    final result = <VideoReference>[];
    for (final (input, file, mediaInfo) in inputs) {
      result.add(
        await _ensure(
          input,
          file,
          provider: provider,
          target: target,
          mediaInfo: mediaInfo,
        ),
      );
    }
    return result;
  }

  Future<ReferenceUploadResult> _channelUpload(
    AiProvider provider,
    VideoInput input,
    File file,
  ) async {
    await resume();
    final key = jsonEncode([input.assetId, provider.id]);
    // Serialize configuration changes for the same row; always recheck the saved context.
    final context = _contextHash(provider, input.mimeType);
    while (_uploads.containsKey(key)) {
      if (_uploadContexts[key] == context) {
        return _uploads[key]!;
      }
      try {
        await _uploads[key];
      } on Object catch (error) {
        _log.warning(
          'previous upload failed before configuration change: ${error.runtimeType}',
        );
      }
      final hit = await cached(provider, input);
      if (hit != null) {
        return hit;
      }
    }
    final pending = _performUpload(provider, input, file);
    _uploads[key] = pending;
    _uploadContexts[key] = context;
    try {
      return await pending;
    } finally {
      if (identical(_uploads[key], pending)) {
        _uploads.remove(key);
        _uploadContexts.remove(key);
      }
    }
  }

  static void _validateUpload(AiProvider provider, String mimeType, int size) {
    switch (provider.typeConfig.uploadProtocol) {
      case UploadProtocol.atlascloud_media:
        AtlasCloudUploadOrchestrator.validate(provider, mimeType, size);
      case UploadProtocol.api88_media:
        Api88UploadOrchestrator.validate(provider, mimeType, size);
      case UploadProtocol.minimax_files:
        MinimaxUploadOrchestrator.validate(provider, mimeType, size);
      case UploadProtocol.purefox_uploads:
        PurefoxUploadOrchestrator.validate(provider, mimeType, size);
      case null:
        throw const VideoException(VideoErrorCode.configuration_required);
    }
  }

  Future<ReferenceUploadResult> _performUpload(
    AiProvider provider,
    VideoInput input,
    File file,
  ) async {
    final hit = await cached(provider, input);
    if (hit != null) {
      return hit;
    }
    final protocol = provider.typeConfig.uploadProtocol;
    final size = await file.length();
    _validateUpload(provider, input.mimeType, size);
    if (_disposed) {
      throw StateError('Reference storage disposed');
    }
    final dao = database.providerAssetDao;
    final row = await dao.start(
      input.assetId,
      provider.id,
      kind: ProviderAssetKind.upload,
      contextHash: _contextHash(provider, input.mimeType),
    );
    final client =
        uploadClient?.call(provider) ??
        provider.createProxyClient() ??
        http.Client();
    _clients.add(client);
    try {
      final run = switch (protocol!) {
        UploadProtocol.atlascloud_media => AtlasCloudUploadOrchestrator().run,
        UploadProtocol.purefox_uploads => PurefoxUploadOrchestrator().run,
        UploadProtocol.api88_media => Api88UploadOrchestrator().run,
        UploadProtocol.minimax_files => MinimaxUploadOrchestrator().run,
      };
      final result = await run(
        provider: provider,
        file: file,
        mimeType: input.mimeType,
        client: client,
      );
      _validateResult(
        result,
        allowPurefoxKey:
            provider.typeConfig.uploadProtocol ==
            UploadProtocol.purefox_uploads,
      );
      await dao.write(
        row.id,
        ProviderAssetsCompanion(
          remoteId: Value(
            protocol == UploadProtocol.purefox_uploads
                ? result.url
                : result.url.startsWith('mm_file://')
                ? result.url.substring('mm_file://'.length)
                : null,
          ),
          remoteUrl: Value(
            protocol == UploadProtocol.purefox_uploads ||
                    result.url.startsWith('mm_file://')
                ? null
                : result.url,
          ),
          expiresAt: Value(result.expiresAt),
          status: const Value(ProviderAssetStatus.active),
        ),
      );
      return result;
    } catch (error) {
      _log.warning(
        'upload failed provider=${provider.id} asset=${input.assetId} type=${error.runtimeType} code=${error is VideoException ? error.code.name : 'local'}',
      );
      await dao.write(
        row.id,
        ProviderAssetsCompanion(
          status: const Value(ProviderAssetStatus.failed),
          errorCode: Value(
            error is VideoException
                ? '${error.code.name}:${error.detail ?? ''}'
                : error.runtimeType.toString(),
          ),
        ),
      );
      rethrow;
    } finally {
      _clients.remove(client);
      client.close();
    }
  }

  final Future<MediaInfo> Function(String path) probe;

  final _preparing = <String, Future<ReferenceUploadResult>>{};

  Future<VideoReference> ensure(
    VideoInput input,
    File file, {
    AiProvider? provider,
  }) async {
    return _ensure(
      input,
      file,
      provider: provider,
      target: await _storageTarget(),
    );
  }

  Future<VideoReference> _ensure(
    VideoInput input,
    File file, {
    required AiProvider? provider,
    required ({String key, ReferenceUploader upload})? target,
    VideoMediaInfo? mediaInfo,
  }) async {
    final channel = provider?.typeConfig.uploadProtocol != null;
    final inline =
        target == null && !channel && provider != null && _canInline(input);
    if (target == null && !channel && !inline) {
      throw _storageRequired();
    }
    final info = mediaInfo ?? await _probeInfo(file);
    final size = await file.length();
    if (inline &&
        (size < 1 || ((size + 2) ~/ 3) * 4 > videoInlineRequestMaxBytes)) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'file_size',
      );
    }
    final hash = target == null
        ? ''
        : (await sha256.bind(file.openRead()).first).toString();
    final key = '${target?.key}/${input.mimeType}/$hash';
    final uploader = target?.upload;
    final pending = inline
        ? (() async {
            final bytes = await file.readAsBytes();
            if (bytes.length != size) {
              throw const VideoException(
                VideoErrorCode.invalid_request,
                field: 'file_size',
              );
            }
            return (
              url: 'data:${input.mimeType};base64,${base64Encode(bytes)}',
              expiresAt: null,
            );
          })()
        : uploader == null
        ? _channelUpload(provider!, input, file)
        : _preparing[key] ??= uploader(
            file: file,
            sha256: hash,
            mimeType: input.mimeType,
            fileSize: size,
          );
    final ReferenceUploadResult result;
    try {
      result = await pending;
    } finally {
      if (identical(_preparing[key], pending)) {
        _preparing.remove(key);
      }
    }
    if (!inline) {
      _validateResult(
        result,
        allowPurefoxKey:
            provider?.typeConfig.uploadProtocol ==
            UploadProtocol.purefox_uploads,
      );
    }
    return VideoReference(
      role: input.role,
      url: result.url,
      mimeType: input.mimeType,
      fileSize: size,
      mediaInfo: info,
    );
  }

  Future<VideoMediaInfo> _probeInfo(File file) async {
    final info = await probe(file.path);
    return VideoMediaInfo(
      width: info.width,
      height: info.height,
      durationMs: info.duration.inMilliseconds,
      frameRate: info.frameRate,
    );
  }

  static VideoException _storageRequired() => const VideoException(
    VideoErrorCode.configuration_required,
    field: 'reference_storage',
    messageKey: LocaleKeys.productionReferenceStorageNotConnected,
    detail:
        'Application object storage is not configured for reference uploads.',
  );

  static void _validateResult(
    ReferenceUploadResult result, {
    bool allowPurefoxKey = false,
  }) {
    final fileReference =
        (allowPurefoxKey && isPurefoxUploadKey(result.url)) ||
        (result.url.startsWith('mm_file://') &&
            result.url.length > 'mm_file://'.length);
    final url = fileReference ? null : Uri.tryParse(result.url);
    final expires = result.expiresAt;
    if ((!fileReference &&
            (url == null ||
                !{'http', 'https'}.contains(url.scheme) ||
                url.host.isEmpty ||
                url.userInfo.isNotEmpty)) ||
        (expires != null && !expires.isAfter(DateTime.now().toUtc()))) {
      throw const VideoException(VideoErrorCode.invalid_response);
    }
  }
}

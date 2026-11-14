// 职责: 准备本地参考素材的元数据，优先渠道上传、其次对象存储，图片／音频最后使用 Base64，并合并重复上传。
// 关联文件:
//   lib/shared/providers/video_tasks.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart
//   lib/shared/models/production/media.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json

import '../../../models/provider_model.dart';
import '../../../agent/agent_tool_dispatcher.dart';
import '../../../models/image/config.dart';
import '../../../models/production/image_request.dart';
import '../../plugins/host.dart';
import '../../plugins/files.dart';
import '../../plugins/runtime.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'dart:io';
import 'dart:async';
import '../../production/ffmpeg_runner.dart';
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
    this.pluginHost,
  });
  final PluginHostService? pluginHost;
  final _cancellations = <AgentCancellationController>{};
  final AppDatabase database;
  final ObjectStorageService storage;
  final http.Client Function(AiProvider)? uploadClient;
  final _clients = <http.Client>{};
  final _uploads = <String, Future<ReferenceUploadResult>>{};
  bool _disposed = false;
  Future<void>? _startup;

  void dispose() {
    _disposed = true;
    for (final cancellation in _cancellations) {
      cancellation.cancel();
    }
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

  Future<String> _contextHash(AiProvider provider, String mime) async {
    if (provider.pluginId != null) {
      final host = pluginHost;
      if (host == null) {
        throw PluginHostError(
          'configuration_required',
          'Plugin Host is required for reference upload',
        );
      }
      return host.providerUploadContext(provider, mime);
    }
    return sha256
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
  }

  Future<ReferenceUploadResult?> cached(
    AiProvider provider,
    VideoInput input,
  ) async {
    if (provider.pluginId == null &&
        provider.typeConfig.uploadProtocol == null) {
      return null;
    }
    final row = await database.providerAssetDao.find(
      input.assetId,
      provider.id,
      kind: ProviderAssetKind.upload,
    );
    if (row == null ||
        row.status != ProviderAssetStatus.active ||
        row.contextHash != await _contextHash(provider, input.mimeType) ||
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
      allowOpaque: provider.pluginId != null,
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

  Future<({String key, ReferenceUploader upload})?> _storageTarget({
    AgentCancellationToken? cancellation,
  }) async {
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
              cancellation: cancellation,
            );
            return (url: result.url.toString(), expiresAt: result.expiresAt);
          },
    );
  }

  Future<bool> _hasUpload(AiProvider provider) async {
    if (provider.pluginId == null) {
      return provider.typeConfig.uploadProtocol != null;
    }
    final host = pluginHost;
    if (host == null) {
      throw PluginHostError(
        'configuration_required',
        'Plugin Host is required for video references',
      );
    }
    await host.start();
    return host.providerHasMethod(provider.pluginId!, 'uploadReference');
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
        resolveVideoModel(
              provider,
              modelId,
            )?.capabilities.supportsCertifiedAssets ==
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
    if (provider != null && await _hasUpload(provider)) {
      return true;
    }
    if (await _storageTarget() != null) {
      return true;
    }
    if (provider == null) {
      return false;
    }
    if (!provider.isPluginProvider && provider.effectiveApiKey.trim().isEmpty) {
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
    final channel = await _hasUpload(provider);
    final target = channel ? null : await _storageTarget();
    if (target == null && !channel) {
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
    if (channel) {
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

  /// 按输入顺序准备视频参考；认证、渠道上传、对象存储、内联只选择一次。
  Future<List<Map<String, dynamic>>> prepareVideos(
    List<(VideoInput, File, VideoMediaInfo)> inputs, {
    required AiProvider provider,
    required bool supportsCertifiedAssets,
    required PluginFileScope files,
    required String taskId,
    AgentCancellationToken? cancellation,
  }) async {
    if (files.providerId != provider.id ||
        files.taskId != taskId ||
        (provider.pluginId != null && files.pluginId != provider.pluginId)) {
      throw PluginHostError(
        'permission_denied',
        'Video reference scope belongs to another task',
      );
    }
    if (inputs.isEmpty) {
      return [];
    }
    final certified = <int, String>{};
    for (final (index, (input, _, _)) in inputs.indexed) {
      if (supportsCertifiedAssets) {
        final row = await database.providerAssetDao.find(
          input.assetId,
          provider.id,
        );
        if (row?.status == ProviderAssetStatus.active &&
            row?.remoteId?.trim().isNotEmpty == true) {
          certified[index] = row!.remoteId!;
        }
      }
    }
    final pending = certified.length != inputs.length;
    final channel = pending && await _hasUpload(provider);
    final target = pending && !channel
        ? await _storageTarget(cancellation: cancellation)
        : null;
    var encodedSize = 0;
    for (final (index, (input, file, _)) in inputs.indexed) {
      if (certified.containsKey(index)) {
        continue;
      }
      final size = await file.length();
      if (size < 1) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'file_size',
        );
      }
      if (channel) {
        _validateUpload(provider, input.mimeType, size);
      } else if (target == null) {
        if (!_canInline(input)) {
          throw _storageRequired();
        }
        encodedSize += ((size + 2) ~/ 3) * 4;
      }
    }
    if (encodedSize > videoInlineRequestMaxBytes) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'file_size',
      );
    }
    final result = <Map<String, dynamic>>[];
    for (final (index, (input, file, media)) in inputs.indexed) {
      if (_disposed || cancellation?.isCancellationRequested == true) {
        throw PluginHostError(
          'cancelled',
          'Video reference preparation cancelled',
        );
      }
      final Map<String, dynamic> source;
      if (certified[index] case final id?) {
        source = {'kind': 'certified', 'remoteId': id};
      } else if (channel) {
        final uploaded = await _channelUpload(
          provider,
          input,
          file,
          taskId: taskId,
          cancellation: cancellation,
        );
        source = {
          'kind': 'uploaded',
          'ref': uploaded.url,
          if (uploaded.expiresAt != null)
            'expiresAt': uploaded.expiresAt!.toUtc().toIso8601String(),
        };
      } else if (target != null) {
        final uploaded = await target.upload(
          file: file,
          sha256: (await sha256.bind(file.openRead()).first).toString(),
          mimeType: input.mimeType,
          fileSize: await file.length(),
        );
        _validateResult(uploaded);
        source = {
          'kind': 'url',
          'url': uploaded.url,
          if (uploaded.expiresAt != null)
            'expiresAt': uploaded.expiresAt!.toUtc().toIso8601String(),
        };
      } else {
        final info = await files.register(
          file,
          name: p.basename(file.path),
          mimeType: input.mimeType,
        );
        source = {'kind': 'file', 'handle': info['handle']};
      }
      result.add({
        'assetId': input.assetId,
        'role': input.role.name,
        'mimeType': input.mimeType,
        'fileSize': await file.length(),
        'mediaInfo': {
          'width': media.width,
          'height': media.height,
          'durationMs': media.durationMs,
          'frameRate': media.frameRate,
        },
        'source': source,
      });
    }
    return result;
  }

  /// 图片严格按模型声明准备参考；不会在上传失败后改走其他传输。
  Future<List<Map<String, dynamic>>> prepareImages(
    List<(ProductionImageReference, File, String)> inputs, {
    required AiProvider provider,
    required ImageReferenceTransport transport,
    required PluginFileScope files,
    required String taskId,
    AgentCancellationToken? cancellation,
  }) async {
    if (files.providerId != provider.id ||
        files.taskId != taskId ||
        (provider.pluginId != null && files.pluginId != provider.pluginId)) {
      throw PluginHostError(
        'permission_denied',
        'Image reference scope belongs to another task',
      );
    }
    if (inputs.isEmpty) {
      return [];
    }
    final target = transport == ImageReferenceTransport.url
        ? await _storageTarget(cancellation: cancellation)
        : null;
    if (transport == ImageReferenceTransport.url && target == null) {
      throw _storageRequired();
    }
    // Validate the whole group before the first external upload.
    for (final (_, file, mime) in inputs) {
      if (!mime.startsWith('image/') ||
          !await file.exists() ||
          await file.length() < 1) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'reference_image',
        );
      }
      final info = await _probeInfo(file, cancellation: cancellation);
      if ((info.width ?? 0) < 1 || (info.height ?? 0) < 1) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'reference_image',
        );
      }
      if (transport == ImageReferenceTransport.uploaded) {
        _validateUpload(provider, mime, await file.length());
        await _contextHash(provider, mime);
      }
    }
    final result = <Map<String, dynamic>>[];
    for (final (reference, file, mime) in inputs) {
      if (_disposed || cancellation?.isCancellationRequested == true) {
        throw PluginHostError(
          'cancelled',
          'Image reference preparation cancelled',
        );
      }
      final Map<String, dynamic> source;
      switch (transport) {
        case ImageReferenceTransport.file:
          final info = await files.register(
            file,
            name: p.basename(file.path),
            mimeType: mime,
          );
          source = {'kind': 'file', 'handle': info['handle']};
        case ImageReferenceTransport.url:
          final uploaded = await target!.upload(
            file: file,
            sha256: (await sha256.bind(file.openRead()).first).toString(),
            mimeType: mime,
            fileSize: await file.length(),
          );
          _validateResult(uploaded);
          source = {'kind': 'url', 'url': uploaded.url};
        case ImageReferenceTransport.uploaded:
          final uploaded = await _channelUpload(
            provider,
            VideoInput(
              role: VideoInputRole.reference_image,
              assetId: reference.assetId,
              mimeType: mime,
            ),
            file,
            taskId: taskId,
            cancellation: cancellation,
          );
          source = {
            'kind': 'uploaded',
            'ref': uploaded.url,
            if (uploaded.expiresAt != null)
              'expiresAt': uploaded.expiresAt!.toUtc().toIso8601String(),
          };
      }
      result.add({
        'assetId': reference.assetId,
        if (reference.clipId != null) 'clipId': reference.clipId,
        if (reference.inputId != null) 'inputId': reference.inputId,
        'mimeType': mime,
        'source': source,
      });
    }
    return result;
  }

  Future<ReferenceUploadResult> _channelUpload(
    AiProvider provider,
    VideoInput input,
    File file, {
    String? taskId,
    AgentCancellationToken? cancellation,
  }) async {
    await resume();
    final key = jsonEncode([input.assetId, provider.id]);
    void checkCancelled() {
      if (_disposed || cancellation?.isCancellationRequested == true) {
        throw PluginHostError('cancelled', 'Reference upload cancelled');
      }
    }

    checkCancelled();
    // Only completed uploads are shared. Each invocation owns its transport/token.
    while (_uploads.containsKey(key)) {
      final cancelled = Completer<void>();
      final unlink = cancellation?.onCancel(() {
        if (!cancelled.isCompleted) {
          cancelled.complete();
        }
      });
      try {
        await Future.any<void>([
          _uploads[key]!.then<void>((_) {}),
          cancelled.future.then<void>((_) => checkCancelled()),
        ]);
      } on Object catch (error) {
        checkCancelled();
        _log.warning('previous upload failed: ${error.runtimeType}');
      } finally {
        unlink?.call();
      }
      checkCancelled();
      final hit = await cached(provider, input);
      checkCancelled();
      if (hit != null) {
        return hit;
      }
    }
    checkCancelled();
    final pending = () async {
      final context = await _contextHash(provider, input.mimeType);
      checkCancelled();
      return _performUpload(
        provider,
        input,
        file,
        context: context,
        taskId: taskId ?? const Uuid().v4(),
        cancellation: cancellation,
      );
    }();
    _uploads[key] = pending;
    try {
      final result = await pending;
      checkCancelled();
      return result;
    } finally {
      if (identical(_uploads[key], pending)) {
        _uploads.remove(key);
      }
    }
  }

  static void _validateUpload(AiProvider provider, String mimeType, int size) {
    if (provider.pluginId != null) {
      if (size < 1) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'file_size',
        );
      }
      return;
    }
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
    File file, {
    required String context,
    required String taskId,
    AgentCancellationToken? cancellation,
  }) async {
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
      contextHash: context,
    );
    try {
      final uploader = _providerUploader(provider, taskId, cancellation);
      final result = await uploader(
        file: file,
        sha256: (await sha256.bind(file.openRead()).first).toString(),
        mimeType: input.mimeType,
        fileSize: size,
      );
      if (context != await _contextHash(provider, input.mimeType)) {
        throw PluginHostError(
          'configuration_required',
          'Provider configuration changed during upload',
        );
      }
      _validateResult(
        result,
        allowOpaque: provider.pluginId != null,
        allowPurefoxKey:
            provider.typeConfig.uploadProtocol ==
            UploadProtocol.purefox_uploads,
      );
      await dao.write(
        row.id,
        ProviderAssetsCompanion(
          remoteId: Value(
            provider.pluginId != null
                ? null
                : protocol == UploadProtocol.purefox_uploads
                ? result.url
                : result.url.startsWith('mm_file://')
                ? result.url.substring('mm_file://'.length)
                : null,
          ),
          remoteUrl: Value(
            provider.pluginId != null
                ? result.url
                : protocol == UploadProtocol.purefox_uploads ||
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
    }
  }

  ReferenceUploader _providerUploader(
    AiProvider provider,
    String taskId,
    AgentCancellationToken? cancellation,
  ) =>
      ({
        required file,
        required sha256,
        required mimeType,
        required fileSize,
      }) async {
        if (provider.pluginId != null) {
          final host = pluginHost;
          if (host == null) {
            throw PluginHostError(
              'configuration_required',
              'Plugin Host is required for reference upload',
            );
          }
          final controller = AgentCancellationController();
          final unlink = cancellation?.onCancel(controller.cancel);
          _cancellations.add(controller);
          final scope = PluginFileScope(
            pluginId: provider.pluginId!,
            providerId: provider.id,
            taskId: taskId,
          );
          try {
            final info = await scope.register(
              file,
              name: p.basename(file.path),
              mimeType: mimeType,
            );
            final value = await host.callProvider(
              provider,
              'uploadReference',
              input: {'file': info},
              taskId: taskId,
              files: scope,
              cancellation: controller.token,
            );
            if (value is! Map ||
                value['ref'] is! String ||
                (value['ref'] as String).trim().isEmpty ||
                (value['expiresAt'] != null && value['expiresAt'] is! String)) {
              throw PluginHostError(
                'invalid_response',
                'Invalid upload reference result',
              );
            }
            final expires = value['expiresAt'] == null
                ? null
                : DateTime.tryParse(value['expiresAt'] as String);
            if (value['expiresAt'] != null &&
                (expires == null || !expires.isUtc)) {
              throw PluginHostError(
                'invalid_response',
                'Upload expiration must be UTC ISO 8601',
              );
            }
            return (url: value['ref'] as String, expiresAt: expires);
          } finally {
            scope.revoke();
            unlink?.call();
            _cancellations.remove(controller);
          }
        }
        final client =
            uploadClient?.call(provider) ??
            provider.createProxyClient() ??
            http.Client();
        _clients.add(client);
        final unlink = cancellation?.onCancel(client.close);
        try {
          final run = switch (provider.typeConfig.uploadProtocol) {
            UploadProtocol.atlascloud_media =>
              AtlasCloudUploadOrchestrator().run,
            UploadProtocol.purefox_uploads => PurefoxUploadOrchestrator().run,
            UploadProtocol.api88_media => Api88UploadOrchestrator().run,
            UploadProtocol.minimax_files => MinimaxUploadOrchestrator().run,
            null => throw const VideoException(
              VideoErrorCode.configuration_required,
            ),
          };
          return await run(
            provider: provider,
            file: file,
            mimeType: mimeType,
            client: client,
          );
        } finally {
          unlink?.call();
          _clients.remove(client);
          client.close();
        }
      };

  final Future<MediaInfo> Function(
    String path, {
    MediaCancellation? cancellation,
  })
  probe;

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
      target: provider != null && await _hasUpload(provider)
          ? null
          : await _storageTarget(),
    );
  }

  Future<VideoReference> _ensure(
    VideoInput input,
    File file, {
    required AiProvider? provider,
    required ({String key, ReferenceUploader upload})? target,
    VideoMediaInfo? mediaInfo,
  }) async {
    final channel = provider != null && await _hasUpload(provider);
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
        allowOpaque: provider?.isPluginProvider == true,
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

  Future<VideoMediaInfo> _probeInfo(
    File file, {
    AgentCancellationToken? cancellation,
  }) async {
    if (cancellation?.isCancellationRequested == true) {
      throw PluginHostError('cancelled', 'Reference preparation cancelled');
    }
    final mediaCancellation = MediaCancellation();
    Future<void> cancelProbe() async {
      try {
        await mediaCancellation.cancel();
      } catch (error, stack) {
        _log.error(
          'Reference probe cancellation failed',
          error: error,
          stackTrace: stack,
        );
      }
    }

    final unlink = cancellation?.onCancel(() => unawaited(cancelProbe()));
    final MediaInfo info;
    try {
      info = await probe(file.path, cancellation: mediaCancellation);
    } finally {
      unlink?.call();
    }
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
    bool allowOpaque = false,
  }) {
    final fileReference =
        (allowOpaque && result.url.trim().isNotEmpty) ||
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

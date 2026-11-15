// 职责: 获取、校验并缓存插件市场索引，以及下载和校验插件 ZIP 安装包。
// 关联文件:
//   lib/shared/app_config.dart
//   lib/shared/models/plugin/marketplace_plugin.dart
//   lib/shared/services/plugins/package_archive.dart
//   lib/shared/providers/plugin_marketplace_providers.dart
// 遵循的 Rules:
//   .agents/rules/code-style.md
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app_config.dart';
import '../../logger/app_logger.dart';
import '../../models/plugin/marketplace_plugin.dart';
import 'package_archive.dart';

final _log = AppLogger.forModule('PluginMarketplace');

/// 插件市场网络/校验错误分类，避免向 UI 透出底层异常细节。
enum PluginMarketplaceErrorKind {
  network,
  invalidCatalog,
  downloadFailed,
  packageTooLarge,
  integrityMismatch,
  invalidPackage,
}

class PluginMarketplaceException implements Exception {
  const PluginMarketplaceException(this.kind, this.message);

  final PluginMarketplaceErrorKind kind;
  final String message;

  @override
  String toString() => 'PluginMarketplaceException($kind): $message';
}

/// 负责插件市场索引读取/缓存与安装包下载/完整性校验的服务。
class PluginMarketplaceService {
  PluginMarketplaceService({
    this.indexUrl = revericPluginMarketplaceIndexUrl,
    this.cacheFile,
    FutureOr<Directory> Function()? supportDirectoryProvider,
    FutureOr<Dio> Function()? createClient,
    this.maxCatalogBytes = 2 * 1024 * 1024,
  }) : _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory,
       _createClient = createClient ?? _defaultClient;

  static Dio _defaultClient() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  final String indexUrl;
  final File? cacheFile;
  final FutureOr<Directory> Function() _supportDirectoryProvider;
  final FutureOr<Dio> Function() _createClient;
  final int maxCatalogBytes;

  Future<File> _resolveCacheFile() async {
    if (cacheFile != null) {
      return cacheFile!;
    }
    final root = await _supportDirectoryProvider();
    return File(p.join(root.path, 'plugin_marketplace', 'index.json'));
  }

  MarketplacePluginIndex _decodeCatalogJson(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Plugin index root must be a JSON object');
    }
    return MarketplacePluginIndex.fromJson(
      decoded.cast<String, Object?>(),
      maxPackageBytes: PluginPackageArchive.maxZipBytes,
    );
  }

  /// 读取本地缓存的索引；缺失、超限或损坏时返回 null。
  Future<MarketplacePluginIndex?> readCatalogCache() async {
    try {
      final file = await _resolveCacheFile();
      if (!await file.exists()) {
        return null;
      }
      final length = await file.length();
      if (length <= 0 || length > maxCatalogBytes) {
        return null;
      }
      final raw = await file.readAsString();
      return _decodeCatalogJson(raw);
    } on Object catch (error, stackTrace) {
      _log.error(
        'Failed to read cached plugin marketplace catalog',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 拉取远程官方索引并在校验成功后原子写入缓存。
  Future<MarketplacePluginIndex> fetchCatalog({
    CancelToken? cancelToken,
  }) async {
    final client = await _createClient();
    final Uint8List bytes;
    try {
      bytes = await _downloadBoundedBytes(
        client: client,
        url: indexUrl,
        maxBytes: maxCatalogBytes,
        cancelToken: cancelToken,
      );
    } on DioException catch (error, stackTrace) {
      if (CancelToken.isCancel(error)) {
        rethrow;
      }
      _log.error(
        'Failed to fetch plugin marketplace catalog',
        error: error,
        stackTrace: stackTrace,
      );
      throw PluginMarketplaceException(
        PluginMarketplaceErrorKind.network,
        error.message ?? 'Network error fetching plugin catalog',
      );
    } on PluginMarketplaceException {
      rethrow;
    }

    final String raw;
    final MarketplacePluginIndex index;
    try {
      raw = utf8.decode(bytes);
      index = _decodeCatalogJson(raw);
    } on Object catch (error, stackTrace) {
      _log.error(
        'Invalid plugin marketplace catalog payload',
        error: error,
        stackTrace: stackTrace,
      );
      throw PluginMarketplaceException(
        PluginMarketplaceErrorKind.invalidCatalog,
        error.toString(),
      );
    }

    try {
      final file = await _resolveCacheFile();
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(raw, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await temp.rename(file.path);
    } on Object catch (error, stackTrace) {
      _log.error(
        'Failed to persist plugin marketplace cache',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return index;
  }

  /// 下载、校验大小与 SHA-256、解包并核对包内清单的插件 ID 与版本。
  ///
  /// 主地址失败或完整性校验未通过时自动尝试 [MarketplacePluginVersion.fallbackUrl]。
  Future<PluginPackageArchive> downloadPackage({
    required String pluginId,
    required MarketplacePluginVersion version,
    CancelToken? cancelToken,
  }) async {
    final urls = version.downloadUrls;
    if (urls.isEmpty) {
      throw const PluginMarketplaceException(
        PluginMarketplaceErrorKind.downloadFailed,
        'No download URL available',
      );
    }

    final client = await _createClient();
    final maxAllowedBytes = math.min(
      version.size,
      PluginPackageArchive.maxZipBytes,
    );
    PluginMarketplaceException? lastError;

    for (final url in urls) {
      if (cancelToken?.isCancelled ?? false) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: url),
          reason: cancelToken?.cancelError,
        );
      }
      try {
        final bytes = await _downloadBoundedBytes(
          client: client,
          url: url,
          maxBytes: maxAllowedBytes,
          cancelToken: cancelToken,
        );
        if (bytes.length != version.size) {
          throw PluginMarketplaceException(
            PluginMarketplaceErrorKind.integrityMismatch,
            'Package size mismatch: ${bytes.length} != ${version.size}',
          );
        }
        final digest = sha256.convert(bytes).toString();
        if (digest != version.sha256) {
          throw PluginMarketplaceException(
            PluginMarketplaceErrorKind.integrityMismatch,
            'Package SHA-256 mismatch for $pluginId@${version.version}',
          );
        }
        return _decodeAndVerifyArchive(
          bytes: bytes,
          expectedId: pluginId,
          expectedVersion: version.version,
        );
      } on DioException catch (error, stackTrace) {
        if (CancelToken.isCancel(error)) {
          rethrow;
        }
        _log.error(
          'Failed downloading plugin package from $url',
          error: error,
          stackTrace: stackTrace,
        );
        lastError = PluginMarketplaceException(
          PluginMarketplaceErrorKind.downloadFailed,
          error.message ?? 'Download failed',
        );
      } on PluginMarketplaceException catch (error) {
        if (error.kind == PluginMarketplaceErrorKind.invalidPackage) {
          rethrow;
        }
        _log.error('Plugin package check failed from $url: ${error.message}');
        lastError = error;
      }
    }

    throw lastError ??
        const PluginMarketplaceException(
          PluginMarketplaceErrorKind.downloadFailed,
          'Download failed',
        );
  }

  PluginPackageArchive _decodeAndVerifyArchive({
    required Uint8List bytes,
    required String expectedId,
    required String expectedVersion,
  }) {
    final PluginPackageArchive archive;
    try {
      archive = PluginPackageArchive.decode(bytes);
    } on Object catch (error, stackTrace) {
      _log.error(
        'Failed to decode downloaded plugin package',
        error: error,
        stackTrace: stackTrace,
      );
      throw PluginMarketplaceException(
        PluginMarketplaceErrorKind.invalidPackage,
        error.toString(),
      );
    }

    if (archive.manifest.id != expectedId ||
        archive.manifest.version != expectedVersion) {
      throw PluginMarketplaceException(
        PluginMarketplaceErrorKind.integrityMismatch,
        'Package manifest mismatch: expected $expectedId@$expectedVersion, '
        'got ${archive.manifest.id}@${archive.manifest.version}',
      );
    }
    return archive;
  }

  Future<Uint8List> _downloadBoundedBytes({
    required Dio client,
    required String url,
    required int maxBytes,
    CancelToken? cancelToken,
  }) async {
    final response = await client.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: const {'Accept': 'application/json, application/zip, */*'},
      ),
    );
    final body = response.data;
    if (body == null) {
      throw const PluginMarketplaceException(
        PluginMarketplaceErrorKind.downloadFailed,
        'Empty response body',
      );
    }
    final contentLength = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (contentLength != null && contentLength > maxBytes) {
      await body.stream.drain<void>().catchError((_) {});
      throw PluginMarketplaceException(
        PluginMarketplaceErrorKind.packageTooLarge,
        'Response length $contentLength exceeds $maxBytes bytes',
      );
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (cancelToken?.isCancelled ?? false) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: url),
          reason: cancelToken?.cancelError,
        );
      }
      if (builder.length + chunk.length > maxBytes) {
        throw PluginMarketplaceException(
          PluginMarketplaceErrorKind.packageTooLarge,
          'Downloaded payload exceeds $maxBytes bytes',
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

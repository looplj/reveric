// 职责: 读取画廊目录、调用投稿接口并按签名头传输文件。
// 关联文件:
//   lib/shared/services/canvas_gallery/orchestrator.dart
//   lib/shared/providers/canvas_gallery_providers.dart
//   lib/shared/app_config.dart

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../app_config.dart';
import '../../logger/app_logger.dart';

final _log = AppLogger.forModule('CanvasGallery');
const canvasGalleryUserAgent = 'Reveric/$appVersion';
const canvasGalleryPartSize = 8 * 1024 * 1024;
const canvasGalleryPackageLimit = 2 * 1024 * 1024 * 1024;
const canvasGalleryCoverLimit = 2 * 1024 * 1024;

class CanvasGalleryItem {
  CanvasGalleryItem.fromJson(Map<String, dynamic> json)
    : id = _string(json, 'canvas_id'),
      title = _string(json, 'title'),
      description = json['description'] as String,
      cover = Uri.parse(_string(json, 'cover_url')),
      size = _integer(json, 'content_size_bytes'),
      publishedAt = _date(json, 'published_at'),
      conversationCount = _integer(json, 'conversation_count'),
      pinned = json['is_pinned'] as bool;

  final String id;
  final String title;
  final String description;
  final Uri cover;
  final int size;
  final DateTime publishedAt;
  final int conversationCount;
  final bool pinned;
}

class CanvasGalleryDetail extends CanvasGalleryItem {
  CanvasGalleryDetail.fromJson(super.json)
    : archive = Uri.parse(_string(json, 'content_url')),
      version = _integer(json, 'content_version'),
      nodeCount = _integer(json, 'node_count'),
      assetCount = _integer(json, 'asset_count'),
      conversationFileCount = _integer(json, 'conversation_file_count'),
      super.fromJson();

  final Uri archive;
  final int version;
  final int nodeCount;
  final int assetCount;
  final int conversationFileCount;
}

class CanvasGalleryPageData {
  const CanvasGalleryPageData(this.items, this.nextCursor);

  final List<CanvasGalleryItem> items;
  final String? nextCursor;
}

class CanvasGalleryPublicationResult {
  CanvasGalleryPublicationResult.fromJson(Map<String, dynamic> json)
    : id = _string(json, 'canvas_id'),
      publishedAt = _date(json, 'published_at');

  final String id;
  final DateTime publishedAt;
}

class CanvasGallerySignedPut {
  CanvasGallerySignedPut.fromJson(Map<String, dynamic> json)
    : url = Uri.parse(_string(json, 'url')),
      headers = Map<String, String>.from(_object(json['headers'])),
      expires = _date(json, 'expires_at'),
      part = json['part_number'] as int?;

  final Uri url;
  final Map<String, String> headers;
  final DateTime expires;
  final int? part;
}

class CanvasGalleryUpload {
  CanvasGalleryUpload.fromJson(Map<String, dynamic> json)
    : id = _string(json, 'upload_id'),
      expires = _date(json, 'expires_at'),
      cover = _object(json['urls'])['cover'] == null
          ? null
          : CanvasGallerySignedPut.fromJson(
              _object(_object(json['urls'])['cover']),
            ),
      parts = (_object(json['urls'])['parts'] as List<dynamic>)
          .map((part) => CanvasGallerySignedPut.fromJson(_object(part)))
          .toList(growable: false);

  final String id;
  final DateTime expires;
  final CanvasGallerySignedPut? cover;
  final List<CanvasGallerySignedPut> parts;
}

class CanvasGalleryFailure implements Exception {
  const CanvasGalleryFailure(this.code, {this.status, this.retryAfter});

  final String code;
  final int? status;
  final Duration? retryAfter;

  @override
  String toString() => 'CanvasGalleryFailure($code, HTTP ${status ?? "-"})';
}

class CanvasGalleryService {
  const CanvasGalleryService({
    required this.createClient,
    required this.apiOrigin,
    required this.publicOrigin,
  });

  final FutureOr<Dio> Function() createClient;
  final Uri apiOrigin;
  final Uri publicOrigin;

  Future<CanvasGalleryPageData> list({String? cursor, CancelToken? cancel}) =>
      _api(
        'GET',
        '/gallery/canvas',
        (data) {
          final items = (data['items'] as List<dynamic>)
              .map((item) {
                final entry = CanvasGalleryItem.fromJson(_object(item));
                _requirePublic(entry.cover);
                return entry;
              })
              .toList(growable: false);
          return CanvasGalleryPageData(items, data['next_cursor'] as String?);
        },
        query: {'cursor': ?cursor},
        cancel: cancel,
      );

  Future<CanvasGalleryDetail> detail(String id, {CancelToken? cancel}) =>
      _api('GET', '/gallery/canvas/${Uri.encodeComponent(id)}', (data) {
        final item = CanvasGalleryDetail.fromJson(data);
        _requirePublic(item.cover);
        _requirePublic(item.archive);
        return item;
      }, cancel: cancel);

  Future<CanvasGalleryUpload> requestUpload({
    required String token,
    required String requestId,
    required int coverSize,
    required int archiveSize,
    String? uploadId,
    CancelToken? cancel,
  }) => _api(
    'POST',
    '/gallery/canvas/upload',
    CanvasGalleryUpload.fromJson,
    body: uploadId == null
        ? {'cover_size_bytes': coverSize, 'content_size_bytes': archiveSize}
        : {'upload_id': uploadId},
    headers: {
      HttpHeaders.authorizationHeader: 'Bearer $token',
      if (uploadId == null) 'Idempotency-Key': requestId,
    },
    cancel: cancel,
  );

  Future<CanvasGalleryPublicationResult> create({
    required String token,
    required String uploadId,
    required String title,
    required String description,
    CancelToken? cancel,
  }) => _api(
    'POST',
    '/gallery/canvas',
    CanvasGalleryPublicationResult.fromJson,
    body: {'upload_id': uploadId, 'title': title, 'description': description},
    headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
    cancel: cancel,
  );

  Future<void> put({
    required CanvasGallerySignedPut signed,
    required File source,
    required int offset,
    required int length,
    CancelToken? cancel,
  }) async {
    final url = signed.url;
    if (url.scheme != 'https' ||
        !(url.host.endsWith('.r2.cloudflarestorage.com') ||
            url.host == 'r2.cloudflarestorage.com') ||
        url.userInfo.isNotEmpty ||
        url.port != 443) {
      throw const CanvasGalleryFailure('invalid_signature');
    }
    final lengthHeader = signed.headers.entries
        .where(
          (header) =>
              header.key.toLowerCase() == HttpHeaders.contentLengthHeader,
        )
        .singleOrNull;
    if (lengthHeader?.value != '$length' || length <= 0 || offset < 0) {
      throw const CanvasGalleryFailure('invalid_signature');
    }
    if (!signed.expires.isAfter(DateTime.now())) {
      throw const CanvasGalleryFailure('signature_expired');
    }

    final client = await createClient();
    try {
      // Dio infers a content type unless the interceptor is removed. The PUT
      // must send the signed headers and must never inherit API authorization.
      client.interceptors.removeImplyContentTypeInterceptor();
      final response = await client.putUri<String>(
        url,
        data: source.openRead(offset, offset + length),
        options: Options(
          headers: signed.headers,
          followRedirects: false,
          validateStatus: (_) => true,
          responseType: ResponseType.plain,
          sendTimeout: const Duration(minutes: 3),
          receiveTimeout: const Duration(seconds: 30),
        ),
        cancelToken: cancel,
      );
      final status = response.statusCode;
      if (status == null || status < 200 || status >= 300) {
        _log.warning(
          'PUT R2 host=${url.host} status=$status part=${signed.part}',
        );
        throw CanvasGalleryFailure('storage_upload', status: status);
      }
    } on DioException catch (error) {
      throw _transport('PUT R2', error);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> download({
    required CanvasGalleryDetail item,
    required File file,
    void Function(double)? onProgress,
    CancelToken? cancel,
  }) async {
    _requirePublic(item.archive);
    if (item.version != 1) {
      throw const CanvasGalleryFailure('unsupported_package');
    }
    if (item.size <= 0 || item.size > canvasGalleryPackageLimit) {
      throw const CanvasGalleryFailure('package_too_large');
    }
    var length = await file.exists() ? await file.length() : 0;
    if (length == item.size) {
      onProgress?.call(1);
      return;
    }
    if (length > item.size) {
      await file.delete();
      length = 0;
    }
    final client = await createClient();
    try {
      final response = await client.getUri<ResponseBody>(
        item.archive,
        options: Options(
          headers: {
            HttpHeaders.acceptEncodingHeader: 'identity',
            HttpHeaders.userAgentHeader: canvasGalleryUserAgent,
            if (length > 0) HttpHeaders.rangeHeader: 'bytes=$length-',
          },
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          followRedirects: false,
          receiveTimeout: const Duration(seconds: 45),
        ),
        cancelToken: cancel,
      );
      if (response.statusCode == 200) {
        // A server ignoring Range returned the full file, so restart at zero.
        length = 0;
      } else if (response.statusCode != 206 ||
          response.headers.value(HttpHeaders.contentRangeHeader) !=
              'bytes $length-${item.size - 1}/${item.size}') {
        _log.warning(
          'GET R2 host=${item.archive.host} status=${response.statusCode}',
        );
        throw CanvasGalleryFailure(
          'download_failed',
          status: response.statusCode,
        );
      }
      final declared = response.headers.value(HttpHeaders.contentLengthHeader);
      if (declared != null && declared != '${item.size - length}') {
        throw const CanvasGalleryFailure('download_failed');
      }
      final sink = await file.open(
        mode: length == 0 ? FileMode.write : FileMode.append,
      );
      var written = length;
      try {
        await for (final bytes in response.data!.stream) {
          if (written + bytes.length > item.size) {
            throw const CanvasGalleryFailure('download_failed');
          }
          await sink.writeFrom(bytes);
          written += bytes.length;
          onProgress?.call(written / item.size);
        }
        if (written != item.size) {
          throw const CanvasGalleryFailure('download_failed');
        }
      } finally {
        await sink.close();
      }
    } on DioException catch (error) {
      throw _transport('GET R2', error);
    } finally {
      client.close(force: true);
    }
  }

  Future<T> _api<T>(
    String method,
    String route,
    T Function(Map<String, dynamic>) decode, {
    Map<String, String>? query,
    Map<String, String>? headers,
    Map<String, Object>? body,
    CancelToken? cancel,
  }) async {
    final uri = apiOrigin.resolve(route).replace(queryParameters: query);
    final client = await createClient();
    try {
      final response = await client.requestUri<dynamic>(
        uri,
        data: body,
        cancelToken: cancel,
        options: Options(
          method: method,
          headers: headers,
          followRedirects: false,
          validateStatus: (_) => true,
          receiveTimeout: const Duration(seconds: 90),
        ),
      );
      final status = response.statusCode;
      if (status != 200 && status != 201) {
        final data = response.data;
        final apiError = data is Map ? data['error'] : null;
        final raw = apiError is Map ? apiError['code'] : null;
        final code = raw is String && RegExp(r'^[a-z_]{1,48}$').hasMatch(raw)
            ? raw
            : 'request_failed';
        final seconds = int.tryParse(
          response.headers.value('retry-after') ?? '',
        );
        _log.warning('$method $route status=$status code=$code');
        throw CanvasGalleryFailure(
          code,
          status: status,
          retryAfter: seconds == null ? null : Duration(seconds: seconds),
        );
      }
      return decode(_object(response.data));
    } on DioException catch (error) {
      throw _transport('$method $route', error);
    } on FormatException catch (error) {
      _log.warning('$method $route invalid reply type=${error.runtimeType}');
      throw const CanvasGalleryFailure('invalid_reply');
    } on TypeError catch (error) {
      _log.warning('$method $route invalid reply type=${error.runtimeType}');
      throw const CanvasGalleryFailure('invalid_reply');
    } finally {
      client.close(force: true);
    }
  }

  void _requirePublic(Uri uri) {
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        uri.origin != publicOrigin.origin ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const CanvasGalleryFailure('invalid_reply');
    }
  }
}

CanvasGalleryFailure _transport(String step, DioException error) {
  if (CancelToken.isCancel(error)) {
    return const CanvasGalleryFailure('cancelled');
  }
  _log.warning(
    '$step transport=${error.type.name} status=${error.response?.statusCode}',
  );
  return CanvasGalleryFailure('network', status: error.response?.statusCode);
}

Map<String, dynamic> _object(Object? value) =>
    Map<String, dynamic>.from(value as Map);
String _string(Map<String, dynamic> data, String key) => data[key] as String;
int _integer(Map<String, dynamic> data, String key) => data[key] as int;
DateTime _date(Map<String, dynamic> data, String key) =>
    DateTime.parse(_string(data, key));

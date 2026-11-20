// 职责: 从应用网络设置装配画廊客户端。
// 关联文件:
//   lib/shared/services/canvas_gallery/service.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/app_config.dart

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_config.dart';
import '../services/canvas_gallery/service.dart';
import '../services/proxy_client.dart';
import 'settings_providers.dart';

final canvasGalleryServiceProvider = Provider<CanvasGalleryService>((ref) {
  return CanvasGalleryService(
    apiOrigin: Uri.parse(anonymousReportingBaseUrl),
    publicOrigin: Uri.parse('https://gallery.reveric.app'),
    createClient: () async {
      final settings = await ref.read(appSettingsProvider.future);
      return createProxyDioClient(
        settings.networkProxy,
        options: BaseOptions(connectTimeout: const Duration(seconds: 15)),
      );
    },
  );
});

// 职责: 为主动诊断上传提供按当前通用代理设置创建的 HTTP 客户端。
// 关联文件:
//   lib/shared/services/anonymous_file_service.dart
//   lib/shared/services/proxy_client.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/app_config.dart
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/io_client.dart';
import '../app_config.dart';
import '../services/anonymous_file_service.dart';
import '../services/proxy_client.dart';
import 'settings_providers.dart';

// 两个反馈入口共用服务；每次上传独占客户端，设置变更只影响后续上传。
final anonymousUploadServiceProvider = Provider<AnonymousFileService>((ref) {
  return AnonymousFileService(
    baseUrl: diagnosticsBaseUrl,
    createClient: () async {
      final settings = await ref.read(appSettingsProvider.future);
      if (!ref.mounted) {
        throw StateError('Diagnostic upload provider disposed');
      }
      return IOClient(await createProxyHttpClient(settings.networkProxy));
    },
  );
});

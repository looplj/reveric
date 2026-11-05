// 职责: 启动时按已保存的 PureFox Media 配置重新登记型号目录，并向依赖型号能力的界面暴露完成信号。
// 关联文件:
//   lib/shared/services/ai/purefox_media.dart
//   lib/shared/providers/settings_providers.dart
//   lib/main.dart
//   lib/desktop/features/production/composer.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../services/ai/purefox_media.dart';
import 'settings_providers.dart';

/// 测试可替换的 HTTP 客户端；默认由各供应商配置自行创建并关闭。
final purefoxMediaHttpClientProvider = Provider<http.Client?>((ref) => null);

/// 型号能力只存在内存目录，冷启动后为空。这里在设置加载完成后按已保存配置
/// 重新拉取并登记；同一进程只执行一次。
///
/// 只读取一次设置而不 watch：配置每次按键都会写回，watch 会把每次编辑变成一次
/// `/v1/models` 请求。之后新增或变更的配置由设置页的「获取模型」刷新。
///
/// 单个供应商的失败在 service 内记录，界面照常可用。
final purefoxMediaModelsProvider = FutureProvider<void>((ref) async {
  final settings = await ref.read(appSettingsProvider.future);
  await ensurePurefoxMediaModelsRegistered(
    settings.aiSettings.providers,
    httpClient: ref.read(purefoxMediaHttpClientProvider),
  );
});

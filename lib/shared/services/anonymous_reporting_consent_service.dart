// 职责: 读写匿名诊断上报设置，不依赖 Drift。
// 关联文件:
//   lib/shared/providers/anonymous_reporting_providers.dart
//   lib/shared/logger/startup_failure_reporter.dart
//   lib/shared/services/device_id_service.dart

import 'package:shared_preferences/shared_preferences.dart';

/// 匿名诊断上报默认开启，用户保存的设置优先。
///
/// 存在 SharedPreferences 而非应用数据库：启动失败上报要在数据库不可用时也能判断，
/// 且同意属于本机决定，不随备份恢复迁移到其它设备。
class AnonymousReportingConsentService {
  const AnonymousReportingConsentService();

  static const _key = 'anonymous_reporting_consent';

  Future<bool> isGranted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? true;
  }

  Future<void> setGranted(bool granted) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, granted);
  }
}

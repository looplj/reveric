// 职责: 定义交互式分步引导的数据模型、供应商配置判定与 app_states 持久化读写。
// 关联文件:
//   lib/shared/widgets/guide/overlay.dart
//   lib/shared/widgets/guide/trigger.dart
//   lib/shared/services/app_initialization.dart
//   lib/shared/database/daos/app_state_dao.dart
//   lib/shared/models/ai_provider.dart
// 遵循的 Rules:
//   .agents/rules/code-style.md
//   .agents/rules/error-handling.md
import 'package:flutter/widgets.dart';

import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_provider.dart';
import '../../theme/theme.dart';

final _log = AppLogger.forModule('GuideTour');

/// 存储在 `app_states` 表中的引导完成记录前缀。
const guideTourStateKeyPrefix = 'guide_tour_seen.';

/// 各页面的交互式引导标识，对应 `app_states` 中独立的已完成键。
enum GuideTourId {
  home('home'),
  aiProviders('ai_providers'),
  modelSettings('model_settings');

  const GuideTourId(this.keySuffix);

  final String keySuffix;

  String get storageKey => '$guideTourStateKeyPrefix$keySuffix';
}

/// 分步引导中的单一步骤。
class GuideStep {
  const GuideStep({
    required this.id,
    required this.title,
    required this.description,
    this.targetKey,
    this.icon,
    this.primaryActionLabel,
    this.onPrimaryAction,
    this.onBeforeEnter,
    this.highlightPadding = 6.0,
    this.highlightRadius = RevericRadius.large,
  });

  final String id;

  /// 要高亮的目标控件；为空或当前未挂载时回退为居中卡片。
  final GlobalKey? targetKey;
  final String title;
  final String description;

  /// 可选 Phosphor 图标路径（来自 [RevericIcons]）。
  final String? icon;

  /// 可选额外跳转按钮（例如「去配置供应商」「去看看模型设置」）。
  final String? primaryActionLabel;
  final VoidCallback? onPrimaryAction;

  /// 进入该步骤前执行的可选准备动作（如展开面板）。
  final VoidCallback? onBeforeEnter;

  final double highlightPadding;
  final double highlightRadius;
}

/// 判断用户是否已经配置过任意 AI 供应商。
///
/// 内置供应商默认预置为 `enabled: false` 且 `apiKey: ''`，不计作已配置；
/// 只要用户填写过任一 API Key、或存在可用/已启用的供应商，即视为已配置。
bool hasConfiguredAiProvider(AiSettings settings) {
  return settings.allConfigs.any(
    (provider) =>
        provider.isValid ||
        provider.hasApiKey ||
        (provider.enabled && (provider.isCodex || provider.isPluginProvider)),
  );
}

Future<bool> hasSeenGuideTour(AppDatabase database, GuideTourId tourId) async {
  return database.appStateDao.has(tourId.storageKey);
}

Future<void> markGuideTourSeen(AppDatabase database, GuideTourId tourId) async {
  await database.appStateDao.set(
    key: tourId.storageKey,
    value: DateTime.now().toIso8601String(),
  );
}

Future<void> clearGuideTourRecords(AppDatabase database) async {
  try {
    final entries = await database.appStateDao.getAllByPrefix(
      guideTourStateKeyPrefix,
    );
    for (final key in entries.keys) {
      await database.appStateDao.remove(key);
    }
  } catch (error, stackTrace) {
    _log.error(
      '[DB] table=app_states operation=DELETE id=$guideTourStateKeyPrefix* error=$error',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

// 职责: 订阅供应商配置，让制作输入框在设置变更后保留草稿并更新模型候选。
// 关联文件:
//   lib/shared/database/daos/ai_provider_dao.dart
//   lib/desktop/features/production/audio_composer.dart
//   lib/desktop/features/production/image_composer.dart
//   lib/desktop/features/production/composer.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../database/app_database.dart';
import '../models/plugin/provider_registry.dart';

AsyncSnapshot<List<AiProvider>> useAiProviders(AppDatabase database) {
  useListenable(pluginProviderModels);
  return useStream(
    useMemoized(() => database.aiProviderDao.watchAll(), [database]),
  );
}

// 职责: 管理交互式引导的运行时调试开关，开启后强制触发引导且不写入真实已完成记录。
// 关联文件:
//   lib/shared/widgets/guide/trigger.dart
//   lib/shared/widgets/settings/debug_settings_section.dart
// 遵循的 Rules:
//   .agents/rules/code-style.md
//   .agents/rules/directory-structure.md
import 'package:flutter/foundation.dart';

/// 运行时调试开关：为 true 时忽略「已配置供应商」与「已看过引导」判断，
/// 每次进入支持引导的页面都会弹出引导，且调试期间不写入真实 `guide_tour_seen.*` 记录。
final ValueNotifier<bool> guideDebugForceShowNotifier = ValueNotifier<bool>(
  false,
);

bool get isGuideDebugForceShowEnabled => guideDebugForceShowNotifier.value;

void setGuideDebugForceShow(bool enabled) {
  if (guideDebugForceShowNotifier.value == enabled) {
    return;
  }
  guideDebugForceShowNotifier.value = enabled;
}

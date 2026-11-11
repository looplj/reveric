// 职责: 汇集当前制作区域的本地编辑离开检查，并在片段草稿被外部改写时让编辑浮层重载。
// 关联文件:
//   lib/desktop/features/production/composer.dart
//   lib/desktop/features/production/region.dart
//   lib/desktop/features/storyboard/inline_editor.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/widgets/screenplay/director_shell.dart';

class ProductionEditSession {
  Future<bool> Function()? leave;
  final guards = <Object, Future<bool> Function()>{};
  Future<bool> close() async {
    if (!(await leave?.call() ?? true)) {
      return false;
    }
    for (final guard in guards.values.toList()) {
      if (!await guard()) {
        return false;
      }
    }
    return true;
  }
}

class ProductionSceneActions {
  const ProductionSceneActions({
    this.ask,
    required this.openDirector,
    this.openEditing,
    this.uploadScript,
  });
  final void Function(String prompt)? ask;
  final ScreenplayDirectorOpen openDirector;
  final void Function()? openEditing;
  final Future<void> Function()? uploadScript;
}

String _draftKey(ProductionClipRow clip) => jsonEncode([
  clip.title,
  clip.prompt,
  clip.providerId,
  clip.modelId,
  clip.referenceMode,
  clip.durationMs,
  clip.ratio,
  clip.resolution,
  clip.inputs.map((i) => i.toJson()).toList(),
]);

/// 片段草稿被浮层以外（如 agent）改写时调用 [reload] 重新挂载编辑表单。
/// 本地还有没写完的改动时以本地为准，不打断输入。
/// 返回的 [sync] 在自己写库后调用，记下写入结果，免得把自己的保存当成外部改动。
({void Function(ProductionClipRow clip) sync}) useExternalDraftReload({
  required ProductionClipRow initial,
  required ProductionClipRow? latest,
  required bool Function() settled,
  required VoidCallback? reload,
}) {
  final known = useRef(_draftKey(initial));
  useEffect(() {
    final key = latest == null || latest.id != initial.id
        ? null
        : _draftKey(latest);
    if (key != null && key != known.value && settled()) {
      known.value = key;
      // effect 在 build 内执行，不能同步改父级状态。
      WidgetsBinding.instance.addPostFrameCallback((_) => reload?.call());
    }
    return null;
  }, [latest]);
  return (sync: (clip) => known.value = _draftKey(clip));
}

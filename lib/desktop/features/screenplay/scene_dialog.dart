// 职责: 从桌面场次列表打开共享场次属性编辑器。
// 关联文件:
//   lib/shared/widgets/screenplay/scene_properties.dart
//   lib/desktop/features/screenplay/scene_list.dart
//   lib/shared/models/screenplay.dart

import 'package:flutter/material.dart';
import '../../../shared/models/screenplay.dart';
import '../../../shared/widgets/screenplay/scene_properties.dart';

Future<void> showScreenplaySceneDialog(
  BuildContext context, {
  required String databasePath,
  required String novelId,
  required ScreenplaySceneSummary scene,
}) => showSceneProperties(
  context,
  novelId: novelId,
  databasePath: databasePath,
  episodeId: scene.episodeId,
  sceneId: scene.id,
);

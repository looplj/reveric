// 职责: 将制作节点持久视角接到共享查看器与节点级会话。
// 关联文件:
//   lib/desktop/features/production/node_card.dart
//   lib/shared/providers/production_panorama.dart
//   lib/shared/widgets/production/panorama/viewer.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../../shared/database/novel_content_database.dart';
import '../../../../shared/models/production/panorama.dart';
import '../../../../shared/providers/production_panorama.dart';
import '../../../../shared/services/production/canvas_service.dart';
import '../../../../shared/widgets/production/panorama/viewer.dart';

class ProductionPanoramaNode extends HookConsumerWidget {
  const ProductionPanoramaNode({
    super.key,
    required this.service,
    required this.node,
    required this.path,
    required this.selected,
    this.readOnly = false,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final String path;
  final bool selected;
  final bool readOnly;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(
      productionPanoramaProvider((
        service: service,
        nodeId: node.id,
        readOnly: readOnly,
      )),
    );
    final persisted = PanoramaView.fromStyle(node.style)!;
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          controller.restore(persisted);
        }
      });
      return null;
    }, [controller, persisted]);
    return PanoramaViewer(
      path: service.library.resolvePath(path),
      controller: controller,
      interactive: selected,
    );
  }
}

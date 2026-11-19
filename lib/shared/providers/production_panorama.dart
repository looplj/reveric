// 职责: 按制作画布节点共享轻量视角会话，随最后一个使用方释放并保存。
// 关联文件:
//   lib/shared/widgets/production/panorama/controller.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/desktop/features/production/view/panorama_node.dart
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../models/production/panorama.dart';
import '../services/production/canvas_service.dart';
import '../services/production/panorama_service.dart';
import '../widgets/production/panorama/controller.dart';

typedef ProductionPanoramaKey = ({
  ProductionCanvasService service,
  String nodeId,
  bool readOnly,
});
final productionPanoramaProvider = Provider.autoDispose
    .family<PanoramaController, ProductionPanoramaKey>((ref, key) {
      final controller = PanoramaController(
        initial: const PanoramaView(),
        save: key.readOnly
            ? (_) async {}
            : (view) => key.service.setPanoramaView(
                key.nodeId,
                view,
                onlyIfActive: true,
              ),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

final productionPanoramaServiceProvider = Provider.autoDispose
    .family<PanoramaService, ProductionCanvasService>(
      (ref, service) => PanoramaService(service),
    );

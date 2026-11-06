// 职责: 持有制作视图并上报当前子页面，供工作区外壳显示面包屑、浮窗及 AI 定位当前调度。
// 关联文件:
//   lib/desktop/features/production/region.dart
//   lib/desktop/widgets/sidebar/rail.dart
//   lib/desktop/features/editing/region.dart
//   lib/shared/widgets/screenplay/director_workspace.dart
//   lib/desktop/widgets/workspace/novel_workspace_panel.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'production_view.g.dart';

/// 制片页的三个视图：分镜和画布各占左栏一个入口，列表是画布节点的另一种排布。
enum ProductionViewMode { segments, canvas, grid }

/// 制片页当前视图，由左栏入口和制片页共同驱动。
///
/// 左栏写入目标视图，制片页监听后带着焦点切换；切换被拒（编辑未保存等）时
/// 制片页把状态写回实际视图。保活以便离开制片分区后再回来仍停在上次的视图。
@Riverpod(keepAlive: true)
class ProductionView extends _$ProductionView {
  @override
  ProductionViewMode build(String novelId) => ProductionViewMode.segments;

  void set(ProductionViewMode mode) {
    if (state == mode) {
      return;
    }
    state = mode;
  }
}

typedef ProductionSubpageContext = ({String label, String? stagingId});

/// 制片页里打开的剪辑或导演台；名称用于面包屑，调度 ID 用于 AI 上下文。
///
/// 按作品内容库路径区分：剪辑和导演台只持有路径。工作区外壳在制片分区时 watch 保活。
@riverpod
class ProductionSubpage extends _$ProductionSubpage {
  @override
  ProductionSubpageContext? build(String databasePath) => null;

  void set(ProductionSubpageContext? page) {
    // 子页面卸载时延后写入，外壳可能已经先释放了这个 provider。
    if (!ref.mounted || state == page) {
      return;
    }
    state = page;
  }

  void clear(ProductionSubpageContext page) {
    if (ref.mounted && state == page) {
      set(null);
    }
  }
}

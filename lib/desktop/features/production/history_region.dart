// 职责: 随制作画布挂载管理局部撤销记录，并向画布区域提供同一服务和历史实例。
// 关联文件:
//   lib/desktop/features/production/region.dart
//   lib/shared/services/production/canvas_history.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/database/app_database.dart' show Novel;
import '../../../shared/providers/storyboard.dart';
import '../../../shared/providers/production_media.dart';
import 'support.dart';
import 'text_inputs.dart';
import 'edit_session.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/services/production/canvas_history.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/widgets/screenplay/loading.dart';
export '../../../shared/services/production/canvas_history.dart';

class ProductionHistoryRegion extends HookConsumerWidget {
  const ProductionHistoryRegion({
    super.key,
    required this.novel,
    required this.episodeId,
    required this.child,
  });
  final Novel novel;
  final String episodeId;
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shots = ref.watch(
      storyboardServiceProvider(novel.contentDatabasePath!),
    );
    final library = ref.watch(mediaLibraryServiceProvider);
    final service = useMemoized(
      () => ProductionCanvasService(shots, library, novel.id),
      [shots, library, novel.id],
    );
    final session = useMemoized(ProductionEditSession.new, [
      service,
      episodeId,
    ]);
    final loaded = useFuture(
      useMemoized(() => service.ensureCanvas(episodeId), [service, episodeId]),
      preserveState: false,
    );
    final history = useMemoized(
      () =>
          loaded.hasData ? CanvasHistory(service.shots, loaded.data!.id) : null,
      [service, episodeId, loaded.data?.id],
    );
    useEffect(() => history?.dispose, [history]);
    if (loaded.hasError) {
      return Center(child: Text(context.t(LocaleKeys.productionFailed)));
    }
    if (!loaded.hasData) {
      return const ScreenplayLoading();
    }
    return ProductionHistoryScope(
      service: service,
      canvas: loaded.data!,
      history: history!,
      session: session,
      child: ProductionTextInputs(
        service: service,
        canvasId: loaded.data!.id,
        child: child,
      ),
    );
  }
}

class ProductionHistoryScope extends InheritedWidget {
  const ProductionHistoryScope({
    super.key,
    required this.service,
    required this.canvas,
    required this.history,
    this.session,
    required super.child,
  });
  final ProductionCanvasService service;
  final CanvasEntry canvas;
  final CanvasHistory history;
  final ProductionEditSession? session;
  static ProductionHistoryScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ProductionHistoryScope>();
  static ProductionHistoryScope of(BuildContext context) => maybeOf(context)!;
  @override
  bool updateShouldNotify(ProductionHistoryScope oldWidget) =>
      history != oldWidget.history ||
      service != oldWidget.service ||
      session != oldWidget.session;
}

/// 一个用户手势的组合写入；所有已有改动节点必须列入 nodeIds，新节点作为结果返回。
Future<T> recordProductionChange<T>(
  BuildContext context,
  Iterable<String> nodeIds,
  Future<T> Function() action,
) {
  final history = ProductionHistoryScope.maybeOf(context)?.history;
  return history == null
      ? action()
      : history.record('canvas', nodeIds: nodeIds, action: action);
}

/// 先保存参数草稿，再将一次输入关系修改独立记步；保存失败保留草稿并回滚数据。
Future<void> changeProductionInputs(
  BuildContext context,
  String nodeId,
  Future<bool> Function() save,
  VoidCallback change,
) async {
  final history = ProductionHistoryScope.maybeOf(context)?.history;
  await productionRun(context, () async {
    if (!await save() || !context.mounted) {
      return;
    }
    Future<void> apply() async {
      change();
      if (!await save()) {
        throw StateError('Input change could not be saved');
      }
    }

    if (history == null) {
      await apply();
    } else {
      await history.record('inputs', nodeIds: [nodeId], action: apply);
    }
  });
}

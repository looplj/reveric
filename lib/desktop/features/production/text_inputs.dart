// 职责: 隔离文本节点内容订阅，为生成表单提供即时提示词校验数据。
// 关联文件:
//   lib/desktop/features/production/history_region.dart
//   lib/desktop/features/production/composer.dart
//   lib/shared/services/production/canvas_service.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/performance.md
import 'package:collection/collection.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import '../../../shared/logger/app_logger.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/services/production/canvas_service.dart';

final _log = AppLogger.forModule('ProductionText');

class ProductionTextInputs extends HookWidget {
  const ProductionTextInputs({
    super.key,
    required this.service,
    required this.canvasId,
    required this.child,
  });
  final ProductionCanvasService service;
  final String canvasId;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final snapshot = useStream(
      useMemoized(
        () =>
            (service.db.select(service.db.canvasNodes)..where(
                  (t) =>
                      t.canvasId.equals(canvasId) &
                      t.type.equals(canvasNodeTypeText) &
                      t.deletedAt.equals(notDeletedSentinel),
                ))
                .watch()
                .map(
                  (nodes) => {
                    for (final node in nodes)
                      if (node.type == canvasNodeTypeText)
                        node.id: node.content,
                  },
                )
                .distinct(const DeepCollectionEquality().equals),
        [service, canvasId],
      ),
    );
    useEffect(() {
      if (snapshot.hasError) {
        _log.error(
          'Text input query failed',
          error: snapshot.error,
          stackTrace: snapshot.stackTrace,
        );
      }
      return null;
    }, [snapshot.error]);
    return ProductionTextInputScope(
      values: snapshot.data,
      error: snapshot.error,
      child: child,
    );
  }
}

class ProductionTextInputScope extends InheritedWidget {
  const ProductionTextInputScope({
    super.key,
    required this.values,
    this.error,
    required super.child,
  });
  final Map<String, String>? values;
  final Object? error;
  static bool hasError(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ProductionTextInputScope>()
          ?.error !=
      null;
  static Map<String, String>? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ProductionTextInputScope>()
      ?.values;
  @override
  bool updateShouldNotify(ProductionTextInputScope oldWidget) =>
      error != oldWidget.error ||
      !const DeepCollectionEquality().equals(values, oldWidget.values);
}

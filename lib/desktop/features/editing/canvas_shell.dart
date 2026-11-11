// 职责: 在独立画布和指定剪辑工程间整窗切换，校验节点归属并统一离开保存。
// 关联文件:
//   lib/desktop/features/editing/region.dart
//   lib/desktop/features/production/history_region.dart
//   lib/desktop/features/production/editing_node.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/database/app_database.dart' show Novel;
import '../production/history_region.dart';
import 'region.dart';

class CanvasEditingShell extends HookWidget {
  const CanvasEditingShell({
    super.key,
    required this.novel,
    required this.registerFlush,
    required this.builder,
  });
  final Novel novel;
  final ValueChanged<Future<void> Function()?> registerFlush;
  final Widget Function(ValueChanged<Future<void> Function()?> register)
  builder;
  @override
  Widget build(BuildContext context) {
    final service = ProductionHistoryScope.of(context).service;
    final editingId = useState<String?>(null);
    final canvasFlush = useRef<Future<void> Function()?>(null);
    final editingFlush = useRef<Future<void> Function()?>(null);
    final registration = useRef(registerFlush)..value = registerFlush;
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          registration.value(() async {
            await editingFlush.value?.call();
            await canvasFlush.value?.call();
          });
        }
      });
      return () => registration.value(null);
    }, [service]);
    Future<void> open(String nodeId) async {
      await canvasFlush.value?.call();
      await editingFlush.value?.call();
      final project = await service.requireEditingNode(nodeId);
      if (context.mounted) {
        editingId.value = project.id;
      }
    }

    return CanvasEditingScope(
      open: open,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: editingId.value != null,
            child: TickerMode(
              enabled: editingId.value == null,
              child: Offstage(
                offstage: editingId.value != null,
                child: builder((flush) => canvasFlush.value = flush),
              ),
            ),
          ),
          if (editingId.value case final id?)
            EditingRegion(
              key: ValueKey((novel.id, id)),
              novelId: novel.id,
              identity: (path: novel.contentDatabasePath!, episodeId: null),
              editingId: id,
              onClose: () => editingId.value = null,
              registerFlush: (flush) => editingFlush.value = flush,
            ),
        ],
      ),
    );
  }
}

class CanvasEditingScope extends InheritedWidget {
  const CanvasEditingScope({
    super.key,
    required this.open,
    required super.child,
  });
  final Future<void> Function(String nodeId) open;
  static CanvasEditingScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CanvasEditingScope>();
  @override
  bool updateShouldNotify(CanvasEditingScope oldWidget) =>
      open != oldWidget.open;
}

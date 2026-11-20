// 职责: 在制作画布之上承载导演台。
// 关联文件:
//   lib/shared/widgets/screenplay/director_host.dart
//   lib/desktop/features/production/region.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import '../../services/director/session.dart';
import '../director/viewport.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'director_export.dart';
import 'director_host.dart';
import 'director_workspace.dart' show ScreenplayDirectorRecognize;

/// [canvas] 是打开导演台的画布节点，导出结果可加入画布时传入。
typedef ScreenplayDirectorOpen =
    Future<void> Function(String stagingId, {ScreenplayDirectorCanvas? canvas});

typedef ScreenplayDirectorBuilder =
    Widget Function(
      ScreenplayDirectorOpen open,
      ValueChanged<Future<void> Function()?> registerFlush,
    );

class ScreenplayDirectorShell extends HookWidget {
  const ScreenplayDirectorShell({
    super.key,
    required this.novelId,
    required this.databasePath,
    this.navigationTarget,
    required this.registerFlush,
    required this.builder,
    this.recognize,
    this.viewportBuilder,
  });
  final String novelId;
  final String databasePath;
  final ScreenplayDirectorRecognize? recognize;
  @visibleForTesting
  final Widget Function(DirectorSession, ViewState)? viewportBuilder;
  final Object? navigationTarget;
  final ValueChanged<Future<void> Function()?> registerFlush;
  final ScreenplayDirectorBuilder builder;

  @override
  Widget build(BuildContext context) {
    final opened = useState<({String id, ScreenplayDirectorCanvas? canvas})?>(
      null,
    );
    useEffect(() {
      // The host commits this navigation identity only after its registered close guard succeeds.
      opened.value = null;
      return null;
    }, [navigationTarget]);
    final documentFlush = useRef<Future<void> Function()?>(null);
    final directorFlush = useRef<Future<void> Function()?>(null);
    final register = useRef(registerFlush)..value = registerFlush;
    useEffect(() {
      register.value(() async {
        await directorFlush.value?.call();
        await documentFlush.value?.call();
      });
      return () => register.value(null);
    }, const []);
    final open = useCallback<ScreenplayDirectorOpen>((id, {canvas}) async {
      FocusManager.instance.primaryFocus?.unfocus();
      opened.value = (id: id, canvas: canvas);
    }, const []);
    final current = opened.value;
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: current != null,
          child: TickerMode(
            enabled: current == null,
            child: Offstage(
              offstage: current != null,
              child: builder(open, (flush) => documentFlush.value = flush),
            ),
          ),
        ),
        if (current != null)
          ScreenplayDirectorHost(
            key: ValueKey(current.id),
            novelId: novelId,
            databasePath: databasePath,
            stagingId: current.id,
            canvas: current.canvas,
            onClose: () => opened.value = null,
            registerFlush: (flush) => directorFlush.value = flush,
            recognize: recognize,
            viewportBuilder: viewportBuilder,
          ),
      ],
    );
  }
}

// 职责: 在导演页面存活期间加载、持有并释放共享编辑会话。
// 关联文件:
//   lib/shared/services/director/session.dart
//   lib/shared/widgets/screenplay/director_host.dart
//   lib/shared/widgets/director/workspace.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules: .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_placeholder.dart';
import '../../logger/app_logger.dart';
import '../../services/director/session.dart';
import '../../theme/theme.dart';
import 'strings.dart';

final _log = AppLogger.forModule('DirectorSession');

class DirectorSessionHost extends HookWidget {
  const DirectorSessionHost({
    super.key,
    required this.sessionLoader,
    required this.onClose,
    required this.builder,
  });
  /// 宿主先准备所用视口的依赖，再加载会话；自定义视口不需要默认 GPU 资源。
  final Future<DirectorSession> Function() sessionLoader;
  final VoidCallback onClose;
  final Widget Function(BuildContext, DirectorSession) builder;
  @override
  Widget build(BuildContext context) {
    final future = useMemoized(sessionLoader, [sessionLoader]);
    final result = useFuture(future), owned = useRef<DirectorSession?>(null);
    useEffect(() {
      var disposed = false;
      future.then(
        (session) {
          if (disposed) {
            session.dispose();
          } else {
            owned.value = session;
          }
        },
        onError: (Object error, StackTrace stack) {
          _log.error(
            'director initialization failed type=${error.runtimeType}',
            stackTrace: stack,
          );
        },
      );
      return () {
        disposed = true;
        owned.value?.dispose();
      };
    }, [future]);
    final session = result.data;
    if (session != null) {
      return builder(context, session);
    }
    return Center(
      child: result.hasError
          ? RevericPlaceholder.error(
              title: tr(context, 'operation_failed'),
              action: RevericButton.secondary(
                label: tr(context, 'back'),
                onPressed: onClose,
              ),
            )
          : Text(
              tr(context, 'loading'),
              style: RevericTheme.typographyOf(context).ui,
            ),
    );
  }
}

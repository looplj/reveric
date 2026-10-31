// 职责: 展示插件页面的加载/失败状态，并将宿主尺寸、主题和前后台环境送入页面运行时。
// 关联文件:
//   lib/shared/services/plugins/ui_session.dart
//   lib/shared/widgets/plugin_view/tree_view.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../components/reveric_placeholder.dart';
import '../../components/reveric_spinner.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../services/plugins/ui_session.dart';
import '../../theme/theme.dart';
import 'tree_view.dart';

class PluginUiSurface extends StatelessWidget {
  const PluginUiSurface({
    super.key,
    required this.session,
    this.visible = true,
  });
  final PluginUiSession session;
  final bool visible;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) => _SurfaceBody(
      session: session,
      width: size.maxWidth,
      height: size.maxHeight,
      visible: visible,
    ),
  );
}

class _SurfaceBody extends HookWidget {
  const _SurfaceBody({
    required this.session,
    required this.width,
    required this.height,
    required this.visible,
  });
  final PluginUiSession session;
  final double width, height;
  final bool visible;
  @override
  Widget build(BuildContext context) {
    final lifecycle = useAppLifecycleState();
    final error = useValueListenable(session.error),
        ready = useValueListenable(session.ready);
    final theme = Theme.of(context),
        locale = Localizations.localeOf(context).toLanguageTag();
    final active =
        visible &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    useEffect(
      () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            unawaited(
              session.setEnvironment({
                'width': width.isFinite ? width : 0,
                'height': height.isFinite ? height : 0,
                'platform': theme.platform.name.toLowerCase(),
                'theme': theme.brightness.name,
                'locale': locale,
                'visible': active,
              }),
            );
          }
        });
        return null;
      },
      [
        session,
        width,
        height,
        theme.platform,
        theme.brightness,
        locale,
        active,
      ],
    );
    if (error != null) {
      return RevericPlaceholder.error(
        title: context.t(LocaleKeys.settingsPluginsViewFailed),
      );
    }
    if (!ready) {
      return Center(
        child: SizedBox.square(
          dimension: RevericSizes.placeholderIconSize,
          child: RevericSpinner(color: RevericTheme.colorsOf(context).accent),
        ),
      );
    }
    return TickerMode(
      enabled: active,
      child: PluginUiTreeView(tree: session.tree, onEvent: session.dispatch),
    );
  }
}

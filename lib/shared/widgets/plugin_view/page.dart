// 职责: 承载独立插件页面，按协议挂载界面并处理导航、草稿确认与页面资源释放。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/page_session.dart
//   lib/shared/providers/plugin_providers.dart
//   lib/desktop/widgets/desktop_window_frame.dart
//   lib/desktop/pages/home.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/desktop-window-frame.md
//   .agents/rules/design-system.md
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../desktop/widgets/desktop_window_frame.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_dialog.dart';
import '../../components/reveric_icon_button.dart';
import '../../components/reveric_placeholder.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../models/plugin/view.dart';
import '../../providers/plugin_providers.dart';
import '../../services/plugins/a2ui_session.dart';
import '../../services/plugins/page_session.dart';
import '../../services/plugins/ui_session.dart';
import '../../theme/theme.dart';
import '../a2ui/components/display.dart' show a2uiIconAssets;
import '../a2ui/surface_view.dart';
import '../app_background.dart';
import 'surface.dart';
import 'host_ui.dart';
import '../../services/plugins/runtime.dart';

final _log = AppLogger.forModule('PluginPage');

/// 插件页面在宿主导航和页头中使用的统一图标，与“设置 / 插件”保持一致。
const pluginPageIcon = RevericIcons.layers_outlined;

Future<void> openPluginPage(
  BuildContext context,
  PluginView view, {
  String? workId,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => PluginPage(view: view, workId: workId),
  ),
);

typedef _PluginPageState = ({
  Widget content,
  ValueListenable<bool> dirty,
  Future<bool> Function() discard,
});

/// 打开并持有一个插件页面会话；页面外壳只负责页头、导航与关闭确认。
_PluginPageState _usePluginPage(
  BuildContext context,
  WidgetRef ref, {
  required PluginView view,
  required String? workId,
  required bool visible,
  required void Function(PluginView target) openView,
  required VoidCallback onUnavailable,
}) {
  final host = ref.watch(pluginHostServiceProvider);
  ref.watch(pluginStatusesProvider);
  final page = useState<PluginPageSession?>(null);
  final failed = useState(false);
  final confirming = useRef(false);
  final openViewRef = useRef(openView);
  openViewRef.value = openView;
  final unavailableRef = useRef(onUnavailable);
  unavailableRef.value = onUnavailable;
  final ui = useMemoized(
    () => PluginPageUi(context, (viewId) async {
      final target = host.views
          .where(
            (candidate) =>
                candidate.pluginId == view.pluginId && candidate.id == viewId,
          )
          .firstOrNull;
      if (target == null) {
        throw PluginHostError('unavailable', 'View is not registered: $viewId');
      }
      openViewRef.value(target);
    }),
    [host, view, workId],
  );
  useEffect(() => ui.close, [ui]);
  Future<bool> discard() async {
    if (!context.mounted || confirming.value) {
      return false;
    }
    confirming.value = true;
    try {
      return await showRevericDialog<bool>(
            context: context,
            builder: (dialog) => RevericDialog(
              title: context.t(LocaleKeys.commonDiscardChanges),
              actions: [
                RevericButton.text(
                  label: context.t(LocaleKeys.commonCancel),
                  onPressed: () => Navigator.of(dialog).pop(false),
                ),
                RevericButton.danger(
                  label: context.t(LocaleKeys.commonDiscard),
                  onPressed: () => Navigator.of(dialog).pop(true),
                ),
              ],
            ),
          ) ==
          true;
    } finally {
      confirming.value = false;
    }
  }

  void dispose(PluginPageSession session) {
    if (session is PluginUiSession) {
      session.dispose();
    }
    if (session is PluginA2uiSession) {
      session.dispose();
    }
  }

  useEffect(() {
    var attached = true;
    PluginPageSession? owned;
    Future<void>(() async {
      try {
        final session = view.isTsx
            ? await host.openTsxView(
                view,
                workId: workId,
                confirmDiscard: discard,
                uiCall: ui.call,
                onClose: ui.close,
                iconNames: a2uiIconAssets.keys.toSet(),
              )
            : await host.openA2uiView(
                view,
                workId: workId,
                confirmDiscard: discard,
                uiCall: ui.call,
                onClose: ui.close,
              );
        owned = session;
        if (!attached) {
          dispose(session);
          return;
        }
        page.value = session;
      } catch (error, stack) {
        _log.error(
          'Failed to open ${view.pluginId}/${view.id}',
          error: error,
          stackTrace: stack,
        );
        if (attached) {
          failed.value = true;
        }
      }
    });
    return () {
      attached = false;
      final session = owned;
      if (session != null) {
        unawaited(session.close());
        WidgetsBinding.instance.addPostFrameCallback((_) => dispose(session));
      }
    };
  }, [host, view, workId]);
  final session = page.value;
  final pluginAvailable = host.statuses.any(
    (status) => status.id == view.pluginId && status.state == 'available',
  );
  useEffect(() {
    if (session?.closed == true && !pluginAvailable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          unavailableRef.value();
        }
      });
    }
    return null;
  }, [session, session?.closed, pluginAvailable]);
  final emptyDirty = useMemoized(() => ValueNotifier(false));
  useEffect(() => emptyDirty.dispose, [emptyDirty]);
  Widget content;
  if (failed.value) {
    content = RevericPlaceholder.error(
      title: context.t(LocaleKeys.pluginViewFailed),
    );
  } else if (session == null) {
    content = const Center(child: CircularProgressIndicator());
  } else if (session is PluginUiSession) {
    content = PluginUiSurface(session: session, visible: visible);
  } else {
    content = _A2uiPageBody(session: session as PluginA2uiSession);
  }
  return (
    content: content,
    dirty: session?.dirty ?? emptyDirty,
    discard: discard,
  );
}

/// 独立路由中的插件页面：工作区导航和移动端使用。
class PluginPage extends HookConsumerWidget {
  const PluginPage({super.key, required this.view, this.workId});
  final PluginView view;
  final String? workId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ModalRoute.of(context);
    final allowClose = useState(false);
    final confirming = useRef(false);
    final backKey = useMemoized(GlobalKey.new);
    final page = _usePluginPage(
      context,
      ref,
      view: view,
      workId: workId,
      visible: route?.isCurrent ?? true,
      openView: (target) =>
          unawaited(openPluginPage(context, target, workId: workId)),
      onUnavailable: () {
        if (route != null && route.isActive) {
          Navigator.of(context).removeRoute(route);
        }
      },
    );
    final dirty = useValueListenable(page.dirty);
    final platform = Theme.of(context).platform;
    final mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    final colors = RevericTheme.colorsOf(context);
    final Widget body;
    if (mobile) {
      body = Scaffold(
        appBar: AppBar(
          title: Text(
            view.title.resolve(Localizations.localeOf(context)),
            overflow: TextOverflow.ellipsis,
            style: RevericTheme.typographyOf(
              context,
            ).uiSemibold.copyWith(color: colors.textPrimary),
          ),
        ),
        body: SafeArea(top: false, child: page.content),
      );
    } else {
      body = Scaffold(
        backgroundColor: appScaffoldBackgroundColor(
          colors,
          ref.watch(appBackgroundActiveProvider),
        ),
        body: DesktopWindowFrame(
          titleBarGestureExclusionKeys: [backKey],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PluginPageHeader(
                title: view.title.resolve(Localizations.localeOf(context)),
                // 返回按钮与标题同处左侧，Windows 无需下移右侧操作区。
                leadingInset: platform == TargetPlatform.macOS
                    ? DesktopWindowFrame.macosTrafficLightWidth
                    : RevericSpacing.lg,
                trailingInset:
                    RevericSpacing.lg + DesktopWindowFrame.trailingInset,
                backKey: backKey,
                onBack: () => Navigator.of(context).maybePop(),
              ),
              Expanded(child: page.content),
            ],
          ),
        ),
      );
    }
    return PopScope<void>(
      canPop: !dirty || allowClose.value,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || confirming.value) {
          return;
        }
        confirming.value = true;
        try {
          if (await page.discard() && context.mounted) {
            allowClose.value = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            });
          }
        } finally {
          confirming.value = false;
        }
      },
      child: body,
    );
  }
}

/// 嵌入桌面首页内容区的插件页面；离开前的草稿确认由首页统一处理。
class PluginPageRegion extends HookConsumerWidget {
  const PluginPageRegion({
    super.key,
    required this.view,
    required this.onOpenView,
    required this.onUnavailable,
    required this.onRegisterHasChanges,
    this.headerTrailingInset = 0,
  });
  final PluginView view;
  final ValueChanged<PluginView> onOpenView;
  final VoidCallback onUnavailable;
  final ValueChanged<bool Function()> onRegisterHasChanges;
  final double headerTrailingInset;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(pluginHostServiceProvider);
    ref.watch(pluginStatusesProvider);
    // 插件更新后注册项会换成新实例，按身份取当前注册项并重新挂载会话。
    final current = host.views
        .where(
          (candidate) =>
              candidate.pluginId == view.pluginId && candidate.id == view.id,
        )
        .firstOrNull;
    final unavailableRef = useRef(onUnavailable);
    unavailableRef.value = onUnavailable;
    useEffect(() {
      if (current == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            unavailableRef.value();
          }
        });
      }
      return null;
    }, [current == null]);
    final colors = RevericTheme.colorsOf(context);
    return Container(
      color: appScaffoldBackgroundColor(
        colors,
        ref.watch(appBackgroundActiveProvider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PluginPageHeader(
            title: view.title.resolve(Localizations.localeOf(context)),
            leadingInset: RevericSpacing.x2l,
            trailingInset: RevericSpacing.lg + headerTrailingInset,
          ),
          Expanded(
            child: current == null
                ? const SizedBox.shrink()
                : _PluginPageRegionBody(
                    key: ObjectKey(current),
                    view: current,
                    onOpenView: onOpenView,
                    onUnavailable: onUnavailable,
                    onRegisterHasChanges: onRegisterHasChanges,
                  ),
          ),
        ],
      ),
    );
  }
}

class _PluginPageRegionBody extends HookConsumerWidget {
  const _PluginPageRegionBody({
    super.key,
    required this.view,
    required this.onOpenView,
    required this.onUnavailable,
    required this.onRegisterHasChanges,
  });
  final PluginView view;
  final ValueChanged<PluginView> onOpenView;
  final VoidCallback onUnavailable;
  final ValueChanged<bool Function()> onRegisterHasChanges;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = _usePluginPage(
      context,
      ref,
      view: view,
      workId: null,
      visible: ModalRoute.of(context)?.isCurrent ?? true,
      openView: onOpenView,
      onUnavailable: onUnavailable,
    );
    final dirty = useRef(page.dirty);
    dirty.value = page.dirty;
    final registerRef = useRef(onRegisterHasChanges);
    registerRef.value = onRegisterHasChanges;
    useEffect(() {
      registerRef.value(() => dirty.value.value);
      return null;
    }, const []);
    return page.content;
  }
}

/// 与首页管理页一致的页头：标题留在标题栏高度内，只有左侧返回入口。
class _PluginPageHeader extends StatelessWidget {
  const _PluginPageHeader({
    required this.title,
    required this.leadingInset,
    required this.trailingInset,
    this.backKey,
    this.onBack,
  });
  final String title;
  final double leadingInset;
  final double trailingInset;
  final GlobalKey? backKey;
  final VoidCallback? onBack;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: DesktopWindowFrame.titleBarHeight,
          padding: EdgeInsets.only(left: leadingInset, right: trailingInset),
          child: Row(
            children: [
              if (onBack != null) ...[
                RevericIconButton(
                  key: backKey,
                  icon: RevericIcons.arrow_back,
                  tooltip: context.t(LocaleKeys.commonBack),
                  onPressed: onBack,
                ),
                const SizedBox(width: RevericSpacing.xs),
              ],
              RevericIcon(pluginPageIcon, size: 18, color: colors.accent),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: typo.heading2.copyWith(color: colors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
        ),
        Divider(height: RevericSizes.dividerThickness, color: colors.border),
      ],
    );
  }
}

class _A2uiPageBody extends HookWidget {
  const _A2uiPageBody({required this.session});
  final PluginA2uiSession session;
  @override
  Widget build(BuildContext context) {
    final error = useValueListenable(session.actionError);
    return Column(
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(RevericSpacing.md),
            child: Text(
              context.t(LocaleKeys.pluginViewFailed),
              style: RevericTheme.typographyOf(
                context,
              ).ui.copyWith(color: RevericTheme.colorsOf(context).warningText),
            ),
          ),
        Expanded(child: A2uiSurfaceView(session: session.surface)),
      ],
    );
  }
}

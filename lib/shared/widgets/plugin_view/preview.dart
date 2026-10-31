// 职责: 在现有调试入口运行真实 TSX 示例，验证原生状态、输入及关闭时的草稿确认。
// 关联文件:
//   lib/shared/widgets/plugin_view/surface.dart
//   lib/shared/services/plugins/ui_session.dart
//   assets/plugin_preview/counter.js
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../components/reveric_dialog.dart';
import '../../components/reveric_icon_button.dart';
import '../../components/reveric_button.dart';
import '../../models/plugin/ui_tree.dart';
import '../../services/plugins/ui_session.dart';
import '../../services/plugins/runtime.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../theme/theme.dart';
import '../a2ui/components/display.dart' show a2uiIconAssets;
import 'surface.dart';

Future<void> showPluginUiPreview(BuildContext context) async {
  if ([
    TargetPlatform.android,
    TargetPlatform.iOS,
  ].contains(Theme.of(context).platform)) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(context.t(LocaleKeys.settingsPluginsPreviewTitle)),
          ),
          body: const SafeArea(top: false, child: PluginUiPreviewPanel()),
        ),
      ),
    );
  } else {
    await showRevericDialog<void>(
      context: context,
      builder: (context) => RevericDialog.panel(
        width: 1040,
        title: Row(
          children: [
            Expanded(
              child: Text(context.t(LocaleKeys.settingsPluginsPreviewTitle)),
            ),
            RevericIconButton(
              icon: RevericIcons.close,
              tooltip: context.t(LocaleKeys.commonClose),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
        content: SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: const PluginUiPreviewPanel(),
        ),
      ),
    );
  }
}

class PluginUiPreviewPanel extends HookWidget {
  const PluginUiPreviewPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final session = useMemoized(
      () => PluginUiSession(
        tree: PluginUiTree(
          surface: 'preview-${DateTime.now().microsecondsSinceEpoch}',
          generation: 1,
          iconNames: a2uiIconAssets.keys.toSet(),
        ),
        hostCall: (method, args) async {
          if (method == 'storage.get' && args['key'] == 'preview.delay') {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return null;
          }
          throw PluginHostError(
            'unavailable',
            'Preview does not implement $method',
          );
        },
      ),
      const [],
    );
    final dirty = useValueListenable(session.dirty),
        allowClose = useState(false),
        confirming = useRef(false);
    useEffect(() {
      Future(() async {
        try {
          final source = await rootBundle.loadString(
            'assets/plugin_preview/counter.js',
          );
          await session.start(
            source: source,
            scope: {
              'plugin': {'id': 'reveric.preview', 'version': '1.0.0'},
              'request': {
                'requestId': session.tree.surface,
                'sessionId': session.tree.surface,
                'workId': null,
                'agentId': 'preview',
                'mode': 'preview',
              },
            },
            environment: {},
          );
        } catch (error, stack) {
          session.fail(error, stack);
        }
      });
      return () => WidgetsBinding.instance.addPostFrameCallback(
        (_) => session.dispose(),
      );
    }, [session]);
    return PopScope<void>(
      canPop: !dirty || allowClose.value,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || confirming.value) {
          return;
        }
        confirming.value = true;
        final discard = await showRevericDialog<bool>(
          context: context,
          builder: (context) => RevericDialog(
            title: context.t(LocaleKeys.commonDiscardChanges),
            actions: [
              RevericButton.text(
                label: context.t(LocaleKeys.commonCancel),
                onPressed: () => Navigator.of(context).pop(false),
              ),
              RevericButton.danger(
                label: context.t(LocaleKeys.commonDiscard),
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        );
        confirming.value = false;
        if (discard == true && context.mounted) {
          allowClose.value = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          });
        }
      },
      child: PluginUiSurface(session: session),
    );
  }
}

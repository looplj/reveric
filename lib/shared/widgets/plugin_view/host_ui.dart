// 职责: 将插件临时消息、确认和同插件页面导航映射为宿主控件，并在页面关闭时清理弹层。
// 关联文件:
//   lib/shared/widgets/plugin_view/page.dart
//   lib/shared/services/plugins/runtime.dart
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'package:flutter/material.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_dialog.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../services/plugins/runtime.dart';

class PluginPageUi {
  PluginPageUi(this.context, this.navigate);
  final BuildContext context;
  final Future<void> Function(String viewId) navigate;
  Route<dynamic>? _dialog;
  bool _closed = false;
  bool _showing = false;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _toast;
  String _text(
    Map<String, dynamic> args,
    String key,
    int max, {
    bool optional = false,
  }) {
    final value = args[key];
    if (value == null && optional) {
      return '';
    }
    if (value is! String || value.trim().isEmpty || value.length > max) {
      throw PluginHostError(
        'invalid_argument',
        'Invalid ui.$key (1–$max characters)',
      );
    }
    return value;
  }

  Future<Object?> call(String method, Map<String, dynamic> args) async {
    if (_closed ||
        !context.mounted ||
        ModalRoute.of(context)?.isCurrent != true) {
      throw PluginHostError('unavailable', 'Page is not visible');
    }
    switch (method) {
      case 'ui.toast':
        _toast?.close();
        _toast = ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_text(args, 'message', 4000))));
        return null;
      case 'ui.navigate':
        await navigate(_text(args, 'viewId', 64));
        return null;
      case 'ui.dialog':
        final title = _text(args, 'title', 200),
            message = _text(args, 'message', 10000, optional: true);
        if (_showing) {
          throw PluginHostError('busy', 'A dialog is already open');
        }
        _showing = true;
        try {
          return await showRevericDialog<bool>(
                context: context,
                builder: (dialog) {
                  _dialog = ModalRoute.of(dialog);
                  return RevericDialog(
                    title: title,
                    content: message.isEmpty ? null : Text(message),
                    actions: [
                      RevericButton.text(
                        label: dialog.t(LocaleKeys.commonCancel),
                        onPressed: () => Navigator.of(dialog).pop(false),
                      ),
                      RevericButton.primary(
                        label: dialog.t(LocaleKeys.commonConfirm),
                        onPressed: () => Navigator.of(dialog).pop(true),
                      ),
                    ],
                  );
                },
              ) ==
              true;
        } finally {
          _dialog = null;
          _showing = false;
        }
      default:
        throw PluginHostError('unavailable', 'Unknown UI operation: $method');
    }
  }

  void close() {
    _closed = true;
    _toast?.close();
    final dialog = _dialog;
    if (dialog?.isActive == true) {
      dialog!.navigator?.removeRoute(dialog);
    }
  }
}

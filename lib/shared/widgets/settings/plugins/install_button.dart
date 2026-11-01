// 职责: 从系统选择器读取并解析插件 ZIP，解析成功后交给安装预览。
// 关联文件:
//   lib/shared/services/plugins/package_archive.dart
//   lib/shared/widgets/settings/plugins/section.dart
//   lib/shared/widgets/settings/plugins/preview_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/file-access.md
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../components/reveric_button.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../services/plugins/package_archive.dart';
import '../../../theme/theme.dart';

final _log = AppLogger.forModule('PluginInstall');

class PluginInstallButton extends HookWidget {
  const PluginInstallButton({
    super.key,
    required this.onPicked,
    required this.onFailed,
  });

  final ValueChanged<PluginPackageArchive> onPicked;

  /// 选择或解析失败；取消选择不算失败。
  final VoidCallback onFailed;

  @override
  Widget build(BuildContext context) {
    final busy = useState(false);
    Future<void> select() async {
      busy.value = true;
      try {
        final file = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(
              label: 'ZIP',
              extensions: ['zip'],
              mimeTypes: ['application/zip'],
              uniformTypeIdentifiers: ['public.zip-archive'],
            ),
          ],
        );
        if (file == null) {
          return;
        }
        if (await file.length() > PluginPackageArchive.maxZipBytes) {
          throw const FormatException('Plugin ZIP exceeds 10 MB');
        }
        final parsed = await compute(
          PluginPackageArchive.decode,
          await file.readAsBytes(),
        );
        if (context.mounted) {
          onPicked(parsed);
        }
      } catch (error, stack) {
        _log.error(
          'Plugin package selection failed',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          onFailed();
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    return RevericButton.primary(
      icon: RevericIcons.add,
      label: context.t(LocaleKeys.commonInstall),
      loading: busy.value,
      onPressed: busy.value ? null : select,
    );
  }
}

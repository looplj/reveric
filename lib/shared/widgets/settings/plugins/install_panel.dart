// 职责: 从系统选择器读取插件包，展示身份与新增权限并在确认后安装。
// 关联文件:
//   lib/shared/services/plugins/installer.dart
//   lib/shared/services/plugins/package_archive.dart
//   lib/shared/providers/plugin_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/file-access.md
import '../../../services/plugins/runtime.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../components/reveric_button.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../providers/plugin_providers.dart';
import '../../../services/plugins/installer.dart';
import '../../../services/plugins/package_archive.dart';
import '../../../theme/theme.dart';

final _log = AppLogger.forModule('PluginInstall');

class PluginInstallPanel extends HookConsumerWidget {
  const PluginInstallPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidate = useState<PluginPackageArchive?>(null);
    final newPermissions = useState<Set<String>>({});
    final busy = useState(false);
    final failed = useState(false);
    final host = ref.watch(pluginHostServiceProvider);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    Future<void> select() async {
      busy.value = true;
      failed.value = false;
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
        final existing = await host.dao.grantedPermissions(parsed.manifest.id);
        if (context.mounted) {
          candidate.value = parsed;
          newPermissions.value = parsed.manifest.permissions.difference(
            existing,
          );
        }
      } catch (error, stack) {
        if (error is PluginHostError && error.code == 'cancelled') {
          return;
        }
        _log.error(
          'Plugin package selection failed',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          failed.value = true;
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    Future<void> install() async {
      final archive = candidate.value;
      if (archive == null) {
        return;
      }
      busy.value = true;
      failed.value = false;
      try {
        await PluginInstallOrchestrator().install(
          host: host,
          archive: archive,
          grantedPermissions: archive.manifest.permissions,
          temporaryRoot: await getTemporaryDirectory(),
        );
        if (context.mounted) {
          candidate.value = null;
        }
      } catch (error, stack) {
        if (error is PluginHostError && error.code == 'cancelled') {
          return;
        }
        _log.error(
          'Plugin installation failed',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          failed.value = true;
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    final archive = candidate.value;
    final locale = Localizations.localeOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RevericButton.secondary(
          label: context.t(LocaleKeys.settingsPluginsChoosePackage),
          onPressed: busy.value ? null : select,
          loading: busy.value && archive == null,
        ),
        if (archive != null) ...[
          const SizedBox(height: RevericSpacing.lg),
          Text(
            '${archive.manifest.name.resolve(locale)} · ${archive.manifest.version}',
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
          Text(
            archive.manifest.id,
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
          if (archive.manifest.description case final description?)
            Text(
              description.resolve(locale),
              style: typo.ui.copyWith(color: colors.textSecondary),
            ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(
              newPermissions.value.isEmpty
                  ? LocaleKeys.settingsPluginsNoNewPermissions
                  : LocaleKeys.settingsPluginsNewPermissions,
            ),
            style: typo.ui.copyWith(color: colors.textSecondary),
          ),
          for (final permission in newPermissions.value)
            Text(
              permission == 'ai.generateText'
                  ? context.t(LocaleKeys.settingsPluginsAiPermission)
                  : permission,
              style: typo.ui.copyWith(color: colors.textPrimary),
            ),
          const SizedBox(height: RevericSpacing.sm),
          Wrap(
            spacing: RevericSpacing.sm,
            children: [
              RevericButton.primary(
                label: context.t(LocaleKeys.commonInstall),
                onPressed: busy.value ? null : install,
                loading: busy.value,
              ),
              RevericButton.text(
                label: context.t(LocaleKeys.commonCancel),
                onPressed: busy.value ? null : () => candidate.value = null,
              ),
            ],
          ),
        ],
        if (failed.value)
          Text(
            context.t(LocaleKeys.settingsPluginsInstallFailed),
            style: typo.uiSmall.copyWith(color: colors.warningText),
          ),
      ],
    );
  }
}

// 职责: 本地插件的安装预览子页面 — 展示身份、新增权限、声明内容与工具，确认后授权并安装。
// 关联文件:
//   lib/shared/widgets/settings/plugins/subpage.dart
//   lib/shared/widgets/settings/plugins/permissions.dart
//   lib/shared/services/plugins/installer.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/package_archive.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/file-access.md
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../components/reveric_badge.dart';
import '../../../components/reveric_button.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../models/plugin/text.dart';
import '../../../providers/plugin_providers.dart';
import '../../../services/plugins/installer.dart';
import '../../../services/plugins/package_archive.dart';
import '../../../services/plugins/registry.dart';
import '../../../services/plugins/runtime.dart';
import '../../../theme/theme.dart';
import '../settings_section_widgets.dart';
import 'overview.dart';
import 'permissions.dart';
import 'subpage.dart';
import 'tools_section.dart';

final _log = AppLogger.forModule('PluginInstall');

class PluginPreviewPage extends HookConsumerWidget {
  const PluginPreviewPage({
    super.key,
    required this.archive,
    required this.mobile,
    required this.onClose,
    required this.onInstalled,
  });

  final PluginPackageArchive archive;
  final bool mobile;

  /// 放弃安装并返回列表。
  final VoidCallback onClose;

  /// 安装成功，参数为插件 id。
  final ValueChanged<String> onInstalled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(pluginHostServiceProvider);
    final manifest = archive.manifest;
    final installing = useState(false), failed = useState(false);
    final granted = useFuture(
      useMemoized(() => host.dao.grantedPermissions(manifest.id), [archive]),
    );
    // 预览需要执行插件的 apply 才能读到工具；apply 只能注册，不开放宿主 API。
    final tools = useFuture(
      useMemoized(
        () => host.previewTools(
          manifest,
          utf8.decode(archive.files[manifest.main]!),
        ),
        [archive],
      ),
    );
    useEffect(() {
      if (tools.error case final error?) {
        _log.error('Plugin preview failed: ${manifest.id}', error: error);
      }
      return null;
    }, [tools.error]);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final locale = Localizations.localeOf(context);
    final installed = host.statuses
        .where((status) => status.id == manifest.id)
        .firstOrNull;
    final newPermissions = granted.hasData
        ? manifest.permissions.difference(granted.requireData)
        : manifest.permissions;

    Future<void> install() async {
      installing.value = true;
      failed.value = false;
      try {
        await PluginInstallOrchestrator().install(
          host: host,
          archive: archive,
          grantedPermissions: manifest.permissions,
          temporaryRoot: await getTemporaryDirectory(),
        );
        if (context.mounted) {
          onInstalled(manifest.id);
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
          installing.value = false;
        }
      }
    }

    Widget entries(
      List<({String title, String? detail, Widget? badge})> rows,
    ) => SettingsCard(
      padding: EdgeInsets.zero,
      children: [
        for (final (index, row) in rows.indexed) ...[
          if (index > 0) const SettingsRowDivider(),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.lg,
              vertical: RevericSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: RevericSpacing.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      row.title,
                      style: typo.ui.copyWith(color: colors.textPrimary),
                    ),
                    ?row.badge,
                  ],
                ),
                if (row.detail case final detail? when detail.isNotEmpty) ...[
                  const SizedBox(height: RevericSpacing.xxs),
                  Text(
                    detail,
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
    String text(PluginText value) => value.resolve(locale);
    final ready = granted.hasData && tools.hasData;
    return PluginSubpage(
      title: text(manifest.name),
      mobile: mobile,
      onBack: installing.value ? null : onClose,
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          RevericButton.text(
            label: context.t(LocaleKeys.commonCancel),
            onPressed: installing.value ? null : onClose,
          ),
          const SizedBox(width: RevericSpacing.sm),
          RevericButton.primary(
            label: context.t(
              newPermissions.isEmpty
                  ? LocaleKeys.commonInstall
                  : LocaleKeys.pluginGrantAndInstall,
            ),
            loading: installing.value,
            onPressed: ready && !installing.value ? install : null,
          ),
        ],
      ),
      children: [
        PluginOverview(
          manifest: manifest,
          local: true,
          previousVersion: installed?.manifest?.version,
          notices: [
            PluginNotice(message: context.t(LocaleKeys.pluginUnreviewed)),
            if (failed.value)
              PluginNotice(message: context.t(LocaleKeys.pluginInstallFailed)),
          ],
        ),
        if (manifest.permissions.isNotEmpty)
          SettingsSection(
            titleKey: LocaleKeys.pluginPermissions,
            descriptionKey: newPermissions.isEmpty
                ? LocaleKeys.pluginNoNewPermissions
                : LocaleKeys.pluginGrantOnInstall,
            child: PluginPermissionList(
              permissions: manifest.permissions,
              highlighted: newPermissions,
            ),
          ),
        if (manifest.settings.isNotEmpty)
          SettingsSection(
            titleKey: LocaleKeys.pluginSettings,
            child: entries([
              for (final field in manifest.settings)
                (
                  title: text(field.title),
                  detail: field.description == null
                      ? null
                      : text(field.description!),
                  badge: field.required
                      ? RevericBadge(
                          label: context.t(LocaleKeys.commonRequired),
                          color: colors.warningText,
                        )
                      : null,
                ),
            ]),
          ),
        if (manifest.tasks.isNotEmpty)
          SettingsSection(
            titleKey: LocaleKeys.pluginTasks,
            child: entries([
              for (final task in manifest.tasks)
                (
                  title: text(task.title),
                  detail: _interval(context, task.intervalMinutes),
                  badge: null,
                ),
            ]),
          ),
        if (manifest.pages.isNotEmpty)
          SettingsSection(
            titleKey: LocaleKeys.pluginPages,
            child: entries([
              for (final page in manifest.pages)
                (title: text(page.title), detail: null, badge: null),
            ]),
          ),
        if (tools.hasError)
          PluginNotice(message: context.t(LocaleKeys.pluginPreviewToolsFailed))
        else if (!tools.hasData)
          const LinearProgressIndicator()
        else
          PluginToolsSection(
            tools: tools.requireData,
            emptyText: context.t(LocaleKeys.pluginPreviewNoTools),
            overriddenBy: (tool) => _conflict(host.registry, tool, locale),
          ),
      ],
    );
  }
}

/// 同名工具已由其他插件提供时返回该插件名称；同一插件升级不算冲突。
String? _conflict(PluginRegistry registry, PluginTool tool, Locale locale) {
  final owner = registry.resolve(tool.name);
  return owner == null || owner.pluginId == tool.pluginId
      ? null
      : owner.pluginName.resolve(locale);
}

String _interval(BuildContext context, int minutes) => minutes % 1440 == 0
    ? context.t(
        LocaleKeys.pluginTaskIntervalDays,
        namedArgs: {'count': '${minutes ~/ 1440}'},
      )
    : minutes % 60 == 0
    ? context.t(
        LocaleKeys.pluginTaskIntervalHours,
        namedArgs: {'count': '${minutes ~/ 60}'},
      )
    : context.t(
        LocaleKeys.pluginTaskIntervalMinutes,
        namedArgs: {'count': '$minutes'},
      );

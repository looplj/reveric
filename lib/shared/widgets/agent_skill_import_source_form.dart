// 职责: 提供本地文件夹、Markdown 文件与公开代码托管仓库链接的技能导入入口。
// 关联文件:
//   lib/shared/services/agent_skill_import_orchestrator.dart
//   lib/shared/services/agent_skill_import_source.dart
//   lib/shared/widgets/agent_skill_import_dialog.dart
//   lib/shared/providers/agent_skill_catalog_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/file-access.md

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../components/reveric_button.dart';
import '../components/reveric_text_field.dart';
import '../localization/app_localization.dart';
import '../localization/locale_keys.dart';
import '../logger/app_logger.dart';
import '../providers/agent_skill_catalog_providers.dart';
import '../services/agent_skill_import_orchestrator.dart';
import '../services/agent_skill_import_source.dart';
import '../services/agent_skill_transfer.dart';
import '../theme/theme.dart';

final _log = AppLogger.forModule('SkillImportSourceForm');

class AgentSkillImportSourceForm extends HookConsumerWidget {
  const AgentSkillImportSourceForm({
    super.key,
    required this.existingNames,
    required this.pickFiles,
    this.pickDirectory,
    required this.onDiscovered,
    this.padding = EdgeInsets.zero,
    this.initialUrl = '',
  });

  final Set<String> existingNames;
  final Future<List<AgentSkillImportCandidate>?> Function() pickFiles;
  final Future<List<AgentSkillImportCandidate>?> Function()? pickDirectory;
  final ValueChanged<List<AgentSkillImportCandidate>> onDiscovered;

  /// 弹窗正文已有内边距，保持默认 0；移动 sheet 传入与标题头对齐的内边距。
  final EdgeInsetsGeometry padding;
  final String initialUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ModalRoute.of(context);
    final url = useTextEditingController(text: initialUrl);
    final busy = useState(false);
    final errorKey = useState<String?>(null);
    final request = useRef<CancelToken?>(null);
    final client = useRef<Dio?>(null);
    useEffect(
      () => () {
        final token = request.value;
        if (token != null && !token.isCancelled) {
          token.cancel('Import closed');
        }
        client.value?.close(force: true);
      },
      [client],
    );

    Future<void> scan(
      Future<List<AgentSkillImportCandidate>?> Function() action,
    ) async {
      if (busy.value) {
        return;
      }
      busy.value = true;
      errorKey.value = null;
      try {
        final candidates = await action();
        if (!context.mounted ||
            route?.isCurrent == false ||
            candidates == null) {
          return;
        }
        if (candidates.isEmpty) {
          errorKey.value = LocaleKeys.agentSkillImportEmpty;
        } else {
          onDiscovered(candidates);
        }
      } catch (error, stackTrace) {
        _log.error(
          'skill source scan failed type=${error.runtimeType}',
          error: error is DioException ? error.type.name : error,
          stackTrace: stackTrace,
        );
        if (!context.mounted || route?.isCurrent == false) {
          return;
        }
        errorKey.value = switch (error) {
          AgentSkillImportLimitException() =>
            LocaleKeys.agentSkillImportTooLarge,
          AgentSkillImportUnavailableException() =>
            LocaleKeys.agentSkillImportUnavailable,
          DioException(response: final response)
              when response?.statusCode == 404 =>
            LocaleKeys.agentSkillImportUnavailable,
          DioException(response: final response)
              when response?.statusCode == 403 || response?.statusCode == 429 =>
            LocaleKeys.agentSkillImportRateLimited,
          DioException() ||
          TimeoutException() => LocaleKeys.agentSkillImportNetworkFailed,
          _ => LocaleKeys.agentSkillImportFailed,
        };
      } finally {
        if (context.mounted && route?.isCurrent != false) {
          busy.value = false;
        }
      }
    }

    void scanLink() {
      if (busy.value) {
        return;
      }
      final AgentSkillImportSource source;
      try {
        source = AgentSkillImportSource.parse(url.text);
      } on FormatException {
        errorKey.value = LocaleKeys.agentSkillImportInvalidUrl;
        return;
      }
      FocusScope.of(context).unfocus();
      final token = CancelToken();
      request.value = token;
      unawaited(
        scan(() async {
          final openClient = ref.read(skillHttpClientFactoryProvider);
          final acquired = await openClient();
          if (!context.mounted || token.isCancelled) {
            acquired.close(force: true);
            return null;
          }
          client.value = acquired;
          try {
            return await AgentSkillImportOrchestrator()
                .discover(
                  source: source,
                  existingNames: existingNames,
                  client: acquired,
                  cancelToken: token,
                  openPackageClient: openClient,
                )
                .timeout(
                  const Duration(minutes: 2),
                  onTimeout: () {
                    token.cancel('Import timed out');
                    throw TimeoutException('Repository scan timed out');
                  },
                );
          } finally {
            acquired.close(force: true);
            client.value = null;
          }
        }),
      );
    }

    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final sectionTitle = typo.uiSemibold.copyWith(color: colors.textPrimary);
    final hint = typo.uiSmall.copyWith(color: colors.textMuted);
    final pickers = [
      if (pickDirectory != null)
        RevericButton.secondary(
          label: context.t(LocaleKeys.agentSkillImportSelectFolder),
          icon: RevericIcons.folder_outlined,
          onPressed: busy.value ? null : () => unawaited(scan(pickDirectory!)),
        ),
      RevericButton.secondary(
        label: context.t(LocaleKeys.agentSkillImportSelectFile),
        icon: RevericIcons.file_text,
        onPressed: busy.value ? null : () => unawaited(scan(pickFiles)),
      ),
    ];
    return SingleChildScrollView(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.t(LocaleKeys.agentSkillImportLocal),
            style: sectionTitle,
          ),
          const SizedBox(height: RevericSpacing.sm),
          Row(
            children: [
              for (final (index, picker) in pickers.indexed) ...[
                if (index > 0) const SizedBox(width: RevericSpacing.sm),
                Expanded(child: picker),
              ],
            ],
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(context.t(LocaleKeys.agentSkillImportLocalHint), style: hint),
          const SizedBox(height: RevericSpacing.x2l),
          Divider(
            height: RevericSizes.dividerThickness,
            color: colors.borderSubtle,
          ),
          const SizedBox(height: RevericSpacing.x2l),
          Text(
            context.t(LocaleKeys.agentSkillImportRemote),
            style: sectionTitle,
          ),
          const SizedBox(height: RevericSpacing.sm),
          Row(
            children: [
              Expanded(
                child: RevericTextField(
                  controller: url,
                  hintText: context.t(
                    LocaleKeys.agentSkillImportUrlPlaceholder,
                  ),
                  height: RevericSizes.buttonHeight,
                  enabled: !busy.value,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => scanLink(),
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              RevericButton.primary(
                label: context.t(LocaleKeys.agentSkillImportScan),
                loading: busy.value,
                onPressed: busy.value ? null : scanLink,
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(context.t(LocaleKeys.agentSkillImportUrlHint), style: hint),
          if (errorKey.value != null) ...[
            const SizedBox(height: RevericSpacing.md),
            Semantics(
              liveRegion: true,
              child: Text(
                context.t(errorKey.value!),
                style: typo.uiSmall.copyWith(color: colors.error),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

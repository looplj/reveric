// 职责: 共享 AI provider 配置 — 已保存供应商面板与草稿共用的表单（API key / baseUrl / 代理 / 模型 / 温度），含获取模型 API 调用。
// 关联文件:
//   lib/shared/widgets/settings/provider_draft.dart
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/models/network_proxy.dart
//   lib/shared/components/reveric_text_field.dart
//   lib/shared/localization/ai_provider_localization.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/theme/theme.dart
//   assets/translations/en/settings.json
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/zh-CN/provider.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/account.json
//   assets/translations/zh-CN/account.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../../../mobile/widgets/sheet.dart';
import '../../services/plugins/runtime.dart';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../components/dialog_feedback.dart';
import '../../components/reveric_search_field.dart';
import '../../components/reveric_switch.dart';
import '../../components/reveric_text_field.dart';
import '../../localization/ai_provider_localization.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import 'provider_overview.dart';
import 'provider_logo.dart';
import '../../models/ai_provider.dart';
import '../../services/ai/new_api.dart';
import '../../services/ai/purefox_media.dart';
import '../../models/network_proxy.dart';
import '../../models/image/channels.dart';
import '../../models/audio/channels.dart';
import '../../models/video/channels.dart';
import '../../agent/client/codex_client.dart';
import '../../services/ai/codex/credentials.dart';
import '../../providers/settings_providers.dart';
import '../../theme/theme.dart';
import '../../utils/text_input_composing.dart';
import 'ai_providers_section.dart';
import 'provider_actions.dart';
import 'provider_video_models.dart';
import 'provider_models_editor.dart';
import 'provider_audio_models.dart';
import 'plugins/config_form.dart';
import 'proxy_settings_section.dart';
import 'plugin_provider_fields.dart';
import 'codex_connection.dart';
import '../../components/reveric_dialog.dart';
import '../../components/reveric_button.dart';

final _log = AppLogger.forModule('ProviderModels');

typedef _SaveProviderChange =
    Future<void> Function(AiProvider Function(AiProvider));

/// 供应商配置面板引导锚点：凭证区（Base URL / API Key）、多模态模型区与启用开关。
class ProviderConfigGuideKeys {
  const ProviderConfigGuideKeys({
    required this.credentials,
    required this.models,
    required this.enableSwitch,
  });

  final GlobalKey credentials;
  final GlobalKey models;
  final GlobalKey enableSwitch;
}

/// 已保存供应商的配置面板：读取持久化配置，修改即时写回，头部提供启用开关与删除。
class ProviderConfigPanel extends ConsumerWidget {
  final String providerId;

  final VoidCallback? onDeleted;
  final ProviderConfigGuideKeys? guideKeys;

  const ProviderConfigPanel({
    super.key,
    required this.providerId,

    this.onDeleted,
    this.guideKeys,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsNotifier = ref.read(appSettingsProvider.notifier);
    final config = ref.watch(aiSettingsProvider).findConfigById(providerId);

    if (config == null) {
      return const SizedBox.shrink();
    }

    return ProviderConfigForm(
      key: ValueKey(config.id),
      config: config,
      onChanged: settingsNotifier.setAiProviderConfig,
      badge: StatusBadge(isValid: config.isValid),
      guideKeys: guideKeys,
      headerActions: [
        KeyedSubtree(
          key: guideKeys?.enableSwitch,
          child: RevericSwitch(
            value: config.enabled,
            onChanged:
                (!config.isTypeSupported && !config.isPluginProvider) ||
                    !config.isPlatformSupported
                ? null
                : (v) async {
                    final validationMessage = config.enableValidationMessage;
                    if (v &&
                        !config.isPluginProvider &&
                        validationMessage != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: DialogToast(
                            variant: DialogToastVariant.warning,
                            child: Text(validationMessage),
                          ),
                        ),
                      );
                      return;
                    }
                    try {
                      await settingsNotifier.toggleAiProviderEnabled(
                        config.id,
                        v,
                      );
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              context.t(LocaleKeys.commonSaveFailed),
                            ),
                          ),
                        );
                      }
                    }
                  },
          ),
        ),
        ProviderActionsMenu(
          config: config,
          onDelete: () => _confirmDelete(context, ref, config: config),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref, {
    required AiProvider config,
  }) async {
    final notifier = ref.read(appSettingsProvider.notifier);
    final deleted = await confirmDeleteProvider(
      context,
      config: config,
      onDelete: () => notifier.removeProvider(config.id),
    );
    if (deleted && context.mounted) {
      onDeleted?.call();
    }
  }
}

/// 供应商配置表单：已保存供应商与新建草稿共用，每次修改都交给 [onChanged]。
///
/// [isDraft] 表示尚未落库的新建表单；供应商类型始终只读。
class ProviderConfigForm extends HookWidget {
  const ProviderConfigForm({
    super.key,
    required this.config,
    required this.onChanged,
    required this.badge,
    required this.headerActions,
    this.isDraft = false,
    this.pluginDraftController,
    this.guideKeys,
  });

  final AiProvider config;
  final Future<void> Function(AiProvider config) onChanged;
  final Widget badge;
  final List<Widget> headerActions;
  final bool isDraft;
  final PluginConfigDraftController? pluginDraftController;
  final ProviderConfigGuideKeys? guideKeys;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final config = this.config;

    final providerName = localizedAiProviderName(context, config);
    final latestConfig = useRef(config);
    final pendingSave = useRef(Future<void>.value());
    useEffect(() {
      latestConfig.value = config;
      return null;
    }, [config]);

    Future<void> saveChange(AiProvider Function(AiProvider) change) =>
        pendingSave.value = pendingSave.value.then((_) async {
          final previous = latestConfig.value;
          try {
            final next = change(previous);
            await onChanged(next);
            if (identical(latestConfig.value, previous)) {
              latestConfig.value = next;
            }
          } catch (error) {
            _log.warning(
              'Provider configuration save failed id=${previous.id} '
              'type=${error.runtimeType}',
            );
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
              );
            }
          }
        });

    final apiKeyController = _useProviderText(
      config.apiKey,
      (value) => saveChange((current) => current.copyWith(apiKey: value)),
    );
    final baseUrlController = _useProviderText(
      config.isTypeSupported ? config.effectiveBaseUrl : config.baseUrl,
      (value) => saveChange((current) => current.copyWith(baseUrl: value)),
    );
    final nameController = _useProviderText(
      config.name,
      (value) => saveChange((current) => current.copyWith(name: value)),
    );
    final builtinBaseUrl = aiProviderBuiltinById(config.id)?.baseUrl;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.x4l,
            vertical: RevericSpacing.lg,
          ),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: Row(
            children: [
              ProviderLogo(type: config.type),
              const SizedBox(width: RevericSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: RevericSpacing.sm,
                      runSpacing: RevericSpacing.xxs,
                      children: [
                        Text(
                          providerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.uiSemibold.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        badge,
                      ],
                    ),
                    if (!config.isTypeSupported ||
                        providerName !=
                            localizedProviderTypeName(
                              context,
                              config.type,
                            )) ...[
                      const SizedBox(height: RevericSpacing.xxs),
                      Row(
                        children: [
                          Text(
                            config.isTypeSupported
                                ? localizedProviderTypeName(
                                    context,
                                    config.type,
                                  )
                                : config.type,
                            style: typo.uiSmall.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              ...headerActions,
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(RevericSpacing.x4l),
            child: !config.isTypeSupported && !config.isPluginProvider
                ? Text(
                    context.t(
                      LocaleKeys.providerTypeUnsupported,
                      namedArgs: {'type': config.type},
                    ),
                    style: typo.ui.copyWith(color: colors.warningText),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildEditableConfig(
                        context,
                        colors,
                        typo,
                        config,
                        apiKeyController,
                        baseUrlController,
                        nameController,
                        builtinBaseUrl,
                        saveChange,
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildEditableConfig(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
    AiProvider config,
    TextEditingController apiKeyController,
    TextEditingController baseUrlController,
    TextEditingController nameController,
    String? builtinBaseUrl,
    _SaveProviderChange saveChange,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!config.isBuiltin) ...[
          _buildTextField(
            context: context,
            label: context.t(LocaleKeys.providerNameLabel),
            hint: context.t(LocaleKeys.providerNameHint),
            controller: nameController,
          ),
          const SizedBox(height: RevericSpacing.lg),
          _buildReadOnlyField(
            context: context,
            label: context.t(LocaleKeys.providerTypeLabel),
            value: localizedProviderTypeName(context, config.type),
          ),
          const SizedBox(height: RevericSpacing.xs),
        ],
        if (config.isPluginProvider)
          PluginProviderFields(
            config: config,
            isDraft: isDraft,
            draftController: pluginDraftController,
          )
        else ...[
          ProviderOverview(config: config),
          const SizedBox(height: RevericSpacing.x4l),
          Column(
            key: guideKeys?.credentials,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (config.hasFixedBaseUrl)
                _buildReadOnlyField(
                  context: context,
                  label: context.t(LocaleKeys.settingsAiBaseUrl),
                  value: config.effectiveBaseUrl,
                )
              else
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: baseUrlController,
                  builder: (context, value, _) {
                    final suggested = _baseUrlWithoutEndpoint(value.text);
                    return RevericTextField(
                      label: context.t(LocaleKeys.settingsAiBaseUrl),
                      hintText: config.isBuiltin
                          ? (builtinBaseUrl ?? '')
                          : 'https://api.example.com/v1',
                      controller: baseUrlController,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      inputFormatters: const [ProviderBaseUrlInputFormatter()],
                      errorText: suggested == value.text.trim()
                          ? null
                          : context.t(
                              LocaleKeys.providerBaseUrlEndpointHint,
                              namedArgs: {'url': suggested},
                            ),
                      errorMaxLines: 4,
                    );
                  },
                ),
              if (!config.hasBaseUrl) ...[
                const SizedBox(height: RevericSpacing.xs),
                Text(
                  context.t(LocaleKeys.providerConfigNeedBaseUrl),
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
              ],
              const SizedBox(height: RevericSpacing.lg),
              if (config.isCodex)
                CodexConnection(config: config)
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: _buildTextField(
                        context: context,
                        label: context.t(LocaleKeys.settingsAiApiKey),
                        hint: context.t(LocaleKeys.settingsAiApiKeyHint),
                        controller: apiKeyController,
                        obscureText: true,
                      ),
                    ),
                  ],
                ),
              if (!config.isCodex && !config.hasApiKey) ...[
                const SizedBox(height: RevericSpacing.xs),
                Text(
                  context.t(LocaleKeys.providerConfigNeedApiKey),
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
              ],
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          Column(
            key: guideKeys?.models,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (config.supportsModelKind(AiModelKind.chat))
                ProviderModelsEditor(
                  label: context.t(LocaleKeys.providerChatModelsLabel),
                  hint: context.t(LocaleKeys.providerChatModelsHint),
                  models: config.availableModels,
                  onChanged: (models) =>
                      saveChange((current) => current.copyWith(models: models)),
                  fetchButton: _buildFetchButton(
                    context,
                    config,
                    config.availableModels,
                    (models) => saveChange(
                      (current) => current.copyWith(models: models),
                    ),
                  ),
                ),
              if (!config.hasModels) ...[
                const SizedBox(height: RevericSpacing.xs),
                Text(
                  context.t(LocaleKeys.providerConfigNeedModels),
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
              ],
              if (config.supportsModelKind(AiModelKind.video)) ...[
                const SizedBox(height: RevericSpacing.lg),
                ProviderVideoModels(
                  config: config,
                  onChanged: (models) => saveChange(
                    (current) => current.copyWith(videoModels: models),
                  ),
                  fetchButton: _buildFetchButton(
                    context,
                    config,
                    config.availableVideoModels,
                    (models) => saveChange(
                      (current) => current.copyWith(videoModels: models),
                    ),
                    kind: AiModelKind.video,
                  ),
                ),
              ],
              if (config.supportsModelKind(AiModelKind.audio)) ...[
                const SizedBox(height: RevericSpacing.lg),
                ProviderAudioModels(
                  config: config,
                  onChanged: (models) => saveChange(
                    (current) => current.copyWith(audioModels: models),
                  ),
                  fetchButton: _buildFetchButton(
                    context,
                    config,
                    config.availableAudioModels,
                    (models) => saveChange(
                      (current) => current.copyWith(audioModels: models),
                    ),
                    kind: AiModelKind.audio,
                  ),
                ),
              ],
              if (config.supportsModelKind(AiModelKind.image)) ...[
                const SizedBox(height: RevericSpacing.lg),
                ProviderModelsEditor(
                  label: context.t(LocaleKeys.providerImageModelsLabel),
                  hint: context.t(LocaleKeys.providerImageModelsHint),
                  models: config.availableImageModels,
                  onChanged: (models) => saveChange(
                    (current) => current.copyWith(imageModels: models),
                  ),
                  fetchButton: _buildFetchButton(
                    context,
                    config,
                    config.availableImageModels,
                    (models) => saveChange(
                      (current) => current.copyWith(imageModels: models),
                    ),
                    kind: AiModelKind.image,
                  ),
                ),
              ],
            ],
          ),
          if (!config.isCodex &&
              config.supportsModelKind(AiModelKind.chat)) ...[
            const SizedBox(height: RevericSpacing.lg),
            _EnableTemperatureSwitch(
              config: config,
              onChanged: (value) => saveChange(
                (current) => current.copyWith(
                  config: Value(
                    current.providerConfig.copyWith(enableTemperature: value),
                  ),
                ),
              ),
            ),
            const SizedBox(height: RevericSpacing.sm),
            _buildSliderField(
              context: context,
              label: context.t(LocaleKeys.settingsAiTemperature),
              value: config.temperature,
              min: 0.0,
              max: 2.0,
              divisions: 20,
              onChanged: config.providerConfig.enableTemperature
                  ? (v) => saveChange(
                      (current) => current.copyWith(temperature: v),
                    )
                  : null,
            ),
          ],
          if (config.type == AiProviderType.volcengine.name) ...[
            const SizedBox(height: RevericSpacing.lg),
            _AssetCredentialsSection(config: config, saveChange: saveChange),
          ],
        ],
        const SizedBox(height: RevericSpacing.lg),
        _ProxySection(config: config, saveChange: saveChange),
      ],
    );
  }

  Widget _buildReadOnlyField({
    required BuildContext context,
    required String label,
    required String value,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: typo.uiSemibold.copyWith(color: colors.textPrimary)),
        const SizedBox(height: RevericSpacing.xs),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceDim.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(RevericRadius.medium),
            border: Border.all(color: colors.borderSubtle),
          ),
          child: Row(
            children: [
              RevericIcon(
                RevericIcons.lock_outline,
                size: 14,
                color: colors.textSubtle,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Text(
                  value,
                  style: typo.ui.copyWith(color: colors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 未填凭证时保持可见但禁用，避免用户不知道有这个入口。
  Widget _buildFetchButton(
    BuildContext context,
    AiProvider provider,
    List<String> currentModels,
    ValueChanged<List<String>> onChanged, {
    AiModelKind kind = AiModelKind.chat,
  }) {
    final ready = provider.hasCredentialConfiguration;
    return TextButton.icon(
      icon: RevericIcon(RevericIcons.download, size: 14),
      label: Text(context.t(LocaleKeys.providerFetchModels)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.sm),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: !ready
          ? null
          : () async {
              Widget builder(BuildContext ctx) => ProviderModelsDialogContent(
                config: provider,
                kind: kind,
                existingModels: currentModels.toSet(),
              );
              final selected = defaultTargetPlatform == TargetPlatform.android
                  ? await showMobileSheet<Set<String>>(
                      context: context,
                      builder: builder,
                    )
                  : await showRevericDialog<Set<String>>(
                      context: context,
                      builder: builder,
                    );
              if (selected != null) {
                onChanged(selected.toList());
              }
            },
    );
  }

  Widget _buildTextField({
    required BuildContext context,
    required String label,
    required String hint,
    required TextEditingController controller,
    bool obscureText = false,
  }) {
    return RevericTextField(
      label: label,
      hintText: hint,
      controller: controller,
      obscureText: obscureText,
    );
  }

  Widget _buildSliderField({
    required BuildContext context,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double>? onChanged,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            Text(
              value.toStringAsFixed(value > 100 ? 0 : 1),
              style: typo.ui.copyWith(color: colors.accent),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: colors.accent,
          inactiveColor: colors.border,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _EnableTemperatureSwitch extends StatelessWidget {
  const _EnableTemperatureSwitch({
    required this.config,
    required this.onChanged,
  });

  final AiProvider config;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final enabled = config.providerConfig.enableTemperature;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.t(LocaleKeys.settingsAiEnableTemperature),
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.xs),
              Text(
                context.t(LocaleKeys.settingsAiEnableTemperatureDescription),
                style: typo.ui.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
        RevericSwitch(value: enabled, onChanged: onChanged),
      ],
    );
  }
}

/// 清理粘贴 / 批量插入的接口地址；逐字输入和 IME 组词保留原文。
class ProviderBaseUrlInputFormatter extends TextInputFormatter {
  const ProviderBaseUrlInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!oldValue.composing.isCollapsed || !newValue.composing.isCollapsed) {
      return newValue;
    }
    // 用选区替换长度计算插入量，覆盖「全选后粘贴更短 URL」。
    final selection = oldValue.selection;
    final replaced = selection.isValid ? selection.end - selection.start : 0;
    final inserted = newValue.text.length - oldValue.text.length + replaced;
    if (inserted <= 1 || oldValue.text == newValue.text) {
      return newValue;
    }
    final normalized = _baseUrlWithoutEndpoint(newValue.text);
    if (normalized == newValue.text) {
      return newValue;
    }
    return TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
  }
}

String _baseUrlWithoutEndpoint(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty) {
    return trimmed;
  }
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  final endpoint = RegExp(
    r'/(?:chat/completions|completions|responses|messages|models|embeddings|images/generations|images/edits)$',
  ).firstMatch(path);
  if (endpoint == null) {
    return trimmed;
  }
  // 仅删除已知接口路径；版本、代理前缀及查询参数保持不变。
  return uri.replace(path: path.substring(0, endpoint.start)).toString();
}

@visibleForTesting
String modelsFetchErrorKey(int? statusCode) => switch (statusCode) {
  400 => LocaleKeys.providerFetchModelsBadRequest,
  401 || 403 => LocaleKeys.providerFetchModelsAuthFailed,
  404 => LocaleKeys.providerFetchModelsNotFound,
  429 => LocaleKeys.providerFetchModelsRateLimited,
  _ => LocaleKeys.providerFetchModelsServerError,
};

List<String> _atlasCloudImageModelIds(Map<String, dynamic> body) {
  final data = body['data'];
  if (data is! List) {
    return const [];
  }
  final ids = <String>[];
  for (final item in data) {
    if (item is! Map) {
      continue;
    }
    if (item['type']?.toString().toLowerCase() != 'image' ||
        item['display_console'] == false) {
      continue;
    }
    final id = item['model'];
    if (id is String && id.trim().isNotEmpty) {
      ids.add(id.trim());
    }
  }
  return ids;
}

class _ModelsFetchHttpException implements Exception {
  const _ModelsFetchHttpException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'Failed to fetch models ($statusCode)';
}

@visibleForTesting
Future<List<String>> fetchProviderModels(
  AiProvider config, {
  AiModelKind kind = AiModelKind.chat,
}) async {
  if (config.typeConfig.usesNewApi) {
    return NewApiClient(config).modelIds(kind);
  }
  if (config.typeEnum == AiProviderType.purefox_media) {
    final catalog = await fetchPurefoxMediaModels(config);
    catalog.register();
    return catalog.idsOfKind(switch (kind) {
      AiModelKind.image => 'image',
      AiModelKind.video => 'video',
      AiModelKind.audio => 'audio',
      _ => '',
    });
  }
  if (kind == AiModelKind.audio &&
      config.typeEnum != AiProviderType.openrouter) {
    return audioModelsForProvider(config.type);
  }
  if (kind == AiModelKind.video) {
    return videoModelsForProvider(config.type);
  }
  if (config.isCodex && kind == AiModelKind.image) {
    return codexPresetImageModels;
  }
  if (config.typeEnum == AiProviderType.minimax && kind == AiModelKind.chat) {
    return minimaxPresetChatModels;
  }
  // 有预设清单的渠道直接使用清单。OpenRouter 与 AtlasCloud 图片走各自的
  // 模型列表，未登记型号仍返回，沿用制作侧已有的通用规格。
  final imagePresets =
      kind == AiModelKind.image &&
          config.typeEnum != AiProviderType.openrouter &&
          config.typeEnum != AiProviderType.atlascloud
      ? imageModelsForProvider(config.type)
      : const <String>[];
  if (imagePresets.isNotEmpty) {
    return imagePresets;
  }
  final client = config.createProxyClient() ?? http.Client();
  try {
    if (config.isCodex) {
      return await CodexClient.fetchModels(client: client);
    }
    Uri url;
    Map<String, String> headers;

    final baseUrl = config.effectiveBaseUrl.trim().replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    final baseUri = Uri.parse(baseUrl);
    final basePath = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
    switch (config.typeEnum) {
      case AiProviderType.anthropic:
        final rootPath = basePath.replaceFirst(RegExp(r'/v1$'), '');
        url = baseUri.replace(path: '$rootPath/v1/models');
        headers = <String, String>{
          'Content-Type': 'application/json',
          'x-api-key': config.effectiveApiKey,
          'anthropic-version': '2023-06-01',
        };
      case AiProviderType.gemini:
        url = baseUri.replace(
          path: '$basePath/models',
          queryParameters: {
            ...baseUri.queryParameters,
            'key': config.effectiveApiKey,
          },
        );
        headers = <String, String>{'Content-Type': 'application/json'};
      case AiProviderType.openrouter:
        url = baseUri.replace(
          path: kind == AiModelKind.image
              ? '$basePath/images/models'
              : '$basePath/models',
          queryParameters: kind == AiModelKind.chat
              ? {'output_modalities': 'text'}
              : kind == AiModelKind.audio
              ? {'output_modalities': 'speech'}
              : null,
        );
        headers = {'Authorization': 'Bearer ${config.effectiveApiKey}'};
      case AiProviderType.atlascloud when kind == AiModelKind.image:
        final rootPath = basePath.replaceFirst(RegExp(r'/v1/?$'), '');
        url = baseUri.replace(
          path: '$rootPath/api/v1/models',
          queryParameters: {'type': 'Image'},
        );
        headers = {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.effectiveApiKey}',
        };
      default:
        url = baseUri.replace(path: '$basePath/models');
        headers = <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.effectiveApiKey}',
        };
    }

    final response = await client.get(url, headers: headers);
    if (response.statusCode != 200) {
      final body = response.body.replaceAll(
        config.effectiveApiKey,
        '[redacted]',
      );
      _log.warning(
        'GET ${url.origin}${url.path} '
        'status=${response.statusCode} type=ModelsFetchHttpException body=$body',
      );
      throw _ModelsFetchHttpException(response.statusCode);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final models = switch (config.typeEnum) {
      AiProviderType.gemini =>
        (body['models'] as List<dynamic>)
            .map((m) => (m as Map<String, dynamic>)['name'] as String)
            .map(
              (name) => name.startsWith('models/') ? name.substring(7) : name,
            )
            .where((name) => !name.contains('/tunedModels/'))
            .toList(),
      AiProviderType.atlascloud when kind == AiModelKind.image =>
        _atlasCloudImageModelIds(body),
      _ =>
        (body['data'] as List<dynamic>)
            .where(
              (m) =>
                  config.typeEnum != AiProviderType.openrouter ||
                  kind != AiModelKind.audio ||
                  ((m
                                  as Map<
                                    String,
                                    dynamic
                                  >)['architecture']?['output_modalities']
                              as List? ??
                          [])
                      .contains('speech'),
            )
            .map((m) => (m as Map<String, dynamic>)['id'] as String)
            .toList(),
    };

    if (config.typeEnum == AiProviderType.openrouter &&
        kind == AiModelKind.audio) {
      models.removeWhere(
        (id) => lookupAudioChannelModel(config.type, id) == null,
      );
    }
    models.sort();
    return models;
  } finally {
    client.close();
  }
}

class ProviderModelsDialogContent extends StatefulWidget {
  final AiProvider config;
  final AiModelKind kind;
  final Set<String> existingModels;
  final Future<List<String>> Function()? loadModels;
  final String Function(String model)? labelForModel;

  const ProviderModelsDialogContent({
    super.key,
    required this.config,
    required this.kind,
    required this.existingModels,
    this.loadModels,
    this.labelForModel,
  });

  @override
  State<ProviderModelsDialogContent> createState() =>
      _ProviderModelsDialogContentState();
}

const _fetchModelsDialogWidth = 480.0;
const _fetchModelsDialogContentHeight = 500.0;

class _ProviderModelsDialogContentState
    extends State<ProviderModelsDialogContent> {
  bool _isLoading = true;
  ({String key, int? statusCode, String? detail})? _error;
  List<String> _models = [];
  Set<String> _selected = {};
  String _filterQuery = '';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final models = widget.loadModels == null
          ? await fetchProviderModels(widget.config, kind: widget.kind)
          : await widget.loadModels!();

      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _models = models;
        _selected = models
            .where((m) => widget.existingModels.contains(m))
            .toSet();
      });
    } catch (e, stack) {
      _log.error('Fetch models failed', error: e, stackTrace: stack);

      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        final statusCode = switch (e) {
          _ModelsFetchHttpException() => e.statusCode,
          CodexHttpException() => e.statusCode,
          PurefoxMediaModelsException() => e.statusCode,
          _ => null,
        };
        _error = (
          detail: e is PluginHostError && e.code == 'invalid_models'
              ? e.message
              : null,
          key: e is PluginHostError && e.code == 'invalid_models'
              ? LocaleKeys.providerPluginModelsInvalid
              : e is CodexAuthException
              ? codexAuthErrorKey(e)
              : modelsFetchErrorKey(statusCode),
          statusCode: statusCode,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final actions = [
      RevericButton.secondary(
        label: context.t(LocaleKeys.commonCancel),
        onPressed: () => Navigator.of(context).pop(),
      ),
      RevericButton.primary(
        label: context.t(LocaleKeys.commonConfirm),
        onPressed: _isLoading || _error != null
            ? null
            : () => Navigator.of(context).pop(_selected),
      ),
    ];
    if (defaultTargetPlatform == TargetPlatform.android) {
      return MobileSheetScaffold(
        expand: true,
        header: MobileSheetHeader.closable(
          title: context.t(LocaleKeys.providerFetchModels),
          onClose: () => Navigator.of(context).pop(),
        ),
        footer: Row(
          children: [
            for (final action in actions)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.xs,
                  ),
                  child: action,
                ),
              ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(RevericSpacing.lg),
          child: _buildContent(colors, typo),
        ),
      );
    }
    return RevericDialog.panel(
      title: Text(context.t(LocaleKeys.providerFetchModels)),
      content: SizedBox(
        width: _fetchModelsDialogWidth,
        height: math.min(
          _fetchModelsDialogContentHeight,
          MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: _buildContent(colors, typo),
      ),

      width: _fetchModelsDialogWidth + RevericSpacing.x4l * 2,

      actions: actions,
    );
  }

  Widget _buildContent(RevericColors colors, RevericTypography typo) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.t(
                _error!.key,
                namedArgs: {
                  if (_error!.detail != null) 'details': _error!.detail!,
                  if (_error!.statusCode != null)
                    'status': _error!.statusCode.toString(),
                },
              ),
              textAlign: TextAlign.center,
              style: typo.ui.copyWith(color: colors.error),
            ),
          ],
        ),
      );
    }

    if (_models.isEmpty) {
      return Center(
        child: Text(
          context.t(LocaleKeys.providerFetchModelsEmpty),
          style: typo.ui.copyWith(color: colors.textMuted),
        ),
      );
    }

    final filteredModels = _filteredModels();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RevericDebouncedSearchField(
          hint: context.t(LocaleKeys.providerFetchModelsSearchHint),
          onDebouncedChanged: (query) {
            setState(() {
              _filterQuery = query;
            });
          },
        ),
        const SizedBox(height: RevericSpacing.sm),
        Row(
          children: [
            TextButton(
              onPressed: filteredModels.isEmpty
                  ? null
                  : () => setState(
                      () => _selected = {..._selected, ...filteredModels},
                    ),
              child: Text(
                '${context.t(LocaleKeys.commonSelectAll)} '
                '(${filteredModels.length})',
                style: typo.uiSmall,
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            TextButton(
              onPressed: () => setState(() => _selected = {}),
              child: Text(
                context.t(LocaleKeys.commonClearSelection),
                style: typo.uiSmall,
              ),
            ),
          ],
        ),
        if (filteredModels.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                context.t(LocaleKeys.providerFetchModelsNoMatches),
                style: typo.ui.copyWith(color: colors.textMuted),
              ),
            ),
          )
        else
          Expanded(
            child: ListView(
              children: [
                for (final model in filteredModels)
                  CheckboxListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title: Text(
                      widget.labelForModel?.call(model) ?? model,
                      style: typo.uiSmall,
                    ),
                    value: _selected.contains(model),
                    onChanged: (checked) {
                      setState(() {
                        if (checked == true) {
                          _selected.add(model);
                        } else {
                          _selected.remove(model);
                        }
                      });
                    },
                  ),
              ],
            ),
          ),
      ],
    );
  }

  List<String> _filteredModels() {
    final query = _filterQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return _models;
    }
    return [
      for (final model in _models)
        if (model.toLowerCase().contains(query) ||
            (widget.labelForModel?.call(model).toLowerCase().contains(query) ??
                false))
          model,
    ];
  }
}

/// 保存回执只同步尚未编辑的文本，IME 上屏才触发即时保存。
TextEditingController _useProviderText(
  String savedText,
  Future<void> Function(String) onEdited,
) {
  final controller = useTextEditingController(text: savedText);
  final previousSaved = useRef(savedText);
  final lastCommitted = useRef(savedText);
  final pendingEdits = useRef(0);
  final edited = useRef(onEdited)..value = onEdited;

  useEffect(() {
    final previous = previousSaved.value;
    previousSaved.value = savedText;
    if (pendingEdits.value == 0 &&
        controller.text == previous &&
        previous != savedText &&
        !isTextInputComposing(controller)) {
      lastCommitted.value = savedText;
      final selection = controller.selection;
      controller.value = TextEditingValue(
        text: savedText,
        selection: selection.copyWith(
          baseOffset: selection.baseOffset.clamp(0, savedText.length),
          extentOffset: selection.extentOffset.clamp(0, savedText.length),
        ),
      );
    }
    return null;
  }, [controller, savedText]);

  useEffect(() {
    void onTextChanged() {
      final text = controller.text;
      if (!isTextInputComposing(controller) && text != lastCommitted.value) {
        lastCommitted.value = text;
        pendingEdits.value++;
        unawaited(edited.value(text).whenComplete(() => pendingEdits.value--));
      }
    }

    controller.addListener(onTextChanged);
    return () => controller.removeListener(onTextChanged);
  }, [controller]);
  return controller;
}

/// 渠道私域素材库的 AK/SK 与项目名；素材认证（Seedance 合规校验）用。
class _AssetCredentialsSection extends HookWidget {
  const _AssetCredentialsSection({
    required this.config,
    required this.saveChange,
  });

  final AiProvider config;
  final _SaveProviderChange saveChange;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final accessKey = _useProviderText(
      config.accessKeyId ?? '',
      (text) => saveChange(
        (current) => current.copyWith(accessKeyId: Value(text.trim())),
      ),
    );
    final secretKey = _useProviderText(
      config.secretAccessKey ?? '',
      (text) => saveChange(
        (current) => current.copyWith(secretAccessKey: Value(text.trim())),
      ),
    );
    final project = _useProviderText(
      config.assetProjectName ?? '',
      (text) => saveChange(
        (current) => current.copyWith(assetProjectName: Value(text.trim())),
      ),
    );
    final expanded = useState((config.accessKeyId ?? '').trim().isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => expanded.value = !expanded.value,
          borderRadius: BorderRadius.circular(RevericRadius.small),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xxs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.t(LocaleKeys.providerAssetSection),
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(width: RevericSpacing.xxs),
                RevericIcon(
                  expanded.value
                      ? RevericIcons.expand_less_rounded
                      : RevericIcons.expand_more,
                  size: RevericSizes.buttonIconSize,
                  color: colors.textSubtle,
                ),
              ],
            ),
          ),
        ),
        if (expanded.value) ...[
          const SizedBox(height: RevericSpacing.xs),
          RevericTextField(
            label: context.t(LocaleKeys.providerAssetAccessKeyLabel),
            controller: accessKey,
          ),
          const SizedBox(height: RevericSpacing.lg),
          RevericTextField(
            label: context.t(LocaleKeys.providerAssetSecretKeyLabel),
            controller: secretKey,
            obscureText: true,
          ),
          const SizedBox(height: RevericSpacing.lg),
          RevericTextField(
            label: context.t(LocaleKeys.providerAssetProjectLabel),
            hintText: context.t(LocaleKeys.providerAssetProjectHint),
            controller: project,
          ),
        ],
      ],
    );
  }
}

/// 代理设置区：默认折叠，已配置代理地址时展开。
///
/// 输入不合法时只提示错误、不写回配置，避免把无法使用的代理存进 provider。
class _ProxySection extends HookWidget {
  const _ProxySection({required this.config, required this.saveChange});

  final AiProvider config;
  final _SaveProviderChange saveChange;

  /// 与 [AiProviderX.createProxyClient] 一致，按去掉首尾空白后的值校验。
  ({String? url, String? username, String? password}) _errors(
    BuildContext context,
    String url,
    String username,
    String password,
  ) {
    url = url.trim();
    final credentials = NetworkProxy.credentialFieldErrors(
      address: url,
      username: username.trim(),
      password: password.trim(),
    );
    return (
      url: url.isNotEmpty && NetworkProxy.parseAddress(url) == null
          ? context.t(LocaleKeys.settingsProxyInvalidUrl)
          : null,
      username: networkProxyCredentialErrorText(
        context,
        credentials.username,
        username: true,
      ),
      password: networkProxyCredentialErrorText(
        context,
        credentials.password,
        username: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    late final TextEditingController urlController;
    late final TextEditingController usernameController;
    late final TextEditingController passwordController;
    Future<void> save(String _) async {
      if ([
        urlController,
        usernameController,
        passwordController,
      ].any(isTextInputComposing)) {
        return;
      }
      final url = urlController.text;
      final username = usernameController.text;
      final password = passwordController.text;
      final errors = _errors(context, url, username, password);
      if (errors.url == null &&
          errors.username == null &&
          errors.password == null) {
        await saveChange(
          (current) => current.copyWith(
            proxyUrl: url,
            proxyUsername: username,
            proxyPassword: password,
          ),
        );
      }
    }

    urlController = _useProviderText(config.proxyUrl, save);
    usernameController = _useProviderText(config.proxyUsername, save);
    passwordController = _useProviderText(config.proxyPassword, save);
    final expanded = useState(urlController.text.trim().isNotEmpty);
    useListenable(
      Listenable.merge([urlController, usernameController, passwordController]),
    );
    final errors = _errors(
      context,
      urlController.text,
      usernameController.text,
      passwordController.text,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => expanded.value = !expanded.value,
          borderRadius: BorderRadius.circular(RevericRadius.small),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xxs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.t(LocaleKeys.providerProxySection),
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(width: RevericSpacing.xxs),
                RevericIcon(
                  expanded.value
                      ? RevericIcons.expand_less_rounded
                      : RevericIcons.expand_more,
                  size: RevericSizes.buttonIconSize,
                  color: colors.textSubtle,
                ),
              ],
            ),
          ),
        ),
        if (expanded.value) ...[
          const SizedBox(height: RevericSpacing.xs),
          RevericTextField(
            label: context.t(LocaleKeys.providerProxyUrlLabel),
            hintText: context.t(LocaleKeys.providerProxyUrlHint),
            controller: urlController,
            errorText: errors.url,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: RevericSpacing.lg),
          RevericTextField(
            label: context.t(LocaleKeys.providerProxyUsernameLabel),
            hintText: context.t(LocaleKeys.providerProxyUsernameHint),
            controller: usernameController,
            errorText: errors.username,
          ),
          const SizedBox(height: RevericSpacing.lg),
          RevericTextField(
            label: context.t(LocaleKeys.providerProxyPasswordLabel),
            hintText: context.t(LocaleKeys.providerProxyPasswordHint),
            controller: passwordController,
            obscureText: true,
            errorText: errors.password,
          ),
        ],
      ],
    );
  }
}

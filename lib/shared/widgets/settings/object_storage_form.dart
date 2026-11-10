// 职责: 对象存储连接表单 — 按服务商预设编辑 S3 兼容配置，测试连接通过后保存，支持清空连接配置；桌面设置页与生成前的配置弹窗共用。
// 关联文件:
//   lib/shared/models/object_storage_config.dart
//   lib/shared/services/object_storage/service.dart
//   lib/shared/providers/object_storage.dart
//   lib/desktop/widgets/settings/settings_storage_section.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/form.md
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../components/dialog_feedback.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_select.dart';
import '../../components/reveric_switch.dart';
import '../../form/form.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../models/object_storage_config.dart';
import '../../providers/object_storage.dart';
import '../../services/object_storage/service.dart';
import '../../theme/theme.dart';
import '../confirm_dialog.dart';

enum ObjectStorageField implements FieldSchema {
  vendor,
  accountId,
  endpoint,
  region,
  bucket,
  accessKeyId,
  secretAccessKey,
  keyPrefix,
  pathStyle,
  publicBaseUrl;

  @override
  List<Validator<dynamic>>? get validators => null;
}

final _log = AppLogger.forModule('ObjectStorage');

/// 宽度足够时短字段两两并排；生成前的配置弹窗较窄，退回单列。
const double _twoColumnMinWidth = 560;

class ObjectStorageForm extends HookConsumerWidget {
  const ObjectStorageForm({super.key, required this.config, this.onSaved});

  final ObjectStorageConfig config;

  /// 测试通过并保存后调用。
  final VoidCallback? onSaved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final saving = useState(false);
    final clearing = useState(false);
    final busy = saving.value || clearing.value;
    final feedback = useState<(String, bool)?>(null);
    final obscureSecret = useState(true);
    final (initialVendor, initialIdentifier) = ObjectStorageVendor.detect(
      config,
    );
    final initialCustom = initialVendor == ObjectStorageVendor.custom;
    // 可选项改过默认值时默认展开，避免用户以为配置丢失。
    final advancedOpen = useState(
      config.keyPrefix != ObjectStorageConfig.defaultKeyPrefix ||
          config.publicBaseUrl.isNotEmpty ||
          (initialCustom && config.pathStyle),
    );
    final form = useForm<ObjectStorageField>(
      initialValues: <ObjectStorageField, dynamic>{
        ObjectStorageField.vendor: initialVendor,
        ObjectStorageField.accountId:
            initialVendor == ObjectStorageVendor.cloudflare
            ? initialIdentifier
            : '',
        ObjectStorageField.endpoint: initialCustom ? config.endpoint : '',
        ObjectStorageField.region: switch (initialVendor) {
          ObjectStorageVendor.custom => config.region,
          ObjectStorageVendor.cloudflare => '',
          _ => initialIdentifier,
        },
        ObjectStorageField.bucket: config.bucket,
        ObjectStorageField.accessKeyId: config.accessKeyId,
        ObjectStorageField.secretAccessKey: config.secretAccessKey,
        ObjectStorageField.keyPrefix: config.keyPrefix,
        ObjectStorageField.pathStyle: initialCustom && config.pathStyle,
        ObjectStorageField.publicBaseUrl: config.publicBaseUrl,
      },
      keys: <Object?>[config.encode()],
    );

    String text(ObjectStorageField field) =>
        form.getValue<String>(field)?.trim() ?? '';
    final vendor =
        form.getValue<ObjectStorageVendor>(ObjectStorageField.vendor) ??
        initialVendor;
    final identifierField = vendor == ObjectStorageVendor.cloudflare
        ? ObjectStorageField.accountId
        : ObjectStorageField.region;

    Future<void> save() async {
      if (saving.value || clearing.value) {
        return;
      }
      feedback.value = null;
      form.clearForcedErrors();
      final custom = vendor == ObjectStorageVendor.custom;
      final identifier = text(identifierField).toLowerCase();
      final endpoint = custom
          ? text(ObjectStorageField.endpoint)
          : vendor.endpointFor(identifier);
      if (endpoint == null) {
        form.setError(
          identifierField,
          context.t(
            identifier.isEmpty
                ? LocaleKeys.commonRequired
                : LocaleKeys.settingsObjectStorageInvalidIdentifier,
          ),
        );
        return;
      }
      final next = ObjectStorageConfig(
        provider: config.provider,
        endpoint: endpoint,
        region: switch (vendor) {
          ObjectStorageVendor.custom => text(ObjectStorageField.region),
          ObjectStorageVendor.cloudflare =>
            ObjectStorageVendor.cloudflareRegion,
          _ => identifier,
        },
        bucket: text(ObjectStorageField.bucket),
        accessKeyId: text(ObjectStorageField.accessKeyId),
        secretAccessKey: text(ObjectStorageField.secretAccessKey),
        keyPrefix: text(ObjectStorageField.keyPrefix),
        pathStyle: custom
            ? form.getValue<bool>(ObjectStorageField.pathStyle) ?? false
            : vendor.pathStyle,
        publicBaseUrl: text(ObjectStorageField.publicBaseUrl),
      ).normalized();
      final issue = next.validate();
      if (issue != null) {
        final (field, key) = switch (issue) {
          ObjectStorageConfigIssue.invalid_endpoint => (
            ObjectStorageField.endpoint,
            LocaleKeys.settingsObjectStorageInvalidUrl,
          ),
          ObjectStorageConfigIssue.missing_region => (
            ObjectStorageField.region,
            LocaleKeys.commonRequired,
          ),
          ObjectStorageConfigIssue.missing_bucket => (
            ObjectStorageField.bucket,
            LocaleKeys.commonRequired,
          ),
          ObjectStorageConfigIssue.missing_access_key_id => (
            ObjectStorageField.accessKeyId,
            LocaleKeys.commonRequired,
          ),
          ObjectStorageConfigIssue.missing_secret_access_key => (
            ObjectStorageField.secretAccessKey,
            LocaleKeys.commonRequired,
          ),
          ObjectStorageConfigIssue.invalid_key_prefix => (
            ObjectStorageField.keyPrefix,
            LocaleKeys.settingsObjectStorageInvalidKeyPrefix,
          ),
          ObjectStorageConfigIssue.invalid_public_base_url => (
            ObjectStorageField.publicBaseUrl,
            LocaleKeys.settingsObjectStorageInvalidUrl,
          ),
        };
        if (field == ObjectStorageField.keyPrefix ||
            field == ObjectStorageField.publicBaseUrl) {
          advancedOpen.value = true;
        }
        form.setError(field, context.t(key));
        return;
      }
      saving.value = true;
      final service = ref.read(objectStorageServiceProvider);
      try {
        final failure = await service.test(next);
        if (!context.mounted) {
          return;
        }
        if (failure != null) {
          feedback.value = (context.t(_failureKey(failure)), true);
          return;
        }
        await service.save(next);
        if (!context.mounted) {
          return;
        }
        feedback.value = (
          context.t(LocaleKeys.settingsObjectStorageSaved),
          false,
        );
        onSaved?.call();
      } catch (_) {
        if (context.mounted) {
          feedback.value = (
            context.t(LocaleKeys.settingsObjectStorageSaveFailed),
            true,
          );
        }
      } finally {
        if (context.mounted) {
          saving.value = false;
        }
      }
    }

    Future<void> clear() async {
      if (saving.value || clearing.value) {
        return;
      }
      clearing.value = true;
      final service = ref.read(objectStorageServiceProvider);
      try {
        final confirmed = await showConfirmDialog(
          context,
          title: context.t(LocaleKeys.settingsObjectStorageClearTitle),
          message: context.t(LocaleKeys.settingsObjectStorageClearConfirm),
          confirmLabel: context.t(LocaleKeys.commonClear),
          variant: ConfirmDialogVariant.warning,
        );
        if (!confirmed || !context.mounted) {
          return;
        }
        await service.clear();
        if (context.mounted) {
          advancedOpen.value = false;
          obscureSecret.value = true;
          feedback.value = (
            context.t(LocaleKeys.settingsObjectStorageCleared),
            false,
          );
        }
      } catch (error, stack) {
        _log.error(
          'Clear object storage configuration failed',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          feedback.value = (
            context.t(LocaleKeys.settingsObjectStorageClearFailed),
            true,
          );
        }
      } finally {
        if (context.mounted) {
          clearing.value = false;
        }
      }
    }

    Widget field(
      ObjectStorageField field,
      String labelKey, {
      String? hintKey,
      String? helperKey,
      bool url = false,
      bool secret = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.md),
      child: HookedTextFormField<ObjectStorageField>(
        key: ValueKey('object_storage_${field.name}_field'),
        fieldHook: field,
        enabled: !busy,
        keyboardType: url ? TextInputType.url : null,
        autocorrect: false,
        enableSuggestions: false,
        obscureText: secret && obscureSecret.value,
        label: context.t(labelKey),
        hintText: hintKey == null ? null : context.t(hintKey),
        helperText: helperKey == null ? null : context.t(helperKey),
        suffixIcon: secret
            ? IconButton(
                onPressed: () => obscureSecret.value = !obscureSecret.value,
                icon: RevericIcon(
                  obscureSecret.value
                      ? RevericIcons.visibility
                      : RevericIcons.visibility_off,
                  size: 18,
                ),
              )
            : null,
      ),
    );

    return HookedForm<ObjectStorageField>(
      form: form,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= _twoColumnMinWidth;
          Widget pair(Widget first, Widget second) => wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: first),
                    const SizedBox(width: RevericSpacing.lg),
                    Expanded(child: second),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [first, second],
                );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: RevericSpacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child:
                          HookedFormField<
                            ObjectStorageField,
                            ObjectStorageVendor
                          >(
                            fieldHook: ObjectStorageField.vendor,
                            notifyOnChange: true,
                            builder: (value, onChanged, _) => RevericSelect(
                              key: const ValueKey(
                                'object_storage_vendor_select',
                              ),
                              value: value,
                              label: context.t(
                                LocaleKeys.settingsObjectStorageProvider,
                              ),
                              enabled: !busy,
                              items: [
                                for (final item in ObjectStorageVendor.values)
                                  RevericSelectItem(
                                    value: item,
                                    label: context.t(_vendorLabelKey(item)),
                                    subtitle: item == ObjectStorageVendor.custom
                                        ? context.t(
                                            LocaleKeys
                                                .settingsObjectStorageVendorCustomHint,
                                          )
                                        : null,
                                  ),
                              ],
                              onChanged: (v) {
                                form.clearForcedErrors(notify: false);
                                // 各服务商的 Region 取值互不通用，切换后重新填写。
                                if (v != value) {
                                  form.updateValue<String>(
                                    ObjectStorageField.region,
                                    '',
                                    notify: false,
                                  );
                                }
                                onChanged?.call(v);
                              },
                            ),
                          ),
                    ),
                    if (_createBucketUrl(vendor) case final url?) ...[
                      const SizedBox(width: RevericSpacing.md),
                      RevericButton.secondary(
                        key: const ValueKey('object_storage_create_bucket'),
                        label: context.t(
                          LocaleKeys.settingsObjectStorageCreateBucket,
                        ),
                        onPressed: () => _openCreateBucket(context, url),
                      ),
                    ],
                  ],
                ),
              ),
              if (vendor == ObjectStorageVendor.custom)
                field(
                  ObjectStorageField.endpoint,
                  LocaleKeys.settingsObjectStorageEndpoint,
                  hintKey: LocaleKeys.settingsObjectStorageEndpointHint,
                  url: true,
                ),
              pair(
                vendor == ObjectStorageVendor.cloudflare
                    ? field(
                        ObjectStorageField.accountId,
                        LocaleKeys.settingsObjectStorageAccountId,
                        helperKey:
                            LocaleKeys.settingsObjectStorageAccountIdHint,
                      )
                    : field(
                        ObjectStorageField.region,
                        LocaleKeys.settingsObjectStorageRegion,
                        helperKey: switch (vendor) {
                          ObjectStorageVendor.aliyun =>
                            LocaleKeys.settingsObjectStorageRegionHintAliyun,
                          ObjectStorageVendor.tencent =>
                            LocaleKeys.settingsObjectStorageRegionHintTencent,
                          _ => LocaleKeys.settingsObjectStorageRegionHint,
                        },
                      ),
                field(
                  ObjectStorageField.bucket,
                  LocaleKeys.settingsObjectStorageBucket,
                  helperKey: vendor == ObjectStorageVendor.tencent
                      ? LocaleKeys.settingsObjectStorageBucketHintTencent
                      : null,
                ),
              ),
              pair(
                field(
                  ObjectStorageField.accessKeyId,
                  LocaleKeys.settingsObjectStorageAccessKeyId,
                ),
                field(
                  ObjectStorageField.secretAccessKey,
                  LocaleKeys.settingsObjectStorageSecretAccessKey,
                  secret: true,
                ),
              ),
              _AdvancedToggle(
                open: advancedOpen.value,
                onTap: () => advancedOpen.value = !advancedOpen.value,
              ),
              // 折叠时保留字段状态，提交时仍能读取和回填错误。
              Visibility(
                visible: advancedOpen.value,
                maintainState: true,
                child: Padding(
                  padding: const EdgeInsets.only(top: RevericSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      pair(
                        field(
                          ObjectStorageField.keyPrefix,
                          LocaleKeys.settingsObjectStorageKeyPrefix,
                        ),
                        field(
                          ObjectStorageField.publicBaseUrl,
                          LocaleKeys.settingsObjectStoragePublicBaseUrl,
                          helperKey:
                              LocaleKeys.settingsObjectStoragePublicBaseUrlHint,
                          url: true,
                        ),
                      ),
                      if (vendor == ObjectStorageVendor.custom)
                        HookedFormField<ObjectStorageField, bool>(
                          fieldHook: ObjectStorageField.pathStyle,
                          builder: (value, onChanged, _) => Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      context.t(
                                        LocaleKeys
                                            .settingsObjectStoragePathStyle,
                                      ),
                                      style: typo.uiSemibold.copyWith(
                                        color: colors.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: RevericSpacing.xxs),
                                    Text(
                                      context.t(
                                        LocaleKeys
                                            .settingsObjectStoragePathStyleHint,
                                      ),
                                      style: typo.uiSmall.copyWith(
                                        color: colors.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: RevericSpacing.lg),
                              RevericSwitch(
                                value: value ?? false,
                                onChanged: busy
                                    ? null
                                    : (v) => onChanged?.call(v),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: RevericSpacing.lg),
              Wrap(
                spacing: RevericSpacing.sm,
                runSpacing: RevericSpacing.sm,
                children: [
                  RevericButton.primary(
                    key: const ValueKey('object_storage_save_button'),
                    label: context.t(
                      saving.value
                          ? LocaleKeys.settingsObjectStorageTesting
                          : LocaleKeys.settingsObjectStorageSaveAndTest,
                    ),
                    icon: RevericIcons.cloud_upload,
                    loading: saving.value,
                    onPressed: busy ? null : save,
                  ),
                  if (!config.isEmpty)
                    RevericButton.secondary(
                      key: const ValueKey('object_storage_clear_button'),
                      label: context.t(LocaleKeys.commonClear),
                      onPressed: busy ? null : clear,
                    ),
                ],
              ),
              if (feedback.value case (final message, final isError)) ...[
                const SizedBox(height: RevericSpacing.md),
                _Feedback(message: message, isError: isError),
              ],
            ],
          );
        },
      ),
    );
  }
}

String _failureKey(ObjectStorageFailure failure) => switch (failure) {
  ObjectStorageFailure.connection_failed =>
    LocaleKeys.settingsObjectStorageConnectionFailed,
  ObjectStorageFailure.unauthorized =>
    LocaleKeys.settingsObjectStorageUnauthorized,
  ObjectStorageFailure.bucket_not_found =>
    LocaleKeys.settingsObjectStorageBucketNotFound,
  ObjectStorageFailure.upload_failed =>
    LocaleKeys.settingsObjectStorageUploadFailed,
  ObjectStorageFailure.read_failed =>
    LocaleKeys.settingsObjectStorageReadFailed,
  ObjectStorageFailure.invalid_configuration =>
    LocaleKeys.settingsObjectStorageSaveFailed,
};

String _vendorLabelKey(ObjectStorageVendor vendor) => switch (vendor) {
  ObjectStorageVendor.aliyun => LocaleKeys.settingsObjectStorageVendorAliyun,
  ObjectStorageVendor.tencent => LocaleKeys.settingsObjectStorageVendorTencent,
  ObjectStorageVendor.cloudflare =>
    LocaleKeys.settingsObjectStorageVendorCloudflare,
  ObjectStorageVendor.aws => LocaleKeys.settingsObjectStorageVendorAws,
  ObjectStorageVendor.custom => LocaleKeys.settingsObjectStorageVendorCustom,
};

String? _createBucketUrl(ObjectStorageVendor vendor) => switch (vendor) {
  ObjectStorageVendor.aliyun =>
    'https://www.aliyun.com/product/oss?userCode=8r0xgvta',
  ObjectStorageVendor.tencent => 'https://curl.qcloud.com/dSLNpBe5',
  ObjectStorageVendor.cloudflare =>
    'https://dash.cloudflare.com/?to=/:account/r2/new',
  ObjectStorageVendor.aws =>
    'https://s3.console.aws.amazon.com/s3/bucket/create',
  ObjectStorageVendor.custom => null,
};

Future<void> _openCreateBucket(BuildContext context, String url) async {
  try {
    if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
      return;
    }
    _log.warning('URL launch returned false: $url');
  } catch (error, stackTrace) {
    _log.error(
      'Failed to open bucket creation page: $url',
      error: error,
      stackTrace: stackTrace,
    );
  }
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: DialogToast(
        variant: DialogToastVariant.error,
        child: Text(context.t(LocaleKeys.commonOpenLinkFailed)),
      ),
    ),
  );
}

/// 可选配置的折叠开关，与字段左缘对齐。
class _AdvancedToggle extends StatelessWidget {
  const _AdvancedToggle({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: InkWell(
        key: const ValueKey('object_storage_advanced_toggle'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.small),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RevericIcon(
                open
                    ? RevericIcons.keyboard_arrow_down
                    : RevericIcons.chevron_right,
                size: 14,
                color: colors.textMuted,
              ),
              const SizedBox(width: RevericSpacing.xs),
              Text(
                context.t(LocaleKeys.commonAdvancedOptions),
                style: typo.uiSemibold.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Feedback extends StatelessWidget {
  const _Feedback({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final color = isError ? colors.deletionBorder : colors.additionBorder;
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.md),
      decoration: BoxDecoration(
        color: isError ? colors.deletionBg : colors.additionBg,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
      child: Row(
        children: [
          RevericIcon(
            isError ? RevericIcons.error_outline : RevericIcons.check_circle,
            size: 18,
            color: color,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(message, style: typo.uiSmall.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

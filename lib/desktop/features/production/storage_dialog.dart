// 职责: 生成前的存储配置拦截 — 需要上传本地参考素材而存储未配置时，弹窗就地配置，保存后继续。
// 关联文件:
//   lib/shared/widgets/settings/object_storage_form.dart
//   lib/shared/providers/object_storage.dart
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/desktop/features/production/composer.dart
//   lib/desktop/features/production/support.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/object_storage.dart';
import '../../../shared/models/video/request.dart';
import '../../../shared/services/ai/video/reference_storage_service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/settings/object_storage_form.dart';

/// 存储已配置，或用户在弹窗里配置成功时返回 true；取消返回 false。
Future<bool> ensureReferenceStorage(
  BuildContext context,
  ReferenceStorageService storage, {
  String? providerId,
  String? modelId,
  List<VideoInput> inputs = const [],
}) async {
  Future<bool> ready() => storage.preflight(
    providerId: providerId,
    inputs: inputs,
    modelId: modelId,
  );
  if (await ready()) {
    return true;
  }
  if (!context.mounted) {
    return false;
  }
  return await showReferenceStorageDialog(context) == true && await ready();
}

Future<bool?> showReferenceStorageDialog(BuildContext context) =>
    showRevericDialog<bool>(
      context: context,
      builder: (_) => const _ReferenceStorageDialog(),
    );

class _ReferenceStorageDialog extends ConsumerWidget {
  const _ReferenceStorageDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final config = ref.watch(objectStorageConfigProvider).asData?.value;
    return RevericDialog(
      title: context.t(LocaleKeys.productionStorageRequiredTitle),
      width: RevericSizes.dialogWidth * 1.25,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.t(LocaleKeys.productionStorageRequiredMessage),
            style: typo.body.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: RevericSpacing.x2l),
          if (config != null)
            ObjectStorageForm(
              config: config,
              onSaved: () => Navigator.of(context).pop(true),
            ),
        ],
      ),
      actions: [
        RevericButton.secondary(
          label: context.t(LocaleKeys.commonCancel),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
    );
  }
}

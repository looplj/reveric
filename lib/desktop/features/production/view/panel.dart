// 职责: 管理派生参数编辑会话并提交镜头或打光生成。
// 关联文件:
//   lib/desktop/features/production/view/form.dart
//   lib/desktop/features/production/view/models.dart
//   lib/shared/services/production/view_derive_orchestrator.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/form.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../../shared/components/reveric_button.dart';
import '../../../../shared/components/reveric_select.dart';
import '../../../../shared/database/novel_content_database.dart';
import '../../../../shared/form/form.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/models/ai_provider.dart';
import '../../../../shared/models/production/view_presets.dart';
import '../../../../shared/models/video/request.dart';
import '../../../../shared/providers/settings_providers.dart';
import '../../../../shared/providers/production_images.dart';
import '../../../../shared/services/production/canvas_service.dart';
import '../../../../shared/services/production/view_derive_orchestrator.dart';
import '../../../../shared/theme/theme.dart';
import '../popover.dart';
import '../support.dart';
import 'camera_panel.dart';
import 'light_panel.dart';
import 'form.dart';
import 'models.dart';
import 'sphere_preview.dart';
import '../../../widgets/agent_management/ai_providers_page.dart';

class ProductionViewPanel extends HookConsumerWidget {
  const ProductionViewPanel({
    super.key,
    required this.service,
    required this.node,
    required this.preset,
    required this.onClose,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final ViewPreset preset;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(
      availableAiModelOptionsByKindProvider(AiModelKind.image),
    );
    final preferred = ref.watch(
      resolvedAiModelOptionForKindProvider(kind: AiModelKind.image),
    );
    final providers = ref.watch(aiSettingsProvider).providers;
    final choices = viewModelOptions(options: options, providers: providers);
    final picked = useState<String?>(null);
    final model =
        choices.where((option) => option.id == picked.value).firstOrNull ??
        resolveViewModel(
          options: options,
          providers: providers,
          preferredOptionId: preferred?.id,
        );
    final jobs = ref.watch(imageTaskServiceProvider);
    final asset = useFuture(
      useMemoized(
        () => service.inputAsset(
          ProductionInput.node(node.id, VideoInputRole.reference_image),
        ),
        [service, node.id],
      ),
    );
    return ViewPresetForm(
      preset: preset,
      imagePath: asset.data == null
          ? null
          : service.library.resolve(asset.data!),
      model: SizedBox(
        width: 160,
        child: RevericSelect<String>(
          value: model?.id,
          compact: true,
          dropUp: true,
          height: 30,
          menuWidth: 240,
          leadingIcon: RevericIcons.auto_awesome,
          onEmptyTap: () => showAiProviderSettingsDialog(context),
          footerAction: (
            label: context.t(LocaleKeys.aiAddModel),
            onTap: () => showAiProviderSettingsDialog(context),
          ),
          textStyle: RevericTheme.typographyOf(context).uiSmall,
          placeholder: context.t(LocaleKeys.productionViewImageModelRequired),
          items: [
            for (final option in choices)
              RevericSelectItem(
                value: option.id,
                label: option.displayModelName,
                subtitle: option.providerDisplayName,
              ),
          ],
          onChanged: (id) => picked.value = id,
        ),
      ),
      onClose: onClose,
      onSubmit: model == null || !asset.hasData
          ? null
          : (args) async {
              final label = context.t(
                preset == ViewPreset.camera
                    ? LocaleKeys.productionViewCamera
                    : LocaleKeys.productionViewLight,
              );
              final details = preset == ViewPreset.camera
                  ? '${args.yaw}° / ${args.pitch}° · ${context.t('${LocaleKeys.productionViewOptions}.framing.${args.framing.index}')}'
                  : context.t(
                      '${LocaleKeys.productionViewOptions}.direction.${args.direction.index}',
                    );
              await ViewDeriveOrchestrator().run(
                service: service,
                jobs: jobs,
                sourceNodeId: node.id,
                preset: preset,
                args: args,
                model: model,
                title: '${node.title} · $label $details',
              );
            },
    );
  }
}

class ViewPresetForm extends HookWidget {
  const ViewPresetForm({
    super.key,
    required this.preset,
    required this.imagePath,
    this.model,
    required this.onSubmit,
    required this.onClose,
  });
  final ViewPreset preset;
  final String? imagePath;

  /// 放在底栏左侧的模型选择。
  final Widget? model;
  final Future<void> Function(ViewPresetArgs)? onSubmit;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    const initial = ViewPresetArgs();
    final form = useForm<ViewField>(
      initialValues: {
        ViewField.yaw: initial.yaw,
        ViewField.pitch: initial.pitch,
        ViewField.framing: initial.framing,
        ViewField.direction: initial.direction,
        ViewField.brightness: initial.brightness,
        ViewField.texture: initial.texture,
        ViewField.temperature: initial.temperature,
        ViewField.description: initial.description,
      },
    );
    final busy = useState(false);
    final args = viewArgs(form);
    final controls = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (preset == ViewPreset.camera)
          const ProductionCameraPanel()
        else
          const ProductionLightPanel(),
        HookedTextFormField<ViewField>(
          fieldHook: ViewField.description,
          label: context.t(LocaleKeys.productionViewDescription),
        ),
      ],
    );
    return ProductionPopoverPanel(
      width: RevericSizes.productionComposerWidth,
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      child: HookedForm(
        form: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ProductionPopoverHead(
                title: context.t(
                  preset == ViewPreset.camera
                      ? LocaleKeys.productionViewCamera
                      : LocaleKeys.productionViewLight,
                ),
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final sphere = ProductionSpherePreview(
                    preset: preset,
                    args: args,
                    imagePath: imagePath,
                  );
                  return constraints.maxWidth < 500
                      ? Column(
                          children: [
                            SizedBox(width: 140, child: sphere),
                            controls,
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 160, child: sphere),
                            const SizedBox(width: RevericSpacing.x2l),
                            Expanded(child: controls),
                          ],
                        );
                },
              ),
              const SizedBox(height: RevericSpacing.lg),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: RevericSpacing.sm,
                runSpacing: RevericSpacing.sm,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ?model,
                      RevericButton.text(
                        label: context.t(LocaleKeys.commonReset),
                        onPressed: busy.value ? null : form.reset,
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RevericButton.text(
                        label: context.t(LocaleKeys.commonCancel),
                        onPressed: busy.value ? null : onClose,
                      ),
                      const SizedBox(width: RevericSpacing.sm),
                      RevericButton.primary(
                        label: context.t(LocaleKeys.commonGenerate),
                        loading: busy.value,
                        onPressed: onSubmit == null || busy.value
                            ? null
                            : () => productionRun(context, () async {
                                if (!form.validate()) {
                                  return;
                                }
                                busy.value = true;
                                try {
                                  await onSubmit!(viewArgs(form));
                                  if (context.mounted) {
                                    onClose();
                                  }
                                } finally {
                                  if (context.mounted) {
                                    busy.value = false;
                                  }
                                }
                              }),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

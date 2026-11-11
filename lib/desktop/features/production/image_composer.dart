// 职责: 编辑图片节点草稿与参考输入，按实际模型能力预览后提交单张生成。
// 关联文件:
//   lib/desktop/features/production/image_submit.dart
//   lib/desktop/features/production/view/method.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/models/production/image_request.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/form.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/design-system.md
import '../../../shared/hooks/use_ai_providers.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/components/reveric_select.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/database/app_database.dart' show AssetRow;
import '../../../shared/form/form.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/ai_provider.dart';
import '../../../shared/models/image/channels.dart';
import '../../../shared/models/production/image_request.dart';
import '../../../shared/models/production/view_presets.dart';
import '../../../shared/models/video/request.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import '../canvas/widgets/glass.dart';
import '../storyboard/edit_form.dart' show ShotField;
import 'edit_session.dart';
import 'history_region.dart';
import 'image_submit.dart';
import 'input_preview.dart';
import 'prompt_controller.dart';
import 'popover.dart';
import 'composer_toolbar.dart';
import 'prompt_field.dart';
import 'style_button.dart';
import 'spec_panel.dart';
import 'support.dart';
import 'upload.dart';
import 'view/method.dart';
import '../../widgets/agent_management/ai_providers_page.dart';

final _log = AppLogger.forModule('ProductionImage');

class ProductionImageComposer extends HookWidget {
  const ProductionImageComposer({
    super.key,
    required this.service,
    required this.node,
    required this.path,
    required this.session,
    this.clip,
    this.onExternalChange,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final String path;
  final ProductionEditSession session;
  final ProductionClipRow? clip;
  final VoidCallback? onExternalChange;
  @override
  Widget build(BuildContext context) {
    final loaded = useFuture(
      useMemoized(
        () async => (
          clip: (await service.shots.getShot(node.clipId!))!,
          inputs: await service.draftInputs(node.id),
        ),
        [service, node.id],
      ),
    );
    if (loaded.hasError) {
      return Text(context.t(LocaleKeys.productionFailed));
    }
    if (!loaded.hasData) {
      return const SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return _ImageForm(
      service: service,
      node: node,
      path: path,
      session: session,
      initial: loaded.data!,
      clip: clip,
      onExternalChange: onExternalChange,
    );
  }
}

class _ImageForm extends HookConsumerWidget {
  const _ImageForm({
    required this.service,
    required this.node,
    required this.path,
    required this.session,
    required this.initial,
    required this.clip,
    required this.onExternalChange,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final String path;
  final ProductionEditSession session;
  final ({ProductionClipRow clip, List<ProductionInput> inputs}) initial;
  final ProductionClipRow? clip;
  final VoidCallback? onExternalChange;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prompt = useMemoized(
      () => ProductionPromptController(initial.clip.prompt),
      [node.id],
    );
    useEffect(() => prompt.dispose, [prompt]);
    final inputs = useState(initial.inputs);
    final form = useForm<ShotField>(
      listen: false,
      initialValues: {
        ShotField.title: initial.clip.title,
        ShotField.model: (
          initial.clip.providerId ?? '',
          initial.clip.modelId ?? '',
        ),
        ShotField.ratio: initial.clip.ratio,
        ShotField.resolution: initial.clip.resolution,
        ShotField.imagePreset: ImageGenerationPreset.fromStyle(node.style),
      },
      keys: [node.id],
    );
    final model = useListenableSelector(
      form,
      () => form.getValue<(String, String)>(ShotField.model)!,
    );
    final preset = useListenableSelector(
      form,
      () => form.getValue<ImageGenerationPreset>(ShotField.imagePreset)!,
    );
    final providers = useAiProviders(service.library.database);
    final provider = providers.data?.where((p) => p.id == model.$1).firstOrNull;
    final capability = provider == null
        ? null
        : ProductionImageCapabilities(provider, model.$2);
    final complexities = provider == null
        ? const <String>[]
        : imageComplexityLevels(provider.type, model.$2).toList();
    String? blockedReason;
    if (!providers.hasData) {
      blockedReason = context.t(
        providers.hasError
            ? LocaleKeys.productionFailed
            : LocaleKeys.productionGenerateChecking,
      );
    } else if (provider == null ||
        !provider.enabled ||
        !capability!.isSupported ||
        model.$2.trim().isEmpty ||
        !provider.availableImageModels.contains(model.$2)) {
      blockedReason = context.t(LocaleKeys.productionGenerateModelRequired);
    }
    if (blockedReason == null &&
        referenceRequiredMethods.contains(preset.method) &&
        inputs.value.every((input) => input.isPrompt)) {
      blockedReason = context.t(LocaleKeys.productionViewImageRequired);
    }
    if (blockedReason == null &&
        preset.method == ImageGenerationMethod.panorama &&
        !capability!.ratios.contains('2:1')) {
      blockedReason = context.t(LocaleKeys.productionViewPanoramaModelRequired);
    }
    final saved = useRef('');
    final pending = useRef<Timer?>(null);
    final writing = useRef<Future<bool>?>(null);
    final error = useState(false);
    final overlay = ref.watch(workingOverlayServiceProvider(path));
    String value(ShotField key) => form.getValue<String>(key) ?? '';
    String signature() =>
        '${prompt.source}|${value(ShotField.title)}|${form.getValue<(String, String)>(ShotField.model)}|${value(ShotField.ratio)}|${value(ShotField.resolution)}|${form.getValue<ImageGenerationPreset>(ShotField.imagePreset)!.toJson()}|${inputs.value.map((r) => '${r.identity}:${r.sourceNodeId}').join(',')}';
    if (saved.value.isEmpty) {
      saved.value = signature();
    }
    final external = useExternalDraftReload(
      initial: initial.clip,
      latest: clip,
      settled: () =>
          pending.value?.isActive != true &&
          writing.value == null &&
          saved.value == signature(),
      reload: onExternalChange,
    );
    Future<bool> persist() async {
      final version = signature();
      try {
        final selection = form.getValue<(String, String)>(ShotField.model)!;
        await service.saveImage(
          nodeId: node.id,
          draft: ProductionImageDraft(
            title: value(ShotField.title),
            providerId: selection.$1.isEmpty ? null : selection.$1,
            modelId: selection.$2,
            prompt: prompt.source,
            resolution: value(ShotField.resolution),
            ratio: value(ShotField.ratio),
            preset: form.getValue<ImageGenerationPreset>(ShotField.imagePreset),
          ),
          inputs: inputs.value,
          overlay: overlay,
        );
        saved.value = version;
        external.sync((await service.shots.getShot(node.clipId!))!);
        if (context.mounted) {
          error.value = false;
        }
        return true;
      } catch (failure, stack) {
        _log.error(
          'draft save failed node=${node.id}',
          error: failure,
          stackTrace: stack,
        );
        if (context.mounted) {
          error.value = true;
        }
        return false;
      }
    }

    Future<bool> save() async {
      pending.value?.cancel();
      while (writing.value != null) {
        await writing.value;
      }
      if (saved.value == signature()) {
        return true;
      }
      final future = persist();
      writing.value = future;
      try {
        return await future;
      } finally {
        writing.value = null;
      }
    }

    final changes = useMemoized(
      () => Listenable.merge([prompt, form, inputs]),
      [prompt, form, inputs],
    );
    useEffect(() {
      void schedule() {
        pending.value?.cancel();
        pending.value = Timer(const Duration(milliseconds: 600), save);
      }

      changes.addListener(schedule);
      return () {
        changes.removeListener(schedule);
        pending.value?.cancel();
      };
    }, [changes]);
    session.leave = save;
    useEffect(
      () => () {
        session.leave = null;
      },
      [session],
    );
    prompt.inputIds = inputs.value.map((i) => i.id).toSet();
    prompt.onPreview = (id) => productionRun(context, () async {
      final input = inputs.value.firstWhere((i) => i.id == id);
      if (input.isPrompt) {
        return;
      }
      final asset = await service.inputAsset(input);
      if (context.mounted) {
        await previewProductionAsset(context, service, asset.id);
      }
    });
    Future<void> attach(AssetRow asset, {bool reference = false}) async {
      if (!context.mounted) {
        return;
      }
      var input = inputs.value
          .where(
            (i) =>
                i.refType == ProductionInputType.asset && i.refId == asset.id,
          )
          .firstOrNull;
      if (input == null) {
        input = ProductionInput.asset(asset.id, VideoInputRole.reference_image);
        await changeProductionInputs(context, node.id, save, () {
          inputs.value = [...inputs.value, input!];
        });
      }
      if (reference) {
        prompt.insertReference(input.id, asset.name);
      }
    }

    Future<void> pickReference() async {
      final asset = await pickProductionAsset(
        context,
        service,
        types: {'image'},
      );
      if (asset != null && context.mounted) {
        await attach(asset, reference: true);
      }
    }

    Future<void> reference() async {
      final box = context.findRenderObject()! as RenderBox;
      final names = <String, String>{};
      for (final input in inputs.value) {
        names[input.identity] = await service.inputName(input);
      }
      if (!context.mounted) {
        return;
      }
      await showRevericContextMenu(
        context: context,
        position: box.localToGlobal(Offset.zero),
        entries: [
          for (final entry in names.entries)
            RevericMenuItem(
              label: entry.value.isEmpty ? entry.key : entry.value,
              onTap: () {
                if (!context.mounted) {
                  return;
                }
                final input = inputs.value.firstWhere(
                  (i) => i.identity == entry.key,
                );
                prompt.insertReference(input.id, entry.value);
              },
            ),
          RevericMenuItem(
            label: context.t(LocaleKeys.productionAssets),
            onTap: () => productionRun(context, pickReference),
          ),
        ],
      );
    }

    final expanded = useState(false);
    final ratio = useListenableSelector(form, () => value(ShotField.ratio));
    final resolution = useListenableSelector(
      form,
      () => value(ShotField.resolution),
    );
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Material(
      type: MaterialType.transparency,
      child: CanvasGlass(
        raised: true,
        radius: RevericRadius.canvasNode,
        padding: const EdgeInsets.fromLTRB(
          RevericSpacing.lg,
          RevericSpacing.lg,
          RevericSpacing.lg,
          RevericSpacing.md,
        ),
        child: HookedForm(
          form: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ProductionComposerTools(
                expanded: expanded.value,
                onExpand: () => expanded.value = !expanded.value,
                children: [
                  ProductionAddInputButton(
                    service: service,
                    types: const {'image'},
                    onPicked: attach,
                  ),
                  ProductionToolChip(
                    icon: RevericIcons.at,
                    label: context.t(LocaleKeys.productionMention),
                    tooltip: context.t(LocaleKeys.productionReference),
                    onTap: () => productionRun(context, reference),
                  ),
                  const ProductionImageMethodButton(),
                ],
              ),
              if (inputs.value.isNotEmpty) ...[
                const SizedBox(height: RevericSpacing.sm),
                Wrap(
                  spacing: RevericSpacing.sm,
                  runSpacing: RevericSpacing.sm,
                  children: [
                    for (var i = 0; i < inputs.value.length; i++)
                      ProductionInputTile(
                        service: service,
                        input: inputs.value[i],
                        valid:
                            inputs.value[i].isPrompt ||
                            (capability?.allowsReferenceCount(
                                  inputs.value
                                      .take(i + 1)
                                      .where((input) => !input.isPrompt)
                                      .length,
                                ) ??
                                false),
                        onRole: null,
                        onMove: inputs.value.length < 2
                            ? null
                            : (delta) => changeProductionInputs(
                                context,
                                node.id,
                                save,
                                () {
                                  final target = i + delta;
                                  if (target >= 0 &&
                                      target < inputs.value.length) {
                                    final next = [...inputs.value];
                                    next.insert(target, next.removeAt(i));
                                    inputs.value = next;
                                  }
                                },
                              ),
                        onRemove: () =>
                            changeProductionInputs(context, node.id, save, () {
                              inputs.value = [...inputs.value]..removeAt(i);
                            }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: RevericSpacing.sm),
              // 画布留给输入框的高度不够时，提示词区先收缩，在框内滚动。
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: expanded.value ? 200 : 60,
                    maxHeight: expanded.value ? 360 : 140,
                  ),
                  child: SingleChildScrollView(
                    child: ProductionPromptField(
                      controller: prompt,
                      hintText: preset.method == ImageGenerationMethod.free
                          ? null
                          : context.t(LocaleKeys.productionImageMethodPrompt),
                      footer: false,
                      maxLines: null,
                      onReference: () => productionRun(context, reference),
                    ),
                  ),
                ),
              ),
              if (error.value)
                Padding(
                  padding: const EdgeInsets.only(top: RevericSpacing.xs),
                  child: Text(
                    context.t(LocaleKeys.productionInvalid),
                    style: typo.uiTiny.copyWith(color: colors.error),
                  ),
                ),
              const SizedBox(height: RevericSpacing.sm),
              ProductionComposerToolbar(
                submit: ProductionImageSubmit(
                  service: service,
                  node: node,
                  path: path,
                  save: save,
                  blockedReason: blockedReason,
                ),
                children: [
                  ProductionStylePill(service: service, clipId: node.clipId!),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: RevericSpacing.sm,
                    ),
                    child: SizedBox(
                      width: 180,
                      child: HookedFormField<ShotField, (String, String)>(
                        fieldHook: ShotField.model,
                        notifyOnChange: true,
                        builder: (value, changed, error) =>
                            RevericSelect<(String, String)>(
                              value: value,
                              compact: true,
                              dropUp: true,
                              searchable: true,
                              height: 30,
                              menuWidth: 240,
                              leadingIcon: RevericIcons.auto_awesome,
                              onEmptyTap: () =>
                                  showAiProviderSettingsDialog(context),
                              footerAction: (
                                label: context.t(LocaleKeys.aiAddModel),
                                onTap: () =>
                                    showAiProviderSettingsDialog(context),
                              ),
                              textStyle: typo.uiSmall,
                              placeholder: context.t(
                                LocaleKeys.storyboardModel,
                              ),
                              items: [
                                for (final p
                                    in providers.data ?? <AiProvider>[])
                                  if (p.enabled &&
                                      ProductionImageCapabilities.supports(p))
                                    for (final m
                                        in p.availableImageModels.where(
                                          (m) => ProductionImageCapabilities(
                                            p,
                                            m,
                                          ).isSupported,
                                        ))
                                      RevericSelectItem(
                                        value: (p.id, m),
                                        label: m,
                                        subtitle: p.name,
                                      ),
                              ],
                              onChanged: (v) {
                                final nextProvider = providers.data!.firstWhere(
                                  (p) => p.id == v.$1,
                                );
                                final next = ProductionImageCapabilities(
                                  nextProvider,
                                  v.$2,
                                );
                                changed?.call(v);
                                if (preset.method !=
                                        ImageGenerationMethod.panorama &&
                                    !next.ratios.contains(
                                      form.getValue<String>(ShotField.ratio),
                                    )) {
                                  form.updateValue(
                                    ShotField.ratio,
                                    next.ratios.first,
                                  );
                                }
                                if (!next.resolutions.contains(
                                  form.getValue<String>(ShotField.resolution),
                                )) {
                                  form.updateValue(
                                    ShotField.resolution,
                                    next.resolutions.first,
                                  );
                                }
                              },
                            ),
                      ),
                    ),
                  ),
                  ProductionSpecPill(
                    ratios: preset.method == ImageGenerationMethod.panorama
                        ? const ['2:1']
                        : capability?.ratios ?? [initial.clip.ratio],
                    resolutions:
                        capability?.resolutions ?? [initial.clip.resolution],
                    ratio: ratio,
                    resolution: resolution,
                    complexities: complexities,
                    complexity: provider == null
                        ? null
                        : imageComplexityFor(
                            provider.type,
                            model.$2,
                            preset.complexity,
                          ),
                    onComplexity: (value) {
                      form.updateValue(
                        ShotField.imagePreset,
                        ImageGenerationPreset(
                          method: preset.method,
                          complexity: value,
                        ),
                      );
                    },
                    onChanged: ({ratio, resolution}) {
                      if (ratio != null) {
                        form.updateValue(ShotField.ratio, ratio);
                      }
                      if (resolution != null) {
                        form.updateValue(ShotField.resolution, resolution);
                      }
                    },
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

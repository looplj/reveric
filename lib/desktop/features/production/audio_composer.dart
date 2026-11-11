// 职责: 编辑音频节点草稿，选择官方模型并提交音频生成。
// 关联文件:
//   lib/desktop/features/production/audio_submit.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/models/audio/request.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
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
import '../../../shared/models/audio/request.dart';
import '../../../shared/models/audio/settings.dart';
import '../../../shared/models/audio/channels.dart';
import '../../../shared/services/production/audio_generate_orchestrator.dart';
import '../../../shared/models/video/request.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import '../canvas/widgets/glass.dart';
import '../storyboard/edit_form.dart' show ShotField;
import 'edit_session.dart';
import 'history_region.dart';
import 'audio_submit.dart';
import 'speech_options.dart';
import 'input_preview.dart';
import 'prompt_controller.dart';
import 'composer_toolbar.dart';
import 'prompt_field.dart';
import 'support.dart';
import 'upload.dart';
import 'popover.dart';
import '../../widgets/agent_management/ai_providers_page.dart';

final _log = AppLogger.forModule('ProductionAudio');

class ProductionAudioComposer extends HookWidget {
  const ProductionAudioComposer({
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
    return _AudioForm(
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

class _AudioForm extends HookConsumerWidget {
  const _AudioForm({
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
        ShotField.audioVoice:
            audioParametersFromStyle(
              node.style,
              initial.clip.providerId,
              initial.clip.modelId,
            ).voice ??
            '',
        ShotField.audioInstructions:
            audioParametersFromStyle(
              node.style,
              initial.clip.providerId,
              initial.clip.modelId,
            ).instructions ??
            '',
        ShotField.model: (
          initial.clip.providerId ?? '',
          initial.clip.modelId ?? '',
        ),
        ShotField.ratio: initial.clip.ratio,
        ShotField.resolution: initial.clip.resolution,
      },
      keys: [node.id],
    );
    final model = useListenableSelector(
      form,
      () => form.getValue<(String, String)>(ShotField.model)!,
    );
    final providers = useAiProviders(service.library.database);
    final provider = providers.data?.where((p) => p.id == model.$1).firstOrNull;
    final capability =
        provider == null ||
            !AudioCapabilities(model.$2).supportsProvider(provider)
        ? null
        : AudioCapabilities.forProvider(model.$2, provider);
    final voice = useListenableSelector(
      form,
      () => form.getValue<String>(ShotField.audioVoice) ?? '',
    );
    final instructions = useListenableSelector(
      form,
      () => form.getValue<String>(ShotField.audioInstructions) ?? '',
    );
    final showInstructions = useState(false);
    final inputKinds = inputs.value
        .where((i) => !i.isPrompt)
        .map((i) => i.role.kind.name)
        .toList();
    final imageMode = inputKinds.contains('image');
    final referenceTypes = {
      for (final kind in capability?.model.references.keys ?? <String>[])
        if (capability!.accepts([...inputKinds, kind])) kind,
    };
    String? blockedReason;
    if (!providers.hasData) {
      blockedReason = context.t(
        providers.hasError
            ? LocaleKeys.productionFailed
            : LocaleKeys.productionGenerateChecking,
      );
    } else if (provider == null ||
        !provider.enabled ||
        !AudioCapabilities(model.$2).supportsProvider(provider) ||
        capability == null ||
        model.$2.trim().isEmpty ||
        !provider.availableAudioModels.contains(model.$2)) {
      blockedReason = context.t(LocaleKeys.productionGenerateModelRequired);
    }
    if (blockedReason == null && !capability!.accepts(inputKinds)) {
      blockedReason = context.t(LocaleKeys.productionAudioReferenceInvalid);
    }
    if (blockedReason == null &&
        capability!.model.requiresVoice &&
        inputs.value.every((input) => input.isPrompt) &&
        voice.trim().isEmpty) {
      blockedReason = context.t(LocaleKeys.productionSpeechVoiceRequired);
    }
    if (blockedReason == null &&
        capability!.model.requiresInstructions &&
        instructions.trim().isEmpty) {
      blockedReason = context.t(
        LocaleKeys.productionSpeechInstructionsRequired,
      );
    }
    final saved = useRef('');
    final pending = useRef<Timer?>(null);
    final writing = useRef<Future<bool>?>(null);
    final error = useState(false);
    final overlay = ref.watch(workingOverlayServiceProvider(path));
    String value(ShotField key) => form.getValue<String>(key) ?? '';
    String signature() =>
        '${value(ShotField.audioVoice)}|${value(ShotField.audioInstructions)}|${prompt.source}|${value(ShotField.title)}|${form.getValue<(String, String)>(ShotField.model)}|${value(ShotField.ratio)}|${value(ShotField.resolution)}|${inputs.value.map((r) => '${r.identity}:${r.sourceNodeId}').join(',')}';
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
        await service.saveAudio(
          nodeId: node.id,
          prompt: prompt.source,
          providerId: selection.$1.isEmpty ? null : selection.$1,
          modelId: selection.$2.isEmpty ? null : selection.$2,
          inputs: inputs.value,
          parameters: AudioRequestDefaults(
            voice: ConfigValue(
              inputs.value.every((input) => input.isPrompt) &&
                      value(ShotField.audioVoice).trim().isNotEmpty
                  ? value(ShotField.audioVoice).trim()
                  : null,
            ),
            instructions: ConfigValue(
              value(ShotField.audioInstructions).trim().isNotEmpty
                  ? value(ShotField.audioInstructions).trim()
                  : null,
            ),
          ),
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
      final asset = await service.inputAsset(input);
      if (context.mounted) {
        await previewProductionAsset(context, service, asset.id);
      }
    });
    Future<void> attach(AssetRow asset, {bool reference = false}) async {
      if (!context.mounted) {
        return;
      }
      final next = [...inputs.value];
      var input = next
          .where(
            (i) =>
                i.refType == ProductionInputType.asset && i.refId == asset.id,
          )
          .firstOrNull;
      if (input == null) {
        input = ProductionInput.asset(
          asset.id,
          asset.type == 'audio'
              ? VideoInputRole.reference_audio
              : VideoInputRole.reference_image,
        );
        next.add(input);
      }
      await resolveAudioReferences(
        service,
        model.$2,
        next,
        providerId: model.$1,
      );
      if (!context.mounted) {
        return;
      }
      await changeProductionInputs(context, node.id, save, () {
        inputs.value = next;
      });
      if (reference &&
          capability?.model.supportsAudioReferencePlaceholders == true &&
          asset.type == 'audio') {
        prompt.insertReference(input.id, asset.name);
      }
    }

    Future<void> pickReference() async {
      final asset = await pickProductionAsset(
        context,
        service,
        types: const {'audio'},
      );
      if (asset != null && context.mounted) {
        await attach(asset, reference: true);
      }
    }

    Future<void> reference() async {
      if (!inputs.value.any((input) => input.isPrompt) &&
          (imageMode ||
              capability == null ||
              !capability.model.supportsAudioReferencePlaceholders)) {
        return;
      }
      final box = context.findRenderObject()! as RenderBox;
      final names = <String, String>{};
      for (final input in inputs.value.where(
        (i) =>
            i.isPrompt ||
            (!imageMode &&
                capability?.model.supportsAudioReferencePlaceholders == true &&
                i.role == VideoInputRole.reference_audio),
      )) {
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
                    types: referenceTypes,
                    enabled: referenceTypes.isNotEmpty,
                    onPicked: attach,
                  ),
                  ProductionToolChip(
                    icon: RevericIcons.at,
                    label: context.t(LocaleKeys.productionMention),
                    tooltip: context.t(LocaleKeys.productionReference),
                    onTap:
                        !inputs.value.any((input) => input.isPrompt) &&
                            (imageMode ||
                                capability == null ||
                                !capability
                                    .model
                                    .supportsAudioReferencePlaceholders)
                        ? null
                        : () => productionRun(context, reference),
                  ),
                ],
              ),
              if (inputs.value.isNotEmpty) ...[
                const SizedBox(height: RevericSpacing.sm),
                Wrap(
                  spacing: RevericSpacing.sm,
                  runSpacing: RevericSpacing.sm,
                  children: [
                    for (var i = 0; i < inputs.value.length; i++)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!inputs.value[i].isPrompt &&
                              inputs.value[i].role ==
                                  VideoInputRole.reference_audio)
                            Text(
                              context.t(
                                LocaleKeys.productionAudioReferenceLabel,
                                namedArgs: {'index': '${i + 1}'},
                              ),
                              style: typo.uiTiny.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
                          ProductionInputTile(
                            service: service,
                            input: inputs.value[i],
                            valid: capability?.accepts(inputKinds) ?? false,
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
                            onRemove: () => changeProductionInputs(
                              context,
                              node.id,
                              save,
                              () {
                                inputs.value = [...inputs.value]..removeAt(i);
                              },
                            ),
                          ),
                        ],
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
                      hintText: imageMode
                          ? context.t(LocaleKeys.productionAudioImagePrompt)
                          : context.t(
                              capability?.model.speech == true
                                  ? LocaleKeys.productionSpeechText
                                  : LocaleKeys.productionAudioPrompt,
                            ),
                      footer: false,
                      maxLines: null,
                      onReference: () => productionRun(context, reference),
                    ),
                  ),
                ),
              ),
              if (capability?.model.supportsInstructions == true &&
                  (capability!.model.requiresInstructions ||
                      showInstructions.value ||
                      instructions.isNotEmpty))
                ProductionSpeechInstructions(
                  // 只有用户点开时抢焦点；带着已有说明打开节点时焦点留在台词。
                  autofocus: showInstructions.value && instructions.isEmpty,
                ),
              if (capability != null)
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: prompt,
                  builder: (context, value, child) {
                    final count = prompt.plainText.runes.length;
                    return Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        '$count/${capability.model.maxPromptCharacters}',
                        style: typo.uiTiny.copyWith(
                          color: count > capability.model.maxPromptCharacters
                              ? colors.error
                              : colors.textMuted,
                        ),
                      ),
                    );
                  },
                ),
              if (capability != null &&
                  capability.model.supportsAudioReferencePlaceholders)
                Text(
                  context.t(
                    LocaleKeys.productionAudioReferenceHint,
                    namedArgs: {
                      'audio':
                          '${capability.model.references['audio']?.maxCount ?? 0}',
                      'images':
                          '${capability.model.references['image']?.maxCount ?? 0}',
                      'seconds':
                          '${(capability.model.references['audio']?.maxDurationMs ?? 0) ~/ 1000}',
                      'mb':
                          '${(capability.model.references['audio']?.maxBytes ?? capability.model.references['image']?.maxBytes ?? 0) ~/ (1024 * 1024)}',
                    },
                  ),
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
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
                submit: ProductionAudioSubmit(
                  service: service,
                  node: node,
                  path: path,
                  save: save,
                  blockedReason: blockedReason,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: RevericSpacing.sm),
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
                                      AudioCapabilities.supports(p))
                                    for (final m
                                        in p.availableAudioModels.where(
                                          (m) =>
                                              lookupAudioChannelModel(
                                                p.type,
                                                m,
                                              ) !=
                                              null,
                                        ))
                                      RevericSelectItem(
                                        value: (p.id, m),
                                        label: m,
                                        subtitle: p.name,
                                      ),
                              ],
                              onChanged: (value) {
                                final picked = providers.data!.firstWhere(
                                  (p) => p.id == value.$1,
                                );
                                final next = AudioCapabilities.forProvider(
                                  value.$2,
                                  picked,
                                ).model;
                                form.updateValue(
                                  ShotField.audioVoice,
                                  next.voices.firstOrNull ?? '',
                                );
                                form.updateValue(
                                  ShotField.audioInstructions,
                                  '',
                                );
                                changed?.call(value);
                              },
                            ),
                      ),
                    ),
                  ),
                  if (capability?.model.requiresVoice == true)
                    ProductionSpeechVoiceSelect(
                      capability: capability!.model,
                      hasReference: inputs.value.isNotEmpty,
                    ),
                  if (capability?.model.supportsInstructions == true)
                    ProductionToolButton(
                      icon: RevericIcons.theater_comedy_outlined,
                      tooltip: context.t(
                        LocaleKeys.productionSpeechInstructions,
                      ),
                      open: showInstructions.value || instructions.isNotEmpty,
                      onTap: () =>
                          showInstructions.value = !showInstructions.value,
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

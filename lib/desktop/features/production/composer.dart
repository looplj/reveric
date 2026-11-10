// 职责: 贴在选中视频节点下方的生成输入框：编辑输入、提示词与生成规格，保存并校验后直接提交。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/desktop/features/production/region.dart
//   lib/desktop/features/production/storage_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import '../../../shared/hooks/use_ai_providers.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_select.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/database/app_database.dart' show AssetRow;
import '../../../shared/form/form.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/models/video/request.dart';
import '../../../shared/models/video/task_result.dart';
import '../../../shared/database/daos/generation_task_dao.dart';
import '../../../shared/models/storyboard/prompt.dart';
import '../../../shared/models/video/capabilities.dart';
import '../../../shared/models/video/channels.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/purefox_media_providers.dart';
import '../../../shared/providers/video_tasks.dart';
import '../../../shared/services/ai/video/draft.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/generate_orchestrator.dart';
import '../../../shared/theme/theme.dart';
import '../canvas/widgets/glass.dart';
import 'storage_dialog.dart';
import '../storyboard/edit_form.dart' show ShotField;
import 'prompt_controller.dart';
import 'input_preview.dart';
import 'character_input.dart';
import '../../../shared/services/production/voices.dart';
import 'edit_session.dart';
import 'prompt_field.dart';
import 'support.dart';
import 'style_button.dart';
import 'camera_picker.dart';
import 'popover.dart';
import 'composer_toolbar.dart';
import 'generate_button.dart';
import 'spec_panel.dart';
import 'upload.dart';
import '../../widgets/agent_management/ai_providers_page.dart';
import '../../../shared/widgets/settings/provider_video_highlights.dart';

final _log = AppLogger.forModule('Production');

/// 将参考输入校验失败映射为当前渠道和模式下可操作的提示。
String productionReferenceErrorKey({
  required VideoChannelModel channel,
  required VideoMode mode,
  required List<VideoInputRole> roles,
}) {
  if (roles.contains(VideoInputRole.middle_frame) &&
      productionUsesFrames(mode) &&
      channel.capabilities.maxMiddleFrames == 0) {
    return LocaleKeys.productionGenerateMiddleFramesUnsupported;
  }
  if (!productionUsesFrames(mode)) {
    return channel.capabilities.allowsReferenceMode
        ? LocaleKeys.productionGenerateReferencesInvalid
        : LocaleKeys.productionGenerateReferenceUnsupported;
  }
  if (roles.any((role) => !channel.frameRoles.contains(role))) {
    return LocaleKeys.productionGenerateFramesUnsupported;
  }
  return LocaleKeys.productionGenerateFramesRequired;
}

class ProductionComposer extends HookConsumerWidget {
  const ProductionComposer({
    super.key,
    required this.service,
    required this.node,
    required this.session,
    required this.path,
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
  Widget build(BuildContext context, WidgetRef ref) {
    final loaded = useFuture(
      useMemoized(() async {
        final shot = node.clipId == null
            ? null
            : await service.shots.getShot(node.clipId!);
        return (
          clip: shot!,
          title: shot.title,
          episodeId: shot.episodeId,
          request: shotVideoRequest(shot),
          provider: shot.providerId,
          inputs: await service.draftInputs(node.id),
        );
      }, [node.id]),
    );
    // 本次提交是否出样片：只在输入框里生效，换节点即复位，不写进片段配置。
    final sample = useValueNotifier(false, [node.id]);
    if (loaded.hasError) {
      return Text(context.t(LocaleKeys.productionFailed));
    }
    if (!loaded.hasData) {
      return const SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final data = loaded.data!;
    return _ComposerForm(
      path: path,
      service: service,
      node: node,
      session: session,
      initial: data,
      clip: clip,
      sample: sample,
      onExternalChange: onExternalChange,
    );
  }
}

class _ComposerForm extends HookConsumerWidget {
  const _ComposerForm({
    required this.service,
    required this.node,
    required this.session,
    required this.initial,
    required this.path,
    required this.clip,
    required this.sample,
    required this.onExternalChange,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final ProductionEditSession session;
  final String path;
  final ProductionClipRow? clip;
  final ValueNotifier<bool> sample;
  final VoidCallback? onExternalChange;
  final ({
    ProductionClipRow clip,
    String title,
    String episodeId,
    VideoRequest request,
    String? provider,
    List<ProductionInput> inputs,
  })
  initial;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prompt = useMemoized(
      () => ProductionPromptController(initial.request.prompt),
      [node.id],
    );
    useEffect(() => prompt.dispose, [prompt]);
    final inputs = useState(initial.inputs);
    final busy = useState(false);
    final error = useState<String?>(null);
    final saved = useRef('');
    // 型号能力由启动时的远端登记决定；完成后重建，让型号下拉拿到最新的能力表。
    ref.watch(purefoxMediaModelsProvider);
    final form = useForm<ShotField>(
      listen: false,
      initialValues: {
        ShotField.title: initial.title,
        ShotField.model: (initial.provider ?? '', initial.request.modelId),
        ShotField.mode: initial.request.mode.name,
        ShotField.ratio: initial.request.ratio,
        ShotField.resolution: initial.request.resolution,
        ShotField.duration: '${initial.request.durationSeconds}',
        ShotField.generateAudio: initial.request.audio,
      },
      keys: [node.id],
    );
    final modelSelection = useListenableSelector(
      form,
      () => form.getValue<(String, String)>(ShotField.model),
    );
    final providers = useAiProviders(service.library.database);
    final selectedProvider = providers.data
        ?.where((p) => p.id == modelSelection?.$1)
        .firstOrNull;
    final modelConfig = selectedProvider == null
        ? null
        : lookupVideoChannelModel(selectedProvider.type, modelSelection?.$2);
    final tasks = useStream(
      useMemoized(
        () => service.library.database.generationTaskDao.watchSource(
          novelId: service.novelId,
          sourceType: 'production_clip',
          sourceId: node.clipId!,
        ),
        [service, node.id, node.clipId],
      ),
    );
    final sourceBusy = tasks.data?.any(GenerationTaskDao.blocksSource) ?? false;
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final overlay = ref.watch(workingOverlayServiceProvider(path));
    String value(ShotField field) => form.getValue<String>(field) ?? '';
    String signature() =>
        '${value(ShotField.title)}|${prompt.source}|${inputs.value.map((i) => '${i.identity}:${i.role.name}:${i.sourceNodeId}:${i.voiceAssetId}').join('|')}|${form.getValue<(String, String)>(ShotField.model)}|${value(ShotField.mode)}|${value(ShotField.ratio)}|${value(ShotField.resolution)}|${value(ShotField.duration)}|${form.getValue<bool>(ShotField.generateAudio)}';
    if (saved.value.isEmpty) {
      saved.value = signature();
    }
    prompt.inputIds = inputs.value.map((i) => i.id).toSet();
    prompt.onPreview = (id) => productionRun(context, () async {
      final input = inputs.value.firstWhere((i) => i.id == id);
      final asset = await service.inputAsset(input);
      if (context.mounted) {
        await previewProductionAsset(context, service, asset.id);
      }
    });
    // 改动自动保存：停手片刻后写入；离开节点、切视图或生成前先把没写完的立刻写掉。
    final pending = useRef<Timer?>(null);
    final writing = useRef<Future<bool>?>(null);
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
      final model = form.getValue<(String, String)>(ShotField.model)!;
      final duration = int.tryParse(value(ShotField.duration)) ?? 0;
      final signed = signature();
      try {
        await service.save(
          nodeId: node.id,
          title: value(ShotField.title),
          providerId: model.$1.isEmpty ? null : model.$1,
          request: VideoRequest(
            modelId: model.$2,
            prompt: prompt.source,
            mode: VideoMode.values.byName(value(ShotField.mode)),
            resolution: value(ShotField.resolution),
            ratio: value(ShotField.ratio),
            durationSeconds: duration,
            audio: form.getValue<bool>(ShotField.generateAudio),
          ),
          inputs: inputs.value,
          overlay: overlay,
        );
        saved.value = signed;
        external.sync((await service.shots.getShot(node.clipId!))!);
        if (context.mounted) {
          error.value = null;
        }
        return true;
      } catch (e, st) {
        _log.error('Composer autosave failed', error: e, stackTrace: st);
        if (context.mounted) {
          error.value = context.t(LocaleKeys.productionInvalid);
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
      final run = persist();
      writing.value = run;
      try {
        return await run;
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
        if (saved.value.isEmpty || saved.value == signature()) {
          return;
        }
        pending.value?.cancel();
        pending.value = Timer(const Duration(milliseconds: 600), save);
      }

      changes.addListener(schedule);
      return () {
        changes.removeListener(schedule);
        pending.value?.cancel();
      };
    }, [changes]);

    Future<bool> leave() => save();

    session.leave = leave;
    useEffect(() {
      return () {
        session.leave = null;
      };
    }, [session]);
    // 菜单在最近一次点按处向上弹出（输入框贴在节点下方）。
    final tapAt = useRef(Offset.zero);
    Future<void> menu<T>(
      List<(T, String)> choices,
      FutureOr<void> Function(T) onPicked,
    ) => showRevericContextMenu(
      context: context,
      position: tapAt.value,
      anchor: Alignment.bottomLeft,
      minWidth: 140,
      entries: [
        for (final (value, label) in choices)
          RevericMenuItem(
            label: label,
            onTap: () => productionRun(context, () async {
              if (context.mounted) {
                await onPicked(value);
              }
            }),
          ),
      ],
    );

    List<VideoInputRole> currentRoles() =>
        productionRoles(VideoMode.values.byName(value(ShotField.mode)))
            .where(
              (role) =>
                  role != VideoInputRole.middle_frame ||
                  (!productionUsesFrames(
                        VideoMode.values.byName(value(ShotField.mode)),
                      ) ||
                      (modelConfig?.capabilities.maxMiddleFrames ?? 0) > 0),
            )
            .toList();

    Future<void> attach(AssetRow asset, {bool reference = false}) async {
      final matching = currentRoles()
          .where((r) => r.kind.name == asset.type)
          .toList();
      void apply(VideoInputRole role) {
        if (!context.mounted) {
          return;
        }
        var input = inputs.value
            .where(
              (i) =>
                  i.refType == ProductionInputType.asset &&
                  i.refId == asset.id &&
                  i.role == role,
            )
            .firstOrNull;
        if (input == null) {
          input = ProductionInput.asset(asset.id, role);
          inputs.value = [...inputs.value, input];
        }
        if (reference) {
          prompt.insertReference(input.id, asset.name);
        }
      }

      if (matching.length == 1) {
        apply(matching.single);
      } else {
        await menu([
          for (final role in matching)
            (
              role,
              productionRole(
                context,
                role,
                mode: VideoMode.values.byName(value(ShotField.mode)),
              ),
            ),
        ], apply);
      }
    }

    Future<void> pickReference() async {
      final asset = await pickProductionAsset(
        context,
        service,
        types: currentRoles().map((r) => r.kind.name).toSet(),
        confirmLabel: context.t(LocaleKeys.productionAddInput),
      );
      if (asset != null && context.mounted) {
        await attach(asset, reference: true);
      }
    }

    Future<void> reference() async {
      final allowed = productionRoles(
        VideoMode.values.byName(value(ShotField.mode)),
      );
      final candidates = inputs.value
          .where((i) => allowed.contains(i.role))
          .toList();
      final labels = <String, String>{};
      for (final input in candidates) {
        labels[input.identity] = await service.inputName(input);
      }
      if (!context.mounted) {
        return;
      }
      await menu(
        [
          for (final input in candidates)
            (
              input.identity,
              labels[input.identity]!.isEmpty
                  ? input.identity
                  : labels[input.identity]!,
            ),
          ('library', context.t(LocaleKeys.productionAddInput)),
        ],
        (selected) async {
          if (selected == 'library') {
            await pickReference();
            return;
          }
          final input = candidates.firstWhere((i) => i.identity == selected);
          prompt.insertReference(
            input.id,
            labels[selected]!.isEmpty ? selected : labels[selected]!,
          );
        },
      );
    }

    Future<void> generate({bool draft = false}) async {
      if (busy.value || sourceBusy) {
        return;
      }
      busy.value = true;
      if (!await save() || !context.mounted) {
        if (context.mounted) {
          busy.value = false;
        }
        return;
      }
      await productionRun(context, () async {
        final operation = ProductionGenerateOrchestrator();
        final preview = await operation.preview(service, node.id, draft: draft);
        if (!context.mounted) {
          return;
        }
        final tasks = await ref.read(videoTaskServiceProvider.future);
        final needsStorage = await tasks.needsReferenceUpload(
          providerId: preview.providerId,
          modelId: preview.request.modelId,
          assetIds: preview.inputs.map((input) => input.assetId),
        );
        if (needsStorage &&
            (!context.mounted ||
                !await ensureReferenceStorage(
                  context,
                  ref.read(referenceStorageServiceProvider),
                  providerId: preview.providerId,
                  modelId: preview.request.modelId,
                  inputs: preview.inputs
                      .map(
                        (input) => VideoInput(
                          role: input.role,
                          assetId: input.assetId,
                          mimeType: input.mimeType,
                        ),
                      )
                      .toList(),
                ))) {
          return;
        }
        await operation.submit(
          service,
          tasks,
          preview,
          acknowledgeReferenceUpload: true,
        );
      });
      if (context.mounted) {
        busy.value = false;
      }
    }

    final mode = useListenableSelector(
      form,
      () => VideoMode.values.byName(value(ShotField.mode)),
    );
    final generateAudio = useListenableSelector(
      form,
      () => form.getValue<bool>(ShotField.generateAudio),
    );
    final ratio = useListenableSelector(form, () => value(ShotField.ratio));
    final resolution = useListenableSelector(
      form,
      () => value(ShotField.resolution),
    );
    final allowed = productionRoles(mode);
    final supportsMiddleFrames =
        !productionUsesFrames(mode) ||
        (modelConfig?.capabilities.maxMiddleFrames ?? 0) > 0;
    final displayInputs = productionUsesFrames(mode)
        ? [
            for (final role in [
              VideoInputRole.first_frame,
              VideoInputRole.middle_frame,
              VideoInputRole.last_frame,
            ])
              ...inputs.value.where((input) => input.role == role),
            ...inputs.value.where(
              (input) => ![
                VideoInputRole.first_frame,
                VideoInputRole.middle_frame,
                VideoInputRole.last_frame,
              ].contains(input.role),
            ),
          ]
        : inputs.value;
    final audioKey = inputs.value
        .where(
          (i) => i.role.kind == VideoMediaKind.audio || i.voiceAssetId != null,
        )
        .map((i) => '${i.identity}:${i.role.name}:${i.voiceAssetId}')
        .join('|');
    final audioNames = useFuture(
      useMemoized(
        () => service.audioInputNames(
          inputs.value.where((i) => allowed.contains(i.role)).toList(),
        ),
        [service, audioKey, mode],
      ),
    );
    String tooManyAudio() {
      final untitled = context.t(LocaleKeys.commonUntitled);
      final separator = Localizations.localeOf(context).languageCode == 'zh'
          ? '、'
          : ', ';
      String join(List<String?> names) =>
          names.map((n) => n ?? untitled).join(separator);
      final names = audioNames.data;
      return [
        context.t(LocaleKeys.productionGenerateTooManyAudio),
        if (names != null && names.audio.isNotEmpty)
          context.t(
            LocaleKeys.productionGenerateAudioInputs,
            namedArgs: {'names': join(names.audio)},
          ),
        if (names != null && names.voices.isNotEmpty)
          context.t(
            LocaleKeys.productionGenerateVoiceInputs,
            namedArgs: {'names': join(names.voices)},
          ),
      ].join('\n');
    }

    String? generationBlockedReason({bool draft = false}) {
      if (busy.value || sourceBusy) {
        return context.t(LocaleKeys.productionGenerateBusy);
      }
      if (!providers.hasData || !tasks.hasData) {
        return context.t(
          providers.hasError || tasks.hasError
              ? LocaleKeys.productionFailed
              : LocaleKeys.productionGenerateChecking,
        );
      }
      final model = form.getValue<(String, String)>(ShotField.model);
      final provider = providers.data!
          .where((p) => p.id == model?.$1)
          .firstOrNull;
      if (provider == null ||
          !provider.enabled ||
          !provider.videoModels.contains(model?.$2) ||
          !productionSupportsVideoModel(provider.type, model?.$2)) {
        return context.t(LocaleKeys.productionGenerateModelRequired);
      }
      if (provider.apiKey.trim().isEmpty) {
        return context.t(LocaleKeys.productionGenerateProviderRequired);
      }
      if (productionUsesFrames(mode) &&
          inputs.value.any((i) => i.voiceAssetId != null)) {
        return context.t(LocaleKeys.productionVoiceMode);
      }
      final activeInputs = productionInputsWithVoices(
        inputs.value,
      ).where((input) => allowed.contains(input.role)).toList();
      final roles = activeInputs
          .map((input) => productionSubmitRole(mode, input.role))
          .toList();
      final parsed = StoryboardPrompt.parse(prompt.source);
      if (parsed.parts.any(
        (part) =>
            part.isReference &&
            !activeInputs.any((input) => input.id == part.inputId),
      )) {
        return context.t(LocaleKeys.productionGenerateReferenceMissing);
      }
      try {
        VideoCapabilities(provider.type).validateParameters(
          compileProductionPrompt(
            provider.type,
            VideoRequest(
              modelId: model!.$2,
              prompt: prompt.source,
              mode: productionSubmitMode(mode, roles),
              resolution: draft
                  ? videoDraftResolution
                  : value(ShotField.resolution),
              ratio: value(ShotField.ratio),
              durationSeconds: int.tryParse(value(ShotField.duration)) ?? 0,
              audio: modelConfig?.requiresAudio == true
                  ? form.getValue<bool>(ShotField.generateAudio) ??
                        modelConfig?.requestDefaults.audio
                  : null,
              promptExtend: modelConfig?.requestDefaults.promptExtend,
            ),
            [
              for (final input in activeInputs)
                ResolvedProductionInput(input, input.refId),
            ],
          ),
          roles,
        );
      } on VideoException catch (e) {
        if (e.field == 'audio_reference') {
          return context.t(
            LocaleKeys.productionGenerateVisualReferenceRequired,
          );
        }
        if (e.field == 'references') {
          return context.t(
            productionReferenceErrorKey(
              channel: lookupVideoChannelModel(provider.type, model!.$2)!,
              mode: mode,
              roles: roles,
            ),
          );
        }
        if (e.field == 'audio_count') {
          return tooManyAudio();
        }
        if (e.field?.endsWith('_count') ?? false) {
          return context.t(LocaleKeys.productionGenerateTooManyInputs);
        }
        final field = switch (e.field) {
          'model' => LocaleKeys.storyboardModel,
          'prompt' => LocaleKeys.storyboardPrompt,
          'resolution' => LocaleKeys.storyboardResolution,
          'ratio' => LocaleKeys.storyboardRatio,
          'duration' => LocaleKeys.storyboardDuration,
          _ => null,
        };
        return field == null
            ? context.t(LocaleKeys.productionInvalid)
            : context.t(
                LocaleKeys.productionGenerateInvalidField,
                namedArgs: {'field': context.t(field)},
              );
      }
      return null;
    }

    final expanded = useState(false);
    Widget pill(
      ShotField field,
      List<String> choices, {
      double? width,
      String Function(String)? label,
      ValueChanged<String>? onPicked,
    }) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.sm),
      child: IntrinsicWidth(
        child: SizedBox(
          width: width,
          child: HookedFormField<ShotField, String>(
            fieldHook: field,
            notifyOnChange: true,
            builder: (value, onChanged, error) => RevericSelect<String>(
              value: value,
              compact: true,
              dropUp: true,
              height: 30,
              menuWidth: math.max(width ?? 0, 120),
              textStyle: typo.uiSmall,
              items: choices
                  .map(
                    (v) =>
                        RevericSelectItem(value: v, label: label?.call(v) ?? v),
                  )
                  .toList(),
              onChanged: (v) {
                onChanged?.call(v);
                onPicked?.call(v);
              },
            ),
          ),
        ),
      ),
    );
    final supportsDraft = modelConfig?.protocolOptions.supportsDraft == true;
    final frames = productionUsesFrames(mode);
    final ratios =
        frames &&
            modelConfig?.protocolOptions.framesRequireAdaptiveRatio == true
        ? const ['adaptive']
        : [
            for (final ratio in modelConfig?.ratios ?? <String>{})
              if (frames ||
                  modelConfig!.supportsAdaptiveTextRatio ||
                  ratio != 'adaptive')
                ratio,
          ];
    Future<void> insertCamera() async {
      final camera = await pickProductionCamera(context);
      if (camera == null || !context.mounted) {
        return;
      }
      final start = prompt.selection.isValid
          ? prompt.selection.start
          : prompt.text.length;
      final end = prompt.selection.isValid
          ? prompt.selection.end
          : prompt.text.length;
      prompt.value = TextEditingValue(
        text: prompt.text.replaceRange(start, end, camera),
        selection: TextSelection.collapsed(offset: start + camera.length),
      );
    }

    return Listener(
      onPointerDown: (e) => tapAt.value = e.position,
      child: Material(
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
                      types: allowed.map((r) => r.kind.name).toSet(),
                      enabled: !busy.value,
                      onPicked: attach,
                    ),
                    ProductionToolChip(
                      icon: RevericIcons.at,
                      label: context.t(LocaleKeys.productionMention),
                      tooltip: context.t(LocaleKeys.productionReference),
                      onTap: busy.value
                          ? null
                          : () => productionRun(context, reference),
                    ),
                    ProductionToolChip(
                      icon: RevericIcons.video_camera,
                      label: context.t(LocaleKeys.productionCameraLibrary),
                      onTap: busy.value
                          ? null
                          : () => productionRun(context, insertCamera),
                    ),
                  ],
                ),
                if (displayInputs.isNotEmpty) ...[
                  const SizedBox(height: RevericSpacing.sm),
                  Wrap(
                    spacing: RevericSpacing.sm,
                    runSpacing: RevericSpacing.sm,
                    children: [
                      for (var i = 0; i < displayInputs.length; i++)
                        ProductionCharacterInput(
                          key: ValueKey(displayInputs[i].identity),
                          service: service,
                          input: displayInputs[i],
                          framesMode: frames,
                          onChanged: (input) {
                            final next = [...inputs.value];
                            next[next.indexWhere(
                                  (item) => item.id == displayInputs[i].id,
                                )] =
                                input;
                            inputs.value = next;
                          },
                          child: ProductionInputTile(
                            service: service,
                            input: displayInputs[i],
                            mode: mode,
                            valid:
                                allowed.contains(displayInputs[i].role) &&
                                (displayInputs[i].role !=
                                        VideoInputRole.middle_frame ||
                                    supportsMiddleFrames),
                            supportsMiddleFrames: supportsMiddleFrames,
                            middleFrameIndex: displayInputs[i].middleFrameIndex(
                              inputs.value,
                            ),
                            onRole: (r) {
                              final next = [...inputs.value];
                              final index = next.indexWhere(
                                (item) => item.id == displayInputs[i].id,
                              );
                              next[index] = next[index].withRole(r);
                              inputs.value = next;
                            },
                            onMove:
                                displayInputs.length < 2 ||
                                    (productionUsesFrames(mode) &&
                                        displayInputs[i].role !=
                                            VideoInputRole.middle_frame)
                                ? null
                                : (delta) {
                                    final to = i + delta;
                                    if (to < 0 ||
                                        to >= displayInputs.length ||
                                        (productionUsesFrames(mode) &&
                                            displayInputs[to].role !=
                                                VideoInputRole.middle_frame)) {
                                      return;
                                    }
                                    final next = [...displayInputs];
                                    next.insert(to, next.removeAt(i));
                                    inputs.value = next;
                                  },
                            onRemove: () {
                              inputs.value = inputs.value
                                  .where(
                                    (input) => input.id != displayInputs[i].id,
                                  )
                                  .toList();
                            },
                          ),
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
                        footer: false,
                        maxLines: null,
                        onReference: () => productionRun(context, reference),
                      ),
                    ),
                  ),
                ),
                if (error.value != null)
                  Padding(
                    padding: const EdgeInsets.only(top: RevericSpacing.xs),
                    child: Text(
                      error.value!,
                      style: typo.uiTiny.copyWith(color: colors.error),
                    ),
                  ),
                const SizedBox(height: RevericSpacing.sm),
                ProductionComposerToolbar(
                  submit: ListenableBuilder(
                    listenable: Listenable.merge([changes, sample]),
                    builder: (context, _) {
                      final draft = supportsDraft && sample.value;
                      return ProductionGenerateButton(
                        blocked: generationBlockedReason(draft: draft),
                        draft: draft,
                        repeat: tasks.data?.isNotEmpty ?? false,
                        onGenerate: () => generate(draft: draft),
                      );
                    },
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
                          notifyOnChange: true,
                          fieldHook: ShotField.model,
                          builder: (value, onChanged, error) =>
                              RevericSelect<(String, String)>(
                                value: value,
                                placeholder: context.t(
                                  LocaleKeys.storyboardModel,
                                ),
                                compact: true,
                                dropUp: true,
                                searchable: true,
                                height: 30,
                                menuWidth: 300,
                                leadingIcon: RevericIcons.auto_awesome,
                                onEmptyTap: () =>
                                    showAiProviderSettingsDialog(context),
                                footerAction: (
                                  label: context.t(LocaleKeys.aiAddModel),
                                  onTap: () =>
                                      showAiProviderSettingsDialog(context),
                                ),
                                textStyle: typo.uiSmall,
                                items: [
                                  for (final p in providers.data ?? [])
                                    if (p.enabled)
                                      for (final model in p.videoModels.where(
                                        (m) => productionSupportsVideoModel(
                                          p.type,
                                          m,
                                        ),
                                      ))
                                        RevericSelectItem(
                                          value: (p.id, model),
                                          label: model,
                                          subtitle: p.name,
                                          badges: providerVideoHighlights(
                                            context,
                                            p.type,
                                            model,
                                            dense: true,
                                          ),
                                          notice: providerVideoNotice(
                                            context,
                                            p.type,
                                            model,
                                          ),
                                        ),
                                ],
                                onChanged: (v) {
                                  onChanged?.call(v);
                                  final provider = providers.data!.firstWhere(
                                    (p) => p.id == v.$1,
                                  );
                                  final next = lookupVideoChannelModel(
                                    provider.type,
                                    v.$2,
                                  )!;
                                  if (!next.protocolOptions.supportsDraft) {
                                    sample.value = false;
                                  }
                                  final currentDuration = int.tryParse(
                                    form.getValue<String>(ShotField.duration) ??
                                        '',
                                  );
                                  if (currentDuration == null ||
                                      !next
                                          .durationsForResolution(
                                            form.getValue<String>(
                                                  ShotField.resolution,
                                                ) ??
                                                next.resolutions.first,
                                          )
                                          .contains(currentDuration)) {
                                    form.updateValue(
                                      ShotField.duration,
                                      '${next.minDurationSeconds}',
                                    );
                                  }
                                  final ratios =
                                      frames &&
                                          next
                                              .protocolOptions
                                              .framesRequireAdaptiveRatio
                                      ? ['adaptive']
                                      : next.ratios.toList();
                                  if (!ratios.contains(
                                    form.getValue<String>(ShotField.ratio),
                                  )) {
                                    form.updateValue(
                                      ShotField.ratio,
                                      ratios.first,
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
                      ratios: ratios,
                      resolutions: modelConfig?.resolutions.toList() ?? [],
                      ratio: ratio,
                      resolution: resolution,
                      sample: supportsDraft ? sample : null,
                      audio: modelConfig?.requiresAudio == true
                          ? generateAudio ?? modelConfig?.requestDefaults.audio
                          : null,
                      onAudio: (value) {
                        form.updateValue(ShotField.generateAudio, value);
                      },
                      onChanged: ({ratio, resolution}) {
                        if (ratio != null) {
                          form.updateValue(ShotField.ratio, ratio);
                        }
                        if (resolution != null) {
                          form.updateValue(ShotField.resolution, resolution);
                          final duration = int.tryParse(
                            form.getValue<String>(ShotField.duration) ?? '',
                          );
                          final allowed = modelConfig?.durationsForResolution(
                            resolution,
                          );
                          if (allowed != null && !allowed.contains(duration)) {
                            form.updateValue(
                              ShotField.duration,
                              '${allowed.last}',
                            );
                          }
                        }
                      },
                    ),
                    pill(
                      ShotField.duration,
                      [
                        if (modelConfig != null)
                          for (
                            var s = modelConfig.minDurationSeconds;
                            s <= modelConfig.maxDurationSeconds;
                            s++
                          )
                            if (modelConfig
                                .durationsForResolution(resolution)
                                .contains(s))
                              '$s',
                      ],
                      width: 40,
                      label: (s) => '${s}s',
                    ),
                    pill(
                      ShotField.mode,
                      [
                        VideoMode.reference.name,
                        VideoMode.first_last_frame.name,
                      ],
                      label: (m) => context.t(
                        m == VideoMode.reference.name
                            ? LocaleKeys.storyboardReference
                            : LocaleKeys.storyboardFirstLastFrame,
                      ),
                      onPicked: (m) {
                        if (m == VideoMode.first_last_frame.name &&
                            modelConfig
                                    ?.protocolOptions
                                    .framesRequireAdaptiveRatio ==
                                true) {
                          form.updateValue(ShotField.ratio, 'adaptive');
                        } else if (m == VideoMode.reference.name &&
                            modelConfig?.supportsAdaptiveTextRatio != true &&
                            value(ShotField.ratio) == 'adaptive') {
                          form.updateValue(ShotField.ratio, '9:16');
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

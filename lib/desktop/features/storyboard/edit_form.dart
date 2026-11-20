// 职责: 编辑分镜或剧本输出默认值，保留未保存输入并统一提交。
// 关联文件:
//   lib/shared/providers/storyboard.dart
//   lib/shared/services/storyboard/edit_orchestrator.dart
//   lib/shared/form/form.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/form.md
import '../../../shared/hooks/use_ai_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_select.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/models/ai_provider.dart';
import '../../../shared/models/production/settings.dart';
import '../../../shared/models/production/view_presets.dart';
import '../../../shared/form/form.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/storyboard.dart';
import '../../../shared/services/storyboard/edit_orchestrator.dart';
import '../../../shared/services/storyboard/service.dart';
import '../../../shared/theme/theme.dart';
import 'support.dart';

enum ShotField<T> implements FieldSchema {
  title<String>(),
  prompt<String>(),
  model<(String, String)>(),
  imagePreset<ImageGenerationPreset>(),
  generateAudio<bool>(),
  audioVoice<String>(),
  audioInstructions<String>(),
  mode<String>(),
  duration<String>(),
  ratio<String>(),
  resolution<String>();

  const ShotField();
  @override
  List<Validator<dynamic>>? get validators => null;
}

class ShotEditForm extends HookConsumerWidget {
  const ShotEditForm({
    super.key,
    required this.path,
    required this.novelId,
    required this.sceneId,
    this.shot,
    this.production,
  });
  final String path;
  final String novelId;
  final String sceneId;
  final ProductionClipRow? shot;
  final ScreenplayRow? production;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(
      storyboardServiceProvider(path, novelId: novelId),
    );
    final overlay = ref.watch(
      workOverlayServiceProvider((path: path, novelId: novelId)),
    );
    final appDb = ref.watch(appDatabaseProvider);
    final providers = useAiProviders(appDb);
    final saving = useState(false);
    final error = useState<String?>(null);
    final form = useForm<ShotField>(
      initialValues: {
        ShotField.title: shot?.title ?? '',
        ShotField.prompt: shot?.prompt ?? '',
        ShotField.model: (shot?.providerId ?? '', shot?.modelId ?? ''),
        ShotField.mode: shot?.referenceMode ?? 'reference',
        ShotField.duration: shot?.durationMs == null
            ? ''
            : '${shot!.durationMs! / 1000}',
        ShotField.ratio: shot?.ratio ?? production?.ratio ?? '16:9',
        ShotField.resolution:
            shot?.resolution ?? production?.resolution ?? '720p',
      },
      keys: [shot?.id, production?.id, sceneId],
    );
    final image = shot?.kind == 'image';
    final settings = production != null && sceneId.isEmpty;
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    Future<bool> save() async {
      if (saving.value || !form.validate()) {
        return false;
      }
      saving.value = true;
      error.value = null;
      try {
        String text(ShotField field) => form.getValue<String>(field) ?? '';
        final values = <String, dynamic>{
          'ratio': text(ShotField.ratio),
          'resolution': text(ShotField.resolution),
        };
        if (settings) {
          await service.saveSettings(values);
        } else {
          final durationText = text(ShotField.duration).trim();
          final duration = double.tryParse(durationText);
          if (durationText.isNotEmpty &&
              (duration == null || !duration.isFinite || duration <= 0)) {
            throw const StoryboardException('invalid_config');
          }
          final model = form.getValue<(String, String)>(ShotField.model)!;
          values.addAll({
            'title': text(ShotField.title),
            'prompt': text(ShotField.prompt),
            if (!image) 'reference_mode': text(ShotField.mode),
            'provider_id': model.$1.isEmpty ? null : model.$1,
            'model_id': model.$2.isEmpty ? null : model.$2,
            if (!image)
              'duration_ms': duration == null
                  ? null
                  : (duration * 1000).round(),
            'resolution': text(ShotField.resolution),
          });
          if (shot == null) {
            await StoryboardEditOrchestrator().create(
              service: service,
              overlay: overlay,
              sceneId: sceneId,
              values: values,
            );
          } else {
            await StoryboardEditOrchestrator().save(
              service: service,
              overlay: overlay,
              shotId: shot!.id,
              values: values,
            );
          }
        }
        return true;
      } catch (e) {
        if (context.mounted) {
          error.value = shotError(context, e);
        }
        return false;
      } finally {
        if (context.mounted) {
          saving.value = false;
        }
      }
    }

    Future<void> close() async {
      if (saving.value) {
        return;
      }
      if (settings || !form.hasChanged) {
        Navigator.of(context).pop();
        return;
      }
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(context.t(LocaleKeys.storyboardUnsaved)),
          content: Text(context.t(LocaleKeys.storyboardUnsavedDetail)),
          actions: [
            RevericButton.text(
              label: context.t(LocaleKeys.storyboardStay),
              onPressed: () => Navigator.pop(ctx, 'stay'),
            ),
            RevericButton.text(
              label: context.t(LocaleKeys.storyboardDiscard),
              onPressed: () => Navigator.pop(ctx, 'discard'),
            ),
            RevericButton.primary(
              label: context.t(LocaleKeys.commonSave),
              onPressed: () => Navigator.pop(ctx, 'save'),
            ),
          ],
        ),
      );
      if (action == 'discard' || (action == 'save' && await save())) {
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      }
    }

    Widget input(ShotField field, String key, {bool multiline = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: RevericSpacing.lg),
          child: HookedTextFormField(
            fieldHook: field,
            label: context.t(key),
            multiline: multiline,
            minLines: 5,
            maxLines: 10,
            enabled: !saving.value,
          ),
        );
    Widget select(
      ShotField field,
      String label,
      List<RevericSelectItem<String>> items,
    ) => Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.lg),
      child: HookedFormField<ShotField, String>(
        fieldHook: field,
        builder: (value, onChanged, fieldError) => RevericSelect<String>(
          value: value,
          label: context.t(label),
          items: items,
          enabled: !saving.value,
          onChanged: (v) => onChanged?.call(v),
        ),
      ),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          close();
        }
      },
      child: AlertDialog(
        title: Text(
          context.t(
            settings
                ? LocaleKeys.storyboardSettings
                : shot == null
                ? LocaleKeys.commonCreate
                : LocaleKeys.commonEdit,
          ),
        ),
        content: SizedBox(
          width: RevericSizes.dialogWidth * 1.5,
          child: HookedForm(
            form: form,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!settings) ...[
                    input(ShotField.title, LocaleKeys.storyboardTitle),
                    input(
                      ShotField.prompt,
                      LocaleKeys.storyboardPrompt,
                      multiline: true,
                    ),
                    if (providers.hasError)
                      Text(
                        context.t(LocaleKeys.storyboardError),
                        style: typo.ui.copyWith(color: colors.error),
                      ),
                    HookedFormField<ShotField, (String, String)>(
                      fieldHook: ShotField.model,
                      builder: (value, onChanged, fieldError) =>
                          RevericSelect<(String, String)>(
                            value: value,
                            label: context.t(LocaleKeys.storyboardModel),
                            enabled: providers.hasData && !saving.value,
                            items: [
                              RevericSelectItem(
                                value: ('', ''),
                                label: context.t(
                                  LocaleKeys.storyboardUnconfigured,
                                ),
                              ),
                              if (shot?.providerId != null &&
                                  !(providers.data ?? []).any(
                                    (p) =>
                                        p.id == shot!.providerId &&
                                        (image
                                                ? p.availableImageModels
                                                : p.videoModels)
                                            .contains(shot!.modelId),
                                  ))
                                RevericSelectItem(
                                  value: (shot!.providerId!, shot!.modelId!),
                                  label: shot!.modelId!,
                                ),
                              for (final provider in providers.data ?? [])
                                for (final model
                                    in (image
                                        ? provider.availableImageModels
                                        : provider.videoModels))
                                  RevericSelectItem(
                                    value: (provider.id, model),
                                    label: '${provider.name} · $model',
                                  ),
                            ],
                            onChanged: (v) => onChanged?.call(v),
                          ),
                    ),
                    const SizedBox(height: RevericSpacing.lg),
                    if (!image)
                      select(ShotField.mode, LocaleKeys.storyboardMode, [
                        for (final entry in {
                          'reference': LocaleKeys.storyboardReference,
                          'first_last_frame':
                              LocaleKeys.storyboardFirstLastFrame,
                        }.entries)
                          RevericSelectItem(
                            value: entry.key,
                            label: context.t(entry.value),
                          ),
                      ]),
                    if (!image)
                      input(ShotField.duration, LocaleKeys.storyboardDuration),
                    input(
                      ShotField.resolution,
                      LocaleKeys.storyboardResolution,
                    ),
                  ],
                  if (settings) ...[
                    select(ShotField.ratio, LocaleKeys.storyboardRatio, [
                      for (final value in ProductionSettings.ratios)
                        RevericSelectItem(value: value, label: value),
                    ]),
                    select(
                      ShotField.resolution,
                      LocaleKeys.storyboardResolution,
                      [
                        for (final value in ProductionSettings.resolutions)
                          RevericSelectItem(value: value, label: value),
                      ],
                    ),
                  ] else ...[
                    input(ShotField.ratio, LocaleKeys.storyboardRatio),
                  ],
                  if (error.value != null)
                    Text(
                      error.value!,
                      style: typo.ui.copyWith(color: colors.error),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          RevericButton.text(
            label: context.t(LocaleKeys.commonCancel),
            onPressed: saving.value ? null : close,
          ),
          RevericButton.primary(
            label: context.t(LocaleKeys.commonSave),
            loading: saving.value,
            onPressed: () async {
              if (await save() && context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
    );
  }
}

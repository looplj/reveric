// 职责: 配置朗读模型、角色音色与旁白范围，校验并保存后提交播放计划。
// 关联文件:
//   lib/desktop/features/narration/dialog.dart
//   lib/desktop/features/narration/voice.dart
//   lib/shared/models/narration.dart
//   lib/shared/providers/narration.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/form.md

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_checkbox.dart';
import '../../../shared/components/reveric_placeholder.dart';
import '../../../shared/components/reveric_select.dart';
import '../../../shared/form/form.dart';
import '../../../shared/hooks/use_ai_providers.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/audio/channels.dart';
import '../../../shared/models/narration.dart';
import '../../../shared/providers/narration.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../widgets/agent_management/ai_providers_page.dart';
import 'errors.dart';
import 'voice.dart';

final _log = AppLogger.forModule('Narration');

typedef NarrationPlan = ({
  NarrationSettings settings,
  List<NarrationSegment> segments,
});

enum _Field<T> implements FieldSchema {
  model<(String, String)>(),
  narrator<String>(),
  voices<Map<String, String>>(),
  includeNarration<bool>();

  const _Field();
  @override
  List<Validator<T>>? get validators => null;
}

class NarrationSetup extends HookConsumerWidget {
  const NarrationSetup({
    super.key,
    required this.workId,
    required this.source,
    required this.initial,
    required this.onStart,
  });
  final String workId;
  final NarrationSource source;
  final NarrationSettings initial;
  final ValueChanged<NarrationPlan> onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = useForm<_Field>(
      initialValues: {
        _Field.model: (initial.providerId, initial.modelId),
        _Field.narrator: initial.narrator,
        _Field.voices: initial.voices,
        _Field.includeNarration: initial.includeNarration,
      },
    );
    final busy = useState(false);
    final error = useState<Object?>(null);
    final providers = useAiProviders(ref.watch(appDatabaseProvider));
    final model = form.getValue<(String, String)>(_Field.model)!;
    final choices = [
      for (final provider in providers.data ?? [])
        if (provider.enabled)
          for (final id in provider.audioModels)
            if (lookupAudioChannelModel(
                  provider.type,
                  id,
                )?.capabilities.speech ==
                true)
              (provider: provider, id: id),
    ];
    final selected = choices
        .where((c) => c.provider.id == model.$1 && c.id == model.$2)
        .firstOrNull;
    final capability = selected == null
        ? null
        : lookupAudioChannelModel(
            selected.provider.type,
            selected.id,
          )!.capabilities;
    final voices = form.getValue<Map<String, String>>(_Field.voices)!;
    final narrator = form.getValue<String>(_Field.narrator)!;
    final include = form.getValue<bool>(_Field.includeNarration)!;
    final typo = RevericTheme.typographyOf(context);
    final colors = RevericTheme.colorsOf(context);

    Future<void> start() async {
      if (busy.value || !form.validate() || selected == null) {
        return;
      }
      busy.value = true;
      error.value = null;
      final service = ref.read(narrationServiceProvider);
      try {
        final settings = NarrationSettings(
          providerId: model.$1,
          modelId: model.$2,
          narrator: narrator,
          includeNarration: include,
          voices: Map.fromEntries(
            voices.entries.where((e) => e.value.trim().isNotEmpty),
          ),
        );
        final segments = compileNarration(
          source,
          settings,
          maxCharacters: math.min(500, capability!.maxPromptCharacters),
          supportsInstructions: capability.supportsInstructions,
        );
        if (!context.mounted) {
          return;
        }
        await service.save(workId, settings);
        if (context.mounted) {
          onStart((settings: settings, segments: segments));
        }
      } catch (failure, stack) {
        _log.error('setup failed', error: failure, stackTrace: stack);
        if (context.mounted) {
          error.value = failure;
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    if (providers.hasError) {
      return RevericPlaceholder.error(
        title: context.t(LocaleKeys.narrationFailed),
      );
    }
    if (!providers.hasData) {
      return const Center(child: CircularProgressIndicator());
    }
    if (choices.isEmpty) {
      return Center(
        child: RevericPlaceholder.empty(
          icon: RevericIcons.music_notes,
          title: context.t(LocaleKeys.narrationNoModels),
          description: context.t(LocaleKeys.narrationNoModelsHint),
          action: RevericButton.secondary(
            label: context.t(LocaleKeys.narrationConfigure),
            onPressed: () => showAiProviderSettingsDialog(context),
          ),
        ),
      );
    }
    final modelSelect = RevericSelect<(String, String)>(
      label: context.t(LocaleKeys.narrationModel),
      value: selected == null ? null : model,
      enabled: !busy.value,
      placeholder: context.t(LocaleKeys.narrationChooseModel),
      items: [
        for (final choice in choices)
          RevericSelectItem(
            value: (choice.provider.id, choice.id),
            label: choice.id,
            subtitle: choice.provider.name,
          ),
      ],
      onChanged: (value) {
        form.updateValue(_Field.model, value);
        final choice = choices.firstWhere(
          (c) => (c.provider.id, c.id) == value,
        );
        final available = lookupAudioChannelModel(
          choice.provider.type,
          choice.id,
        )!.capabilities.voices;
        form.updateValue(_Field.narrator, available.firstOrNull ?? '');
        form.updateValue(_Field.voices, <String, String>{
          for (final (index, id) in source.characterIds.indexed)
            if (available.isNotEmpty)
              id: available[(index + 1) % available.length],
        });
      },
    );
    return HookedForm(
      form: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 两列等宽排布，字段与角色音色共用同一网格。
                  final cell = (constraints.maxWidth - RevericSpacing.x2l) / 2;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        context.t(LocaleKeys.narrationHint),
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                      const SizedBox(height: RevericSpacing.x3l),
                      Wrap(
                        spacing: RevericSpacing.x2l,
                        runSpacing: RevericSpacing.lg,
                        children: [
                          SizedBox(width: cell, child: modelSelect),
                          if (capability != null)
                            SizedBox(
                              width: cell,
                              child: IgnorePointer(
                                ignoring: busy.value,
                                child: NarrationVoiceSelect(
                                  label: context.t(
                                    LocaleKeys.narrationNarrator,
                                  ),
                                  allowNarrator: false,
                                  value: narrator,
                                  voices: capability.voices,
                                  onChanged: (value) {
                                    form.updateValue(_Field.narrator, value);
                                  },
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (capability != null) ...[
                        const SizedBox(height: RevericSpacing.sm),
                        MergeSemantics(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(
                              RevericRadius.medium,
                            ),
                            onTap: busy.value
                                ? null
                                : () {
                                    form.updateValue(
                                      _Field.includeNarration,
                                      !include,
                                    );
                                  },
                            child: Row(
                              children: [
                                RevericCheckbox(
                                  value: include,
                                  onChanged: busy.value
                                      ? null
                                      : (value) {
                                          form.updateValue(
                                            _Field.includeNarration,
                                            value,
                                          );
                                        },
                                ),
                                Expanded(
                                  child: Text(
                                    context.t(LocaleKeys.narrationInclude),
                                    style: typo.ui.copyWith(
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (source.characterIds.isNotEmpty) ...[
                          const SizedBox(height: RevericSpacing.x2l),
                          Divider(height: 1, color: colors.borderSubtle),
                          const SizedBox(height: RevericSpacing.x2l),
                          Text(
                            context.t(LocaleKeys.narrationCharacters),
                            style: typo.uiSmallSemibold.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                          const SizedBox(height: RevericSpacing.lg),
                          Wrap(
                            spacing: RevericSpacing.x2l,
                            runSpacing: RevericSpacing.lg,
                            children: [
                              for (final id in source.characterIds)
                                SizedBox(
                                  width: cell,
                                  child: IgnorePointer(
                                    ignoring: busy.value,
                                    child: NarrationVoiceSelect(
                                      label:
                                          source.characterNames[id] ??
                                          context.t(
                                            LocaleKeys
                                                .screenplayDeletedCharacter,
                                          ),
                                      value: voices[id] ?? '',
                                      voices: capability.voices,
                                      onChanged: (value) {
                                        form.updateValue(_Field.voices, {
                                          ...voices,
                                          id: value,
                                        });
                                      },
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: RevericSpacing.x2l),
          Row(
            children: [
              Expanded(
                child: error.value == null
                    ? const SizedBox.shrink()
                    : Text(
                        narrationErrorText(context, error.value!),
                        style: typo.uiSmall.copyWith(color: colors.warningText),
                      ),
              ),
              const SizedBox(width: RevericSpacing.lg),
              RevericButton.primary(
                label: context.t(LocaleKeys.commonPlay),
                icon: RevericIcons.play_arrow,
                loading: busy.value,
                onPressed: selected == null || narrator.trim().isEmpty
                    ? null
                    : start,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

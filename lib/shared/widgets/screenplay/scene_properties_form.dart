// 职责: 编辑并保存场次属性，复用正文会话的校验、审阅与撤销链路。
// 关联文件:
//   lib/shared/widgets/screenplay/scene_properties.dart
//   lib/shared/widgets/screenplay/scene_events_editor.dart
//   lib/shared/widgets/screenplay/document_session.dart
//   lib/shared/components/reveric_tags_editor.dart
//   lib/shared/form/form.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/form.md
//   .agents/rules/text-input-ime.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../components/reveric_select.dart';
import '../../components/reveric_tags_editor.dart';
import '../../form/form.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/screenplay.dart';
import '../../models/screenplay_document.dart';
import '../../providers/maps_providers.dart';
import '../../services/screenplay_service.dart';
import '../../services/maps_service.dart';
import '../../theme/theme.dart';
import '../../utils/text_input_composing.dart';
import 'document_session.dart';
import 'scene_events_editor.dart';
import 'time_field.dart';

enum ScenePropertyField<T> implements FieldSchema {
  title<String>(),
  locationId<String?>(),
  timeLabel<String>(),
  interiorExterior<String?>(),
  synopsis<String>(),
  emotion<List<String>>(),
  events<List<Map<String, dynamic>>>(),
  stage<String>(),
  newLocation<String>();

  const ScenePropertyField();
  dynamic get initialValue => null;
  @override
  List<Validator<dynamic>>? get validators => null;
}

class ScenePropertiesForm extends HookConsumerWidget {
  const ScenePropertiesForm({
    super.key,
    required this.databasePath,
    required this.sceneId,
    required this.session,
  });
  final String databasePath;
  final String sceneId;
  final ScreenplayDocumentSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initial = useMemoized(() => session.controller.screenplay!, [
      session,
      sceneId,
    ]);
    final expected = useRef(initial);
    final scene = initial.scenes[sceneId]!;
    final heading = initial.sceneElements(sceneId).first;
    // 只有时间字段还用外部 controller：ScreenplayTimeField 底下是 RevericAutocomplete，
    // 需要自己持有文本。其余文本字段都交给 HookedTextFormField 托管。
    final time = useTextEditingController(text: heading.timeLabel ?? '');
    final saving = useState(false);
    final newLocation = useState(false);
    final createdLocation = useState<String?>(null);
    final error = useState<String?>(null);
    final locations = ref.watch(locationsProvider(databasePath));
    final locationService = ref.watch(locationsServiceProvider(databasePath));
    final form = useForm<ScenePropertyField>(
      initialValues: {
        ScenePropertyField.title: scene.title,
        ScenePropertyField.locationId: heading.locationId,
        ScenePropertyField.timeLabel: heading.timeLabel ?? '',
        ScenePropertyField.interiorExterior: heading.interiorExterior,
        ScenePropertyField.synopsis: scene.synopsis,
        ScenePropertyField.emotion: scene.emotion ?? <String>[],
        ScenePropertyField.events: scene.events ?? <Map<String, dynamic>>[],
        ScenePropertyField.stage: scene.stage,
        ScenePropertyField.newLocation: '',
      },
      keys: [sceneId],
      listen: false,
    );
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    Future<void> save() async {
      if (saving.value || isTextInputComposing(time)) {
        return;
      }
      syncFormFieldsFromControllersBeforeValidate(
        form: form,
        fields: {ScenePropertyField.timeLabel: time},
      );
      if (!form.validate()) {
        return;
      }
      final emotions = form.getValue<List<String>>(ScenePropertyField.emotion)!;
      final events = form.getValue<List<Map<String, dynamic>>>(
        ScenePropertyField.events,
      )!;
      saving.value = true;
      error.value = null;
      try {
        var locationId = form.getValue<String?>(ScenePropertyField.locationId);
        if (newLocation.value) {
          final name =
              form.getValue<String>(ScenePropertyField.newLocation)?.trim() ??
              '';
          if (name.isEmpty) {
            form.setError(
              ScenePropertyField.newLocation,
              context.t(LocaleKeys.screenplayLocationName),
            );
            return;
          }
          locationId =
              createdLocation.value ??
              await locationService.createLocation(name: name);
          if (context.mounted) {
            createdLocation.value = locationId;
          }
        }
        final current = session.controller.screenplay!;
        final expectedScene = expected.value.scenes[sceneId]!;
        final expectedHeading = expected.value.sceneElements(sceneId).first;
        if (!expectedScene.sameAs(current.scenes[sceneId]) ||
            current.sceneElements(sceneId).first.interiorExterior !=
                expectedHeading.interiorExterior ||
            current.sceneElements(sceneId).first.locationId !=
                expectedHeading.locationId ||
            current.sceneElements(sceneId).first.timeLabel !=
                expectedHeading.timeLabel) {
          throw const ScreenplayServiceException(
            'stale_screenplay_edit',
            'Scene properties changed.',
          );
        }
        final interior = form.getValue<String?>(
          ScenePropertyField.interiorExterior,
        );
        final nextHeading = current
            .sceneElements(sceneId)
            .first
            .copyWith(
              locationId: locationId,
              clearLocationId: locationId == null,
              interiorExterior: interior,
              clearInteriorExterior: interior == null,
              timeLabel: time.text.trim(),
            );
        final nextScene = ScreenplayDocumentScene(
          id: sceneId,
          cast: current.scenes[sceneId]!.cast,
          title: form.getValue<String>(ScenePropertyField.title)?.trim() ?? '',
          synopsis:
              form.getValue<String>(ScenePropertyField.synopsis)?.trim() ?? '',
          emotion: emotions.isEmpty && scene.emotion == null ? null : emotions,
          events: events.isEmpty && scene.events == null ? null : events,
          stage: form.getValue<String>(ScenePropertyField.stage)!,
          beatId: current.scenes[sceneId]!.beatId,
        );
        session.controller.editDocument(
          current.copyWith(
            scenes: {...current.scenes, sceneId: nextScene},
            elements: [
              for (final e in current.elements)
                e.id == nextHeading.id ? nextHeading : e,
            ],
          ),
        );
        expected.value = session.controller.screenplay!;
        await session.flush();
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      } on DuplicateLocationNameException {
        if (context.mounted) {
          form.setError(
            ScenePropertyField.newLocation,
            context.t(LocaleKeys.mapEditorLocationNameDuplicate),
          );
        }
      } catch (e) {
        if (context.mounted) {
          error.value = context.t(
            e is ScreenplayServiceException &&
                    e.errorCode == 'stale_screenplay_edit'
                ? LocaleKeys.screenplayStaleEdit
                : LocaleKeys.screenplaySaveFailed,
          );
        }
      } finally {
        if (context.mounted) {
          saving.value = false;
        }
      }
    }

    Widget sectionHeader(String title, {Widget? trailing}) {
      final label = Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
      );
      return SizedBox(
        height: 24,
        // 标题必须走 Expanded：Row 给非 flex 子节点的是无界宽度，长标题（如
        // Scene target duration (seconds)）和「标题 + 快速新建地点按钮」在窄屏
        // 下都会直接溢出，maxLines/ellipsis 根本不生效。
        child: Row(
          children: [
            Expanded(child: label),
            ?trailing,
          ],
        ),
      );
    }

    Widget pair(Widget first, Widget second) => LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 480) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              first,
              const SizedBox(height: RevericSpacing.lg),
              second,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: first),
            const SizedBox(width: RevericSpacing.lg),
            Expanded(child: second),
          ],
        );
      },
    );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: HookedForm<ScenePropertyField>(
        form: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.x2l,
                RevericSpacing.lg,
                RevericSpacing.md,
                RevericSpacing.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.t(LocaleKeys.screenplaySceneProperties),
                      style: typo.heading2,
                    ),
                  ),
                  IconButton(
                    onPressed: saving.value
                        ? null
                        : () => Navigator.of(context).pop(),
                    tooltip: context.t(LocaleKeys.commonClose),
                    icon: const RevericIcon(RevericIcons.close, size: 20),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.x2l,
                  RevericSpacing.sm,
                  RevericSpacing.x2l,
                  0,
                ),
                child: AbsorbPointer(
                  absorbing: saving.value,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      sectionHeader(
                        context.t(LocaleKeys.screenplaySceneShortTitle),
                      ),
                      const SizedBox(height: RevericSpacing.xs),
                      // 标题可以留空，留空时正文按地点显示（scene_short_title_hint），
                      // 所以这里不挂必填校验。
                      HookedTextFormField<ScenePropertyField>(
                        fieldHook: ScenePropertyField.title,
                        fieldKey: const ValueKey('scene_title_field'),
                        hintText: context.t(
                          LocaleKeys.screenplaySceneShortTitleHint,
                        ),
                      ),
                      const SizedBox(height: RevericSpacing.lg),
                      pair(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            sectionHeader(
                              context.t(
                                newLocation.value
                                    ? LocaleKeys.screenplayLocationName
                                    : LocaleKeys.screenplayLocations,
                              ),
                              trailing: TextButton.icon(
                                onPressed: () {
                                  newLocation.value = !newLocation.value;
                                  createdLocation.value = null;
                                  if (!newLocation.value) {
                                    form.updateValue(
                                      ScenePropertyField.newLocation,
                                      '',
                                      notify: false,
                                    );
                                    // 本表单只在 newLocation 上 setError，收起输入框时
                                    // 一并清掉，免得下次展开还挂着上次的报错。
                                    form.clearForcedErrors(notify: false);
                                  }
                                },
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: RevericSpacing.xs,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                icon: RevericIcon(
                                  newLocation.value
                                      ? RevericIcons.close
                                      : RevericIcons.add,
                                  size: 14,
                                ),
                                label: Text(
                                  context.t(
                                    newLocation.value
                                        ? LocaleKeys.commonCancel
                                        : LocaleKeys
                                              .screenplayQuickCreateLocation,
                                  ),
                                  style: typo.uiSmall,
                                ),
                              ),
                            ),
                            const SizedBox(height: RevericSpacing.xs),
                            if (newLocation.value)
                              HookedTextFormField<ScenePropertyField>(
                                fieldHook: ScenePropertyField.newLocation,
                                fieldKey: const ValueKey(
                                  'scene_new_location_field',
                                ),
                                autovalidateMode:
                                    AutovalidateMode.onUserInteraction,
                                validator: (value) =>
                                    value == null || value.trim().isEmpty
                                    ? context.t(LocaleKeys.formRequired)
                                    : null,
                                hintText: context.t(
                                  LocaleKeys.screenplayLocationName,
                                ),
                              )
                            else
                              HookedFormField<ScenePropertyField, String?>(
                                fieldHook: ScenePropertyField.locationId,
                                builder: (value, onChanged, _) =>
                                    RevericSelect<String>(
                                      value: value ?? '',
                                      items: [
                                        RevericSelectItem(
                                          value: '',
                                          label: context.t(
                                            LocaleKeys.screenplayUnspecified,
                                          ),
                                        ),
                                        for (final location
                                            in locations.value ?? [])
                                          RevericSelectItem(
                                            value: location.id,
                                            label: location.name,
                                          ),
                                      ],
                                      onChanged: (val) => onChanged?.call(
                                        val.isEmpty ? null : val,
                                      ),
                                    ),
                              ),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            sectionHeader(context.t(LocaleKeys.screenplayTime)),
                            const SizedBox(height: RevericSpacing.xs),
                            ScreenplayTimeField(controller: time),
                          ],
                        ),
                      ),
                      const SizedBox(height: RevericSpacing.lg),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          sectionHeader(
                            context.t(LocaleKeys.screenplayInteriorExterior),
                          ),
                          const SizedBox(height: RevericSpacing.xs),
                          HookedFormField<ScenePropertyField, String?>(
                            fieldHook: ScenePropertyField.interiorExterior,
                            builder: (value, onChanged, _) => Wrap(
                              spacing: RevericSpacing.xs,
                              runSpacing: RevericSpacing.xs,
                              children: [
                                for (final option in <String?, String>{
                                  screenplayInterior:
                                      LocaleKeys.screenplayInterior,
                                  screenplayExterior:
                                      LocaleKeys.screenplayExterior,
                                  screenplayInteriorExterior:
                                      LocaleKeys.screenplayInteriorAndExterior,
                                  null: LocaleKeys.screenplayUnspecified,
                                }.entries)
                                  ChoiceChip(
                                    label: Text(context.t(option.value)),
                                    selected: value == option.key,
                                    showCheckmark: false,
                                    onSelected: (_) =>
                                        onChanged?.call(option.key),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: RevericSpacing.lg),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          sectionHeader(context.t(LocaleKeys.screenplayStage)),
                          const SizedBox(height: RevericSpacing.xs),
                          HookedFormField<ScenePropertyField, String?>(
                            fieldHook: ScenePropertyField.stage,
                            builder: (value, onChanged, _) =>
                                RevericSelect<String>(
                                  value: value ?? screenplayStageDraft,
                                  items: [
                                    RevericSelectItem(
                                      value: screenplayStageDraft,
                                      label: context.t(
                                        LocaleKeys.screenplayDraft,
                                      ),
                                    ),
                                    RevericSelectItem(
                                      value: screenplayStageFinal,
                                      label: context.t(
                                        LocaleKeys.screenplayFinal,
                                      ),
                                    ),
                                  ],
                                  onChanged: (val) => onChanged?.call(val),
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: RevericSpacing.lg),
                      sectionHeader(context.t(LocaleKeys.screenplaySynopsis)),
                      const SizedBox(height: RevericSpacing.xs),
                      HookedTextFormField<ScenePropertyField>(
                        fieldHook: ScenePropertyField.synopsis,
                        multiline: true,
                        minLines: 3,
                        maxLines: 6,
                        hintText: context.t(LocaleKeys.screenplaySynopsis),
                      ),
                      const SizedBox(height: RevericSpacing.lg),
                      sectionHeader(
                        context.t(LocaleKeys.screenplaySceneEmotion),
                      ),
                      const SizedBox(height: RevericSpacing.xs),
                      HookedFormField<ScenePropertyField, List<String>>(
                        fieldHook: ScenePropertyField.emotion,
                        builder: (value, onChanged, _) => RevericTagsEditor(
                          tags: value ?? [],
                          onChanged: (value) => onChanged?.call(value),
                          maxLength: 32,
                          addLabel: context.t(
                            LocaleKeys.screenplaySceneEmotionAdd,
                          ),
                          hintText: context.t(
                            LocaleKeys.screenplaySceneEmotion,
                          ),
                        ),
                      ),
                      const SizedBox(height: RevericSpacing.lg),
                      sectionHeader(
                        context.t(LocaleKeys.screenplaySceneEvents),
                      ),
                      Text(
                        context.t(LocaleKeys.screenplaySceneEventsHint),
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                      ),
                      const SizedBox(height: RevericSpacing.xs),
                      HookedFormField<
                        ScenePropertyField,
                        List<Map<String, dynamic>>
                      >(
                        fieldHook: ScenePropertyField.events,
                        validator: (value) {
                          try {
                            ScreenplayService.validateSceneAnalysis(
                              events: value,
                            );
                          } on ScreenplayServiceException {
                            return context.t(
                              LocaleKeys.screenplaySceneEventRequired,
                            );
                          }
                          return null;
                        },
                        builder: (value, onChanged, fieldError) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SceneEventsEditor(
                              events: value ?? [],
                              onChanged: (value) => onChanged?.call(value),
                            ),
                            if (fieldError != null) ...[
                              const SizedBox(height: RevericSpacing.xs),
                              Text(
                                fieldError,
                                style: typo.uiSmall.copyWith(
                                  color: colors.error,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: RevericSpacing.lg),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(RevericSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: error.value == null
                        ? const SizedBox.shrink()
                        : Text(
                            error.value!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: typo.uiSmall.copyWith(color: colors.error),
                          ),
                  ),
                  TextButton(
                    onPressed: saving.value
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(context.t(LocaleKeys.commonCancel)),
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  FilledButton(
                    onPressed: saving.value || !locations.hasValue
                        ? null
                        : save,
                    child: Text(context.t(LocaleKeys.commonSave)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

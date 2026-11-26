// 职责: NovelAgentSkill 独立编辑面板 — 编辑应用全局本地技能快照并提交保存。
// 关联文件:
//   lib/desktop/features/agent_skills/setup_panel.dart
//   lib/desktop/features/agent_skills/agent_skill_reference_file_tree.dart
//   lib/shared/models/novel_agent_skill.dart
//   lib/shared/components/reveric_text_field.dart
//   lib/shared/components/reveric_select.dart
//   lib/shared/components/reveric_tags_editor.dart
//   lib/shared/components/reveric_switch.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/form.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_select.dart';
import '../../../shared/components/reveric_switch.dart';
import '../../../shared/components/reveric_tags_editor.dart';
import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/agent_skill_reference.dart';
import '../../../shared/providers/dictionary_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/utils/text_input_composing.dart';
import '../../../shared/widgets/md/reveric_markdown_editor.dart';
import '../../../third/form/flutter_hook_form.dart';
import '../../widgets/desktop_window_frame.dart';
import 'agent_skill_reference_file_tree.dart';
import 'setup_panel.dart' show kLocalSkillCategories;

enum AgentSkillSetupEditField implements FieldSchema {
  name(validators: [RequiredValidator<String>()], initialValue: ''),
  whenToUse(initialValue: ''),
  description(initialValue: ''),
  prompt(validators: [RequiredValidator<String>()], initialValue: ''),
  category(initialValue: '');

  const AgentSkillSetupEditField({this.validators, this.initialValue});

  final dynamic initialValue;

  @override
  final List<Validator<dynamic>>? validators;
}

class AgentSkillSetupEditDraft {
  const AgentSkillSetupEditDraft({
    required this.name,
    required this.whenToUse,
    required this.description,
    required this.prompt,
    required this.category,
    this.tags = const [],
    this.references = const [],
    required this.enabled,
  });

  const AgentSkillSetupEditDraft.novel()
    : name = '',
      whenToUse = '',
      description = '',
      prompt = '',
      category = '',
      tags = const [],
      references = const [],
      enabled = true;

  final String name;
  final String whenToUse;
  final String description;
  final String prompt;
  final String category;
  final List<String> tags;
  final List<AgentSkillReferenceFile> references;
  final bool enabled;

  AgentSkillSetupEditDraft copyWith({
    String? name,
    String? whenToUse,
    String? description,
    String? prompt,
    String? category,
    List<String>? tags,
    List<AgentSkillReferenceFile>? references,
    bool? enabled,
  }) {
    return AgentSkillSetupEditDraft(
      name: name ?? this.name,
      whenToUse: whenToUse ?? this.whenToUse,
      description: description ?? this.description,
      prompt: prompt ?? this.prompt,
      category: category ?? this.category,
      tags: tags ?? this.tags,
      references: references ?? this.references,
      enabled: enabled ?? this.enabled,
    );
  }
}

bool _sameDraft(AgentSkillSetupEditDraft left, AgentSkillSetupEditDraft right) {
  return left.name == right.name &&
      left.whenToUse == right.whenToUse &&
      left.description == right.description &&
      left.prompt == right.prompt &&
      left.category == right.category &&
      listEquals(left.tags, right.tags) &&
      listEquals(left.references, right.references) &&
      left.enabled == right.enabled;
}

class AgentSkillSetupEditPanel extends HookConsumerWidget {
  const AgentSkillSetupEditPanel({
    super.key,
    required this.draft,
    required this.createTitleKey,
    required this.onBack,
    this.onSave,
    this.onConfirmSave,
    this.readOnly = false,
    this.subtitleKey = LocaleKeys.commonEdit,
    this.headerLeadingInset = 0,
    this.headerTrailingInset = 0,
    this.headerGestureExclusionKey,
    this.onSaved,
    this.onHasChangesChanged,
    this.onRegisterSave,
    this.onRegisterHasChanges,
    this.onRegisterIsBlankCreateDraft,
  }) : assert(readOnly || onSave != null, 'onSave is required when editing');

  final AgentSkillSetupEditDraft draft;
  final String createTitleKey;

  /// 打开版本历史。为空时不显示入口（新建草稿尚无历史）。

  /// intro 副标题 locale key;只读详情可传官方/市场来源文案。
  final String subtitleKey;
  final bool readOnly;
  final Future<AgentSkillSetupEditDraft> Function(
    AgentSkillSetupEditDraft draft,
  )?
  onSave;
  final VoidCallback onBack;

  /// 保存前确认;返回 false 则中止保存。
  final Future<bool> Function(
    BuildContext context,
    AgentSkillSetupEditDraft draft,
  )?
  onConfirmSave;
  final double headerLeadingInset;
  final double headerTrailingInset;
  final GlobalKey? headerGestureExclusionKey;
  final ValueChanged<AgentSkillSetupEditDraft>? onSaved;
  final ValueChanged<bool>? onHasChangesChanged;
  final ValueChanged<Future<bool> Function()?>? onRegisterSave;
  final ValueChanged<bool Function()?>? onRegisterHasChanges;
  final ValueChanged<bool Function()?>? onRegisterIsBlankCreateDraft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final editorHeight = MediaQuery.sizeOf(context).height * 0.6;
    final baseline = useState(draft);
    final effectiveDraft = baseline.value;
    final tagSuggestions = ref.watch(skillTagsProvider).value;
    final remoteCategories = ref.watch(skillCategoriesProvider).value;
    final form = useForm<AgentSkillSetupEditField>(
      initialValues: {
        AgentSkillSetupEditField.name: effectiveDraft.name,
        AgentSkillSetupEditField.whenToUse: effectiveDraft.whenToUse,
        AgentSkillSetupEditField.description: effectiveDraft.description,
        AgentSkillSetupEditField.prompt: effectiveDraft.prompt,
        AgentSkillSetupEditField.category: effectiveDraft.category,
      },
      keys: [effectiveDraft],
      listen: false,
    );
    final nameController = useTextEditingController(text: effectiveDraft.name);
    final whenToUseController = useTextEditingController(
      text: effectiveDraft.whenToUse,
    );
    final descriptionController = useTextEditingController(
      text: effectiveDraft.description,
    );
    final promptController = useTextEditingController(
      text: effectiveDraft.prompt,
    );
    final promptFocusNode = useFocusNode();
    final tags = useState<List<String>>(List<String>.from(effectiveDraft.tags));
    final references = useState<List<AgentSkillReferenceFile>>(
      List<AgentSkillReferenceFile>.from(effectiveDraft.references),
    );
    final enabled = useState(effectiveDraft.enabled);
    // 左列选中项：-1 = SKILL.md 主体；>=0 = references 下标。
    final selection = useState<int>(-1);
    // 每个 reference 的字段级 inline error（切换文件/保存时置位，编辑后清除）。
    final refErrors = useState<Map<int, ({String? name, String? content})>>(
      const {},
    );
    final hasEdits = useState(false);
    final isSaving = useState(false);
    final syncingControllers = useRef(false);
    final lastIncomingDraft = useRef(draft);

    bool computeHasEdits() {
      return nameController.text != effectiveDraft.name ||
          whenToUseController.text != effectiveDraft.whenToUse ||
          descriptionController.text != effectiveDraft.description ||
          promptController.text != effectiveDraft.prompt ||
          (form.getValue<String>(AgentSkillSetupEditField.category) ?? '') !=
              effectiveDraft.category ||
          !listEquals(tags.value, effectiveDraft.tags) ||
          !listEquals(references.value, effectiveDraft.references) ||
          enabled.value != effectiveDraft.enabled;
    }

    bool isBlankCreateDraft() {
      return effectiveDraft.name.trim().isEmpty &&
          whenToUseController.text.trim().isEmpty &&
          descriptionController.text.trim().isEmpty &&
          promptController.text.trim().isEmpty &&
          (form.getValue<String>(AgentSkillSetupEditField.category) ?? '')
              .trim()
              .isEmpty &&
          tags.value.isEmpty &&
          references.value.isEmpty;
    }

    void notifyDirtyIfNeeded({TextEditingController? composingController}) {
      notifyDirtyAfterExternalControllerEdit(
        focusToPreserve: promptFocusNode,
        suppress: syncingControllers.value,
        composingController: composingController,
        computeHasEdits: computeHasEdits,
        readHasEdits: () => hasEdits.value,
        writeHasEdits: (next) => hasEdits.value = next,
        onHasChangesChanged: onHasChangesChanged,
      );
    }

    final saveRef = useRef<Future<bool> Function()?>(null);
    final hasChangesRef = useRef<bool Function()?>(null);
    final isBlankCreateDraftRef = useRef<bool Function()?>(null);
    final onRegisterSaveRef = useRef(onRegisterSave);
    final onRegisterHasChangesRef = useRef(onRegisterHasChanges);
    final onRegisterIsBlankCreateDraftRef = useRef(
      onRegisterIsBlankCreateDraft,
    );
    onRegisterSaveRef.value = onRegisterSave;
    onRegisterHasChangesRef.value = onRegisterHasChanges;
    onRegisterIsBlankCreateDraftRef.value = onRegisterIsBlankCreateDraft;
    useEffect(() {
      onRegisterSaveRef.value?.call(
        () async => await saveRef.value?.call() ?? false,
      );
      onRegisterHasChangesRef.value?.call(
        () => hasChangesRef.value?.call() ?? false,
      );
      onRegisterIsBlankCreateDraftRef.value?.call(
        () => isBlankCreateDraftRef.value?.call() ?? false,
      );
      return () {
        onRegisterSaveRef.value?.call(null);
        onRegisterHasChangesRef.value?.call(null);
        onRegisterIsBlankCreateDraftRef.value?.call(null);
      };
    }, const []);

    useEffect(() {
      if (!_sameDraft(draft, lastIncomingDraft.value)) {
        lastIncomingDraft.value = draft;
        baseline.value = draft;
      }
      return null;
    }, [draft]);

    useEffect(() {
      syncingControllers.value = true;
      nameController.text = effectiveDraft.name;
      whenToUseController.text = effectiveDraft.whenToUse;
      descriptionController.text = effectiveDraft.description;
      promptController.text = effectiveDraft.prompt;
      tags.value = List<String>.from(effectiveDraft.tags);
      references.value = List<AgentSkillReferenceFile>.from(
        effectiveDraft.references,
      );
      enabled.value = effectiveDraft.enabled;
      syncingControllers.value = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        hasEdits.value = false;
        onHasChangesChanged?.call(false);
      });
      return null;
    }, [effectiveDraft]);

    useEffect(
      () {
        void onChanged(TextEditingController controller) {
          notifyDirtyIfNeeded(composingController: controller);
        }

        void onNameChanged() => onChanged(nameController);
        void onWhenToUseChanged() => onChanged(whenToUseController);
        void onDescriptionChanged() => onChanged(descriptionController);
        void onPromptChanged() => onChanged(promptController);

        nameController.addListener(onNameChanged);
        whenToUseController.addListener(onWhenToUseChanged);
        descriptionController.addListener(onDescriptionChanged);
        promptController.addListener(onPromptChanged);
        return () {
          nameController.removeListener(onNameChanged);
          whenToUseController.removeListener(onWhenToUseChanged);
          descriptionController.removeListener(onDescriptionChanged);
          promptController.removeListener(onPromptChanged);
        };
      },
      [
        nameController,
        whenToUseController,
        descriptionController,
        promptController,
        promptFocusNode,
      ],
    );

    // 单个 reference 的字段级校验（文件名须合法扩展名、内容非空）。
    ({String? name, String? content}) validateReference(
      AgentSkillReferenceFile f,
    ) {
      final nameOk = AgentSkillReferences.isValidRelativePath(f.path);
      final contentOk = f.content.trim().isNotEmpty;
      return (
        name: nameOk
            ? null
            : context.t(LocaleKeys.agentSkillReferencesFileNameInvalid),
        content: contentOk
            ? null
            : context.t(LocaleKeys.agentSkillReferencesContentRequired),
      );
    }

    Future<bool> save() async {
      if (readOnly) {
        return false;
      }
      final persist = onSave;
      if (persist == null) {
        return false;
      }
      syncFormFieldsFromControllersBeforeValidate(
        form: form,
        fields: {
          AgentSkillSetupEditField.name: nameController,
          AgentSkillSetupEditField.whenToUse: whenToUseController,
          AgentSkillSetupEditField.description: descriptionController,
          AgentSkillSetupEditField.prompt: promptController,
        },
      );
      if (!form.validate()) {
        return false;
      }
      // 保存时校验全部 reference（fail loud）：任一文件名非法或内容为空则中止，
      // 跳到首个非法文件并 inline 提示，避免 sanitize 静默丢弃用户内容。
      final errorMap = <int, ({String? name, String? content})>{};
      var firstInvalid = -1;
      for (var i = 0; i < references.value.length; i++) {
        final res = validateReference(references.value[i]);
        if (res.name != null || res.content != null) {
          errorMap[i] = res;
          if (firstInvalid == -1) {
            firstInvalid = i;
          }
        }
      }
      if (firstInvalid != -1) {
        refErrors.value = errorMap;
        selection.value = firstInvalid;
        return false;
      }

      final next = AgentSkillSetupEditDraft(
        name: nameController.text.trim(),
        whenToUse: whenToUseController.text.trim(),
        description: descriptionController.text.trim(),
        prompt: promptController.text.trim(),
        category: form
            .getValue<String>(AgentSkillSetupEditField.category)!
            .trim(),
        tags: List<String>.from(tags.value),
        references: AgentSkillReferences.sanitize(references.value),
        enabled: enabled.value,
      );
      final confirmSave = onConfirmSave;
      if (confirmSave != null) {
        final confirmed = await confirmSave(context, next);
        if (!confirmed || !context.mounted) {
          return false;
        }
      }
      isSaving.value = true;
      try {
        final saved = await persist(next);
        baseline.value = saved;
        hasEdits.value = false;
        onHasChangesChanged?.call(false);
        onSaved?.call(saved);
        return true;
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
        return false;
      } finally {
        isSaving.value = false;
      }
    }

    final categoryChoices = <String>{
      ...(remoteCategories ?? kLocalSkillCategories),
      if (effectiveDraft.category.isNotEmpty) effectiveDraft.category,
    }.toList();

    saveRef.value = save;
    hasChangesRef.value = computeHasEdits;
    isBlankCreateDraftRef.value = isBlankCreateDraft;

    final title = effectiveDraft.name.isEmpty
        ? context.t(createTitleKey)
        : effectiveDraft.name;
    final currentHasEdits = computeHasEdits();
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onHasChangesChanged?.call(currentHasEdits);
      });
      return null;
    }, [currentHasEdits, effectiveDraft]);

    final refs = references.value;
    // 选中项越界（删除后）时回落到主体。
    final selectedIndex = selection.value >= 0 && selection.value < refs.length
        ? selection.value
        : -1;

    // 切换文件前校验「正在打开的文件」，把结果写入 refErrors（合法则清除）。
    void commitOpenFileErrors() {
      if (selectedIndex == -1) {
        return;
      }
      final res = validateReference(refs[selectedIndex]);
      final map = Map<int, ({String? name, String? content})>.from(
        refErrors.value,
      );
      if (res.name == null && res.content == null) {
        map.remove(selectedIndex);
      } else {
        map[selectedIndex] = res;
      }
      refErrors.value = map;
    }

    void addReference(String directoryPath) {
      commitOpenFileErrors();
      final next = <AgentSkillReferenceFile>[
        ...refs,
        AgentSkillReferenceFile(
          path: _nextReferenceFileName(refs, directoryPath: directoryPath),
          content: '',
        ),
      ];
      references.value = next;
      selection.value = next.length - 1;
      notifyDirtyIfNeeded();
    }

    void deleteReference(int index) {
      final next = List<AgentSkillReferenceFile>.from(refs)..removeAt(index);
      references.value = next;
      // 下标位移会让 refErrors 错位，删除后整体清空（下次切换/保存重新计算）。
      refErrors.value = const {};
      if (selection.value == index) {
        selection.value = -1;
      } else if (selection.value > index) {
        selection.value = selection.value - 1;
      }
      notifyDirtyIfNeeded();
    }

    void updateReference(int index, AgentSkillReferenceFile updated) {
      final next = List<AgentSkillReferenceFile>.from(refs);
      next[index] = updated;
      references.value = next;
      // 用户开始编辑后清除该文件残留的 inline error。
      if (refErrors.value.containsKey(index)) {
        final map = Map<int, ({String? name, String? content})>.from(
          refErrors.value,
        )..remove(index);
        refErrors.value = map;
      }
      notifyDirtyIfNeeded();
    }

    // 左列切换：先校验离开的文件，再切换。
    void selectMain() {
      commitOpenFileErrors();
      selection.value = -1;
    }

    void selectReference(int index) {
      if (index != selectedIndex) {
        commitOpenFileErrors();
      }
      selection.value = index;
    }

    return Container(
      color: colors.canvas,
      child: Column(
        children: [
          _EditorHeader(
            title: title,
            enabled: enabled.value,
            showEnabled: !readOnly,
            showSave: !readOnly,
            hasChanges: currentHasEdits,
            isSaving: isSaving.value,
            onBack: onBack,
            onToggleEnabled: (value) {
              enabled.value = value;
              notifyDirtyIfNeeded();
            },
            onSave: () async {
              await save();
            },
            leadingInset: headerLeadingInset,
            trailingInset: headerTrailingInset,
            gestureExclusionKey: headerGestureExclusionKey,
          ),
          Divider(height: RevericSizes.dividerThickness, color: colors.border),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SkillFileList(
                  references: refs,
                  selectedIndex: selectedIndex,
                  invalidIndices: refErrors.value.keys.toSet(),
                  readOnly: readOnly,
                  onSelectMain: selectMain,
                  onSelectReference: selectReference,
                  onAddReference: addReference,
                  onDeleteReference: deleteReference,
                ),
                VerticalDivider(
                  width: RevericSizes.dividerThickness,
                  thickness: RevericSizes.dividerThickness,
                  color: colors.border,
                ),
                Expanded(
                  child: IndexedStack(
                    index: selectedIndex == -1 ? 0 : 1,
                    sizing: StackFit.expand,
                    children: [
                      // 0 = SKILL.md 主体：元数据表单 + 指令编辑器。始终挂载，
                      // 保证 HookedFormField 注册不因切到 reference 而丢失。
                      SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                          RevericSpacing.x6l,
                          RevericSpacing.x4l,
                          RevericSpacing.x6l,
                          RevericSpacing.x6l,
                        ),
                        child: HookedForm(
                          form: form,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 840),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _EditorIntro(
                                  title: title,
                                  subtitleKey: subtitleKey,
                                ),
                                const SizedBox(height: RevericSpacing.x3l),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _FieldLabel(
                                            label: context.t(
                                              LocaleKeys.agentSkillName,
                                            ),
                                          ),
                                          const SizedBox(
                                            height: RevericSpacing.sm,
                                          ),
                                          _TextField<AgentSkillSetupEditField>(
                                            field:
                                                AgentSkillSetupEditField.name,
                                            controller: nameController,
                                            readOnly: readOnly,
                                            requiredMessage: readOnly
                                                ? null
                                                : context.t(
                                                    LocaleKeys
                                                        .agentSkillNameRequired,
                                                  ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: RevericSpacing.x2l),
                                    Expanded(
                                      flex: 2,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _FieldLabel(
                                            label: context.t(
                                              LocaleKeys.agentSkillCategory,
                                            ),
                                          ),
                                          const SizedBox(
                                            height: RevericSpacing.sm,
                                          ),
                                          HookedFormField<
                                            AgentSkillSetupEditField,
                                            String
                                          >(
                                            fieldHook: AgentSkillSetupEditField
                                                .category,
                                            autovalidateMode: AutovalidateMode
                                                .onUserInteraction,
                                            validator: readOnly
                                                ? null
                                                : (value) =>
                                                      value == null ||
                                                          value.trim().isEmpty
                                                      ? context.t(
                                                          LocaleKeys
                                                              .agentSkillCategoryRequired,
                                                        )
                                                      : null,
                                            builder:
                                                (
                                                  value,
                                                  onChanged,
                                                  error,
                                                ) => Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    RevericSelect<String>(
                                                      value:
                                                          value == null ||
                                                              value.isEmpty
                                                          ? null
                                                          : value,
                                                      placeholder: context.t(
                                                        LocaleKeys
                                                            .agentSkillCategoryPlaceholder,
                                                      ),
                                                      enabled: !readOnly,
                                                      items: [
                                                        for (final category
                                                            in categoryChoices)
                                                          RevericSelectItem<
                                                            String
                                                          >(
                                                            value: category,
                                                            label: category,
                                                          ),
                                                      ],
                                                      onChanged: (selected) {
                                                        onChanged?.call(
                                                          selected,
                                                        );
                                                        notifyDirtyIfNeeded();
                                                      },
                                                    ),
                                                    if (error != null) ...[
                                                      const SizedBox(
                                                        height:
                                                            RevericSpacing.xs,
                                                      ),
                                                      Text(
                                                        error,
                                                        style: typo.uiSmall
                                                            .copyWith(
                                                              color: colors
                                                                  .warningText,
                                                            ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: RevericSpacing.x2l),
                                _FieldLabel(
                                  label: context.t(
                                    LocaleKeys.agentSkillWhenToUse,
                                  ),
                                  helpText: context.t(
                                    LocaleKeys.agentSkillWhenToUseHelp,
                                  ),
                                ),
                                const SizedBox(height: RevericSpacing.sm),
                                _TextField<AgentSkillSetupEditField>(
                                  field: AgentSkillSetupEditField.whenToUse,
                                  controller: whenToUseController,
                                  readOnly: readOnly,
                                  maxLines: 2,
                                  hintText: context.t(
                                    LocaleKeys.agentSkillWhenToUseHint,
                                  ),
                                ),
                                const SizedBox(height: RevericSpacing.x2l),
                                _FieldLabel(
                                  label: context.t(
                                    LocaleKeys.agentSkillDescription,
                                  ),
                                ),
                                const SizedBox(height: RevericSpacing.sm),
                                _TextField<AgentSkillSetupEditField>(
                                  field: AgentSkillSetupEditField.description,
                                  controller: descriptionController,
                                  readOnly: readOnly,
                                  maxLines: 3,
                                ),
                                const SizedBox(height: RevericSpacing.x2l),
                                _FieldLabel(
                                  label: context.t(LocaleKeys.commonTags),
                                ),
                                const SizedBox(height: RevericSpacing.sm),
                                if (readOnly)
                                  _ReadonlyTags(tags: tags.value)
                                else
                                  RevericTagsEditor(
                                    tags: tags.value,
                                    onChanged: (updated) {
                                      tags.value = updated;
                                      notifyDirtyIfNeeded();
                                    },
                                    addLabel: context.t(
                                      LocaleKeys.libraryAddTag,
                                    ),
                                    hintText: context.t(
                                      LocaleKeys.libraryTagHint,
                                    ),
                                    suggestions: tagSuggestions,
                                  ),
                                const SizedBox(height: RevericSpacing.x2l),
                                _FieldLabel(
                                  label: context.t(LocaleKeys.agentSkillPrompt),
                                ),
                                const SizedBox(height: RevericSpacing.sm),
                                HookedFormField<
                                  AgentSkillSetupEditField,
                                  String
                                >(
                                  fieldHook: AgentSkillSetupEditField.prompt,
                                  autovalidateMode:
                                      AutovalidateMode.onUserInteraction,
                                  validator: readOnly
                                      ? null
                                      : (value) =>
                                            value == null ||
                                                value.trim().isEmpty
                                            ? context.t(
                                                LocaleKeys
                                                    .agentSkillPromptRequired,
                                              )
                                            : null,
                                  builder: (_, _, error) => Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        height: editorHeight,
                                        child: RevericMarkdownEditor(
                                          controller: promptController,
                                          focusNode: promptFocusNode,
                                          hintText: context.t(
                                            LocaleKeys.agentSkillPromptHint,
                                          ),
                                          limitPasteSize: false,
                                          disabled: readOnly,
                                        ),
                                      ),
                                      if (error != null) ...[
                                        const SizedBox(
                                          height: RevericSpacing.xs,
                                        ),
                                        Text(
                                          error,
                                          style: typo.uiSmall.copyWith(
                                            color: colors.warningText,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 1 = reference 编辑：单个文件编辑器，切换文件时按 path 重建。
                      selectedIndex == -1
                          ? const SizedBox.shrink()
                          : SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(
                                RevericSpacing.x6l,
                                RevericSpacing.x4l,
                                RevericSpacing.x6l,
                                RevericSpacing.x6l,
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 840,
                                ),
                                child: _ReferenceFileEditor(
                                  // 按下标 key，切换文件时重建；编辑文件名会改
                                  // path，若用 path 作 key 会每敲一个字就重建导致失焦。
                                  key: ValueKey('ref-$selectedIndex'),
                                  file: refs[selectedIndex],
                                  readOnly: readOnly,
                                  nameError:
                                      refErrors.value[selectedIndex]?.name,
                                  contentError:
                                      refErrors.value[selectedIndex]?.content,
                                  onChanged: (updated) =>
                                      updateReference(selectedIndex, updated),
                                ),
                              ),
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.title,
    required this.enabled,
    required this.showEnabled,
    required this.showSave,
    required this.hasChanges,
    required this.isSaving,
    required this.onBack,
    required this.onToggleEnabled,
    required this.onSave,
    required this.leadingInset,
    required this.trailingInset,
    required this.gestureExclusionKey,
  });

  final String title;
  final bool enabled;
  final bool showEnabled;
  final bool showSave;
  final bool hasChanges;
  final bool isSaving;
  final VoidCallback onBack;
  final ValueChanged<bool> onToggleEnabled;
  final VoidCallback onSave;
  final double leadingInset;
  final double trailingInset;
  final GlobalKey? gestureExclusionKey;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      height: DesktopWindowFrame.titleBarHeight,
      padding: EdgeInsets.only(
        left: leadingInset,
        right: RevericSpacing.lg + trailingInset,
      ),
      color: colors.surfaceContainer,
      child: KeyedSubtree(
        key: gestureExclusionKey,
        child: Row(
          children: [
            IconButton(
              onPressed: onBack,
              icon: const RevericIcon(RevericIcons.arrow_back, size: 16),
            ),
            const SizedBox(width: RevericSpacing.xs),
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
            ),
            if (showEnabled) ...[
              Text(
                context.t(LocaleKeys.agentSkillEnabled),
                style: typo.uiSmall.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(width: RevericSpacing.xs),
              RevericSwitch(value: enabled, onChanged: onToggleEnabled),
              const SizedBox(width: RevericSpacing.md),
            ],
            if (showSave)
              FilledButton(
                onPressed: isSaving || !hasChanges ? null : onSave,
                child: Text(
                  isSaving
                      ? context.t(LocaleKeys.commonSaving)
                      : context.t(LocaleKeys.commonSave),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EditorIntro extends StatelessWidget {
  const _EditorIntro({required this.title, required this.subtitleKey});

  final String title;
  final String subtitleKey;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      children: [
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.surfaceDim,
            border: Border.all(color: colors.borderInput, width: 2),
            borderRadius: BorderRadius.circular(RevericRadius.large),
          ),
          child: RevericIcon(
            RevericIcons.layers_outlined,
            size: 28,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(width: RevericSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: typo.display.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: RevericSpacing.xs),
              Text(
                context.t(subtitleKey),
                style: typo.bodySmall.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReadonlyTags extends StatelessWidget {
  const _ReadonlyTags({required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) {
      return const SizedBox.shrink();
    }
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Wrap(
      spacing: RevericSpacing.sm,
      runSpacing: RevericSpacing.sm,
      children: [
        for (final tag in tags)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.sm,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceDim,
              borderRadius: BorderRadius.circular(RevericRadius.small),
              border: Border.all(color: colors.borderInput),
            ),
            child: Text(
              tag,
              style: typo.uiTiny.copyWith(color: colors.textSecondary),
            ),
          ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label, this.helpText});

  final String label;
  final String? helpText;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final help = helpText?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: typo.uiSemibold.copyWith(color: colors.textSecondary),
        ),
        if (help != null && help.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.xxs),
          Text(help, style: typo.uiTiny.copyWith(color: colors.textMuted)),
        ],
      ],
    );
  }
}

class _TextField<T extends FieldSchema> extends StatelessWidget {
  const _TextField({
    required this.field,
    required this.controller,
    this.requiredMessage,
    this.readOnly = false,
    this.maxLines = 1,
    this.hintText,
  });

  final T field;
  final TextEditingController controller;
  final String? requiredMessage;
  final bool readOnly;
  final int maxLines;
  final String? hintText;

  @override
  Widget build(BuildContext context) {
    return HookedFormField<T, String>(
      fieldHook: field,
      autovalidateMode: requiredMessage == null
          ? null
          : AutovalidateMode.onUserInteraction,
      validator: requiredMessage == null
          ? null
          : (value) =>
                value == null || value.trim().isEmpty ? requiredMessage : null,
      builder: (_, _, error) => RevericTextField(
        controller: controller,
        errorText: error,
        readOnly: readOnly,
        hintText: hintText,
        multiline: maxLines > 1,
        minLines: maxLines,
        maxLines: maxLines,
      ),
    );
  }
}

/// 在指定 references 目录生成不冲突的下一个文件名。
String _nextReferenceFileName(
  List<AgentSkillReferenceFile> current, {
  required String directoryPath,
}) {
  final normalizedDirectory = directoryPath.endsWith('/')
      ? directoryPath
      : '$directoryPath/';
  var index = current.length + 1;
  while (true) {
    final candidate = '${normalizedDirectory}ref-$index.md';
    if (current.every((file) => file.path != candidate)) {
      return candidate;
    }
    index += 1;
  }
}

/// 左列文件树：SKILL.md 主体 + 可折叠 references 目录树 + 新增文件入口。
class _SkillFileList extends StatelessWidget {
  const _SkillFileList({
    required this.references,
    required this.selectedIndex,
    required this.invalidIndices,
    required this.readOnly,
    required this.onSelectMain,
    required this.onSelectReference,
    required this.onAddReference,
    required this.onDeleteReference,
  });

  final List<AgentSkillReferenceFile> references;

  /// -1 = 主体；>=0 = references 下标。
  final int selectedIndex;

  /// 校验不通过的 reference 下标，行尾显示警告标记。
  final Set<int> invalidIndices;
  final bool readOnly;
  final VoidCallback onSelectMain;
  final ValueChanged<int> onSelectReference;
  final ValueChanged<String> onAddReference;
  final ValueChanged<int> onDeleteReference;

  @override
  Widget build(BuildContext context) {
    return AgentSkillReferenceFileTree(
      references: references,
      selectedIndex: selectedIndex,
      invalidIndices: invalidIndices,
      readOnly: readOnly,
      onSelectMain: onSelectMain,
      onSelectReference: onSelectReference,
      onAddReference: onAddReference,
      onDeleteReference: onDeleteReference,
    );
  }
}

class _ReferenceFileEditor extends HookWidget {
  const _ReferenceFileEditor({
    super.key,
    required this.file,
    required this.readOnly,
    required this.onChanged,
    this.nameError,
    this.contentError,
  });

  final AgentSkillReferenceFile file;
  final bool readOnly;
  final ValueChanged<AgentSkillReferenceFile> onChanged;

  /// 文件名 / 内容 inline error（仅切换文件或保存校验失败时由父层传入，
  /// 不做实时校验）。
  final String? nameError;
  final String? contentError;

  @override
  Widget build(BuildContext context) {
    final fileName =
        file.path.startsWith(AgentSkillReferences.relativeDirPrefix)
        ? file.path.substring(AgentSkillReferences.relativeDirPrefix.length)
        : file.path;
    final nameController = useTextEditingController(text: fileName);
    final contentController = useTextEditingController(text: file.content);
    final syncing = useRef(false);

    useEffect(() {
      syncing.value = true;
      final nextName =
          file.path.startsWith(AgentSkillReferences.relativeDirPrefix)
          ? file.path.substring(AgentSkillReferences.relativeDirPrefix.length)
          : file.path;
      if (nameController.text != nextName) {
        nameController.text = nextName;
      }
      if (contentController.text != file.content) {
        contentController.text = file.content;
      }
      syncing.value = false;
      return null;
    }, [file.path, file.content]);

    void emit() {
      if (syncing.value || readOnly) {
        return;
      }
      final rawName = nameController.text.trim();
      // 不做 untitled 兜底：空名 → 'references/' 非法路径，交由切换/保存校验捕获。
      final path = '${AgentSkillReferences.relativeDirPrefix}$rawName';
      onChanged(
        AgentSkillReferenceFile(path: path, content: contentController.text),
      );
    }

    useEffect(() {
      void onName() => emit();
      void onContent() => emit();
      nameController.addListener(onName);
      contentController.addListener(onContent);
      return () {
        nameController.removeListener(onName);
        contentController.removeListener(onContent);
      };
    }, [file.path, readOnly]);

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: RevericTheme.colorsOf(context).borderInput),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RevericTextField(
            controller: nameController,
            readOnly: readOnly,
            errorText: readOnly ? null : nameError,
            hintText: context.t(LocaleKeys.agentSkillReferencesFileName),
          ),
          const SizedBox(height: RevericSpacing.sm),
          RevericTextField(
            controller: contentController,
            readOnly: readOnly,
            errorText: readOnly ? null : contentError,
            multiline: true,
            minLines: 14,
            maxLines: 40,
            hintText: context.t(LocaleKeys.agentSkillReferencesContentHint),
          ),
        ],
      ),
    );
  }
}

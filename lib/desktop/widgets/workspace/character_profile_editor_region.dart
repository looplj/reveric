// 职责: 桌面人物编辑区域 — 独立管理人物表单、输入资源、草稿、媒体与历史化保存编排。
// 关联文件:
//   lib/desktop/widgets/workspace/character_profile_editor.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/models/character_profile.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
// 遵循的 Rules:
//   .agents/rules/form.md
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/text-input-ime.md

import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/character_profile.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/providers/ai_providers.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../../shared/services/ai/chat.dart';
import '../../../shared/services/novel_content.dart';
import '../../../shared/services/working_overlay.dart';
import '../../../shared/utils/text_input_composing.dart';
import '../../../third/form/flutter_hook_form.dart';
import 'character_profile_editor.dart';

const _characterAutoSaveDelay = Duration(milliseconds: 800);

class CharacterProfileEditorSnapshot {
  const CharacterProfileEditorSnapshot({
    required this.name,
    required this.role,
    required this.gender,
    required this.biography,
  });

  final String name;
  final String role;
  final String gender;
  final String biography;
}

class CharacterProfileEditorRegionHost {
  const CharacterProfileEditorRegionHost({
    required this.onCreateCharacter,
    required this.onSavingChanged,
    required this.onGenerateAvatar,
    required this.onGeneratePhoto,
    this.onNavigateToChapter,
    this.onOpenEntityGraph,
  });

  final VoidCallback onCreateCharacter;
  final ValueChanged<bool> onSavingChanged;
  final Future<void> Function(String prompt, String characterId)
  onGenerateAvatar;
  final Future<void> Function(String prompt, String characterId)
  onGeneratePhoto;
  final ValueChanged<String>? onNavigateToChapter;
  final VoidCallback? onOpenEntityGraph;
}

class CharacterProfileEditorRegionController {
  Object? _bindingToken;
  _CharacterProfileRegionBinding? _binding;

  bool get hasDraftContent => _binding?.hasDraftContent() ?? false;

  CharacterProfileEditorSnapshot? get snapshot => _binding?.snapshot();

  Future<String?> save({bool showSuccess = false}) {
    return _binding?.save(showSuccess: showSuccess) ?? Future<String?>.value();
  }

  Future<String?> replaceBiographyAndSave(String content) {
    return _binding?.replaceBiographyAndSave(content) ??
        Future<String?>.value();
  }

  Future<bool> flushBeforeTransition({required String? selectedItemId}) async {
    if (selectedItemId == null) {
      return true;
    }
    // 人物编辑区不在树上（主区当前是智能体规则 / 封面工坊等非工作区页面）时没有
    // 任何待落盘草稿，`save()` 恒为 null。此时若按「保存失败」拦截，会把切 section、
    // 打开规则、返回等所有导航静默拦死，且 selection 会被持久化、重进依然复现。
    final binding = _binding;
    if (binding == null) {
      return true;
    }
    return await binding.save() != null;
  }

  void _attach(Object token, _CharacterProfileRegionBinding binding) {
    _bindingToken = token;
    _binding = binding;
  }

  void _detach(Object token) {
    if (identical(_bindingToken, token)) {
      _bindingToken = null;
      _binding = null;
    }
  }
}

class _CharacterProfileRegionBinding {
  const _CharacterProfileRegionBinding({
    required this.hasDraftContent,
    required this.snapshot,
    required this.save,
    required this.replaceBiographyAndSave,
  });

  final bool Function() hasDraftContent;
  final CharacterProfileEditorSnapshot Function() snapshot;
  final Future<String?> Function({bool showSuccess}) save;
  final Future<String?> Function(String content) replaceBiographyAndSave;
}

class _CharacterProfileSaveRequest {
  const _CharacterProfileSaveRequest({
    required this.name,
    required this.role,
    required this.gender,
    required this.aliases,
    required this.tags,
    required this.identity,
    required this.age,
    required this.motivation,
    required this.arc,
    required this.biography,
    required this.appearance,
    required this.personality,
    required this.description,
    required this.behaviorTags,
    required this.currentState,
    required this.avatarAssetId,
    required this.photos,
  });

  final String name;
  final String role;
  final String gender;
  final List<String> aliases;
  final List<String> tags;
  final String identity;
  final String age;
  final String motivation;
  final String arc;
  final String biography;
  final String appearance;
  final String personality;
  final String description;
  final List<CharacterBehaviorTag> behaviorTags;
  final String currentState;
  final String? avatarAssetId;
  final List<SubjectPhoto> photos;
}

class _CharacterProfileSaveOrchestrator {
  Future<String?> save({
    required NovelContentService service,
    required WorkingOverlayService overlay,
    required bool isCreating,
    required String? entryId,
    required _CharacterProfileSaveRequest request,
  }) async {
    if (isCreating) {
      final createdId = await service.createCharacterProfile(
        name: request.name,
        role: request.role,
        gender: request.gender,
        aliases: request.aliases,
        tags: request.tags,
        identity: request.identity,
        age: request.age,
        motivation: request.motivation,
        arc: request.arc,
        biography: request.biography,
        appearance: request.appearance,
        personality: request.personality,
        description: request.description,
        behaviorTags: request.behaviorTags,
        currentState: request.currentState,
      );
      if (request.avatarAssetId != null || request.photos.isNotEmpty) {
        await service.updateCharacterAvatarAndPhotos(
          entryId: createdId,
          avatarAssetId: request.avatarAssetId,
          photos: request.photos.isEmpty ? null : request.photos,
        );
      }
      return createdId;
    }

    if (entryId == null) {
      return null;
    }
    final existing = await service.getCharacterProfileById(entryId);
    if (existing == null) {
      return null;
    }
    final changeIds = <String>[];

    Future<void> stageText({
      required String field,
      required String oldText,
      required String newText,
    }) async {
      if (oldText == newText) {
        return;
      }
      final change = await overlay.stageTextChange(
        resourcePath: '/characters/$entryId/$field',
        resourceType: 'characters',
        resourceId: entryId,
        field: field,
        oldText: oldText,
        newText: newText,
        source: workingChangeSourceManual,
        summary: 'Update character $field',
      );
      changeIds.add(change.id);
    }

    await stageText(
      field: 'name',
      oldText: existing.name,
      newText: request.name,
    );
    await stageText(
      field: 'role',
      oldText: existing.role,
      newText: request.role,
    );
    await stageText(
      field: 'gender',
      oldText: existing.gender,
      newText: request.gender,
    );
    await stageText(
      field: 'identity',
      oldText: existing.identity,
      newText: request.identity,
    );
    await stageText(field: 'age', oldText: existing.age, newText: request.age);
    await stageText(
      field: 'motivation',
      oldText: existing.motivation,
      newText: request.motivation,
    );
    await stageText(field: 'arc', oldText: existing.arc, newText: request.arc);
    await stageText(
      field: 'biography',
      oldText: existing.biography,
      newText: request.biography,
    );
    await stageText(
      field: 'appearance',
      oldText: existing.appearance,
      newText: request.appearance,
    );
    await stageText(
      field: 'description',
      oldText: existing.description,
      newText: request.description,
    );
    await stageText(
      field: 'personality',
      oldText: existing.personality,
      newText: request.personality,
    );
    await stageText(
      field: 'current_state',
      oldText: existing.currentState,
      newText: request.currentState,
    );
    if (!listEquals(existing.aliases, request.aliases)) {
      await stageText(
        field: 'aliases',
        oldText: jsonEncode(existing.aliases),
        newText: jsonEncode(request.aliases),
      );
    }
    if (!listEquals(existing.tags, request.tags)) {
      await service.updateCharacterTags(entryId: entryId, tags: request.tags);
    }
    if (!listEquals(existing.behaviorTags, request.behaviorTags)) {
      await stageText(
        field: 'behavior_tags',
        oldText: jsonEncode(
          existing.behaviorTags.map((tag) => tag.toJson()).toList(),
        ),
        newText: jsonEncode(
          request.behaviorTags.map((tag) => tag.toJson()).toList(),
        ),
      );
    }
    if (changeIds.isNotEmpty) {
      await overlay.commitManualSave(
        manualChangeIds: changeIds,
        resourceScopes: ['/characters/$entryId'],
        manualMessage: 'history.commit_message.manual_entry_save',
      );
    }
    return entryId;
  }
}

class _CharacterMediaOrchestrator {
  Future<String> importAvatar({
    required NovelContentService service,
    required String sourcePath,
    required String? characterId,
  }) async {
    final assetId = await service.saveCharacterImage(
      sourcePath: sourcePath,
      kind: 'avatar',
    );
    if (characterId != null) {
      await service.updateCharacterAvatarAndPhotos(
        entryId: characterId,
        avatarAssetId: assetId,
      );
    }
    return assetId;
  }

  Future<List<SubjectPhoto>> importPhoto({
    required NovelContentService service,
    required String sourcePath,
    required String? characterId,
    required List<SubjectPhoto> currentPhotos,
  }) async {
    final assetId = await service.saveCharacterImage(
      sourcePath: sourcePath,
      kind: 'photo',
    );
    final next = [...currentPhotos, SubjectPhoto(assetId: assetId)];
    if (characterId != null) {
      await service.updateCharacterAvatarAndPhotos(
        entryId: characterId,
        photos: next,
      );
    }
    return next;
  }

  /// 只移除人物引用；图片资产可能还被别处引用，文件保留。
  Future<void> removePhoto({
    required NovelContentService service,
    required String? characterId,
    required List<SubjectPhoto> nextPhotos,
  }) async {
    if (characterId != null) {
      await service.updateCharacterAvatarAndPhotos(
        entryId: characterId,
        photos: nextPhotos,
      );
    }
  }
}

class _CharacterMediaState extends ChangeNotifier {
  String? avatarAssetId;
  List<SubjectPhoto> photos = const <SubjectPhoto>[];
  bool avatarPicking = false;
  bool photoAdding = false;

  void load({required String? avatar, required List<SubjectPhoto> nextPhotos}) {
    avatarAssetId = avatar;
    photos = nextPhotos;
    notifyListeners();
  }

  void setAvatar(String? value) {
    avatarAssetId = value;
    notifyListeners();
  }

  void setPhotos(List<SubjectPhoto> value) {
    photos = value;
    notifyListeners();
  }

  void setAvatarPicking(bool value) {
    avatarPicking = value;
    notifyListeners();
  }

  void setPhotoAdding(bool value) {
    photoAdding = value;
    notifyListeners();
  }
}

class CharacterProfileEditorRegion extends HookConsumerWidget {
  const CharacterProfileEditorRegion({
    super.key,
    required this.databasePath,
    required this.selection,
    required this.novel,
    required this.controller,
    required this.nameAssistantAiService,
    required this.host,
  });

  final String databasePath;
  final WorkspaceSelection selection;
  final Novel novel;
  final CharacterProfileEditorRegionController controller;
  final AiClient? nameAssistantAiService;
  final CharacterProfileEditorRegionHost host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final characterProfiles =
        ref.watch(characterProfilesProvider(databasePath)).asData?.value ??
        const <CharacterProfile>[];
    final selectedCharacter = characterProfiles
        .where((character) => character.id == selection.itemId)
        .firstOrNull;
    final service = ref.watch(
      workContentServiceProvider((path: databasePath, novelId: novel.id)),
    );
    final overlay = ref.watch(
      workOverlayServiceProvider((path: databasePath, novelId: novel.id)),
    );
    final editorFontFamily = ref.watch(editorFontFamilyProvider);
    final editorFontSize = ref.watch(editorFontSizeProvider);
    final isImageGenerationConfigured = ref.watch(
      isImageGenerationConfiguredProvider,
    );

    final form = useForm<CharacterProfileEditFields>(
      initialValues: _formValues(selectedCharacter),
      keys: [
        selection.itemId ?? '__character_create__',
        selection.isCreating,
        selectedCharacter?.updatedAt,
      ],
      listen: false,
    );
    final nameController = useTextEditingController();
    final roleController = useTextEditingController(
      text: characterRoleSupporting,
    );
    final genderController = useTextEditingController(
      text: characterGenderUnknown,
    );
    final identityController = useTextEditingController();
    final ageController = useTextEditingController(text: '未知');
    final motivationController = useTextEditingController();
    final arcController = useTextEditingController();
    final biographyController = useTextEditingController();
    final appearanceController = useTextEditingController();
    final descriptionController = useTextEditingController();
    final personalityController = useTextEditingController();
    final currentStateController = useTextEditingController();
    final nameFocusNode = useFocusNode();
    final identityFocusNode = useFocusNode();
    final ageFocusNode = useFocusNode();
    final motivationFocusNode = useFocusNode();
    final arcFocusNode = useFocusNode();
    final biographyFocusNode = useFocusNode();
    final appearanceFocusNode = useFocusNode();
    final descriptionFocusNode = useFocusNode();
    final personalityFocusNode = useFocusNode();
    final currentStateFocusNode = useFocusNode();
    final aliases = useState<List<String>>(const <String>[]);
    final tags = useState<List<String>>(const <String>[]);
    final behaviorTags = useState<List<CharacterBehaviorTag>>(
      const <CharacterBehaviorTag>[],
    );
    final media = useMemoized(_CharacterMediaState.new);
    useListenable(media);
    final syncingControllers = useRef(false);
    final loadedTarget = useRef<String?>(null);
    final autoSaveTimer = useRef<Timer?>(null);
    final saveInFlight = useRef<Future<String?>?>(null);
    final bindingToken = useMemoized(Object.new);

    final textControllers = <TextEditingController>[
      nameController,
      roleController,
      genderController,
      identityController,
      ageController,
      motivationController,
      arcController,
      biographyController,
      appearanceController,
      descriptionController,
      personalityController,
      currentStateController,
    ];

    CharacterProfileEditorSnapshot snapshot() {
      return CharacterProfileEditorSnapshot(
        name: nameController.text.trim(),
        role: roleController.text,
        gender: genderController.text,
        biography: biographyController.text,
      );
    }

    bool hasDraftContent() {
      if (!selection.isCreating) {
        return false;
      }
      return nameController.text.trim().isNotEmpty ||
          identityController.text.trim().isNotEmpty ||
          motivationController.text.trim().isNotEmpty ||
          arcController.text.trim().isNotEmpty ||
          biographyController.text.trim().isNotEmpty ||
          appearanceController.text.trim().isNotEmpty ||
          descriptionController.text.trim().isNotEmpty ||
          personalityController.text.trim().isNotEmpty ||
          currentStateController.text.trim().isNotEmpty ||
          aliases.value.isNotEmpty ||
          tags.value.isNotEmpty ||
          behaviorTags.value.isNotEmpty ||
          media.avatarAssetId != null ||
          media.photos.isNotEmpty;
    }

    bool hasComposingText() {
      return textControllers.any(isTextInputComposing);
    }

    Future<String?> persist({bool showSuccess = false}) async {
      if (hasComposingText()) {
        autoSaveTimer.value?.cancel();
        autoSaveTimer.value = null;
        return null;
      }
      final activeSave = saveInFlight.value;
      if (activeSave != null) {
        return activeSave;
      }

      late final Future<String?> future;
      future = () async {
        autoSaveTimer.value?.cancel();
        autoSaveTimer.value = null;
        syncFormFieldsFromControllersBeforeValidate(
          form: form,
          fields: {
            CharacterProfileEditFields.name: nameController,
            CharacterProfileEditFields.role: roleController,
            CharacterProfileEditFields.gender: genderController,
            CharacterProfileEditFields.identity: identityController,
            CharacterProfileEditFields.age: ageController,
            CharacterProfileEditFields.motivation: motivationController,
            CharacterProfileEditFields.arc: arcController,
            CharacterProfileEditFields.biography: biographyController,
            CharacterProfileEditFields.appearance: appearanceController,
            CharacterProfileEditFields.description: descriptionController,
            CharacterProfileEditFields.personality: personalityController,
            CharacterProfileEditFields.currentState: currentStateController,
          },
        );
        form.updateValue(
          CharacterProfileEditFields.aliases,
          aliases.value,
          notify: false,
        );
        form.updateValue(
          CharacterProfileEditFields.tags,
          tags.value,
          notify: false,
        );
        form.updateValue(
          CharacterProfileEditFields.behaviorTags,
          behaviorTags.value,
          notify: false,
        );
        if (!form.validate()) {
          if (showSuccess) {
            nameFocusNode.requestFocus();
          }
          return null;
        }
        final normalizedName = nameController.text.trim().toLowerCase();
        final nameConflictsWithAlias = aliases.value.any(
          (alias) => alias.trim().toLowerCase() == normalizedName,
        );
        if (nameConflictsWithAlias) {
          form.setError(
            CharacterProfileEditFields.name,
            context.t(LocaleKeys.workspaceCharacterNameConflictsWithAlias),
          );
          if (showSuccess) {
            nameFocusNode.requestFocus();
          }
          return null;
        }

        final request = _CharacterProfileSaveRequest(
          name: nameController.text.trim(),
          role: roleController.text,
          gender: genderController.text,
          aliases: aliases.value,
          tags: tags.value,
          identity: identityController.text,
          age: ageController.text,
          motivation: motivationController.text,
          arc: arcController.text,
          biography: biographyController.text,
          appearance: appearanceController.text,
          personality: personalityController.text,
          description: descriptionController.text,
          behaviorTags: behaviorTags.value,
          currentState: currentStateController.text,
          avatarAssetId: media.avatarAssetId,
          photos: media.photos,
        );
        host.onSavingChanged(true);
        try {
          final savedId = await _CharacterProfileSaveOrchestrator().save(
            service: service,
            overlay: overlay,
            isCreating: selection.isCreating,
            entryId: selection.itemId,
            request: request,
          );
          if (savedId != null && showSuccess && context.mounted) {
            _showSaved(context);
          }
          return savedId;
        } finally {
          host.onSavingChanged(false);
        }
      }();
      saveInFlight.value = future;
      try {
        return await future;
      } finally {
        if (identical(saveInFlight.value, future)) {
          saveInFlight.value = null;
        }
      }
    }

    void scheduleAutoSave() {
      if (syncingControllers.value || selection.isCreating) {
        return;
      }
      if (hasComposingText()) {
        autoSaveTimer.value?.cancel();
        autoSaveTimer.value = null;
        return;
      }
      autoSaveTimer.value?.cancel();
      autoSaveTimer.value = Timer(
        _characterAutoSaveDelay,
        () => unawaited(persist()),
      );
    }

    Future<String?> replaceBiographyAndSave(String content) async {
      syncingControllers.value = true;
      biographyController.value = TextEditingValue(
        text: content,
        selection: TextSelection.collapsed(offset: content.length),
      );
      syncingControllers.value = false;
      return persist();
    }

    useEffect(() {
      final targetKey = selection.isCreating
          ? '__character_create__'
          : selection.itemId;
      final targetChanged = loadedTarget.value != targetKey;
      syncingControllers.value = true;
      try {
        if (selection.isCreating) {
          if (targetChanged) {
            _syncController(nameController, '', nameFocusNode, force: true);
            roleController.text = characterRoleSupporting;
            genderController.text = characterGenderUnknown;
            _syncController(
              identityController,
              '',
              identityFocusNode,
              force: true,
            );
            _syncController(ageController, '未知', ageFocusNode, force: true);
            _syncController(
              motivationController,
              '',
              motivationFocusNode,
              force: true,
            );
            _syncController(arcController, '', arcFocusNode, force: true);
            _syncController(
              biographyController,
              '',
              biographyFocusNode,
              force: true,
            );
            _syncController(
              appearanceController,
              '',
              appearanceFocusNode,
              force: true,
            );
            _syncController(
              descriptionController,
              '',
              descriptionFocusNode,
              force: true,
            );
            _syncController(
              personalityController,
              '',
              personalityFocusNode,
              force: true,
            );
            _syncController(
              currentStateController,
              '',
              currentStateFocusNode,
              force: true,
            );
            aliases.value = const <String>[];
            tags.value = const <String>[];
            behaviorTags.value = const <CharacterBehaviorTag>[];
            media.load(avatar: null, nextPhotos: const <SubjectPhoto>[]);
          }
        } else if (selectedCharacter != null) {
          _syncController(
            nameController,
            selectedCharacter.name,
            nameFocusNode,
            force: targetChanged,
          );
          roleController.text = selectedCharacter.normalizedRole;
          genderController.text = selectedCharacter.normalizedGender;
          _syncController(
            identityController,
            selectedCharacter.identity,
            identityFocusNode,
            force: targetChanged,
          );
          _syncController(
            ageController,
            selectedCharacter.age,
            ageFocusNode,
            force: targetChanged,
          );
          _syncController(
            motivationController,
            selectedCharacter.motivation,
            motivationFocusNode,
            force: targetChanged,
          );
          _syncController(
            arcController,
            selectedCharacter.arc,
            arcFocusNode,
            force: targetChanged,
          );
          _syncController(
            biographyController,
            selectedCharacter.biography,
            biographyFocusNode,
            force: targetChanged,
          );
          _syncController(
            appearanceController,
            selectedCharacter.appearance,
            appearanceFocusNode,
            force: targetChanged,
          );
          _syncController(
            descriptionController,
            selectedCharacter.description,
            descriptionFocusNode,
            force: targetChanged,
          );
          _syncController(
            personalityController,
            selectedCharacter.personality,
            personalityFocusNode,
            force: targetChanged,
          );
          _syncController(
            currentStateController,
            selectedCharacter.currentState,
            currentStateFocusNode,
            force: targetChanged,
          );
          aliases.value = selectedCharacter.aliases;
          tags.value = selectedCharacter.tags;
          behaviorTags.value = selectedCharacter.behaviorTags;
          media.load(
            avatar: selectedCharacter.avatarAssetId,
            nextPhotos: selectedCharacter.photos ?? const <SubjectPhoto>[],
          );
        }
        loadedTarget.value = targetKey;
      } finally {
        syncingControllers.value = false;
      }
      return null;
    }, [selection.itemId, selection.isCreating, selectedCharacter?.updatedAt]);

    useOnListenableChange(nameController, scheduleAutoSave);
    useOnListenableChange(roleController, scheduleAutoSave);
    useOnListenableChange(genderController, scheduleAutoSave);
    useOnListenableChange(identityController, scheduleAutoSave);
    useOnListenableChange(ageController, scheduleAutoSave);
    useOnListenableChange(motivationController, scheduleAutoSave);
    useOnListenableChange(arcController, scheduleAutoSave);
    useOnListenableChange(biographyController, scheduleAutoSave);
    useOnListenableChange(appearanceController, scheduleAutoSave);
    useOnListenableChange(descriptionController, scheduleAutoSave);
    useOnListenableChange(personalityController, scheduleAutoSave);
    useOnListenableChange(currentStateController, scheduleAutoSave);

    // 失焦落盘必须调用「本次 build 的 persist」：form 控制器会随人物切换和每次保存
    // 重建，effect 里捕获的旧 persist 拿着已经不在树上的 Form key，`form.validate()`
    // 恒为 false，于是把焦点抢回名称字段且一个字都存不下去。
    final flushOnBlurRef = useRef<void Function(FocusNode)>((_) {});
    flushOnBlurRef.value = (node) {
      if (!node.hasFocus && !selection.isCreating && !hasComposingText()) {
        autoSaveTimer.value?.cancel();
        autoSaveTimer.value = null;
        unawaited(persist());
      }
    };

    useEffect(() {
      final focusNodes = <FocusNode>[
        nameFocusNode,
        identityFocusNode,
        ageFocusNode,
        motivationFocusNode,
        arcFocusNode,
        biographyFocusNode,
        appearanceFocusNode,
        descriptionFocusNode,
        personalityFocusNode,
        currentStateFocusNode,
      ];
      final listeners = <VoidCallback>[];
      for (final node in focusNodes) {
        void listener() => flushOnBlurRef.value(node);
        listeners.add(listener);
        node.addListener(listener);
      }
      return () {
        for (var index = 0; index < focusNodes.length; index++) {
          focusNodes[index].removeListener(listeners[index]);
        }
      };
    }, const []);

    useEffect(() {
      return () {
        autoSaveTimer.value?.cancel();
        controller._detach(bindingToken);
        media.dispose();
      };
    }, [controller, bindingToken, media]);

    Future<void> pickAvatar() async {
      final selected = await _selectImage();
      if (selected == null || !context.mounted) {
        return;
      }
      media.setAvatarPicking(true);
      try {
        final stored = await _CharacterMediaOrchestrator().importAvatar(
          service: service,
          sourcePath: selected,
          characterId: selection.itemId,
        );
        media.setAvatar(stored);
      } finally {
        media.setAvatarPicking(false);
      }
    }

    Future<void> addPhoto() async {
      final selected = await _selectImages();
      if (selected.isEmpty || !context.mounted) {
        return;
      }
      media.setPhotoAdding(true);
      try {
        // 逐张导入，单张失败跳过不影响其余；importPhoto 内部已逐次落库。
        var photos = media.photos;
        for (final path in selected) {
          photos = await _CharacterMediaOrchestrator().importPhoto(
            service: service,
            sourcePath: path,
            characterId: selection.itemId,
            currentPhotos: photos,
          );
        }
        media.setPhotos(photos);
      } finally {
        media.setPhotoAdding(false);
      }
    }

    Future<void> removePhoto(String assetId) async {
      final next = media.photos
          .where((photo) => photo.assetId != assetId)
          .toList();
      media.setPhotos(next);
      await _CharacterMediaOrchestrator().removePhoto(
        service: service,
        characterId: selection.itemId,
        nextPhotos: next,
      );
    }

    Future<void> removeAvatar() async {
      media.setAvatar(null);
      if (selection.itemId case final characterId?) {
        await service.updateCharacterAvatarAndPhotos(
          entryId: characterId,
          avatarAssetId: '',
        );
      }
    }

    controller._attach(
      bindingToken,
      _CharacterProfileRegionBinding(
        hasDraftContent: hasDraftContent,
        snapshot: snapshot,
        save: persist,
        replaceBiographyAndSave: replaceBiographyAndSave,
      ),
    );

    return CharacterProfileEditor(
      session: CharacterProfileEditorSession(
        target: CharacterProfileEditorTarget(
          selectedItemId: selection.itemId,
          isCreating: selection.isCreating,
          characterProfiles: characterProfiles,
        ),
        fields: CharacterProfileFormSession(
          form: form,
          controllers: {
            CharacterProfileEditFields.name: nameController,
            CharacterProfileEditFields.role: roleController,
            CharacterProfileEditFields.gender: genderController,
            CharacterProfileEditFields.identity: identityController,
            CharacterProfileEditFields.age: ageController,
            CharacterProfileEditFields.motivation: motivationController,
            CharacterProfileEditFields.arc: arcController,
            CharacterProfileEditFields.biography: biographyController,
            CharacterProfileEditFields.appearance: appearanceController,
            CharacterProfileEditFields.description: descriptionController,
            CharacterProfileEditFields.personality: personalityController,
            CharacterProfileEditFields.currentState: currentStateController,
          },
          focusNodes: {
            CharacterProfileEditFields.name: nameFocusNode,
            CharacterProfileEditFields.identity: identityFocusNode,
            CharacterProfileEditFields.age: ageFocusNode,
            CharacterProfileEditFields.motivation: motivationFocusNode,
            CharacterProfileEditFields.arc: arcFocusNode,
            CharacterProfileEditFields.biography: biographyFocusNode,
            CharacterProfileEditFields.appearance: appearanceFocusNode,
            CharacterProfileEditFields.description: descriptionFocusNode,
            CharacterProfileEditFields.personality: personalityFocusNode,
            CharacterProfileEditFields.currentState: currentStateFocusNode,
          },
          aliases: aliases.value,
          tags: tags.value,
          behaviorTags: behaviorTags.value,
          onAliasesChanged: (next) {
            aliases.value = next;
            scheduleAutoSave();
          },
          onTagsChanged: (next) {
            tags.value = next;
            scheduleAutoSave();
          },
          onBehaviorTagsChanged: (next) {
            behaviorTags.value = next;
            scheduleAutoSave();
          },
        ),
        media: CharacterProfileMediaSession(
          avatarAssetId: media.avatarAssetId,
          photos: media.photos,
          avatarPicking: media.avatarPicking,
          photoAdding: media.photoAdding,
          isImageGenerationConfigured:
              !selection.isCreating && isImageGenerationConfigured,
          onPickAvatar: pickAvatar,
          onAddPhoto: addPhoto,
          onRemovePhoto: removePhoto,
          onRenamePhoto: (assetId, name) async {
            final List<SubjectPhoto> next;
            if (selection.itemId case final id?) {
              next = await service.renameCharacterPhoto(
                id: id,
                assetId: assetId,
                name: name,
              );
            } else {
              next = media.photos
                  .map(
                    (photo) => photo.assetId == assetId
                        ? photo.copyWith(name: name.trim())
                        : photo,
                  )
                  .toList();
            }
            if (context.mounted) {
              media.setPhotos(next);
            }
          },
          onRemoveAvatar: removeAvatar,
          onGenerateAvatar: host.onGenerateAvatar,
          onGeneratePhoto: host.onGeneratePhoto,
        ),
        onCreateCharacter: host.onCreateCharacter,
      ),
      editorFontFamily: editorFontFamily,
      editorFontSize: editorFontSize,
      nameAssistantAiService: nameAssistantAiService,
      novel: novel,
      databasePath: databasePath,
      onNavigateToChapter: host.onNavigateToChapter,
      onOpenEntityGraph: host.onOpenEntityGraph,
    );
  }
}

Map<CharacterProfileEditFields, dynamic> _formValues(
  CharacterProfile? character,
) {
  return {
    CharacterProfileEditFields.name: character?.name ?? '',
    CharacterProfileEditFields.role:
        character?.normalizedRole ?? characterRoleSupporting,
    CharacterProfileEditFields.gender:
        character?.normalizedGender ?? characterGenderUnknown,
    CharacterProfileEditFields.aliases: character?.aliases ?? const <String>[],
    CharacterProfileEditFields.tags: character?.tags ?? const <String>[],
    CharacterProfileEditFields.identity: character?.identity ?? '',
    CharacterProfileEditFields.age: character?.age ?? '未知',
    CharacterProfileEditFields.motivation: character?.motivation ?? '',
    CharacterProfileEditFields.arc: character?.arc ?? '',
    CharacterProfileEditFields.description: character?.description ?? '',
    CharacterProfileEditFields.biography: character?.biography ?? '',
    CharacterProfileEditFields.appearance: character?.appearance ?? '',
    CharacterProfileEditFields.personality: character?.personality ?? '',
    CharacterProfileEditFields.behaviorTags:
        character?.behaviorTags ?? const <CharacterBehaviorTag>[],
    CharacterProfileEditFields.currentState: character?.currentState ?? '',
    CharacterProfileEditFields.firstAppearChapterId:
        character?.firstAppearChapterId,
    CharacterProfileEditFields.avatar: character?.avatarAssetId ?? '',
    CharacterProfileEditFields.photos:
        character?.photos ?? const <SubjectPhoto>[],
  };
}

void _syncController(
  TextEditingController controller,
  String text,
  FocusNode focusNode, {
  required bool force,
}) {
  if (controller.text == text || (!force && focusNode.hasFocus)) {
    return;
  }
  controller.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
}

Future<String?> _selectImage() async {
  final result = await openFile(
    acceptedTypeGroups: [
      const XTypeGroup(
        label: 'images',
        extensions: ['png', 'jpg', 'jpeg', 'webp'],
      ),
    ],
  );
  return result?.path;
}

Future<List<String>> _selectImages() async {
  final results = await openFiles(
    acceptedTypeGroups: [
      const XTypeGroup(
        label: 'images',
        extensions: ['png', 'jpg', 'jpeg', 'webp'],
      ),
    ],
  );
  return results.map((file) => file.path).toList(growable: false);
}

void _showSaved(BuildContext context) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(context.t(LocaleKeys.commonSaved))));
}

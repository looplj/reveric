// 职责: 移动端人物编辑页，把完整人物档案平铺成七个分组的连续滚动页并以防抖方式保存。
// 关联文件:
//   lib/mobile/widgets/characters_panel.dart
//   lib/mobile/widgets/chapter_picker_sheet.dart
//   lib/shared/widgets/character/character_profile_section.dart
//   lib/shared/widgets/character/character_relations_overview.dart
//   lib/shared/components/reveric_select.dart
//   lib/shared/components/reveric_text_field.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/widgets/character_avatar.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/models/character_profile.dart
//   lib/shared/models/chapter.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/character.json
//   assets/translations/zh-CN/character.json
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/error-handling.md
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../shared/components/reveric_select.dart';
import '../../shared/components/reveric_text_field.dart';
import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/models/character_profile.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/character/character_profile_section.dart';
import '../../shared/widgets/character/character_relations_overview.dart';
import '../../shared/widgets/character/character_tag_fields.dart';
import '../../shared/widgets/character_avatar.dart';
import '../../shared/widgets/subject_photo_name.dart';
import '../../shared/widgets/md/reveric_markdown_editor.dart';
import '../widgets/chapter_picker_sheet.dart';
import '../widgets/character_image_actions.dart';
import '../widgets/detail_scaffold.dart';
import '../widgets/editor_app_bar.dart';
import '../../shared/widgets/media_asset_image.dart';

final _log = AppLogger.forModule('MobileCharacterEditor');

/// 角色编辑页（按 id 加载）：从角色列表按 id 取 profile 后渲染编辑主体。
/// 拆 loader 让条目跳转/列表打开统一「只传 id」，主体同步拿到具体对象不变。
class MobileCharacterEditorPage extends ConsumerWidget {
  const MobileCharacterEditorPage({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.characterId,
    this.onOpenGraph,
    this.isScreenplay = false,
  });

  final String databasePath;
  final String novelId;
  final String characterId;

  /// 关系网络分组的「在关系图中查看」入口；为空时隐藏（如从聊天页推入，无法切回关系图）。
  final VoidCallback? onOpenGraph;

  /// 剧本作品没有章节，「本作首次出场」整行隐藏。
  final bool isScreenplay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref
        .watch(characterProfilesProvider(databasePath))
        .asData
        ?.value;
    final character = list?.cast<CharacterProfile?>().firstWhere(
      (c) => c?.id == characterId,
      orElse: () => null,
    );
    if (character == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _CharacterEditorBody(
      key: ValueKey(character.id),
      novelId: novelId,
      databasePath: databasePath,
      character: character,
      onOpenGraph: onOpenGraph,
      isScreenplay: isScreenplay,
    );
  }
}

class _CharacterEditorBody extends HookConsumerWidget {
  const _CharacterEditorBody({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.character,
    required this.onOpenGraph,
    required this.isScreenplay,
  });

  final String databasePath;
  final String novelId;
  final CharacterProfile character;
  final VoidCallback? onOpenGraph;
  final bool isScreenplay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);

    final nameController = useTextEditingController(text: character.name);
    final identityController = useTextEditingController(
      text: character.identity,
    );
    final ageController = useTextEditingController(text: character.age);
    final motivationController = useTextEditingController(
      text: character.motivation,
    );
    final arcController = useTextEditingController(text: character.arc);
    final summaryController = useTextEditingController(
      text: character.biography,
    );
    final appearanceController = useTextEditingController(
      text: character.appearance,
    );
    final descriptionController = useTextEditingController(
      text: character.description,
    );
    final personalityController = useTextEditingController(
      text: character.personality,
    );
    final currentStateController = useTextEditingController(
      text: character.currentState,
    );
    final motivationFocusNode = useFocusNode();
    final arcFocusNode = useFocusNode();
    final summaryFocusNode = useFocusNode();
    final appearanceFocusNode = useFocusNode();
    final descriptionFocusNode = useFocusNode();
    final personalityFocusNode = useFocusNode();
    final currentStateFocusNode = useFocusNode();
    final scrollController = useScrollController();
    // 共享 undo/redo 控制器：名称/小传/描述同页，按钮作用于当前焦点字段。
    final undoController = useMemoized(UndoHistoryController.new);
    useEffect(() => undoController.dispose, const []);
    final role = useState<String>(character.normalizedRole);
    final gender = useState<String>(character.normalizedGender);
    final aliases = useState<List<String>>(character.aliases);
    final tags = useState<List<String>>(character.tags);
    final behaviorTags = useState<List<CharacterBehaviorTag>>(
      character.behaviorTags,
    );
    final spy = useMemoized(
      () => CharacterProfileScrollSpy(
        scrollController: scrollController,
        stickyExtent: characterProfileAnchorBarHeight,
      ),
      [scrollController],
    );
    useEffect(() {
      spy.attach();
      return spy.dispose;
    }, [spy]);
    // 图像由人物流持有，聊天应用生成结果后无需重新打开编辑页。
    final avatarAssetId = character.avatarAssetId;
    final photos = character.photos ?? const <SubjectPhoto>[];
    final firstAppearChapterId = useState<String?>(
      character.firstAppearChapterId,
    );
    final picking = useState<bool>(false);

    final dirty = useRef(false);
    final autoSaveTimer = useRef<Timer?>(null);
    final saveState = useState<(bool, DateTime?)>((false, character.updatedAt));
    final nameConflictsWithAlias = useState<bool>(false);

    bool hasNameAliasConflict() {
      final normalizedName = nameController.text.trim().toLowerCase();
      return aliases.value.any(
        (alias) => alias.trim().toLowerCase() == normalizedName,
      );
    }

    final service = ref.watch(
      workContentServiceProvider((path: databasePath, novelId: novelId)),
    );
    // 剧本作品没有章节，「本作首次出场」整行隐藏，也不必订阅章节列表。
    final chaptersAsync = isScreenplay
        ? null
        : ref.watch(chaptersProvider(databasePath));
    final chapters = chaptersAsync?.asData?.value ?? const <Chapter>[];

    // 文本/枚举字段防抖保存；avatar/photos/firstAppear 走即时写入，
    // 故 updateCharacterProfile 传入 avatar/photos 为 null（absent）避免覆盖。
    Future<void> persist() async {
      autoSaveTimer.value?.cancel();
      if (!dirty.value) return;
      final conflict = hasNameAliasConflict();
      nameConflictsWithAlias.value = conflict;
      if (conflict) {
        saveState.value = (false, saveState.value.$2);
        return;
      }
      saveState.value = (true, saveState.value.$2);
      try {
        await service.updateCharacterProfile(
          entryId: character.id,
          name: nameController.text.trim(),
          role: role.value,
          gender: gender.value,
          aliases: aliases.value,
          tags: tags.value,
          identity: identityController.text,
          age: ageController.text,
          motivation: motivationController.text,
          arc: arcController.text,
          biography: summaryController.text,
          appearance: appearanceController.text,
          personality: personalityController.text,
          description: descriptionController.text,
          behaviorTags: behaviorTags.value,
          currentState: currentStateController.text,
        );
        dirty.value = false;
        saveState.value = (false, DateTime.now());
      } catch (_) {
        saveState.value = (false, saveState.value.$2);
      }
    }

    void scheduleSave() {
      final hasComposingText =
          [
            nameController,
            identityController,
            ageController,
            motivationController,
            arcController,
            summaryController,
            appearanceController,
            descriptionController,
            personalityController,
            currentStateController,
          ].any((controller) {
            final composing = controller.value.composing;
            return composing.isValid && !composing.isCollapsed;
          });
      if (hasComposingText) return;
      dirty.value = true;
      autoSaveTimer.value?.cancel();
      autoSaveTimer.value = Timer(const Duration(milliseconds: 800), persist);
    }

    useEffect(() {
      void listener() => scheduleSave();
      summaryController.addListener(listener);
      appearanceController.addListener(listener);
      descriptionController.addListener(listener);
      personalityController.addListener(listener);
      currentStateController.addListener(listener);
      identityController.addListener(listener);
      ageController.addListener(listener);
      motivationController.addListener(listener);
      arcController.addListener(listener);
      return () {
        summaryController.removeListener(listener);
        appearanceController.removeListener(listener);
        descriptionController.removeListener(listener);
        personalityController.removeListener(listener);
        currentStateController.removeListener(listener);
        identityController.removeListener(listener);
        ageController.removeListener(listener);
        motivationController.removeListener(listener);
        arcController.removeListener(listener);
      };
    }, const []);

    useEffect(
      () => () {
        autoSaveTimer.value?.cancel();
        if (!dirty.value || hasNameAliasConflict()) {
          return;
        }
        service.updateCharacterProfile(
          entryId: character.id,
          name: nameController.text.trim(),
          role: role.value,
          gender: gender.value,
          aliases: aliases.value,
          tags: tags.value,
          identity: identityController.text,
          age: ageController.text,
          motivation: motivationController.text,
          arc: arcController.text,
          biography: summaryController.text,
          appearance: appearanceController.text,
          personality: personalityController.text,
          description: descriptionController.text,
          behaviorTags: behaviorTags.value,
          currentState: currentStateController.text,
        );
      },
      const [],
    );

    void reportImageFailure(Object error, StackTrace stackTrace) {
      _log.error(
        'Character image selection failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
        );
      }
    }

    Future<void> pickAvatar() async {
      if (!context.mounted || picking.value) {
        return;
      }
      picking.value = true;
      try {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
        );
        if (!context.mounted || picked == null) {
          return;
        }
        final saved = await service.saveCharacterImage(
          sourcePath: picked.path,
          kind: 'avatar',
        );
        if (!context.mounted) {
          return;
        }
        await service.updateCharacterAvatarAndPhotos(
          entryId: character.id,
          avatarAssetId: saved,
        );
      } catch (error, stackTrace) {
        reportImageFailure(error, stackTrace);
      } finally {
        if (context.mounted) {
          picking.value = false;
        }
      }
    }

    Future<void> addPhoto() async {
      if (!context.mounted || picking.value) {
        return;
      }
      picking.value = true;
      try {
        final picked = await ImagePicker().pickMultiImage();
        if (!context.mounted || picked.isEmpty) {
          return;
        }
        // 逐张导入，单张失败跳过不影响其余；全部处理完一次性落库。
        final added = <SubjectPhoto>[];
        for (final file in picked) {
          final saved = await service.saveCharacterImage(
            sourcePath: file.path,
            kind: 'photo',
          );
          if (!context.mounted) {
            return;
          }
          added.add(SubjectPhoto(assetId: saved));
        }
        if (added.isNotEmpty) {
          final current = await service.getCharacterProfileById(character.id);
          final next = [...?current?.photos, ...added];
          await service.updateCharacterAvatarAndPhotos(
            entryId: character.id,
            photos: next,
          );
        }
      } catch (error, stackTrace) {
        reportImageFailure(error, stackTrace);
      } finally {
        if (context.mounted) {
          picking.value = false;
        }
      }
    }

    Future<void> removePhoto(String assetId) async {
      final next = photos.where((p) => p.assetId != assetId).toList();
      await service.updateCharacterAvatarAndPhotos(
        entryId: character.id,
        photos: next,
      );
    }

    Future<void> setAsAvatar(String assetId) async {
      await service.updateCharacterAvatarAndPhotos(
        entryId: character.id,
        avatarAssetId: assetId,
      );
    }

    Future<void> pickFirstAppearChapter() async {
      final picked = await showMobileChapterPickerSheet(
        context,
        chapters: chapters,
        selectedChapterId: firstAppearChapterId.value,
      );
      if (picked == firstAppearChapterId.value) return;
      firstAppearChapterId.value = picked;
      await service.updateCharacterFirstAppearChapter(
        characterId: character.id,
        firstAppearChapterId: picked,
      );
    }

    final firstAppearChapter = _chapterById(
      chapters,
      firstAppearChapterId.value,
    );
    useListenable(nameController);

    final displayName = nameController.text.trim().isEmpty
        ? context.t(LocaleKeys.commonUntitled)
        : nameController.text.trim();

    // 关系条数只用于锚点栏角标。
    final relationCount =
        ref
            .watch(
              entityRelationsProvider(
                path: databasePath,
                entityType: entityTypeCharacter,
                entityId: character.id,
              ),
            )
            .value
            ?.where((relation) => relation.status == 'active')
            .length ??
        0;

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            MobileEditorAppBar(
              title: displayName,
              subtitle: _roleLabel(context, role.value),
              saving: saveState.value.$1,
              savedAt: saveState.value.$2,
              onBack: () => Navigator.of(context).maybePop(),
              undoController: undoController,
            ),
            Expanded(
              child: CustomScrollView(
                controller: scrollController,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.x4l,
                      RevericSpacing.md,
                      RevericSpacing.x4l,
                      RevericSpacing.x3l,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: _MobileCharacterHero(
                        avatarAssetId: avatarAssetId,
                        nameController: nameController,
                        undoController: undoController,
                        picking: picking.value,
                        onPick: pickAvatar,
                        onNameChanged: (_) => scheduleSave(),
                        nameError: nameConflictsWithAlias.value
                            ? context.t(
                                LocaleKeys
                                    .workspaceCharacterNameConflictsWithAlias,
                              )
                            : null,
                        badges: [
                          _roleLabel(context, role.value),
                          _genderLabel(context, gender.value),
                          if (identityController.text.trim().isNotEmpty)
                            identityController.text.trim(),
                        ],
                      ),
                    ),
                  ),
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: CharacterProfileAnchorHeaderDelegate(
                      child: CharacterProfileAnchorBar(
                        spy: spy,
                        counts: {
                          if (photos.isNotEmpty)
                            CharacterProfileSectionId.figure: photos.length,
                          if (behaviorTags.value.isNotEmpty)
                            CharacterProfileSectionId.psyche:
                                behaviorTags.value.length,
                          if (relationCount > 0)
                            CharacterProfileSectionId.relations: relationCount,
                        },
                        horizontalPadding: RevericSpacing.x4l,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.x4l,
                      0,
                      RevericSpacing.x4l,
                      RevericSpacing.x6l,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _MobileCharacterSection(
                            sectionKey: spy.keyOf(
                              CharacterProfileSectionId.identity,
                            ),
                            section: characterProfileSections[0],
                            isFirst: true,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                MobileDetailFieldList(
                                  children: [
                                    MobileDetailFieldRow(
                                      label: context.t(LocaleKeys.commonRole),
                                      child: MobileDetailSelect<String>(
                                        value: role.value,
                                        items: [
                                          for (final r in characterRoles)
                                            RevericSelectItem<String>(
                                              value: r,
                                              label: _roleLabel(context, r),
                                            ),
                                        ],
                                        onChanged: (next) {
                                          role.value = next;
                                          scheduleSave();
                                        },
                                      ),
                                    ),
                                    MobileDetailFieldRow(
                                      label: context.t(LocaleKeys.commonGender),
                                      child: MobileDetailSelect<String>(
                                        value: gender.value,
                                        items: [
                                          for (final g in characterGenders)
                                            RevericSelectItem<String>(
                                              value: g,
                                              label: _genderLabel(context, g),
                                            ),
                                        ],
                                        onChanged: (next) {
                                          gender.value = next;
                                          scheduleSave();
                                        },
                                      ),
                                    ),
                                    MobileDetailFieldRow(
                                      label: context.t(
                                        LocaleKeys.historyFieldIdentity,
                                      ),
                                      child: _CharacterFieldInput(
                                        controller: identityController,
                                        hintText: context.t(
                                          LocaleKeys
                                              .workspaceCharacterIdentityHint,
                                        ),
                                      ),
                                    ),
                                    MobileDetailFieldRow(
                                      label: context.t(
                                        LocaleKeys.historyFieldAge,
                                      ),
                                      child: _CharacterFieldInput(
                                        controller: ageController,
                                        hintText: context.t(
                                          LocaleKeys.workspaceCharacterAgeHint,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: RevericSpacing.lg),
                                _MobileCharacterIdentifiersCard(
                                  characterName: nameController.text,
                                  aliases: aliases.value,
                                  groups: tags.value,
                                  onAliasesChanged: (next) {
                                    aliases.value = next;
                                    scheduleSave();
                                  },
                                  onGroupsChanged: (next) {
                                    tags.value = next;
                                    scheduleSave();
                                  },
                                ),
                              ],
                            ),
                          ),
                          _MobileCharacterSection(
                            sectionKey: spy.keyOf(
                              CharacterProfileSectionId.figure,
                            ),
                            section: characterProfileSections[1],
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _MobileCharacterProse(
                                  controller: appearanceController,
                                  focusNode: appearanceFocusNode,
                                  undoController: undoController,
                                  hintKey: LocaleKeys
                                      .workspaceCharacterAppearanceHint,
                                ),
                                const SizedBox(height: RevericSpacing.x3l),
                                MobileCharacterImageActions(
                                  novelId: novelId,
                                  databasePath: databasePath,
                                  characterId: character.id,
                                  prepareCharacter: () async {
                                    await persist();
                                    return !dirty.value;
                                  },
                                ),
                                const SizedBox(height: RevericSpacing.lg),
                                CharacterProfileSubLabel(
                                  text: context.t(
                                    LocaleKeys.workspaceCharacterPhotosLabel,
                                  ),
                                ),
                                const SizedBox(height: RevericSpacing.md),
                                _PhotosRow(
                                  photos: photos,
                                  onAdd: addPhoto,
                                  onRemove: removePhoto,
                                  onRename: (assetId, name) async {
                                    await service.renameCharacterPhoto(
                                      id: character.id,
                                      assetId: assetId,
                                      name: name,
                                    );
                                  },
                                  onSetAvatar: setAsAvatar,
                                ),
                              ],
                            ),
                          ),
                          _MobileCharacterSection(
                            sectionKey: spy.keyOf(
                              CharacterProfileSectionId.biography,
                            ),
                            section: characterProfileSections[2],
                            child: _MobileCharacterProse(
                              controller: summaryController,
                              focusNode: summaryFocusNode,
                              undoController: undoController,
                              hintKey: LocaleKeys.workspaceCharacterSummaryHint,
                            ),
                          ),
                          _MobileCharacterSection(
                            sectionKey: spy.keyOf(
                              CharacterProfileSectionId.outward,
                            ),
                            section: characterProfileSections[3],
                            child: _MobileCharacterProse(
                              controller: descriptionController,
                              focusNode: descriptionFocusNode,
                              undoController: undoController,
                              hintKey:
                                  LocaleKeys.workspaceCharacterDescriptionHint,
                            ),
                          ),
                          _MobileCharacterSection(
                            sectionKey: spy.keyOf(
                              CharacterProfileSectionId.psyche,
                            ),
                            section: characterProfileSections[4],
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                CharacterProfileSubLabel(
                                  text: context.t(
                                    LocaleKeys.historyFieldMotivation,
                                  ),
                                ),
                                const SizedBox(height: RevericSpacing.xs),
                                _MobileCharacterProse(
                                  controller: motivationController,
                                  focusNode: motivationFocusNode,
                                  undoController: undoController,
                                  hintKey: LocaleKeys
                                      .workspaceCharacterMotivationHint,
                                  dense: true,
                                ),
                                const SizedBox(height: RevericSpacing.lg),
                                CharacterProfileSubLabel(
                                  text: context.t(LocaleKeys.historyFieldArc),
                                ),
                                const SizedBox(height: RevericSpacing.xs),
                                _MobileCharacterProse(
                                  controller: arcController,
                                  focusNode: arcFocusNode,
                                  undoController: undoController,
                                  hintKey: LocaleKeys.workspaceCharacterArcHint,
                                  dense: true,
                                ),
                                const SizedBox(height: RevericSpacing.x3l),
                                CharacterProfileSubLabel(
                                  text: context.t(
                                    LocaleKeys
                                        .workspaceCharacterPersonalityLabel,
                                  ),
                                ),
                                const SizedBox(height: RevericSpacing.xs),
                                _MobileCharacterProse(
                                  controller: personalityController,
                                  focusNode: personalityFocusNode,
                                  undoController: undoController,
                                  hintKey: LocaleKeys
                                      .workspaceCharacterPersonalityHint,
                                ),
                                const SizedBox(height: RevericSpacing.x3l),
                                _MobileCharacterBehaviorTagsEditor(
                                  tags: behaviorTags.value,
                                  onChanged: (next) {
                                    behaviorTags.value = next;
                                    scheduleSave();
                                  },
                                ),
                              ],
                            ),
                          ),
                          _MobileCharacterSection(
                            sectionKey: spy.keyOf(
                              CharacterProfileSectionId.story,
                            ),
                            section: characterProfileSections[5],
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (!isScreenplay) ...[
                                  MobileDetailFieldList(
                                    children: [
                                      MobileDetailLinkRow(
                                        label: context.t(
                                          LocaleKeys
                                              .workspaceCharacterFirstAppearChapter,
                                        ),
                                        value:
                                            firstAppearChapter?.displayTitle ??
                                            context.t(LocaleKeys.commonNone),
                                        onTap: pickFirstAppearChapter,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: RevericSpacing.lg),
                                ],
                                _MobileCharacterProse(
                                  controller: currentStateController,
                                  focusNode: currentStateFocusNode,
                                  undoController: undoController,
                                  hintKey: LocaleKeys
                                      .workspaceCharacterCurrentStateHint,
                                ),
                              ],
                            ),
                          ),
                          _MobileCharacterSection(
                            sectionKey: spy.keyOf(
                              CharacterProfileSectionId.relations,
                            ),
                            section: characterProfileSections[6],
                            child: CharacterRelationsOverview(
                              databasePath: databasePath,
                              characterId: character.id,
                              onOpenGraph: onOpenGraph,
                            ),
                          ),
                        ],
                      ),
                    ),
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

/// 别名与分组同属标识、检索维度，移动端窄屏上下排在同一张卡片里。
class _MobileCharacterIdentifiersCard extends StatelessWidget {
  const _MobileCharacterIdentifiersCard({
    required this.characterName,
    required this.aliases,
    required this.groups,
    required this.onAliasesChanged,
    required this.onGroupsChanged,
  });

  final String characterName;
  final List<String> aliases;
  final List<String> groups;
  final ValueChanged<List<String>> onAliasesChanged;
  final ValueChanged<List<String>> onGroupsChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CharacterAliasesField(
            characterName: characterName,
            aliases: aliases,
            onChanged: onAliasesChanged,
          ),
          const SizedBox(height: RevericSpacing.lg),
          CharacterGroupsField(groups: groups, onChanged: onGroupsChanged),
        ],
      ),
    );
  }
}

class _MobileCharacterBehaviorTagsEditor extends HookWidget {
  const _MobileCharacterBehaviorTagsEditor({
    required this.tags,
    required this.onChanged,
  });

  final List<CharacterBehaviorTag> tags;
  final ValueChanged<List<CharacterBehaviorTag>> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final tagController = useTextEditingController();
    final contextController = useTextEditingController();
    final errorText = useState<String?>(null);

    void addTag() {
      final tag = tagController.text.trim();
      final trigger = contextController.text.trim();
      if (tag.isEmpty || trigger.isEmpty) {
        errorText.value = context.t(
          LocaleKeys.workspaceCharacterBehaviorTagContextRequired,
        );
        return;
      }
      final candidate = CharacterBehaviorTag(tag: tag, context: trigger);
      if (tags.contains(candidate)) {
        errorText.value = context.t(
          LocaleKeys.workspaceCharacterBehaviorTagDuplicate,
        );
        return;
      }
      onChanged([...tags, candidate]);
      tagController.clear();
      contextController.clear();
      errorText.value = null;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.t(LocaleKeys.workspaceCharacterBehaviorTagsLabel),
            style: typo.uiSemibold.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: RevericSpacing.xs),
          Text(
            context.t(LocaleKeys.workspaceCharacterBehaviorTagsHint),
            style: typo.bodySmall.copyWith(color: colors.textMuted),
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: RevericSpacing.md),
            for (var index = 0; index < tags.length; index++) ...[
              _MobileCharacterBehaviorTagCard(
                key: ValueKey('${tags[index].tag}:${tags[index].context}'),
                index: index,
                value: tags[index],
                isDuplicate: (candidate) {
                  for (var i = 0; i < tags.length; i++) {
                    if (i != index && tags[i] == candidate) {
                      return true;
                    }
                  }
                  return false;
                },
                onChanged: (value) {
                  final next = [...tags];
                  next[index] = value;
                  onChanged(next);
                },
                onRemove: () {
                  final next = [...tags]..removeAt(index);
                  onChanged(next);
                },
              ),
              if (index != tags.length - 1)
                const SizedBox(height: RevericSpacing.sm),
            ],
          ],
          const SizedBox(height: RevericSpacing.md),
          RevericTextField(
            fieldKey: const ValueKey('mobile-character-behavior-tag-field'),
            controller: tagController,
            textInputAction: TextInputAction.next,
            hintText: context.t(
              LocaleKeys.workspaceCharacterBehaviorTagNameHint,
            ),
          ),
          const SizedBox(height: RevericSpacing.sm),
          RevericTextField(
            fieldKey: const ValueKey('mobile-character-behavior-context-field'),
            controller: contextController,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => addTag(),
            hintText: context.t(
              LocaleKeys.workspaceCharacterBehaviorTagContextHint,
            ),
            errorText: errorText.value,
            suffixIconConstraints: const BoxConstraints(minWidth: 36),
            suffixIcon: IconButton(
              key: const ValueKey('mobile-character-behavior-add-button'),
              tooltip: context.t(LocaleKeys.workspaceCharacterBehaviorTagAdd),
              onPressed: addTag,
              icon: RevericIcon(
                RevericIcons.add,
                size: 18,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileCharacterBehaviorTagCard extends HookWidget {
  const _MobileCharacterBehaviorTagCard({
    super.key,
    required this.index,
    required this.value,
    required this.isDuplicate,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final CharacterBehaviorTag value;
  final bool Function(CharacterBehaviorTag candidate) isDuplicate;
  final ValueChanged<CharacterBehaviorTag> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final tagController = useTextEditingController(text: value.tag);
    final contextController = useTextEditingController(text: value.context);
    final rowFocus = useFocusNode();
    final tagFocus = useFocusNode();
    final contextFocus = useFocusNode();
    final errorText = useState<String?>(null);
    final commitRef = useRef<VoidCallback>(() {});

    void commit() {
      final tag = tagController.text.trim();
      final trigger = contextController.text.trim();
      if (tag.isEmpty || trigger.isEmpty) {
        errorText.value = context.t(
          LocaleKeys.workspaceCharacterBehaviorTagContextRequired,
        );
        return;
      }
      final next = CharacterBehaviorTag(tag: tag, context: trigger);
      if (next == value) {
        errorText.value = null;
        return;
      }
      if (isDuplicate(next)) {
        errorText.value = context.t(
          LocaleKeys.workspaceCharacterBehaviorTagDuplicate,
        );
        return;
      }
      errorText.value = null;
      onChanged(next);
    }

    // 失焦监听器只注册一次，提交逻辑通过 ref 始终读取最新的父级闭包。
    commitRef.value = commit;

    return Focus(
      focusNode: rowFocus,
      onFocusChange: (hasFocus) {
        if (!hasFocus) commitRef.value();
      },
      child: Container(
        padding: const EdgeInsets.all(RevericSpacing.md),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          border: Border.all(color: colors.borderSubtle),
        ),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: RevericTextField(
                    fieldKey: ValueKey(
                      'mobile-character-behavior-row-tag:$index',
                    ),
                    controller: tagController,
                    focusNode: tagFocus,
                    textInputAction: TextInputAction.next,
                    hintText: context.t(
                      LocaleKeys.workspaceCharacterBehaviorTagNameHint,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: context.t(
                    LocaleKeys.workspaceCharacterBehaviorTagRemove,
                  ),
                  onPressed: onRemove,
                  icon: RevericIcon(
                    RevericIcons.close,
                    size: 18,
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: RevericSpacing.sm),
            RevericTextField(
              fieldKey: ValueKey(
                'mobile-character-behavior-row-context:$index',
              ),
              controller: contextController,
              focusNode: contextFocus,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => commit(),
              hintText: context.t(
                LocaleKeys.workspaceCharacterBehaviorTagContextHint,
              ),
              errorText: errorText.value,
            ),
          ],
        ),
      ),
    );
  }
}

/// 角色 meta 行的右对齐单行输入（身份/年龄/动机/弧光），无边框贴合 `.srow` 值样式。
class _CharacterFieldInput extends StatelessWidget {
  const _CharacterFieldInput({
    required this.controller,
    required this.hintText,
  });

  final TextEditingController controller;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return TextField(
      controller: controller,
      textAlign: TextAlign.right,
      style: typo.ui.copyWith(color: colors.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintText: hintText,
        hintStyle: typo.ui.copyWith(color: colors.textSubtle),
      ),
    );
  }
}

Chapter? _chapterById(List<Chapter> chapters, String? id) {
  if (id == null) return null;
  for (final c in chapters) {
    if (c.id == id) return c;
  }
  return null;
}

/// 角色详情紧凑顶栏：左侧可点头像 + 右对齐名称输入（AppBar 已展示角色定位，不再重复 hero 文案）。
class _PhotosRow extends StatelessWidget {
  const _PhotosRow({
    required this.photos,
    required this.onAdd,
    required this.onRemove,
    required this.onRename,
    required this.onSetAvatar,
  });

  final List<SubjectPhoto> photos;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;
  final Future<void> Function(String path, String name) onRename;
  final ValueChanged<String> onSetAvatar;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    if (photos.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          key: const ValueKey('character-photo-picker'),
          onTap: onAdd,
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.lg,
              vertical: RevericSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(RevericRadius.pill),
              border: Border.all(color: colors.borderSubtle),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RevericIcon(
                  RevericIcons.add,
                  size: 16,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: RevericSpacing.xs),
                Text(
                  context.t(LocaleKeys.workspaceCharacterPickPhoto),
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 80 + RevericSizes.touchTargetSize,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: photos.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: RevericSpacing.sm),
        itemBuilder: (context, index) {
          if (index == photos.length) {
            return _AddPhotoTile(onTap: onAdd);
          }
          final assetId = photos[index].assetId;
          return SizedBox(
            width: 80,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PhotoTile(
                  assetId: assetId,
                  onRemove: () => onRemove(assetId),
                  onSetAvatar: () => onSetAvatar(assetId),
                ),
                SubjectPhotoName(
                  photo: photos[index],
                  onRename: (name) => onRename(assetId, name),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AddPhotoTile extends StatelessWidget {
  const _AddPhotoTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(RevericRadius.large),
          border: Border.all(color: colors.borderSubtle),
        ),
        child: Center(
          child: RevericIcon(
            RevericIcons.add,
            size: 22,
            color: colors.textMuted,
          ),
        ),
      ),
    );
  }
}

class _PhotoTile extends ConsumerWidget {
  const _PhotoTile({
    required this.assetId,
    required this.onRemove,
    required this.onSetAvatar,
  });

  final String assetId;
  final VoidCallback onRemove;
  final VoidCallback onSetAvatar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final resolved = watchMediaAssetFile(ref, assetId);
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(RevericRadius.large),
          child: SizedBox(
            width: 80,
            height: 80,
            child: resolved != null
                ? Image.file(File(resolved), fit: BoxFit.cover)
                : Container(color: colors.surfaceContainer),
          ),
        ),
        Positioned(
          right: 2,
          top: 2,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(RevericSpacing.xxs),
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: 0.9),
                shape: BoxShape.circle,
              ),
              child: RevericIcon(
                RevericIcons.close,
                size: 14,
                color: colors.error,
              ),
            ),
          ),
        ),
        Positioned(
          left: 2,
          bottom: 2,
          child: GestureDetector(
            onTap: onSetAvatar,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.xs,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(RevericRadius.pill),
              ),
              child: Text(
                context.t(LocaleKeys.workspaceCharacterSetAsAvatar),
                style: RevericTheme.typographyOf(
                  context,
                ).uiTiny.copyWith(color: colors.accent),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _roleLabel(BuildContext context, String role) {
  return switch (role) {
    characterRoleProtagonist => context.t(LocaleKeys.characterRoleProtagonist),
    characterRoleAntagonist => context.t(LocaleKeys.characterRoleAntagonist),
    characterRoleSupporting => context.t(LocaleKeys.characterRoleSupporting),
    characterRoleMinor => context.t(LocaleKeys.characterRoleMinor),
    _ => context.t(LocaleKeys.characterRoleSupporting),
  };
}

String _genderLabel(BuildContext context, String gender) {
  return switch (gender) {
    characterGenderMale => context.t(LocaleKeys.characterGenderMale),
    characterGenderFemale => context.t(LocaleKeys.characterGenderFemale),
    characterGenderNonBinary => context.t(LocaleKeys.characterGenderNonBinary),
    characterGenderOther => context.t(LocaleKeys.characterGenderOther),
    characterGenderUnknown => context.t(LocaleKeys.characterGenderUnknown),
    _ => context.t(LocaleKeys.characterGenderUnknown),
  };
}

/// 移动端 Hero：头像 + 名字 + 定位/性别/身份徽章。
class _MobileCharacterHero extends StatelessWidget {
  const _MobileCharacterHero({
    required this.avatarAssetId,
    required this.nameController,
    required this.undoController,
    required this.picking,
    required this.onPick,
    required this.onNameChanged,
    required this.nameError,
    required this.badges,
  });

  final String? avatarAssetId;
  final TextEditingController nameController;
  final UndoHistoryController undoController;
  final bool picking;
  final VoidCallback onPick;
  final ValueChanged<String> onNameChanged;
  final String? nameError;
  final List<String> badges;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      children: [
        GestureDetector(
          key: const ValueKey('character-avatar-picker'),
          onTap: picking ? null : onPick,
          child: SizedBox(
            width: 96,
            height: 92,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CharacterAvatar(
                  avatarAssetId: avatarAssetId,
                  fallbackName: nameController.text,
                  size: 88,
                  backgroundColor: colors.accent.withValues(alpha: 0.2),
                  textColor: colors.accent,
                ),
                if (picking)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                // 头像是正圆，按钮贴 45° 切点才不会像被咬了一口。
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colors.surface,
                      border: Border.all(color: colors.canvas, width: 2),
                    ),
                    child: Center(
                      child: RevericIcon(
                        RevericIcons.image_outlined,
                        size: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: RevericSpacing.sm),
        MobileDetailTitleField(
          controller: nameController,
          undoController: undoController,
          hintText: context.t(LocaleKeys.workspaceCharacterNameHint),
          onChanged: onNameChanged,
        ),
        if (nameError != null) ...[
          const SizedBox(height: RevericSpacing.xs),
          Text(
            nameError!,
            style: typo.uiSmall.copyWith(color: colors.warningText),
          ),
        ],
        const SizedBox(height: RevericSpacing.sm),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: RevericSpacing.xs,
          runSpacing: RevericSpacing.xs,
          children: [
            for (var index = 0; index < badges.length; index++)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.md,
                  vertical: RevericSpacing.xxs,
                ),
                decoration: BoxDecoration(
                  color: index == 0 ? colors.accent : colors.selected,
                  borderRadius: BorderRadius.circular(RevericRadius.pill),
                ),
                child: Text(
                  badges[index],
                  style: typo.uiSmallSemibold.copyWith(
                    color: index == 0 ? colors.onAccent : colors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 分组外壳：挂 scroll spy 的锚点、画分隔线、统一标题与间距。
class _MobileCharacterSection extends StatelessWidget {
  const _MobileCharacterSection({
    required this.sectionKey,
    required this.section,
    required this.child,
    this.isFirst = false,
  });

  final GlobalKey sectionKey;
  final CharacterProfileSection section;
  final Widget child;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      key: sectionKey,
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.x3l),
      decoration: isFirst
          ? null
          : BoxDecoration(
              border: Border(top: BorderSide(color: colors.borderSubtle)),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CharacterProfileSectionHeader(section: section),
          const SizedBox(height: RevericSpacing.lg),
          child,
        ],
      ),
    );
  }
}

/// 平铺在分组里的长文编辑器：随内容自增高，滚动交给页面。
class _MobileCharacterProse extends StatelessWidget {
  const _MobileCharacterProse({
    required this.controller,
    required this.focusNode,
    required this.undoController,
    required this.hintKey,
    this.dense = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final UndoHistoryController undoController;
  final String hintKey;

  /// 动机 / 弧光这类「比一行长、比一段短」的字段用更矮的底高。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return RevericMarkdownEditor(
      controller: controller,
      focusNode: focusNode,
      undoController: undoController,
      hintText: context.t(hintKey),
      autoHeight: true,
      showToolbar: false,
      minHeight: dense ? 72 : 132,
    );
  }
}

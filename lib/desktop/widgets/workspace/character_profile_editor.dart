// 职责: 桌面人物资料编辑器，把完整人物字段平铺成七个分组的连续滚动页，并与吸顶锚点栏联动。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/desktop/widgets/workspace/character_profile_editor_region.dart
//   lib/desktop/widgets/workspace/chapter_list_dropdown.dart
//   lib/shared/widgets/character/character_profile_section.dart
//   lib/shared/widgets/character/character_relations_overview.dart
//   lib/shared/models/character_profile.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/widgets/character_avatar.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
//   assets/translations/en/relation.json
//   assets/translations/zh-CN/relation.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_select.dart';
import '../../../shared/components/horizontal_wheel_scroll.dart';
import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/entity_graph/labels.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/services/ai/chat.dart';
import '../../../shared/models/content_kind.dart';
import '../../../shared/models/cover_style.dart';
import '../../../shared/models/character_profile.dart';
import '../../../shared/services/name_generator_service.dart';
import '../../../shared/services/character_image_prompt_builder.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/character/character_profile_section.dart';
import '../../../shared/widgets/character/character_relations_overview.dart';
import '../../../shared/widgets/character/character_tag_fields.dart';
import '../../../shared/widgets/character_avatar.dart';
import '../../../shared/widgets/subject_photo_name.dart';
import '../../../shared/widgets/md/reveric_markdown_editor.dart';
import '../../../shared/widgets/name_assistant_button.dart';
import '../../../third/form/flutter_hook_form.dart';
import '../agent_management/agent_model_settings_page.dart';
import 'chapter_list_dropdown.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/widgets/media_asset_image.dart';

const _imageStyles = [
  (
    style: CoverStyle.cinematic,
    label: LocaleKeys.editorCoverStyleCinematic,
    icon: RevericIcons.movie_outlined,
  ),
  (
    style: CoverStyle.illustration,
    label: LocaleKeys.editorCoverStyleIllustration,
    icon: RevericIcons.brush_outlined,
  ),
  (
    style: CoverStyle.eastern,
    label: LocaleKeys.editorCoverStyleEastern,
    icon: RevericIcons.temple_buddhist_outlined,
  ),
  (
    style: CoverStyle.minimal,
    label: LocaleKeys.editorCoverStyleMinimal,
    icon: RevericIcons.crop_square_rounded,
  ),
];

Future<String?> _showCharacterImageStyleDialog({
  required BuildContext context,
  required String title,
  required String confirmLabel,
}) {
  final extraController = TextEditingController();
  final customStyleController = TextEditingController();
  CoverStyle? selectedStyle;
  String? selectedLabel;
  var isCustom = false;
  return showRevericDialog<String>(
    context: context,
    builder: (context) {
      final colors = RevericTheme.colorsOf(context);
      final typo = RevericTheme.typographyOf(context);
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final canConfirm =
              selectedStyle != null ||
              (isCustom && customStyleController.text.trim().isNotEmpty);
          return RevericDialog(
            title: title,
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.t(LocaleKeys.editorCoverStyle),
                    style: typo.uiSemibold.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: RevericSpacing.md),
                  Wrap(
                    spacing: RevericSpacing.md,
                    runSpacing: RevericSpacing.md,
                    children: [
                      ..._imageStyles.map((option) {
                        final isSelected = selectedStyle == option.style;
                        return GestureDetector(
                          onTap: () {
                            setDialogState(() {
                              selectedStyle = option.style;
                              selectedLabel = context.t(option.label);
                              isCustom = false;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(
                              horizontal: RevericSpacing.lg,
                              vertical: RevericSpacing.md,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? colors.accent.withValues(alpha: 0.1)
                                  : colors.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(
                                RevericRadius.large,
                              ),
                              border: Border.all(
                                color: isSelected
                                    ? colors.accent
                                    : colors.border,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                RevericIcon(
                                  option.icon,
                                  size: 16,
                                  color: isSelected
                                      ? colors.accent
                                      : colors.textSecondary,
                                ),
                                const SizedBox(width: RevericSpacing.sm),
                                Text(
                                  context.t(option.label),
                                  style: typo.uiSemibold.copyWith(
                                    color: isSelected
                                        ? colors.accent
                                        : colors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                      GestureDetector(
                        onTap: () {
                          setDialogState(() {
                            isCustom = true;
                            selectedStyle = null;
                            selectedLabel = null;
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(
                            horizontal: RevericSpacing.lg,
                            vertical: RevericSpacing.md,
                          ),
                          decoration: BoxDecoration(
                            color: isCustom
                                ? colors.accent.withValues(alpha: 0.1)
                                : colors.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(
                              RevericRadius.large,
                            ),
                            border: Border.all(
                              color: isCustom ? colors.accent : colors.border,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              RevericIcon(
                                RevericIcons.edit_outlined,
                                size: 16,
                                color: isCustom
                                    ? colors.accent
                                    : colors.textSecondary,
                              ),
                              const SizedBox(width: RevericSpacing.sm),
                              Text(
                                context.t(LocaleKeys.agentRoleCustom),
                                style: typo.uiSemibold.copyWith(
                                  color: isCustom
                                      ? colors.accent
                                      : colors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isCustom) ...[
                    const SizedBox(height: RevericSpacing.lg),
                    RevericTextField(
                      controller: customStyleController,
                      onChanged: (_) => setDialogState(() {}),
                      hintText: context.t(
                        LocaleKeys.editorCoverStyleCustomHint,
                      ),
                      multiline: true,
                      minLines: 1,
                      maxLines: 2,
                    ),
                  ],
                  const SizedBox(height: RevericSpacing.xl),
                  Text(
                    context.t(LocaleKeys.editorCoverExtraRequirements),
                    style: typo.uiSemibold.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: RevericSpacing.md),
                  RevericTextField(
                    controller: extraController,
                    hintText: context.t(LocaleKeys.editorCoverExtraHint),
                    multiline: true,
                    minLines: 2,
                    maxLines: 4,
                  ),
                ],
              ),
            ),
            width: 400,
            actions: [
              RevericButton.secondary(
                label: context.t(LocaleKeys.commonCancel),
                onPressed: () {
                  extraController.dispose();
                  customStyleController.dispose();
                  Navigator.of(context).pop();
                },
              ),
              RevericButton.primary(
                label: confirmLabel,
                onPressed: canConfirm
                    ? () {
                        final extra = extraController.text.trim();
                        extraController.dispose();
                        final styleText = isCustom
                            ? customStyleController.text.trim()
                            : (selectedLabel ?? '');
                        customStyleController.dispose();
                        Navigator.of(context).pop(
                          extra.isEmpty ? styleText : '$styleText\n\n$extra',
                        );
                      }
                    : null,
              ),
            ],
          );
        },
      );
    },
  );
}

class CharacterProfileEditorTarget {
  const CharacterProfileEditorTarget({
    required this.selectedItemId,
    required this.isCreating,
    required this.characterProfiles,
  });

  final String? selectedItemId;
  final bool isCreating;
  final List<CharacterProfile> characterProfiles;
}

class CharacterProfileFormSession {
  const CharacterProfileFormSession({
    required this.form,
    required this._controllers,
    required this._focusNodes,
    required this.aliases,
    required this.tags,
    required this.behaviorTags,
    required this._onAliasesChanged,
    required this._onTagsChanged,
    required this._onBehaviorTagsChanged,
  });

  final FormFieldsController<CharacterProfileEditFields> form;
  final Map<CharacterProfileEditFields, TextEditingController> _controllers;
  final Map<CharacterProfileEditFields, FocusNode> _focusNodes;
  final List<String> aliases;
  final List<String> tags;
  final List<CharacterBehaviorTag> behaviorTags;
  final ValueChanged<List<String>> _onAliasesChanged;
  final ValueChanged<List<String>> _onTagsChanged;
  final ValueChanged<List<CharacterBehaviorTag>> _onBehaviorTagsChanged;

  TextEditingController controller(CharacterProfileEditFields field) {
    return _controllers[field]!;
  }

  FocusNode focusNode(CharacterProfileEditFields field) {
    return _focusNodes[field]!;
  }

  void updateAliases(List<String> value) => _onAliasesChanged(value);

  void updateTags(List<String> value) => _onTagsChanged(value);

  void updateBehaviorTags(List<CharacterBehaviorTag> value) {
    _onBehaviorTagsChanged(value);
  }
}

class CharacterProfileMediaSession {
  const CharacterProfileMediaSession({
    required this.avatarAssetId,
    required this.photos,
    required this.avatarPicking,
    required this.photoAdding,
    required this.isImageGenerationConfigured,
    required this.onPickAvatar,
    required this.onAddPhoto,
    required this.onRemovePhoto,
    required this.onRenamePhoto,
    required this.onRemoveAvatar,
    required this.onGenerateAvatar,
    required this.onGeneratePhoto,
  });

  final String? avatarAssetId;
  final List<SubjectPhoto> photos;
  final bool avatarPicking;
  final bool photoAdding;
  final bool isImageGenerationConfigured;
  final Future<void> Function() onPickAvatar;
  final Future<void> Function() onAddPhoto;
  final Future<void> Function(String path) onRemovePhoto;
  final Future<void> Function(String path, String name) onRenamePhoto;
  final Future<void> Function() onRemoveAvatar;
  final Future<void> Function(String prompt, String characterId)
  onGenerateAvatar;
  final Future<void> Function(String prompt, String characterId)
  onGeneratePhoto;
}

/// 人物编辑器的一次局部编辑会话。
///
/// 上层 region 只传入目标、表单资源、媒体资源和创建动作四个语义对象；纯 UI
/// 不再接触 Page，也不接收 30 多个标量构造参数。
class CharacterProfileEditorSession {
  const CharacterProfileEditorSession({
    required this.target,
    required this.fields,
    required this.media,
    required this.onCreateCharacter,
  });

  final CharacterProfileEditorTarget target;
  final CharacterProfileFormSession fields;
  final CharacterProfileMediaSession media;
  final VoidCallback onCreateCharacter;

  FormFieldsController<CharacterProfileEditFields> get form => fields.form;
  String? get selectedItemId => target.selectedItemId;
  bool get isCreating => target.isCreating;
  List<CharacterProfile> get characterProfiles => target.characterProfiles;
  TextEditingController get nameController =>
      fields.controller(CharacterProfileEditFields.name);
  TextEditingController get roleController =>
      fields.controller(CharacterProfileEditFields.role);
  TextEditingController get genderController =>
      fields.controller(CharacterProfileEditFields.gender);
  TextEditingController get identityController =>
      fields.controller(CharacterProfileEditFields.identity);
  TextEditingController get ageController =>
      fields.controller(CharacterProfileEditFields.age);
  TextEditingController get motivationController =>
      fields.controller(CharacterProfileEditFields.motivation);
  TextEditingController get arcController =>
      fields.controller(CharacterProfileEditFields.arc);
  TextEditingController get summaryController =>
      fields.controller(CharacterProfileEditFields.biography);
  TextEditingController get appearanceController =>
      fields.controller(CharacterProfileEditFields.appearance);
  TextEditingController get descriptionController =>
      fields.controller(CharacterProfileEditFields.description);
  TextEditingController get personalityController =>
      fields.controller(CharacterProfileEditFields.personality);
  TextEditingController get currentStateController =>
      fields.controller(CharacterProfileEditFields.currentState);
  List<String> get aliases => fields.aliases;
  List<String> get tags => fields.tags;
  List<CharacterBehaviorTag> get behaviorTags => fields.behaviorTags;
  ValueChanged<List<String>> get onAliasesChanged => fields.updateAliases;
  ValueChanged<List<String>> get onTagsChanged => fields.updateTags;
  ValueChanged<List<CharacterBehaviorTag>> get onBehaviorTagsChanged =>
      fields.updateBehaviorTags;
  FocusNode get nameFocusNode =>
      fields.focusNode(CharacterProfileEditFields.name);
  FocusNode get identityFocusNode =>
      fields.focusNode(CharacterProfileEditFields.identity);
  FocusNode get ageFocusNode =>
      fields.focusNode(CharacterProfileEditFields.age);
  FocusNode get motivationFocusNode =>
      fields.focusNode(CharacterProfileEditFields.motivation);
  FocusNode get arcFocusNode =>
      fields.focusNode(CharacterProfileEditFields.arc);
  FocusNode get summaryFocusNode =>
      fields.focusNode(CharacterProfileEditFields.biography);
  FocusNode get appearanceFocusNode =>
      fields.focusNode(CharacterProfileEditFields.appearance);
  FocusNode get descriptionFocusNode =>
      fields.focusNode(CharacterProfileEditFields.description);
  FocusNode get personalityFocusNode =>
      fields.focusNode(CharacterProfileEditFields.personality);
  FocusNode get currentStateFocusNode =>
      fields.focusNode(CharacterProfileEditFields.currentState);
  Future<void> Function() get onPickAvatar => media.onPickAvatar;
  Future<void> Function() get onAddPhoto => media.onAddPhoto;
  Future<void> Function(String path) get onRemovePhoto => media.onRemovePhoto;
  Future<void> Function(String path, String name) get onRenamePhoto =>
      media.onRenamePhoto;
  Future<void> Function() get onRemoveAvatar => media.onRemoveAvatar;
  Future<void> Function(String prompt, String characterId)
  get onGenerateAvatar => media.onGenerateAvatar;
  Future<void> Function(String prompt, String characterId)
  get onGeneratePhoto => media.onGeneratePhoto;
  String? get avatarAssetId => media.avatarAssetId;
  List<SubjectPhoto> get photos => media.photos;
  bool get avatarPicking => media.avatarPicking;
  bool get photoAdding => media.photoAdding;
  bool get isImageGenerationConfigured => media.isImageGenerationConfigured;
}

class CharacterProfileEditor extends HookConsumerWidget {
  const CharacterProfileEditor({
    super.key,
    required this.session,
    this.editorFontFamily = 'Georgia',
    this.editorFontSize = 16,
    this.nameAssistantAiService,
    this.novel,
    this.databasePath,
    this.onNavigateToChapter,
    this.onOpenEntityGraph,
  });

  final CharacterProfileEditorSession session;
  final String editorFontFamily;
  final int editorFontSize;
  final AiClient? nameAssistantAiService;
  final Novel? novel;
  final String? databasePath;
  final ValueChanged<String>? onNavigateToChapter;

  /// 关系网络分组的「在关系图中查看」入口；为空时隐藏。
  final VoidCallback? onOpenEntityGraph;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedItemId = session.selectedItemId;
    final isCreating = session.isCreating;
    final characterProfiles = session.characterProfiles;
    final currentDatabasePath = databasePath;
    final pageScrollController = useScrollController();
    final spy = useMemoized(
      () => CharacterProfileScrollSpy(
        scrollController: pageScrollController,
        stickyExtent: characterProfileAnchorBarHeight,
      ),
      [pageScrollController],
    );
    useEffect(() {
      spy.attach();
      return spy.dispose;
    }, [spy]);

    if (selectedItemId == null && !isCreating) {
      return _EmptyCharacterEditorState(
        hasCharacters: characterProfiles.isNotEmpty,
        onCreate: session.onCreateCharacter,
      );
    }

    // 剧本作品没有章节，「本作首次出场」整块隐藏，也不必订阅章节列表。
    final isScreenplay = novel?.contentKind == contentKindScreenplay;

    // Watch chapters for the chapter selector
    final chaptersAsync = currentDatabasePath != null && !isScreenplay
        ? ref.watch(chaptersProvider(currentDatabasePath))
        : null;
    final chapters = chaptersAsync?.value ?? const [];

    // Get selected character
    final selectedCharacter = characterProfiles
        .where((c) => c.id == selectedItemId)
        .firstOrNull;

    // 关系条数只用于锚点栏角标；新建态还没有实体 id，直接记 0。
    final relationCount =
        (selectedItemId != null && currentDatabasePath != null)
        ? (ref
                  .watch(
                    entityRelationsProvider(
                      path: currentDatabasePath,
                      entityType: entityTypeCharacter,
                      entityId: selectedItemId,
                    ),
                  )
                  .value
                  ?.where((relation) => relation.status == 'active')
                  .length ??
              0)
        : 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = constraints.maxWidth < 760
            ? RevericSpacing.x4l
            : RevericSpacing.x6l;
        final prose = _ProseStyle(
          fontFamily: editorFontFamily,
          fontSize: editorFontSize,
        );
        final counts = <CharacterProfileSectionId, int>{
          if (session.photos.isNotEmpty)
            CharacterProfileSectionId.figure: session.photos.length,
          if (session.behaviorTags.isNotEmpty)
            CharacterProfileSectionId.psyche: session.behaviorTags.length,
          if (relationCount > 0)
            CharacterProfileSectionId.relations: relationCount,
        };
        return Scrollbar(
          controller: pageScrollController,
          thumbVisibility: true,
          child: CustomScrollView(
            controller: pageScrollController,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  RevericSpacing.x4l,
                  horizontalPadding,
                  RevericSpacing.x3l,
                ),
                sliver: SliverToBoxAdapter(
                  child: _CharacterHeroBand(
                    session: session,
                    novel: novel,
                    nameAssistantAiService: nameAssistantAiService,
                  ),
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: CharacterProfileAnchorHeaderDelegate(
                  child: CharacterProfileAnchorBar(
                    spy: spy,
                    counts: counts,
                    horizontalPadding: horizontalPadding,
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  0,
                  horizontalPadding,
                  RevericSpacing.x6l,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _CharacterSectionShell(
                        sectionKey: spy.keyOf(
                          CharacterProfileSectionId.identity,
                        ),
                        section: characterProfileSections[0],
                        isFirst: true,
                        child: _IdentitySection(session: session),
                      ),
                      _CharacterSectionShell(
                        sectionKey: spy.keyOf(CharacterProfileSectionId.figure),
                        section: characterProfileSections[1],
                        child: _FigureSection(
                          session: session,
                          prose: prose,
                          onGenerateAvatar: isCreating
                              ? null
                              : _handleGenerateAvatar,
                          onGeneratePhoto: isCreating
                              ? null
                              : _handleGeneratePhoto,
                        ),
                      ),
                      _CharacterSectionShell(
                        sectionKey: spy.keyOf(
                          CharacterProfileSectionId.biography,
                        ),
                        section: characterProfileSections[2],
                        child: _BiographySection(
                          session: session,
                          prose: prose,
                        ),
                      ),
                      _CharacterSectionShell(
                        sectionKey: spy.keyOf(
                          CharacterProfileSectionId.outward,
                        ),
                        section: characterProfileSections[3],
                        child: _OutwardSection(session: session, prose: prose),
                      ),
                      _CharacterSectionShell(
                        sectionKey: spy.keyOf(CharacterProfileSectionId.psyche),
                        section: characterProfileSections[4],
                        child: _PsycheSection(session: session, prose: prose),
                      ),
                      _CharacterSectionShell(
                        sectionKey: spy.keyOf(CharacterProfileSectionId.story),
                        section: characterProfileSections[5],
                        child: _StorySection(
                          session: session,
                          prose: prose,
                          chapterLink:
                              !isScreenplay &&
                                  selectedItemId != null &&
                                  currentDatabasePath != null
                              ? _CharacterChapterLink(
                                  databasePath: currentDatabasePath,
                                  characterId: selectedItemId,
                                  firstAppearChapterId:
                                      selectedCharacter?.firstAppearChapterId,
                                  chapters: chapters,
                                  onNavigateToChapter: onNavigateToChapter,
                                )
                              : null,
                        ),
                      ),
                      _CharacterSectionShell(
                        sectionKey: spy.keyOf(
                          CharacterProfileSectionId.relations,
                        ),
                        section: characterProfileSections[6],
                        child:
                            selectedItemId != null &&
                                currentDatabasePath != null
                            ? CharacterRelationsOverview(
                                databasePath: currentDatabasePath,
                                characterId: selectedItemId,
                                onOpenGraph: onOpenEntityGraph,
                              )
                            : const _RelationsUnavailable(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _handleGenerateAvatar(BuildContext context) {
    if (!session.isImageGenerationConfigured) {
      showAgentModelSettingsDialog(context);
      return;
    }
    _showCharacterImageStyleDialog(
      context: context,
      title: context.t(LocaleKeys.workspaceCharacterGenerateAvatar),
      confirmLabel: context.t(LocaleKeys.toolNameGenerateAvatar),
    ).then((stylePrompt) {
      if (stylePrompt == null ||
          stylePrompt.isEmpty ||
          session.selectedItemId == null) {
        return;
      }
      final prompt = buildCharacterAvatarPrompt(
        name: session.nameController.text,
        stylePrompt: stylePrompt,
      );
      session.onGenerateAvatar(prompt, session.selectedItemId!);
    });
  }

  void _handleGeneratePhoto(BuildContext context) {
    if (!session.isImageGenerationConfigured) {
      showAgentModelSettingsDialog(context);
      return;
    }
    _showCharacterImageStyleDialog(
      context: context,
      title: context.t(LocaleKeys.workspaceCharacterGeneratePhoto),
      confirmLabel: context.t(LocaleKeys.toolNameGeneratePhoto),
    ).then((stylePrompt) {
      if (stylePrompt == null ||
          stylePrompt.isEmpty ||
          session.selectedItemId == null) {
        return;
      }
      final prompt = buildCharacterPhotoPrompt(
        name: session.nameController.text,
        stylePrompt: stylePrompt,
        avatarAssetId: session.avatarAssetId,
      );
      session.onGeneratePhoto(prompt, session.selectedItemId!);
    });
  }
}

/// 别名与分组同属标识、检索维度，合成一张卡片：宽屏并排一行，窄屏回落成上下两段。
class _CharacterIdentifiersCard extends StatelessWidget {
  const _CharacterIdentifiersCard({required this.session});

  final CharacterProfileEditorSession session;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final aliases = CharacterAliasesField(
      characterName: session.nameController.text,
      aliases: session.aliases,
      onChanged: session.onAliasesChanged,
    );
    final groups = CharacterGroupsField(
      groups: session.tags,
      onChanged: session.onTagsChanged,
    );

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                aliases,
                const SizedBox(height: RevericSpacing.lg),
                groups,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: aliases),
              const SizedBox(width: RevericSpacing.lg),
              Expanded(child: groups),
            ],
          );
        },
      ),
    );
  }
}

class _CharacterBehaviorTagsEditor extends HookWidget {
  const _CharacterBehaviorTagsEditor({
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
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
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
            const SizedBox(height: RevericSpacing.lg),
            for (var index = 0; index < tags.length; index++) ...[
              _CharacterBehaviorTagRow(
                key: ValueKey('${tags[index].tag}:${tags[index].context}'),
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
          const SizedBox(height: RevericSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: RevericTextField(
                  fieldKey: const Key('character-behavior-tag-field'),
                  controller: tagController,
                  textInputAction: TextInputAction.next,
                  hintText: context.t(
                    LocaleKeys.workspaceCharacterBehaviorTagNameHint,
                  ),
                ),
              ),
              const SizedBox(width: RevericSpacing.md),
              Expanded(
                flex: 2,
                child: RevericTextField(
                  fieldKey: const Key('character-behavior-context-field'),
                  controller: contextController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => addTag(),
                  hintText: context.t(
                    LocaleKeys.workspaceCharacterBehaviorTagContextHint,
                  ),
                  errorText: errorText.value,
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              IconButton(
                tooltip: context.t(LocaleKeys.workspaceCharacterBehaviorTagAdd),
                onPressed: addTag,
                icon: RevericIcon(
                  RevericIcons.add,
                  size: 18,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CharacterBehaviorTagRow extends HookWidget {
  const _CharacterBehaviorTagRow({
    super.key,
    required this.value,
    required this.isDuplicate,
    required this.onChanged,
    required this.onRemove,
  });

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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: RevericTextField(
              controller: tagController,
              focusNode: tagFocus,
              textInputAction: TextInputAction.next,
              hintText: context.t(
                LocaleKeys.workspaceCharacterBehaviorTagNameHint,
              ),
            ),
          ),
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            flex: 2,
            child: RevericTextField(
              controller: contextController,
              focusNode: contextFocus,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => commit(),
              hintText: context.t(
                LocaleKeys.workspaceCharacterBehaviorTagContextHint,
              ),
              errorText: errorText.value,
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          IconButton(
            tooltip: context.t(LocaleKeys.workspaceCharacterBehaviorTagRemove),
            onPressed: onRemove,
            icon: RevericIcon(
              RevericIcons.close,
              size: 18,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _CharacterImageBand extends StatelessWidget {
  const _CharacterImageBand({
    required this.avatarAssetId,
    required this.photos,
    required this.avatarPicking,
    required this.photoAdding,
    required this.isImageGenerationConfigured,
    required this.onPickAvatar,
    required this.onAddPhoto,
    required this.onRemovePhoto,
    required this.onRenamePhoto,
    required this.onRemoveAvatar,
    required this.onGenerateAvatar,
    required this.onGeneratePhoto,
  });

  final String? avatarAssetId;
  final List<SubjectPhoto> photos;
  final bool avatarPicking;
  final bool photoAdding;
  final bool isImageGenerationConfigured;
  final Future<void> Function() onPickAvatar;
  final Future<void> Function() onAddPhoto;
  final Future<void> Function(String path) onRemovePhoto;
  final Future<void> Function(String path, String name) onRenamePhoto;
  final Future<void> Function() onRemoveAvatar;
  final void Function(BuildContext context)? onGenerateAvatar;
  final void Function(BuildContext context)? onGeneratePhoto;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 620) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 164,
                child: _AvatarSection(
                  avatarAssetId: avatarAssetId,
                  isPicking: avatarPicking,
                  isImageGenerationConfigured: isImageGenerationConfigured,
                  onPick: onPickAvatar,
                  onRemove: onRemoveAvatar,
                  onGenerate: onGenerateAvatar,
                ),
              ),
              const SizedBox(height: RevericSpacing.x2l),
              SizedBox(
                height: 128,
                child: _PhotosSection(
                  photos: photos,
                  isAdding: photoAdding,
                  isImageGenerationConfigured: isImageGenerationConfigured,
                  onAdd: onAddPhoto,
                  onRemove: onRemovePhoto,
                  onRename: onRenamePhoto,
                  onGenerate: onGeneratePhoto,
                  avatarAssetId: avatarAssetId,
                ),
              ),
            ],
          );
        }

        return SizedBox(
          height: 164,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 260,
                child: _AvatarSection(
                  avatarAssetId: avatarAssetId,
                  isPicking: avatarPicking,
                  isImageGenerationConfigured: isImageGenerationConfigured,
                  onPick: onPickAvatar,
                  onRemove: onRemoveAvatar,
                  onGenerate: onGenerateAvatar,
                ),
              ),
              const SizedBox(width: RevericSpacing.x2l),
              Expanded(
                child: _PhotosSection(
                  photos: photos,
                  isAdding: photoAdding,
                  isImageGenerationConfigured: isImageGenerationConfigured,
                  onAdd: onAddPhoto,
                  onRemove: onRemovePhoto,
                  onRename: onRenamePhoto,
                  onGenerate: onGeneratePhoto,
                  avatarAssetId: avatarAssetId,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CharacterChapterLink extends HookConsumerWidget {
  const _CharacterChapterLink({
    required this.databasePath,
    required this.characterId,
    required this.firstAppearChapterId,
    required this.chapters,
    this.onNavigateToChapter,
  });

  final String databasePath;
  final String characterId;
  final String? firstAppearChapterId;
  final List<Chapter> chapters;
  final ValueChanged<String>? onNavigateToChapter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.t(LocaleKeys.workspaceCharacterFirstAppearChapter),
            style: typo.uiSemibold.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: RevericSpacing.md),
          Row(
            children: [
              Expanded(
                child: ChapterListDropdown(
                  selectedChapterId: firstAppearChapterId,
                  chapters: chapters,
                  onNavigate: onNavigateToChapter,
                  onChanged: (chapterId) async {
                    final service = ref.read(
                      novelContentServiceProvider(databasePath),
                    );
                    await service.updateCharacterFirstAppearChapter(
                      characterId: characterId,
                      firstAppearChapterId: chapterId,
                    );
                  },
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.lg,
                    vertical: RevericSpacing.sm,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AvatarSection extends StatelessWidget {
  const _AvatarSection({
    required this.avatarAssetId,
    required this.isPicking,
    required this.isImageGenerationConfigured,
    required this.onPick,
    required this.onRemove,
    required this.onGenerate,
  });

  final String? avatarAssetId;
  final bool isPicking;
  final bool isImageGenerationConfigured;
  final Future<void> Function() onPick;
  final Future<void> Function() onRemove;
  final void Function(BuildContext context)? onGenerate;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final disabledGenerateMessage = context.t(
      LocaleKeys.aiNoImageModelConfigured,
    );
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.t(LocaleKeys.workspaceCharacterAvatar),
            style: typo.uiSemibold.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: RevericSpacing.md),
          Expanded(
            child: Row(
              children: [
                _EditableAvatarPreview(
                  avatarAssetId: avatarAssetId,
                  onRemove: onRemove,
                ),
                const SizedBox(width: RevericSpacing.lg),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _CharacterActionButton(
                        icon: RevericIcons.image_outlined,
                        label: context.t(
                          LocaleKeys.workspaceCharacterPickAvatar,
                        ),
                        isLoading: isPicking,
                        onPressed: isPicking ? null : onPick,
                      ),
                      const SizedBox(height: RevericSpacing.xs),
                      if (onGenerate != null)
                        _DisabledActionTooltip(
                          enabled: !isImageGenerationConfigured,
                          message: disabledGenerateMessage,
                          child: _CharacterActionButton(
                            icon: RevericIcons.auto_awesome_outlined,
                            label: context.t(
                              LocaleKeys.workspaceCharacterGenerateAvatar,
                            ),
                            onPressed: () => onGenerate!(context),
                          ),
                        )
                      else
                        const SizedBox.shrink(),
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

class _EditableAvatarPreview extends ConsumerWidget {
  const _EditableAvatarPreview({
    required this.avatarAssetId,
    required this.onRemove,
  });

  final String? avatarAssetId;
  final Future<void> Function() onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final hasAvatar = avatarAssetId != null && avatarAssetId!.isNotEmpty;
    final resolvedAvatar = watchMediaAssetFile(ref, avatarAssetId);
    return GestureDetector(
      onTap: resolvedAvatar != null
          ? () => _showImagePreview(context, resolvedAvatar)
          : null,
      child: SizedBox(
        width: 72,
        height: 72,
        child: Stack(
          children: [
            CharacterAvatar(
              avatarAssetId: avatarAssetId,
              fallbackName: '?',
              size: 72,
            ),
            if (hasAvatar)
              Positioned(
                top: 0,
                right: 0,
                child: Tooltip(
                  message: context.t(LocaleKeys.workspaceCharacterRemovePhoto),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: IconButton(
                      onPressed: onRemove,
                      icon: RevericIcon(
                        RevericIcons.close_rounded,
                        size: 12,
                        color: colors.warningText,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: colors.surface.withValues(alpha: 0.92),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CharacterActionButton extends StatelessWidget {
  const _CharacterActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isLoading = false,
  });

  final String icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final enabled = onPressed != null && !isLoading;
    final foreground = enabled ? colors.accent : colors.textSubtle;
    return OutlinedButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: isLoading
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(colors.accent),
              ),
            )
          : RevericIcon(icon, size: 14, color: foreground),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        foregroundColor: foreground,
        side: BorderSide(color: enabled ? colors.accent : colors.borderInput),
        minimumSize: const Size(0, RevericSizes.buttonHeightSm),
        padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.lg),
        textStyle: typo.uiSmall,
      ),
    );
  }
}

class _DisabledActionTooltip extends StatelessWidget {
  const _DisabledActionTooltip({
    required this.enabled,
    required this.message,
    required this.child,
  });

  final bool enabled;
  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return child;
    }

    return Tooltip(message: message, child: child);
  }
}

class _PhotosSection extends StatelessWidget {
  const _PhotosSection({
    required this.photos,
    required this.isAdding,
    required this.isImageGenerationConfigured,
    required this.onAdd,
    required this.onRemove,
    required this.onRename,
    required this.onGenerate,
    this.avatarAssetId,
  });

  final List<SubjectPhoto> photos;
  final bool isAdding;
  final bool isImageGenerationConfigured;
  final Future<void> Function() onAdd;
  final Future<void> Function(String path) onRemove;
  final Future<void> Function(String path, String name) onRename;
  final void Function(BuildContext context)? onGenerate;
  final String? avatarAssetId;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final hasAvatar = avatarAssetId != null && avatarAssetId!.isNotEmpty;
    final disabledGenerateMessage = context.t(
      LocaleKeys.aiNoImageModelConfigured,
    );
    final setAvatarFirstMessage = context.t(
      LocaleKeys.workspaceCharacterSetAvatarFirst,
    );
    final canGeneratePhoto = hasAvatar;
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.t(LocaleKeys.workspaceCharacterPhotos),
                  style: typo.uiSemibold.copyWith(color: colors.textSecondary),
                ),
              ),
              if (onGenerate != null)
                _DisabledActionTooltip(
                  enabled: !hasAvatar,
                  message: setAvatarFirstMessage,
                  child: _DisabledActionTooltip(
                    enabled: !isImageGenerationConfigured,
                    message: disabledGenerateMessage,
                    child: TextButton.icon(
                      onPressed: canGeneratePhoto
                          ? () => onGenerate!(context)
                          : null,
                      icon: RevericIcon(
                        RevericIcons.auto_awesome_outlined,
                        size: 14,
                        color: canGeneratePhoto
                            ? colors.accent
                            : colors.textSubtle,
                      ),
                      label: Text(
                        context.t(LocaleKeys.workspaceCharacterGeneratePhoto),
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSmall.copyWith(
                          color: canGeneratePhoto
                              ? colors.accent
                              : colors.textSubtle,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                          horizontal: RevericSpacing.sm,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: RevericSpacing.md),
          Expanded(
            child: photos.isEmpty && !isAdding
                ? _EmptyPhotosState(onAdd: onAdd)
                : HorizontalWheelScroll(
                    builder: (context, controller) => ListView.separated(
                      controller: controller,
                      scrollDirection: Axis.horizontal,
                      itemCount: photos.length + 1,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: RevericSpacing.sm),
                      itemBuilder: (context, index) {
                        if (index < photos.length) {
                          final photo = photos[index];
                          return SizedBox(
                            width: 88,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: _PhotoThumbnail(
                                    assetId: photo.assetId,
                                    onRemove: () => onRemove(photo.assetId),
                                  ),
                                ),
                                SubjectPhotoName(
                                  photo: photo,
                                  onRename: (name) =>
                                      onRename(photo.assetId, name),
                                ),
                              ],
                            ),
                          );
                        }
                        return _AddPhotoButton(
                          isAdding: isAdding,
                          onAdd: onAdd,
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPhotosState extends StatelessWidget {
  const _EmptyPhotosState({required this.onAdd});

  final Future<void> Function() onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: RevericSpacing.sm,
        runSpacing: RevericSpacing.xs,
        children: [
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: RevericIcon(
              RevericIcons.add_rounded,
              size: 16,
              color: colors.accent,
            ),
            label: Text(
              context.t(LocaleKeys.workspaceCharacterPickPhoto),
              overflow: TextOverflow.ellipsis,
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.accent,
              side: BorderSide(color: colors.accent),
              minimumSize: const Size(0, RevericSizes.buttonHeightSm),
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.lg,
              ),
              textStyle: typo.uiSmall,
            ),
          ),
        ],
      ),
    );
  }
}

void _showImagePreview(BuildContext context, String imagePath) {
  showRevericDialog(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) {
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(RevericSpacing.x4l),
        child: Stack(
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(RevericRadius.xl),
                child: InteractiveViewer(
                  child: Image.file(
                    File(imagePath),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RevericIcon(
                            RevericIcons.broken_image_outlined,
                            size: 64,
                          ),
                          const SizedBox(height: RevericSpacing.md),
                          Text('无法加载图片'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: RevericIcon(
                  RevericIcons.close_rounded,
                  size: 24,
                  color: Colors.white,
                ),
                style: IconButton.styleFrom(backgroundColor: Colors.black38),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _PhotoThumbnail extends ConsumerWidget {
  const _PhotoThumbnail({required this.assetId, required this.onRemove});

  final String assetId;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final resolved = watchMediaAssetFile(ref, assetId);
    final exists = resolved != null;

    return GestureDetector(
      onTap: exists ? () => _showImagePreview(context, resolved) : null,
      child: SizedBox(
        width: 88,
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(RevericRadius.medium),
              child: Container(
                color: colors.surfaceDim,
                child: exists
                    ? Image.file(File(resolved), fit: BoxFit.cover)
                    : Center(
                        child: RevericIcon(
                          RevericIcons.broken_image_outlined,
                          color: colors.textSubtle,
                          size: 24,
                        ),
                      ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Tooltip(
                message: context.t(LocaleKeys.workspaceCharacterRemovePhoto),
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    onPressed: onRemove,
                    icon: RevericIcon(
                      RevericIcons.close_rounded,
                      size: 14,
                      color: colors.warningText,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: colors.surface.withValues(alpha: 0.92),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddPhotoButton extends StatelessWidget {
  const _AddPhotoButton({required this.isAdding, required this.onAdd});

  final bool isAdding;
  final Future<void> Function() onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return SizedBox(
      width: 88,
      child: Material(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: InkWell(
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          onTap: isAdding ? null : () => onAdd(),
          child: Center(
            child: isAdding
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(colors.accent),
                    ),
                  )
                : RevericIcon(
                    RevericIcons.add_rounded,
                    size: 28,
                    color: colors.textMuted,
                  ),
          ),
        ),
      ),
    );
  }
}

class _EmptyCharacterEditorState extends StatelessWidget {
  const _EmptyCharacterEditorState({
    required this.hasCharacters,
    required this.onCreate,
  });

  final bool hasCharacters;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x6l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.person_outline,
              color: colors.textSubtle,
              size: 32,
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              context.t(
                LocaleKeys.workspaceNoEntrySelected,
                namedArgs: {'type': context.t(LocaleKeys.workspaceCharacters)},
              ),
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.sm),
            Text(
              hasCharacters
                  ? context.t(
                      LocaleKeys.workspaceSelectEntryToEdit,
                      namedArgs: {
                        'type': context.t(LocaleKeys.workspaceCharacters),
                      },
                    )
                  : context.t(
                      LocaleKeys.workspaceCreateFirstEntry,
                      namedArgs: {
                        'type': context.t(LocaleKeys.workspaceCharacters),
                      },
                    ),
              style: typo.ui.copyWith(color: colors.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: RevericSpacing.x2l),
            FilledButton(
              onPressed: onCreate,
              child: Text(context.t(LocaleKeys.workspaceNewCharacter)),
            ),
          ],
        ),
      ),
    );
  }
}

class _CharacterMetaBand extends StatelessWidget {
  const _CharacterMetaBand({required this.children});

  final List<_CharacterMetaField> children;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return Column(
              children: [
                for (int i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i < children.length - 1)
                    const SizedBox(height: RevericSpacing.lg),
                ],
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int i = 0; i < children.length; i++) ...[
                Expanded(flex: children[i].flex, child: children[i]),
                if (i < children.length - 1)
                  const SizedBox(width: RevericSpacing.lg),
              ],
            ],
          );
        },
      ),
    );
  }
}

abstract class _CharacterMetaField extends StatelessWidget {
  const _CharacterMetaField({this.flex = 1});

  final int flex;
}

class _CharacterNameFormField extends _CharacterMetaField {
  const _CharacterNameFormField({
    required this.form,
    required this.label,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.suffixIcon,
  });

  final FormFieldsController<CharacterProfileEditFields> form;
  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final Widget suffixIcon;

  @override
  Widget build(BuildContext context) {
    return HookedForm<CharacterProfileEditFields>(
      form: form,
      child: HookedFormField<CharacterProfileEditFields, String>(
        fieldHook: CharacterProfileEditFields.name,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        builder: (value, onChanged, error) {
          return _CharacterMetaTextField(
            label: label,
            controller: controller,
            focusNode: focusNode,
            hintText: hintText,
            suffixIcon: suffixIcon,
            errorText: error,
            fieldKey: const Key('character-name-field'),
            // 名称只出现在 hero 区，跟头像、身份徽章一起走居中轴线。
            centered: true,
            flex: flex,
          );
        },
      ),
    );
  }
}

class _CharacterMetaTextField extends _CharacterMetaField {
  const _CharacterMetaTextField({
    required this.label,
    required this.controller,
    required this.hintText,
    this.focusNode,
    this.suffixIcon,
    this.errorText,
    this.fieldKey,
    this.centered = false,
    super.flex,
  });

  final String label;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final Widget? suffixIcon;
  final String? errorText;
  final Key? fieldKey;

  /// 标签与输入文本是否居中（hero 区名称用）。
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: typo.uiTinySemibold.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: RevericSpacing.xs),
        RevericTextField(
          controller: controller,
          fieldKey: fieldKey,
          focusNode: focusNode,
          hintText: hintText,
          errorText: errorText,
          suffixIcon: suffixIcon,
          textAlign: centered ? TextAlign.center : TextAlign.start,
        ),
      ],
    );
  }
}

class _CharacterMetaDropdownField extends _CharacterMetaField {
  const _CharacterMetaDropdownField({
    required this.label,
    required this.controller,
    required this.options,
    required this.optionLabels,
  });

  final String label;
  final TextEditingController controller;
  final List<String> options;
  final Map<String, String> optionLabels;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final currentValue = options.contains(value.text)
            ? value.text
            : options.first;
        if (currentValue != value.text) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (controller.text != currentValue) {
              controller.text = currentValue;
            }
          });
        }
        return _CharacterMetaStatusField(
          label: label,
          value: currentValue,
          options: options,
          optionLabels: optionLabels,
          onChanged: (next) {
            if (next != controller.text) {
              controller.text = next;
            }
          },
        );
      },
    );
  }
}

class _CharacterMetaStatusField extends _CharacterMetaField {
  const _CharacterMetaStatusField({
    required this.label,
    required this.value,
    required this.options,
    required this.optionLabels,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> options;
  final Map<String, String> optionLabels;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final currentValue = options.contains(value) ? value : options.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: typo.uiTinySemibold.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: RevericSpacing.xs),
        RevericSelect<String>(
          value: currentValue,
          items: [
            for (final option in options)
              RevericSelectItem<String>(
                value: option,
                label: optionLabels[option] ?? option,
              ),
          ],
          onChanged: (next) {
            onChanged(next);
          },
        ),
      ],
    );
  }
}

/// 长文分组共用的排版设置，避免每个分组都摊开 fontFamily / fontSize 两个参数。
class _ProseStyle {
  const _ProseStyle({required this.fontFamily, required this.fontSize});

  final String fontFamily;
  final int fontSize;
}

const _proseHintKeys = <CharacterProfileEditFields, String>{
  CharacterProfileEditFields.biography:
      LocaleKeys.workspaceCharacterSummaryHint,
  CharacterProfileEditFields.appearance:
      LocaleKeys.workspaceCharacterAppearanceHint,
  CharacterProfileEditFields.description:
      LocaleKeys.workspaceCharacterDescriptionHint,
  CharacterProfileEditFields.personality:
      LocaleKeys.workspaceCharacterPersonalityHint,
  CharacterProfileEditFields.currentState:
      LocaleKeys.workspaceCharacterCurrentStateHint,
  CharacterProfileEditFields.motivation:
      LocaleKeys.workspaceCharacterMotivationHint,
  CharacterProfileEditFields.arc: LocaleKeys.workspaceCharacterArcHint,
};

const _proseEditorKeys = <CharacterProfileEditFields, Key>{
  CharacterProfileEditFields.biography: Key('character-biography-editor'),
  CharacterProfileEditFields.appearance: Key('character-appearance-editor'),
  CharacterProfileEditFields.description: Key('character-description-editor'),
  CharacterProfileEditFields.personality: Key('character-personality-editor'),
  CharacterProfileEditFields.currentState: Key(
    'character-current-state-editor',
  ),
  CharacterProfileEditFields.motivation: Key('character-motivation-editor'),
  CharacterProfileEditFields.arc: Key('character-arc-editor'),
};

/// 平铺在分组里的长文编辑器：随内容自增高，滚动交给页面。
class _CharacterProse extends StatelessWidget {
  const _CharacterProse({
    required this.session,
    required this.field,
    required this.prose,
    this.dense = false,
  });

  final CharacterProfileEditorSession session;
  final CharacterProfileEditFields field;
  final _ProseStyle prose;

  /// 动机 / 弧光这类「比一行长、比一段短」的字段用更矮的底高。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return RevericMarkdownEditor(
      key: _proseEditorKeys[field],
      controller: session.fields.controller(field),
      focusNode: session.fields.focusNode(field),
      hintText: context.t(_proseHintKeys[field]!),
      fontFamily: prose.fontFamily,
      fontSize: prose.fontSize,
      autoHeight: true,
      showToolbar: false,
      minHeight: dense ? 76 : 148,
    );
  }
}

/// 分组外壳：挂 scroll spy 的锚点、画分隔线、统一标题与间距。
class _CharacterSectionShell extends StatelessWidget {
  const _CharacterSectionShell({
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
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.x4l),
      decoration: isFirst
          ? null
          : BoxDecoration(
              border: Border(top: BorderSide(color: colors.borderSubtle)),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CharacterProfileSectionHeader(section: section),
          const SizedBox(height: RevericSpacing.x2l),
          child,
        ],
      ),
    );
  }
}

/// Hero：头像 + 名字 + 定位/性别/年龄徽章 + 身份速览。
/// 徽章只是速览，可编辑的同名字段在「身份档案」分组里。
class _CharacterHeroBand extends StatelessWidget {
  const _CharacterHeroBand({
    required this.session,
    required this.novel,
    required this.nameAssistantAiService,
  });

  final CharacterProfileEditorSession session;
  final Novel? novel;
  final AiClient? nameAssistantAiService;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      children: [
        _CharacterHeroAvatar(
          avatarAssetId: session.avatarAssetId,
          isPicking: session.avatarPicking,
          onPick: session.onPickAvatar,
        ),
        const SizedBox(height: RevericSpacing.lg),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: _CharacterNameFormField(
            form: session.form,
            label: context.t(LocaleKeys.commonName),
            controller: session.nameController,
            focusNode: session.nameFocusNode,
            hintText: context.t(LocaleKeys.workspaceCharacterNameHint),
            suffixIcon: NameAssistantButton(
              nameType: NameType.character,
              aiClient: nameAssistantAiService,
              novel: novel,
              entityDescription: session.descriptionController.text.trim(),
              onNameGenerated: (name) {
                session.nameController.text = name;
                session.nameController.selection = TextSelection.fromPosition(
                  TextPosition(offset: name.length),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: RevericSpacing.lg),
        AnimatedBuilder(
          animation: Listenable.merge([
            session.roleController,
            session.genderController,
            session.ageController,
            session.identityController,
          ]),
          builder: (context, _) {
            final identity = session.identityController.text.trim();
            final age = session.ageController.text.trim();
            // 这里只是下方表单字段的摘要，占一行就够；过长的年龄与身份省略号截断，
            // 不换行成第二、第三行。
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CharacterHeroBadge(
                  label: localizeCharacterRoleLabel(
                    context,
                    session.roleController.text,
                  ),
                  emphasized: true,
                ),
                const SizedBox(width: RevericSpacing.xs),
                _CharacterHeroBadge(
                  label: _genderLabel(context, session.genderController.text),
                ),
                if (age.isNotEmpty) ...[
                  const SizedBox(width: RevericSpacing.xs),
                  Flexible(child: _CharacterHeroBadge(label: age)),
                ],
                if (identity.isNotEmpty) ...[
                  const SizedBox(width: RevericSpacing.sm),
                  Flexible(
                    child: Text(
                      identity,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.bodySmall.copyWith(color: colors.textMuted),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _CharacterHeroAvatar extends StatelessWidget {
  const _CharacterHeroAvatar({
    required this.avatarAssetId,
    required this.isPicking,
    required this.onPick,
  });

  final String? avatarAssetId;
  final bool isPicking;
  final Future<void> Function() onPick;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        children: [
          CharacterAvatar(
            avatarAssetId: avatarAssetId,
            fallbackName: '?',
            size: 88,
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Tooltip(
              message: context.t(LocaleKeys.workspaceCharacterPickAvatar),
              child: Material(
                color: colors.surface,
                shape: CircleBorder(
                  side: BorderSide(color: colors.borderSubtle),
                ),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: isPicking ? null : onPick,
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: Center(
                      child: isPicking
                          ? SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colors.textMuted,
                              ),
                            )
                          : RevericIcon(
                              RevericIcons.image_outlined,
                              size: 14,
                              color: colors.textSecondary,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CharacterHeroBadge extends StatelessWidget {
  const _CharacterHeroBadge({required this.label, this.emphasized = false});

  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: emphasized ? colors.accent : colors.selected,
        borderRadius: BorderRadius.circular(RevericRadius.pill),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: typo.uiSmallSemibold.copyWith(
          color: emphasized ? colors.onAccent : colors.textSecondary,
        ),
      ),
    );
  }
}

String _genderLabel(BuildContext context, String gender) {
  return switch (gender) {
    characterGenderMale => context.t(LocaleKeys.characterGenderMale),
    characterGenderFemale => context.t(LocaleKeys.characterGenderFemale),
    characterGenderNonBinary => context.t(LocaleKeys.characterGenderNonBinary),
    characterGenderOther => context.t(LocaleKeys.characterGenderOther),
    _ => context.t(LocaleKeys.characterGenderUnknown),
  };
}

class _IdentitySection extends StatelessWidget {
  const _IdentitySection({required this.session});

  final CharacterProfileEditorSession session;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CharacterMetaBand(
          children: [
            _CharacterMetaDropdownField(
              label: context.t(LocaleKeys.commonRole),
              controller: session.roleController,
              options: characterRoles,
              optionLabels: {
                for (final role in characterRoles)
                  role: localizeCharacterRoleLabel(context, role),
              },
            ),
            _CharacterMetaDropdownField(
              label: context.t(LocaleKeys.commonGender),
              controller: session.genderController,
              options: characterGenders,
              optionLabels: {
                for (final gender in characterGenders)
                  gender: _genderLabel(context, gender),
              },
            ),
            _CharacterMetaTextField(
              label: context.t(LocaleKeys.historyFieldAge),
              controller: session.ageController,
              focusNode: session.ageFocusNode,
              fieldKey: const Key('character-age-field'),
              hintText: context.t(LocaleKeys.workspaceCharacterAgeHint),
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.lg),
        _CharacterMetaBand(
          children: [
            _CharacterMetaTextField(
              label: context.t(LocaleKeys.historyFieldIdentity),
              controller: session.identityController,
              focusNode: session.identityFocusNode,
              fieldKey: const Key('character-identity-field'),
              hintText: context.t(LocaleKeys.workspaceCharacterIdentityHint),
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.lg),
        _CharacterIdentifiersCard(session: session),
      ],
    );
  }
}

class _FigureSection extends StatelessWidget {
  const _FigureSection({
    required this.session,
    required this.prose,
    required this.onGenerateAvatar,
    required this.onGeneratePhoto,
  });

  final CharacterProfileEditorSession session;
  final _ProseStyle prose;
  final void Function(BuildContext context)? onGenerateAvatar;
  final void Function(BuildContext context)? onGeneratePhoto;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CharacterProse(
          session: session,
          field: CharacterProfileEditFields.appearance,
          prose: prose,
        ),
        const SizedBox(height: RevericSpacing.x3l),
        CharacterProfileSubLabel(
          text: context.t(LocaleKeys.workspaceCharacterPhotosLabel),
        ),
        const SizedBox(height: RevericSpacing.md),
        _CharacterImageBand(
          avatarAssetId: session.avatarAssetId,
          photos: session.photos,
          avatarPicking: session.avatarPicking,
          photoAdding: session.photoAdding,
          isImageGenerationConfigured: session.isImageGenerationConfigured,
          onPickAvatar: session.onPickAvatar,
          onAddPhoto: session.onAddPhoto,
          onRemovePhoto: session.onRemovePhoto,
          onRenamePhoto: session.onRenamePhoto,
          onRemoveAvatar: session.onRemoveAvatar,
          onGenerateAvatar: onGenerateAvatar,
          onGeneratePhoto: onGeneratePhoto,
        ),
      ],
    );
  }
}

class _BiographySection extends StatelessWidget {
  const _BiographySection({required this.session, required this.prose});

  final CharacterProfileEditorSession session;
  final _ProseStyle prose;

  @override
  Widget build(BuildContext context) {
    return _CharacterProse(
      session: session,
      field: CharacterProfileEditFields.biography,
      prose: prose,
    );
  }
}

class _OutwardSection extends StatelessWidget {
  const _OutwardSection({required this.session, required this.prose});

  final CharacterProfileEditorSession session;
  final _ProseStyle prose;

  @override
  Widget build(BuildContext context) {
    return _CharacterProse(
      session: session,
      field: CharacterProfileEditFields.description,
      prose: prose,
    );
  }
}

class _PsycheSection extends StatelessWidget {
  const _PsycheSection({required this.session, required this.prose});

  final CharacterProfileEditorSession session;
  final _ProseStyle prose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 动机与弧光都会自增高，并排放底边永远对不齐，因此走通栏。
        CharacterProfileSubLabel(
          text: context.t(LocaleKeys.historyFieldMotivation),
        ),
        const SizedBox(height: RevericSpacing.xs),
        _CharacterProse(
          session: session,
          field: CharacterProfileEditFields.motivation,
          prose: prose,
          dense: true,
        ),
        const SizedBox(height: RevericSpacing.lg),
        CharacterProfileSubLabel(text: context.t(LocaleKeys.historyFieldArc)),
        const SizedBox(height: RevericSpacing.xs),
        _CharacterProse(
          session: session,
          field: CharacterProfileEditFields.arc,
          prose: prose,
          dense: true,
        ),
        const SizedBox(height: RevericSpacing.x3l),
        CharacterProfileSubLabel(
          text: context.t(LocaleKeys.workspaceCharacterPersonalityLabel),
        ),
        const SizedBox(height: RevericSpacing.xs),
        _CharacterProse(
          session: session,
          field: CharacterProfileEditFields.personality,
          prose: prose,
        ),
        const SizedBox(height: RevericSpacing.x3l),
        _CharacterBehaviorTagsEditor(
          tags: session.behaviorTags,
          onChanged: session.onBehaviorTagsChanged,
        ),
      ],
    );
  }
}

class _StorySection extends StatelessWidget {
  const _StorySection({
    required this.session,
    required this.prose,
    required this.chapterLink,
  });

  final CharacterProfileEditorSession session;
  final _ProseStyle prose;
  final Widget? chapterLink;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (chapterLink != null) ...[
          chapterLink!,
          const SizedBox(height: RevericSpacing.lg),
        ],
        _CharacterProse(
          session: session,
          field: CharacterProfileEditFields.currentState,
          prose: prose,
        ),
      ],
    );
  }
}

/// 新建态还没有实体 id，关系只能在保存后查看。
class _RelationsUnavailable extends StatelessWidget {
  const _RelationsUnavailable();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Text(
      context.t(LocaleKeys.workspaceCharacterRelationsEmpty),
      style: typo.bodySmall.copyWith(color: colors.textMuted),
    );
  }
}

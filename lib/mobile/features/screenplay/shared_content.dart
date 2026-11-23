// 职责: 在剧本工作区组合人物、设定资产、地图、关系图谱和当前进度，并提供对应的新建入口。
// 关联文件:
//   lib/mobile/features/screenplay/editor_page.dart
//   lib/mobile/widgets/section_panel.dart
//   lib/mobile/widgets/compendium_panel.dart
//   lib/mobile/widgets/characters_panel.dart
//   lib/mobile/widgets/entity_graph_panel.dart
//   lib/shared/widgets/story_progress_panel.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/entity_graph.json
//   assets/translations/zh-CN/entity_graph.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/error-handling.md

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart'
    show locationTypeWorld;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/screenplay_workspace_state.dart';
import '../../../shared/providers/maps_providers.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/relation_edit_dialog.dart';
import '../../../shared/widgets/story_progress_panel.dart';
import '../../pages/character_editor_page.dart';
import '../../pages/foreshadowing_editor_page.dart';
import '../../widgets/compendium_panel.dart';
import '../../widgets/foreshadowings_panel.dart';
import '../../pages/entry_editor_page.dart';
import '../../pages/location_editor_page.dart';
import '../../widgets/characters_panel.dart';
import '../../widgets/entity_graph_panel.dart';
import '../../widgets/maps_panel.dart';
import '../../widgets/section_panel.dart';

final _log = AppLogger.forModule('MobileScreenplaySharedContent');

/// 返回共享分区对应的新建文案 key；无新建入口的分区返回 null。
String? mobileScreenplayCreateLabelKey(ScreenplayWorkspaceSection section) {
  return switch (section) {
    ScreenplayWorkspaceSection.characters => LocaleKeys.workspaceNewCharacter,
    ScreenplayWorkspaceSection.foreshadowings =>
      LocaleKeys.workspaceNewForeshadowing,
    ScreenplayWorkspaceSection.lore => MobileEditorSection.lore.newLabelKey,
    ScreenplayWorkspaceSection.compendium =>
      LocaleKeys.workspaceNewCompendiumEntry,
    ScreenplayWorkspaceSection.maps => LocaleKeys.mapEditorCreateWorldTitle,
    ScreenplayWorkspaceSection.materials =>
      MobileEditorSection.materials.newLabelKey,
    ScreenplayWorkspaceSection.entity_graph =>
      LocaleKeys.entityGraphAddRelation,
    _ => null,
  };
}

class MobileScreenplaySharedContent extends HookConsumerWidget {
  const MobileScreenplaySharedContent({
    super.key,
    required this.novel,
    required this.section,
    required this.registerCreate,
  });

  final Novel novel;
  final ScreenplayWorkspaceSection section;
  final void Function(
    ScreenplayWorkspaceSection section,
    Future<void> Function()? handler,
  )
  registerCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = novel.contentDatabasePath!;
    final documentCreate = useRef<Future<void> Function()?>(null);
    final creating = useState(false);
    final simple = switch (section) {
      ScreenplayWorkspaceSection.lore => MobileEditorSection.lore,
      ScreenplayWorkspaceSection.materials => MobileEditorSection.materials,
      _ => null,
    };

    void openGraph() {
      final provider = screenplayWorkspaceStateControllerProvider(
        novel.id,
        path,
      );
      ref
          .read(provider.notifier)
          .update(
            ref
                .read(provider)
                .copyWith(section: ScreenplayWorkspaceSection.entity_graph),
          );
    }

    Future<void> create({MobileEditorSection? compendiumSection}) async {
      if (creating.value) {
        return;
      }
      creating.value = true;
      try {
        if (section == ScreenplayWorkspaceSection.entity_graph) {
          await RelationEditDialog.show(context, databasePath: path);
          return;
        }
        if (simple?.isDocument == true) {
          final handler = documentCreate.value;
          if (handler == null) {
            throw StateError(
              'Document folder create handler is not registered',
            );
          }
          await handler();
          return;
        }
        final service = ref.read(novelContentServiceProvider(path));
        final Widget editor;
        if (section == ScreenplayWorkspaceSection.characters) {
          final id = await service.createCharacterProfile(
            defaultName: context.t(LocaleKeys.workspaceNewCharacter),
          );
          editor = MobileCharacterEditorPage(
            novelId: novel.id,
            databasePath: path,
            characterId: id,
            onOpenGraph: openGraph,
            isScreenplay: true,
          );
        } else if (section == ScreenplayWorkspaceSection.foreshadowings) {
          final id = await service.createForeshadowing(
            defaultTitle: context.t(LocaleKeys.workspaceNewForeshadowing),
          );
          editor = MobileForeshadowingEditorPage(
            novelId: novel.id,
            databasePath: path,
            foreshadowingId: id,
          );
        } else if (section == ScreenplayWorkspaceSection.maps) {
          final id = await ref
              .read(locationsServiceProvider(path))
              .createLocationWithDefaultName(
                defaultName: context.t(LocaleKeys.mobileEditorNewWorld),
                type: locationTypeWorld,
                parentId: null,
              );
          editor = MobileLocationEditorPage(
            databasePath: path,
            novelId: novel.id,
            locationId: id,
          );
        } else if (section == ScreenplayWorkspaceSection.compendium) {
          final entrySection =
              compendiumSection ??
              await showMobileCompendiumCreateSheet(context);
          if (entrySection == null || !context.mounted) {
            return;
          }
          final id = await service.createItem(
            type: entrySection.typeValue,
            defaultTitle: context.t(entrySection.newLabelKey),
          );
          editor = MobileEntryEditorPage(
            novelId: novel.id,
            databasePath: path,
            section: entrySection,
            entryId: id,
          );
        } else {
          throw StateError('Unsupported create screenplay section: $section');
        }
        if (context.mounted) {
          await Navigator.of(
            context,
          ).push<void>(MaterialPageRoute(builder: (_) => editor));
        }
      } catch (error, stackTrace) {
        _log.error(
          'Create screenplay workspace entry failed: ${section.name}',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      } finally {
        if (context.mounted) {
          creating.value = false;
        }
      }
    }

    final createRef = useRef<Future<void> Function()>(create);
    createRef.value = create;
    final registerCreateRef = useRef(registerCreate);
    registerCreateRef.value = registerCreate;
    useEffect(() {
      if (mobileScreenplayCreateLabelKey(section) == null) {
        registerCreateRef.value(section, null);
        return null;
      }
      Future<void> dispatch() => createRef.value();
      registerCreateRef.value(section, dispatch);
      return () => registerCreateRef.value(section, null);
    }, [section]);

    if (simple != null) {
      return MobileSectionPanel(
        novelId: novel.id,
        databasePath: path,
        section: simple,
        onCreate: create,
        onRegisterDocumentCreate: (handler) => documentCreate.value = handler,
      );
    }
    return switch (section) {
      ScreenplayWorkspaceSection.foreshadowings => MobileForeshadowingsPanel(
        novelId: novel.id,
        databasePath: path,
        onCreate: create,
      ),
      ScreenplayWorkspaceSection.characters => MobileCharactersPanel(
        novelId: novel.id,
        databasePath: path,
        onCreate: create,
        onOpenGraph: openGraph,
        isScreenplay: true,
      ),
      ScreenplayWorkspaceSection.compendium => MobileCompendiumPanel(
        novelId: novel.id,
        databasePath: path,
        onCreate: (entrySection) {
          unawaited(create(compendiumSection: entrySection));
        },
      ),
      ScreenplayWorkspaceSection.maps => MobileMapsPanel(
        novelId: novel.id,
        databasePath: path,
        onCreate: create,
      ),
      ScreenplayWorkspaceSection.entity_graph => MobileEntityGraphPanel(
        novelId: novel.id,
        databasePath: path,
        onCreate: create,
      ),
      ScreenplayWorkspaceSection.story_progress => StoryProgressPanel(
        databasePath: path,
        chapters: ref.watch(chaptersProvider(path)).value ?? const [],
        padding: const EdgeInsets.all(RevericSpacing.x2l),
      ),
      _ => throw StateError('Unsupported shared screenplay section: $section'),
    };
  }
}

// 职责: AI 工具路径解析与资源名解析 — 将章节/角色等路径映射为用户可读标题。
// 关联文件:
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/services/ai/tools.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/assets.json
//   assets/translations/zh-CN/assets.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/character.json
//   assets/translations/zh-CN/character.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/tool.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/relation.json
//   assets/translations/zh-CN/relation.json
import 'package:flutter/widgets.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reveric/shared/entity_graph/labels.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/outline.dart';
import 'package:reveric/shared/providers/screenplay_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/providers/novel_providers.dart';

class AiToolResolvedResource {
  const AiToolResolvedResource({
    required this.collection,
    required this.resourceTitle,
    this.workTitle,
    this.isUnavailableWork = false,
    this.showCollection = true,
    this.resourceMeta,
    this.ordinals = const {},
    this.isListing = false,
    this.chapterNum,
    this.volumeNum,
    this.subCollection,
    this.subResourceTitle,
    this.field,
    this.queryParameters = const {},
    this.labelPath,
  });

  final Map<String, int> ordinals;
  final bool isListing;
  final bool isUnavailableWork;
  final bool showCollection;
  final String collection;
  final String resourceTitle;
  final String? workTitle;
  final String? resourceMeta;
  final int? chapterNum;
  final int? volumeNum;
  final String? subCollection;
  final String? subResourceTitle;
  final String? field;
  final Map<String, String> queryParameters;

  /// 画布制作路径。展示时整段本地化，避免只剩集合名。
  final String? labelPath;

  // 解析结果按实际展示字段比较，正文、字数和更新时间变化不刷新工具行。
  List<Object?> get _displayFields => [
    collection,
    resourceTitle,
    workTitle,
    isUnavailableWork,
    showCollection,
    resourceMeta,
    ordinals,
    isListing,
    chapterNum,
    volumeNum,
    subCollection,
    subResourceTitle,
    field,
    queryParameters,
    labelPath,
  ];

  @override
  bool operator ==(Object other) =>
      other is AiToolResolvedResource &&
      const DeepCollectionEquality().equals(
        _displayFields,
        other._displayFields,
      );

  @override
  int get hashCode => const DeepCollectionEquality().hash(_displayFields);

  String displayLabel(BuildContext context) {
    if (labelPath != null) {
      final localized = localizedToolPathLabel(context, labelPath!);
      final parts = <String>[
        if (isUnavailableWork) context.t(LocaleKeys.toolWorkUnavailable),
        if (workTitle != null && workTitle!.trim().isNotEmpty)
          workTitle!.trim(),
        if (localized.isNotEmpty) localized,
        ..._localizedQueryParameters(context, queryParameters),
      ];
      return parts.join(' · ');
    }
    final parts = <String>[
      if (isUnavailableWork) context.t(LocaleKeys.toolWorkUnavailable),
      if (workTitle != null && workTitle!.trim().isNotEmpty) workTitle!.trim(),
      if (showCollection && (ordinals.isEmpty || isListing))
        _localizedCollection(context, collection, asList: isListing),
      for (final entry in ordinals.entries)
        context.t(
          entry.key,
          namedArgs: {'number': '${entry.value}', 'index': '${entry.value}'},
        ),
      ..._localizedOrdinalLabels(context),
      if (resourceTitle.isNotEmpty) resourceTitle,
      if (subCollection != null && subCollection!.trim().isNotEmpty)
        _localizedSubCollection(context, subCollection!),
      if (subResourceTitle != null && subResourceTitle!.trim().isNotEmpty)
        _localizedSubResourceTitle(context, subResourceTitle!),
      if (field != null && field!.trim().isNotEmpty)
        aiToolFieldLabel(context, field!),
      ..._localizedQueryParameters(context, queryParameters),
    ];
    return parts.join(' · ');
  }

  List<String> _localizedOrdinalLabels(BuildContext context) {
    if (chapterNum != null) {
      return [
        context.t(
          LocaleKeys.commonChapterNumber,
          namedArgs: {'number': '$chapterNum'},
        ),
      ];
    }
    if (volumeNum != null) {
      return [
        context.t(
          LocaleKeys.workspaceVolumeNumber,
          namedArgs: {'number': '$volumeNum'},
        ),
      ];
    }
    if (resourceMeta == nodeTypeExtra) {
      return [context.t(LocaleKeys.workspaceExtra)];
    }
    final meta = resourceMeta?.trim();
    if (meta == null || meta.isEmpty) {
      return const [];
    }
    return [meta];
  }
}

class _ParsedToolPath {
  const _ParsedToolPath({
    required this.collection,
    required this.target,
    this.resourceIdOrName,
    this.field,
    this.queryParameters = const {},
  });

  final String collection;
  final ParsedPath target;
  final String? resourceIdOrName;
  final String? field;
  final Map<String, String> queryParameters;
}

final toolResolvedResourceProvider =
    FutureProvider.family<
      AiToolResolvedResource?,
      ({String novelId, String databasePath, String path})
    >((ref, params) async {
      final target = parseAiToolPath(params.path);
      if (target.workId != null && params.novelId != target.workId) {
        final targetWork = await ref.watch(
          novelProvider(target.workId!).future,
        );
        return _crossWorkResolvedResource(target, targetWork?.title);
      }
      final parsed = _parseToolPath(target);
      if (parsed == null) {
        return null;
      }

      if (parsed.collection == 'profile') {
        return AiToolResolvedResource(
          collection: parsed.collection,
          resourceTitle: '',
          field: parsed.field,
          queryParameters: parsed.queryParameters,
        );
      }

      if (parsed.collection == 'relations') {
        return AiToolResolvedResource(
          collection: parsed.collection,
          resourceTitle: '',
          subCollection: parsed.target.resourceSegment == 'change_logs'
              ? 'change_logs'
              : null,
          field: parsed.field,
          queryParameters: parsed.queryParameters,
        );
      }

      if (_screenplayCollections.contains(parsed.collection) ||
          (parsed.collection == 'clips' &&
              parsed.target.resourceSegment == 'clips' &&
              parsed.target.isResourceListing)) {
        return _resolveScreenplayResource(
          ref,
          params.databasePath,
          parsed.target,
        );
      }

      if (parsed.collection == 'canvas') {
        return AiToolResolvedResource(
          collection: parsed.collection,
          resourceTitle: parsed.target.locator('name') ?? '',
          isListing: parsed.target.isResourceListing,
          subCollection: parsed.target.resourceSegment == 'canvas'
              ? null
              : parsed.target.resourceSegment,
          field: parsed.field,
        );
      }

      if (parsed.collection == 'production') {
        return AiToolResolvedResource(
          collection: parsed.collection,
          resourceTitle: '',
          showCollection: false,
          isListing: parsed.target.isResourceListing,
          labelPath: parsed.target.displayPath,
          queryParameters: parsed.queryParameters,
        );
      }

      // 多层集合路径由 localizedToolPathLabel 统一处理，避免把子路径当资源名。
      if (const ['screenplay', '_schema'].contains(parsed.collection)) {
        return null;
      }

      final idOrName = parsed.resourceIdOrName;
      AiToolResolvedResource fallback() => AiToolResolvedResource(
        collection: parsed.collection,
        resourceTitle: idOrName ?? '',
        field: parsed.field,
        queryParameters: parsed.queryParameters,
      );
      if (parsed.collection == 'chapters' || parsed.collection == 'volumes') {
        final identity = _splitIdentityQueryParams(
          parsed.collection,
          parsed.queryParameters,
        );
        // 集合标签与树无关；带章号、卷号或标题的查询仍需解析实际节点。
        if (idOrName == null &&
            identity.chapterNum == null &&
            identity.volumeNum == null &&
            identity.title == null) {
          return fallback();
        }
        return ref.watch(
          chapterTreeProvider(params.databasePath).selectAsync((nodes) {
            if (parsed.collection == 'chapters') {
              if (idOrName != null) {
                final chapter = _findNodeById(nodes, idOrName);
                if (chapter != null && chapter.isChapter) {
                  return _chapterResolvedResource(parsed, chapter);
                }
              } else {
                return _resolveChapterQuery(nodes, parsed) ?? fallback();
              }
            } else {
              if (idOrName != null) {
                final volume = _findNodeById(nodes, idOrName);
                if (volume != null && volume.isVolume) {
                  return _volumeResolvedResource(parsed, volume);
                }
              } else {
                return _resolveVolumeQuery(nodes, parsed) ?? fallback();
              }
            }
            return fallback();
          }),
        );
      }

      final service = ref.watch(
        novelContentServiceProvider(params.databasePath),
      );

      if (parsed.collection == 'clips' && idOrName != null) {
        final shot = await StoryboardService(
          service.database,
        ).getShot(idOrName);
        if (shot != null) {
          return AiToolResolvedResource(
            collection: 'clips',
            resourceTitle: shot.title,
            field: parsed.field,
          );
        }
      }
      if (parsed.collection == 'characters' && idOrName != null) {
        final character = await service.getCharacterProfileById(idOrName);
        if (character != null) {
          return AiToolResolvedResource(
            collection: parsed.collection,
            resourceTitle: character.name,
            field: parsed.field,
            queryParameters: parsed.queryParameters,
          );
        }
      }

      if (parsed.collection == 'foreshadowing' && idOrName != null) {
        final foreshadowing = await service.getForeshadowingById(idOrName);
        if (foreshadowing != null) {
          return AiToolResolvedResource(
            collection: parsed.collection,
            resourceTitle: foreshadowing.title,
            field: parsed.field,
            queryParameters: parsed.queryParameters,
          );
        }
      }

      if (parsed.collection == 'locations' && idOrName != null) {
        final location = await service.locationsService.getLocationById(
          idOrName,
        );
        if (location != null) {
          return AiToolResolvedResource(
            collection: parsed.collection,
            resourceTitle: location.name,
            field: parsed.field,
            queryParameters: parsed.queryParameters,
          );
        }
      }

      if (parsed.collection == '.agents/rules' && idOrName != null) {
        return AiToolResolvedResource(
          collection: parsed.collection,
          resourceTitle: idOrName,
          field: parsed.field,
          queryParameters: parsed.queryParameters,
        );
      }

      const itemTypeByCollection = {
        'skills': 'skill',
        'items': 'item',
        'factions': 'faction',
        'creatures': 'creature',
      };
      if (itemTypeByCollection.containsKey(parsed.collection) &&
          idOrName != null) {
        final itemType = itemTypeByCollection[parsed.collection]!;
        final item = await service.getItemById(idOrName);
        if (item != null && item.type == itemType) {
          return AiToolResolvedResource(
            collection: parsed.collection,
            resourceTitle: item.title,
            field: parsed.field,
            queryParameters: parsed.queryParameters,
          );
        }
      }

      if (parsed.collection == 'outlines' && idOrName != null) {
        final outline =
            await service.outlineService.getByDocumentId(idOrName) ??
            await service.outlineService.getByTitle(
              _outlineTitleFromNamePath(parsed),
            );
        final beatId = parsed.target.outlineBeatId;
        final beatTitle = beatId == null
            ? null
            : _outlineBeatTitle(outline?.beats, beatId);
        return AiToolResolvedResource(
          collection: parsed.collection,
          resourceTitle: outline?.title.trim().isNotEmpty == true
              ? outline!.title.trim()
              : _outlineTitleFromNamePath(parsed),
          subCollection: _isOutlineBeatsPath(parsed) ? 'beats' : null,
          subResourceTitle: beatId == null ? null : beatTitle ?? beatId,
          field: _outlineField(parsed),
          queryParameters: parsed.queryParameters,
        );
      }

      // 'worldbuilding' 是 /lore 改名前的历史工具调用记录里的路径。
      if (const {
            'lore',
            'worldbuilding',
            'materials',
          }.contains(parsed.collection) &&
          idOrName != null) {
        return AiToolResolvedResource(
          collection: parsed.collection,
          resourceTitle: idOrName,
          field: parsed.field,
          queryParameters: parsed.queryParameters,
        );
      }

      return fallback();
    });

const _screenplayCollections = {'seasons', 'episodes', 'scenes'};

Future<AiToolResolvedResource?> _resolveScreenplayResource(
  Ref ref,
  String databasePath,
  ParsedPath parsed,
) async {
  final collection = parsed.collection;
  final id = switch (collection) {
    'seasons' => parsed.locator('season_id'),
    'episodes' => parsed.locator('episode_id'),
    'scenes' => parsed.locator('scene_id'),
    _ => null,
  };
  final query = Map<String, String>.of(parsed.queryParameters);
  String? seasonId = collection == 'seasons' ? id : query['season_id'];
  String? episodeId = collection == 'episodes' ? id : query['episode_id'];
  final sceneId = collection == 'scenes' ? id : query['scene_id'];
  int? sceneNumber;
  String title = '';
  String? detail;

  // ref.watch 尽量在 await 之前同步登记：本 provider 是 autoDispose，跨 await 再
  // watch 会在订阅者中途消失时用到已失效的 ref。root 之后的三个 family 都要
  // root.id，没法再往前提，所以集中在下面这一处一次性登记，然后统一 await。
  final root = await ref.watch(screenplayRootProvider(databasePath).future);
  if (root == null) {
    return null;
  }
  final seasonsFuture = ref.watch(
    screenplaySeasonsProvider(databasePath, root.id).future,
  );
  final episodesFuture = ref.watch(
    screenplayEpisodesOfScreenplayProvider(databasePath, root.id).future,
  );
  final scenesFuture = sceneId == null
      ? null
      : ref.watch(
          screenplayScenesOfScreenplayProvider(databasePath, root.id).future,
        );
  final seasons = await seasonsFuture;
  final episodes = await episodesFuture;

  if (sceneId != null) {
    final scenes = await scenesFuture!;
    final scene = scenes.values
        .expand((rows) => rows)
        .where((row) => row.id == sceneId)
        .firstOrNull;
    if (scene == null) {
      return null;
    }
    episodeId = scene.episodeId;
    sceneNumber = scene.sceneNumber;
    if (parsed.resourceSegment == 'elements') {
      detail = 'elements';
    }
    query.remove('scene_id');
  }
  final episode = episodes.where((row) => row.id == episodeId).firstOrNull;
  if (episodeId != null && episode == null) {
    return null;
  }
  seasonId ??= episode?.seasonId;
  final season = seasons.where((row) => row.id == seasonId).firstOrNull;
  if (seasonId != null && season == null) {
    return null;
  }
  if (collection == 'episodes' && id != null) {
    title = episode?.title ?? '';
  } else if (collection == 'seasons' && id != null) {
    title = season?.title ?? '';
  }
  if (episode != null) {
    query.remove('episode_id');
  }
  if (season != null) {
    query.remove('season_id');
  }
  return AiToolResolvedResource(
    collection: collection,
    resourceTitle: title.trim(),
    isListing: id == null,
    ordinals: {
      if (season != null) LocaleKeys.screenplaySeason: season.seasonNumber,
      if (episode != null) LocaleKeys.screenplayEpisode: episode.episodeNumber,
      LocaleKeys.screenplayScene: ?sceneNumber,
    },
    subCollection: _productionStructuralTail(parsed.originalPath, parsed.field),
    field: parsed.field ?? detail,
    queryParameters: query,
  );
}

typedef ToolRelationEndpointLabels = ({String? source, String? target});

final toolRelationEndpointLabelsProvider =
    FutureProvider.family<
      ToolRelationEndpointLabels?,
      ({
        String databasePath,
        String sourceType,
        String sourceId,
        String targetType,
        String targetId,
      })
    >((ref, params) async {
      final sourceType = params.sourceType.trim();
      final sourceId = params.sourceId.trim();
      final targetType = params.targetType.trim();
      final targetId = params.targetId.trim();
      if (sourceId.isEmpty && targetId.isEmpty) {
        return null;
      }

      final service = ref.watch(
        novelContentServiceProvider(params.databasePath),
      );
      final source = sourceId.isEmpty
          ? null
          : await resolveEntityDisplayName(service, sourceType, sourceId);
      final target = targetId.isEmpty
          ? null
          : await resolveEntityDisplayName(service, targetType, targetId);
      if ((source == null || source.isEmpty) &&
          (target == null || target.isEmpty)) {
        return null;
      }
      return (source: source, target: target);
    });

/// 返回 null 表示这个过滤条件不出 chip。
String? localizedToolQueryChip(BuildContext context, String key, String value) {
  return _localizedQueryChip(context, key, value);
}

String localizedChapterTypeLabel(BuildContext context, String type) {
  final normalized = type.trim().toLowerCase();
  switch (normalized) {
    case 'chapter':
    case '正文':
    case 'main':
    case 'main_chapter':
      return context.t(LocaleKeys.toolChapterTypeChapter);
    case 'extra':
    case '番外':
    case 'side':
    case 'side_story':
      return context.t(LocaleKeys.workspaceExtra);
    default:
      return type;
  }
}

String localizedToolPathLabel(
  BuildContext context,
  String path, {
  bool collectionAsList = false,
}) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) {
    return path;
  }

  final queryStart = trimmed.indexOf('?');
  if (queryStart >= 0) {
    final pathPart = trimmed.substring(0, queryStart);
    final segments = pathPart
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .toList();
    if (segments.isEmpty) {
      return trimmed;
    }
    final collection = localizedToolPathLabel(
      context,
      pathPart,
      collectionAsList: collectionAsList,
    );

    final queryParams = parseAiToolPath(trimmed).queryParameters;
    final chips = <String>[
      for (final entry in queryParams.entries)
        ?_localizedQueryChip(context, entry.key, entry.value),
    ];

    if (chips.isEmpty) {
      return collection;
    }
    return '$collection · ${chips.join(' · ')}';
  }

  final segments = trimmed
      .split('/')
      .where((segment) => segment.trim().isNotEmpty)
      .toList();
  if (segments.isEmpty) {
    return trimmed;
  }

  // 异步解析完成后会用作品标题替换前缀；加载或查找失败时也不暴露内部作品 ID。
  if (segments.first == 'works' && segments.length >= 2) {
    final parts = <String>[
      _localizedCollection(context, 'works'),
      if (segments.length > 2)
        localizedToolPathLabel(
          context,
          segments.skip(2).join('/'),
          collectionAsList: collectionAsList,
        ),
    ];
    return parts.join(' · ');
  }

  final collection = _localizedCollection(
    context,
    segments.first,
    asList: collectionAsList && segments.length == 1,
  );
  if (segments.length == 1) {
    return collection;
  }

  final parsed = parseAiToolPath(
    trimmed.replaceFirst(RegExp(r'^/?worldbuilding(?=/|$)'), 'lore'),
  );

  if (parsed.collection == 'relations') {
    return AiToolResolvedResource(
      collection: parsed.collection,
      resourceTitle: '',
      subCollection: parsed.resourceSegment == 'change_logs'
          ? 'change_logs'
          : null,
      field: parsed.field,
    ).displayLabel(context);
  }

  // Canvas paths 形如 /canvas/{name}[/nodes|edges/{id}[/{field}]] 或 /canvas/{name}/layout。
  // 画布名是路径键、也是用户在列表里看到的标题，保留；节点与边的 id 折叠掉。
  if (segments.first == 'canvas') {
    if (!parsed.isValidResourcePath) {
      return trimmed;
    }
    final canvasName = parsed.locator('name')!;
    final subcollection = parsed.resourceSegment == 'canvas'
        ? parsed.field
        : parsed.resourceSegment;
    final sublabel = switch (subcollection) {
      'nodes' => context.t(LocaleKeys.toolPathCanvasNodes),
      'edges' => context.t(LocaleKeys.toolPathCanvasEdges),
      'layout' => context.t(LocaleKeys.toolPathCanvasLayout),
      null => null,
      _ => aiToolFieldLabel(context, subcollection),
    };
    return sublabel == null
        ? '$collection · $canvasName'
        : '$collection · $canvasName · $sublabel';
  }

  // 画布制作 /production/… 与按集 …/production/canvas/…。id 段不展示。
  if (segments.first == 'production') {
    return _localizedProductionSegments(
      context,
      segments,
      canvasWork: true,
    ).join(' · ');
  }

  if (segments.first == '_schema') {
    final target = segments.length > 2 && segments[1] == 'groups'
        ? switch (segments[2]) {
            'shared' => context.t(LocaleKeys.toolSchemaShared),
            'novel' => context.t(LocaleKeys.toolSchemaNovel),
            'screenplay' => context.t(LocaleKeys.screenplayScript),
            _ => segments[2],
          }
        : _localizedCollection(context, segments[1]);
    return '$collection · $target';
  }
  if (_screenplayCollections.contains(segments.first)) {
    final productionAt = segments.indexOf('production');
    if (productionAt >= 0) {
      final tail = _localizedProductionSegments(
        context,
        segments.sublist(productionAt),
        canvasWork: false,
      ).join(' · ');
      return [collection, if (tail.isNotEmpty) tail].join(' · ');
    }
    return [
      collection,
      if (parsed.resourceSegment == 'elements')
        aiToolFieldLabel(context, 'elements'),
      if (segments.length >= 3 &&
          !const ['elements', 'text'].contains(segments.last) &&
          aiToolFieldLabel(context, segments.last) != segments.last)
        aiToolFieldLabel(context, segments.last),
    ].join(' · ');
  }

  final field = segments.last;
  final fieldLabelText = aiToolFieldLabel(context, field);
  final hasKnownField = fieldLabelText != field;

  if (const {
    'lore',
    'worldbuilding',
    'outlines',
    'materials',
  }.contains(segments.first)) {
    if (!parsed.isValidResourcePath) {
      return trimmed;
    }
    if (parsed.isOutlineBeat) {
      return [
        collection,
        parsed.locator('title')!,
        _localizedSubCollection(context, 'beats'),
        ?parsed.outlineBeatId,
        if (parsed.field case final field?) aiToolFieldLabel(context, field),
      ].join(' · ');
    }
    final title = parsed.namePath.join(' / ');
    return [
      collection,
      title,
      if (parsed.field case final field?) aiToolFieldLabel(context, field),
    ].join(' · ');
  }

  if (segments.length >= 3 && hasKnownField) {
    final id = segments[1];
    final shortId = id.length > 16 ? '${id.substring(0, 12)}…' : id;
    return '$collection · $shortId · $fieldLabelText';
  }

  if (segments.length == 2) {
    return '$collection · ${segments[1]}';
  }

  return trimmed;
}

String localizeGlobPattern(BuildContext context, String pattern) {
  final trimmed = pattern.trim();
  if (trimmed.isEmpty) {
    return pattern;
  }

  final globMatch = RegExp(r'(\*\*|\*|\?)$').firstMatch(trimmed);
  var pathPart = trimmed;
  var suffix = '';
  if (globMatch != null) {
    suffix = globMatch.group(0)!;
    pathPart = trimmed.substring(0, trimmed.length - suffix.length);
  }

  if (pathPart.isEmpty) {
    return suffix;
  }

  final segments = pathPart
      .split('/')
      .where((segment) => segment.trim().isNotEmpty)
      .toList();
  if (segments.isEmpty) {
    return trimmed;
  }

  final canvasWork = segments.first == 'production';
  final inProduction = canvasWork || segments.contains('production');
  final localizedSegments = <String>[
    for (var index = 0; index < segments.length; index++)
      _localizedGlobSegment(
        context,
        segments[index],
        index: index,
        inProduction: inProduction,
        canvasWork: canvasWork,
      ),
  ];
  final separator = pathPart.endsWith('/') ? '/' : '';
  return '/${localizedSegments.join('/')}$separator$suffix';
}

Future<String?> resolveEntityDisplayName(
  NovelContentService service,
  String entityType,
  String entityId,
) async {
  final trimmedId = entityId.trim();
  if (trimmedId.isEmpty) {
    return null;
  }

  switch (entityType) {
    case entityTypeCharacter:
      return (await service.getCharacterProfileById(trimmedId))?.name;
    case entityTypeChapter:
      final chapter = await service.getChapterById(trimmedId);
      if (chapter == null || !chapter.isChapter) {
        return null;
      }
      final chapterTitle = (chapter.title ?? '').trim();
      return chapterTitle.isNotEmpty ? chapterTitle : trimmedId;
    case entityTypeForeshadowing:
      return (await service.getForeshadowingById(trimmedId))?.title;
    case entityTypeLocation:
      return (await service.locationsService.getLocationById(trimmedId))?.name;
    case entityTypeFaction:
    case entityTypeSkill:
    case entityTypeItem:
    case entityTypeCreature:
      return (await service.getItemById(trimmedId))?.title;
    default:
      return trimmedId;
  }
}

String _localizedSubResourceTitle(BuildContext context, String title) {
  final match = RegExp(r'^#(\d+)$').firstMatch(title.trim());
  if (match != null) {
    return context.t(
      LocaleKeys.toolBeatIndexFmt,
      namedArgs: {'index': match.group(1)!},
    );
  }
  return title;
}

String _localizedCollection(
  BuildContext context,
  String collection, {
  bool asList = false,
}) {
  final key = switch (collection) {
    'works' => LocaleKeys.toolRunNovel,
    'story_state' => LocaleKeys.toolStoryState,
    '_schema' => LocaleKeys.toolSchema,
    'screenplay' => LocaleKeys.screenplayScript,
    'seasons' => LocaleKeys.screenplaySeasons,
    'episodes' => LocaleKeys.screenplayEpisodes,
    'scenes' => LocaleKeys.screenplayScenes,
    'clips' => LocaleKeys.productionClips,
    'production' => LocaleKeys.toolPathProduction,
    'beats' => LocaleKeys.screenplayBeats,
    'profile' => LocaleKeys.workspaceNovelOverview,
    'canvas' => LocaleKeys.workspaceCanvas,
    'chapters' => LocaleKeys.workspaceChapters,
    'volumes' => LocaleKeys.workspaceVolume,
    'characters' => LocaleKeys.workspaceCharacters,
    'lore' || 'worldbuilding' => LocaleKeys.workspaceLore,
    'outlines' => LocaleKeys.workspaceOutlines,
    'materials' => LocaleKeys.workspaceMaterials,
    'skills' => LocaleKeys.workspaceSkills,
    'items' => LocaleKeys.workspaceItems,
    'factions' => LocaleKeys.workspaceFactions,
    'creatures' => LocaleKeys.workspaceCreatures,
    'foreshadowing' => LocaleKeys.workspaceForeshadowings,
    'relations' => LocaleKeys.workspaceRelations,
    'locations' => LocaleKeys.toolCollectionLocations,
    '.agents/rules' => LocaleKeys.agentRuleTitle,
    _ => null,
  };
  final label = key == null ? collection : context.t(key);
  if (!asList ||
      collection == 'story_state' ||
      collection == '_schema' ||
      collection == 'screenplay' ||
      collection == 'profile') {
    return label;
  }
  return context.t(
    LocaleKeys.toolCollectionListFmt,
    namedArgs: {'collection': label},
  );
}

_ParsedToolPath? _parseToolPath(ParsedPath parsed) {
  if (parsed.collection.isEmpty || !parsed.isValidResourcePath) {
    return null;
  }
  return _ParsedToolPath(
    target: parsed,
    collection: parsed.collection,
    resourceIdOrName: _parsedResourceIdOrName(parsed),
    field: parsed.field,
    queryParameters: parsed.hasId
        ? const <String, String>{}
        : parsed.queryParameters,
  );
}

String? _parsedResourceIdOrName(ParsedPath parsed) {
  if (parsed.id != null) {
    return parsed.id;
  }
  if (parsed.namePath.isEmpty) {
    return null;
  }
  return parsed.namePath.join('/');
}

String _outlineTitleFromNamePath(_ParsedToolPath parsed) =>
    parsed.target.locator('title') ?? '';

bool _isOutlineBeatsPath(_ParsedToolPath parsed) => parsed.target.isOutlineBeat;

String? _outlineBeatTitle(List<OutlineBeatDraft>? beats, String id) {
  final title = beats?.where((beat) => beat.id == id).firstOrNull?.title.trim();
  return title == null || title.isEmpty ? null : title;
}

String? _outlineField(_ParsedToolPath parsed) => parsed.target.field;

const _productionStructuralTokens = {
  'production',
  'canvas',
  'clips',
  'settings',
  'nodes',
  'edges',
  'generations',
};

const _productionIdParents = {'clips', 'nodes', 'edges', 'generations'};

String? _productionStructuralTail(String path, String? field) {
  final segments = path
      .split('/')
      .where((segment) => segment.trim().isNotEmpty)
      .toList();
  final index = segments.indexOf('production');
  if (index <= 0) {
    return null;
  }
  final tail = segments.sublist(index);
  if (field != null && tail.isNotEmpty && tail.last == field) {
    tail.removeLast();
  }
  final structural = <String>[];
  var expectId = false;
  for (final segment in tail) {
    final isStructural = _productionStructuralTokens.contains(segment);
    if (expectId) {
      expectId = false;
      if (!isStructural) {
        continue;
      }
    }
    if (!isStructural) {
      continue;
    }
    structural.add(segment);
    expectId = _productionIdParents.contains(segment);
  }
  if (structural.isEmpty) {
    return null;
  }
  return structural.join('/');
}

String? _productionTokenLabel(
  BuildContext context,
  String token, {
  required bool canvasWork,
}) {
  final key = switch (token) {
    'production' =>
      canvasWork
          ? LocaleKeys.toolPathProduction
          : LocaleKeys.toolPathEpisodeProduction,
    'canvas' => LocaleKeys.productionCanvas,
    'clips' => LocaleKeys.productionClips,
    'settings' => LocaleKeys.toolPathProductionSettings,
    'nodes' => LocaleKeys.toolPathCanvasNodes,
    'edges' => LocaleKeys.toolPathCanvasEdges,
    'generations' => LocaleKeys.toolPathProductionGenerations,
    _ => null,
  };
  if (key == null) {
    return null;
  }
  return context.t(key);
}

List<String> _localizedProductionSegments(
  BuildContext context,
  List<String> segments, {
  required bool canvasWork,
}) {
  final labels = <String>[];
  var expectId = false;
  for (final segment in segments) {
    final structural = _productionTokenLabel(
      context,
      segment,
      canvasWork: canvasWork,
    );
    if (expectId) {
      expectId = false;
      if (structural != null) {
        labels.add(structural);
        expectId = _productionIdParents.contains(segment);
        continue;
      }
      final fieldLabel = _productionFieldLabel(context, segment);
      if (fieldLabel != segment) {
        labels.add(fieldLabel);
      }
      continue;
    }
    if (structural != null) {
      labels.add(structural);
      expectId = _productionIdParents.contains(segment);
      continue;
    }
    labels.add(_productionFieldLabel(context, segment));
  }
  return labels;
}

String _productionFieldLabel(BuildContext context, String field) {
  // kind 在查询芯片里只展示取值；路径字段仍要译出字段名。
  final key = switch (field) {
    'kind' => LocaleKeys.toolFieldKind,
    _ => null,
  };
  if (key != null) {
    return context.t(key);
  }
  return aiToolFieldLabel(context, field);
}

String _localizedGlobSegment(
  BuildContext context,
  String segment, {
  required int index,
  required bool inProduction,
  required bool canvasWork,
}) {
  if (inProduction) {
    final token = _productionTokenLabel(
      context,
      segment,
      canvasWork: canvasWork,
    );
    if (token != null) {
      return token;
    }
  }
  if (index == 0) {
    return _localizedCollection(context, segment);
  }
  return segment;
}

String _localizedSubCollection(BuildContext context, String collection) {
  final parts = collection.split('/');
  if (parts.first == 'production') {
    return _localizedProductionSegments(
      context,
      parts,
      canvasWork: false,
    ).join(' · ');
  }
  final key = switch (collection) {
    'change_logs' => LocaleKeys.historyTitle,
    'beats' => LocaleKeys.toolOutlineBeats,
    'nodes' => LocaleKeys.toolPathCanvasNodes,
    'edges' => LocaleKeys.toolPathCanvasEdges,
    _ => null,
  };
  return key == null ? collection : context.t(key);
}

/// AI 工具界面共用的字段名本地化映射。
///
/// tool_card_descriptor 的 `fieldLabel` 与本文件的路径标签都走这里，避免多份
/// switch 各自维护导致新增字段时漏翻译。未知字段原样返回。
String aiToolFieldLabel(BuildContext context, String field) {
  final key = switch (field) {
    'text' || 'elements' || 'document' => LocaleKeys.historyFieldContent,
    'synopsis' => LocaleKeys.screenplaySynopsis,
    'season_id' => LocaleKeys.screenplaySeasons,
    'episode_id' => LocaleKeys.screenplayEpisodes,
    'scene_id' => LocaleKeys.screenplayScenes,
    'prompt' => LocaleKeys.storyboardPrompt,
    'reference_mode' => LocaleKeys.storyboardMode,
    'duration_ms' => LocaleKeys.storyboardDurationMs,
    'width' => LocaleKeys.storyboardWidth,
    'height' => LocaleKeys.storyboardHeight,
    'fps' => LocaleKeys.storyboardFps,
    'ratio' => LocaleKeys.storyboardRatio,
    'resolution' => LocaleKeys.storyboardResolution,
    'model_id' => LocaleKeys.storyboardModel,
    'location_id' => LocaleKeys.screenplayLocations,
    'character_id' => LocaleKeys.screenplayCharacterName,
    'time_label' => LocaleKeys.screenplayTime,
    'beat_id' => LocaleKeys.screenplayBeats,
    'stage' => LocaleKeys.screenplayStage,
    'cast' => LocaleKeys.screenplayCurrentSceneCharacters,
    'act' => LocaleKeys.screenplayActNumber,
    'chapter_num' => LocaleKeys.workspaceChapters,
    'title' => 'history.field_title',
    'summary' => 'history.field_summary',
    // chapters.brief 与通用 summary 同义，共用「简介」。
    'brief' || 'summary' => 'history.field_summary',
    'content' => 'history.field_content',
    'name' => 'history.field_name',
    'role' => 'history.field_role',
    'gender' => 'history.field_gender',
    'identity' => 'history.field_identity',
    'age' => 'history.field_age',
    'motivation' => 'history.field_motivation',
    'arc' => 'history.field_arc',
    'category' => 'history.field_category',
    'first_appear_chapter_id' => 'history.field_first_appear_chapter_id',
    'setup' => 'history.field_setup',
    'payoff' => 'history.field_payoff',
    'status' => 'history.field_status',
    'current_state' => 'history.field_current_state',
    'tension' => 'history.field_tension',
    'emotion' => LocaleKeys.assetExportFieldKeys['emotion']!,
    'events' => LocaleKeys.workspaceChapterEvents,
    'beats' => 'workspace.outline_timeline_title',
    'description' => 'common.description',
    'outline' => 'common.outline',
    'tags' => 'common.tags',
    'word_count' => 'workspace.word_count_details',
    'author_name' => LocaleKeys.libraryAuthorName,
    'aliases' => LocaleKeys.workspaceCharacterAliasesLabel,
    'biography' => LocaleKeys.workspaceCharacterSummaryLabel,
    'appearance' => LocaleKeys.workspaceCharacterAppearanceLabel,
    'personality' => LocaleKeys.workspaceCharacterPersonalityLabel,
    'behavior_tags' => LocaleKeys.workspaceCharacterBehaviorTagsLabel,
    'avatar_asset_id' => LocaleKeys.workspaceCharacterAvatar,
    'skills' => 'history.field_skills',
    'setup_chapter_id' ||
    'setup_scene_id' => LocaleKeys.workspaceForeshadowSetupPosition,
    'payoff_chapter_id' ||
    'payoff_scene_id' => LocaleKeys.workspaceForeshadowPayoffPosition,
    'type' => LocaleKeys.commonType,
    'parent_id' => 'history.field_parent',
    'volume_id' => LocaleKeys.workspaceVolume,
    'start_chapter_num' => LocaleKeys.workspaceOutlineStartChapter,
    'source_type' => LocaleKeys.toolQuerySourceType,
    'target_type' => LocaleKeys.toolQueryTargetType,
    'relation_type' => LocaleKeys.toolQueryRelationType,
    'proof' => LocaleKeys.relationProof,
    'reason' => LocaleKeys.relationReason,
    'source_id' => 'history.field_resource',
    'target_id' => 'history.field_resource',
    'chapter_id' => LocaleKeys.toolQueryChapterId,
    'ref_type' => LocaleKeys.toolFieldRefType,
    'ref_id' => LocaleKeys.toolFieldRefId,
    'panorama' => LocaleKeys.toolFieldPanorama,
    'image_method' => LocaleKeys.toolFieldImageMethod,
    'group' => LocaleKeys.toolFieldGroup,
    'x' => LocaleKeys.toolFieldX,
    'y' => LocaleKeys.toolFieldY,
    'style_id' || 'style_selection' => LocaleKeys.toolFieldStyle,
    'inputs' => LocaleKeys.toolFieldInputs,
    'adopted_asset_id' => LocaleKeys.toolFieldAdoptedAsset,
    'provider_id' => LocaleKeys.toolFieldProvider,
    'generate_audio' => LocaleKeys.toolFieldGenerateAudio,
    'data' => LocaleKeys.toolFieldData,
    'positions' => LocaleKeys.toolFieldPositions,
    'remove_types' => LocaleKeys.toolFieldRemoveTypes,
    'cancel_requested_at' => LocaleKeys.toolFieldCancelRequestedAt,
    'result_asset_id' => LocaleKeys.toolFieldResultAsset,
    'result_file_path' => LocaleKeys.toolFieldResultFile,
    'result_applied' => LocaleKeys.toolFieldResultApplied,
    _ => '',
  };
  if (key.isEmpty) {
    return field;
  }
  return context.t(key);
}

List<String> _localizedQueryParameters(
  BuildContext context,
  Map<String, String> queryParameters,
) {
  return [
    for (final entry in queryParameters.entries)
      ?_localizedQueryChip(context, entry.key, entry.value),
  ];
}

/// 返回 null 表示这个过滤条件不出 chip。
String? _localizedQueryChip(BuildContext context, String key, String value) {
  switch (key) {
    case 'is_storyboard':
      return switch (value) {
        'true' => context.t(LocaleKeys.storyboardBoard),
        'false' => context.t(LocaleKeys.productionIndependentMedia),
        _ => value,
      };
    // 内部 ID 不给用户看，而单独渲染集合名（「场次 · 分集」）什么也没说明。
    // 解析成功时季/集/场的真实编号由 ordinals 给出，这里直接不出 chip。
    case 'season_id':
    case 'episode_id':
    case 'scene_id':
    case 'beat_id':
      return null;
    case 'chapter_num':
      final number = int.tryParse(value);
      if (number != null) {
        return context.t(
          LocaleKeys.commonChapterNumber,
          namedArgs: {'number': '$number'},
        );
      }
    case 'volume_num':
      final number = int.tryParse(value);
      if (number != null) {
        return context.t(
          LocaleKeys.workspaceVolumeNumber,
          namedArgs: {'number': '$number'},
        );
      }
    case 'title':
    case 'name':
    case 'search':
      return value;
    default:
      final label = aiToolFieldLabel(context, key);
      final localizedValue = _localizedQueryValue(context, key, value);
      if (label == key) {
        return localizedValue;
      }
      return context.t(
        LocaleKeys.toolQueryFilterFmt,
        namedArgs: {'label': label, 'value': localizedValue},
      );
  }
  return value;
}

class _QueryIdentity {
  const _QueryIdentity({
    this.title,
    this.chapterNum,
    this.volumeNum,
    this.remaining = const {},
  });

  final String? title;
  final int? chapterNum;
  final int? volumeNum;
  final Map<String, String> remaining;
}

AiToolResolvedResource? _crossWorkResolvedResource(
  ParsedPath target,
  String? workTitle,
) {
  final parsed = _parseToolPath(target);
  final isUnavailableWork = workTitle == null || workTitle.trim().isEmpty;
  if (parsed == null) {
    return AiToolResolvedResource(
      collection: 'works',
      resourceTitle: '',
      workTitle: workTitle,
      isUnavailableWork: isUnavailableWork,
      showCollection: false,
    );
  }
  return AiToolResolvedResource(
    collection: parsed.collection,
    resourceTitle: '',
    workTitle: workTitle,
    isUnavailableWork: isUnavailableWork,
    isListing: !target.hasId && !target.hasField,
    showCollection: target.collection != 'production',
    labelPath: target.collection == 'production'
        ? target.localDisplayPath
        : null,
    subCollection:
        target.collection == 'relations' &&
            target.resourceSegment == 'change_logs'
        ? 'change_logs'
        : target.collection == 'production'
        ? null
        : _productionStructuralTail(target.localDisplayPath, parsed.field),
    field: target.collection == 'production' ? null : parsed.field,
    queryParameters: parsed.queryParameters,
  );
}

_QueryIdentity _splitIdentityQueryParams(
  String collection,
  Map<String, String> queryParameters,
) {
  final remaining = Map<String, String>.from(queryParameters);
  String? title;
  int? chapterNum;
  int? volumeNum;

  if (collection == 'chapters') {
    final chapterNumRaw = remaining.remove('chapter_num');
    if (chapterNumRaw != null) {
      chapterNum = int.tryParse(chapterNumRaw);
    }
    title = remaining.remove('title');
  } else if (collection == 'volumes') {
    title = remaining.remove('title');
    final volumeNumRaw = remaining.remove('volume_num');
    if (volumeNumRaw != null) {
      volumeNum = int.tryParse(volumeNumRaw);
    }
  } else if (const {
    'characters',
    'foreshadowing',
    'locations',
    'skills',
    'items',
    'factions',
    'creatures',
    'outlines',
    'lore',
    'worldbuilding',
    'materials',
  }.contains(collection)) {
    title = remaining.remove('title') ?? remaining.remove('name');
  }

  return _QueryIdentity(
    title: title,
    chapterNum: chapterNum,
    volumeNum: volumeNum,
    remaining: remaining,
  );
}

Chapter? _findNodeById(List<Chapter> nodes, String id) {
  for (final node in nodes) {
    if (node.id == id) {
      return node;
    }
  }
  return null;
}

AiToolResolvedResource? _resolveChapterQuery(
  List<Chapter> nodes,
  _ParsedToolPath parsed,
) {
  final identity = _splitIdentityQueryParams(
    parsed.collection,
    parsed.queryParameters,
  );
  if (identity.chapterNum == null && identity.title == null) {
    return null;
  }

  final chapters = nodes.where((chapter) {
    return chapter.isChapter;
  });
  Chapter? chapter;
  if (identity.chapterNum != null) {
    for (final candidate in chapters) {
      if (candidate.chapterNum == identity.chapterNum) {
        chapter = candidate;
        break;
      }
    }
  }
  if (chapter == null && identity.title != null) {
    final titleLower = identity.title!.toLowerCase();
    for (final candidate in chapters) {
      if ((candidate.title ?? '').toLowerCase() == titleLower) {
        chapter = candidate;
        break;
      }
    }
  }

  if (chapter != null) {
    return _chapterResolvedResource(parsed, chapter, identity.remaining);
  }

  return AiToolResolvedResource(
    collection: parsed.collection,
    resourceTitle: identity.title ?? '',
    chapterNum: identity.chapterNum,
    field: parsed.field,
    queryParameters: identity.remaining,
  );
}

AiToolResolvedResource? _resolveVolumeQuery(
  List<Chapter> nodes,
  _ParsedToolPath parsed,
) {
  final identity = _splitIdentityQueryParams(
    parsed.collection,
    parsed.queryParameters,
  );
  if (identity.title == null && identity.volumeNum == null) {
    return null;
  }

  final volumes = nodes.where((node) {
    return node.isVolume;
  });
  Chapter? volume;
  if (identity.volumeNum != null) {
    for (final candidate in volumes) {
      if (candidate.volumeNum == identity.volumeNum) {
        volume = candidate;
        break;
      }
    }
  }
  if (volume == null && identity.title != null) {
    final titleLower = identity.title!.toLowerCase();
    for (final candidate in volumes) {
      if ((candidate.title ?? '').toLowerCase() == titleLower) {
        volume = candidate;
        break;
      }
    }
  }

  if (volume != null) {
    return _volumeResolvedResource(parsed, volume, identity.remaining);
  }

  return AiToolResolvedResource(
    collection: parsed.collection,
    resourceTitle: identity.title ?? '',
    volumeNum: identity.volumeNum,
    field: parsed.field,
    queryParameters: identity.remaining,
  );
}

AiToolResolvedResource _chapterResolvedResource(
  _ParsedToolPath parsed,
  Chapter chapter, [
  Map<String, String>? queryParameters,
]) {
  final title = (chapter.title ?? '').trim();
  return AiToolResolvedResource(
    collection: parsed.collection,
    resourceTitle: title.isEmpty ? chapter.id : title,
    chapterNum: chapter.isExtra ? null : chapter.chapterNum,
    resourceMeta: chapter.isExtra ? nodeTypeExtra : null,
    field: parsed.field,
    queryParameters: queryParameters ?? parsed.queryParameters,
  );
}

AiToolResolvedResource _volumeResolvedResource(
  _ParsedToolPath parsed,
  Chapter volume, [
  Map<String, String>? queryParameters,
]) {
  final title = (volume.title ?? '').trim();
  return AiToolResolvedResource(
    collection: parsed.collection,
    resourceTitle: title.isEmpty ? volume.id : title,
    volumeNum: volume.volumeNum,
    field: parsed.field,
    queryParameters: queryParameters ?? parsed.queryParameters,
  );
}

String _localizedQueryValue(BuildContext context, String field, String value) {
  switch (field) {
    case 'kind':
      final key = switch (value) {
        'video' => LocaleKeys.editingFilterVideo,
        'image' => LocaleKeys.editingFilterImage,
        'audio' => LocaleKeys.editingFilterAudio,
        _ => null,
      };
      return key == null ? value : context.t(key);
    case 'stage':
      final key = switch (value) {
        'draft' => LocaleKeys.screenplayDraft,
        'final' => LocaleKeys.screenplayFinal,
        _ => null,
      };
      return key == null ? value : context.t(key);
    case 'gender':
      final key = switch (value) {
        'female' => LocaleKeys.characterGenderFemale,
        'male' => LocaleKeys.characterGenderMale,
        'non_binary' => LocaleKeys.characterGenderNonBinary,
        'other' => LocaleKeys.characterGenderOther,
        'unknown' => LocaleKeys.characterGenderUnknown,
        _ => null,
      };
      return key == null ? value : context.t(key);
    case 'role':
      final key = switch (value) {
        'protagonist' => LocaleKeys.characterRoleProtagonist,
        'antagonist' => LocaleKeys.characterRoleAntagonist,
        'supporting' => LocaleKeys.characterRoleSupporting,
        'minor' => LocaleKeys.characterRoleMinor,
        _ => null,
      };
      return key == null ? value : context.t(key);
    case 'source_type':
    case 'target_type':
      return localizeEntityNodeTypeName(context, value);
    case 'relation_type':
      return localizeRelationTypeLabel(context, value);
    default:
      return value;
  }
}

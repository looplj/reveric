// 职责: 按用户选定范围将小说或剧本正文、大纲、设定与素材导出为分层目录或 ZIP。
// 关联文件:
//   lib/shared/services/novel_content.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/widgets/novel_export_form.dart
//   test/shared/services/novel_export_test.dart

import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/novel_content_database.dart'
    show
        ScreenplaySeasonRow,
        ScreenplayEpisodeRow,
        documentTypeLore,
        documentTypeMaterial,
        entityTypeCreature,
        entityTypeFaction,
        entityTypeItem,
        entityTypeSkill,
        notDeletedSentinel;
import '../logger/app_logger.dart';
import '../utils/number_format.dart';
import '../models/chapter.dart';
import '../models/content_kind.dart';
import '../models/screenplay.dart';
import '../models/screenplay_element.dart';
import '../models/screenplay_element_render.dart';
import '../models/character_profile.dart';
import '../models/document.dart';
import '../models/foreshadowing.dart';
import '../models/item.dart';
import '../models/location.dart';
import '../models/novel.dart';
import '../models/outline.dart';
import 'novel_content.dart';

final _log = AppLogger.forModule('NovelExport');

enum NovelExportChapterNumberFormat { chinese, number }

enum NovelExportChapterTitleAlignment { left, center, right }

enum NovelExportScope { outlines, chapter_outlines, settings, materials, body }

enum NovelExportSettingSection {
  worldbuilding,
  characters,
  locations,
  factions,
  creatures,
  items,
  skills,
  foreshadowings,
}

enum NovelExportField {
  author,
  category,
  tags,
  description,
  identity,
  age,
  motivation,
  personality,
  characterArc,
  biography,
  currentState,
  setup,
  payoff,
  chapterCount,
  season,
  episode,
  scene,
  scenes,
  interior,
  exterior,
  interior_exterior,
  cast,
  note,
  untitled_scene,
  unknown_character,
}

class NovelExportLabels {
  const NovelExportLabels({
    required this.sections,
    required this.settingSections,
    required this.fields,
    required this.storyOutline,
    required this.chapterOutline,
    required this.untitled,
    required this.untitledBeat,
    required this.fieldSeparator,
  });

  final Map<NovelExportScope, String> sections;
  final Map<NovelExportSettingSection, String> settingSections;
  final Map<NovelExportField, String> fields;
  final String storyOutline;
  final String chapterOutline;
  final String untitled;
  final String untitledBeat;
  final String fieldSeparator;

  String section(NovelExportScope scope) => sections[scope]!;

  String settingSection(NovelExportSettingSection section) =>
      settingSections[section]!;

  String field(NovelExportField field) => fields[field]!;
}

class NovelExportOptions {
  const NovelExportOptions({
    required this.chapterNumberFormat,
    required this.chapterTitleAlignment,
    required this.labels,
    this.scopes = const <NovelExportScope>{NovelExportScope.body},
  });

  final NovelExportChapterNumberFormat chapterNumberFormat;
  final NovelExportChapterTitleAlignment chapterTitleAlignment;
  final NovelExportLabels labels;
  final Set<NovelExportScope> scopes;

  bool includes(NovelExportScope scope) => scopes.contains(scope);
}

class NovelExportPayload {
  const NovelExportPayload({required this.fileName, required this.content});

  final String fileName;
  final String content;
}

class NovelExportBundleFile {
  const NovelExportBundleFile({
    required this.relativePath,
    required this.content,
  });

  final String relativePath;
  final String content;
}

class NovelExportBundle {
  const NovelExportBundle({
    required this.directoryName,
    required this.directories,
    required this.files,
  });

  final String directoryName;
  final List<String> directories;
  final List<NovelExportBundleFile> files;
}

class NovelExportException implements Exception {
  const NovelExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NovelExportService {
  NovelExportService(
    this._contentService, {
    Future<Directory> Function()? temporaryDirectoryProvider,
  }) : _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory;

  final NovelContentService _contentService;
  final Future<Directory> Function() _temporaryDirectoryProvider;

  Future<NovelExportBundle> buildBundle({
    required Novel novel,
    required NovelExportOptions options,
  }) async {
    if (options.scopes.isEmpty) {
      throw const NovelExportException(
        'At least one export scope is required.',
      );
    }

    final content = await _loadContent(novel, options);
    return _formatBundle(novel: novel, content: content, options: options);
  }

  Future<File> exportToTemporaryZip({
    required Novel novel,
    required NovelExportOptions options,
  }) async {
    final bundle = await buildBundle(novel: novel, options: options);
    final temporaryDirectory = await _temporaryDirectoryProvider();
    final cacheRoot = Directory(
      p.join(temporaryDirectory.path, 'reveric_novel_exports'),
    );
    await cacheRoot.create(recursive: true);
    await _cleanupExpiredExportCache(
      cacheRoot,
      DateTime.now().subtract(const Duration(days: 1)),
    );

    final sessionDirectory = await _createUniqueDirectory(
      cacheRoot,
      DateTime.now().microsecondsSinceEpoch.toString(),
    );
    final zipFile = File(
      p.join(sessionDirectory.path, '${bundle.directoryName}.zip'),
    );
    await _writeBundleZip(bundle: bundle, zipFile: zipFile);
    return zipFile;
  }

  Future<_NovelExportContent> _loadContent(
    Novel novel,
    NovelExportOptions options,
  ) async {
    final isScreenplay = novel.contentKind == contentKindScreenplay;
    final needsChapters =
        options.includes(NovelExportScope.outlines) ||
        options.includes(NovelExportScope.chapter_outlines) ||
        options.includes(NovelExportScope.body);
    final chapters = needsChapters && !isScreenplay
        ? await _contentService.getChapters()
        : const <Chapter>[];
    final outlines =
        !isScreenplay && options.includes(NovelExportScope.outlines)
        ? await _contentService.outlineService.getAll()
        : const <OutlineDraft>[];

    var characters = const <CharacterProfile>[];
    var loreDocuments = const <Document>[];
    var locations = const <Location>[];
    var items = const <Item>[];
    var foreshadowings = const <Foreshadowing>[];
    if (options.includes(NovelExportScope.settings) ||
        (isScreenplay && options.includes(NovelExportScope.body))) {
      characters = await _contentService.getCharacterProfiles();
      locations = await _contentService.locationsService.getLocations();
    }
    if (options.includes(NovelExportScope.settings)) {
      loreDocuments = await _contentService.documentsService.getDocumentsByType(
        documentTypeLore,
      );
      final itemGroups = await Future.wait<List<Item>>([
        _contentService.getItemsByType(entityTypeFaction),
        _contentService.getItemsByType(entityTypeCreature),
        _contentService.getItemsByType(entityTypeItem),
        _contentService.getItemsByType(entityTypeSkill),
      ]);
      items = itemGroups.expand((group) => group).toList(growable: false);
      foreshadowings = await _contentService.getForeshadowings();
    }

    final materials = options.includes(NovelExportScope.materials)
        ? await _contentService.documentsService.getDocumentsByType(
            documentTypeMaterial,
          )
        : const <Document>[];

    return _NovelExportContent(
      screenplay:
          isScreenplay &&
              (options.includes(NovelExportScope.outlines) ||
                  options.includes(NovelExportScope.body))
          ? await _loadScreenplay(options)
          : const [],
      chapters: chapters,
      outlines: outlines,
      characters: characters,
      loreDocuments: loreDocuments,
      locations: locations,
      items: items,
      foreshadowings: foreshadowings,
      materials: materials,
    );
  }

  Future<List<_ScreenplayExportSeason>> _loadScreenplay(
    NovelExportOptions options,
  ) async {
    final dao = _contentService.database.screenplayDao;
    final root = await dao.getRoot();
    if (root == null) {
      throw const NovelExportException('Screenplay content is unavailable.');
    }
    if (root.format != screenplayFormatAsian) {
      throw NovelExportException(
        'Unsupported screenplay format: ${root.format}',
      );
    }
    final result = <_ScreenplayExportSeason>[];
    for (final season in await dao.getSeasons(root.id)) {
      final episodes = <_ScreenplayExportEpisode>[];
      for (final episode in await dao.getEpisodes(season.id)) {
        episodes.add(
          _ScreenplayExportEpisode(
            row: episode,
            cast: options.includes(NovelExportScope.body)
                ? {
                    for (final entry
                        in await dao.watchOutline(episode.id).first)
                      entry.scene.id: entry.characterIds,
                  }
                : const {},
            elements: options.includes(NovelExportScope.body)
                ? await dao.getDocumentElements(episode.id)
                : const [],
            scenes: options.includes(NovelExportScope.outlines)
                ? await dao.getSceneRows(episode.id)
                : const [],
          ),
        );
      }
      result.add(_ScreenplayExportSeason(row: season, episodes: episodes));
    }
    return result;
  }

  Future<Directory> exportToDirectory({
    required Novel novel,
    required NovelExportOptions options,
    required String outputDirectory,
  }) async {
    final directory = Directory(outputDirectory);
    if (!await directory.exists()) {
      throw const NovelExportException('Output directory is unavailable.');
    }

    final bundle = await buildBundle(novel: novel, options: options);
    final exportDirectory = await _createUniqueDirectory(
      directory,
      bundle.directoryName,
    );
    try {
      await _writeBundleDirectory(bundle, exportDirectory);
    } catch (error, stackTrace) {
      _log.error(
        'write export bundle failed directory="${exportDirectory.path}"',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    return exportDirectory;
  }

  static NovelExportPayload formatTxt({
    required String novelTitle,
    required List<Chapter> chapters,
    required NovelExportOptions options,
  }) {
    return _formatTxt(
      novelTitle: novelTitle,
      content: _NovelExportContent(chapters: chapters),
      options: options,
    );
  }

  static NovelExportPayload _formatTxt({
    Novel? novel,
    String? novelTitle,
    required _NovelExportContent content,
    required NovelExportOptions options,
  }) {
    final sections = <String>[];
    final title = (novel?.title ?? novelTitle ?? '').trim();
    if (title.isNotEmpty) {
      sections.add(_alignTitle(title, NovelExportChapterTitleAlignment.center));
    }
    sections.addAll(_formatMetadata(novel, options.labels));
    sections.addAll(_formatBody(content.chapters, options));

    return NovelExportPayload(
      fileName:
          '${_safePathSegment(options.labels.section(NovelExportScope.body))}.txt',
      content: '${sections.join('\n\n')}\n',
    );
  }

  static NovelExportBundle _formatBundle({
    required Novel novel,
    required _NovelExportContent content,
    required NovelExportOptions options,
  }) {
    final builder = _NovelExportBundleBuilder(
      directoryName: _safePathSegment(novel.title),
    );
    if (options.includes(NovelExportScope.body) &&
        novel.contentKind == contentKindScreenplay) {
      _addScreenplayBodyFiles(builder, novel, content, options.labels);
    } else if (options.includes(NovelExportScope.body)) {
      final body = _formatTxt(novel: novel, content: content, options: options);
      builder.addTextFile(
        const <String>[],
        options.labels.section(NovelExportScope.body),
        body.content,
      );
    }
    if (options.includes(NovelExportScope.outlines) &&
        novel.contentKind == contentKindScreenplay) {
      _addScreenplayOutlineFiles(builder, content, options.labels);
    } else if (options.includes(NovelExportScope.outlines)) {
      builder.addDirectory([
        options.labels.section(NovelExportScope.outlines),
        options.labels.storyOutline,
      ]);
      builder.addDirectory([
        options.labels.section(NovelExportScope.outlines),
        options.labels.chapterOutline,
      ]);
      _addOutlineFiles(builder, content, options);
    }
    if (novel.contentKind != contentKindScreenplay &&
        options.includes(NovelExportScope.chapter_outlines)) {
      builder.addTextFile(
        const <String>[],
        options.labels.section(NovelExportScope.chapter_outlines),
        _formatChapterOutlines(novel, content.chapters, options),
      );
    }
    if (options.includes(NovelExportScope.settings)) {
      for (final section in NovelExportSettingSection.values) {
        builder.addDirectory([
          options.labels.section(NovelExportScope.settings),
          options.labels.settingSection(section),
        ]);
      }
      _addSettingFiles(builder, content, options.labels);
    }
    if (options.includes(NovelExportScope.materials)) {
      builder.addDirectory([
        options.labels.section(NovelExportScope.materials),
      ]);
      _addDocumentFiles(
        builder,
        [options.labels.section(NovelExportScope.materials)],
        content.materials,
        options.labels,
      );
    }
    return builder.build();
  }

  static String _screenplayHeading(
    NovelExportLabels labels,
    NovelExportField field,
    int number, [
    String title = '',
  ]) {
    final heading = labels.field(field).replaceAll('{number}', '$number');
    return title.trim().isEmpty ? heading : '$heading ${title.trim()}';
  }

  static void _addScreenplayBodyFiles(
    _NovelExportBundleBuilder builder,
    Novel novel,
    _NovelExportContent content,
    NovelExportLabels labels,
  ) {
    final characterNames = {
      for (final character in content.characters.enabled)
        character.id: character.name,
    };
    final locationNames = {
      for (final location in content.locations.enabled)
        location.id: location.name,
    };
    final root = labels.section(NovelExportScope.body);
    builder.addDirectory([root]);
    for (final season in content.screenplay) {
      final seasonTitle = _screenplayHeading(
        labels,
        NovelExportField.season,
        season.row.seasonNumber,
        season.row.title,
      );
      final sections = <String>[
        if (novel.title.trim().isNotEmpty) novel.title.trim(),
        ..._formatMetadata(novel, labels),
        seasonTitle,
      ];
      for (final episode in season.episodes) {
        sections.add(
          _screenplayHeading(
            labels,
            NovelExportField.episode,
            episode.row.episodeNumber,
            episode.row.title,
          ),
        );
        final text = _formatAsianEpisode(
          episode,
          labels,
          characterNames,
          locationNames,
        );
        if (text.isNotEmpty) {
          sections.add(text);
        }
      }
      builder.addTextFile([root], seasonTitle, sections.join('\n\n'));
    }
  }

  // 排版口径见 screenplay_element_render.dart 的 formatScreenplayElementLines；
  // 这里只补导出专有的场次头（序号 + 出场表）与固定行宽的标题对齐。
  static String _formatAsianEpisode(
    _ScreenplayExportEpisode episode,
    NovelExportLabels labels,
    Map<String, String> characterNames,
    Map<String, String> locationNames,
  ) {
    var sceneNumber = 0;
    String characterName(String id) =>
        characterNames[id] ?? labels.field(NovelExportField.unknown_character);

    List<String> sceneHeading(ScreenplayElement element) {
      sceneNumber++;
      final location =
          locationNames[element.locationId] ??
          labels.field(NovelExportField.untitled_scene);
      final condition = switch (element.interiorExterior) {
        screenplayInterior => labels.field(NovelExportField.interior),
        screenplayExterior => labels.field(NovelExportField.exterior),
        screenplayInteriorExterior => labels.field(
          NovelExportField.interior_exterior,
        ),
        _ => '',
      };
      final conditions = [
        element.timeLabel ?? '',
        condition,
      ].where((value) => value.isNotEmpty).join(' / ');
      final cast = episode.cast[element.sceneId] ?? const <String>[];
      return [
        '$sceneNumber、$location${conditions.isEmpty ? '' : '  $conditions'}',
        if (cast.isNotEmpty)
          '${labels.field(NovelExportField.cast)}${cast.map(characterName).join('、')}',
      ];
    }

    return formatScreenplayElementLines(
      episode.elements,
      characterName: characterName,
      formatNote: (text) => '${labels.field(NovelExportField.note)} $text',
      onSceneHeading: sceneHeading,
      alignTitle: (line, {required centered}) => _alignTitle(
        line,
        centered
            ? NovelExportChapterTitleAlignment.center
            : NovelExportChapterTitleAlignment.right,
      ),
    ).join('\n');
  }

  static void _addScreenplayOutlineFiles(
    _NovelExportBundleBuilder builder,
    _NovelExportContent content,
    NovelExportLabels labels,
  ) {
    final root = labels.section(NovelExportScope.outlines);
    builder.addDirectory([root]);
    for (final season in content.screenplay) {
      final seasonTitle = _screenplayHeading(
        labels,
        NovelExportField.season,
        season.row.seasonNumber,
        season.row.title,
      );
      builder.addDirectory([root, seasonTitle]);
      for (final episode in season.episodes) {
        final episodeTitle = _screenplayHeading(
          labels,
          NovelExportField.episode,
          episode.row.episodeNumber,
          episode.row.title,
        );
        final path = [root, seasonTitle, episodeTitle];
        builder.addDirectory(path);
        if (episode.row.outline.trim().isNotEmpty) {
          builder.addTextFile(
            path,
            labels.storyOutline,
            '$episodeTitle\n\n${episode.row.outline.trim()}',
          );
        }
        for (final (index, scene) in episode.scenes.indexed) {
          if (scene.synopsis.trim().isEmpty) {
            continue;
          }
          final heading = _screenplayHeading(
            labels,
            NovelExportField.scene,
            index + 1,
            scene.title,
          );
          builder.addTextFile(
            [...path, labels.field(NovelExportField.scenes)],
            heading,
            '$heading\n\n${scene.synopsis.trim()}',
          );
        }
      }
    }
  }

  static void _addOutlineFiles(
    _NovelExportBundleBuilder builder,
    _NovelExportContent content,
    NovelExportOptions options,
  ) {
    final labels = options.labels;
    final root = labels.section(NovelExportScope.outlines);
    for (final outline in content.outlines.enabled.sorted) {
      final title = _fallbackTitle(outline.title, labels.untitled);
      builder.addTextFile(
        [root, labels.storyOutline],
        title,
        _formatOutline(outline, labels),
      );
    }

    final volumes = {
      for (final chapter in content.chapters.where((entry) => entry.isVolume))
        chapter.id: chapter,
    };
    for (final chapter in content.chapters) {
      final outline = chapter.outline.trim();
      if (!chapter.isChapter || outline.isEmpty) {
        continue;
      }
      final heading = _chapterHeading(chapter, options.chapterNumberFormat);
      final directories = <String>[root, labels.chapterOutline];
      final volume = volumes[chapter.parentId];
      if (volume != null) {
        directories.add(
          _fallbackTitle(volume.title ?? '', volume.displayTitle),
        );
      }
      builder.addTextFile(directories, heading, '$heading\n\n$outline');
    }
  }

  static void _addSettingFiles(
    _NovelExportBundleBuilder builder,
    _NovelExportContent content,
    NovelExportLabels labels,
  ) {
    final root = labels.section(NovelExportScope.settings);
    _addDocumentFiles(
      builder,
      [root, labels.settingSection(NovelExportSettingSection.worldbuilding)],
      content.loreDocuments,
      labels,
    );
    for (final character in content.characters.enabled.sorted) {
      final title = _fallbackTitle(character.name, labels.untitled);
      builder.addTextFile(
        [root, labels.settingSection(NovelExportSettingSection.characters)],
        title,
        _formatCharacter(character, labels),
      );
    }
    _addLocationFiles(builder, root, content.locations, labels);
    _addItemFiles(
      builder,
      root,
      labels.settingSection(NovelExportSettingSection.factions),
      entityTypeFaction,
      content.items,
      labels,
    );
    _addItemFiles(
      builder,
      root,
      labels.settingSection(NovelExportSettingSection.creatures),
      entityTypeCreature,
      content.items,
      labels,
    );
    _addItemFiles(
      builder,
      root,
      labels.settingSection(NovelExportSettingSection.items),
      entityTypeItem,
      content.items,
      labels,
    );
    _addItemFiles(
      builder,
      root,
      labels.settingSection(NovelExportSettingSection.skills),
      entityTypeSkill,
      content.items,
      labels,
    );
    for (final foreshadowing in content.foreshadowings.enabled.sorted) {
      final title = _fallbackTitle(foreshadowing.title, labels.untitled);
      builder.addTextFile(
        [root, labels.settingSection(NovelExportSettingSection.foreshadowings)],
        title,
        _formatForeshadowing(foreshadowing, labels),
      );
    }
  }

  static void _addDocumentFiles(
    _NovelExportBundleBuilder builder,
    List<String> root,
    List<Document> documents,
    NovelExportLabels labels,
  ) {
    final enabled = documents.enabled.sorted;
    final byId = {for (final document in enabled) document.id: document};
    for (final document in enabled.where((entry) => !entry.isFolder)) {
      final path = _documentPath(document, byId, labels);
      final title = path.last;
      builder.addTextFile(
        [...root, ...path.take(path.length - 1)],
        title,
        _formatDocument(document, title, labels),
      );
    }
  }

  static void _addLocationFiles(
    _NovelExportBundleBuilder builder,
    String root,
    List<Location> locations,
    NovelExportLabels labels,
  ) {
    final enabled = locations.enabled.sorted;
    final byId = {for (final location in enabled) location.id: location};
    for (final location in enabled) {
      final path = _locationPath(location, byId, labels);
      final title = path.last;
      builder.addTextFile(
        [
          root,
          labels.settingSection(NovelExportSettingSection.locations),
          ...path.take(path.length - 1),
        ],
        title,
        _formatLocation(location, title, labels),
      );
    }
  }

  static void _addItemFiles(
    _NovelExportBundleBuilder builder,
    String root,
    String section,
    String type,
    List<Item> items,
    NovelExportLabels labels,
  ) {
    for (final item in items.enabled.sorted.where(
      (entry) => entry.type == type,
    )) {
      final title = _fallbackTitle(item.title, labels.untitled);
      builder.addTextFile([root, section], title, _formatItem(item, labels));
    }
  }

  static List<String> _formatMetadata(Novel? novel, NovelExportLabels labels) {
    if (novel == null) {
      return const <String>[];
    }
    final lines = <String>[];
    _addFieldLine(lines, labels, NovelExportField.author, novel.authorName);
    _addFieldLine(lines, labels, NovelExportField.category, novel.category);
    if (novel.tags.isNotEmpty) {
      _addFieldLine(
        lines,
        labels,
        NovelExportField.tags,
        novel.tags.join(', '),
      );
    }
    _addFieldLine(
      lines,
      labels,
      NovelExportField.description,
      novel.description,
    );
    return lines;
  }

  static String _formatOutline(OutlineDraft outline, NovelExportLabels labels) {
    final buffer = StringBuffer(
      '#### ${_fallbackTitle(outline.title, labels.untitled)}',
    );
    final body = outline.content.trim();
    if (body.isNotEmpty) {
      buffer.write('\n$body');
    }
    final beats =
        outline.beats
            .where((beat) => beat.deletedAt == notDeletedSentinel)
            .toList()
          ..sort((left, right) => left.sortOrder.compareTo(right.sortOrder));
    for (var index = 0; index < beats.length; index++) {
      final beat = beats[index];
      final title = _fallbackTitle(beat.title, labels.untitledBeat);
      buffer.write('\n\n${index + 1}. $title');
      if (beat.chapterCount > 0) {
        buffer.write(
          '\n${labels.field(NovelExportField.chapterCount)}'
          '${labels.fieldSeparator}${beat.chapterCount}',
        );
      }
      final content = beat.content.trim();
      if (content.isNotEmpty) {
        buffer.write('\n$content');
      }
    }
    return buffer.toString();
  }

  static String _formatCharacter(
    CharacterProfile character,
    NovelExportLabels labels,
  ) {
    final lines = <String>[
      '#### ${_fallbackTitle(character.name, labels.untitled)}',
    ];
    _addFieldLine(lines, labels, NovelExportField.identity, character.identity);
    if (character.age.trim().isNotEmpty) {
      _addFieldLine(lines, labels, NovelExportField.age, character.age);
    }
    _addFieldLine(
      lines,
      labels,
      NovelExportField.motivation,
      character.motivation,
    );
    _addFieldLine(
      lines,
      labels,
      NovelExportField.personality,
      character.personality,
    );
    _addFieldLine(lines, labels, NovelExportField.characterArc, character.arc);
    _addFieldLine(
      lines,
      labels,
      NovelExportField.biography,
      character.biography,
    );
    _addFieldLine(
      lines,
      labels,
      NovelExportField.currentState,
      character.description,
    );
    return lines.join('\n');
  }

  static String _formatLocation(
    Location location,
    String title,
    NovelExportLabels labels,
  ) {
    final lines = <String>['#### $title'];
    if (location.tagList.isNotEmpty) {
      _addFieldLine(
        lines,
        labels,
        NovelExportField.tags,
        location.tagList.join(', '),
      );
    }
    _addFieldLine(
      lines,
      labels,
      NovelExportField.description,
      location.description,
    );
    return lines.join('\n');
  }

  static List<String> _locationPath(
    Location location,
    Map<String, Location> byId,
    NovelExportLabels labels,
  ) {
    final path = <String>[];
    final visited = <String>{};
    Location? current = location;
    while (current != null && visited.add(current.id)) {
      path.add(_fallbackTitle(current.name, labels.untitled));
      current = current.parentId == null ? null : byId[current.parentId!];
    }
    return path.reversed.toList(growable: false);
  }

  static String _formatItem(Item item, NovelExportLabels labels) {
    final lines = <String>[
      '#### ${_fallbackTitle(item.title, labels.untitled)}',
    ];
    _addFieldLine(lines, labels, NovelExportField.category, item.category);
    final content = item.content.trim();
    if (content.isNotEmpty) {
      lines.add(content);
    }
    return lines.join('\n');
  }

  static String _formatForeshadowing(
    Foreshadowing foreshadowing,
    NovelExportLabels labels,
  ) {
    final lines = <String>[
      '#### ${_fallbackTitle(foreshadowing.title, labels.untitled)}',
    ];
    _addFieldLine(lines, labels, NovelExportField.setup, foreshadowing.setup);
    _addFieldLine(lines, labels, NovelExportField.payoff, foreshadowing.payoff);
    return lines.join('\n');
  }

  static String _formatDocument(
    Document document,
    String title,
    NovelExportLabels labels,
  ) {
    final lines = <String>['#### $title'];
    _addFieldLine(lines, labels, NovelExportField.category, document.category);
    if (document.tagList.isNotEmpty) {
      _addFieldLine(
        lines,
        labels,
        NovelExportField.tags,
        document.tagList.join(', '),
      );
    }
    final content = document.content.trim();
    if (content.isNotEmpty) {
      lines.add(content);
    }
    return lines.join('\n');
  }

  static List<String> _documentPath(
    Document document,
    Map<String, Document> byId,
    NovelExportLabels labels,
  ) {
    final path = <String>[];
    final visited = <String>{};
    Document? current = document;
    while (current != null && visited.add(current.id)) {
      path.add(_fallbackTitle(current.title, labels.untitled));
      current = current.parentId == null ? null : byId[current.parentId!];
    }
    return path.reversed.toList(growable: false);
  }

  static String _formatChapterOutlines(
    Novel novel,
    List<Chapter> chapters,
    NovelExportOptions options,
  ) {
    final sections = <String>[novel.title.trim()];
    final volumes = {
      for (final chapter in chapters.where((entry) => entry.isVolume))
        chapter.id: chapter,
    };
    String? previousVolumeId;
    for (final chapter in chapters) {
      final outline = chapter.outline.trim();
      if (!chapter.isChapter || outline.isEmpty) {
        continue;
      }
      final volume = volumes[chapter.parentId];
      if (volume != null && volume.id != previousVolumeId) {
        sections.add(_fallbackTitle(volume.title ?? '', volume.displayTitle));
      }
      previousVolumeId = volume?.id;
      sections.add(_chapterHeading(chapter, options.chapterNumberFormat));
      sections.add(outline);
    }
    return '${sections.where((section) => section.isNotEmpty).join('\n\n')}\n';
  }

  static List<String> _formatBody(
    List<Chapter> chapters,
    NovelExportOptions options,
  ) {
    final sections = <String>[];
    for (final chapter in chapters) {
      if (chapter.isVolume) {
        final volumeTitle = chapter.title?.trim() ?? '';
        if (volumeTitle.isNotEmpty) {
          sections.add(
            _alignTitle(volumeTitle, NovelExportChapterTitleAlignment.center),
          );
        }
        continue;
      }
      if (!chapter.isChapter) {
        continue;
      }

      sections.add(
        _alignTitle(
          _chapterHeading(chapter, options.chapterNumberFormat),
          options.chapterTitleAlignment,
        ),
      );
      final content = chapter.content.trimRight();
      if (content.isNotEmpty) {
        sections.add(content);
      }
    }
    return sections;
  }

  static void _addFieldLine(
    List<String> lines,
    NovelExportLabels labels,
    NovelExportField field,
    String value,
  ) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      lines.add('${labels.field(field)}${labels.fieldSeparator}$trimmed');
    }
  }

  static String _fallbackTitle(String value, String fallback) {
    final title = value.trim();
    return title.isEmpty ? fallback : title;
  }

  static String _chapterHeading(
    Chapter chapter,
    NovelExportChapterNumberFormat numberFormat,
  ) {
    final title = chapter.title?.trim() ?? '';
    if (!chapter.isNumberedChapter) {
      return title.isEmpty ? chapter.displayTitle : title;
    }

    final chapterNumber = chapter.chapterNum;
    if (chapterNumber == null) {
      throw StateError('Numbered chapter ${chapter.id} is missing chapterNum.');
    }
    final number = switch (numberFormat) {
      NovelExportChapterNumberFormat.chinese =>
        '第${formatChineseNumber(chapterNumber)}章',
      NovelExportChapterNumberFormat.number => '第$chapterNumber章',
    };
    return title.isEmpty ? number : '$number $title';
  }

  static String _alignTitle(
    String title,
    NovelExportChapterTitleAlignment alignment,
  ) {
    const lineWidth = 40;
    final padding = lineWidth - _displayWidth(title);
    if (padding <= 0) {
      return title;
    }

    return switch (alignment) {
      NovelExportChapterTitleAlignment.left => title,
      NovelExportChapterTitleAlignment.center =>
        '${' ' * (padding ~/ 2)}$title',
      NovelExportChapterTitleAlignment.right => '${' ' * padding}$title',
    };
  }

  static int _displayWidth(String text) {
    return text.runes.fold(0, (width, rune) {
      final isWide =
          rune >= 0x1100 &&
          (rune <= 0x115f ||
              rune == 0x2329 ||
              rune == 0x232a ||
              (rune >= 0x2e80 && rune <= 0xa4cf) ||
              (rune >= 0xac00 && rune <= 0xd7a3) ||
              (rune >= 0xf900 && rune <= 0xfaff) ||
              (rune >= 0xfe10 && rune <= 0xfe19) ||
              (rune >= 0xfe30 && rune <= 0xfe6f) ||
              (rune >= 0xff00 && rune <= 0xff60) ||
              (rune >= 0xffe0 && rune <= 0xffe6));
      return width + (isWide ? 2 : 1);
    });
  }

  static String _safePathSegment(String title) {
    final normalized = title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceFirst(RegExp(r'[. ]+$'), '')
        .trim();
    if (normalized.isEmpty || normalized == '.' || normalized == '..') {
      return 'novel';
    }
    return normalized;
  }
}

Future<void> _writeBundleDirectory(
  NovelExportBundle bundle,
  Directory exportDirectory,
) async {
  await exportDirectory.create(recursive: true);
  for (final relativePath in bundle.directories) {
    await Directory(
      p.joinAll([exportDirectory.path, ...relativePath.split('/')]),
    ).create(recursive: true);
  }
  for (final entry in bundle.files) {
    final file = File(
      p.joinAll([exportDirectory.path, ...entry.relativePath.split('/')]),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.content, flush: true);
  }
}

Future<void> _writeBundleZip({
  required NovelExportBundle bundle,
  required File zipFile,
}) async {
  final stagingParent = Directory(
    '${zipFile.path}.staging-${DateTime.now().microsecondsSinceEpoch}',
  );
  final stagingRoot = Directory(
    p.join(stagingParent.path, bundle.directoryName),
  );
  try {
    await _writeBundleDirectory(bundle, stagingRoot);
    await zipFile.parent.create(recursive: true);
    final sourcePath = stagingRoot.path;
    final outputPath = zipFile.path;
    await Isolate.run(
      () => _createZipFromDirectory(
        sourceDirectoryPath: sourcePath,
        outputPath: outputPath,
      ),
    );
  } catch (error, stackTrace) {
    if (await zipFile.exists()) {
      await zipFile.delete();
    }
    _log.error(
      'write temporary export ZIP failed path="${zipFile.path}"',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  } finally {
    if (await stagingParent.exists()) {
      await stagingParent.delete(recursive: true);
    }
  }
}

void _createZipFromDirectory({
  required String sourceDirectoryPath,
  required String outputPath,
}) {
  final encoder = ZipFileEncoder();
  encoder.create(outputPath);
  try {
    encoder.addDirectorySync(
      Directory(sourceDirectoryPath),
      includeDirName: true,
    );
  } finally {
    encoder.closeSync();
  }
}

Future<void> _cleanupExpiredExportCache(
  Directory cacheRoot,
  DateTime cutoff,
) async {
  await for (final entity in cacheRoot.list(followLinks: false)) {
    try {
      final stat = await entity.stat();
      if (!stat.modified.isBefore(cutoff)) {
        continue;
      }
      if (entity is Directory) {
        await entity.delete(recursive: true);
      } else if (entity is File) {
        await entity.delete();
      } else if (entity is Link) {
        await entity.delete();
      }
    } catch (error) {
      _log.warning(
        'cleanup expired export cache failed path="${entity.path}" error=$error',
      );
    }
  }
}

Future<Directory> _createUniqueDirectory(
  Directory parent,
  String preferredName,
) async {
  var suffix = 1;
  while (true) {
    final name = suffix == 1 ? preferredName : '$preferredName ($suffix)';
    final candidate = Directory(p.join(parent.path, name));
    final entityType = await FileSystemEntity.type(
      candidate.path,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.notFound) {
      return candidate.create(recursive: true);
    }
    suffix++;
  }
}

class _NovelExportBundleBuilder {
  _NovelExportBundleBuilder({required this.directoryName});

  final String directoryName;
  final Set<String> _directories = <String>{};
  final List<NovelExportBundleFile> _files = [];
  final Set<String> _usedPaths = {};

  void addDirectory(List<String> segments) {
    final sanitized = segments
        .map(NovelExportService._safePathSegment)
        .toList(growable: false);
    for (var length = 1; length <= sanitized.length; length++) {
      _directories.add(sanitized.take(length).join('/'));
    }
  }

  void addTextFile(
    List<String> directorySegments,
    String title,
    String content,
  ) {
    final directories = directorySegments
        .map(NovelExportService._safePathSegment)
        .toList(growable: false);
    addDirectory(directories);
    final baseName = NovelExportService._safePathSegment(title);
    var suffix = 1;
    while (true) {
      final fileName = suffix == 1
          ? '$baseName.txt'
          : '$baseName ($suffix).txt';
      final relativePath = [...directories, fileName].join('/');
      if (_usedPaths.add(relativePath.toLowerCase())) {
        _files.add(
          NovelExportBundleFile(
            relativePath: relativePath,
            content: '${content.trimRight()}\n',
          ),
        );
        return;
      }
      suffix++;
    }
  }

  NovelExportBundle build() {
    return NovelExportBundle(
      directoryName: directoryName,
      directories: List<String>.unmodifiable(_directories),
      files: List<NovelExportBundleFile>.unmodifiable(_files),
    );
  }
}

class _NovelExportContent {
  const _NovelExportContent({
    this.screenplay = const [],
    this.chapters = const <Chapter>[],
    this.outlines = const <OutlineDraft>[],
    this.characters = const <CharacterProfile>[],
    this.loreDocuments = const <Document>[],
    this.locations = const <Location>[],
    this.items = const <Item>[],
    this.foreshadowings = const <Foreshadowing>[],
    this.materials = const <Document>[],
  });

  final List<_ScreenplayExportSeason> screenplay;
  final List<Chapter> chapters;
  final List<OutlineDraft> outlines;
  final List<CharacterProfile> characters;
  final List<Document> loreDocuments;
  final List<Location> locations;
  final List<Item> items;
  final List<Foreshadowing> foreshadowings;
  final List<Document> materials;
}

class _ScreenplayExportSeason {
  const _ScreenplayExportSeason({required this.row, required this.episodes});

  final ScreenplaySeasonRow row;
  final List<_ScreenplayExportEpisode> episodes;
}

class _ScreenplayExportEpisode {
  const _ScreenplayExportEpisode({
    required this.row,
    required this.cast,
    required this.elements,
    required this.scenes,
  });

  final ScreenplayEpisodeRow row;
  final Map<String, List<String>> cast;
  final List<ScreenplayElement> elements;
  final List<ScreenplaySceneRecord> scenes;
}

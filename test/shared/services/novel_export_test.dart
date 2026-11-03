// 职责: 验证小说与剧本导出按范围生成分层目录，并保留正文顺序、基础信息与标题格式。
// 关联文件:
//   lib/shared/services/novel_export.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/database/novel_content_database.dart

import 'dart:io';

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_status.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/novel.dart';
import 'package:reveric/shared/models/novel_type.dart';
import 'package:reveric/shared/models/outline.dart';
import 'package:reveric/shared/models/screenplay.dart';
import 'package:reveric/shared/models/screenplay_element.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/novel_export.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'exports chapter headings in tree order with selected numbering and alignment',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'reveric_novel_export_test_',
      );
      addTearDown(() async {
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      final database = NovelContentDatabase(
        '${tempDirectory.path}${Platform.pathSeparator}content.sqlite',
      );
      addTearDown(database.close);
      final now = DateTime(2026);
      await database.chapterDao.upsert(
        ChapterData(
          id: 'volume_1',
          type: nodeTypeVolume,
          siblingOrder: 0,
          title: '第一卷',
          outline: '',
          brief: '',
          content: '',
          wordCount: 0,
          stat: chapterStatDraft,
          embeddingSyncStatus: chapterEmbeddingSyncStatusPending,
          createdAt: now,
          updatedAt: now,
          deletedAt: notDeletedSentinel,
        ),
      );
      await database.chapterDao.upsert(
        ChapterData(
          id: 'chapter_1',
          type: nodeTypeChapter,
          parentId: 'volume_1',
          siblingOrder: 0,
          title: '风起',
          outline: '主角在风暴中做出选择。',
          brief: '',
          content: '第一章正文。',
          wordCount: 5,
          stat: chapterStatDraft,
          embeddingSyncStatus: chapterEmbeddingSyncStatusPending,
          createdAt: now,
          updatedAt: now,
          deletedAt: notDeletedSentinel,
        ),
      );
      await database.chapterDao.upsert(
        ChapterData(
          id: 'chapter_2',
          type: nodeTypeChapter,
          parentId: 'volume_1',
          siblingOrder: 1,
          title: '云涌',
          outline: '',
          brief: '',
          content: '第二章正文。',
          wordCount: 5,
          stat: chapterStatDraft,
          embeddingSyncStatus: chapterEmbeddingSyncStatusPending,
          createdAt: now,
          updatedAt: now,
          deletedAt: notDeletedSentinel,
        ),
      );

      final contentService = NovelContentService(database);
      final outlineId = await contentService.outlineService.createOutline(
        defaultTitle: '主线',
      );
      final outline = await contentService.outlineService.getByDocumentId(
        outlineId,
      );
      await contentService.outlineService.saveOutline(
        outline!.copyWith(
          content: '两个势力围绕古城展开冲突。',
          beats: [
            OutlineBeatDraft(
              id: 'beat_1',
              isNew: true,
              title: '转折',
              content: '主角发现盟友的隐瞒。',
              chapterCount: 2,
            ),
          ],
        ),
      );
      final loreFolderId = await contentService.documentsService.createFolder(
        type: documentTypeLore,
        title: '规则',
      );
      await contentService.documentsService.createDocument(
        type: documentTypeLore,
        parentId: loreFolderId,
        title: '魔法规则',
        content: '使用魔法会消耗记忆。',
      );
      final materialFolderId = await contentService.documentsService
          .createFolder(type: documentTypeMaterial, title: '建筑');
      await contentService.documentsService.createDocument(
        type: documentTypeMaterial,
        parentId: materialFolderId,
        title: '建筑参考',
        content: '古城门与石桥的资料。',
      );
      await contentService.createCharacterProfile(
        name: '林墨',
        identity: '守门人',
        motivation: '守住古城',
        biography: '从边境长大的年轻人。',
      );
      final parentLocationId = await contentService.locationsService
          .createLocation(name: '北境', description: '终年寒冷的北方地区。');
      await contentService.locationsService.createLocation(
        name: '雾城',
        parentId: parentLocationId,
        description: '常年被薄雾包围的古城。',
      );
      await contentService.createItem(
        type: entityTypeFaction,
        title: '白塔议会',
        content: '掌管城内魔法秩序。',
      );
      await contentService.createForeshadowing(
        title: '破损的钥匙',
        setup: '钥匙在雨夜发光。',
        payoff: '它能打开古城地库。',
      );

      final novel = Novel(
        id: 'novel_1',
        title: '测试作品',
        authorName: '山岚',
        description: '一部关于记忆与选择的小说。',
        status: contentStatusInProgress,
        type: novelTypeOriginal,
        contentKind: contentKindNovel,
        wordCount: 10,
        draft: false,
        category: '奇幻',
        tags: const ['冒险', '悬疑'],
        createdAt: now,
        updatedAt: now,
        deletedAt: notDeletedSentinel,
      );
      final service = NovelExportService(
        contentService,
        temporaryDirectoryProvider: () async => tempDirectory,
      );
      final exportDirectory = await service.exportToDirectory(
        novel: novel,
        options: const NovelExportOptions(
          labels: _labels,
          scopes: <NovelExportScope>{
            NovelExportScope.body,
            NovelExportScope.chapter_outlines,
            NovelExportScope.outlines,
            NovelExportScope.settings,
            NovelExportScope.materials,
          },
          chapterNumberFormat: NovelExportChapterNumberFormat.chinese,
          chapterTitleAlignment: NovelExportChapterTitleAlignment.right,
        ),
        outputDirectory: tempDirectory.path,
      );

      expect(exportDirectory.path, endsWith('测试作品'));
      final bodyFile = File(p.join(exportDirectory.path, '正文.txt'));
      expect(await bodyFile.exists(), isTrue);
      final content = await bodyFile.readAsString();
      expect(content, contains('作者：山岚'));
      expect(content, contains('标签：冒险, 悬疑'));
      expect(content, contains('第一卷'));
      expect(content, isNot(contains('第 一章 风起')));
      expect(content, isNot(contains('第 一章')));
      expect(content, contains('第一章 风起'));
      expect(content, contains('第二章 云涌'));
      expect(content.indexOf('第一章 风起'), lessThan(content.indexOf('第二章 云涌')));
      expect(content, contains('                    第一章 风起'));
      expect(content, contains('第一章正文。'));
      expect(content, contains('第二章正文。'));
      expect(content, isNot(contains('两个势力围绕古城')));
      expect(content, isNot(contains('魔法规则')));

      final storyOutline = File(
        p.join(exportDirectory.path, '大纲', '故事大纲', '主线.txt'),
      );
      expect(await storyOutline.exists(), isTrue);
      expect(
        await storyOutline.readAsString(),
        allOf(contains('两个势力围绕古城'), contains('主角发现盟友的隐瞒')),
      );
      final chapterOutline = File(
        p.join(exportDirectory.path, '大纲', '章节提纲', '第一卷', '第一章 风起.txt'),
      );
      expect(await chapterOutline.exists(), isTrue);
      expect(await chapterOutline.readAsString(), contains('主角在风暴中做出选择'));
      final mergedOutlines = await File(
        p.join(exportDirectory.path, '章节大纲.txt'),
      ).readAsString();
      expect(mergedOutlines, '测试作品\n\n第一卷\n\n第一章 风起\n\n主角在风暴中做出选择。\n');

      final expectedSettingFiles = <String>[
        p.join('设定资料', '世界观', '规则', '魔法规则.txt'),
        p.join('设定资料', '角色', '林墨.txt'),
        p.join('设定资料', '地点', '北境.txt'),
        p.join('设定资料', '地点', '北境', '雾城.txt'),
        p.join('设定资料', '势力', '白塔议会.txt'),
        p.join('设定资料', '伏笔', '破损的钥匙.txt'),
        p.join('创作素材', '建筑', '建筑参考.txt'),
      ];
      for (final relativePath in expectedSettingFiles) {
        expect(
          await File(p.join(exportDirectory.path, relativePath)).exists(),
          isTrue,
          reason: relativePath,
        );
      }
      for (final relativePath in <String>[
        p.join('设定资料', '生物'),
        p.join('设定资料', '物品'),
        p.join('设定资料', '技能'),
      ]) {
        expect(
          await Directory(p.join(exportDirectory.path, relativePath)).exists(),
          isTrue,
          reason: relativePath,
        );
      }

      final numberFormat = NovelExportService.formatTxt(
        novelTitle: '测试作品',
        chapters: await NovelContentService(database).getChapters(),
        options: const NovelExportOptions(
          labels: _labels,
          chapterNumberFormat: NovelExportChapterNumberFormat.number,
          chapterTitleAlignment: NovelExportChapterTitleAlignment.left,
        ),
      );
      expect(numberFormat.content, contains('第1章 风起'));
      expect(numberFormat.content, contains('第2章 云涌'));

      final outlineOnly = await service.buildBundle(
        novel: novel,
        options: const NovelExportOptions(
          labels: _labels,
          scopes: <NovelExportScope>{NovelExportScope.outlines},
          chapterNumberFormat: NovelExportChapterNumberFormat.chinese,
          chapterTitleAlignment: NovelExportChapterTitleAlignment.left,
        ),
      );
      expect(
        outlineOnly.files.map((entry) => entry.relativePath),
        containsAll(<String>['大纲/故事大纲/主线.txt', '大纲/章节提纲/第一卷/第一章 风起.txt']),
      );

      final exportCache = Directory(
        p.join(tempDirectory.path, 'reveric_novel_exports'),
      );
      await exportCache.create(recursive: true);
      final expiredCacheFile = File(p.join(exportCache.path, 'expired.zip'));
      await expiredCacheFile.writeAsString('expired');
      await expiredCacheFile.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );

      final archive = await service.exportToTemporaryZip(
        novel: novel,
        options: const NovelExportOptions(
          labels: _labels,
          scopes: <NovelExportScope>{
            NovelExportScope.body,
            NovelExportScope.chapter_outlines,
            NovelExportScope.outlines,
            NovelExportScope.settings,
            NovelExportScope.materials,
          },
          chapterNumberFormat: NovelExportChapterNumberFormat.chinese,
          chapterTitleAlignment: NovelExportChapterTitleAlignment.center,
        ),
      );
      expect(p.basename(archive.path), '测试作品.zip');
      expect(p.isWithin(exportCache.path, archive.path), isTrue);
      expect(await expiredCacheFile.exists(), isFalse);
      final archivePaths = ZipDecoder()
          .decodeBytes(await archive.readAsBytes())
          .files
          .map((entry) => entry.name);
      expect(
        archivePaths,
        containsAll(<String>[
          '测试作品/正文.txt',
          '测试作品/章节大纲.txt',
          '测试作品/大纲/故事大纲/主线.txt',
          '测试作品/大纲/章节提纲/第一卷/第一章 风起.txt',
          '测试作品/设定资料/世界观/规则/魔法规则.txt',
          '测试作品/设定资料/地点/北境/雾城.txt',
          '测试作品/创作素材/建筑/建筑参考.txt',
        ]),
      );
      expect(
        exportCache
            .listSync(recursive: true)
            .where((entry) => entry.path.contains('.staging-')),
        isEmpty,
      );

      final secondExport = await service.exportToDirectory(
        novel: novel,
        options: const NovelExportOptions(
          labels: _labels,
          scopes: <NovelExportScope>{NovelExportScope.body},
          chapterNumberFormat: NovelExportChapterNumberFormat.chinese,
          chapterTitleAlignment: NovelExportChapterTitleAlignment.center,
        ),
        outputDirectory: tempDirectory.path,
      );
      expect(secondExport.path, endsWith('测试作品 (2)'));

      // 插入顺序与章节顺序相反，且空大纲仍占用原有章号。
      await database
          .into(database.chapters)
          .insert(
            ChaptersCompanion.insert(
              id: 'chapter_later',
              type: nodeTypeChapter,
              parentId: const Value('volume_1'),
              siblingOrder: 3,
              title: const Value('归途'),
              outline: const Value('带回真相。'),
            ),
          );
      await database
          .into(database.chapters)
          .insert(
            ChaptersCompanion.insert(
              id: 'chapter_earlier',
              type: nodeTypeChapter,
              parentId: const Value('volume_1'),
              siblingOrder: 2,
              title: const Value('远行'),
              outline: const Value('离开古城。'),
            ),
          );
      const chapterOnlyOptions = NovelExportOptions(
        labels: _labels,
        scopes: {NovelExportScope.chapter_outlines},
        chapterNumberFormat: NovelExportChapterNumberFormat.number,
        chapterTitleAlignment: NovelExportChapterTitleAlignment.left,
      );
      final chapterOnly = await service.buildBundle(
        novel: novel,
        options: chapterOnlyOptions,
      );
      expect(chapterOnly.directories, isEmpty);
      expect(chapterOnly.files.single.relativePath, '章节大纲.txt');
      expect(
        chapterOnly.files.single.content,
        '测试作品\n\n第一卷\n\n第1章 风起\n\n主角在风暴中做出选择。\n\n'
        '第3章 远行\n\n离开古城。\n\n第4章 归途\n\n带回真相。\n',
      );
      final chapterZip = await service.exportToTemporaryZip(
        novel: novel,
        options: chapterOnlyOptions,
      );
      final chapterZipFiles = ZipDecoder()
          .decodeBytes(await chapterZip.readAsBytes())
          .files
          .where((entry) => entry.isFile)
          .toList();
      expect(chapterZipFiles.single.name, '测试作品/章节大纲.txt');
      expect(
        utf8.decode(chapterZipFiles.single.content),
        chapterOnly.files.single.content,
      );

      await expectLater(
        service.buildBundle(
          novel: novel,
          options: const NovelExportOptions(
            labels: _labels,
            scopes: <NovelExportScope>{},
            chapterNumberFormat: NovelExportChapterNumberFormat.chinese,
            chapterTitleAlignment: NovelExportChapterTitleAlignment.center,
          ),
        ),
        throwsA(isA<NovelExportException>()),
      );
    },
  );

  test(
    'exports one script per season with document order, names, notes and hierarchical outlines to directory and ZIP',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'reveric_screenplay_export_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final content = NovelContentService(db);
      final script = ScreenplayService(db);
      final initial = await script.createInitialStructure();
      final root = (await db.screenplayDao.getRoot())!;
      await script.updateSeason(seasonId: initial.seasonId, title: '风起');
      await script.updateEpisode(episodeId: initial.episodeId, title: '重逢');
      await script.updateEpisodeOutline(
        episodeId: initial.episodeId,
        outline: '旧友在雨夜重逢。',
      );
      final characterId = await content.createCharacterProfile(name: '林墨');
      final locationId = await content.locationsService.createLocation(
        name: '茶馆',
      );
      final beatId = await script.createBeat(
        screenplayId: root.id,
        episodeId: initial.episodeId,
        actNumber: 1,
        title: '重逢节拍',
        description: '主角认出了旧友。',
      );
      final sceneId = await script.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
        beatId: beatId,
        locationId: locationId,
        interiorExterior: screenplayInterior,
        timeLabel: '夜',
        title: '茶馆重逢',
        synopsis: '两人在茶馆对话。',
      );
      await script.writeElements(
        sceneId: sceneId,
        elements: [
          const ScreenplayElement(
            type: ScreenplayElementType.action,
            text: '雨打窗棂。',
          ),
          ScreenplayElement(
            type: ScreenplayElementType.character,
            characterId: characterId,
            extension: 'V.O.',
          ),
          const ScreenplayElement(
            type: ScreenplayElementType.parenthetical,
            text: '低声',
          ),
          const ScreenplayElement(
            type: ScreenplayElementType.dialogue,
            text: '好久不见。',
          ),
          const ScreenplayElement(
            type: ScreenplayElementType.note,
            text: '保留停顿',
          ),
          const ScreenplayElement(
            type: ScreenplayElementType.subtitle,
            text: '三年前',
          ),
          const ScreenplayElement(
            type: ScreenplayElementType.transition,
            text: '切至',
          ),
        ],
      );
      final firstSceneId = await script.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
        title: '城门',
        synopsis: '先经过城门。',
      );
      await script.writeElements(
        sceneId: firstSceneId,
        elements: const [
          ScreenplayElement(type: ScreenplayElementType.action, text: '穿过城门。'),
        ],
      );
      await script.moveSceneBefore(firstSceneId, sceneId);
      final deletedScene = await script.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
        synopsis: '不应导出的分场',
      );
      await script.writeElements(
        sceneId: deletedScene,
        elements: const [
          ScreenplayElement(
            type: ScreenplayElementType.action,
            text: '不应导出的正文',
          ),
        ],
      );
      await script.deleteScene(deletedScene);
      final nextEpisode = await script.createEpisode(
        seasonId: initial.seasonId,
        title: '追踪',
      );
      final nextScene = await script.createScene(
        screenplayId: root.id,
        episodeId: nextEpisode,
      );
      await script.writeElements(
        sceneId: nextScene,
        elements: const [
          ScreenplayElement(type: ScreenplayElementType.action, text: '第二集正文'),
        ],
      );
      final secondSeason = await script.createSeason(
        screenplayId: root.id,
        title: '云涌',
      );
      final lastScene = await script.createScene(
        screenplayId: root.id,
        episodeId: secondSeason.episodeId,
      );
      await script.writeElements(
        sceneId: lastScene,
        elements: const [
          ScreenplayElement(type: ScreenplayElementType.action, text: '第二季正文'),
        ],
      );
      final removedSeason = await script.createSeason(
        screenplayId: root.id,
        title: '不应导出的季',
      );
      await script.deleteSeason(removedSeason.seasonId);
      await content.documentsService.createDocument(
        type: documentTypeMaterial,
        title: '参考',
        content: '雨夜素材',
      );
      final now = DateTime(2026);
      final novel = Novel(
        id: 'script',
        title: '雨夜/重逢',
        authorName: '山岚',
        description: '剧本简介',
        status: contentStatusInProgress,
        type: novelTypeOriginal,
        contentKind: contentKindScreenplay,
        wordCount: 0,
        draft: false,
        category: '',
        tags: const [],
        createdAt: now,
        updatedAt: now,
        deletedAt: notDeletedSentinel,
      );
      final labels = NovelExportLabels(
        sections: {..._labels.sections, NovelExportScope.body: '剧本'},
        settingSections: _labels.settingSections,
        fields: {
          ..._labels.fields,
          NovelExportField.interior: '内景',
          NovelExportField.exterior: '外景',
          NovelExportField.interior_exterior: '内外',
          NovelExportField.cast: '出场人物：',
          NovelExportField.note: '注',
          NovelExportField.untitled_scene: '未命名场次',
          NovelExportField.unknown_character: '未知人物',
          NovelExportField.season: '第{number}季',
          NovelExportField.episode: '第{number}集',
          NovelExportField.scene: '第{number}场',
          NovelExportField.scenes: '分场',
        },
        storyOutline: '分集大纲',
        chapterOutline: '章节提纲',
        untitled: '未命名',
        untitledBeat: '未命名节拍',
        fieldSeparator: '：',
      );
      NovelExportOptions options(Set<NovelExportScope> scopes) =>
          NovelExportOptions(
            labels: labels,
            scopes: scopes,
            chapterNumberFormat: NovelExportChapterNumberFormat.chinese,
            chapterTitleAlignment: NovelExportChapterTitleAlignment.center,
          );
      final exporter = NovelExportService(
        content,
        temporaryDirectoryProvider: () async => directory,
      );
      final bodyOnly = await exporter.buildBundle(
        novel: novel,
        options: options({NovelExportScope.body}),
      );
      final bodies = {
        for (final file in bodyOnly.files) file.relativePath: file.content,
      };
      expect(bodies.keys, orderedEquals(['剧本/第1季 风起.txt', '剧本/第2季 云涌.txt']));
      final body = bodies['剧本/第1季 风起.txt']!;
      final secondBody = bodies['剧本/第2季 云涌.txt']!;
      expect(body, isNot(contains('第二季正文')));
      expect(secondBody, contains('第2季 云涌\n\n第1集\n\n1、未命名场次'));
      expect(secondBody, contains('第二季正文'));
      expect(secondBody, contains('作者：山岚'));
      expect(secondBody, isNot(contains('第二集正文')));
      expect(secondBody, isNot(contains('雨打窗棂。')));
      expect(body, contains('作者：山岚'));
      expect(body, contains('剧本简介'));
      expect(body, contains('2、茶馆  夜 / 内景\n出场人物：林墨'));
      expect(
        body,
        contains('△ 雨打窗棂。\n\n林墨（V.O.）：\n    （低声）\n    └ 好久不见。\n\n注 保留停顿'),
      );
      expect(body, contains('\n\n${' ' * 17}三年前\n\n${' ' * 36}切至'));
      expect(body, isNot(contains('INT.')));
      expect(body, isNot(contains('[[保留停顿]]')));
      final ordered = ['第1季 风起', '第1集 重逢', '穿过城门。', '雨打窗棂。', '第2集 追踪', '第二集正文'];
      var cursor = 0;
      for (final value in ordered) {
        final index = body.indexOf(value, cursor);
        expect(index, greaterThanOrEqualTo(cursor), reason: value);
        cursor = index + value.length;
      }
      expect(body, isNot(contains('不应导出')));
      expect(body, isNot(contains(characterId)));
      expect(body, isNot(contains(locationId)));
      final outlineOnly = await exporter.buildBundle(
        novel: novel,
        options: options({NovelExportScope.outlines}),
      );
      final outlines = {
        for (final file in outlineOnly.files) file.relativePath: file.content,
      };
      expect(outlines['大纲/第1季 风起/第1集 重逢/分集大纲.txt'], contains('旧友在雨夜重逢。'));
      expect(outlines['大纲/第1季 风起/第1集 重逢/节拍.txt'], isNull);
      expect(
        outlines['大纲/第1季 风起/第1集 重逢/分场/第2场 茶馆重逢.txt'],
        contains('两人在茶馆对话。'),
      );
      expect(outlines.values.join(), isNot(contains('不应导出')));
      expect(outlines.keys.where((path) => path.startsWith('剧本/')), isEmpty);
      final all = options(NovelExportScope.values.toSet());
      final exported = await exporter.exportToDirectory(
        novel: novel,
        options: all,
        outputDirectory: directory.path,
      );
      expect(p.basename(exported.path), '雨夜_重逢');
      for (final file in bodyOnly.files) {
        expect(
          await File(p.join(exported.path, file.relativePath)).readAsString(),
          file.content,
        );
      }
      expect(
        await File(p.join(exported.path, '设定资料/角色/林墨.txt')).exists(),
        isTrue,
      );
      expect(await File(p.join(exported.path, '创作素材/参考.txt')).exists(), isTrue);
      final zip = await exporter.exportToTemporaryZip(
        novel: novel,
        options: all,
      );
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      for (final file in bodyOnly.files) {
        final zippedBody = archive.files.singleWhere(
          (entry) => entry.name == '雨夜_重逢/${file.relativePath}',
        );
        expect(utf8.decode(zippedBody.content), file.content);
      }
      await (db.update(db.screenplays)
            ..where((table) => table.id.equals(root.id)))
          .write(const ScreenplaysCompanion(format: Value('unsupported')));
      await expectLater(
        exporter.buildBundle(novel: novel, options: all),
        throwsA(
          isA<NovelExportException>().having(
            (error) => error.message,
            'message',
            contains('Unsupported screenplay format'),
          ),
        ),
      );
    },
  );

  test('fails explicitly when a screenplay has no root', () async {
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026);
    final novel = Novel(
      id: 'missing',
      title: 'Missing',
      authorName: '',
      description: '',
      status: contentStatusInProgress,
      type: novelTypeOriginal,
      contentKind: contentKindScreenplay,
      wordCount: 0,
      draft: false,
      category: '',
      tags: const [],
      createdAt: now,
      updatedAt: now,
      deletedAt: notDeletedSentinel,
    );
    await expectLater(
      NovelExportService(NovelContentService(db)).buildBundle(
        novel: novel,
        options: const NovelExportOptions(
          labels: _labels,
          chapterNumberFormat: NovelExportChapterNumberFormat.number,
          chapterTitleAlignment: NovelExportChapterTitleAlignment.left,
        ),
      ),
      throwsA(isA<NovelExportException>()),
    );
  });
}

const _labels = NovelExportLabels(
  sections: <NovelExportScope, String>{
    NovelExportScope.outlines: '大纲',
    NovelExportScope.chapter_outlines: '章节大纲',
    NovelExportScope.settings: '设定资料',
    NovelExportScope.materials: '创作素材',
    NovelExportScope.body: '正文',
  },
  settingSections: <NovelExportSettingSection, String>{
    NovelExportSettingSection.worldbuilding: '世界观',
    NovelExportSettingSection.characters: '角色',
    NovelExportSettingSection.locations: '地点',
    NovelExportSettingSection.factions: '势力',
    NovelExportSettingSection.creatures: '生物',
    NovelExportSettingSection.items: '物品',
    NovelExportSettingSection.skills: '技能',
    NovelExportSettingSection.foreshadowings: '伏笔',
  },
  fields: <NovelExportField, String>{
    NovelExportField.author: '作者',
    NovelExportField.category: '分类',
    NovelExportField.tags: '标签',
    NovelExportField.description: '描述',
    NovelExportField.identity: '身份',
    NovelExportField.age: '年龄',
    NovelExportField.motivation: '动机',
    NovelExportField.personality: '性格',
    NovelExportField.characterArc: '人物弧光',
    NovelExportField.biography: '人物小传',
    NovelExportField.currentState: '当前状态',
    NovelExportField.setup: '铺垫',
    NovelExportField.payoff: '兑现',
    NovelExportField.chapterCount: '预计章节数',
  },
  storyOutline: '故事大纲',
  chapterOutline: '章节提纲',
  untitled: '未命名',
  untitledBeat: '未命名节奏点',
  fieldSeparator: '：',
);

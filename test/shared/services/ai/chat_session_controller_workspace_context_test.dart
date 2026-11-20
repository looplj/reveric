// 职责: 验证聊天工作区路径映射，以及当前查看资源、剧本季集与日期提醒的投递。
// 关联文件:
//   lib/shared/services/ai/chat_session_controller.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/services/canvas_service.dart
//   lib/shared/models/novel_workspace.dart
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/novel_workspace.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/production_view.dart';
import 'package:reveric/shared/services/ai/chat_prompt_builder.dart';
import 'package:reveric/shared/services/ai/chat_session_controller.dart';
import 'package:reveric/shared/services/ai/prompts/ai_prompt_service.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';

import '../../../helpers/novel_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String dbPath;
  late NovelContentDatabase contentDb;
  late NovelContentService contentService;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('current_view_test');
    dbPath = '${tempDir.path}/novel.sqlite';
    contentDb = NovelContentDatabase(dbPath);
    contentService = NovelContentService(contentDb);
    container = ProviderContainer(
      overrides: [
        novelContentDatabaseProvider(dbPath).overrideWithValue(contentDb),
        novelContentServiceProvider(dbPath).overrideWithValue(contentService),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await contentDb.close();
    await tempDir.delete(recursive: true);
  });

  ChatSessionController buildController({
    NovelWorkspaceSection? section,
    String? itemId,
    String? title,
    String novelId = 'test_work',
    String sessionId = 'sess_current_view',
    String contentKind = contentKindNovel,
    AiSessionContext? promptContext,
  }) {
    return ChatSessionController(
      container: container,
      scope: ChatScope(
        activeSessionId: sessionId,
        novel: buildTestNovel(id: novelId, contentKind: contentKind),
        databasePath: dbPath,
        workspaceSection: section,
        workspaceItemId: itemId,
        workspaceTitle: title,
      ),
      host: ChatHost(
        clearComposer: () {},
        focusComposer: () {},
        openModelSelector: () {},
        resetScroll: () {},
        isMounted: () => false,
      ),
      store: DefaultChatComposerStore(),
      promptBuilder: ChatPromptBuilder(),
      availableSubAgents: const [],
      aiPromptService: AiPromptService(),
      promptContext:
          promptContext ??
          const AiSessionContext(databasePath: null, novelName: 'Test Novel'),
    );
  }

  group('workspace path context', () {
    test(
      'canvas context points to production without selected episode',
      () async {
        final view = await buildController(
          contentKind: contentKindCanvas,
          section: NovelWorkspaceSection.storyboard,
          promptContext: const AiSessionContext(contentKind: contentKindCanvas),
        ).resolveCurrentWorkspaceContextForTest();
        expect(view?.path, '/production/canvas');
        expect(view?.episodeId, isNull);
        expect(view?.seasonId, isNull);
      },
    );

    for (final workId in ['', ' \t\n ']) {
      test('rejects a blank work ID ${workId.codeUnits}', () {
        expect(
          () => buildController(
            section: NovelWorkspaceSection.chapters,
            novelId: workId,
            promptContext: const AiSessionContext(
              workId: 'previous_work',
              workspacePath: '/works/previous_work',
            ),
          ),
          throwsArgumentError,
        );
      });
    }

    test('derives the current work root from the shared chat scope', () {
      final controller = buildController(
        section: NovelWorkspaceSection.chapters,
        novelId: 'work_current',
      );

      expect(controller.promptContext.workId, 'work_current');
      expect(controller.scope.novel.id, 'work_current');
      expect(controller.promptContext.workspacePath, '/works/work_current');
    });

    test('replaces a stale workspace path with the current scope', () {
      final controller = buildController(
        section: NovelWorkspaceSection.chapters,
        novelId: 'work_current',
        promptContext: const AiSessionContext(
          workspacePath: '/works/work_explicit',
        ),
      );

      expect(controller.promptContext.workId, 'work_current');
      expect(controller.promptContext.workspacePath, '/works/work_current');
    });
  });

  group('resolveCurrentWorkspaceContextForTest', () {
    test('canvas 存在时把 id 解析成 name 寻址路径', () async {
      final canvasId = await contentService.canvasService.createCanvas(
        name: '时空之图',
      );

      final view = await buildController(
        section: NovelWorkspaceSection.canvas,
        itemId: canvasId,
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNotNull);
      expect(view!.path, '/canvas/时空之图');
      expect(view.title, '时空之图');
    });

    test('canvas 不存在时返回 null（投递 cleared remind）', () async {
      final view = await buildController(
        section: NovelWorkspaceSection.canvas,
        itemId: 'canvas_missing',
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNull);
    });

    test('canvas 软删后返回 null', () async {
      final canvasId = await contentService.canvasService.createCanvas(
        name: '废弃画布',
      );
      await contentService.canvasService.softDeleteCanvas(canvasId);

      final view = await buildController(
        section: NovelWorkspaceSection.canvas,
        itemId: canvasId,
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNull);
    });

    test('maps 选中的 world 映射到 locations 路径', () async {
      final worldId = await contentService.locationsService.createLocation(
        name: '星海大陆',
        type: locationTypeWorld,
      );

      final view = await buildController(
        section: NovelWorkspaceSection.maps,
        itemId: worldId,
        title: '旧标题不应作为真源',
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNotNull);
      expect(view!.path, '/locations/$worldId');
      expect(view.title, '星海大陆');
    });

    test('maps 选中 world 下的子地点时映射到该地点', () async {
      final worldId = await contentService.locationsService.createLocation(
        name: '世界',
        type: locationTypeWorld,
      );
      final cityId = await contentService.locationsService.createLocation(
        name: '城邦',
        type: locationTypeCity,
        parentId: worldId,
      );

      final view = await buildController(
        section: NovelWorkspaceSection.maps,
        itemId: cityId,
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNotNull);
      expect(view!.path, '/locations/$cityId');
      expect(view.title, '城邦');
    });

    test('maps 不接受不属于任何 world 的地点', () async {
      final continentId = await contentService.locationsService.createLocation(
        name: '孤岛大陆',
        type: locationTypeContinent,
      );

      final view = await buildController(
        section: NovelWorkspaceSection.maps,
        itemId: continentId,
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNull);
    });

    test('chapters 选中卷时映射到 /volumes 路径', () async {
      final volumeId = await contentService.createVolume(title: '第一卷');

      final view = await buildController(
        section: NovelWorkspaceSection.chapters,
        itemId: volumeId,
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNotNull);
      expect(view!.path, '/volumes/$volumeId');
      expect(view.title, '第一卷');
    });

    test('chapters 选中章节时保持 /chapters 路径', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 0,
        title: '第一章',
      );

      final view = await buildController(
        section: NovelWorkspaceSection.chapters,
        itemId: chapterId,
        title: '第一章',
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNotNull);
      expect(view!.path, '/chapters/$chapterId');
      expect(view.title, '第一章');
    });

    test('chapters 指向不存在的 id 时返回 null', () async {
      final view = await buildController(
        section: NovelWorkspaceSection.chapters,
        itemId: 'chapter_missing',
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNull);
    });

    test('screenplay outline 选中集时带出集归属（单季不带 season_id）', () async {
      final screenplayService = ScreenplayService(contentDb);
      final initial = await screenplayService.createInitialStructure();
      final episodeId = await screenplayService.createEpisode(
        seasonId: initial.seasonId,
        title: '风暴之夜',
      );

      final view = await buildController(
        section: NovelWorkspaceSection.screenplay_outline,
        itemId: episodeId,
        title: '风暴之夜',
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNotNull);
      expect(view!.path, '/episodes/$episodeId/outline');
      expect(view.episodeId, episodeId);
      expect(view.episodeNumber, 2);
      expect(view.episodeTitle, '风暴之夜');
      expect(view.seasonId, isNull, reason: '单季作品不注入 season_id');
    });

    test('screenplay outline 多季作品带出 season_id', () async {
      final screenplayService = ScreenplayService(contentDb);
      await screenplayService.createInitialStructure();
      final root = await contentDb.screenplayDao.getRoot();
      final season2 = await screenplayService.createSeason(
        screenplayId: root!.id,
      );
      final episodeId = await screenplayService.createEpisode(
        seasonId: season2.seasonId,
      );

      final view = await buildController(
        section: NovelWorkspaceSection.screenplay_outline,
        itemId: episodeId,
        promptContext: AiSessionContext(
          databasePath: null,
          novelName: 'Test Novel',
          hasMultipleSeasons: true,
        ),
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNotNull);
      expect(view!.episodeId, episodeId);
      expect(view.seasonId, season2.seasonId);
    });

    test('screenplay scenes 选中场时经场反查集归属', () async {
      final screenplayService = ScreenplayService(contentDb);
      final initial = await screenplayService.createInitialStructure();
      final root = await contentDb.screenplayDao.getRoot();
      final sceneId = await screenplayService.createScene(
        screenplayId: root!.id,
        episodeId: initial.episodeId,
      );

      final view = await buildController(
        section: NovelWorkspaceSection.screenplay_scenes,
        itemId: sceneId,
      ).resolveCurrentWorkspaceContextForTest();

      expect(view, isNotNull);
      expect(view!.path, '/scenes/$sceneId');
      expect(view.episodeId, initial.episodeId);
      expect(view.episodeNumber, 1);
      expect(view.seasonId, isNull);
    });
  });

  group('buildCurrentWorkspaceContextRemindForTest', () {
    test('section 标签以 path 为准：卷标 volumes 而非 chapters', () {
      const view = CurrentWorkspaceContext(
        section: NovelWorkspaceSection.chapters,
        path: '/volumes/volume_abc',
        title: '第一卷',
      );

      final remind = buildController(
        section: NovelWorkspaceSection.chapters,
        itemId: 'volume_abc',
      ).buildCurrentWorkspaceContextRemindForTest(view);

      expect(remind, contains("section='volumes'"));
      expect(remind, contains("path='/volumes/volume_abc'"));
      expect(remind, contains("hint='Read'"));
      expect(remind, isNot(contains("section='chapters'")));
    });

    test('普通章节保持 section=chapters', () {
      const view = CurrentWorkspaceContext(
        section: NovelWorkspaceSection.chapters,
        path: '/chapters/chapter_abc',
        title: '第一章',
      );

      final remind = buildController(
        section: NovelWorkspaceSection.chapters,
        itemId: 'chapter_abc',
      ).buildCurrentWorkspaceContextRemindForTest(view);

      expect(remind, contains("section='chapters'"));
      expect(remind, contains("path='/chapters/chapter_abc'"));
      expect(remind, contains("hint='Read'"));
    });

    test('剧本属性按需追加：集归属与多季 season_id', () {
      const view = CurrentWorkspaceContext(
        section: NovelWorkspaceSection.screenplay_outline,
        path: '/episodes/episode_abc/outline',
        title: '第一集',
        seasonId: 'season_1',
        episodeId: 'episode_abc',
        episodeNumber: 3,
        episodeTitle: '风暴之夜',
      );

      final remind = buildController(
        section: NovelWorkspaceSection.screenplay_outline,
        itemId: 'episode_abc',
      ).buildCurrentWorkspaceContextRemindForTest(view);

      expect(remind, contains('current_workspace_context'));
      expect(remind, contains("title='第一集'"));
      expect(remind, contains("episode_id='episode_abc'"));
      expect(remind, contains("episode_number='3'"));
      expect(remind, contains("episode_title='风暴之夜'"));
      expect(remind, contains("season_id='season_1'"));
    });

    test('非剧本资源不追加剧本属性', () {
      const view = CurrentWorkspaceContext(
        section: NovelWorkspaceSection.chapters,
        path: '/chapters/chapter_abc',
        title: '第一章',
      );

      final remind = buildController(
        section: NovelWorkspaceSection.chapters,
        itemId: 'chapter_abc',
      ).buildCurrentWorkspaceContextRemindForTest(view);

      expect(remind, isNot(contains('episode_')));
      expect(remind, isNot(contains('season_id')));
    });
  });

  group('current_workspace_context remind', () {
    const sessionId = 'sess_screenplay_context';

    List<AiMessage> reminders() => container
        .read(aiChatSessionProvider(sessionId))
        .messages
        .where(
          (message) => message.content.contains('current_workspace_context'),
        )
        .toList();

    ChatSessionController controller({
      String? seasonId,
      String? episodeId,
      bool multipleSeasons = false,
      NovelWorkspaceSection? section,
      String? itemId,
      String contentKind = contentKindScreenplay,
    }) => buildController(
      sessionId: sessionId,
      section: section,
      itemId: itemId,
      contentKind: contentKind,
      promptContext: AiSessionContext(
        currentSeasonId: seasonId,
        currentEpisodeId: episodeId,
        hasMultipleSeasons: multipleSeasons,
      ),
    );

    setUp(() {
      // 生产 send 持有会话 listener，runtime 在请求期间保活；直接调用提醒链路
      // 的测试也需保留这些实例，避免异步查库时 autoDispose 清掉历史和 Agent。
      final sessionSubscription = container.listen(
        aiChatSessionProvider(sessionId),
        (_, _) {},
      );
      final runtimeSubscription = container.listen(
        aiChatRuntimeProvider(sessionId),
        (_, _) {},
      );
      addTearDown(sessionSubscription.close);
      addTearDown(runtimeSubscription.close);
      container.read(aiChatSessionProvider(sessionId).notifier).markLoaded();
    });

    test('导演台发送真实 staging，切换后更新，关闭后恢复集上下文', () async {
      final initial = await ScreenplayService(
        contentDb,
      ).createInitialStructure();
      await contentDb.screenplayDao.createStaging('stage_a', "庭院与'门廊'");
      await contentDb.screenplayDao.createStaging('stage_b', '室内');
      final subscription = container.listen(
        productionSubpageProvider(dbPath),
        (_, _) {},
      );
      addTearDown(subscription.close);
      final page = container.read(productionSubpageProvider(dbPath).notifier);
      final client = FakeProviderClient();
      final agent = FakeAgent.create(client: client);
      container.read(aiChatRuntimeProvider(sessionId).notifier).agent = agent;
      final chat = controller(
        section: NovelWorkspaceSection.storyboard,
        seasonId: initial.seasonId,
        episodeId: initial.episodeId,
      );
      page.set((label: '旧界面标题', stagingId: 'stage_a'));
      await chat.debugDeliverCurrentContextReminds(sessionId);
      await chat.debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), hasLength(1));
      expect(reminders().single.content, contains("staging_id='stage_a'"));
      expect(reminders().single.content, isNot(contains(' path=')));
      expect(reminders().single.content, contains("hint='Run stagings read'"));
      expect(reminders().single.content, contains("section='stagings'"));
      expect(reminders().single.content, contains("title='庭院与&apos;门廊&apos;'"));
      expect(
        reminders().single.content,
        contains("episode_id='${initial.episodeId}'"),
      );
      await agent.process('调整当前布景').drain<void>();
      expect(
        client.capturedStreamRequests.single.messages.any(
          (message) =>
              message.content.contains("staging_id='stage_a'") &&
              message.content.contains("hint='Run stagings read'"),
        ),
        isTrue,
      );

      page.set((label: '室内', stagingId: 'stage_b'));
      await chat.debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), hasLength(2));
      expect(reminders().last.content, contains("staging_id='stage_b'"));
      expect(reminders().last.content, contains("hint='Run stagings read'"));

      page.set(null);
      await chat.debugDeliverCurrentContextReminds(sessionId);
      await chat.debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), hasLength(3));
      expect(reminders().last.content, isNot(contains('staging_id')));
      expect(reminders().last.content, isNot(contains('/stagings/')));
      expect(reminders().last.content, contains("hint='Read'"));
      expect(reminders().last.content, isNot(contains('Run stagings')));
      expect(
        reminders().last.content,
        contains("episode_id='${initial.episodeId}'"),
      );
    });

    test('失效调度清除旧上下文，不回退到底层片段', () async {
      await contentDb.screenplayDao.createStaging('stage_a', '庭院');
      final subscription = container.listen(
        productionSubpageProvider(dbPath),
        (_, _) {},
      );
      addTearDown(subscription.close);
      container.read(productionSubpageProvider(dbPath).notifier).set((
        label: '庭院',
        stagingId: 'stage_a',
      ));
      final chat = controller(
        section: NovelWorkspaceSection.storyboard,
        itemId: 'underlying_clip',
      );
      await chat.debugDeliverCurrentContextReminds(sessionId);
      expect(reminders().single.content, contains("staging_id='stage_a'"));
      expect(reminders().single.content, isNot(contains('underlying_clip')));
      await (contentDb.update(contentDb.videoStagings)
            ..where((table) => table.id.equals('stage_a')))
          .write(VideoStagingsCompanion(deletedAt: Value(DateTime(2026))));
      await chat.debugDeliverCurrentContextReminds(sessionId);
      await chat.debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), hasLength(2));
      expect(reminders().last.content, contains("status='cleared'"));
      expect(reminders().last.content, isNot(contains(' hint=')));
    });

    test('其它分区和作品不会误带导演台上下文', () async {
      await contentDb.screenplayDao.createStaging('stage_a', '庭院');
      final subscription = container.listen(
        productionSubpageProvider(dbPath),
        (_, _) {},
      );
      addTearDown(subscription.close);
      final page = container.read(productionSubpageProvider(dbPath).notifier);
      page.set((label: '庭院', stagingId: 'stage_a'));
      await controller(
        section: NovelWorkspaceSection.overview,
      ).debugDeliverCurrentContextReminds(sessionId);
      await controller(
        section: NovelWorkspaceSection.storyboard,
        contentKind: contentKindNovel,
      ).debugDeliverCurrentContextReminds(sessionId);
      page.set(null);
      final other = container.listen(
        productionSubpageProvider('another_work'),
        (_, _) {},
      );
      addTearDown(other.close);
      container.read(productionSubpageProvider('another_work').notifier).set((
        label: '庭院',
        stagingId: 'stage_a',
      ));
      await controller(
        section: NovelWorkspaceSection.storyboard,
      ).debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), isEmpty);
    });

    for (final section in [
      null,
      NovelWorkspaceSection.overview,
      NovelWorkspaceSection.screenplay_outline,
      NovelWorkspaceSection.screenplay_script,
      NovelWorkspaceSection.screenplay_scenes,
    ]) {
      test('无具体资源选择也把当前季集送入模型请求 section=$section', () async {
        final service = ScreenplayService(contentDb);
        await service.createInitialStructure();
        final root = await contentDb.screenplayDao.getRoot();
        final season = await service.createSeason(screenplayId: root!.id);
        final episodeId = await service.createEpisode(
          seasonId: season.seasonId,
          title: "风暴与'约定'",
        );
        final client = FakeProviderClient();
        final agent = FakeAgent.create(client: client);
        container.read(aiChatRuntimeProvider(sessionId).notifier).agent = agent;
        final chat = controller(
          section: section,
          seasonId: season.seasonId,
          episodeId: episodeId,
          multipleSeasons: true,
        );

        await chat.debugDeliverCurrentContextReminds(sessionId);
        await agent.process('当前这集有什么内容？').drain<void>();

        final reminder = reminders().single;
        expect(reminder.type, AiMessageType.system_remind);
        expect(reminder.content, contains("season_id='${season.seasonId}'"));
        expect(reminder.content, contains("episode_id='$episodeId'"));
        expect(reminder.content, contains("episode_number='2'"));
        expect(reminder.content, contains("episode_title='风暴与&apos;约定&apos;'"));
        expect(reminder.content, isNot(contains("风暴与'约定'")));
        expect(reminder.content, isNot(contains('scene_id')));
        expect(reminder.content, isNot(contains(' path=')));
        expect(reminder.content, isNot(contains(' section=')));
        final sent = client.capturedStreamRequests.single.messages;
        expect(
          sent.any((message) => message.content == reminder.content),
          isTrue,
        );
        expect(
          sent.indexWhere((message) => message.content == reminder.content),
          lessThan(
            sent.indexWhere((message) => message.content == '当前这集有什么内容？'),
          ),
        );

        // 相同上下文再次发送时不重复追加；重建 controller 不影响去重。
        await controller(
          section: section,
          seasonId: season.seasonId,
          episodeId: episodeId,
          multipleSeasons: true,
        ).debugDeliverCurrentContextReminds(sessionId);
        expect(reminders(), hasLength(1));
      });
    }

    test('资源和季集合成一条提醒，移除资源后不沿用旧路径', () async {
      final initial = await ScreenplayService(
        contentDb,
      ).createInitialStructure();
      final canvasId = await contentService.canvasService.createCanvas(
        name: '故事结构',
      );
      await controller(
        section: NovelWorkspaceSection.canvas,
        itemId: canvasId,
        seasonId: initial.seasonId,
        episodeId: initial.episodeId,
      ).debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), hasLength(1));
      expect(reminders().single.content, contains("path='/canvas/故事结构'"));
      expect(
        reminders().single.content,
        contains("episode_id='${initial.episodeId}'"),
      );

      final withoutResource = controller(
        seasonId: initial.seasonId,
        episodeId: initial.episodeId,
      );
      await withoutResource.debugDeliverCurrentContextReminds(sessionId);
      await withoutResource.debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), hasLength(2));
      expect(
        reminders().last.content,
        contains("episode_id='${initial.episodeId}'"),
      );
      expect(reminders().last.content, isNot(contains(' path=')));
      expect(reminders().last.content, isNot(contains(' title=')));

      // Agent 重建后仍以会话历史为真源，不能靠 runtime 游标决定是否清除。
      container
          .read(aiChatRuntimeProvider(sessionId).notifier)
          .invalidateAgent();
      await controller().debugDeliverCurrentContextReminds(sessionId);
      await controller().debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), hasLength(3));
      expect(
        reminders().last.content,
        "<system-remind type='current_workspace_context' status='cleared' />",
      );
    });

    test('资源路径不变，切换季集仍更新完整上下文', () async {
      final service = ScreenplayService(contentDb);
      final initial = await service.createInitialStructure();
      final root = await contentDb.screenplayDao.getRoot();
      final second = await service.createSeason(screenplayId: root!.id);
      final episodeB = await service.createEpisode(seasonId: second.seasonId);
      final canvasId = await contentService.canvasService.createCanvas(
        name: '共享画布',
      );
      for (final selection in [
        (initial.seasonId, initial.episodeId),
        (second.seasonId, episodeB),
      ]) {
        await controller(
          section: NovelWorkspaceSection.canvas,
          itemId: canvasId,
          seasonId: selection.$1,
          episodeId: selection.$2,
          multipleSeasons: true,
        ).debugDeliverCurrentContextReminds(sessionId);
      }
      expect(reminders(), hasLength(2));
      expect(reminders().last.content, contains("path='/canvas/共享画布'"));
      expect(
        reminders().last.content,
        contains("season_id='${second.seasonId}'"),
      );
      expect(reminders().last.content, contains("episode_id='$episodeB'"));
    });

    test('具体剧本资源的真实归属优先于宿主的旧季集选择', () async {
      final service = ScreenplayService(contentDb);
      final initial = await service.createInitialStructure();
      final root = await contentDb.screenplayDao.getRoot();
      final second = await service.createSeason(screenplayId: root!.id);
      final episodeB = await service.createEpisode(seasonId: second.seasonId);
      await controller(
        section: NovelWorkspaceSection.screenplay_outline,
        itemId: episodeB,
        seasonId: initial.seasonId,
        episodeId: initial.episodeId,
        multipleSeasons: true,
      ).debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), hasLength(1));
      expect(
        reminders().single.content,
        contains("path='/episodes/$episodeB/outline'"),
      );
      expect(
        reminders().single.content,
        contains("season_id='${second.seasonId}'"),
      );
      expect(reminders().single.content, contains("episode_id='$episodeB'"));
      expect(reminders().single.content, isNot(contains(initial.episodeId)));
    });

    for (final section in [
      NovelWorkspaceSection.screenplay_script,
      NovelWorkspaceSection.screenplay_scenes,
    ]) {
      test('所属集已删除时不合并宿主旧季集 section=$section', () async {
        final service = ScreenplayService(contentDb);
        final hostSelection = await service.createInitialStructure();
        final root = await contentDb.screenplayDao.getRoot();
        final resourceSeason = await service.createSeason(
          screenplayId: root!.id,
        );
        final episodeId = await service.createEpisode(
          seasonId: resourceSeason.seasonId,
          title: '资源所属集',
        );
        final resourceId = await service.createScene(
          screenplayId: root.id,
          episodeId: episodeId,
        );
        final chat = controller(
          section: section,
          itemId: resourceId,
          seasonId: hostSelection.seasonId,
          episodeId: hostSelection.episodeId,
          multipleSeasons: true,
        );
        await chat.debugDeliverCurrentContextReminds(sessionId);
        expect(reminders().single.content, contains("episode_id='$episodeId'"));
        expect(
          reminders().single.content,
          contains("season_id='${resourceSeason.seasonId}'"),
        );

        // 构造仅父集失效、子资源仍存在的历史异常数据；service.deleteEpisode
        // 会一并软删子资源，无法覆盖这里需要防御的关联缺失分支。
        await (contentDb.update(
          contentDb.screenplayEpisodes,
        )..where((table) => table.id.equals(episodeId))).write(
          ScreenplayEpisodesCompanion(deletedAt: Value(DateTime(2026))),
        );
        expect(await contentDb.screenplayDao.getEpisode(episodeId), isNull);

        final resolved = await chat.resolveCurrentWorkspaceContextForTest();
        expect(resolved, isNotNull);
        expect(resolved!.path, section.aiResourcePath(itemId: resourceId));
        expect(resolved.episodeId, isNull);
        expect(resolved.episodeNumber, isNull);
        expect(resolved.episodeTitle, isNull);
        expect(resolved.seasonId, isNull);

        await chat.debugDeliverCurrentContextReminds(sessionId);
        expect(reminders(), hasLength(2));
        expect(reminders().last.content, contains("path='${resolved.path}'"));
        expect(reminders().last.content, isNot(contains('episode_')));
        expect(reminders().last.content, isNot(contains('season_id')));
      });
    }

    test('单季只带集信息，A → B → A 重新投递', () async {
      final service = ScreenplayService(contentDb);
      final initial = await service.createInitialStructure();
      final episodeB = await service.createEpisode(seasonId: initial.seasonId);
      for (final episodeId in [
        initial.episodeId,
        episodeB,
        initial.episodeId,
      ]) {
        await controller(
          seasonId: initial.seasonId,
          episodeId: episodeId,
        ).debugDeliverCurrentContextReminds(sessionId);
      }
      expect(reminders(), hasLength(3));
      expect(reminders()[1].content, contains("episode_id='$episodeB'"));
      expect(reminders().last.content, reminders().first.content);
      expect(
        reminders().last.content,
        contains("episode_id='${initial.episodeId}'"),
      );
      expect(reminders().last.content, isNot(contains('season_id')));
    });

    test('切季时不携带上一季残留的集选择', () async {
      final service = ScreenplayService(contentDb);
      final initial = await service.createInitialStructure();
      final root = await contentDb.screenplayDao.getRoot();
      final seasonB = await service.createSeason(screenplayId: root!.id);
      for (final seasonId in [initial.seasonId, seasonB.seasonId]) {
        await controller(
          seasonId: seasonId,
          episodeId: initial.episodeId,
          multipleSeasons: true,
        ).debugDeliverCurrentContextReminds(sessionId);
      }
      expect(reminders(), hasLength(2));
      expect(
        reminders().last.content,
        contains("season_id='${seasonB.seasonId}'"),
      );
      expect(reminders().last.content, isNot(contains('episode_id')));
    });

    test('集被删除后投递 cleared，并且只清除一次', () async {
      final service = ScreenplayService(contentDb);
      final initial = await service.createInitialStructure();
      final episodeId = await service.createEpisode(seasonId: initial.seasonId);
      final chat = controller(seasonId: initial.seasonId, episodeId: episodeId);
      await chat.debugDeliverCurrentContextReminds(sessionId);
      await service.deleteEpisode(episodeId);
      await chat.debugDeliverCurrentContextReminds(sessionId);
      await chat.debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), hasLength(2));
      expect(reminders().last.content, contains("status='cleared'"));
    });

    test('压缩后的回放窗口缺失提醒时重新投递', () async {
      final initial = await ScreenplayService(
        contentDb,
      ).createInitialStructure();
      final chat = controller(
        seasonId: initial.seasonId,
        episodeId: initial.episodeId,
      );
      await chat.debugDeliverCurrentContextReminds(sessionId);
      final notifier = container.read(
        aiChatSessionProvider(sessionId).notifier,
      );
      notifier.addUserMessage('已压缩的上下文', type: AiMessageType.compact_summary);
      final retainedUser = notifier.addUserMessage('继续编辑');
      await chat.debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), hasLength(2));
      expect(reminders().last.content, reminders().first.content);
      final messages = container
          .read(aiChatSessionProvider(sessionId))
          .messages;
      expect(
        messages.indexOf(reminders().last),
        greaterThan(messages.indexOf(retainedUser)),
      );
    });

    test('没有季集或小说不会注入剧本上下文', () async {
      await controller().debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), isEmpty);
      final initial = await ScreenplayService(
        contentDb,
      ).createInitialStructure();
      await controller(
        seasonId: initial.seasonId,
        episodeId: initial.episodeId,
        contentKind: contentKindNovel,
      ).debugDeliverCurrentContextReminds(sessionId);
      expect(reminders(), isEmpty);
      expect(reminders(), isEmpty);
    });
  });

  group('current_date remind', () {
    List<AiMessage> sessionMessages(String sessionId) {
      return container.read(aiChatSessionProvider(sessionId)).messages;
    }

    test('无历史 remind 时投递当日日期 remind', () {
      const sessionId = 'sess_date_fresh';
      final notifier = container.read(
        aiChatSessionProvider(sessionId).notifier,
      );
      notifier.markLoaded();

      buildController(
        section: NovelWorkspaceSection.chapters,
        sessionId: sessionId,
      ).debugDeliverCurrentDateRemind(sessionId);

      final today = currentDateRemindDateString(DateTime.now());
      final reminds = sessionMessages(sessionId)
          .where((message) => message.type == AiMessageType.system_remind)
          .toList();
      expect(reminds, hasLength(1));
      expect(reminds.single.content, buildCurrentDateRemind(today));
    });

    test('已有当日 remind 时不重复投递', () {
      const sessionId = 'sess_date_same_day';
      final notifier = container.read(
        aiChatSessionProvider(sessionId).notifier,
      );
      notifier.markLoaded();
      final today = currentDateRemindDateString(DateTime.now());
      notifier.replaceMessages([
        AiMessage.user(
          id: 'remind_today',
          content: buildCurrentDateRemind(today),
          type: AiMessageType.system_remind,
        ),
        AiMessage.user(id: 'u1', content: '继续写'),
      ]);

      buildController(
        section: NovelWorkspaceSection.chapters,
        sessionId: sessionId,
      ).debugDeliverCurrentDateRemind(sessionId);

      final reminds = sessionMessages(sessionId)
          .where((message) => message.type == AiMessageType.system_remind)
          .toList();
      expect(reminds, hasLength(1), reason: '当天已投过，不得重复注入');
      expect(sessionMessages(sessionId).map((message) => message.id), [
        'remind_today',
        'u1',
      ]);
    });

    test('历史是昨天日期时投今天的', () {
      const sessionId = 'sess_date_stale';
      final notifier = container.read(
        aiChatSessionProvider(sessionId).notifier,
      );
      notifier.markLoaded();
      final yesterday = currentDateRemindDateString(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      notifier.replaceMessages([
        AiMessage.user(
          id: 'remind_yesterday',
          content: buildCurrentDateRemind(yesterday),
          type: AiMessageType.system_remind,
        ),
        AiMessage.user(id: 'u1', content: '继续写'),
      ]);

      buildController(
        section: NovelWorkspaceSection.chapters,
        sessionId: sessionId,
      ).debugDeliverCurrentDateRemind(sessionId);

      final today = currentDateRemindDateString(DateTime.now());
      final reminds = sessionMessages(sessionId)
          .where((message) => message.type == AiMessageType.system_remind)
          .map((message) => message.content)
          .toList();
      expect(reminds, hasLength(2));
      expect(reminds.last, buildCurrentDateRemind(today));
    });
  });
}

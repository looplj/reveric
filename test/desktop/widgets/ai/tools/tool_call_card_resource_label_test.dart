// 职责: 验证工具卡片资源编号、名称、查询范围与中英文标签。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/widgets/ai/tools/tool_resource_resolver.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/relation.json
//   assets/translations/zh-CN/relation.json
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md

import 'dart:async';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/app_config.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/widgets/ai/tools/tool_card_descriptor.dart';
import 'package:reveric/shared/widgets/ai/tools/tool_resource_resolver.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/database/app_database.dart' show AppDatabase;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/models/outline.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  late NovelContentDatabase db;
  late NovelContentService contentService;

  setUp(() {
    rootBundle.clear();
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    contentService = NovelContentService(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('chapter collection labels do not subscribe to the tree', () async {
    var treeReads = 0;
    final container = ProviderContainer.test(
      overrides: [
        chapterTreeProvider('labels').overrideWith((ref) {
          treeReads++;
          return Stream.value(<Chapter>[]);
        }),
        novelContentServiceProvider('labels').overrideWithValue(contentService),
      ],
    );
    for (final path in ['chapters', 'volumes']) {
      final provider = toolResolvedResourceProvider((
        novelId: 'work',
        databasePath: 'labels',
        path: path,
      ));
      final subscription = container.listen(provider, (_, _) {});
      final label = await container.read(provider.future);
      expect(label!.collection, path);
      subscription.close();
    }
    expect(treeReads, 0);
  });

  test(
    'chapter labels ignore body changes but follow rename and numbering',
    () async {
      final stream = StreamController<List<Chapter>>();
      addTearDown(stream.close);
      final container = ProviderContainer.test(
        overrides: [
          chapterTreeProvider('labels').overrideWith((ref) => stream.stream),
          novelContentServiceProvider(
            'labels',
          ).overrideWithValue(contentService),
        ],
      );
      final provider = toolResolvedResourceProvider((
        novelId: 'work',
        databasePath: 'labels',
        path: 'chapters/chapter',
      ));
      var changes = 0;
      container.listen(provider, (_, _) {
        changes++;
      });
      Chapter node(String title, int number, int words) => Chapter.fromViewRow({
        'id': 'chapter',
        'type': nodeTypeChapter,
        'sibling_order': number,
        'chapter_num': number,
        'title': title,
        'word_count': words,
      });
      stream.add([node('Before', 1, 10)]);
      expect((await container.read(provider.future))!.resourceTitle, 'Before');
      final initialChanges = changes;
      stream.add([node('Before', 1, 20)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await container.pump();
      expect(changes, initialChanges);
      stream.add([node('After', 2, 20)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await container.pump();
      final updated = await container.read(provider.future);
      expect(updated!.resourceTitle, 'After');
      expect(updated.chapterNum, 2);
      expect(changes, greaterThan(initialChanges));
      stream.add([]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await container.pump();
      expect((await container.read(provider.future))!.resourceTitle, 'chapter');
    },
  );

  for (final entry in const {
    'skills': 'skill',
    'items': 'item',
    'factions': 'faction',
    'creatures': 'creature',
  }.entries) {
    test(
      '${entry.key} shared tool labels resolve IDs and reject foreign types',
      () async {
        const databasePath = 'item-resource-label-test';
        final id = await contentService.createItem(
          type: entry.value,
          title: '资料标题',
          content: '正文',
        );
        final foreignId = await contentService.createItem(
          type: entry.value == 'skill' ? 'item' : 'skill',
          title: '其他类型标题',
        );
        final container = ProviderContainer(
          overrides: [
            novelContentServiceProvider(
              databasePath,
            ).overrideWithValue(contentService),
          ],
        );
        addTearDown(container.dispose);
        Future<AiToolResolvedResource?> resolve(String path) => container.read(
          toolResolvedResourceProvider((
            novelId: 'current-work',
            databasePath: databasePath,
            path: path,
          )).future,
        );

        final resource = await resolve('${entry.key}/$id/content');
        expect(resource!.resourceTitle, '资料标题');
        expect(resource.field, 'content');
        await contentService.updateItem(
          entryId: id,
          title: '改名后的标题',
          content: '正文',
        );
        container.invalidate(
          toolResolvedResourceProvider((
            novelId: 'current-work',
            databasePath: databasePath,
            path: '${entry.key}/$id/content',
          )),
        );
        expect(
          (await resolve('${entry.key}/$id/content'))!.resourceTitle,
          '改名后的标题',
        );
        expect(
          (await resolve('${entry.key}/$foreignId'))!.resourceTitle,
          foreignId,
        );
        await contentService.deleteItem(id);
        expect((await resolve('${entry.key}/$id'))!.resourceTitle, id);
      },
    );
  }

  test(
    'shared labels distinguish an outline named beats from its beats',
    () async {
      const databasePath = 'reserved-outline-label-test';
      await _seedOutline(
        contentService,
        title: 'beats',
        beats: [
          OutlineBeatDraft(id: 'beat_reserved', title: '关键转折', content: '正文'),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          novelContentServiceProvider(
            databasePath,
          ).overrideWithValue(contentService),
        ],
      );
      addTearDown(container.dispose);
      Future<AiToolResolvedResource?> resolve(String path) => container.read(
        toolResolvedResourceProvider((
          novelId: 'current-work',
          databasePath: databasePath,
          path: path,
        )).future,
      );
      final outline = await resolve('outlines/beats/content');
      expect(outline!.resourceTitle, 'beats');
      expect(outline.subCollection, isNull);
      final beat = await resolve('outlines/beats/beats/beat_reserved/content');
      expect(beat!.resourceTitle, 'beats');
      expect(beat.subResourceTitle, '关键转折');
      expect(beat.field, 'content');
      expect(await resolve('outlines/beats/other/content'), isNull);
    },
  );

  test(
    'shared title resolver uses work ID despite a different stored database path',
    () async {
      const databasePath = 'absolute-resource-label-test';
      final app = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(app.close);
      await app.novelDao.create(
        id: 'current-work',
        title: '当前作品',
        description: '',
        contentDatabasePath: 'novel_workspaces/original-path.sqlite',
      );
      await app.novelDao.create(
        id: 'foreign-work',
        title: '来源作品',
        description: '',
      );
      await _seedOutline(
        contentService,
        beats: [
          OutlineBeatDraft(id: 'stable-beat', title: '关键转折', content: '正文'),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(app),
          novelContentServiceProvider(
            databasePath,
          ).overrideWithValue(contentService),
        ],
      );
      addTearDown(container.dispose);
      Future<AiToolResolvedResource?> resolve(String path) {
        final provider = toolResolvedResourceProvider((
          novelId: 'current-work',
          databasePath: databasePath,
          path: path,
        ));
        final subscription = container.listen(provider, (_, _) {});
        addTearDown(subscription.close);
        return container.read(provider.future);
      }

      const path = 'outlines/主线/beats/stable-beat/content';
      final relative = (await resolve(path))!;
      final absolute = (await resolve('/works/current-work/$path'))!;
      expect(absolute.collection, relative.collection);
      expect(absolute.resourceTitle, relative.resourceTitle);
      expect(absolute.subResourceTitle, '关键转折');
      expect(absolute.field, relative.field);
      final foreign = (await resolve('/works/foreign-work/$path'))!;
      expect(foreign.workTitle, '来源作品');
      expect(foreign.collection, 'outlines');
      expect(foreign.resourceTitle, isEmpty);
      expect(foreign.isUnavailableWork, isFalse);
      final otherContextProvider = toolResolvedResourceProvider((
        novelId: 'another-work',
        databasePath: databasePath,
        path: '/works/current-work/$path',
      ));
      final otherSubscription = container.listen(
        otherContextProvider,
        (_, _) {},
      );
      addTearDown(otherSubscription.close);
      final otherContext = await container.read(otherContextProvider.future);
      expect(otherContext!.workTitle, '当前作品');
      expect(otherContext.resourceTitle, isEmpty);
      // 构思画布默认关闭，路径只在开启时可解析。
      if (ideationCanvasEnabled) {
        final canvas = (await resolve(
          '/works/current-work/canvas/主线/nodes/node_1/content',
        ))!;
        final localCanvas = (await resolve('canvas/主线/nodes/node_1/content'))!;
        expect(canvas.resourceTitle, localCanvas.resourceTitle);
        expect(canvas.subCollection, localCanvas.subCollection);
        expect(canvas.field, localCanvas.field);
      }
    },
  );

  test('outline beat path resolves beat title', () async {
    const databasePath = 'tool-card-resource-label-title-test';
    await _seedOutline(
      contentService,
      beats: [OutlineBeatDraft(id: 'beat_1', title: '关键转折', content: '旧内容')],
    );

    final container = ProviderContainer(
      overrides: [
        novelContentServiceProvider(
          databasePath,
        ).overrideWithValue(contentService),
      ],
    );
    addTearDown(container.dispose);

    final resource = await container.read(
      toolResolvedResourceProvider((
        novelId: 'current-work',
        databasePath: databasePath,
        path: '/outlines/主线/beats/beat_1/content',
      )).future,
    );

    expect(resource, isNotNull);
    expect(resource!.resourceTitle, '主线');
    expect(resource.subCollection, 'beats');
    expect(resource.subResourceTitle, '关键转折');
    expect(resource.field, 'content');
  });

  test(
    'missing outline beat keeps its ID label without guessing order',
    () async {
      const databasePath = 'tool-card-resource-label-index-test';
      await _seedOutline(contentService, beats: const []);

      final container = ProviderContainer(
        overrides: [
          novelContentServiceProvider(
            databasePath,
          ).overrideWithValue(contentService),
        ],
      );
      addTearDown(container.dispose);

      final resource = await container.read(
        toolResolvedResourceProvider((
          novelId: 'current-work',
          databasePath: databasePath,
          path: '/outlines/主线/beats/beat_1/content',
        )).future,
      );

      expect(resource, isNotNull);
      expect(resource!.resourceTitle, '主线');
      expect(resource.subCollection, 'beats');
      expect(resource.subResourceTitle, 'beat_1');
      expect(resource.field, 'content');
    },
  );

  test(
    'chapter query path resolves localized chapter number and title',
    () async {
      const databasePath = 'tool-card-resource-label-chapter-query-test';
      for (var i = 1; i <= 13; i++) {
        await contentService.createChapter(
          siblingOrder: i,
          title: i == 13 ? '庆功宴表白' : '章节 $i',
        );
      }

      final container = ProviderContainer(
        overrides: [
          novelContentServiceProvider(
            databasePath,
          ).overrideWithValue(contentService),
        ],
      );
      final resourceProvider = toolResolvedResourceProvider((
        novelId: 'current-work',
        databasePath: databasePath,
        path: '/chapters?chapter_num=13',
      ));
      final subscription = container.listen(resourceProvider, (_, _) {});
      try {
        final resource = await container.read(resourceProvider.future);

        expect(resource, isNotNull);
        expect(resource!.chapterNum, 13);
        expect(resource.resourceTitle, '庆功宴表白');
        expect(resource.queryParameters, isEmpty);
      } finally {
        subscription.close();
        container.dispose();
      }
    },
  );

  testWidgets('chapter query label avoids raw query parameter text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        final label = const AiToolResolvedResource(
          collection: 'chapters',
          resourceTitle: '',
          chapterNum: 13,
        ).displayLabel(context);
        expect(label, contains('第13章'));
        expect(label, isNot(contains('chapter_num')));
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('outline beat label is localized for users', (tester) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        final label = const AiToolResolvedResource(
          collection: 'outlines',
          resourceTitle: '主线',
          subCollection: 'beats',
          subResourceTitle: '关键转折',
          field: 'content',
        ).displayLabel(context);
        expect(label, contains('大纲'));
        expect(label, contains('主线'));
        expect(label, contains('节拍'));
        expect(label, contains('关键转折'));
        expect(label, contains('内容'));
        expect(label, isNot(contains('beats')));
        final outlineLabel = localizedToolPathLabel(
          context,
          'outlines/beats/content',
        );
        expect(outlineLabel, contains('· beats ·'));
        expect(outlineLabel, isNot(contains('节拍')));
        final beatLabel = localizedToolPathLabel(
          context,
          'outlines/beats/beats/beat_reserved/content',
        );
        expect(beatLabel, contains('· beats ·'));
        expect(beatLabel, contains('节拍'));
        final documentLabel = localizedToolPathLabel(
          context,
          'lore/beats/资料/content',
        );
        expect(documentLabel, contains('beats / 资料'));
        expect(documentLabel, isNot(contains('节拍')));
        for (final historicalPath in [
          'outlines/主线/旧目录/content',
          'canvas/旧画布/nodes/旧节点/未知字段',
        ]) {
          expect(
            localizedToolPathLabel(context, historicalPath),
            historicalPath,
          );
        }
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('outline beat index fallback is localized', (tester) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        final label = const AiToolResolvedResource(
          collection: 'outlines',
          resourceTitle: '主线',
          subCollection: 'beats',
          subResourceTitle: '#1',
          field: 'content',
        ).displayLabel(context);
        expect(label, contains('节拍 #1'));
        expect(label, isNot(contains(' · #1 · ')));
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('relation query chips localize entity and relation types', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        final label = const AiToolResolvedResource(
          collection: 'relations',
          resourceTitle: '',
          queryParameters: {
            'source_type': 'character',
            'relation_type': 'friend',
          },
        ).displayLabel(context);
        expect(label, contains('关系'));
        expect(label, contains('角色'));
        expect(label, isNot(contains('character')));
        expect(label, isNot(contains('friend')));
      }),
    );
    await tester.pumpAndSettle();
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en')]) {
    testWidgets(
      'relation labels hide IDs before and after resolution $locale',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final chinese = locale.languageCode == 'zh';
        final relation = chinese ? '关系' : 'Relations';
        final labels = {
          'relations/relation_internal_id': relation,
          'relations/relation_internal_id/proof':
              '$relation · ${chinese ? '当前依据' : 'Current evidence'}',
          'relations/relation_internal_id/change_logs':
              '$relation · ${chinese ? '修改历史' : 'Change History'}',
          'relations/relation_internal_id/change_logs/rch_internal_id':
              '$relation · ${chinese ? '修改历史' : 'Change History'}',
        };
        final resources = await tester.runAsync(
          () async => {
            for (final path in labels.keys)
              path: await container.read(
                toolResolvedResourceProvider((
                  novelId: 'current-work',
                  databasePath: 'relation-label-test',
                  path: path,
                )).future,
              ),
          },
        );
        await tester.pumpWidget(
          _wrapDescriptorAssertions((context) {
            for (final entry in labels.entries) {
              expect(localizedToolPathLabel(context, entry.key), entry.value);
              expect(
                localizedToolPathLabel(context, '/works/work_id/${entry.key}'),
                '${chinese ? '作品' : 'Novel'} · ${entry.value}',
              );
              final resource = resources![entry.key];
              expect(resource, isNotNull);
              expect(resource!.displayLabel(context), entry.value);
              for (final tool in ['Read', 'Write', 'Edit', 'Remove']) {
                final block = AiToolCallBlock(
                  id: 'relation-label',
                  callId: 'relation-label',
                  toolName: tool,
                  arguments: {'path': entry.key},
                  status: AiToolCallStatus.success,
                );
                for (final resolved in [null, resource]) {
                  expect(toolRowTarget(context, block, resolved), entry.value);
                  expect(
                    toolHeaderSubtitle(context, block, resolved),
                    '${toolActionVerb(context, block)} ${entry.value}',
                  );
                }
              }
            }
          }, locale: locale),
        );
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('glob query path label avoids raw query keys', (tester) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        final label = localizedToolPathLabel(
          context,
          '/chapters?chapter_num=13',
        );
        expect(label, contains('章节'));
        expect(label, contains('第13章'));
        expect(label, isNot(contains('chapter_num')));
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('glob query path label accepts literal percent characters', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        final label = localizedToolPathLabel(
          context,
          '/chapters?search=完成度 50%',
        );
        expect(label, '章节 · 完成度 50%');
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('read collection targets identify listings', (tester) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        for (final entry in {
          '/chapters': '章节列表',
          '/outlines': '大纲列表',
          '/characters': '人物列表',
          '/foreshadowing': '伏笔列表',
          '/locations': '地点列表',
        }.entries) {
          final block = AiToolCallBlock(
            id: 'read_${entry.key}',
            callId: 'call_read_${entry.key}',
            toolName: 'Read',
            arguments: {'path': entry.key},
            status: AiToolCallStatus.success,
          );
          expect(toolRowTarget(context, block, null), entry.value);
          expect(toolHeaderSubtitle(context, block, null), '查看 ${entry.value}');
        }
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('location resource uses a neutral collection label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        final label = const AiToolResolvedResource(
          collection: 'locations',
          resourceTitle: '长梦',
        ).displayLabel(context);
        expect(label, '地点 · 长梦');
        expect(label, isNot(contains('重要')));
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('canvas path labels localize collection and subcollection', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        for (final entry in {
          '/canvas': '画布',
          '/canvas/主线': '画布 · 主线',
          '/canvas/主线/nodes': '画布 · 主线 · 节点',
          '/canvas/主线/edges': '画布 · 主线 · 连线',
          '/canvas/主线/layout': '画布 · 主线 · 布局',
          '/canvas/主线/nodes/node_456': '画布 · 主线 · 节点',
          '/canvas/主线/nodes/node_456/content': '画布 · 主线 · 节点',
          '/canvas/主线/edges/edge_456': '画布 · 主线 · 连线',
        }.entries) {
          expect(
            localizedToolPathLabel(context, entry.key),
            entry.value,
            reason: 'path ${entry.key} should localize to ${entry.value}',
          );
        }
      }),
    );
    await tester.pumpAndSettle();
  }, skip: !ideationCanvasEnabled);

  testWidgets('production paths localize canvas, clips and settings', (
    tester,
  ) async {
    const databasePath = 'production-path-labels';
    final initial = await ScreenplayService(db).createInitialStructure();
    final container = ProviderContainer(
      overrides: [
        novelContentDatabaseProvider(databasePath).overrideWithValue(db),
      ],
    );
    addTearDown(container.dispose);

    Future<AiToolResolvedResource?> readPath(String path) async {
      final provider = toolResolvedResourceProvider((
        novelId: 'current-work',
        databasePath: databasePath,
        path: path,
      ));
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      return container.read(provider.future);
    }

    final canvas = await readPath('/production/canvas');
    final settings = await readPath('/production/settings/style_id');
    final episode = await readPath(
      '/episodes/${initial.episodeId}/production/canvas/nodes/node_1/title',
    );
    expect(canvas?.labelPath, 'production/canvas');
    expect(settings?.labelPath, 'production/settings/style_id');
    expect(episode?.subCollection, 'production/canvas/nodes');
    expect(episode?.field, 'title');

    final labels = {
      const Locale('zh', 'CN'): const {
        '/production': '画布制作',
        '/production/canvas': '画布制作 · 画布',
        '/production/clips': '画布制作 · 片段',
        '/production/settings': '画布制作 · 默认设置',
        '/production/settings/style_id': '画布制作 · 默认设置 · 风格',
        '/production/canvas/nodes/node_1': '画布制作 · 画布 · 节点',
        '/production/canvas/nodes/node_1/title': '画布制作 · 画布 · 节点 · 标题',
        '/production/clips/clip_1/generations/task_1/status':
            '画布制作 · 片段 · 生成记录 · 状态',
        '/episodes/episode_1/production/canvas': '分集 · 制片 · 画布',
        '/works/work_1/production/clips': '作品 · 画布制作 · 片段',
        '/production/canvas/**': '/画布制作/画布/**',
      },
      const Locale('en'): const {
        '/production': 'Canvas production',
        '/production/canvas': 'Canvas production · Canvas',
        '/production/clips': 'Canvas production · Clips',
        '/production/settings': 'Canvas production · Defaults',
        '/production/settings/style_id': 'Canvas production · Defaults · Style',
        '/production/canvas/nodes/node_1': 'Canvas production · Canvas · Nodes',
        '/production/canvas/nodes/node_1/title':
            'Canvas production · Canvas · Nodes · Title',
        '/production/clips/clip_1/generations/task_1/status':
            'Canvas production · Clips · Generations · Status',
        '/episodes/episode_1/production/canvas':
            'Episodes · Production · Canvas',
        '/works/work_1/production/clips': 'Novel · Canvas production · Clips',
        '/production/canvas/**': '/Canvas production/Canvas/**',
      },
    };

    for (final entry in labels.entries) {
      final chinese = entry.key.languageCode == 'zh';
      await tester.pumpWidget(
        _wrapDescriptorAssertions((context) {
          for (final path in entry.value.entries) {
            final label = path.key.endsWith('**')
                ? localizeGlobPattern(context, path.key)
                : localizedToolPathLabel(context, path.key);
            expect(label, path.value, reason: path.key);
          }
          final block = AiToolCallBlock(
            id: 'read_canvas',
            callId: 'read_canvas',
            toolName: 'Read',
            arguments: {'path': '/production/canvas'},
            status: AiToolCallStatus.success,
          );
          expect(
            localizedToolCallTitle(context, block),
            chinese ? '读取' : 'Read',
          );
          expect(
            toolRowTarget(context, block, null),
            chinese ? '画布制作 · 画布' : 'Canvas production · Canvas',
          );
          expect(
            canvas!.displayLabel(context),
            toolRowTarget(context, block, null),
          );
          expect(
            settings!.displayLabel(context),
            chinese
                ? '画布制作 · 默认设置 · 风格'
                : 'Canvas production · Defaults · Style',
          );
          final write = AiToolCallBlock(
            id: 'write_settings',
            callId: 'write_settings',
            toolName: 'Write',
            arguments: {'path': '/production/settings/style_id'},
            status: AiToolCallStatus.success,
          );
          expect(
            toolRowTarget(context, write, settings),
            settings.displayLabel(context),
          );
          expect(
            episode!.displayLabel(context),
            chinese
                ? '第 1 季 · 第 1 集 · 制片 · 画布 · 节点 · 标题'
                : 'Season 1 · Episode 1 · Production · Canvas · Nodes · Title',
          );
          expect(episode.displayLabel(context), isNot(contains('node_1')));
        }, locale: entry.key),
      );
      await tester.pumpAndSettle();
    }
  });

  test(
    'canvas targets expose names and subresources without loading node IDs',
    () async {
      const databasePath = 'tool-card-resource-label-canvas-test';

      final container = ProviderContainer(
        overrides: [
          novelContentServiceProvider(
            databasePath,
          ).overrideWithValue(contentService),
        ],
      );
      addTearDown(container.dispose);

      for (final path in [
        '/canvas',
        '/canvas/主线',
        '/canvas/主线/nodes',
        '/canvas/主线/edges',
        '/canvas/主线/nodes/node_456',
      ]) {
        final resource = await container.read(
          toolResolvedResourceProvider((
            novelId: 'current-work',
            databasePath: databasePath,
            path: path,
          )).future,
        );
        expect(resource?.collection, 'canvas');
        expect(resource?.resourceTitle, path == '/canvas' ? '' : '主线');
        if (path.contains('/nodes')) {
          expect(resource?.subCollection, 'nodes');
        }
        if (path.contains('/edges')) {
          expect(resource?.subCollection, 'edges');
        }
      }
    },
    skip: !ideationCanvasEnabled,
  );

  testWidgets('canvas 操作走通用工具，行标题用画布路径标签', (tester) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        for (final entry in {
          'Create': '/canvas/主线/nodes/node_1',
          'Write': '/canvas/主线/layout',
          'Remove': '/canvas/主线/edges/edge_1',
        }.entries) {
          final block = AiToolCallBlock(
            id: 'block_${entry.key}',
            callId: 'call_${entry.key}',
            toolName: entry.key,
            arguments: {'path': entry.value},
            status: AiToolCallStatus.success,
            targetPath: entry.value,
          );
          final target = toolRowTarget(context, block, null);
          expect(target, isNotNull);
          // 画布名要露出来（用户靠它认是哪张图），内部 id 不能露。
          expect(target, contains('主线'));
          expect(target, isNot(contains('node_1')));
          expect(target, isNot(contains('edge_1')));
        }
      }),
    );
    await tester.pumpAndSettle();
  }, skip: !ideationCanvasEnabled);

  testWidgets('screenplay and cross-work targets localize nested paths', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        const cases = <String, String>{
          '/scenes/scene_1/elements': '场次 · 内容',
          '/episodes/episode_1/outline': '分集 · 大纲',
          '/scenes?episode_id=episode_1': '场次',
          '/works': '作品',
          '/works/work_1/chapters?chapter_num=20': '作品 · 章节 · 第20章',
          '/works/work_1/scenes/scene_1/elements': '作品 · 场次 · 内容',
        };
        for (final entry in cases.entries) {
          expect(localizedToolPathLabel(context, entry.key), entry.value);
        }
        const block = AiToolCallBlock(
          id: 'cross_work_read',
          callId: 'cross_work_read',
          toolName: 'Read',
          arguments: {'path': '/works/work_1/chapters?chapter_num=20'},
          status: AiToolCallStatus.success,
        );
        expect(toolRowTarget(context, block, null), '作品 · 章节列表 · 第20章');
        const resolved = AiToolResolvedResource(
          collection: 'chapters',
          resourceTitle: '',
          workTitle: '来源作品',
          isListing: true,
          queryParameters: {'chapter_num': '20'},
        );
        expect(toolRowTarget(context, block, resolved), '来源作品 · 章节列表 · 第20章');
        const unavailable = AiToolResolvedResource(
          collection: 'chapters',
          resourceTitle: '',
          isUnavailableWork: true,
          isListing: true,
          queryParameters: {'chapter_num': '20'},
        );
        expect(
          toolRowTarget(context, block, unavailable),
          '作品不存在 · 章节列表 · 第20章',
        );
        expect(
          const AiToolResolvedResource(
            collection: 'chapters',
            resourceTitle: '20',
            field: 'chapter_num',
          ).displayLabel(context),
          '章节 · 20 · 章节',
        );
      }),
    );
    await tester.pumpAndSettle();
  });

  test(
    'missing cross-work labels do not query the current content database',
    () async {
      final app = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(app.close);
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(app)],
      );
      addTearDown(container.dispose);
      final provider = toolResolvedResourceProvider((
        novelId: 'current-work',
        databasePath: 'must-not-open-current-work',
        path: '/works/work_1/chapters?chapter_num=20',
      ));
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      final resource = await container.read(provider.future);
      expect(resource, isNotNull);
      expect(resource!.isUnavailableWork, isTrue);
      expect(resource.collection, 'chapters');
      expect(resource.resourceTitle, isEmpty);
    },
  );

  test(
    'screenplay labels resolve real ordinals and preserve query scope',
    () async {
      const databasePath = 'screenplay-resource-labels';
      final service = ScreenplayService(db);
      final initial = await service.createInitialStructure();
      final root = (await db.screenplayDao.getRoot())!;
      final sceneId = await service.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
      );
      final container = ProviderContainer(
        overrides: [
          novelContentDatabaseProvider(databasePath).overrideWithValue(db),
        ],
      );
      addTearDown(container.dispose);
      for (final path in [
        '/scenes/$sceneId',
        'scenes/$sceneId/elements',
        '/scenes/$sceneId/elements/element_unknown/text',
        '/scenes?episode_id=${initial.episodeId}&stage=draft',
        '/clips?episode_id=${initial.episodeId}&is_storyboard=true&kind=video',
        '/clips?scene_id=$sceneId',
        '/episodes/${initial.episodeId}',
        '/seasons/${initial.seasonId}',
      ]) {
        final provider = toolResolvedResourceProvider((
          novelId: 'current-work',
          databasePath: databasePath,
          path: path,
        ));
        final subscription = container.listen(provider, (_, _) {});
        final resource = await container.read(provider.future);
        expect(resource, isNotNull, reason: path);
        expect(resource!.ordinals['screenplay.season'], 1);
        if (!path.startsWith('/seasons')) {
          expect(resource.ordinals['screenplay.episode'], 1);
        }
        expect(resource.resourceTitle, isNot(contains(sceneId)));
        expect(resource.queryParameters, isNot(contains('episode_id')));
        if (path.startsWith('/clips?')) {
          expect(resource.isListing, isTrue);
          if (path.contains('is_storyboard')) {
            expect(resource.queryParameters, {
              'is_storyboard': 'true',
              'kind': 'video',
            });
          } else {
            expect(resource.ordinals['screenplay.scene'], 1);
          }
        }
        if (path.contains('stage=')) {
          expect(resource.isListing, isTrue);
          expect(resource.queryParameters['stage'], 'draft');
        }
        subscription.close();
      }
      final episodeProvider = toolResolvedResourceProvider((
        novelId: 'current-work',
        databasePath: databasePath,
        path: '/episodes/${initial.episodeId}',
      ));
      final updated = Completer<void>();
      final subscription = container.listen(episodeProvider, (_, next) {
        if (next.value?.resourceTitle == '新标题' && !updated.isCompleted) {
          updated.complete();
        }
      });
      await container.read(episodeProvider.future);
      await service.updateEpisode(episodeId: initial.episodeId, title: '新标题');
      await updated.future.timeout(const Duration(seconds: 5));
      subscription.close();
      final missing = await container.read(
        toolResolvedResourceProvider((
          novelId: 'current-work',
          databasePath: databasePath,
          path: '/scenes/missing',
        )).future,
      );
      expect(missing, isNull);
    },
  );

  testWidgets('screenplay and schema summaries hide internal identifiers', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        const resource = AiToolResolvedResource(
          collection: 'scenes',
          resourceTitle: '',
          isListing: true,
          ordinals: {'screenplay.season': 1, 'screenplay.episode': 2},
        );
        const block = AiToolCallBlock(
          id: 'scenes',
          callId: 'scenes',
          toolName: 'Read',
          arguments: {'path': '/scenes?episode_id=episode_internal'},
          status: AiToolCallStatus.success,
        );
        final label = toolRowTarget(context, block, resource)!;
        expect(label, contains('场次列表'));
        expect(label, contains('第 2 集'));
        expect(label, isNot(contains('episode_internal')));
        const clips = AiToolResolvedResource(
          collection: 'clips',
          resourceTitle: '',
          isListing: true,
          ordinals: {'screenplay.season': 1, 'screenplay.episode': 2},
          queryParameters: {'is_storyboard': 'true', 'kind': 'video'},
        );
        final clipsLabel = clips.displayLabel(context);
        expect(clipsLabel, contains('第 2 集'));
        expect(clipsLabel, contains('分镜'));
        expect(clipsLabel, contains('视频'));
        expect(clipsLabel, isNot(contains('true')));
        expect(
          const AiToolResolvedResource(
            collection: 'clips',
            resourceTitle: '',
            isListing: true,
            queryParameters: {'is_storyboard': 'false', 'kind': 'image'},
          ).displayLabel(context),
          contains('独立媒体 · 图片'),
        );

        expect(
          localizedToolPathLabel(
            context,
            '/story_state',
            collectionAsList: true,
          ),
          '故事状态快照',
        );
        expect(localizedToolPathLabel(context, '/_schema/scenes'), '资源说明 · 场次');
        expect(
          localizedToolPathLabel(context, '/_schema/groups/shared'),
          '资源说明 · 共享资料',
        );
        expect(localizedToolPathLabel(context, '/scenes/missing'), '场次');
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets(
    'English resource labels use localized ordinals and schema names',
    (tester) async {
      await tester.pumpWidget(
        _wrapDescriptorAssertions((context) {
          final label = const AiToolResolvedResource(
            collection: 'scenes',
            resourceTitle: '',
            ordinals: {
              'screenplay.season': 1,
              'screenplay.episode': 2,
              'screenplay.scene': 3,
            },
          ).displayLabel(context);
          expect(label, 'Season 1 · Episode 2 · Scene 3');
          expect(
            localizedToolPathLabel(context, '/story_state'),
            'Story state snapshots',
          );
          expect(
            localizedToolPathLabel(context, '/_schema/groups/shared'),
            'Resource reference · Shared resources',
          );
        }, locale: const Locale('en')),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets('read query target remains a listing', (tester) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        const block = AiToolCallBlock(
          id: 'read_chapter_query',
          callId: 'call_read_chapter_query',
          toolName: 'Read',
          arguments: {'path': '/chapters?chapter_num=13'},
          status: AiToolCallStatus.success,
        );
        const resolvedChapter = AiToolResolvedResource(
          collection: 'chapters',
          resourceTitle: '庆功宴表白',
          chapterNum: 13,
        );

        expect(toolRowTarget(context, block, resolvedChapter), '章节列表 · 第13章');
        expect(
          toolHeaderSubtitle(context, block, resolvedChapter),
          '查看 章节列表 · 第13章',
        );
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('read single resource keeps the collection label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        const block = AiToolCallBlock(
          id: 'read_chapter',
          callId: 'call_read_chapter',
          toolName: 'Read',
          arguments: {'path': '/chapters/chapter_1/content'},
          status: AiToolCallStatus.success,
        );
        const resolvedChapter = AiToolResolvedResource(
          collection: 'chapters',
          resourceTitle: '庆功宴表白',
          chapterNum: 13,
          field: 'content',
        );

        expect(
          toolRowTarget(context, block, resolvedChapter),
          '章节 · 第13章 · 庆功宴表白 · 内容',
        );
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('create path label localizes collection name', (tester) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        const block = AiToolCallBlock(
          id: 'create_chapter',
          callId: 'call_create_chapter',
          toolName: 'Create',
          arguments: {
            'path': '/chapters',
            'fields': {'title': '第43章'},
          },
          status: AiToolCallStatus.success,
        );
        expect(toolHeaderSubtitle(context, block, null), '新建 第43章');
        expect(toolRowTarget(context, block, null), '第43章');
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('relation create recognizes absolute work paths', (tester) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        for (final path in [
          '/relations',
          'relations',
          '/works/work_1/relations',
          '/works/work_1/relations/rel_1',
        ]) {
          final block = AiToolCallBlock(
            id: 'create_relation_${path.replaceAll('/', '_')}',
            callId: 'call_create_relation_${path.replaceAll('/', '_')}',
            toolName: 'Create',
            arguments: {
              'path': path,
              'fields': const {
                'source_type': 'character',
                'source_id': 'cha_1',
                'target_type': 'character',
                'target_id': 'cha_2',
                'relation_type': 'enemy',
                'proof': 'test',
              },
            },
            status: AiToolCallStatus.success,
          );
          expect(isRelationCreateBlock(block), isTrue, reason: path);
          expect(
            toolHeaderSubtitle(context, block, null),
            '新建关联 cha_1 → cha_2',
            reason: path,
          );
        }
      }),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('glob pattern localizes collection segments', (tester) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        for (final entry in const {
          '/outlines/**': '/大纲/**',
          '/foreshadowing/*': '/伏笔/*',
          '/outlines/主线/*': '/大纲/主线/*',
          '/outlines/主线*': '/大纲/主线*',
          '/outlines/主线?': '/大纲/主线?',
          '/outlines/*/content': '/大纲/*/content',
          '/outlines/': '/大纲/',
          '/**': '/**',
          '/*': '/*',
          '**': '**',
          '*': '*',
        }.entries) {
          expect(localizeGlobPattern(context, entry.key), entry.value);
        }
      }),
    );
    await tester.pumpAndSettle();
  });

  test('failed not-found tool calls do not use resolved resource labels', () {
    const staleChapterRead = AiToolCallBlock(
      id: 'block_read_missing_chapter',
      callId: 'call_read_missing_chapter',
      toolName: 'Read',
      arguments: {'path': '/chapters/chapter_missing'},
      status: AiToolCallStatus.error,
      result: {
        'error': 'Chapter not found: chapter_missing',
        'error_code': 'not_found',
      },
      errorMessage: 'Chapter not found: chapter_missing',
    );

    expect(shouldUseResolvedResourceForToolCard(staleChapterRead), isFalse);

    const successStatusNotFoundRead = AiToolCallBlock(
      id: 'block_read_missing_chapter_success',
      callId: 'call_read_missing_chapter_success',
      toolName: 'Read',
      arguments: {'path': '/chapters/chapter_missing'},
      status: AiToolCallStatus.success,
      result: {
        'error': 'Chapter not found: chapter_missing',
        'error_code': 'not_found',
      },
    );

    expect(
      shouldUseResolvedResourceForToolCard(successStatusNotFoundRead),
      isFalse,
    );
  });

  test('recoverable edit failures keep resolved resource labels', () {
    const failedEdit = AiToolCallBlock(
      id: 'block_edit_old_text_not_found',
      callId: 'call_edit_old_text_not_found',
      toolName: 'Edit',
      arguments: {'path': '/chapters/chapter_1/content'},
      status: AiToolCallStatus.error,
      result: {
        'error': 'old_text not found',
        'error_code': 'old_text_not_found',
      },
      errorMessage: 'old_text not found',
    );

    expect(shouldUseResolvedResourceForToolCard(failedEdit), isTrue);
  });

  test('tool failure status is only shown in debug mode', () {
    const failedBlock = AiToolCallBlock(
      id: 'failed',
      callId: 'call_failed',
      toolName: 'Read',
      arguments: {'path': '/chapters/1'},
      status: AiToolCallStatus.error,
      errorMessage: 'boom',
    );

    expect(aiDisplayStatus(failedBlock), AiToolCallStatus.error);
    expect(
      shouldShowAiToolStatus(aiDisplayStatus(failedBlock), debugMode: false),
      isFalse,
    );
    expect(
      shouldShowAiToolStatus(aiDisplayStatus(failedBlock), debugMode: true),
      isTrue,
    );
  });

  testWidgets('tool row target uses target-only labels', (tester) async {
    await tester.pumpWidget(
      _wrapDescriptorAssertions((context) {
        const runBlock = AiToolCallBlock(
          id: 'run',
          callId: 'call_run',
          toolName: 'Run',
          arguments: {'command': 'agent-skills', 'subcommand': 'list'},
          status: AiToolCallStatus.success,
        );
        expect(toolRowTarget(context, runBlock, null), isNull);

        const agentRulesCreate = AiToolCallBlock(
          id: 'rules_create',
          callId: 'call_rules_create',
          toolName: 'Run',
          arguments: {
            'command': 'agent-rules',
            'subcommand': 'create',
            'options': {'name': '章节字数', 'content': '4000-5000 字'},
          },
          status: AiToolCallStatus.success,
          result: {'command': 'agent-rules create', 'name': '章节字数'},
        );
        expect(toolRowTarget(context, agentRulesCreate, null), '章节字数');
        expect(
          toolHeaderSubtitle(context, agentRulesCreate, null),
          '创建规则 章节字数',
        );
        expect(localizedToolCallTitle(context, agentRulesCreate), '创建规则');

        const agentRulesList = AiToolCallBlock(
          id: 'rules_list',
          callId: 'call_rules_list',
          toolName: 'Run',
          arguments: {'command': 'agent-rules', 'subcommand': 'list'},
          status: AiToolCallStatus.success,
          result: {
            'command': 'agent-rules list',
            'count': 2,
            'rules': [
              {'name': '章节字数'},
              {'name': '人称'},
            ],
          },
        );
        expect(toolRowTarget(context, agentRulesList, null), '2 条规则');

        const agentRulesCreateNoName = AiToolCallBlock(
          id: 'rules_create_streaming',
          callId: 'call_rules_create_streaming',
          toolName: 'Run',
          arguments: {'command': 'agent-rules', 'subcommand': 'create'},
          status: AiToolCallStatus.running,
        );
        expect(toolRowTarget(context, agentRulesCreateNoName, null), isNull);
        expect(
          toolHeaderSubtitle(context, agentRulesCreateNoName, null),
          '创建规则',
        );

        const sessionsSearch = AiToolCallBlock(
          id: 'sessions_search',
          callId: 'call_sessions_search',
          toolName: 'Run',
          arguments: {
            'command': 'sessions',
            'subcommand': 'search',
            'options': {'query': '伏笔'},
          },
          status: AiToolCallStatus.success,
          result: {'command': 'sessions search'},
        );
        expect(localizedToolCallTitle(context, sessionsSearch), '搜索聊天记录');
        expect(toolRowTarget(context, sessionsSearch, null), '伏笔');
        expect(toolHeaderSubtitle(context, sessionsSearch, null), '搜索聊天记录 伏笔');

        const helpTopic = AiToolCallBlock(
          id: 'help_topic',
          callId: 'call_help_topic',
          toolName: 'Run',
          arguments: {'command': 'help', 'subcommand': 'agent-rules'},
          status: AiToolCallStatus.success,
          result: {'command': 'help agent-rules'},
        );
        expect(localizedToolCallTitle(context, helpTopic), '查看命令帮助');
        expect(toolRowTarget(context, helpTopic, null), '智能体规则');
        expect(toolHeaderSubtitle(context, helpTopic, null), '查看命令帮助 智能体规则');

        const notifyProgress = AiToolCallBlock(
          id: 'notify_progress',
          callId: 'call_notify_progress',
          toolName: 'Run',
          arguments: {
            'command': 'notify',
            'subcommand': 'progress',
            'options': {'content': '正在执行 89/90 章写作'},
          },
          status: AiToolCallStatus.success,
        );
        expect(localizedToolCallTitle(context, notifyProgress), '进度更新');
        expect(toolHeaderSubtitle(context, notifyProgress, null), '进度更新');
        expect(toolRowTarget(context, notifyProgress, null), '正在执行 89/90 章写作');

        const skillsSearch = AiToolCallBlock(
          id: 'skills_search',
          callId: 'call_skills_search',
          toolName: 'Run',
          arguments: {
            'command': 'agent-skills',
            'subcommand': 'search',
            'options': {'query': '写作'},
          },
          status: AiToolCallStatus.success,
          result: {'command': 'agent-skills search'},
        );
        expect(toolRowTarget(context, skillsSearch, null), '写作');
        expect(toolHeaderSubtitle(context, skillsSearch, null), '搜索技能 "写作"');

        const searchBlock = AiToolCallBlock(
          id: 'search',
          callId: 'call_search',
          toolName: 'Search',
          arguments: {'query': '线索'},
          status: AiToolCallStatus.success,
        );
        expect(toolHeaderSubtitle(context, searchBlock, null), '搜索 "线索"');
        expect(toolRowTarget(context, searchBlock, null), '线索');

        const editBlock = AiToolCallBlock(
          id: 'edit',
          callId: 'call_edit',
          toolName: 'Edit',
          arguments: {'path': '/chapters/chapter_1/content'},
          status: AiToolCallStatus.success,
        );
        expect(
          toolRowTarget(
            context,
            editBlock,
            const AiToolResolvedResource(
              collection: 'chapters',
              resourceTitle: '第一章',
              field: 'content',
            ),
          ),
          '章节 · 第一章 · 内容',
        );

        const spawnBlock = AiToolCallBlock(
          id: 'spawn',
          callId: 'call_spawn',
          toolName: 'SpawnAgent',
          arguments: {'name': '审稿员'},
          status: AiToolCallStatus.success,
          metadata: {'sub_agent_model': 'gpt-5'},
        );
        expect(toolRowTarget(context, spawnBlock, null), '审稿员 · gpt-5');

        const skillBlock = AiToolCallBlock(
          id: 'skill',
          callId: 'call_skill',
          toolName: 'AgentSkill',
          arguments: {'name': '章节规划'},
          status: AiToolCallStatus.success,
        );
        expect(toolRowTarget(context, skillBlock, null), '章节规划');
        expect(toolHeaderSubtitle(context, skillBlock, null), '使用技能 章节规划');
      }),
    );
    await tester.pumpAndSettle();
  });
}

Widget _wrapDescriptorAssertions(
  void Function(BuildContext context) assertFn, {
  Locale locale = const Locale('zh', 'CN'),
}) {
  return EasyLocalization(
    // 换语言时重建：EasyLocalization 只在首次挂载时读 startLocale。
    key: ValueKey(locale),
    supportedLocales: [locale],
    saveLocale: false,
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: locale,
    startLocale: locale,
    child: Builder(
      builder: (context) {
        return MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(),
          home: RevericTheme(
            data: RevericThemeData.reveric,
            child: Builder(
              builder: (context) {
                assertFn(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
      },
    ),
  );
}

Future<void> _seedOutline(
  NovelContentService contentService, {
  String title = '主线',
  required List<OutlineBeatDraft> beats,
}) async {
  await contentService.outlineService.createOutline(
    defaultTitle: title,
    beats: beats,
  );
}

// 职责: 测试 BundledControlSkillsLoader — 验证全部 Bundled Control Skill 的加载、
//   callName/runCommand 映射、frontmatter 解析与查找 API。
// 关联文件:
//   lib/shared/services/bundled_control_skills.dart
//   lib/shared/services/agent_skill_import_parser.dart
//   assets/bundled_skills/setup/SKILL.md
//   assets/bundled_skills/setup/references/
//   assets/bundled_skills/management/SKILL.md
//   assets/bundled_skills/management/references/
//   assets/bundled_skills/story-continuity/references/relations.md

import 'package:reveric/shared/app_config.dart';
import 'package:reveric/shared/models/content_kind.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/director/presets.dart';
import 'package:reveric/shared/services/ai/ffmpeg/arguments.dart';
import 'package:reveric/shared/services/production/contact_sheet.dart';
import 'package:reveric/shared/services/bundled_control_skills.dart';

/// 从项目根目录磁盘读取 asset 的 fake bundle。
///
/// flutter test 默认从项目根目录运行,所以直接用相对路径读文件。
/// 仅覆盖 [load] — [loadString] 由父类默认实现
/// 走 UTF-8 解码。
class _FileAssetBundle extends AssetBundle {
  final loadedPaths = <String>{};
  @override
  Future<ByteData> load(String key) async {
    loadedPaths.add(key);
    final bytes = await File(key).readAsBytes();
    return ByteData.sublistView(bytes);
  }
}

class _OverrideAssetBundle extends _FileAssetBundle {
  _OverrideAssetBundle(this.values, {this.missing = const {}});
  final Map<String, String> values;
  final Set<String> missing;
  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (missing.contains(key)) {
      throw const FileSystemException('Missing test asset');
    }
    return values[key] ?? await super.loadString(key, cache: cache);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const loader = BundledControlSkillsLoader();
  late AssetBundle bundle;

  setUp(() {
    bundle = _FileAssetBundle();
  });

  test(
    'director skill catalogs match executable preset IDs and move requirements',
    () async {
      final skill = await loader.findByCallName(bundle, '剧本工具使用规范');
      final guide = skill!.references
          .singleWhere((r) => r.path == 'references/stagings.md')
          .content;
      String section(String title) =>
          guide.split('### $title\n').last.split('\n##').first;
      List<String> tableIds(String title) => RegExp(r'`([^`]+)`')
          .allMatches(
            section(
              title,
            ).split('\n').where((l) => l.startsWith('|')).join('\n'),
          )
          .map((m) => m[1]!)
          .toList();
      final catalogs = {
        '人物模型': actorGeometries,
        '姿势': poseIds,
        '道具': propPresets.map((p) => p.geometry).toList(),
        '机位': cameraPresets,
        '运镜': moveKinds,
      };
      for (final entry in catalogs.entries) {
        expect(guide, contains('### ${entry.key}\n'));
        expect(
          tableIds(entry.key),
          unorderedEquals(entry.value),
          reason: entry.key,
        );
      }
      final moveRows = section(
        '运镜',
      ).split('\n').where((l) => l.startsWith('|')).toList();
      const groups = {'basic': '基础', 'follow': '跟随', 'space': '空间'};
      for (final move in movePresets) {
        final row = moveRows.singleWhere((l) => l.contains('`${move.id}`'));
        expect(
          row,
          startsWith('| ${groups[move.group]} | ${move.subject ? '是' : '否'} |'),
        );
      }
    },
  );

  test(
    'canvas skill discovery and direct loading follow the feature switch',
    () async {
      expect(bundledControlCallNames.contains('画布构图指南'), ideationCanvasEnabled);
      final skill = await loader.findByCallName(bundle, '画布构图指南');
      expect(skill != null, ideationCanvasEnabled);
      if (skill != null) {
        expect(skill.references, hasLength(4));
      }
    },
  );

  test(
    'availability filters listing and direct bundled fallback consistently',
    () async {
      final all = await loader.loadAll(bundle);
      for (final kind in [
        contentKindNovel,
        contentKindScreenplay,
        contentKindCanvas,
      ]) {
        final filtered = await loader.loadAll(bundle, contentKind: kind);
        expect(
          filtered.map((skill) => skill.callName),
          all
              .where((skill) => skill.availableFor(kind))
              .map((skill) => skill.callName),
        );
        for (final skill in all) {
          expect(
            await loader.findByCallName(
                  bundle,
                  skill.callName,
                  contentKind: kind,
                ) !=
                null,
            skill.availableFor(kind),
            reason: '$kind ${skill.callName}',
          );
        }
      }
      final canvas = (await loader.loadAll(
        bundle,
        contentKind: contentKindCanvas,
      )).map((skill) => skill.callName);
      expect(canvas, containsAll(['系统管理', '媒体处理与剪辑']));
      expect(canvas, isNot(contains('创作向导')));
      expect(canvas, isNot(contains('故事连续性维护')));
      expect(canvas, isNot(contains('剧本工具使用规范')));
      for (final command in ['production', 'styles', 'stagings']) {
        expect(
          bundledControlSkillForRun(command, contentKind: contentKindCanvas),
          '画布作品工具',
        );
        expect(
          bundledControlSkillForRun(
            command,
            contentKind: contentKindScreenplay,
          ),
          '剧本工具使用规范',
        );
      }
    },
  );

  test(
    'inline reference extracts only the named second-level section with code fences intact',
    () async {
      final source =
          '# Guide\n## Before\nIgnore\n## Shared\nContent\n### Child\nKeep\n```md\n## Fake heading\n```\n## After\nIgnore';
      final replacement = _OverrideAssetBundle({
        'assets/bundled_skills/setup/references/original.md':
            'Start\n<inline-ref type="reference" skill="剧本工具使用规范" section="Shared">references/clips.md</inline-ref>\nEnd',
        'assets/bundled_skills/screenplay-tools/references/clips.md': source,
      });
      final skill = (await loader.findByCallName(replacement, '创作向导'))!;
      final result = skill.references
          .singleWhere((ref) => ref.path == 'references/original.md')
          .content;
      expect(
        result,
        'Start\n## Shared\nContent\n### Child\nKeep\n```md\n## Fake heading\n```\nEnd',
      );
      expect(result, isNot(contains('<inline-ref')));
    },
  );

  test('whole registered reference is expanded without path rewriting', () async {
    final replacement = _OverrideAssetBundle({
      'assets/bundled_skills/setup/references/original.md':
          '<inline-ref type="reference" skill="剧本工具使用规范">references/clips.md</inline-ref>',
      'assets/bundled_skills/screenplay-tools/references/clips.md':
          '# All\n[Sibling](styles.md)',
    });
    final skill = (await loader.findByCallName(replacement, '创作向导'))!;
    expect(
      skill.references
          .singleWhere((ref) => ref.path == 'references/original.md')
          .content,
      '# All\n[Sibling](styles.md)',
    );
  });

  for (final (tag, source) in [
    (
      '<inline-ref type="reference" skill="missing">references/clips.md</inline-ref>',
      '## Shared\nContent',
    ),
    (
      '<inline-ref type="reference" skill="剧本工具使用规范">references/missing.md</inline-ref>',
      '## Shared\nContent',
    ),
    (
      '<inline-ref type="reference" skill="剧本工具使用规范" section="Missing">references/clips.md</inline-ref>',
      '## Shared\nContent',
    ),
    (
      '<inline-ref type="reference" skill="剧本工具使用规范">references/clips.md</inline-ref>',
      '<inline-ref type="reference" skill="创作向导">references/original.md</inline-ref>',
    ),
    ('<inline-ref type="skill">剧本工具使用规范</inline-ref>', '## Shared\nContent'),
  ]) {
    test('invalid or nested bundled reference fails: $tag / $source', () async {
      final replacement = _OverrideAssetBundle({
        'assets/bundled_skills/setup/references/original.md': tag,
        'assets/bundled_skills/screenplay-tools/references/clips.md': source,
      });
      await expectLater(
        loader.findByCallName(replacement, '创作向导'),
        throwsStateError,
      );
    });
  }

  test(
    'registered but missing inline reference asset throws StateError',
    () async {
      final replacement = _OverrideAssetBundle(
        {
          'assets/bundled_skills/setup/references/original.md':
              '<inline-ref type="reference" skill="剧本工具使用规范">references/clips.md</inline-ref>',
        },
        missing: {'assets/bundled_skills/screenplay-tools/references/clips.md'},
      );
      await expectLater(
        loader.findByCallName(replacement, '创作向导'),
        throwsStateError,
      );
    },
  );

  test('all bundled reference output is expanded', () async {
    for (final skill in await loader.loadAll(bundle)) {
      for (final reference in skill.references) {
        expect(
          reference.content,
          isNot(contains('<inline-ref')),
          reason: '${skill.callName}/${reference.path}',
        );
      }
    }
  });

  test(
    'canvas production references reuse neutral sections and registered staging attachment',
    () async {
      final canvas = (await loader.findByCallName(
        bundle,
        '画布作品工具',
        contentKind: contentKindCanvas,
      ))!;
      expect(canvas.references.map((ref) => ref.path), [
        'references/clips.md',
        'references/production-canvas.md',
        'references/stagings.md',
        'references/styles.md',
      ]);
      final screenplay = (await loader.findByCallName(bundle, '剧本工具使用规范'))!;
      final byPath = {
        for (final ref in canvas.references) ref.path: ref.content,
      };
      expect(
        byPath['references/stagings.md'],
        screenplay.references
            .singleWhere((ref) => ref.path == 'references/stagings.md')
            .content,
      );
      final structure = screenplay.references
          .singleWhere((ref) => ref.path == 'references/screenplay.md')
          .content;
      expect(structure, contains('场景标题写进场次字段，不写进正文'));
      expect(structure, contains('不得把整场正文或整段 Markdown 塞进一个动作元素'));
      expect(byPath['references/stagings.md'], contains('本次剧情依据'));
      expect(byPath['references/stagings.md'], isNot(contains('场次正文')));
      expect(byPath['references/production-canvas.md'], contains('## 文本节点'));
      for (final skill in [canvas, screenplay]) {
        final text = skill.references
            .singleWhere((ref) => ref.path == 'references/production-canvas.md')
            .content;
        expect(text, contains('remove_types=["text"]'));
        expect(text, contains('输入连线和被此次删除清理的标签'));
        expect(text, contains('不覆盖新内容'));
      }
      expect(byPath['references/production-canvas.md'], contains('## 全景取景'));
      expect(byPath['references/clips.md'], contains('## 文本输入'));
      expect(byPath['references/clips.md'], isNot(contains('## 人物与地点图集名称')));
      for (final ref in canvas.references.where(
        (ref) => !ref.path.endsWith('stagings.md'),
      )) {
        expect(ref.content, isNot(contains('/episodes/')));
        expect(ref.content, isNot(contains('`/_schema/clips`')));
        expect(ref.content, isNot(contains('`/clips/')));
        expect(ref.content, isNot(contains('<inline-ref')));
      }
      for (final scenario in ['两人在门口交接钥匙，接收者将钥匙藏进口袋', '夜间追逐后主角返回空房，发现桌上的信']) {
        // 静态任务矩阵仅核对作品类型与操作入口，不声称验证了模型的触发准确率。
        for (final kind in [contentKindCanvas, contentKindScreenplay]) {
          final name = bundledControlSkillForRun(
            'production',
            contentKind: kind,
          )!;
          final selected = await loader.findByCallName(
            bundle,
            name,
            contentKind: kind,
          );
          expect(selected, isNotNull, reason: scenario);
          expect(
            selected!.prompt,
            contains(kind == contentKindCanvas ? 'production/clips' : '剧本'),
          );
        }
      }
    },
  );

  group('loadAll', () {
    test('returns all bundled control skills in fixed spec order', () {
      // fallback 必须齐齐返回,顺序固定,便于上层按 index 引用或 diff。
      // 缺一个意味着 pubspec 漏声明 asset 或 spec 表被误删。
      return loader.loadAll(bundle).then((skills) {
        expect(
          skills.map((s) => s.callName).toList(),
          equals([
            '创作向导',
            '系统管理',
            if (ideationCanvasEnabled) '画布构图指南',
            '剧本工具使用规范',
            '画布作品工具',
            '故事连续性维护',
            '媒体处理与剪辑',
          ]),
        );
      });
    });

    test(
      'callName is the Chinese runtime identifier, not the English filename slug',
      () {
        // 关键不变量:callName 是运行时 fallback 匹配的 key,必须是固定的中文字符串,
        // 同名 NovelAgentSkill 才能覆盖 fallback。禁止退化成英文 slug
        // (setup / management)。
        return loader.loadAll(bundle).then((skills) {
          final byCallName = {for (final s in skills) s.callName: s};

          expect(byCallName['创作向导']!.callName, '创作向导');
          expect(byCallName['系统管理']!.callName, '系统管理');
          expect(
            byCallName['画布构图指南']?.callName,
            ideationCanvasEnabled ? '画布构图指南' : null,
          );
          expect(byCallName['剧本工具使用规范']!.callName, '剧本工具使用规范');
          expect(byCallName['故事连续性维护']!.callName, '故事连续性维护');

          for (final skill in skills) {
            expect(
              skill.name,
              isNotEmpty,
              reason: '${skill.assetPath}: frontmatter name must be parsed',
            );
            expect(
              skill.callName,
              isNot(
                equals(skill.assetPath.split('/').last.replaceAll('.md', '')),
              ),
              reason:
                  '${skill.assetPath}: callName must not regress to filename slug',
            );
          }
        });
      },
    );

    test(
      'frontmatter is parsed into name/whenToUse/description and body into prompt',
      () {
        // 防止 loader 把整篇 markdown 当 prompt 或把 frontmatter 字段读空。
        // 如果 AgentSkillImportParser 行为变化或 frontmatter 结构改写,这里会失败。
        return loader.loadAll(bundle).then((skills) {
          for (final skill in skills) {
            expect(skill.name, isNotEmpty, reason: skill.assetPath);
            expect(skill.whenToUse, isNotEmpty, reason: skill.assetPath);
            expect(skill.description, isNotEmpty, reason: skill.assetPath);
            // prompt 是 frontmatter 之后的 body,不应包含 frontmatter 分隔符。
            expect(skill.prompt, isNotEmpty, reason: skill.assetPath);
            expect(
              skill.prompt.startsWith('---'),
              isFalse,
              reason:
                  '${skill.assetPath}: prompt should not include frontmatter',
            );
          }

          // 抽样验证 body 内容确实来自对应文件(不是被错配到别的 asset)。
          // 「前置准备：先读，再问」是 setup/SKILL.md 的当前流程节点,不会出现在
          // 另外两个管理类 skill 的 body 里。
          final setup = skills.firstWhere((s) => s.callName == '创作向导');
          expect(setup.prompt, contains('# 创作向导'));
          expect(setup.prompt, contains('前置准备：先读，再问'));
          expect(setup.prompt, contains('当前作品」段中的 `type`'));
          expect(setup.prompt, isNot(contains('Novels.type')));
          expect(setup.prompt, contains('Read {"path":"profile"}'));
          expect(setup.prompt, contains('Write {"path":"profile/title"'));
          expect(setup.prompt, isNot(contains('/novel')));
          expect(setup.prompt, isNot(contains('"path":"/profile')));
          expect(setup.references.map((reference) => reference.path), [
            'references/fanfic.md',
            'references/imitation.md',
            'references/original.md',
            'references/sequel.md',
          ]);
          expect(
            setup.references
                .firstWhere(
                  (reference) => reference.path == 'references/fanfic.md',
                )
                .content,
            contains('故事线平行'),
          );
          expect(
            setup.references
                .firstWhere(
                  (reference) => reference.path == 'references/fanfic.md',
                )
                .content,
            contains('建立原著参考大纲'),
          );
          expect(
            setup.references
                .firstWhere(
                  (reference) => reference.path == 'references/fanfic.md',
                )
                .content,
            contains('不是固定模板'),
          );
          final fanficReference = setup.references.firstWhere(
            (reference) => reference.path == 'references/fanfic.md',
          );
          expect(fanficReference.content, contains('原作名 - 剧情梗概'));
          expect(fanficReference.content, contains('原作名 - 完整时间线'));
          expect(fanficReference.content, contains('原作名 - 每章剧情'));
          expect(fanficReference.content, contains('取材区间确认后'));
          expect(fanficReference.content, contains('不要为了初始化机械读取整份文档'));
          expect(fanficReference.content, contains('不算模型记忆'));
          expect(fanficReference.content, contains('用户提供或已核实'));
          expect(fanficReference.content, isNot(contains('一键建同人')));
          expect(fanficReference.content, isNot(contains('本次拆书生成')));
          expect(
            fanficReference.content.indexOf('先读「原作名 - 剧情梗概」'),
            lessThan(fanficReference.content.indexOf('取材区间确认后')),
          );
          expect(
            fanficReference.content.indexOf('取材区间确认后'),
            lessThan(
              fanficReference.content.indexOf('读取「原作名 - 完整时间线」中与取材区间相关的章节'),
            ),
          );

          final management = skills.firstWhere((s) => s.callName == '系统管理');
          final references = {
            for (final reference in management.references)
              reference.path: reference.content,
          };
          expect(references.keys, [
            'references/agent-rules.md',
            'references/agent-skills.md',
            'references/providers.md',
            'references/settings.md',
            'references/skill-design.md',
            'references/subagents.md',
            'references/themes.md',
          ]);
          expect(
            references['references/agent-rules.md'],
            contains('agent-rules'),
          );
          expect(
            references['references/agent-skills.md'],
            contains('reference-move'),
          );
          expect(
            references['references/subagents.md'],
            contains('"command":"subagents"'),
          );
          expect(
            references['references/skill-design.md'],
            contains('Reference 只放'),
          );
          for (final reference in management.references) {
            expect(management.prompt, contains(reference.path));
            expect(management.prompt, isNot(contains(reference.content)));
          }

          if (ideationCanvasEnabled) {
            final canvasGuide = skills.firstWhere(
              (s) => s.callName == '画布构图指南',
            );
            expect(canvasGuide.name, '画布构图指南');
            expect(canvasGuide.whenToUse, contains('操作构思画布'));
            expect(canvasGuide.whenToUse, contains('按集制作画布'));
            expect(canvasGuide.whenToUse, contains('「剧本工具使用规范」'));
            expect(
              canvasGuide.whenToUse,
              isNot(contains('三个以上')),
              reason: '构思画布操作不以节点数量为加载门槛',
            );
            // 入口保留共同调用契约，具体构图方法在场景附件中。
            expect(canvasGuide.prompt, contains('构图优先用 `col`/`row`'));
            // canvas 操作细节从 Read/Write 工具描述下沉到此,删掉就等于删掉唯一真源。
            expect(canvasGuide.prompt, contains('/canvas/{name}/layout'));
            expect(canvasGuide.prompt, contains('/canvas/{name}/open'));
            expect(canvasGuide.prompt, contains('?search='));
            expect(canvasGuide.prompt, contains('/_schema/canvas'));
            expect(canvasGuide.prompt, contains('整体覆盖便签正文'));
            expect(canvasGuide.prompt, contains('局部替换便签正文'));
            expect(canvasGuide.prompt, contains('不支持 Write / Edit'));
            expect(canvasGuide.prompt, contains('创建后不可写'));
            expect(canvasGuide.prompt, contains('不是可读字段'));
            expect(canvasGuide.prompt, contains('成功响应仅为 `{"ok": true}`'));
            expect(canvasGuide.prompt, contains('"value": "发现新的线索"'));
            expect(
              canvasGuide.prompt,
              contains('"old_text": "新的", "new_text": "关键"'),
            );
            expect(canvasGuide.prompt, contains('工具仍支持 `x`/`y`'));

            expect(
              canvasGuide.assetPath,
              'assets/bundled_skills/canvas-composition/SKILL.md',
            );
          }
          final relationGuide = skills.firstWhere(
            (s) => s.callName == '故事连续性维护',
          );
          expect(relationGuide.name, '故事连续性维护');
          final relations = relationGuide.references.singleWhere(
            (ref) => ref.path == 'references/relations.md',
          );
          expect(relations.content, contains('Create {"path": "/relations"'));
          expect(relations.content, contains('GraphSearch {"type":'));
          expect(
            relations.content,
            isNot(contains('entity_type')),
            reason: 'GraphSearch 正式字段是 type / id，skill 不得再教 entity_type',
          );
          expect(relations.content, isNot(contains('已建立的关系不可改写')));
          expect(relations.content, contains('不能仅凭 GraphSearch 无结果就 Create'));
          expect(relations.content, contains('change_logs/{change_id}'));
          expect(relations.content, contains('Edit 只修正当前与最新快照'));
          expect(relations.content, contains('不能用 Remove 表达剧情结束'));
          expect(relations.content, contains('status":"ended'));
          expect(relations.content, contains('无法判断时停止该关系写入'));
          expect(
            relations.content,
            contains('GraphSearch` 的 `relation_type` 是可选过滤'),
          );
          expect(relations.path, 'references/relations.md');
        });
      },
    );
  });

  test(
    'packaged assets include the management entry and all references',
    () async {
      final skills = await loader.loadAll(rootBundle);
      final management = skills.singleWhere(
        (skill) => skill.callName == '系统管理',
      );
      expect(await loader.findByCallName(bundle, '图像生成工具指南'), isNull);
      expect(await loader.findByCallName(bundle, '地图设计指南'), isNull);
      expect(await loader.findByCallName(bundle, '地图草稿工具指南'), isNull);
      if (ideationCanvasEnabled) {
        final canvas = skills.singleWhere(
          (skill) => skill.callName == '画布构图指南',
        );
        expect(
          canvas.references.map((ref) => ref.path),
          unorderedEquals([
            'references/story-structure.md',
            'references/branching-story.md',
            'references/relationships.md',
            'references/idea-board.md',
          ]),
        );
        for (final reference in canvas.references) {
          expect(reference.content, isNotEmpty, reason: reference.path);
        }
      }
      final screenplay = skills.singleWhere(
        (skill) => skill.callName == '剧本工具使用规范',
      );
      expect(
        screenplay.references.map((ref) => ref.path),
        unorderedEquals([
          'references/screenplay.md',
          'references/clips.md',
          'references/styles.md',
          'references/production-canvas.md',
          'references/stagings.md',
        ]),
      );
      final media = skills.singleWhere((skill) => skill.callName == '媒体处理与剪辑');
      expect(
        media.references.map((ref) => ref.path),
        unorderedEquals([
          'references/files.md',
          'references/ffmpeg.md',
          'references/editing.md',
          'references/operations.md',
        ]),
      );
      final continuity = skills.singleWhere(
        (skill) => skill.callName == '故事连续性维护',
      );
      expect(
        continuity.references.map((ref) => ref.path),
        unorderedEquals([
          'references/novel.md',
          'references/screenplay.md',
          'references/relations.md',
        ]),
      );
      expect(continuity.whenToUse, contains('建立、查询、调整或清理人物及实体关系'));
      expect(continuity.prompt, isNot(contains('### character → character')));
      for (final reference in management.references) {
        expect(reference.content, isNotEmpty, reason: reference.path);
      }
      for (final retired in [
        '智能体规则管理',
        '智能体技能管理',
        '技能创作向导',
        '子智能体管理',
        '关系图谱指南',
        '故事事实整理',
      ]) {
        expect(await loader.findByCallName(bundle, retired), isNull);
      }
    },
  );

  test(
    'every enabled bundled file is registered and relative links resolve',
    () async {
      final trackingBundle = _FileAssetBundle();
      final skills = await loader.loadAll(trackingBundle);
      final registered = trackingBundle.loadedPaths;
      final link = RegExp(r'\]\(([^)#]+\.md)(?:#[^)]*)?\)');
      for (final skill in skills) {
        final root = File(skill.assetPath).parent;
        final bodies = {
          skill.assetPath: skill.prompt,
          for (final ref in skill.references)
            '${root.path}/${ref.path}': ref.content,
        };
        for (final entry in bodies.entries) {
          for (final match in link.allMatches(entry.value)) {
            final target = match.group(1)!;
            if (target.contains('://')) {
              continue;
            }
            final path = File('${File(entry.key).parent.path}/$target').path;
            expect(
              bodies.containsKey(path),
              isTrue,
              reason: '${entry.key}: $target',
            );
          }
        }
      }
      final onDisk = Directory('assets/bundled_skills')
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => file.path)
          .where(
            (path) =>
                ideationCanvasEnabled ||
                !path.startsWith('assets/bundled_skills/canvas-composition/'),
          )
          .toSet();
      expect(registered, unorderedEquals(onDisk));
    },
  );

  test('FFmpeg skill examples obey the executable argument contract', () async {
    final skill = (await loader.findByCallName(bundle, '媒体处理与剪辑'))!;
    final reference = skill.references.singleWhere(
      (ref) => ref.path == 'references/ffmpeg.md',
    );
    final examples = RegExp(
      r'```json\n([\s\S]*?)\n```',
    ).allMatches(reference.content);
    expect(examples, isNotEmpty);
    for (final example in examples) {
      final input = jsonDecode(example.group(1)!) as Map<String, dynamic>;
      final options = input['options'] as Map<String, dynamic>;
      if (input['subcommand'] == 'frames') {
        FfmpegArguments.localPath(options['path'] as String);
        expect(
          contactSheetPositions(options['timestamps_ms'], 'timestamps_ms'),
          isNotEmpty,
        );
        continue;
      }
      final parsed = FfmpegArguments.parse(
        options['args'],
        probe: input['subcommand'] == 'probe',
      );
      expect(parsed.inputs, isNotEmpty);
      if (!parsed.probe) {
        expect(
          parsed.outputs.isNotEmpty || parsed.nullOutputs.isNotEmpty,
          true,
        );
        expect(options.containsKey('request_id'), isFalse);
      }
    }
  });

  group('findByCallName', () {
    test('returns matching skill for known callName', () async {
      final skill = await loader.findByCallName(bundle, '系统管理');
      expect(skill, isNotNull);
      expect(skill!.callName, '系统管理');
      expect(skill.assetPath, 'assets/bundled_skills/management/SKILL.md');
    });

    test('returns null for unknown callName', () async {
      // 未知 callName 必须返回 null,而不是抛错 — fallback 调用方会用 null
      // 判定「不是 bundled 控制技能」并走其他路径。
      final skill = await loader.findByCallName(bundle, '不存在的技能');
      expect(skill, isNull);
    });

    test('hits all known callNames', () async {
      // 所有 callName 都必须命中,任一未命中意味着 spec 表或常量集被破坏。
      for (final callName in bundledControlCallNames) {
        final skill = await loader.findByCallName(bundle, callName);
        expect(skill, isNotNull, reason: callName);
        expect(skill!.callName, callName);
      }
    });
  });

  group('关系图谱指南 stays in sync with the relation type constants', () {
    // 合法 relation_type 表原本由 buildRelationTypeReference() 从常量生成、直接进
    // Create 工具描述;下沉到 skill 后表是手写的 markdown,会和常量脱节。真源仍是
    // novel_content_database.dart 的常量,这里把脱节变成测试失败。
    const relationTypeGroups = <String, List<String>>{
      'character → character': characterRelationTypes,
      'character → faction': characterFactionRelationTypes,
      'character → skill': characterSkillRelationTypes,
      'character → item': characterItemRelationTypes,
      'faction → faction': factionRelationTypes,
      'skill → skill': skillRelationTypes,
      'item → item': itemRelationTypes,
      'creature → creature': creatureRelationTypes,
    };

    test(
      'every legal relation type has a direction row in its pair table',
      () async {
        // 每个类型都必须在**它所属实体对的小节里**出现一行方向读法。只检查「出现过」
        // 不够 —— evolves_to 在 skill/item/creature 三个小节都合法，漏掉任一个不会被
        // 全局 contains 发现。这里按小节切片再查。
        final skill = await loader.findByCallName(bundle, '故事连续性维护');
        expect(skill, isNotNull);
        final prompt = skill!.references
            .singleWhere((ref) => ref.path == 'references/relations.md')
            .content;

        for (final entry in relationTypeGroups.entries) {
          final heading = '### ${entry.key}';
          final start = prompt.indexOf(heading);
          expect(start, isNot(-1), reason: '关系图谱指南 缺少 `$heading` 小节');
          // 小节范围 = 本标题到下一个 `###` 之间。
          final rest = prompt.indexOf('\n### ', start + heading.length);
          final section = rest == -1
              ? prompt.substring(start)
              : prompt.substring(start, rest);

          for (final type in entry.value) {
            expect(
              section,
              contains('| `$type` |'),
              reason:
                  '${entry.key} 的 `$type` 在 关系图谱指南 里没有方向行 —— '
                  '常量新增后必须同步补进 assets/bundled_skills/story-continuity/references/relations.md '
                  '的对应小节，且方向要与 novel_content_database.dart 的行尾注释一致',
            );
          }
        }
      },
    );

    test(
      'the two reverse-reading exceptions stay documented as such',
      () async {
        // subordinate / alter_ego 是唯一两个「类型名描述 target」的类型。它们最容易被
        // 后来者"顺手改成和别的一致"，而那会把存量关系的含义整体翻转。
        final skill = await loader.findByCallName(bundle, '故事连续性维护');
        expect(skill, isNotNull);
        final prompt = skill!.references
            .singleWhere((ref) => ref.path == 'references/relations.md')
            .content;

        expect(prompt, contains('**B 是 A 的下属**'));
        expect(prompt, contains('**B 是 A 的化身/马甲**'));
        expect(prompt, contains('**B 是 A 的下属组织**'));
        // 反向记号本身也要在，否则读者不知道这是有意为之的例外。
        expect(prompt, contains('[反读]'));
      },
    );

    test('every entity type appears in the skill body', () async {
      final skill = await loader.findByCallName(bundle, '故事连续性维护');
      expect(skill, isNotNull);
      for (final type in entityTypes) {
        expect(
          skill!.references
              .singleWhere((ref) => ref.path == 'references/relations.md')
              .content,
          contains('`$type`'),
          reason: '实体类型 `$type` 没有出现在 关系图谱指南 里',
        );
      }
    });
  });

  group('findByRunCommand', () {
    for (final command in [
      'agent-rules',
      'agent-skills',
      'subagents',
      'themes',
    ]) {
      test('$command maps to the shared management skill', () async {
        final skill = await loader.findByRunCommand(bundle, command);
        expect(skill, isNotNull);
        expect(skill!.callName, '系统管理');
        expect(skill.runCommand, isNull);
        expect(skill.assetPath, 'assets/bundled_skills/management/SKILL.md');
      });
    }

    for (final command in ['image', 'character', 'item']) {
      test('$command command does not map to a skill', () async {
        expect(await loader.findByRunCommand(bundle, command), isNull);
      });
    }

    test('returns null for unknown runCommand', () async {
      final skill = await loader.findByRunCommand(bundle, 'unknown-command');
      expect(skill, isNull);
    });
  });

  group('创作向导 has no Run command', () {
    test('setup skill runCommand is null', () async {
      // 关键不对称:setup/SKILL.md 没有 Run 命令,因为它由 AI 在写作流程中主动判断触发,
      // 不像 agent-rules/agent-skills/image 由用户显式 Run 调用。
      // 若此处变成非 null,意味着有人误给 setup 加了 Run 命令,会破坏触发语义。
      final skill = await loader.findByCallName(bundle, '创作向导');
      expect(skill, isNotNull);
      expect(skill!.callName, '创作向导');
      expect(skill.runCommand, isNull);
    });

    test(
      'no bundled control skill maps to a runCommand that resolves to 创作向导',
      () {
        // 反向校验:从 runCommand 映射表无法到达「创作向导」。
        expect(
          bundledControlRunCommandToCallName.values,
          isNot(contains('创作向导')),
          reason: '创作向导 should not be reachable via Run command',
        );
      },
    );
  });
}

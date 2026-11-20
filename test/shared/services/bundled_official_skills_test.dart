// 职责: 测试 BundledOfficialSkillsLoader — 验证官方目录从 asset 加载、按 name
//   取详情与附件、资源打包、未知 name 错误及整包内容与规格表不漂移。
// 关联文件:
//   lib/shared/services/bundled_official_skills.dart
//   lib/shared/services/agent_skill_import_parser.dart
//   assets/official_skills/
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/bundled_official_skills.dart';

class _FileAssetBundle extends AssetBundle {
  _FileAssetBundle({this.missingAsset});

  final String? missingAsset;
  final loadedPaths = <String>[];

  @override
  Future<ByteData> load(String key) async {
    loadedPaths.add(key);
    if (key == missingAsset) {
      throw StateError('Missing test asset: $key');
    }
    final bytes = await File(key).readAsBytes();
    return ByteData.sublistView(bytes);
  }
}

/// 若 [graph] 存在有向环（含自环），返回可读路径 `a -> b -> a`；无环返回 null。
String? _findLinkCycle(Map<String, Set<String>> graph) {
  final state = <String, int>{}; // 1 = visiting, 2 = visited
  final stack = <String>[];

  String? dfs(String node) {
    state[node] = 1;
    stack.add(node);
    for (final next in graph[node] ?? const <String>{}) {
      final nextState = state[next];
      if (nextState == 1) {
        final cycleStart = stack.indexOf(next);
        return [...stack.sublist(cycleStart), next].join(' -> ');
      }
      if (nextState == null) {
        final cycle = dfs(next);
        if (cycle != null) return cycle;
      }
    }
    stack.removeLast();
    state[node] = 2;
    return null;
  }

  for (final node in graph.keys) {
    if (state[node] == null) {
      final cycle = dfs(node);
      if (cycle != null) return cycle;
    }
  }
  return null;
}

/// 收集除 [entryPath] 外各附件的标题与被链接别名，用于拦截「标题」式回指成环。
Map<String, Set<String>> _collectAttachmentTitleAliases(
  Map<String, String> files, {
  required String entryPath,
}) {
  final aliases = <String, Set<String>>{};
  final h1Pattern = RegExp(r'^#\s+(.+)$', multiLine: true);
  final labelLinkPattern = RegExp(r'\[([^\]]+)\]\(([^)#]+\.md)(?:#[^)]*)?\)');

  void register(String alias, String targetPath) {
    final normalized = alias.trim();
    if (normalized.isEmpty || targetPath == entryPath) return;
    aliases.putIfAbsent(normalized, () => <String>{}).add(targetPath);
  }

  for (final file in files.entries) {
    if (file.key == entryPath) continue;
    final h1 = h1Pattern.firstMatch(file.value)?.group(1)?.trim();
    if (h1 != null && h1.isNotEmpty) {
      register(h1, file.key);
      if (h1.contains('与')) {
        register(h1.split('与').first, file.key);
      }
    }
  }
  for (final file in files.entries) {
    for (final match in labelLinkPattern.allMatches(file.value)) {
      final target = Uri.parse(match.group(2)!);
      if (target.hasScheme) continue;
      final resolved = Uri.parse(file.key).resolveUri(target).path;
      if (files.containsKey(resolved)) {
        register(match.group(1)!, resolved);
      }
    }
  }
  return aliases;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const loader = BundledOfficialSkillsLoader();
  const productionNoticeAssetPath =
      'assets/official_skills/screenplay-production/NOTICE.md';
  late AssetBundle bundle;

  setUp(() {
    bundle = _FileAssetBundle();
  });

  test('list returns all official skills in sort_order', () async {
    final result = await loader.list(bundle);
    expect(result.agentSkills, hasLength(13));
    expect(
      result.agentSkills
          .where((skill) => skill.category == '剧本')
          .map((skill) => skill.name),
      ['剧本写作', '剧本制片'],
    );
    expect(result.agentSkills.map((skill) => skill.listingId).toList(), [
      for (final skill in result.agentSkills) skill.name,
    ]);
    expect(
      result.agentSkills.map((skill) => skill.version).toList(),
      bundledOfficialSkillSpecs.map((spec) => spec.version).toList(),
    );
  });

  test(
    'detail contains skill-relative references with their full content',
    () async {
      for (final spec in bundledOfficialSkillSpecs) {
        final detail = await loader.get(bundle, spec.name);
        final root = spec.assetPath.substring(
          0,
          spec.assetPath.lastIndexOf('/') + 1,
        );
        expect(detail.references, hasLength(spec.referenceAssetPaths.length));
        for (final reference in detail.references) {
          expect(reference.path, startsWith('references/'));
          final assetPath = '$root${reference.path}';
          expect(spec.referenceAssetPaths, contains(assetPath));
          expect(reference.content, await File(assetPath).readAsString());
        }
      }
    },
  );

  test('catalog summaries do not load reference bodies', () async {
    final trackingBundle = _FileAssetBundle();
    await loader.list(trackingBundle);
    expect(
      trackingBundle.loadedPaths,
      bundledOfficialSkillSpecs.map((spec) => spec.assetPath).toList(),
    );
  });

  test(
    'missing reference fails detail loading instead of returning a partial skill',
    () async {
      final spec = bundledOfficialSkillSpecs.firstWhere(
        (spec) => spec.referenceAssetPaths.isNotEmpty,
      );
      final missing = spec.referenceAssetPaths.last;
      await expectLater(
        loader.get(_FileAssetBundle(missingAsset: missing), spec.name),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'all official skill files are included in the Flutter asset bundle',
    () async {
      for (final spec in bundledOfficialSkillSpecs) {
        final packaged = await loader.get(rootBundle, spec.name);
        final onDisk = await loader.get(bundle, spec.name);
        expect(packaged.prompt, onDisk.prompt);
        expect(
          packaged.references.map((file) => (file.path, file.content)).toList(),
          onDisk.references.map((file) => (file.path, file.content)).toList(),
        );
      }
    },
  );

  test(
    'relative Markdown reference links resolve inside each installed skill without cycles or malformed ref tags',
    () async {
      final links = RegExp(r'\]\(([^)#]+)(?:#[^)]*)?\)');
      final quotedTitle = RegExp(r'「([^」]+)」');
      final refTag = RegExp(r'<ref\b[^>]*>');
      final inputIdAttr = RegExp(r'input_id="([^"]+)"');
      final labelAttr = RegExp(r'label="([^"]+)"');
      for (final spec in bundledOfficialSkillSpecs) {
        final detail = await loader.get(bundle, spec.name);
        final files = {
          'SKILL.md': detail.prompt,
          for (final reference in detail.references)
            reference.path: reference.content,
        };
        final titleAliases = _collectAttachmentTitleAliases(
          files,
          entryPath: 'SKILL.md',
        );
        final graph = <String, Set<String>>{
          for (final path in files.keys) path: <String>{},
        };
        for (final file in files.entries) {
          expect(
            file.value,
            isNot(contains('promptExtend')),
            reason: '${spec.name} (${file.key}): use snake_case prompt_extend',
          );
          for (final match in links.allMatches(file.value)) {
            final target = Uri.parse(match.group(1)!);
            if (target.hasScheme) {
              continue;
            }
            final resolved = Uri.parse(file.key).resolveUri(target).path;
            expect(
              files.keys,
              contains(resolved),
              reason: '${spec.name}: ${file.key} -> $target',
            );
            graph[file.key]!.add(resolved);
          }
          if (file.key != 'SKILL.md') {
            for (final match in quotedTitle.allMatches(file.value)) {
              final phrase = match.group(1)!;
              final targets = titleAliases[phrase];
              if (targets == null) continue;
              final otherTargets = targets
                  .where((target) => target != file.key)
                  .toSet();
              graph[file.key]!.addAll(otherTargets);
              expect(
                otherTargets,
                isEmpty,
                reason:
                    '${spec.name} (${file.key}) must not redirect via title '
                    '「$phrase」 to $otherTargets',
              );
            }
          }
          for (final match in refTag.allMatches(file.value)) {
            final tag = match.group(0)!;
            if (tag == '<ref>') {
              continue;
            }
            final hasInputId =
                inputIdAttr.firstMatch(tag)?.group(1)?.trim().isNotEmpty ??
                false;
            final hasLabel =
                labelAttr.firstMatch(tag)?.group(1)?.trim().isNotEmpty ?? false;
            expect(
              hasInputId && hasLabel,
              isTrue,
              reason: '${spec.name} (${file.key}): malformed ref tag $tag',
            );
          }
        }
        expect(
          _findLinkCycle(graph),
          isNull,
          reason: '${spec.name} must keep a cycle-free DAG reference graph',
        );
      }
    },
  );

  test('production keeps its name and neutral tool-skill routing', () async {
    final skill = await loader.get(bundle, '剧本制片');
    expect(skill.version, 7);
    expect(skill.name, '剧本制片');
    expect(skill.prompt, contains('画布作品工具'));
    expect(skill.whenToUse, contains('适用于剧本和画布作品'));
    expect(skill.whenToUse, isNot(contains('音频')));
    for (final ref in skill.references) {
      expect(ref.content, isNot(contains('剧本工具使用规范')), reason: ref.path);
    }
    expect(
      skill.references
          .singleWhere((ref) => ref.path == 'references/production.md')
          .content,
      contains('文本节点'),
    );
    expect(
      skill.references
          .singleWhere((ref) => ref.path == 'references/qwen-image-prompts.md')
          .content,
      contains('prompt_extend'),
    );
  });

  test('get returns prompt and uses name as listing id', () async {
    final detail = await loader.get(bundle, '黄金三章');
    expect(detail.listingId, '黄金三章');
    expect(detail.name, '黄金三章');
    expect(detail.whenToUse, isNotEmpty);
    expect(detail.prompt, isNotEmpty);
    expect(detail.sortOrder, 5);
    // spec 上的 badge 要透传到详情，UI 才拿得到角标。
    expect(detail.badge, '推荐');
  });

  test('badge from the spec table reaches the summary list', () async {
    final result = await loader.list(bundle);
    final badged = {
      for (final skill in result.agentSkills)
        if (skill.badge != null && skill.badge!.isNotEmpty)
          skill.name: skill.badge,
    };
    expect(badged, {
      for (final spec in bundledOfficialSkillSpecs)
        if (spec.badge != null && spec.badge!.isNotEmpty) spec.name: spec.badge,
    });
  });

  test('get rejects an unknown bundled skill name', () async {
    await expectLater(
      loader.get(bundle, '不存在的技能'),
      throwsA(
        isA<ArgumentError>()
            .having((e) => e.name, 'name', 'listingId')
            .having((e) => e.invalidValue, 'invalidValue', '不存在的技能'),
      ),
    );
  });

  // ── 规格表守卫 ──────────────────────────────────────────────────────────
  //
  // hash 守卫校验内容指纹，目录守卫检查资源登记；它们不判断发布状态。
  // 按 AGENTS.md 核实当前技能版本是否发布，再决定递增还是合并开发修改。
  // 保留版本号不会触发自动升级，须同步 Debug 数据库中已有的官方安装快照。

  test('writing method defers resource location to the tool skill', () async {
    final skill = await loader.get(bundle, '剧本写作');
    expect(skill.version, 3);
    expect(skill.prompt, contains('剧本工具使用规范'));
    expect(skill.prompt, contains('当前作品没有该技能时只交付文本'));
    expect(skill.prompt, isNot(contains('画布作品工具')));
    for (final ref in skill.references) {
      expect(ref.content, isNot(contains('剧本工具使用规范')), reason: ref.path);
      expect(ref.content, isNot(contains('写入剧本工作区')), reason: ref.path);
    }
    expect(
      skill.references
          .singleWhere((ref) => ref.path == 'references/scene-writing.md')
          .content,
      contains('按「工具技能」规定的正文结构'),
    );
    expect(
      skill.references
          .singleWhere((ref) => ref.path == 'references/scene-writing.md')
          .content,
      isNot(contains('未定义的单个字段')),
    );
    expect(
      skill.references
          .singleWhere((ref) => ref.path == 'references/dialogue.md')
          .content,
      contains('小说改稿保留原有叙述格式'),
    );
    final duration = skill.references
        .singleWhere((ref) => ref.path == 'references/duration-estimation.md')
        .content;
    expect(duration, contains('本次要估算的完整正文'));
    expect(duration, isNot(contains('当前集及其场次')));
  });

  test('production method locates material through the tool skill', () {
    final production = File(
      'assets/official_skills/screenplay-production/references/production.md',
    ).readAsStringSync();
    final storyboard = File(
      'assets/official_skills/screenplay-production/references/storyboard.md',
    ).readAsStringSync();
    expect(production, contains('## 从剧本拆分镜'));
    expect(production, contains('按工具技能核对依据'));
    expect(production, isNot(contains('当前集')));
    expect(production, isNot(contains('从场次拆分镜')));
    expect(storyboard, contains('本次剧情依据和目标导演文档'));
    expect(storyboard, isNot(contains('当前场次正文')));
  });

  test('asset content matches the hash registered in the spec table', () async {
    final drifted = <String>[];
    for (final spec in bundledOfficialSkillSpecs) {
      final bytes = BytesBuilder()
        ..add(await File(spec.assetPath).readAsBytes());
      final references = [...spec.referenceAssetPaths]..sort();
      for (final assetPath in references) {
        bytes.add(utf8.encode('\u0000$assetPath\u0000'));
        bytes.add(await File(assetPath).readAsBytes());
      }
      final actual = sha256.convert(bytes.takeBytes()).toString();
      if (actual != spec.contentHash) {
        drifted.add(
          '${spec.name}: spec=${spec.contentHash} actual=$actual '
          '(current version=${spec.version})',
        );
      }
    }

    expect(
      drifted,
      isEmpty,
      reason:
          '以下打包技能的内容与规格表登记的 hash 不一致：\n${drifted.join('\n')}\n\n'
          '如果你确实改了技能内容，请在 lib/shared/services/bundled_official_skills.dart '
          '中按 AGENTS.md 的发布状态规则处理：\n'
          '  1. 核对实际发布记录和标签代码；当前版本已发布才递增 version，'
          '未发布则保持版本号\n'
          '  2. 把 contentHash 更新为上面的 actual 值，并更新 updatedAt\n'
          '  3. 保持版本号时，用 SQLite skill 同步 Debug 数据库中已有的官方安装'
          '快照、附件和相关内容指纹，并查询验证；未安装则无需更新\n'
          'hash 覆盖主文件和按路径排序的所有附件；测试不能代替发布状态核查。',
    );
  });

  test(
    'production notice is packaged without loading it as skill content',
    () async {
      expect(
        await rootBundle.loadString(productionNoticeAssetPath),
        await File(productionNoticeAssetPath).readAsString(),
      );
      final trackingBundle = _FileAssetBundle();
      await loader.get(trackingBundle, '剧本制片');
      expect(
        trackingBundle.loadedPaths,
        isNot(contains(productionNoticeAssetPath)),
      );
    },
  );

  test('spec table and asset directory do not drift', () async {
    final onDisk = Directory(bundledOfficialSkillsAssetDir)
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.path)
        .toSet();
    final inSpec = {
      for (final spec in bundledOfficialSkillSpecs) spec.assetPath,
      for (final spec in bundledOfficialSkillSpecs) ...spec.referenceAssetPaths,
    };
    final packagedFiles = {...inSpec, productionNoticeAssetPath};
    // 技能内容进入规格表，许可文件独立打包。
    expect(
      onDisk.difference(packagedFiles),
      isEmpty,
      reason: '这些文件在 assets/official_skills/ 下但未登记主文件、附件或许可文件。',
    );
    // 规格表有、目录里没有 → 运行时 loadString 会抛错。
    expect(
      packagedFiles.difference(onDisk),
      isEmpty,
      reason: '这些技能资源已登记但文件不存在。',
    );
  });

  test('spec table sort_order and names are unique and contiguous', () {
    expect(
      bundledOfficialSkillSpecs.map((spec) => spec.sortOrder).toList(),
      List.generate(bundledOfficialSkillSpecs.length, (index) => index),
      reason: 'sortOrder 必须从 0 连续递增，且与规格表顺序一致。',
    );
    expect(
      bundledOfficialSkillSpecs.map((spec) => spec.name).toSet(),
      hasLength(bundledOfficialSkillSpecs.length),
      reason: 'name 是官方技能的稳定身份，不能重复。',
    );
  });
}

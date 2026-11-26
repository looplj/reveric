// 职责: 测试 AgentSkillTransferService 的导出（skill 目录/ZIP）与扫描发现。
//   导入写入依赖 InstalledAgentSkillsNotifier，此处覆盖纯 I/O 与解析路径。
// 关联文件:
//   lib/shared/services/agent_skill_transfer.dart
//   lib/shared/services/agent_skill_import_parser.dart
//   lib/shared/models/novel_agent_skill.dart

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/providers/novel_agent_skill_providers.dart';
import 'package:reveric/shared/services/agent_skill_file_store.dart';
import 'package:reveric/shared/services/agent_skill_package.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/services/agent_skill_import_parser.dart';
import 'package:reveric/shared/services/agent_skill_transfer.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('agent_skill_transfer_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  NovelAgentSkillModel makeEntry({
    required String name,
    String description = 'desc',
    String prompt = 'prompt body',
    String category = '',
    List<String> tags = const [],
  }) {
    return NovelAgentSkillModel(
      id: 'id_$name',
      sourceKind: AgentSkillSourceKind.novelLocal,
      name: name,
      description: description,
      prompt: prompt,
      category: category,
      tags: tags,
      createdAt: DateTime(2025, 1, 1),
      updatedAt: DateTime(2025, 1, 1),
    );
  }

  test(
    'folder import, editing and both exports retain package files',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final store = AgentSkillFileStore(() async => tempDir);
      await store.migrateLegacy(db);
      final container = ProviderContainer(
        overrides: [agentSkillFileStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(installedAgentSkillsProvider.notifier);
      final transfer = AgentSkillTransferService(
        temporaryDirectory: () async => tempDir,
      );
      final source = Directory(p.join(tempDir.path, 'source'));
      final skillDir = Directory(p.join(source.path, '中文 skill'));
      final markdown = File(p.join(skillDir.path, 'SKILL.md'));
      await markdown.create(recursive: true);
      await markdown.writeAsString(
        '---\nname: 中文技能\ndescription: desc\n---\nInstructions',
      );
      final resource = File(
        p.join(skillDir.path, 'assets', 'nested', 'raw.bin'),
      );
      await resource.create(recursive: true);
      await resource.writeAsBytes([0, 255, 2]);
      final script = File(p.join(skillDir.path, 'tool.py'));
      await script.create(recursive: true);
      await script.writeAsString('print(42)');
      await File(
        p.join(skillDir.path, 'lib', 'nested', 'fixture'),
      ).create(recursive: true);
      final opaqueReference = await File(
        p.join(skillDir.path, 'references', 'raw.bin'),
      ).create(recursive: true);
      await opaqueReference.writeAsBytes([255, 0]);
      await File(
        p.join(skillDir.path, 'references', 'guide.md'),
      ).writeAsString('guide');
      if (!Platform.isWindows) {
        await Link(
          p.join(skillDir.path, 'assets', 'link.bin'),
        ).create(resource.path);
      }

      for (final ignored in [
        'node_modules',
        '__pycache__',
        '__MACOSX',
        '.cache',
      ]) {
        final file = File(
          p.join(skillDir.path, 'lib', ignored, 'excluded.txt'),
        );
        await file.create(recursive: true);
        await file.writeAsString('exclude');
      }
      final candidate = (await transfer.discoverInDirectory(
        dirPath: source.path,
        existing: [],
      )).single;
      expect(candidate.hasScripts, isTrue);
      // The resource is read when the selected package is copied.
      await resource.writeAsBytes([0, 255, 3]);
      final imported = await transfer.importCandidates(
        candidates: [candidate],
        notifier: notifier,
        existing: [],
      );
      expect(imported.imported, 1, reason: '${imported.failures}');
      final entry = (await notifier.readCurrent()).single;
      expect(entry.references.single.path, 'references/guide.md');
      final edited = await notifier.updateSnapshotFields(
        entry.copyWith(prompt: 'Updated instructions'),
      );
      final stored = Directory(edited.skillRoot!);
      expect(
        stored
            .listSync(recursive: true)
            .whereType<File>()
            .map(
              (file) =>
                  p.split(p.relative(file.path, from: stored.path)).join('/'),
            ),
        unorderedEquals([
          'SKILL.md',
          'tool.py',
          'assets/nested/raw.bin',
          'lib/nested/fixture',
          'references/raw.bin',
          'references/guide.md',
        ]),
      );
      final paths = await transfer.exportToDirectory(
        dirPath: p.join(tempDir.path, 'export'),
        entries: [edited],
      );
      expect(
        await File(
          p.join(p.dirname(paths.single), 'assets', 'nested', 'raw.bin'),
        ).readAsBytes(),
        [0, 255, 3],
      );
      expect(
        await File(p.join(p.dirname(paths.single), 'tool.py')).readAsString(),
        'print(42)',
      );
      final zip = await transfer.exportToZip(
        zipPath: p.join(tempDir.path, 'export.zip'),
        entries: [edited],
      );
      final archive = ZipDecoder().decodeBytes(await File(zip).readAsBytes());
      expect(archive.findFile('中文技能/assets/nested/raw.bin')!.content, [
        0,
        255,
        3,
      ]);
      expect(archive.findFile('中文技能/references/raw.bin')!.content, [255, 0]);
      expect(archive.findFile('中文技能/lib/nested/fixture'), isNotNull);
    },
  );

  test(
    'a failed overwrite keeps the old package and the next skill imports',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final store = AgentSkillFileStore(() async => tempDir);
      await store.migrateLegacy(db);
      final container = ProviderContainer(
        overrides: [agentSkillFileStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(installedAgentSkillsProvider.notifier);
      final old = await notifier.install(
        const InstallSkillInput(
          sourceKind: AgentSkillSourceKind.novelLocal,
          name: 'oversized',
          description: 'Old',
          prompt: 'Old instructions',
        ),
      );
      final sources = Directory(p.join(tempDir.path, 'sources'));
      for (final name in ['oversized', 'other']) {
        final markdown = File(p.join(sources.path, name, 'SKILL.md'));
        await markdown.create(recursive: true);
        await markdown.writeAsString(
          '---\nname: $name\ndescription: desc\n---\nNew instructions',
        );
      }
      final oversized = File(
        p.join(sources.path, 'oversized', 'assets', 'large.bin'),
      );
      await oversized.create(recursive: true);
      final file = await oversized.open(mode: FileMode.write);
      await file.truncate(agentSkillMaxPackageBytes + 1);
      await file.close();

      final cache = await tempDir.createTemp('cache_');
      final transfer = AgentSkillTransferService(
        temporaryDirectory: () async => cache,
      );
      final discovered = await transfer.discoverInDirectory(
        dirPath: sources.path,
        existing: [old],
      );
      expect(discovered, hasLength(2));
      final result = await transfer.importCandidates(
        candidates: [discovered.last, discovered.first],
        notifier: notifier,
        existing: [old],
      );
      expect(result.imported, 1);
      expect(result.failures, [
        (name: 'oversized', reason: AgentSkillImportFailureReason.too_large),
      ]);
      expect(await cache.list().toList(), isEmpty);
      final installed = await notifier.readCurrent();
      expect(installed.map((entry) => entry.name), ['oversized', 'other']);
      expect(installed.first.id, old.id);
      expect(installed.first.skillRoot, old.skillRoot);
      expect(installed.first.prompt, 'Old instructions');
    },
  );

  test(
    'folder and ZIP export preserve an installed resource over 64 MiB',
    () async {
      const transfer = AgentSkillTransferService();
      final skillRoot = await tempDir.createTemp('source_');
      final asset = await File(
        p.join(skillRoot.path, 'assets', 'large.bin'),
      ).create(recursive: true);
      final handle = await asset.open(mode: FileMode.write);
      const size = 65 * 1024 * 1024;
      await handle.truncate(size);
      await handle.setPosition(size - 1);
      await handle.writeByte(42);
      await handle.close();

      final entries = [
        makeEntry(name: 'large').copyWith(skillRoot: skillRoot.path),
      ];
      final staged = await tempDir.createTemp('export_');
      await transfer.exportToDirectory(dirPath: staged.path, entries: entries);
      expect(
        await File(
          p.join(staged.path, 'large', 'assets', 'large.bin'),
        ).length(),
        size,
      );
      final zip = await transfer.exportToZip(
        zipPath: p.join(tempDir.path, 'output.zip'),
        entries: entries,
      );
      final input = InputFileStream(zip);
      try {
        final directory = ZipDirectory()..read(input);
        final header = directory.fileHeaders.singleWhere(
          (h) => h.filename == 'large/assets/large.bin',
        );
        expect(header.uncompressedSize, size);
        expect(header.compressedSize, size);
      } finally {
        await input.close();
      }
    },
  );

  group('exportToDirectory', () {
    test('writes skill-name/SKILL.md layout', () async {
      final entries = [
        makeEntry(name: '扩写场景', category: '扩写', tags: ['节奏']),
        makeEntry(name: '爽文节奏', category: '节奏'),
      ];
      final service = const AgentSkillTransferService();

      final paths = await service.exportToDirectory(
        dirPath: tempDir.path,
        entries: entries,
      );

      expect(paths.length, 2);
      for (final path in paths) {
        expect(p.basename(path), 'SKILL.md');
        expect(File(path).existsSync(), isTrue);
        final parsed = AgentSkillImportParser.parse(
          File(path).readAsStringSync(),
        );
        expect(parsed, isNotNull, reason: '$path should be parseable');
      }

      expect(
        paths.any((path) => path.contains('${p.separator}扩写场景${p.separator}')),
        isTrue,
      );
    });

    test('handles duplicate names with suffix dirs', () async {
      final entries = [makeEntry(name: '同名技能'), makeEntry(name: '同名技能')];
      final service = const AgentSkillTransferService();

      final paths = await service.exportToDirectory(
        dirPath: tempDir.path,
        entries: entries,
      );

      expect(paths.length, 2);
      expect(p.basename(p.dirname(paths[0])), '同名技能');
      expect(p.basename(p.dirname(paths[1])), '同名技能 (2)');
    });

    test('sanitizes illegal directory characters', () async {
      final entries = [makeEntry(name: 'a/b:c*d?e')];
      final service = const AgentSkillTransferService();

      final paths = await service.exportToDirectory(
        dirPath: tempDir.path,
        entries: entries,
      );

      final dirName = p.basename(p.dirname(paths[0]));
      expect(dirName, isNot(contains('/')));
      expect(dirName, isNot(contains(':')));
      expect(dirName, isNot(contains('*')));
      expect(dirName, isNot(contains('?')));
    });

    test('creates directory if not exists', () async {
      final subDir = p.join(tempDir.path, 'nested', 'deep');
      final entries = [makeEntry(name: 'test')];
      final service = const AgentSkillTransferService();

      final paths = await service.exportToDirectory(
        dirPath: subDir,
        entries: entries,
      );

      expect(File(paths[0]).existsSync(), isTrue);
    });
  });

  group('exportToZip', () {
    test('writes a valid zip containing all entries', () async {
      final entries = [
        makeEntry(name: '技能A', category: '扩写', tags: ['x']),
        makeEntry(name: '技能B'),
      ];
      final zipPath = p.join(tempDir.path, 'export.zip');
      final service = const AgentSkillTransferService();

      final result = await service.exportToZip(
        zipPath: zipPath,
        entries: entries,
      );

      expect(result, zipPath);
      expect(File(zipPath).existsSync(), isTrue);
      expect(File(zipPath).lengthSync(), greaterThan(0));
    });
  });

  group('discoverInDirectory', () {
    test('finds nested SKILL.md and marks name conflicts', () async {
      final skillDir = Directory(p.join(tempDir.path, '扩写场景'))..createSync();
      File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync(
        AgentSkillImportParser.write(
          name: '扩写场景',
          description: 'desc',
          body: 'body',
          category: '扩写',
        ),
      );
      // Nested reference.md should be ignored.
      File(p.join(skillDir.path, 'notes.md')).writeAsStringSync('# notes');

      final service = const AgentSkillTransferService();
      final candidates = await service.discoverInDirectory(
        dirPath: tempDir.path,
        existing: [makeEntry(name: '扩写场景')],
      );

      expect(candidates.length, 1);
      expect(candidates.first.name, '扩写场景');
      expect(candidates.first.nameConflict, isTrue);
      expect(candidates.first.category, '扩写');
    });
  });

  group('discoverFromFiles', () {
    test('parses a single selected markdown file', () async {
      final file = File(p.join(tempDir.path, 'legacy.md'))
        ..writeAsStringSync(
          AgentSkillImportParser.write(
            name: '单文件技能',
            description: 'd',
            body: 'b',
          ),
        );

      final service = const AgentSkillTransferService();
      final candidates = await service.discoverFromFiles(
        filePaths: [file.path],
        existing: const [],
      );

      expect(candidates.length, 1);
      expect(candidates.first.name, '单文件技能');
      expect(candidates.first.nameConflict, isFalse);
    });
  });

  group('round-trip export -> parse', () {
    test('exported SKILL.md can be re-parsed with all fields', () async {
      final entries = [
        makeEntry(
          name: '完整技能',
          description: '完整描述',
          prompt: '# 指令\n详细步骤...',
          category: '扩写',
          tags: ['节奏', '爽文'],
        ),
      ];
      final service = const AgentSkillTransferService();

      final paths = await service.exportToDirectory(
        dirPath: tempDir.path,
        entries: entries,
      );

      final content = File(paths[0]).readAsStringSync();
      final parsed = AgentSkillImportParser.parse(content)!;

      expect(p.basename(paths[0]), 'SKILL.md');
      expect(parsed.name, '完整技能');
      expect(parsed.description, '完整描述');
      expect(parsed.body, '# 指令\n详细步骤...');
      expect(parsed.category, '扩写');
      expect(parsed.tags, ['节奏', '爽文']);
    });
  });
}

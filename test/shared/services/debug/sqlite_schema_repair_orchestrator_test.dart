// 职责: 验证 SQLite schema 修复可补齐主库和小说内容库的缺失结构。
// 关联文件:
//   lib/shared/services/debug/sqlite_schema_repair_orchestrator.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/debug/sqlite_schema_repair_orchestrator.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late Directory appSupportDir;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'app_database_schema_repair_test_',
    );
    appSupportDir = Directory(p.join(tempRoot.path, 'support'));
    await appSupportDir.create(recursive: true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              return appSupportDir.path;
            }
            return null;
          },
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test(
    'repairs a relative registration outside the workspace directory',
    () async {
      final registeredDirectory = await Directory(
        p.join(appSupportDir.path, 'restored_works'),
      ).create();
      final contentPath = p.join(registeredDirectory.path, 'story.sqlite');
      sqlite3.open(contentPath).close();
      final app = AppDatabase.forSchemaRepair(
        NativeDatabase(File(p.join(appSupportDir.path, 'reveric.sqlite'))),
      );
      try {
        await app.novelDao.create(
          id: 'restored',
          title: 'Restored work',
          description: '',
          contentDatabasePath: r'restored_works\story.sqlite',
        );
      } finally {
        await app.close();
      }

      final result = await SqliteSchemaRepairOrchestrator().repair();

      expect(result.success, isTrue);
      final repaired = sqlite3.open(contentPath, mode: OpenMode.readOnly);
      try {
        expect(
          repaired.select(
            "SELECT name FROM sqlite_master WHERE name = 'chapter_nodes'",
          ),
          hasLength(1),
        );
      } finally {
        repaired.close();
      }
    },
  );

  test(
    'repairs current schema without restoring removed legacy structures',
    () async {
      final appDatabasePath = p.join(appSupportDir.path, 'reveric.sqlite');
      final workspaceDirectory = Directory(
        p.join(appSupportDir.path, 'novel_workspaces'),
      );
      await workspaceDirectory.create(recursive: true);
      final contentDatabasePath = p.join(
        workspaceDirectory.path,
        'novel_1.sqlite',
      );

      final appDatabase = sqlite3.open(appDatabasePath);
      try {
        appDatabase.execute('PRAGMA user_version = 20');
      } finally {
        appDatabase.close();
      }
      final contentDatabase = sqlite3.open(contentDatabasePath);
      try {
        contentDatabase.execute('PRAGMA user_version = 10');
      } finally {
        contentDatabase.close();
      }

      final result = await SqliteSchemaRepairOrchestrator().repair();

      expect(result.success, isTrue);
      final repaired = sqlite3.open(appDatabasePath, mode: OpenMode.readOnly);
      try {
        final tables = repaired
            .select(
              "SELECT name FROM sqlite_master WHERE type = 'table' "
              "AND name IN ("
              "'novels', "
              "'agent_skill_library_entries', 'novel_agent_skills'"
              ')',
            )
            .map((row) => row['name'])
            .toSet();
        expect(tables, containsAll(<String>{'novels', 'novel_agent_skills'}));
        expect(tables, isNot(contains('agent_skill_library_entries')));

        final indexes = repaired
            .select(
              "SELECT name FROM sqlite_master WHERE type = 'index' "
              "AND name IN ("
              "'novel_agent_skills_by_name_u', "
              "'novel_agent_skills_by_source_listing_public_id', "
              "'novel_agent_skills_by_sort_order', "
              "'novel_agent_skills_by_novel_id', "
              "'agent_skill_library_entries_by_category'"
              ')',
            )
            .map((row) => row['name'])
            .toSet();
        expect(
          indexes,
          containsAll(<String>{
            'novel_agent_skills_by_name_u',
            'novel_agent_skills_by_source_listing_public_id',
            'novel_agent_skills_by_sort_order',
          }),
        );
        expect(indexes, isNot(contains('novel_agent_skills_by_novel_id')));
        expect(
          indexes,
          isNot(contains('agent_skill_library_entries_by_category')),
        );
      } finally {
        repaired.close();
      }

      final repairedContent = sqlite3.open(
        contentDatabasePath,
        mode: OpenMode.readOnly,
      );
      try {
        final tables = repairedContent
            .select(
              "SELECT name FROM sqlite_master WHERE type = 'table' "
              "AND name IN ('chapter_nodes', 'documents', 'ai_chat_messages')",
            )
            .map((row) => row['name'])
            .toSet();
        expect(
          tables,
          containsAll(<String>{
            'chapter_nodes',
            'documents',
            'ai_chat_messages',
          }),
        );
      } finally {
        repairedContent.close();
      }
    },
  );
}

// 职责: 验证初始化数据库保留作品数据能力且不再创建已移除功能的表。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/app_database_indexes.dart
//   lib/shared/database/novel_content_database.dart

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';

void main() {
  for (final hasAudioColumn in [false, true]) {
    test(
      'v1 clips migrate with ${hasAudioColumn ? 'existing' : 'nullable'} audio preference and preserved data',
      () async {
        // v0.4.0 production_clips table and its scene index.
        final database = NovelContentDatabase.forTest(
          NativeDatabase.memory(
            setup: (db) {
              db.execute("""
          CREATE TABLE production_clips (
            inputs TEXT NOT NULL DEFAULT '[]', character_id TEXT,
            location_id TEXT, item_id TEXT, style_selection TEXT,
            last_applied_generation_task_id TEXT, id TEXT NOT NULL PRIMARY KEY,
            episode_id TEXT NOT NULL, kind TEXT NOT NULL, scene_id TEXT,
            sort_order INTEGER, title TEXT NOT NULL DEFAULT '',
            prompt TEXT NOT NULL DEFAULT '',
            error_dismissed INTEGER NOT NULL DEFAULT 0 CHECK (error_dismissed IN (0, 1)),
            provider_id TEXT, model_id TEXT,
            reference_mode TEXT NOT NULL DEFAULT 'reference', duration_ms INTEGER,
            ratio TEXT NOT NULL DEFAULT '9:16', resolution TEXT NOT NULL DEFAULT '720p',
            adopted_asset_id TEXT, created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL, deleted_at INTEGER NOT NULL DEFAULT 0
          );
          CREATE INDEX production_clips_by_scene_id_deleted_at_sort_order
            ON production_clips (scene_id, deleted_at, sort_order);
          INSERT INTO production_clips
            (id, episode_id, kind, title, prompt, created_at, updated_at)
            VALUES ('clip', 'episode', 'video', 'Original', 'Rain', 123, 456);
          PRAGMA user_version = 1;
        """);
              if (hasAudioColumn) {
                db.execute(
                  'ALTER TABLE production_clips ADD COLUMN generate_audio INTEGER',
                );
                db.execute('UPDATE production_clips SET generate_audio = 1');
              }
            },
          ),
        );
        addTearDown(database.close);
        final clips = await database.select(database.productionClips).get();
        expect(clips, hasLength(1));
        expect(clips.single.id, 'clip');
        expect(clips.single.title, 'Original');
        expect(clips.single.prompt, 'Rain');
        expect(clips.single.generateAudio, hasAudioColumn ? isTrue : isNull);
        expect(
          (await database.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          NovelContentDatabase.currentSchemaVersion,
        );
        final columns = await database
            .customSelect('PRAGMA table_info(production_clips)')
            .get();
        expect(
          columns
              .singleWhere((c) => c.read<String>('name') == 'id')
              .read<int>('pk'),
          1,
        );
        expect(
          columns
              .singleWhere((c) => c.read<String>('name') == 'generate_audio')
              .read<String>('type'),
          'INTEGER',
        );
        final indexes = await database
            .customSelect('PRAGMA index_list(production_clips)')
            .get();
        expect(
          indexes.map((i) => i.read<String>('name')),
          contains('production_clips_by_scene_id_deleted_at_sort_order'),
        );
        await database.customStatement(
          'UPDATE production_clips SET generate_audio = 0',
        );
        expect(
          (await database.select(database.productionClips).getSingle())
              .generateAudio,
          isFalse,
        );
        expect(
          (await database
                  .customSelect(
                    'SELECT typeof(generate_audio) AS type FROM production_clips',
                  )
                  .getSingle())
              .read<String>('type'),
          'integer',
        );
      },
    );
  }

  test('fresh schema excludes removed feature tables', () async {
    final database = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(database.close);
    final tables = await database
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    final names = tables.map((row) => row.read<String>('name')).toSet();
    expect(
      names,
      containsAll([
        'novels',
        'ai_chat_sessions',
        'generation_tasks',
        'provider_assets',
        'todos',
        'assets',
        'ai_usages',
      ]),
    );
    for (final removed in [
      'ai_credit_usages',
      'craft_assets',
      'tasks',
      'tips',
      'focus_periods',
      'humanize_history_entries',
      'breakdown_runs',
      'breakdown_run_items',
      'artifact_shares',
    ]) {
      expect(names, isNot(contains(removed)));
    }
    final usageColumns = await database
        .customSelect('PRAGMA table_info(ai_usages)')
        .get();
    final usageNames = usageColumns.map((row) => row.read<String>('name'));
    expect(usageNames, containsAll(['input_tokens', 'output_tokens']));
    expect(usageNames, isNot(contains('credits')));
    expect(usageNames, isNot(contains('pricing_rate_id')));
    final providerColumns = await database
        .customSelect('PRAGMA table_info(ai_providers)')
        .get();
    for (final name in [
      'access_key_id',
      'secret_access_key',
      'asset_project_name',
      'config',
    ]) {
      final column = providerColumns.singleWhere(
        (row) => row.read<String>('name') == name,
      );
      expect(column.read<String>('type'), 'TEXT');
      expect(column.read<int>('notnull'), 0);
    }
    final certificationIndexes = await database
        .customSelect('PRAGMA index_list(provider_assets)')
        .get();
    expect(
      certificationIndexes.map((row) => row.read<String>('name')),
      containsAll([
        'provider_assets_by_asset_id_provider_id',
        'provider_assets_by_status',
      ]),
    );
    await database.novelDao.create(
      id: 'novel',
      title: 'Novel',
      description: '',
    );
    expect(
      (await database.select(database.novels).get()).single.title,
      'Novel',
    );
  });

  test(
    'content schema keeps writing tables without analysis results',
    () async {
      final database = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(database.close);
      final tables = await database
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
          .get();
      final names = tables.map((row) => row.read<String>('name')).toSet();
      expect(
        names,
        containsAll(['chapter_nodes', 'documents', 'character_profiles']),
      );
      for (final removed in [
        'breakdown_chapters',
        'breakdown_reports',
        'breakdown_documents',
        'breakdown_characters',
      ]) {
        expect(names, isNot(contains(removed)));
      }
    },
  );
  test('fresh schemas contain current business columns only', () async {
    final app = AppDatabase.forTest(NativeDatabase.memory());
    final content = NovelContentDatabase.forTest(NativeDatabase.memory());
    addTearDown(app.close);
    addTearDown(content.close);
    for (final (table, removed) in [
      ('novels', 'ai_settings'),
      ('ai_providers', 'max_tokens'),
    ]) {
      final columns = await app.customSelect('PRAGMA table_info($table)').get();
      expect(
        columns.map((row) => row.read<String>('name')),
        isNot(contains(removed)),
      );
    }
    for (final table in ['screenplay_episodes', 'screenplay_scenes']) {
      final columns = await content
          .customSelect('PRAGMA table_info($table)')
          .get();
      expect(
        columns.map((row) => row.read<String>('name')),
        isNot(contains('target_duration_seconds')),
      );
      expect(
        columns.map((row) => row.read<String>('name')),
        isNot(contains('estimated_duration_seconds')),
      );
    }
    final characterColumns = await content
        .customSelect('PRAGMA table_info(character_profiles)')
        .get();
    final names = characterColumns.map((row) => row.read<String>('name'));
    expect(names, contains('biography'));
    expect(names, isNot(contains('summary')));
    await content
        .into(content.characterProfiles)
        .insert(
          CharacterProfilesCompanion.insert(id: 'character', name: 'Character'),
        );
    expect(
      (await content.select(content.characterProfiles).getSingle()).biography,
      '',
    );
  });
}

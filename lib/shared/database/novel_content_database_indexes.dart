// 职责: 创建作品内容数据库首次建库所需的索引。
// 关联文件:
//   lib/shared/database/novel_content_database.dart
// 遵循的 Rules:
//   .agents/rules/db-index-naming.md
import 'package:drift/drift.dart';

Future<void> createNovelContentDatabaseIndexes(
  GeneratedDatabase database,
) async {
  await createChapterHighlightsIndex(database);
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS documents_by_type_parent_id_title_u '
    "ON documents (type, COALESCE(parent_id, ''), title) "
    "WHERE deleted_at = 0 AND title <> ''",
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS canvas_nodes_by_canvas_id '
    'ON canvas_nodes (canvas_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS canvas_edges_by_canvas_id '
    'ON canvas_edges (canvas_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS canvas_edges_by_source '
    'ON canvas_edges (source_node_id)',
  );
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS canvas_edges_unique '
    'ON canvas_edges (canvas_id, source_node_id, target_node_id, type)',
  );
  // 画布名是 AI 路径 `/canvas/{name}` 的主键，必须唯一。
  // 部分索引跳过软删记录：删掉「主线」之后必须还能再建一张「主线」。
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS canvases_by_name_u '
    'ON canvases (name) WHERE deleted_at = 0',
  );
  const statements = <String>[
    'CREATE UNIQUE INDEX IF NOT EXISTS screenplays_by_deleted_at_u '
        'ON screenplays (deleted_at) WHERE deleted_at = 0',
    'CREATE UNIQUE INDEX IF NOT EXISTS screenplay_seasons_by_screenplay_id_season_number_u '
        'ON screenplay_seasons (screenplay_id, season_number) WHERE deleted_at = 0',
    'CREATE INDEX IF NOT EXISTS screenplay_seasons_by_screenplay_id_season_number '
        'ON screenplay_seasons (screenplay_id, season_number)',
    'CREATE UNIQUE INDEX IF NOT EXISTS screenplay_episodes_by_season_id_episode_number_u '
        'ON screenplay_episodes (season_id, episode_number) WHERE deleted_at = 0',
    'CREATE INDEX IF NOT EXISTS screenplay_episodes_by_screenplay_id_season_id_episode_number '
        'ON screenplay_episodes (screenplay_id, season_id, episode_number)',
    'CREATE INDEX IF NOT EXISTS screenplay_scenes_by_screenplay_id_episode_id '
        'ON screenplay_scenes (screenplay_id, episode_id)',
    'CREATE INDEX IF NOT EXISTS screenplay_scenes_by_beat_id '
        'ON screenplay_scenes (beat_id)',
    'CREATE UNIQUE INDEX IF NOT EXISTS screenplay_beats_by_episode_id_act_number_sort_order_u '
        'ON screenplay_beats (episode_id, act_number, sort_order) WHERE deleted_at = 0',
    'CREATE INDEX IF NOT EXISTS screenplay_beats_by_screenplay_id_episode_id_act_number_sort_order '
        'ON screenplay_beats (screenplay_id, episode_id, act_number, sort_order)',
    'CREATE UNIQUE INDEX IF NOT EXISTS screenplay_scene_characters_by_scene_id_character_id_u '
        'ON screenplay_scene_characters (scene_id, character_id) WHERE deleted_at = 0',
    'CREATE INDEX IF NOT EXISTS screenplay_scene_characters_by_scene_id_sort_order '
        'ON screenplay_scene_characters (scene_id, sort_order)',
    'CREATE INDEX IF NOT EXISTS screenplay_scene_characters_by_character_id '
        'ON screenplay_scene_characters (character_id)',
    'CREATE UNIQUE INDEX IF NOT EXISTS screenplay_scene_elements_by_episode_id_sort_order_u '
        'ON screenplay_scene_elements (episode_id, sort_order) WHERE deleted_at = 0',
    'CREATE INDEX IF NOT EXISTS screenplay_scene_elements_by_scene_id_sort_order '
        'ON screenplay_scene_elements (scene_id, sort_order)',
    'CREATE UNIQUE INDEX IF NOT EXISTS screenplay_scene_elements_by_scene_id_type_u '
        "ON screenplay_scene_elements (scene_id, type) WHERE deleted_at = 0 AND type = 'scene_heading'",
    'CREATE INDEX IF NOT EXISTS screenplay_scene_elements_by_location_id '
        'ON screenplay_scene_elements (location_id)',
    'CREATE INDEX IF NOT EXISTS screenplay_scene_elements_by_character_id '
        'ON screenplay_scene_elements (character_id)',
  ];
  for (final statement in statements) {
    await database.customStatement(statement);
  }
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS entity_relations_by_scene_id '
    'ON entity_relations (scene_id)',
  );
  for (final endpoint in ['source', 'target']) {
    await database.customStatement(
      'CREATE INDEX IF NOT EXISTS entity_relations_by_${endpoint}_type_${endpoint}_id_status '
      'ON entity_relations (${endpoint}_type, ${endpoint}_id, status)',
    );
  }
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS revisions_by_entity_type_entity_id_version_u '
    'ON revisions (entity_type, entity_id, version)',
  );
  for (final subject in ['character_id', 'location_id']) {
    await database.customStatement(
      'CREATE INDEX IF NOT EXISTS production_clips_by_${subject}_deleted_at ON production_clips ($subject, deleted_at)',
    );
  }
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS canvas_nodes_by_ref_type_ref_id_deleted_at ON canvas_nodes (ref_type, ref_id, deleted_at)',
  );

  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS production_clips_by_scene_id_deleted_at_sort_order ON production_clips (scene_id, deleted_at, sort_order)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS canvas_nodes_by_parent_id ON canvas_nodes (parent_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS video_editings_by_deleted_at_updated_at ON video_editings (deleted_at, updated_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS screenplay_episodes_by_editing_id ON screenplay_episodes (editing_id)',
  );
}

Future<void> createChapterHighlightsIndex(GeneratedDatabase database) {
  return database.customStatement(
    'CREATE INDEX IF NOT EXISTS chapter_highlights_by_chapter_id_deleted_at '
    'ON chapter_highlights (chapter_id, deleted_at)',
  );
}

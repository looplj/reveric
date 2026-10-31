// 职责: 创建应用数据库首次建库所需的索引。
// 关联文件:
//   lib/shared/database/app_database.dart
// 遵循的 Rules:
//   .agents/rules/db-index-naming.md
import 'package:drift/drift.dart';

Future<void> createAppDatabaseIndexes(GeneratedDatabase database) async {
  await createPluginTaskIndexes(database);
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS provider_assets_by_asset_id_provider_id '
    'ON provider_assets (asset_id, provider_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS provider_assets_by_status '
    'ON provider_assets (status)',
  );
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS tool_permission_rules_by_scope_type_work_id_scope_id_action_u ON tool_permission_rules(scope_type, work_id, scope_id, action)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS generation_tasks_by_draft_task_id_deleted_at '
    'ON generation_tasks (draft_task_id, deleted_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS generation_tasks_by_novel_id_source_type_source_id_deleted_at '
    'ON generation_tasks (novel_id, source_type, source_id, deleted_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS generation_tasks_by_kind_status_next_poll_at '
    'ON generation_tasks (kind, status, next_poll_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS novel_collection_members_by_novel_id '
    'ON novel_collection_members (novel_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS anonymous_outbox_events_by_next_retry_at_priority_id '
    'ON anonymous_outbox_events (next_retry_at, priority, id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS anonymous_outbox_events_by_endpoint_product_code_device_id_next_retry_at_id '
    'ON anonymous_outbox_events '
    '(endpoint, product_code, device_id, next_retry_at, id)',
  );
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS novel_agent_skills_by_name_u '
    'ON novel_agent_skills (name)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS novel_agent_skills_by_source_listing_public_id '
    'ON novel_agent_skills (source_listing_public_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS novel_agent_skills_by_sort_order '
    'ON novel_agent_skills (sort_order)',
  );
  await database.customStatement('''
CREATE UNIQUE INDEX novels_shelf_title_u
ON novels (title)
WHERE deleted_at = 0 AND draft = 0
''');
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS ai_usages_by_created_at '
    'ON ai_usages (created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS ai_usages_by_session_id_created_at '
    'ON ai_usages (session_id, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS ai_usages_by_source_created_at '
    'ON ai_usages (source, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS '
    'novel_agent_skill_revisions_by_skill_id_created_at '
    'ON novel_agent_skill_revisions (skill_id, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS '
    'novel_agent_skill_revisions_by_skill_id_turn_id '
    'ON novel_agent_skill_revisions (skill_id, turn_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS '
    'novel_agent_skill_revision_files_by_sha256 '
    'ON novel_agent_skill_revision_files (sha256)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assets_by_novel_purpose_deleted_created_id '
    'ON assets (novel_id, purpose, deleted_at, created_at, id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assets_by_sha256 ON assets (sha256)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assets_by_batch ON assets (batch_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assets_by_type_novel_id_deleted_at_created_at '
    'ON assets (type, novel_id, deleted_at, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS image_asset_references_by_asset_ordinal '
    'ON image_asset_references (asset_id, ordinal)',
  );
  // 一个批次的同一个序号只能有一个格子：重出是就地替换，不是追加一行。
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS image_batch_slots_by_batch_id_ordinal_u '
    'ON image_batch_slots (batch_id, ordinal)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assistant_messages_by_session_created '
    'ON assistant_messages (session_id, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assistant_inbox_by_session_created '
    'ON assistant_inbox (assistant_session_id, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS novels_by_source_novel_id '
    'ON novels (source_novel_id)',
  );
}

Future<void> createPluginTaskIndexes(
  GeneratedDatabase database,
) => database.customStatement(
  'CREATE INDEX IF NOT EXISTS plugin_tasks_by_enabled_next_due_at ON plugin_tasks(enabled, next_due_at)',
);

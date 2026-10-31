CREATE TABLE memories (
  id TEXT NOT NULL PRIMARY KEY, work_id TEXT, content TEXT NOT NULL,
  category TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 0,
  enabled INTEGER NOT NULL DEFAULT 1, revision INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER
);
CREATE INDEX memories_by_work_id_deleted_at_priority_updated_at ON memories(work_id, deleted_at, priority, updated_at);
CREATE TABLE suggestions (
  id TEXT NOT NULL PRIMARY KEY, memory_id TEXT NOT NULL, source_revision INTEGER NOT NULL,
  content TEXT NOT NULL, category TEXT NOT NULL, run_id TEXT NOT NULL,
  status TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX suggestions_by_memory_id_source_revision_u ON suggestions(memory_id, source_revision);

CREATE TABLE memories_v2 (
  id TEXT NOT NULL PRIMARY KEY,
  content TEXT NOT NULL,
  topic TEXT NOT NULL DEFAULT '',
  priority INTEGER NOT NULL DEFAULT 0,
  enabled INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'active',
  superseded_by TEXT,
  revision INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);

INSERT INTO memories_v2 (
  id, content, topic, priority, enabled, status, superseded_by,
  revision, created_at, updated_at, deleted_at
)
SELECT
  id,
  content,
  CASE category
    WHEN 'preference' THEN '偏好'
    WHEN 'fact' THEN '事实'
    WHEN 'instruction' THEN '要求'
    ELSE ''
  END,
  priority,
  enabled,
  'active',
  NULL,
  revision,
  created_at,
  updated_at,
  deleted_at
FROM memories;

DROP TABLE memories;
ALTER TABLE memories_v2 RENAME TO memories;
CREATE INDEX memories_active_order ON memories(deleted_at, status, enabled, priority, updated_at);

DROP TABLE suggestions;
CREATE TABLE suggestions (
  id TEXT NOT NULL PRIMARY KEY,
  kind TEXT NOT NULL,
  reason TEXT NOT NULL,
  proposed_content TEXT,
  proposed_topic TEXT NOT NULL DEFAULT '',
  proposed_priority INTEGER,
  fingerprint TEXT NOT NULL,
  run_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX suggestions_by_fingerprint_u ON suggestions(fingerprint);
CREATE INDEX suggestions_by_status_created_at ON suggestions(status, created_at);

CREATE TABLE suggestion_sources (
  suggestion_id TEXT NOT NULL,
  memory_id TEXT NOT NULL,
  source_revision INTEGER NOT NULL,
  PRIMARY KEY (suggestion_id, memory_id)
);
CREATE INDEX suggestion_sources_by_memory_id ON suggestion_sources(memory_id);

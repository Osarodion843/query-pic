-- QueryPic index DB schema v1 (Phase 0, revised Phase 2).
-- Air-gapped SQLite: embeddings + token index + metadata. 8-bit vectors target <=25MB/10k files.
-- NOTE: FTS5 was dropped (see tokens table below). sqflite uses the Android
-- system SQLite, and OEM builds (e.g. Transsion/itel) may not compile the
-- FTS5 module ("no such module: fts5" on device). A plain token table works
-- on every SQLite >= 3.0 with zero native dependencies.
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS files (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  uri       TEXT NOT NULL UNIQUE,
  type      TEXT NOT NULL CHECK (type IN ('photo','video')),
  mtime     INTEGER NOT NULL,
  size      INTEGER,
  width     INTEGER,
  height    INTEGER,
  duration  REAL,
  hash      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS embeddings (
  file_id   INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  vec_int8  BLOB NOT NULL,
  model_ver TEXT NOT NULL,
  PRIMARY KEY (file_id, model_ver)
);

CREATE TABLE IF NOT EXISTS ocr (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE PRIMARY KEY,
  text    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS frames (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  t       REAL NOT NULL,
  vec_int8 BLOB NOT NULL,
  PRIMARY KEY (file_id, t)
);

CREATE TABLE IF NOT EXISTS transcripts (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  t_start REAL NOT NULL,
  t_end   REAL NOT NULL,
  text    TEXT NOT NULL,
  PRIMARY KEY (file_id, t_start)
);

CREATE TABLE IF NOT EXISTS audit_log (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,
  ts     INTEGER NOT NULL,
  event  TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT ''
);

-- Token index (replaces FTS5): one row per (kind, token, ref_id).
-- Tokenizer contract (mirrored in IndexDatabase.tokenizeForIndex and in the
-- Python harnesses): lowercase, split on [^a-z0-9]+, drop tokens shorter
-- than 2 chars, dedupe per document.
-- Lookup: SELECT ref_id FROM tokens WHERE kind=? AND token IN (...)
--         GROUP BY ref_id ORDER BY COUNT(*) DESC [, LIMIT ?]
CREATE TABLE IF NOT EXISTS tokens (
  kind   TEXT NOT NULL,
  token  TEXT NOT NULL,
  ref_id INTEGER NOT NULL,
  PRIMARY KEY (kind, token, ref_id)
);
CREATE INDEX IF NOT EXISTS idx_tokens_token ON tokens(token);

-- SpatialBoard web companion — Aurora Serverless v2 PostgreSQL schema
-- Run once against the cluster (psql or RDS Data API) after enabling pgvector.
-- See docs/AWS_PLAN.md §4.

CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id          uuid PRIMARY KEY,
    email       text UNIQUE NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Spaces — the website's top-level tabs
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS spaces (
    id          uuid PRIMARY KEY,
    user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        text NOT NULL,
    color_hex   text NOT NULL DEFAULT '#4A90D9',
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Folders — explicit user grouping carried over from the app
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS folders (
    id          uuid PRIMARY KEY,
    space_id    uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    name        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Notes — a spatially-clustered group of strokes; the unit the web displays.
-- Populated by the ingest Lambda, enriched by the process Lambda.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notes (
    id            uuid PRIMARY KEY,
    space_id      uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    folder_id     uuid REFERENCES folders(id) ON DELETE SET NULL,  -- null = free in world
    title         text,                       -- Bedrock Claude-generated
    ocr_text      text,                        -- Bedrock OCR
    category      text,                        -- Bedrock Claude-assigned
    svg           text,                        -- projected handwriting (2D)
    search_vector tsvector,                    -- keyword search
    embedding     vector(1024),                -- Titan v2 embedding, semantic search
    world_origin  jsonb,                       -- "where you wrote it" cue
    pinned        boolean NOT NULL DEFAULT false,  -- user-pinned to top of the list
    status        text NOT NULL DEFAULT 'pending',  -- pending | processed | failed
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Strokes — raw 3D geometry, stored as JSONB blobs (loaded whole, never queried inside)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS strokes (
    id          uuid PRIMARY KEY,
    note_id     uuid REFERENCES notes(id) ON DELETE CASCADE,
    space_id    uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    geometry    jsonb NOT NULL,               -- { points: [...], bezierSegments: [...] }
    color       text,
    thickness   real,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
-- Semantic search (cosine). ivfflat needs ANALYZE after data load; lists tunable.
CREATE INDEX IF NOT EXISTS notes_embedding_idx
    ON notes USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- Keyword search
CREATE INDEX IF NOT EXISTS notes_search_idx
    ON notes USING gin (search_vector);

-- Web access patterns
CREATE INDEX IF NOT EXISTS notes_space_idx   ON notes (space_id);
CREATE INDEX IF NOT EXISTS notes_category_idx ON notes (space_id, category);
CREATE INDEX IF NOT EXISTS strokes_note_idx  ON strokes (note_id);
CREATE INDEX IF NOT EXISTS folders_space_idx ON folders (space_id);

-- ---------------------------------------------------------------------------
-- Note sharing — a note shared by its owner with another user (by email).
-- mode controls what the recipient sees: 'strokes' (handwriting only),
-- 'text' (transcription only), or 'both'.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS note_shares (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    note_id      uuid NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    owner_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    mode         text NOT NULL DEFAULT 'both',
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (note_id, recipient_id)
);
CREATE INDEX IF NOT EXISTS note_shares_recipient_idx ON note_shares (recipient_id);

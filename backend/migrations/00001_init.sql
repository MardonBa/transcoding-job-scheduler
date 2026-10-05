-- +goose Up

CREATE TYPE job_status AS ENUM (
    'PENDING_UPLOAD', 'QUEUED', 'RUNNING',
    'SUCCESS', 'PARTIAL_SUCCESS', 'FAILED', 'CANCELED', 'EXPIRED'
);

CREATE TYPE task_status AS ENUM (
    'PENDING_UPLOAD', 'QUEUED', 'RUNNING', 'RETRYING',
    'SUCCESS', 'FAILED', 'CANCELED', 'EXPIRED'
);

CREATE TABLE users (
    id          UUID PRIMARY KEY,
    google_sub  TEXT NOT NULL UNIQUE,
    email       TEXT NOT NULL,
    name        TEXT NOT NULL DEFAULT '',
    avatar_url  TEXT NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE jobs (
    id                        UUID PRIMARY KEY,
    user_id                   UUID NOT NULL REFERENCES users (id),
    name                      TEXT NOT NULL,
    status                    job_status NOT NULL DEFAULT 'PENDING_UPLOAD',
    task_count                INT NOT NULL CHECK (task_count > 0),
    idempotency_key           TEXT NOT NULL,
    idempotency_request_hash  TEXT NOT NULL,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at               TIMESTAMPTZ,
    UNIQUE (user_id, idempotency_key)
);

CREATE TABLE tasks (
    id                 UUID PRIMARY KEY,
    job_id             UUID NOT NULL REFERENCES jobs (id) ON DELETE CASCADE,
    user_id            UUID NOT NULL REFERENCES users (id),
    position           INT NOT NULL CHECK (position >= 0),
    status             task_status NOT NULL DEFAULT 'PENDING_UPLOAD',
    input_key          TEXT NOT NULL,
    input_filename     TEXT NOT NULL,
    input_size_bytes   BIGINT NOT NULL CHECK (input_size_bytes > 0),
    input_metadata     JSONB, -- ffprobe output, set when the upload is confirmed
    params             JSONB NOT NULL,
    notices            JSONB NOT NULL DEFAULT '[]',
    output_key         TEXT,
    output_size_bytes  BIGINT,
    progress           REAL NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
    attempt            INT NOT NULL DEFAULT 0 CHECK (attempt >= 0),
    max_attempts       INT NOT NULL DEFAULT 3 CHECK (max_attempts > 0),
    error_code         TEXT,
    error_message      TEXT,
    worker_id          TEXT,
    lease_expires_at   TIMESTAMPTZ,
    next_attempt_at    TIMESTAMPTZ,
    cancel_requested   BOOLEAN NOT NULL DEFAULT false,
    dispatched_at      TIMESTAMPTZ,
    upload_expires_at  TIMESTAMPTZ NOT NULL,
    input_deleted_at   TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    queued_at          TIMESTAMPTZ,
    started_at         TIMESTAMPTZ,
    finished_at        TIMESTAMPTZ,
    output_expires_at  TIMESTAMPTZ,
    -- Also serves lookups by job_id, so there is no separate tasks (job_id) index.
    UNIQUE (job_id, position),
    CHECK (attempt <= max_attempts)
);

-- One row per attempt, written once when the attempt ends (by the worker, or by the reaper on lease expiry).
-- Not unique on (task_id, attempt): an interrupted attempt doesn't count, so its number gets reused.
CREATE TABLE task_attempts (
    id                  BIGSERIAL PRIMARY KEY,
    task_id             UUID NOT NULL REFERENCES tasks (id) ON DELETE CASCADE,
    attempt             INT NOT NULL,
    worker_id           TEXT NOT NULL,
    started_at          TIMESTAMPTZ NOT NULL,
    finished_at         TIMESTAMPTZ NOT NULL,
    outcome             TEXT NOT NULL CHECK (outcome IN (
                            'success', 'retryable_error', 'fatal_error',
                            'lease_expired', 'canceled', 'interrupted'
                        )),
    error_message       TEXT,
    ffmpeg_stderr_tail  TEXT
);

CREATE TABLE outbox (
    id            BIGSERIAL PRIMARY KEY,
    topic         TEXT NOT NULL,
    payload       JSONB NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at  TIMESTAMPTZ
);

-- Dashboard + cursor pagination
CREATE INDEX jobs_user_created_idx ON jobs (user_id, created_at DESC, id DESC);

-- Per-user limits
CREATE INDEX tasks_user_status_idx ON tasks (user_id, status);

-- Scheduler loops. The WHERE clause fixes status, so it isn't repeated in the indexed columns.
CREATE INDEX tasks_running_lease_idx    ON tasks (lease_expires_at)  WHERE status = 'RUNNING';
CREATE INDEX tasks_retrying_next_idx    ON tasks (next_attempt_at)   WHERE status = 'RETRYING';
CREATE INDEX tasks_queued_idx           ON tasks (queued_at)         WHERE status = 'QUEUED';
CREATE INDEX tasks_output_expiry_idx    ON tasks (output_expires_at) WHERE status = 'SUCCESS';
CREATE INDEX tasks_upload_expiry_idx    ON tasks (upload_expires_at) WHERE status = 'PENDING_UPLOAD';
CREATE INDEX tasks_input_sweep_idx      ON tasks (finished_at)       WHERE input_deleted_at IS NULL;

CREATE INDEX task_attempts_task_idx ON task_attempts (task_id);

CREATE INDEX outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;

-- +goose Down

DROP TABLE IF EXISTS outbox;
DROP TABLE IF EXISTS task_attempts;
DROP TABLE IF EXISTS tasks;
DROP TABLE IF EXISTS jobs;
DROP TABLE IF EXISTS users;
DROP TYPE IF EXISTS task_status;
DROP TYPE IF EXISTS job_status;

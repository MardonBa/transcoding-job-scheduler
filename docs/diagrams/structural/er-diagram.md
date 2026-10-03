# Entity Relationship Diagram

This diagram shows the Postgres schema, the source of truth for the system. A job is what the user submits and a task is one video inside it, so a single-video job is just a job with one task. Notice that tasks carry a denormalized user_id for cheap per-user limits, and that outbox is standalone with no foreign keys. It reflects the "Database Schema" and "Statuses" sections of IMPLEMENTATION_NOTES.md.

```mermaid
erDiagram
    users ||--o{ jobs : "submits"
    users ||--o{ tasks : "owns - denormalized"
    jobs ||--o{ tasks : "contains"
    tasks ||--o{ task_attempts : "has history"

    users {
        uuid id PK
        text google_sub UK
        text email
        text name
        text avatar_url
        timestamptz created_at
        timestamptz updated_at
    }

    jobs {
        uuid id PK
        uuid user_id FK
        text name
        job_status status
        int task_count
        text idempotency_key "UK with user_id"
        timestamptz created_at
        timestamptz updated_at
        timestamptz finished_at
    }

    tasks {
        uuid id PK
        uuid job_id FK
        uuid user_id FK
        task_status status
        text input_key
        text input_filename
        bigint input_size_bytes
        jsonb input_metadata
        jsonb params
        text output_key "nullable"
        bigint output_size_bytes "nullable"
        real progress "0 to 100"
        int attempt "default 0"
        int max_attempts "default 3"
        text error_code "nullable"
        text error_message "nullable"
        text worker_id "nullable"
        timestamptz lease_expires_at "nullable"
        timestamptz next_attempt_at "nullable"
        bool cancel_requested "default false"
        timestamptz dispatched_at "nullable"
        timestamptz created_at
        timestamptz queued_at
        timestamptz started_at
        timestamptz finished_at
        timestamptz output_expires_at
    }

    task_attempts {
        bigserial id PK
        uuid task_id FK
        int attempt
        text worker_id
        timestamptz started_at
        timestamptz finished_at
        text outcome
        text error_message
        text ffmpeg_stderr_tail "last 50 lines"
    }

    outbox {
        bigserial id PK
        text topic
        jsonb payload
        timestamptz created_at
        timestamptz published_at "nullable"
    }
```

## Notes

- Unique constraints: users.google_sub; jobs (user_id, idempotency_key).
- task_attempts.outcome values: success, retryable_error, fatal_error, lease_expired, canceled, interrupted.
- Indexes:
  - jobs (user_id, created_at desc) for dashboard and pagination
  - tasks (job_id)
  - tasks (user_id, status) for per-user limits
  - tasks (status, lease_expires_at) where status = RUNNING, for the reaper
  - tasks (status, next_attempt_at) where status = RETRYING
  - tasks (status, queued_at) where status = QUEUED, for dispatch and queue position
  - tasks (output_expires_at) where status = SUCCESS, for cleanup
  - outbox (id) where published_at is null
- job_status enum: PENDING_UPLOAD, QUEUED, RUNNING, SUCCESS, PARTIAL_SUCCESS, FAILED, CANCELED, EXPIRED
- task_status enum: PENDING_UPLOAD, QUEUED, RUNNING, RETRYING, SUCCESS, FAILED, CANCELED, EXPIRED
- Job status is derived from its tasks, never set directly.
- Sessions are stored in Redis, not Postgres, so there is no sessions table.
- Outbox rows are written in the same transaction as the state change; the relay publishes them to Redis.

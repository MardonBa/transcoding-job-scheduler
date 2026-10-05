# Implementation Plan

Build order: get a thin end-to-end slice working first (Phase 1), then layer on reliability, fairness, and observability.
Design details live in [docs/IMPLEMENTATION_NOTES.md](docs/IMPLEMENTATION_NOTES.md). Contracts: [API](docs/API.md), [SSE](docs/SSE.md), [OAuth](docs/OAUTH.md), [nginx](docs/NGINX.md). Diagrams live in [docs/diagrams/](docs/diagrams/).

## Phase 0: Design

- [x] UML diagrams (ER, class, component, deployment, state machines, sequences)
- [x] Review diagrams against implementation notes, resolve any gaps
- [x] Finalize API routes and request/response shapes
- [x] Finalize SSE event payloads
- [x] OAuth flow and nginx setup

## Phase 1: End-to-End Slice

Goal: login -> upload one video -> worker transcodes -> status over SSE -> download. Fixed concurrency, no retries yet.

### Infrastructure & Project Setup
- [x] Docker compose (backing services): postgres, redis, minio (+ bucket init), with healthchecks
- [ ] Go module layout: `cmd/api`, `cmd/worker`, `cmd/scheduler`, shared `internal/` packages
- [ ] Config via env vars
- [ ] Migrations tool + initial migrations (users, jobs, tasks, task_attempts, outbox, enums, indexes)
- [ ] Postgres, redis, minio clients (internal + public minio client for signing), run from host against compose
- [ ] Dockerfiles for api, worker, scheduler, frontend; add them to compose (behind a profile so `docker compose up` stays infra-only)
- [ ] nginx config (`deploy/nginx/nginx.conf`): /api, /api/events, /uploads + /outputs, frontend; add nginx to compose
- [ ] Structured logging with slog from day one
- [ ] Shared JSON error envelope + request id middleware
- [ ] Origin check on POST requests

### Auth
- [ ] `GET /api/auth/login` + `GET /api/auth/callback`: PKCE, state (Redis + cookie), nonce
- [ ] Verify id_token, upsert user on google_sub
- [ ] Redis sessions (hashed id) with 7 day TTL, httpOnly/SameSite=Lax cookie, Secure via env
- [ ] Auth middleware, `GET /api/me`, `POST /api/auth/logout`
- [ ] All job/task queries scoped by user_id, 404 for other users' resources

### Job Creation & Uploads
- [ ] Transcode params typed struct + allowlist validation
- [ ] `GET /api/config`: options, presets, limits from the same Go values
- [ ] `POST /api/jobs`: validate, write job + tasks (PENDING_UPLOAD) in one transaction, return presigned POST forms (30 min window)
- [ ] `Idempotency-Key` header with request hash, 422 on mismatched reuse
- [ ] `POST /api/tasks/{id}/uploaded`: StatObject size check, ffprobe via presigned GET, store input_metadata + notices, move to QUEUED or FAILED
- [ ] `GET /api/jobs?scope=open|history` (cursor on created_at, id), `GET /api/jobs/{id}`

### Queue (basic)
- [ ] Dispatcher-style outbox write in the same transaction as setting dispatched_at (only writer of the outbox)
- [ ] Outbox relay loop in the scheduler: outbox -> XADD -> published_at
- [ ] Redis stream + consumer group setup
- [ ] Worker XREADGROUP, conditional claim in postgres, XACK

### Worker
- [ ] Slot pool (WORKER_SLOTS) with per-ffmpeg threads (FFMPEG_THREADS)
- [ ] Download input to scratch, always clean up scratch
- [ ] Build ffmpeg args from the typed struct, exec as arg slice
- [ ] Parse `-progress pipe:1` output into percent
- [ ] Upload output to minio at a deterministic key
- [ ] Mark SUCCESS, set output_expires_at, recompute job status with row lock

### Progress & SSE
- [ ] Worker publishes events to `user:{user_id}:events` (task.progress throttled to 1/s, job.progress on heartbeat)
- [ ] Api single PSUBSCRIBE + in-memory fan-out to user connections
- [ ] `GET /api/events` SSE endpoint: ready event, 15s keepalive with session recheck

### Downloads
- [ ] `GET /api/tasks/{id}/download`: ownership check -> redirect to presigned GET with Content-Disposition

### Frontend
- [ ] Landing page with login
- [ ] Auth check via `/api/me`, route guarding, `auth_error` message on landing
- [ ] Dashboard layout (side by side, stacks on small screens)
- [ ] Job adder form built from `/api/config`: drag and drop + file picker, job name, presets per video
- [ ] Direct upload to minio (presigned POST via XHR) with per-video progress, then confirm upload
- [ ] Job cards in active / queued / previous collapsible sections
- [ ] Job page: per-video status, progress, download links, expiry
- [ ] SSE context shared across pages: refetch on `ready`, drop stale events by `ts`/attempt, manual backoff on 401/429
- [ ] Job progress tween between server updates

## Phase 2: Reliability

- [ ] Heartbeats: extend lease, write progress, check cancel_requested
- [ ] Error classification into error_code (retryable vs fatal)
- [ ] task_attempts rows with stderr tail
- [ ] RUNNING -> RETRYING with backoff + jitter, max 3 attempts
- [ ] Retry scheduler loop (RETRYING -> QUEUED)
- [ ] Lease reaper loop (expired leases -> RETRYING / FAILED)
- [ ] XAUTOCLAIM for stream messages idle > 60s
- [ ] Task timeout via CommandContext + process group kill
- [ ] Graceful worker shutdown (kill ffmpeg, requeue without counting the attempt)
- [ ] Enforce the full task state machine with conditional updates
- [ ] Batch status derivation: SUCCESS / PARTIAL_SUCCESS / FAILED / CANCELED

## Phase 3: Fairness & Limits

- [ ] Dispatcher loop: round robin across users, max 2 in-flight tasks per user, dispatched_at
- [ ] `queue_ahead` computation + frontend display ("~N ahead"), 10s poll while queued
- [ ] Redis token bucket (lua) rate limit middleware with Retry-After
- [ ] Limits: general api, public per-IP, job creation, videos per job, unfinished tasks per user, SSE connections per user
- [ ] Frontend handling for 429s
- [ ] Docker cpu/memory limits on worker containers

## Phase 4: Cancellation & Cleanup

- [ ] `POST /api/jobs/{id}/cancel` and `POST /api/tasks/{id}/cancel`: pending upload/queued/retrying -> CANCELED, running -> cancel_requested, 202 with job
- [ ] Worker kills ffmpeg on cancel flag -> CANCELED; reaper cancels instead of retrying when cancel_requested is set
- [ ] Cleanup loop (every 5 min): expire outputs -> EXPIRED, fail PENDING_UPLOAD past window + 15 min
- [ ] Input sweep: delete inputs of terminal tasks once no upload can land, set input_deleted_at
- [ ] MinIO lifecycle rule on uploads bucket (1 day) as a backstop
- [ ] Frontend: job + per-video cancel buttons, "Canceling…" state, EXPIRED state, error messages

## Phase 5: Hardening

- [ ] ffmpeg runs as non-root with `-protocol_whitelist file`
- [ ] Worker network restricted to minio, postgres, redis
- [ ] Filename sanitization for display + Content-Disposition
- [ ] Re-run ffprobe in the worker before transcoding
- [ ] Clamp requested resolution to the source (no upscaling)

## Phase 6: Observability

- [ ] Log fields: request_id, user_id, job_id, task_id, worker_id, attempt
- [ ] Prometheus `/metrics` on api, worker, scheduler
- [ ] Metrics: http, queue depth, task outcomes, retries, wait/run time, transcode speed, slot usage, outbox lag, leases reaped, minio, SSE connections, rate limit rejections
- [ ] Prometheus + Grafana in docker compose, dashboard provisioned from repo
- [ ] Grafana alert rules (oldest queued task, failure rate, outbox lag, worker heartbeats)
- [ ] `/healthz` + `/readyz`, wired into compose healthchecks
- [ ] (Optional) OpenTelemetry tracing through the stream message, Jaeger locally

## Phase 7: Testing

- [ ] Unit tests: params validation, ffmpeg arg builder, progress parser, state transitions, job status derivation
- [ ] Integration tests with testcontainers (postgres, redis, minio)
- [ ] Duplicate delivery test: same task delivered twice, runs once
- [ ] Chaos test: kill workers mid task, verify nothing lost or stuck
- [ ] Batch race test: last two tasks finish at the same time
- [ ] Load test: many users submitting at once, verify fairness

## Phase 8: Polish

- [ ] Frontend animations for state transitions
- [ ] Responsive layout pass (3x2 grid on large screens)
- [ ] README: architecture overview, how to run, screenshots
- [ ] Demo script / recording

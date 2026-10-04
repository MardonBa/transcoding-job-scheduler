# Implementation Notes

Exact contracts live next to this file: [API.md](API.md) (routes, payloads, errors), [SSE.md](SSE.md) (events), [OAUTH.md](OAUTH.md) (login and sessions), [NGINX.md](NGINX.md) (routing, one origin, presigned URLs).

## UI

Check if authenticated (GET /api/me). If not, show the user a landing page. Simple. Describes what the app does, login button in the center.

If authenticated, take the user to the jobs dashboard. Split into current job viewer and job adder.

Job adder is a form. User inputs video(s) to transcode, attribute to change per video, job name. Drag video files, or upload video button which opens file picker.
Max 10 videos per job.

Attributes come from a fixed set of options, not freeform text. Container, video codec, resolution, bitrate/quality, fps, keep or strip audio.
Show presets (e.g. "720p MP4", "1080p WebM") with an advanced section to tweak the individual options. Invalid combos get disabled in the form (webm only allows vp9).
Do basic checks client side before uploading (file type, size under limit) so the user finds out early, but the backend is what actually validates.
The options, presets and limits for the form come from GET /api/config, so the frontend never keeps its own copy of the allowlist.
After submit show upload progress per video, since the browser uploads straight to storage.

Job view page shows active jobs, queued jobs, previous jobs. Each as a collapsible section. Active holds PENDING_UPLOAD and RUNNING jobs, Queued holds QUEUED jobs. Nice fading animation
when a job transitions from state to state. Queued jobs see their place in the queue, active jobs see progress % per video and which attempt they're on.
Place in queue is approximate (~N ahead) since per-user fairness can let other tasks skip ahead.
Previous jobs are paginated, cursor based on created_at.

On biggest screens we should show 3 cols, 2 rows of each job type and then the remainder scrollable
On smaller screens shift, but i want this to be side by side until screen size forbids it, then
i want job creation on top and then seeing your jobs on the bottom. Jobs show as cards, clicking takes to job page

Clicking on a job's card takes you to it's page. On the page shows status, progress, download link (with expiry time set).
Expiration set so that we aren't storing data on the server for too long. Outputs are kept 24h, then the video shows as EXPIRED with no link.
Each video in the job gets its own row with status, progress, download link, and the error message if it failed.
Cancel button on the job while anything in it is cancelable, and a cancel button per video.
Job progress comes from the server every ~10s. The bar tweens from the value on screen to the new one over that interval, so it moves smoothly instead of jumping.
Page fetches the job from the api on load since the user might deep link or refresh, then stays live with SSE.

Backend communicates status changes to the frontend with SSE. Updates only go server -> client so websockets are overkill.
Frontend opens one EventSource to GET /api/events and shares it between the dashboard and job page. Events are ready, task.status, task.progress, job.status, job.progress.
On every ready event (connect and reconnect) the frontend refetches to catch anything it missed while disconnected.

If the user hits a rate limit (429) show a message with when they can try again (Retry-After).

## Backend

Go backend. Rate limiting, use workers, manage CPU usage

Three binaries in the same repo, sharing packages:
api - http, auth, SSE, rate limiting, job creation, input validation
worker - pulls tasks from the queue and runs ffmpeg. Scale by running more of these
scheduler - single instance. Runs the background loops: outbox relay, dispatcher, lease reaper, retry scheduler, cleanup

Workers never talk to the api directly. They write to postgres and publish events to redis.

nginx sits in front of everything and serves the frontend, the api (under /api) and the MinIO buckets on one origin. That keeps cookies simple, avoids CORS, and gives presigned URLs an address the browser can reach.

Postgres is the source of truth. Redis is just transport (queue, pub/sub, sessions, rate limit counters).
If redis gets wiped we should be able to rebuild the queue from postgres.

### Database Schema

A job is what the user submits, a task is one video inside it. A single video job is just a job with one task, so batch isn't a special case.
Primary keys of users, jobs and tasks are UUIDv7 generated in Go (time ordered, friendlier to btree indexes).

users
- id uuid pk
- google_sub text unique (this is the identity key, email can change)
- email text
- name text
- avatar_url text
- created_at, updated_at

jobs
- id uuid pk
- user_id uuid fk -> users
- name text
- status job_status
- task_count int
- idempotency_key text, unique on (user_id, idempotency_key) so a double click doesn't make two jobs
- idempotency_request_hash text (sha256 of the request body, so a reused key with a different body gets rejected)
- created_at, updated_at, finished_at

tasks
- id uuid pk
- job_id uuid fk -> jobs
- user_id uuid fk -> users (denormalized, makes per-user limits and queries cheap)
- position int (order of the video in the request, unique per job, since tasks inserted in one transaction share created_at)
- status task_status
- input_key text (minio object key)
- input_filename text (original name, display only)
- input_size_bytes bigint
- input_metadata jsonb (ffprobe output: duration, codecs, resolution, fps)
- params jsonb (validated transcode options, effective values after clamping)
- notices jsonb default [] (e.g. resolution_clamped, shown on the job page)
- output_key text null
- output_size_bytes bigint null
- progress real (0-100)
- attempt int default 0
- max_attempts int default 3
- error_code text null, error_message text null
- worker_id text null
- lease_expires_at timestamptz null
- next_attempt_at timestamptz null (when a RETRYING task can go back in the queue)
- cancel_requested bool default false
- dispatched_at timestamptz null (when it was pushed to the redis stream)
- upload_expires_at timestamptz (created_at + 30 min, the presigned upload form expires then)
- input_deleted_at timestamptz null (set once the input object is gone)
- created_at, queued_at, started_at, finished_at, output_expires_at

task_attempts - one row per try so we have history for debugging
- id bigserial pk
- task_id uuid fk -> tasks
- attempt int
- worker_id text
- started_at, finished_at
- outcome text (success, retryable_error, fatal_error, lease_expired, canceled, interrupted)
- error_message text
- ffmpeg_stderr_tail text (last ~50 lines)

outbox - messages that need to get onto the redis stream, written in the same transaction as the state change. Only the dispatcher writes here. Status events for the browser go straight to pub/sub, since losing one is fine
- id bigserial pk
- topic text
- payload jsonb
- created_at
- published_at timestamptz null

Indexes
- jobs (user_id, created_at desc, id desc) for the dashboard + cursor pagination
- tasks (job_id)
- tasks (user_id, status) for per-user limits
- tasks (status, lease_expires_at) where status = RUNNING, for the reaper
- tasks (status, next_attempt_at) where status = RETRYING
- tasks (status, queued_at) where status = QUEUED, for dispatch + queue position
- tasks (output_expires_at) where status = SUCCESS, for cleanup
- tasks (upload_expires_at) where status = PENDING_UPLOAD, for cleanup
- tasks (finished_at) where input_deleted_at is null, for the input sweep
- outbox (id) where published_at is null

Sessions live in redis, not postgres.

### Statuses

Task statuses: PENDING_UPLOAD, QUEUED, RUNNING, RETRYING, SUCCESS, FAILED, CANCELED, EXPIRED

PENDING_UPLOAD -> QUEUED (upload confirmed + validated)
PENDING_UPLOAD -> FAILED (validation failed, or not confirmed by upload_expires_at + 15 min)
PENDING_UPLOAD -> CANCELED
QUEUED -> RUNNING (worker claims it)
QUEUED -> CANCELED
RUNNING -> SUCCESS
RUNNING -> RETRYING (retryable error, attempts left)
RUNNING -> FAILED (fatal error, or out of attempts)
RUNNING -> CANCELED (worker sees cancel_requested, or the reaper finds an expired lease with cancel_requested set)
RUNNING -> QUEUED (worker graceful shutdown, attempt doesn't count, dispatched_at cleared)
RETRYING -> QUEUED (after backoff)
RETRYING -> CANCELED
SUCCESS -> EXPIRED (output deleted by cleanup)

Progress resets to 0 whenever a task leaves RUNNING for RETRYING or QUEUED.
Any transition not on this list gets rejected. Every transition is a conditional update (UPDATE ... WHERE id = $1 AND status = $expected) so two things racing on the same task can't both win.

Job statuses: PENDING_UPLOAD, QUEUED, RUNNING, SUCCESS, PARTIAL_SUCCESS, FAILED, CANCELED, EXPIRED
Job status is derived from its tasks, never set directly.
Any task not uploaded yet -> PENDING_UPLOAD. All non-terminal tasks queued and no task ever started (started_at null everywhere) -> QUEUED. Anything else still in progress -> RUNNING.
Once a job has started it stays RUNNING until every task is terminal, so it never jumps back from Active to Queued.
Once every task is terminal, checked in this order: all success -> SUCCESS, at least one success -> PARTIAL_SUCCESS, at least one task CANCELED -> CANCELED, otherwise -> FAILED.
Cancel works per job and per task, so a batch can end up with a mix of outcomes.
An EXPIRED task counts as a success here.
All outputs expired -> EXPIRED.
Recomputed in the same transaction as a task's status change, with SELECT ... FOR UPDATE on the job row so two workers finishing the last two tasks of a batch don't race.

Max 3 attempts. Backoff between attempts is 10s, 30s, 90s with some jitter.
Retryable: worker crashed (lease expired), ffmpeg killed by a signal / OOM, minio or postgres timeouts
Not retryable: invalid or corrupt input, unsupported codec, ffmpeg decode error, task timeout (the same input will just time out again), canceled
Workers classify errors into an error_code so the retry decision isn't based on parsing strings everywhere.
Retryable codes: lease_expired, oom_or_signal, storage_error
Not retryable codes: invalid_input, unsupported_codec, decode_error, timeout, canceled, upload_timeout, plus the upload validation codes upload_too_large, unsupported_format, no_video_stream, duration_too_long, resolution_too_high, fps_too_high (full table in API.md)

### Queue

Redis Streams with a consumer group. Stream tasks, group workers. A message only carries the task_id, the worker loads everything else from postgres.

worker has a free slot -> XREADGROUP -> claim in postgres (UPDATE tasks SET status = RUNNING, worker_id, lease_expires_at = now() + 30s, attempt = attempt + 1 WHERE id = $1 AND status = QUEUED)
-> if 0 rows updated, someone else has it or it was canceled, XACK and skip -> otherwise XACK and start

XACK right after the claim since the postgres lease is the guarantee from that point on.
If a worker dies between XREADGROUP and the claim, the message is stuck pending. Workers run XAUTOCLAIM on messages idle > 60s to pick those up.
If a worker dies after the claim, the lease expires and the reaper handles it.

Delivery is at-least-once, so the same task can show up twice. That's fine because the claim is conditional and output goes to a deterministic key (outputs/{user_id}/{task_id}.{ext}), so a rerun just overwrites.

Heartbeat: every 10s the worker extends lease_expires_at, writes progress, and checks cancel_requested.

### Scheduler loops

Outbox relay (every ~500ms): read unpublished outbox rows -> XADD to the stream -> set published_at.
If it crashes between XADD and setting published_at the message gets sent twice, which the conditional claim already handles.
This fixes the dual write problem. Writing the task and enqueuing it happen in one postgres transaction, so we never get a task in the db that never makes it to the queue.

Dispatcher (every 1s): picks QUEUED tasks with dispatched_at null and pushes them to the stream, round robin across users, only if that user has fewer than 2 tasks in flight. In flight = (QUEUED and dispatched_at not null) or RUNNING.
Sets dispatched_at and writes an outbox row in one transaction. This is what keeps one user with 50 videos from hogging every worker.

Lease reaper (every 15s): RUNNING tasks with lease_expires_at < now() -> CANCELED if cancel_requested is set, otherwise RETRYING with next_attempt_at, or FAILED if out of attempts. Writes a task_attempts row with outcome lease_expired.

Retry scheduler (every 5s): RETRYING tasks with next_attempt_at <= now() -> QUEUED, clear dispatched_at so the dispatcher picks it up again.

Cleanup (every 5 min): see storage section.

Queue position = count of QUEUED tasks with an earlier queued_at. Computed when the dashboard fetches jobs, not pushed over SSE. Frontend refetches positions every ~10s and on any task.status event.

### Storage

MinIO (S3 compatible), running in docker compose. Redis is the wrong place for video since it's all in memory.

Buckets: uploads, outputs
Keys (bucket, then key): uploads {user_id}/{task_id}, outputs {user_id}/{task_id}.{ext}. Path-style URLs, so the browser sees /uploads/{user_id}/{task_id} through nginx

Uploads go straight from the browser to minio with presigned POST forms. Videos never pass through the go api.
The POST policy pins the key, caps content-length at the size the client declared, and expires at upload_expires_at (30 min after job creation). Once that passes, the video is gone. There is no route to get a new form, the user makes a new job.
Presigned POST instead of PUT because a PUT url can't cap the size. A client side size check is only for UX.
Max file size is 500 MB, which is plenty for a personal project on a small server. A single POST is fine at that size.

Worker downloads the input to /scratch/{task_id}/ -> runs ffmpeg -> uploads the output -> deletes the scratch dir. Scratch gets deleted even on failure (defer).
Input is kept until the task is terminal since retries need it, then deleted. The worker deletes it right away on SUCCESS. Everything else is swept by cleanup (see below).

Downloads go through the api so we can check ownership: GET /api/tasks/{id}/download -> check the task belongs to the user -> 302 redirect to a presigned GET url (expires in 5 min) with Content-Disposition set to {sanitized original name}_transcoded.{ext}.
Output itself is kept for 24h (output_expires_at). Expired outputs return 410 so the frontend can show EXPIRED instead of a generic error.
Presigned urls for the browser are signed with a second minio client pointed at the public endpoint (localhost), since the signature covers the host. See NGINX.md.

Cleanup loop
- SUCCESS tasks past output_expires_at -> delete the object -> EXPIRED
- PENDING_UPLOAD tasks past upload_expires_at + 15 min -> FAILED (error_code upload_timeout). The 15 min grace lets an upload started just before the deadline finish
- Terminal tasks with input_deleted_at null -> delete the input -> set input_deleted_at. Only once no upload can still land: queued_at is set (upload already finished), or upload_expires_at + 15 min has passed
- Minio lifecycle rule on the uploads bucket deletes anything older than 1 day as a backstop in case the loop misses something

### Auth

Account creation and login are the same flow. Upsert the user on google_sub.
Go api owns the OAuth flow (Google OIDC, authorization code + PKCE, with state and nonce). Verify the id_token, upsert the user, create a session. Details in OAUTH.md.
Routes: GET /api/auth/login, GET /api/auth/callback, POST /api/auth/logout. There's no separate create account route, it's the same flow.
Don't store Google access/refresh tokens. We never call Google APIs, we only need to know who the user is.
Session is a random id stored in redis with a 7 day TTL, sent as an httpOnly, Secure, SameSite=Lax cookie.
Every job/task query is scoped by user_id. Return 404 (not 403) for other users' jobs so we don't leak that they exist.

### Rate Limiting

Done in api middleware with redis. Token bucket implemented as a lua script so the check + decrement is atomic across api instances.
Over the limit -> 429 with Retry-After.

Limits (all configurable via env)
- General api: 60 requests/min per user. Public routes (/api/auth/*, /api/config) 30 requests/min per IP
- Job creation: 5 jobs/min per user
- Max 10 videos per job
- Max 50 unfinished tasks per user at once (PENDING_UPLOAD, QUEUED, RUNNING, RETRYING). Job creation gets rejected past that
- Max 2 tasks in flight per user (enforced by the dispatcher, not the middleware)
- Max 5 SSE connections per user
- Max file size 500 MB (upload policy + StatObject), max duration 30 min (enforced in input validation)
- Maybe a daily quota on total input minutes per user, if we want to go further

### CPU Management

Each worker process has K slots (goroutines). Each ffmpeg runs with -threads N. Set K * N ~= number of cores on the machine.
Default N = 2, K = cores / 2. Configured with WORKER_SLOTS and FFMPEG_THREADS env vars.
A slot only reads from the stream when it's free, so "wait for cpu space" is just "wait for a free slot". No load-based checks.
Need more throughput -> run more worker containers.

Worker containers get docker cpu and memory limits so ffmpeg can't take down the host.
Encoder preset also matters a lot for CPU, so use a fixed preset instead of letting the user pick. The server is small, so favor speed: x264 -preset fast, x265 -preset fast, vp9 -deadline good -cpu-used 4 -row-mt 1.
h265 in mp4 gets -tag:v hvc1 so it plays on Apple devices. Audio is aac for mp4/mkv and opus for webm, fixed per container.

Task timeout: max(10 min, 3x input duration). Run ffmpeg with exec.CommandContext in its own process group so the whole thing gets killed on timeout or cancel.

Graceful shutdown: on SIGTERM stop reading new messages -> kill running ffmpeg processes -> put those tasks back to QUEUED without counting the attempt -> exit.
Transcodes can be long, so waiting for them to finish isn't realistic.
The attempt row gets outcome interrupted. If the worker gets SIGKILLed before it finishes, the lease reaper handles it like a crash.

### Input Validation

Happens in the api when the browser confirms an upload (POST /api/tasks/{id}/uploaded), so the user finds out right away. Worker re-runs ffprobe before transcoding anyway.

- StatObject in minio to check the object exists and get the real size. Don't trust the size the client sent. Must be <= declared size and <= 500 MB. If the object is missing, answer 409 and leave the task PENDING_UPLOAD
- ffprobe against a presigned GET url with a 10s timeout. Only reads the headers, doesn't download the whole file
- ffprobe has to succeed and find at least one video stream
- Input format on an allowlist: mp4, mov, mkv, webm, avi
- Duration <= 30 min, resolution <= 4K, fps <= 60
- If the requested resolution is above the source, clamp it to original instead of failing, since the user already uploaded. Store the effective params and a resolution_clamped notice, shown on the job page
- A validation failure is still a 200 from /uploaded, with the task FAILED and its error. The route always answers with the task's current status
- Store the ffprobe output in input_metadata. The worker uses the duration for progress

Transcode params get validated against an allowlist when the job is created, before anything is uploaded
- container: mp4, webm, mkv
- video codec: h264, h265, vp9, with valid combos only (webm requires vp9)
- resolution: 480p, 720p, 1080p, original. Upscaling gets checked at upload confirmation since we don't know the source resolution yet
- quality: CRF within a fixed range, or bitrate between 500k and 20M
- fps: 24, 30, 60, original
- audio: keep or strip

ffmpeg args get built from a typed struct and passed to exec.Command as an arg slice. Never a shell, never user strings in args.
Files on disk use generated paths (/scratch/{task_id}/input), never the original filename. Original filename is only for display and Content-Disposition, sanitized.
ffmpeg runs as non-root with -protocol_whitelist file so a crafted input can't make it open urls. Worker container only has network access to minio, postgres and redis.

### Progress

Worker already has the duration from ffprobe. Run ffmpeg with -progress pipe:1 -nostats and parse the out_time_us lines. progress = out_time / duration.
Publish to redis pub/sub channel user:{user_id}:events at most once per second.
Only write progress to postgres on the heartbeat (every 10s), not every tick.
Job progress is emitted by the server. On each heartbeat the worker recomputes the job's progress from all its tasks (weighted by duration, terminal tasks count as 100) and publishes job.progress. job.status carries progress too.
Status changes always get written to postgres first, then published.

SSE in the api: GET /api/events, authed with the session cookie. Payloads in SSE.md.
Each api instance has one redis subscription (PSUBSCRIBE user:*:events) and fans events out in memory to that user's open connections, instead of one redis subscription per connection.
Send a comment line every 15s so proxies don't close idle connections.
Pub/sub is fire and forget. Losing a message is fine because postgres has the truth and the frontend refetches on reconnect.

## User interactions

### Account Creation

User presses create account -> Log in with Google -> User Logs in with google -> api verifies the id_token -> upsert user on google_sub (name, email, avatar) -> create session in redis + set cookie -> send the user to main dashboard

Same flow as login. No google tokens stored.

### Login

User presses login -> login with google -> api verifies the id_token -> upsert user, update name/email/avatar if changed -> create session + set cookie -> send user to main dashboard

### Job Creation

User fills out job creation form -> POST /api/jobs with job name, params per video, file name + size per video, Idempotency-Key header -> api checks rate limits + idempotency + validates params -> write job + tasks (PENDING_UPLOAD) in one transaction -> return presigned upload forms (30 min)
-> browser uploads each video straight to minio, shows upload progress -> POST /api/tasks/{id}/uploaded per video -> api validates the video -> task QUEUED (or FAILED with the reason)
-> dispatcher pushes it to the redis stream once the user has a free slot -> frontend gets updates over SSE

job gets queued -> dispatched to stream -> wait for a worker with a free slot -> claim in postgres (RUNNING) -> download input to scratch -> ffmpeg, stream progress to frontend, heartbeat every 10s
-> upload output to minio -> SUCCESS, set output_expires_at -> recompute job status -> publish events -> delete scratch + input -> download link expires after 24h

task fails -> retryable? RETRYING with backoff -> retry scheduler puts it back in QUEUED -> after 3 attempts FAILED with error message shown to the user
worker crashes mid task -> lease expires -> reaper moves it to RETRYING

batch job gets created -> one task per video, all tagged with the job_id -> stream per-video progress, job status gets recomputed every time a task finishes -> terminal once every task is done (SUCCESS, PARTIAL_SUCCESS, FAILED) -> same process of giving data back to the user

### Cancel Job

User presses cancel -> POST /api/jobs/{id}/cancel (or POST /api/tasks/{id}/cancel for one video) -> pending upload/queued/retrying tasks go straight to CANCELED, running tasks get cancel_requested = true -> 202 with the job
-> worker sees the flag on its next heartbeat (up to 10s) -> kills ffmpeg -> CANCELED -> job status recomputed -> events published

### Download

User clicks download -> GET /api/tasks/{id}/download -> ownership check -> redirect to presigned minio url -> after 24h the output is deleted and the link is gone

user clicks job card -> GET /api/jobs/{id} on page load (needed for deep links / refresh) -> live updates over SSE from there

## Observability

Logs
- Structured JSON logs with slog
- Every line carries request_id, user_id, job_id, task_id, worker_id, attempt where it applies, so you can grep one task across api, scheduler and worker
- ffmpeg stderr is only logged on failure (the tail), and also saved to task_attempts

Metrics
Prometheus, /metrics on api, worker and scheduler.
- http_requests_total and http_request_duration_seconds by route + status
- Queue depth: undispatched QUEUED tasks in postgres, stream length, pending entries (XPENDING)
- tasks_total by final status and error_code
- task_retries_total by error_code
- queue_wait_seconds (queued_at -> started_at)
- task_duration_seconds (started_at -> finished_at)
- transcode speed (input duration / wall time), tells us if the cpu settings are any good
- worker slots busy vs total
- outbox lag (age of the oldest unpublished row)
- leases reaped
- minio upload/download duration and bytes
- open SSE connections
- rate_limit_rejections_total by limit

Grafana dashboard provisioned from a file in the repo: queue depth, throughput, p50/p95 wait and run time, failure rate, worker utilization.
Prometheus + Grafana run in docker compose.

Tracing
OpenTelemetry. Put the trace context in the stream message so one trace goes from POST /api/jobs -> dispatcher -> worker -> ffmpeg -> minio upload. Jaeger locally to view.
Nice to have, do after logs + metrics.

Alerts (grafana rules, mostly to show it works)
- Oldest queued task waiting > 10 min
- Task failure rate > 20% over 15 min
- Outbox lag > 30s
- No worker heartbeats for 1 min

Health checks
- /healthz just says the process is alive
- /readyz checks postgres, redis and minio are reachable
- Docker compose healthchecks use these

## Notes

Need a concurrency-safe queue. Definitely a non-negotiable here, so redis queue is a good choice
Using Redis Streams with a consumer group. Concurrency safety comes from the consumer group plus the conditional claim in postgres.
Delivery is at-least-once, so every step has to be idempotent.

## Tech Stack

nginx (one origin) -> Frontend (NextJS) -> Backend api (Golang) -> Postgres (source of truth) + Redis (stream queue, pub/sub, sessions, rate limits) + MinIO (video files)
-> Go scheduler (outbox relay, dispatcher, reaper, cleanup) -> Go workers -> ffmpeg / ffprobe
-> workers write results to postgres + minio and publish events to redis -> api pushes them to the frontend over SSE

Prometheus + Grafana (+ Jaeger later) for observability. Everything runs in docker compose.

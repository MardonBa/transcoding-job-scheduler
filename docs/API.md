# API

HTTP contract for the Go api. Live updates are in [SSE.md](SSE.md), the login flow is in [OAUTH.md](OAUTH.md), and routing and origins are in [NGINX.md](NGINX.md). Design rationale lives in [IMPLEMENTATION_NOTES.md](IMPLEMENTATION_NOTES.md).

## Route summary

| Method | Path | Auth | Purpose | Success |
|---|---|---|---|---|
| GET | `/api/auth/login` | no | Start Google login | 302 |
| GET | `/api/auth/callback` | no | Finish Google login, set session cookie | 302 |
| POST | `/api/auth/logout` | yes | End the session | 204 |
| GET | `/api/me` | yes | Current user | 200 |
| GET | `/api/config` | no | Allowed options, presets, limits | 200 |
| POST | `/api/jobs` | yes | Create a job and get upload forms | 201 / 200 replay |
| GET | `/api/jobs` | yes | List open jobs or job history | 200 |
| GET | `/api/jobs/{id}` | yes | Full job with all tasks | 200 |
| POST | `/api/jobs/{id}/cancel` | yes | Cancel every cancelable task in the job | 202 |
| POST | `/api/tasks/{id}/uploaded` | yes | Confirm an upload, validate it, return the task's status | 200 |
| POST | `/api/tasks/{id}/cancel` | yes | Cancel one video | 202 |
| GET | `/api/tasks/{id}/download` | yes | Redirect to the output file | 302 |
| GET | `/api/events` | yes | SSE stream, see [SSE.md](SSE.md) | 200 stream |

Internal only, served on the Go port and never routed by nginx: `/healthz`, `/readyz`, `/metrics`.

## Conventions

- **Origin.** Everything is served from one origin through nginx (`http://localhost` in dev). The api lives under `/api`. The frontend fetches client side with relative URLs and `credentials: "same-origin"`.
- **Format.** JSON request and response bodies with `Content-Type: application/json`, snake_case keys. Request bodies are capped at 64 KB.
- **IDs.** UUIDv7 strings generated in Go. They are time ordered, which keeps btree inserts local.
- **Timestamps.** RFC 3339 in UTC with milliseconds, e.g. `2026-10-04T18:21:07.123Z`.
- **Enums.** Statuses are `UPPER_SNAKE`. Option values are lowercase strings, and that includes fps (`"30"`, `"original"`), so every option is a string.
- **Units.** Sizes are integer bytes (`*_bytes`), durations are seconds (`*_s`), progress is a float from 0 to 100 rounded to 1 decimal.
- **Nulls.** Nullable fields are always present as `null` and never omitted.
- **Auth.** The session cookie `sid` (see [OAUTH.md](OAUTH.md)). A route marked "yes" answers 401 `unauthenticated` without a valid session.
- **Ownership.** Every query is scoped by `user_id`. Another user's job or task is answered with 404, never 403.
- **CSRF.** `POST` requests must carry an `Origin` header equal to `APP_BASE_URL`, or the api answers 403 `forbidden_origin`. Together with `SameSite=Lax` this is enough.
- **Caching.** Every response sends `Cache-Control: no-store`, except `/api/config`, which sends `public, max-age=300`.
- **Request IDs.** nginx sets `X-Request-ID`. The api logs it, echoes it in the response header and puts it in error bodies.

## Errors

Every non-2xx JSON response has the same shape:

```json
{
  "error": {
    "code": "validation_failed",
    "message": "Some videos have invalid settings.",
    "details": {
      "fields": [
        { "path": "tasks[2].params.video_codec", "code": "invalid_combo", "message": "webm requires vp9" }
      ]
    },
    "request_id": "8f1c2e0b9a6d4c3e"
  }
}
```

- `code` is stable and machine readable. The frontend switches on `code` and never parses `message`.
- `message` is safe to show the user as is.
- `details` is always an object (`{}` when there is nothing to add). Its known keys are `fields` (validation), `retry_after_s` (429) and `limit` (429, the name of the limit that was hit).
- A 429 also sets the `Retry-After` header in seconds.

### Request error codes

| HTTP | code | When |
|---|---|---|
| 400 | `bad_request` | Malformed JSON, missing `Idempotency-Key`, bad `scope` or `cursor` |
| 400 | `validation_failed` | One or more fields invalid, see `details.fields` |
| 401 | `unauthenticated` | No session or the session expired |
| 403 | `forbidden_origin` | `POST` without a matching `Origin` |
| 404 | `not_found` | Missing, or owned by someone else |
| 409 | `upload_not_found` | `/uploaded` was called but nothing is in storage yet. The task stays `PENDING_UPLOAD` |
| 409 | `not_cancelable` | Every targeted task is already terminal |
| 409 | `output_not_ready` | Download requested before the task reached `SUCCESS` |
| 410 | `output_expired` | Download requested after the output was deleted |
| 413 | `payload_too_large` | JSON body over 64 KB |
| 422 | `idempotency_key_reused` | Same `Idempotency-Key` with a different request body |
| 429 | `rate_limited` | Token bucket empty |
| 429 | `quota_exceeded` | The user would have more than 50 unfinished tasks |
| 500 | `internal` | Bug or unexpected failure |
| 503 | `unavailable` | Postgres, Redis or MinIO unreachable |

### Field error codes

`details.fields[].code` is one of: `required`, `too_long`, `not_allowed` (value not in the allowlist), `out_of_range`, `invalid_combo`, `too_many`, `too_large`.

### Task error codes

These are not HTTP errors. They appear on a task as `error.code` when a video fails, and in [SSE.md](SSE.md) events.

| code | Retryable | Set by | Meaning |
|---|---|---|---|
| `upload_too_large` | no | api, at `/uploaded` | Stored object is bigger than the declared size or the max |
| `unsupported_format` | no | api, at `/uploaded` | Container is not mp4, mov, mkv, webm or avi |
| `no_video_stream` | no | api, at `/uploaded` | ffprobe found no video stream |
| `duration_too_long` | no | api, at `/uploaded` | Longer than 30 min |
| `resolution_too_high` | no | api, at `/uploaded` | Larger than 3840x2160 |
| `fps_too_high` | no | api, at `/uploaded` | Above 60 fps |
| `invalid_input` | no | api or worker | ffprobe failed or the file is corrupt |
| `unsupported_codec` | no | api or worker | Input codec cannot be decoded |
| `decode_error` | no | worker | ffmpeg failed while decoding |
| `timeout` | no | worker | Ran past max(10 min, 3x duration) |
| `oom_or_signal` | yes | worker | ffmpeg killed by a signal or OOM |
| `storage_error` | yes | worker | MinIO or Postgres timeout |
| `lease_expired` | yes | scheduler (reaper) | Worker stopped heartbeating |
| `upload_timeout` | no | scheduler (cleanup) | Never uploaded or confirmed inside the upload window |
| `canceled` | no | api or worker | Canceled by the user |

While a task is `RETRYING`, `error` holds the error from the last attempt and `retryable` is true.

## Shared objects

### Job (summary)

Returned by `GET /api/jobs` and embedded in `POST /api/jobs`.

```json
{
  "id": "01928c3e-5f2a-7b4c-9d1e-2f3a4b5c6d7e",
  "name": "Vacation clips",
  "status": "RUNNING",
  "task_counts": {
    "total": 3,
    "pending_upload": 0, "queued": 1, "running": 1, "retrying": 0,
    "success": 1, "failed": 0, "canceled": 0, "expired": 0
  },
  "progress": 52.3,
  "cancelable": true,
  "queue_ahead": 4,
  "created_at": "2026-10-04T18:21:07.123Z",
  "updated_at": "2026-10-04T18:25:41.002Z",
  "finished_at": null
}
```

### Job (detail)

Returned by `GET /api/jobs/{id}` and both cancel routes. It is the summary plus `tasks`, ordered by `position`.

```json
{
  "id": "…", "name": "…", "status": "…", "task_counts": { … }, "progress": 52.3,
  "cancelable": true, "queue_ahead": 4,
  "created_at": "…", "updated_at": "…", "finished_at": null,
  "tasks": [ Task, … ]
}
```

### Task

```json
{
  "id": "01928c3e-6a10-7c2d-8e3f-4a5b6c7d8e9f",
  "job_id": "01928c3e-5f2a-7b4c-9d1e-2f3a4b5c6d7e",
  "position": 0,
  "status": "SUCCESS",
  "filename": "beach.mov",
  "size_bytes": 184320512,
  "input": {
    "format": "mov",
    "duration_s": 94.2,
    "width": 1920,
    "height": 1080,
    "fps": 29.97,
    "video_codec": "h264",
    "audio_codec": "aac"
  },
  "params": {
    "container": "mp4",
    "video_codec": "h264",
    "resolution": "720p",
    "quality": { "mode": "crf", "crf": 23, "bitrate_kbps": null },
    "fps": "original",
    "audio": "keep"
  },
  "notices": [],
  "progress": 100,
  "attempt": 1,
  "max_attempts": 3,
  "cancelable": false,
  "cancel_requested": false,
  "queue_ahead": null,
  "next_attempt_at": null,
  "upload_expires_at": "2026-10-04T18:51:07.123Z",
  "error": null,
  "output": {
    "filename": "beach_transcoded.mp4",
    "size_bytes": 61234567,
    "expires_at": "2026-10-05T18:24:10.000Z",
    "download_url": "/api/tasks/01928c3e-6a10-7c2d-8e3f-4a5b6c7d8e9f/download"
  },
  "created_at": "…", "queued_at": "…", "started_at": "…", "finished_at": "…"
}
```

| Field | Notes |
|---|---|
| `size_bytes` | The declared size until the upload is confirmed, then the real size from StatObject |
| `input` | `null` until the upload is confirmed and probed |
| `params` | The **effective** params. If the requested resolution was above the source, it is stored as `"original"` and a notice is added |
| `notices` | `[{ "code": "resolution_clamped", "message": "Requested 1080p but the source is 720p, so the original resolution was kept." }]`. `resolution_clamped` is the only notice code for now |
| `error` | `{ "code", "message", "retryable" }` or `null` |
| `output` | Present only while `status = SUCCESS`, otherwise `null` |
| `next_attempt_at` | Set while `RETRYING`, so the UI can show "retrying in 20s" |

Never exposed: `worker_id`, `lease_expires_at`, `dispatched_at`, object keys, `idempotency_key`, task attempts and the ffmpeg stderr tail.

### TranscodeParams

```json
{
  "container": "mp4",
  "video_codec": "h264",
  "resolution": "720p",
  "quality": { "mode": "crf", "crf": 23, "bitrate_kbps": null },
  "fps": "original",
  "audio": "keep"
}
```

- `quality.mode = "crf"` requires `crf` inside that codec's range, and `bitrate_kbps` must be `null`.
- `quality.mode = "bitrate"` requires `bitrate_kbps` from 500 to 20000, and `crf` must be `null`.
- The allowed values and valid combos come from `GET /api/config`. The frontend builds the form from it and the api validates against the same Go values.

### Derived fields

- **`progress` (job).** Weighted average of task progress, weighted by input duration. Terminal tasks (`SUCCESS`, `FAILED`, `CANCELED`, `EXPIRED`) count as 100. `PENDING_UPLOAD` and `QUEUED` count as 0. A task without a known duration yet uses the mean of the known durations, or 1 if none is known. Task progress resets to 0 when a task goes to `RETRYING`, so job progress can move backwards.
- **`cancelable` (task).** True when the status is `PENDING_UPLOAD`, `QUEUED` or `RETRYING`, or the status is `RUNNING` and `cancel_requested` is false. A job is cancelable when any of its tasks is.
- **`queue_ahead` (task).** For a `QUEUED` task, the number of `QUEUED` tasks across all users with an earlier `queued_at`. The UI shows it as "~N ahead", because per-user fairness can let tasks skip ahead. It is `null` for any other status.
- **`queue_ahead` (job).** The minimum over the job's `QUEUED` tasks, or `null` if it has none.

## Routes

### `GET /api/auth/login`

Query: `return_to` (optional, a relative path such as `/jobs/0192…`). Redirects to Google. Full details in [OAUTH.md](OAUTH.md).

### `GET /api/auth/callback`

Called by Google. On success it sets `sid` and redirects to `return_to` or `/dashboard`. On failure it redirects to `/?auth_error=<code>`. See [OAUTH.md](OAUTH.md).

### `POST /api/auth/logout`

Deletes the Redis session and clears the cookie. Answers **204** even if the session was already gone, so logging out twice is never an error.

### `GET /api/me`

```json
{
  "id": "01928c3e-…",
  "email": "user@example.com",
  "name": "Jane Doe",
  "avatar_url": "https://lh3.googleusercontent.com/…"
}
```

Used for the auth check and the avatar and name in the header. There is no profile page.

### `GET /api/config`

Public, cached for 5 minutes, rate limited per IP. The values come from the same Go constants and env vars the api enforces, so the frontend never keeps its own copy.

```json
{
  "limits": {
    "max_videos_per_job": 10,
    "max_file_size_bytes": 524288000,
    "max_duration_s": 1800,
    "max_input_width": 3840,
    "max_input_height": 2160,
    "max_input_fps": 60,
    "max_unfinished_tasks": 50,
    "max_in_flight_tasks": 2,
    "max_job_name_length": 100,
    "max_filename_length": 255,
    "max_attempts": 3,
    "upload_window_s": 1800,
    "output_ttl_s": 86400,
    "job_progress_interval_s": 10,
    "rate_limits": {
      "requests_per_min": 60,
      "jobs_per_min": 5,
      "sse_connections": 5
    }
  },
  "input_formats": ["mp4", "mov", "mkv", "webm", "avi"],
  "options": {
    "containers": [
      { "id": "mp4",  "label": "MP4",  "video_codecs": ["h264", "h265"],         "audio_codec": "aac" },
      { "id": "webm", "label": "WebM", "video_codecs": ["vp9"],                  "audio_codec": "opus" },
      { "id": "mkv",  "label": "MKV",  "video_codecs": ["h264", "h265", "vp9"],  "audio_codec": "aac" }
    ],
    "video_codecs": [
      { "id": "h264", "label": "H.264", "crf": { "min": 18, "max": 30, "default": 23 } },
      { "id": "h265", "label": "H.265", "crf": { "min": 20, "max": 32, "default": 28 } },
      { "id": "vp9",  "label": "VP9",   "crf": { "min": 20, "max": 45, "default": 32 } }
    ],
    "resolutions": ["480p", "720p", "1080p", "original"],
    "quality_modes": ["crf", "bitrate"],
    "bitrate_kbps": { "min": 500, "max": 20000, "default": 4000 },
    "fps": ["24", "30", "60", "original"],
    "audio": ["keep", "strip"]
  },
  "presets": [
    { "id": "mp4_720p",       "label": "720p MP4",         "params": { "container": "mp4",  "video_codec": "h264", "resolution": "720p",     "quality": { "mode": "crf", "crf": 23, "bitrate_kbps": null }, "fps": "original", "audio": "keep" } },
    { "id": "mp4_1080p",      "label": "1080p MP4",        "params": { "container": "mp4",  "video_codec": "h264", "resolution": "1080p",    "quality": { "mode": "crf", "crf": 23, "bitrate_kbps": null }, "fps": "original", "audio": "keep" } },
    { "id": "webm_1080p",     "label": "1080p WebM",       "params": { "container": "webm", "video_codec": "vp9",  "resolution": "1080p",    "quality": { "mode": "crf", "crf": 32, "bitrate_kbps": null }, "fps": "original", "audio": "keep" } },
    { "id": "mp4_480p_small", "label": "480p MP4 (small)", "params": { "container": "mp4",  "video_codec": "h264", "resolution": "480p",     "quality": { "mode": "crf", "crf": 28, "bitrate_kbps": null }, "fps": "30",       "audio": "keep" } },
    { "id": "mp4_h265",       "label": "Compress (H.265)", "params": { "container": "mp4",  "video_codec": "h265", "resolution": "original", "quality": { "mode": "crf", "crf": 28, "bitrate_kbps": null }, "fps": "original", "audio": "keep" } }
  ],
  "default_preset": "mp4_720p"
}
```

A container's `video_codecs` list is the valid-combo rule (webm only allows vp9). The audio codec is fixed per container and is not a user option.

### `POST /api/jobs`

Headers: `Idempotency-Key: <uuid>` (required, 1 to 255 chars). The frontend generates it once per form submission and reuses it on retries.

Rate limits: general bucket and the 5 jobs/min bucket.

```json
{
  "name": "Vacation clips",
  "tasks": [
    {
      "filename": "beach.mov",
      "size_bytes": 184320512,
      "params": { "container": "mp4", "video_codec": "h264", "resolution": "720p",
                  "quality": { "mode": "crf", "crf": 23, "bitrate_kbps": null },
                  "fps": "original", "audio": "keep" }
    }
  ]
}
```

| Field | Rule |
|---|---|
| `name` | Optional, trimmed, 1 to 100 chars. If empty it defaults to the first filename, plus `" + N more"` for batches |
| `tasks` | 1 to 10 items |
| `tasks[].filename` | 1 to 255 chars. The extension must be an allowed input format. Display only, never used as a path |
| `tasks[].size_bytes` | 1 to 524288000. Becomes the upper bound of the upload policy |
| `tasks[].params` | Must pass TranscodeParams validation |

Processing order:
1. Auth, then rate limits.
2. Idempotency lookup on `(user_id, Idempotency-Key)`:
   - Found and the SHA-256 of the canonical body matches: answer **200** with the original job.
   - Found and the hash differs: **422** `idempotency_key_reused`.
3. Validate the body (400 `validation_failed`).
4. Quota check: unfinished tasks (`PENDING_UPLOAD`, `QUEUED`, `RUNNING`, `RETRYING`) plus new tasks must be at most 50 (429 `quota_exceeded`).
5. One transaction inserts the job (with the key and request hash) and its tasks as `PENDING_UPLOAD`. Each task gets `upload_expires_at = now() + 30 min`.
6. Answer **201**.

If two requests with the same key race, the unique constraint catches the second one. It then re-reads the row and follows step 2.

Response (201 on create, 200 on replay):

```json
{
  "job": { …Job summary, status "PENDING_UPLOAD" },
  "tasks": [
    {
      "id": "01928c3e-6a10-7c2d-8e3f-4a5b6c7d8e9f",
      "position": 0,
      "filename": "beach.mov",
      "status": "PENDING_UPLOAD",
      "upload": {
        "url": "http://localhost/uploads",
        "fields": {
          "key": "{user_id}/{task_id}",
          "policy": "eyJleHBpcmF0aW9uIjoi…",
          "x-amz-algorithm": "AWS4-HMAC-SHA256",
          "x-amz-credential": "…/20261004/us-east-1/s3/aws4_request",
          "x-amz-date": "20261004T182107Z",
          "x-amz-signature": "…",
          "success_action_status": "204"
        },
        "expires_at": "2026-10-04T18:51:07.123Z"
      }
    }
  ]
}
```

- Every job returns its tasks, single video or not.
- The upload policy pins the bucket (`uploads`), the exact key, `content-length-range: [1, size_bytes]` and an absolute expiration equal to `upload_expires_at`.
- A replay re-signs the forms with the **same** expiration, so a replay never extends the window. Once a task's window has passed, its `upload` is `null`.
- There is no route to get a new upload form. Once the window passes, the video is gone and the user creates a new job.

**Browser upload.** For each task, build a `FormData` with every entry of `fields` first and the file last under the name `file`. Send it with `XMLHttpRequest` (for upload progress events) as a `POST` to `upload.url`. MinIO answers 204 on success and 403 if the file is larger than declared or the window has passed. Then call `POST /api/tasks/{id}/uploaded`.

### `GET /api/jobs`

| Query | Values |
|---|---|
| `scope` | `open` (default) or `history` |
| `limit` | `history` only, 1 to 50, default 20 |
| `cursor` | `history` only, the `next_cursor` from the previous page |

- **`scope=open`** returns every job with status `PENDING_UPLOAD`, `QUEUED` or `RUNNING`, newest first, **not paginated**. The list is small, since a user can't have more than 50 unfinished tasks. The dashboard puts `PENDING_UPLOAD` and `RUNNING` in **Active** and `QUEUED` in **Queued**.
- **`scope=history`** returns jobs with status `SUCCESS`, `PARTIAL_SUCCESS`, `FAILED`, `CANCELED` or `EXPIRED`, ordered by `created_at DESC, id DESC`. The cursor is opaque base64url JSON of `{"created_at", "id"}`. The query is `WHERE user_id = $1 AND (created_at, id) < ($2, $3)`, served by the `jobs (user_id, created_at desc, id desc)` index.

```json
{
  "data": [ Job summary, … ],
  "next_cursor": "eyJjcmVhdGVkX2F0IjoiMjAyNi0xMC0wNFQxODoyMTowNy4xMjNaIiwiaWQiOiIwMTkyOGMzZS0uLi4ifQ"
}
```

`next_cursor` is `null` on the last page, and always `null` for `scope=open`. A bad cursor answers 400 `bad_request`.

### `GET /api/jobs/{id}`

Answers 200 with a Job detail, or 404.

### `POST /api/jobs/{id}/cancel`

Body: none. In one transaction:
- `PENDING_UPLOAD`, `QUEUED` and `RETRYING` tasks become `CANCELED`, with error code `canceled` and `finished_at` set.
- `RUNNING` tasks get `cancel_requested = true`. A worker finishes the cancel within one heartbeat (10s).
- Job status is recomputed with the job row locked.

| Result | Response |
|---|---|
| At least one task was canceled or flagged, or a cancel is already in progress | **202** with the Job detail |
| Every task is already terminal | **409** `not_cancelable` |
| Not found or not owned | 404 |

Calling it again while a running task is still canceling answers 202, so a double click is harmless.

### `POST /api/tasks/{id}/uploaded`

Body: none. Confirms the browser's upload and answers with the task's resulting status.

| Task status when called | What happens | Response |
|---|---|---|
| `PENDING_UPLOAD`, object missing | Nothing changes. The browser may retry the upload while the window is open | **409** `upload_not_found` |
| `PENDING_UPLOAD`, object present | Synchronous validation: StatObject, then ffprobe via a presigned GET with a 10s timeout (see [input-validation](diagrams/activity/input-validation.md)) | **200** with the Task, now `QUEUED`, or `FAILED` with an `error` |
| Any other status | Nothing changes | **200** with the current Task |

A video that fails validation is a successful request with a failed task. The answer is 200 with `status: "FAILED"` and `error` set, not a 4xx. This makes the route safe to call twice and means it always tells the client where the upload stands.

### `POST /api/tasks/{id}/cancel`

Same rules as the job cancel route, but for one task. Answers **202** with the parent Job detail, because the job's status and counts change too. Answers 409 `not_cancelable` if the task is terminal.

### `GET /api/tasks/{id}/download`

A browser navigation, not a fetch. The frontend renders `<a href={task.output.download_url}>` only while the task is `SUCCESS`.

| Case | Response |
|---|---|
| `SUCCESS` | **302** to a presigned MinIO GET (5 min) with `response-content-disposition: attachment; filename="beach_transcoded.mp4"; filename*=UTF-8''beach_transcoded.mp4` |
| `EXPIRED` | 410 `output_expired` |
| Any other status | 409 `output_not_ready` |
| Not found or not owned | 404 |

The download filename is the sanitized original base name plus `_transcoded` and the output extension. Sanitizing keeps letters, digits, space, `.`, `-` and `_`, replaces everything else with `_` and caps the result at 100 chars. The `filename*` form keeps non-ASCII names intact for browsers that support it.

### `GET /api/events`

The SSE stream. See [SSE.md](SSE.md).

## Rate limits

| Bucket | Key | Limit | Applies to |
|---|---|---|---|
| General | user_id | 60/min | Every authenticated route |
| Job creation | user_id | 5/min | `POST /api/jobs`, in addition to general |
| Public | client IP (`X-Real-IP` from nginx) | 30/min | `/api/auth/*`, `/api/config` |
| SSE connections | user_id | 5 open | `GET /api/events` |

All limits are configurable via env, and `/api/config` reports the effective values.

## Frontend polling budget

Queue positions are pulled, not pushed. To stay well under 60 requests/min:
- The dashboard refetches `GET /api/jobs?scope=open` every 10s, and only while at least one job is `QUEUED`.
- The job page refetches `GET /api/jobs/{id}` every 10s, and only while one of its tasks is `QUEUED`.
- Refetches triggered by `task.status` events are debounced by 1s.
- History is fetched on mount and on "load more" only.

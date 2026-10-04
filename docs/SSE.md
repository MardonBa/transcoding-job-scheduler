# Server-Sent Events

Live updates from the backend to the browser. REST shapes and field definitions are in [API.md](API.md). The delivery path is drawn in [05-progress-sse](diagrams/sequence/05-progress-sse.md).

## Endpoint

`GET /api/events`, authenticated with the `sid` cookie. The browser uses `new EventSource("/api/events")`. It is same origin, so no `withCredentials` is needed.

Response headers:

```
Content-Type: text/event-stream
Cache-Control: no-store
Connection: keep-alive
X-Accel-Buffering: no
```

| Case | Response |
|---|---|
| No valid session | 401 with the JSON error body |
| Already 5 open streams for this user | 429 `rate_limited`, `details.limit = "sse_connections"` |
| Otherwise | 200 and the stream starts |

One connection per browser tab. The dashboard and the job page share the same stream through a single React context, so moving between pages does not reconnect.

## Wire format

Each message is an SSE `event:` line plus one JSON `data:` line:

```
event: task.progress
data: {"job_id":"0192…","task_id":"0192…","attempt":1,"progress":63.4,"eta_s":41,"speed":1.8,"ts":"2026-10-04T18:23:11.512Z"}

```

- **No `id:` lines and no `Last-Event-ID` replay.** Pub/sub is fire and forget. Postgres is the truth, and the client refetches on every (re)connect.
- **First message** is `retry: 3000`, which sets the browser's auto-reconnect delay to 3s, followed by a `ready` event.
- **Keepalive** is a `: ping` comment every 15s. On each keepalive the api also checks that the session still exists. If it is gone (logout or expiry), the api closes the stream, and the reconnect gets a 401.

## Events

Every event payload has `ts` (when the publisher created it). Every task and job event has `job_id`, which is how a task event is tied to its job.

| Event | Sent when | Publisher |
|---|---|---|
| `ready` | Stream registered in the hub | api |
| `task.status` | A task changes status, or `cancel_requested` flips to true | whoever made the change: api, worker or scheduler |
| `task.progress` | ffmpeg reports progress, at most once per second per task | worker |
| `job.status` | The derived job status or task counts change | whoever changed the task |
| `job.progress` | Every heartbeat (10s) of a running task in the job | worker |

### `ready`

```json
{ "server_time": "2026-10-04T18:21:07.123Z", "ts": "2026-10-04T18:21:07.123Z" }
```

When the client receives `ready` it refetches whatever is on screen (`GET /api/jobs?scope=open`, or `GET /api/jobs/{id}`). The refetch waits for `ready` rather than `onopen`, so the hub is already forwarding events before the snapshot is taken. That way nothing falls into the gap between the two.

### `task.status`

```json
{
  "job_id": "0192…",
  "task_id": "0192…",
  "status": "RETRYING",
  "prev_status": "RUNNING",
  "attempt": 2,
  "max_attempts": 3,
  "progress": 0,
  "cancel_requested": false,
  "cancelable": true,
  "error": { "code": "storage_error", "message": "Upload to storage timed out.", "retryable": true },
  "next_attempt_at": "2026-10-04T18:23:41.000Z",
  "output": null,
  "notices": [],
  "ts": "2026-10-04T18:23:11.204Z"
}
```

- `prev_status` equals `status` when the event is only a `cancel_requested` flip. The UI then shows "Canceling…".
- `output` has the same shape as in the REST Task and is set only on `SUCCESS`.
- `notices` is filled when the task reaches `QUEUED` after validation, for example with `resolution_clamped`.
- `error` is set on `FAILED`, `RETRYING` and `CANCELED`, and is `null` otherwise.

### `task.progress`

```json
{
  "job_id": "0192…",
  "task_id": "0192…",
  "attempt": 2,
  "progress": 63.4,
  "eta_s": 41,
  "speed": 1.8,
  "ts": "2026-10-04T18:23:11.512Z"
}
```

- `progress` is `out_time / input duration * 100`, rounded to 1 decimal.
- `speed` is media seconds processed per wall second, as ffmpeg reports it. It is `null` until known.
- `eta_s` is `(duration - out_time) / speed`. It is `null` until `speed` is known.
- Progress events are **not** written to Postgres. The heartbeat writes progress every 10s.

### `job.status`

```json
{
  "job_id": "0192…",
  "status": "PARTIAL_SUCCESS",
  "prev_status": "RUNNING",
  "task_counts": {
    "total": 3,
    "pending_upload": 0, "queued": 0, "running": 0, "retrying": 0,
    "success": 2, "failed": 1, "canceled": 0, "expired": 0
  },
  "progress": 100,
  "cancelable": false,
  "finished_at": "2026-10-04T18:30:02.881Z",
  "ts": "2026-10-04T18:30:02.884Z"
}
```

It is sent whenever task counts change, even if the job status itself stays the same. For example, the first of three tasks finishing leaves the job `RUNNING` but changes the counts. The client never derives job status itself and always takes it from this event or from REST.

### `job.progress`

```json
{ "job_id": "0192…", "progress": 47.9, "ts": "2026-10-04T18:23:20.000Z" }
```

- **Who publishes it.** The worker, on every heartbeat (10s), after writing its task's progress. It recomputes job progress in SQL from every task in the job, using the formula in [API.md](API.md#derived-fields).
- **Other updates.** `job.status` also carries `progress`, so status changes update the bar right away.
- **Duplicates.** A job with two tasks running at once gets a `job.progress` from each worker's heartbeat. That's harmless, since each one carries the full recomputed value.
- **Animation.** The client tweens the job bar from the value on screen to the new value over `job_progress_interval_s` (10s, from `/api/config`). That makes the bar move smoothly instead of jumping every 10s. If a newer value arrives mid-tween, restart the tween from the current on-screen value. The value can go **down** when a task retries, and the tween handles that the same way.

## Client rules

1. **Ordering.** Messages from different publishers (api versus worker) are not ordered relative to each other. Per task, keep the latest `ts` seen and drop any `task.status` or `task.progress` older than it. Do the same per job for `job.status` and `job.progress`. All containers run on one host clock, so `ts` is safe to compare.
2. **Stale progress.** Drop a `task.progress` whose `attempt` is lower than the task's current attempt, or whose task is already terminal.
3. **Unknown ids.** An event for a job that isn't loaded (for example a job created in another tab) triggers a debounced refetch of the open jobs list.
4. **Queue positions.** These never come over SSE. A `task.status` event triggers a debounced (1s) refetch, plus the 10s poll described in [API.md](API.md#frontend-polling-budget).
5. **Errors and reconnects.**
   - `EventSource` reconnects by itself after network drops, and each reconnect produces a fresh `ready` and refetch.
   - On a non-200 response (401 or 429) the browser **does not** retry, and `readyState` becomes `CLOSED`. In `onerror`, if `readyState === CLOSED`, call `GET /api/me`. On a 401, go to the landing page. Otherwise reconnect manually with backoff: 1s, 2s, 4s and so on, capped at 30s.
6. **Logout.** Close the `EventSource` before calling `POST /api/auth/logout`.

## Server side

- **Redis channel.** `user:{user_id}:events`. Message body: `{"type": "<event name>", "data": { …payload… }}`. The api turns it into `event: <type>` and `data: <json(data)>` without parsing the payload.
- **Hub.** Each api instance holds one `PSUBSCRIBE user:*:events` and a map from `user_id` to open connections. Each connection has a buffered channel of 64 messages. If the buffer fills (a slow client), the api closes that connection, and the client's reconnect and refetch bring it back in sync.
- **Connection limit.** On connect: `INCR sse_conns:{user_id}`, and if the result is above 5, `DECR` and answer 429. On disconnect: `DECR`. Each keepalive refreshes `EXPIRE sse_conns:{user_id} 60`, so an api crash can't leave the counter stuck.
- **Publish order.** Status changes are committed to Postgres first and published second. For one task change the order is `task.status`, then `job.status`. Status events are never sent through the outbox: they are best effort, and the refetch on `ready` plus polling covers anything that gets lost.

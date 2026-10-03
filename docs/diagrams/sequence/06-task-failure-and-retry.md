# Task Failure and Retry

Shows what happens when ffmpeg exits non-zero. The worker classifies the failure into an error_code, then either schedules a retry (RETRYING with backoff of 10s, 30s, 90s plus jitter) or marks the task FAILED when the error is fatal or all 3 attempts are used. The scheduler's retry loop later moves the task back to QUEUED and the dispatcher picks it up again. Reflects the Statuses, Queue, Scheduler loops and Storage sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    participant Worker as Go worker
    participant FFmpeg as ffmpeg
    participant PG as Postgres
    participant RPubSub as Redis pub/sub
    participant Sched as Go scheduler

    Note over Worker: Scratch dir /scratch/task_id is deleted by defer on every path
    FFmpeg-->>Worker: exit non-zero (stderr tail captured)
    Worker->>Worker: classify error into error_code

    alt retryable error and attempt < max_attempts (3)
        Worker->>PG: BEGIN
        Worker->>PG: UPDATE tasks SET status RETRYING, next_attempt_at = now + backoff (10s/30s/90s + jitter), clear worker_id and lease WHERE id AND status = RUNNING
        Worker->>PG: UPDATE task_attempts SET finished_at, outcome = retryable_error, error_message, ffmpeg_stderr_tail
        Worker->>PG: recompute job status (SELECT FOR UPDATE on job row)
        Worker->>PG: COMMIT
        Worker->>RPubSub: PUBLISH user:user_id:events task.status RETRYING and job.status
    else fatal error or out of attempts
        Worker->>PG: BEGIN
        Worker->>PG: UPDATE tasks SET status FAILED, error_code, error_message, finished_at WHERE id AND status = RUNNING
        Worker->>PG: UPDATE task_attempts SET finished_at, outcome = fatal_error, error_message, ffmpeg_stderr_tail
        Worker->>PG: SELECT job row FOR UPDATE then recompute job status
        Worker->>PG: COMMIT
        Worker->>RPubSub: PUBLISH task.status FAILED and job.status
    end
    Worker->>Worker: deferred cleanup removes scratch dir

    loop every 5s (retry scheduler)
        Sched->>PG: SELECT RETRYING tasks with next_attempt_at at or before now
        Sched->>PG: UPDATE tasks SET status QUEUED, dispatched_at = NULL WHERE id AND status = RETRYING
        Sched->>RPubSub: PUBLISH task.status QUEUED
    end

    Note over Sched,Worker: Dispatcher sees QUEUED with dispatched_at null and re-dispatches via outbox and Redis stream. See 03-dispatch-and-outbox.md
```

## Notes
- Retryable codes: lease expired, ffmpeg killed by signal or OOM, MinIO or Postgres timeouts. Not retryable: invalid or corrupt input, unsupported codec, decode error, timeout, canceled.
- Status changes are written to Postgres first, then published. Pub/sub is fire and forget.
- The input object is kept while retries are possible and deleted once the task is terminal.

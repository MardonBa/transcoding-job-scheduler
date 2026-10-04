# Task Timeout

Shows how a runaway transcode is stopped. ffmpeg runs under exec.CommandContext with a deadline of max(10 min, 3x input duration) in its own process group. When the deadline hits, the whole group is killed and the task goes straight to FAILED with error_code timeout, since the same input would just time out again. Reflects the CPU Management and Statuses sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    participant Worker as Go worker
    participant FFmpeg as ffmpeg
    participant PG as Postgres
    participant RPubSub as Redis pub/sub

    Worker->>Worker: deadline = max(10 min, 3x input duration from input_metadata)
    Worker->>FFmpeg: exec.CommandContext(ctx with deadline) in own process group
    loop while running
        FFmpeg-->>Worker: -progress pipe:1 out_time_us lines
        Worker->>RPubSub: PUBLISH task.progress (at most once per second)
        Worker->>PG: heartbeat every 10s (lease and progress)
    end
    Note over Worker: context deadline exceeded
    Worker->>FFmpeg: kill whole process group
    FFmpeg-->>Worker: terminated
    Worker->>Worker: classify as timeout (not retryable)
    Worker->>PG: BEGIN
    Worker->>PG: UPDATE tasks SET FAILED, error_code timeout, error_message WHERE id AND status = RUNNING
    Worker->>PG: UPDATE task_attempts SET finished_at, outcome = fatal_error, error_message, ffmpeg_stderr_tail
    Worker->>PG: SELECT job FOR UPDATE then recompute job status
    Worker->>PG: COMMIT
    Worker->>RPubSub: PUBLISH task.status FAILED and job.status
    Worker->>Worker: deferred cleanup removes scratch dir
```

## Notes
- No retry is scheduled even if attempts remain.
- Timeout is a deadline on wall-clock time, so a slow server makes it more likely. Encoder presets are chosen with that in mind (see the CPU Management section of the notes).
- The task_attempts outcome value fatal_error is used because the allowed outcomes are success, retryable_error, fatal_error, lease_expired, canceled, interrupted. The timeout detail lives in error_code and error_message.

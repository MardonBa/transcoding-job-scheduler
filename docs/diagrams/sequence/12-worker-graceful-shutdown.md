# Worker Graceful Shutdown

On SIGTERM the worker stops pulling new messages, kills every running ffmpeg process group and puts those tasks back to QUEUED without counting the attempt, then exits. It does not wait for transcodes to finish because they can be long. The dispatcher later re-dispatches the requeued tasks. Reflects the CPU Management (graceful shutdown) and Queue sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    participant Docker as Container runtime
    participant Worker as Go worker
    participant RStream as Redis stream
    participant FFmpeg as ffmpeg
    participant PG as Postgres
    participant RPubSub as Redis pub/sub
    participant Sched as Go scheduler

    Docker->>Worker: SIGTERM
    Worker->>Worker: stop reading, no new XREADGROUP
    par for each running slot
        Worker->>FFmpeg: kill process group
        FFmpeg-->>Worker: terminated
        Worker->>PG: BEGIN
        Worker->>PG: UPDATE tasks SET QUEUED, worker_id = NULL, lease_expires_at = NULL, dispatched_at = NULL, attempt = attempt - 1 WHERE id AND status = RUNNING
        Worker->>PG: UPDATE task_attempts SET finished_at, outcome = interrupted, error_message = worker shutdown
        Worker->>PG: SELECT job FOR UPDATE then recompute job status
        Worker->>PG: COMMIT
        Worker->>RPubSub: PUBLISH task.status QUEUED and job.status
        Worker->>Worker: delete scratch dir
    end
    Worker->>Worker: all slots done, process exits

    Note over Sched,RStream: Dispatcher sees QUEUED with dispatched_at null and pushes it again via outbox and Redis stream. See 03-dispatch-and-outbox.md
```

## Notes
- Decrementing attempt means a deploy or restart never burns one of the 3 attempts.
- If the worker is killed before finishing (for example SIGKILL after the grace period), the normal lease reaper path in 07-worker-crash-recovery.md applies.

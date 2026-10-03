# Cleanup

The scheduler's cleanup loop runs every hour and handles two cases. Expired outputs (SUCCESS past output_expires_at) are deleted from MinIO and the task becomes EXPIRED. Uploads that never completed (PENDING_UPLOAD older than 1h) are cleaned up and failed with upload_timeout. A MinIO lifecycle rule is a backstop. Reflects the Storage, Scheduler loops and Statuses sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    participant Sched as Go scheduler
    participant PG as Postgres
    participant MinIO
    participant RPubSub as Redis pub/sub

    loop every hour (cleanup)
        rect rgb(245, 245, 245)
        Note over Sched,RPubSub: (a) expired outputs
        Sched->>PG: SELECT tasks WHERE status = SUCCESS AND output_expires_at before now
        loop each expired task
            Sched->>MinIO: delete outputs/user_id/task_id.ext
            Sched->>PG: BEGIN
            Sched->>PG: UPDATE tasks SET EXPIRED WHERE id AND status = SUCCESS
            Sched->>PG: SELECT job FOR UPDATE then recompute job status (EXPIRED when all outputs expired)
            Sched->>PG: COMMIT
            Sched->>RPubSub: PUBLISH task.status EXPIRED and job.status
        end
        end

        rect rgb(245, 245, 245)
        Note over Sched,RPubSub: (b) abandoned uploads
        Sched->>PG: SELECT tasks WHERE status = PENDING_UPLOAD AND created_at older than 1h
        loop each stale task
            Sched->>MinIO: delete uploads/user_id/task_id if present
            Sched->>PG: BEGIN
            Sched->>PG: UPDATE tasks SET FAILED, error_code upload_timeout WHERE id AND status = PENDING_UPLOAD
            Sched->>PG: SELECT job FOR UPDATE then recompute job status
            Sched->>PG: COMMIT
            Sched->>RPubSub: PUBLISH task.status FAILED and job.status
        end
        end
    end

    Note over MinIO: (c) Lifecycle rule on the uploads bucket deletes anything older than 2 days as a backstop if the loop misses something
```

## Notes
- Every transition is a conditional update, so cleanup cannot clobber a task that changed state in the meantime.
- Delete-then-update order means a crash in between is safe: the next run finds the task still SUCCESS and deleting a missing object is harmless.

# Cleanup

The scheduler's cleanup loop runs every 5 minutes and handles three cases. Expired outputs (SUCCESS past output_expires_at) are deleted from MinIO and the task becomes EXPIRED. Uploads that were never confirmed (PENDING_UPLOAD 15 min past their upload window) are failed with upload_timeout. Inputs of terminal tasks are deleted as soon as no upload can still land. A MinIO lifecycle rule is a backstop. Reflects the Storage, Scheduler loops and Statuses sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    participant Sched as Go scheduler
    participant PG as Postgres
    participant MinIO
    participant RPubSub as Redis pub/sub

    loop Every 5 min (cleanup)
        rect rgb(245, 245, 245)
        Note over Sched,RPubSub: (a) expired outputs
        Sched->>PG: SELECT tasks WHERE status = SUCCESS AND output_expires_at before now
        loop Each expired task
            Sched->>MinIO: Delete outputs bucket, key user_id/task_id.ext
            Sched->>PG: BEGIN
            Sched->>PG: UPDATE tasks SET EXPIRED WHERE id AND status = SUCCESS
            Sched->>PG: SELECT job FOR UPDATE, recompute job status (EXPIRED when all outputs expired)
            Sched->>PG: COMMIT
            Sched->>RPubSub: PUBLISH task.status EXPIRED, then job.status
        end
        end

        rect rgb(245, 245, 245)
        Note over Sched,RPubSub: (b) abandoned uploads
        Sched->>PG: SELECT tasks WHERE status = PENDING_UPLOAD AND upload_expires_at + 15 min before now
        loop Each stale task
            Sched->>PG: BEGIN
            Sched->>PG: UPDATE tasks SET FAILED, error_code upload_timeout WHERE id AND status = PENDING_UPLOAD
            Sched->>PG: SELECT job FOR UPDATE, recompute job status
            Sched->>PG: COMMIT
            Sched->>RPubSub: PUBLISH task.status FAILED, then job.status
        end
        end

        rect rgb(245, 245, 245)
        Note over Sched,RPubSub: (c) inputs of terminal tasks
        Sched->>PG: SELECT terminal tasks WHERE input_deleted_at IS NULL AND (queued_at IS NOT NULL OR upload_expires_at + 15 min before now)
        loop Each task
            Sched->>MinIO: Delete uploads bucket, key user_id/task_id (missing object is fine)
            Sched->>PG: UPDATE tasks SET input_deleted_at = now()
        end
        end
    end

    Note over MinIO: (d) Lifecycle rule on the uploads bucket deletes anything older than 1 day as a backstop
```

## Notes
- Every status transition is a conditional update, so cleanup cannot clobber a task that changed state in the meantime.
- Delete-then-update order means a crash in between is safe. The next run finds the task unchanged, and deleting a missing object is harmless.
- Why (c) waits: a task canceled or failed while still PENDING_UPLOAD may have an upload in flight that lands after a delete. A task that reached QUEUED (queued_at set) finished uploading, so nothing can land later. Otherwise cleanup waits until the upload window and grace period have passed, so no new object can appear after the final delete.
- The worker deletes the input right away on SUCCESS and sets input_deleted_at itself, so (c) mostly handles canceled, failed and timed-out tasks.
- Running every 5 minutes keeps outputs at roughly 24h and abandoned uploads at roughly 50 min at most.

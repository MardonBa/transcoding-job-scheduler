# Cancel Job or Task

The user cancels a whole job or a single video. In one transaction the api moves PENDING_UPLOAD, QUEUED and RETRYING tasks straight to CANCELED and flags RUNNING tasks with cancel_requested. The worker notices the flag on its next heartbeat (within 10s), kills the ffmpeg process group and finishes the cancel with a conditional update. If the worker dies before that, the lease reaper finishes the cancel. Reflects the Cancel Job interaction, Statuses, Queue and CPU Management sections of IMPLEMENTATION_NOTES.md and docs/API.md.

```mermaid
sequenceDiagram
    actor User
    participant Browser as Next.js frontend
    participant API as Go api
    participant PG as Postgres
    participant RPubSub as Redis pub/sub
    participant Worker as Go worker
    participant FFmpeg as ffmpeg
    participant Sched as Go scheduler

    User->>Browser: Press Cancel on the job, or on one video
    Browser->>API: POST /api/jobs/{id}/cancel or POST /api/tasks/{id}/cancel
    API->>PG: BEGIN, SELECT job FOR UPDATE WHERE id AND user_id = session user
    alt Not found or not owned
        API-->>Browser: 404 not_found
    else Every targeted task already terminal
        API-->>Browser: 409 not_cancelable
    else Something to cancel
        API->>PG: UPDATE targeted tasks SET CANCELED, error_code canceled, finished_at WHERE status IN (PENDING_UPLOAD, QUEUED, RETRYING)
        API->>PG: UPDATE targeted tasks SET cancel_requested = true WHERE status = RUNNING
        API->>PG: Recompute job status
        API->>PG: COMMIT
        API->>RPubSub: PUBLISH task.status per changed task, then job.status
        API-->>Browser: 202 job detail (running tasks show cancel_requested)
    end

    Note over Worker,PG: A QUEUED task already in the stream is still delivered later. The claim UPDATE ... WHERE status = QUEUED updates 0 rows, so the worker XACKs and skips it.
    Note over Browser,PG: A task canceled during upload may still finish uploading. Its /uploaded call returns 200 with status CANCELED, and cleanup deletes the object once the upload window has closed.

    loop Heartbeat every 10s
        Worker->>PG: Extend lease, write progress, read cancel_requested
    end
    PG-->>Worker: cancel_requested = true
    Worker->>FFmpeg: Kill process group
    FFmpeg-->>Worker: exits
    Worker->>PG: BEGIN
    Worker->>PG: UPDATE task SET CANCELED, error_code canceled, finished_at WHERE id AND status = RUNNING
    Worker->>PG: Finish task_attempts row, outcome canceled
    Worker->>PG: SELECT job FOR UPDATE, recompute job status
    Worker->>PG: COMMIT
    Worker->>RPubSub: PUBLISH task.status CANCELED, then job.status
    Worker->>Worker: Delete scratch dir, delete input object

    opt Worker died before seeing the flag
        Sched->>PG: Lease reaper finds expired lease with cancel_requested = true
        Sched->>PG: UPDATE task SET CANCELED WHERE id AND status = RUNNING, attempt outcome lease_expired, recompute job
        Sched->>RPubSub: PUBLISH task.status CANCELED, then job.status
    end
```

## Notes
- If the task finishes (SUCCESS) between the api setting the flag and the worker noticing it, the worker's conditional update decides which transition wins.
- Cancel is not retryable, so a canceled task never goes to RETRYING. The reaper checks cancel_requested before deciding between RETRYING and FAILED.
- Calling cancel again while a running task is still canceling returns 202, so double clicks are harmless.
- The api only forwards pub/sub events to the browser. Workers never talk to the api directly.

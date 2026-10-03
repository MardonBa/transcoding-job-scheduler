# Cancel Job

The user cancels a job. In one transaction the API moves QUEUED and RETRYING tasks straight to CANCELED and flags RUNNING tasks with cancel_requested. The worker notices the flag on its next heartbeat (within 10s), kills the ffmpeg process group and finishes the cancel with a conditional update. Reflects the Cancel Job interaction, Statuses, Queue and CPU Management sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    actor User
    participant Browser as Next.js frontend
    participant API as Go api
    participant PG as Postgres
    participant RPubSub as Redis pub/sub
    participant RStream as Redis stream
    participant Worker as Go worker
    participant FFmpeg as ffmpeg

    User->>Browser: press Cancel
    Browser->>API: POST /jobs/id/cancel
    API->>PG: SELECT job WHERE id AND user_id = session user
    alt job not found or not owned
        API-->>Browser: 404
    else owned
        API->>PG: BEGIN
        API->>PG: SELECT job FOR UPDATE
        API->>PG: UPDATE tasks SET CANCELED WHERE job_id AND status IN (QUEUED, RETRYING)
        API->>PG: UPDATE tasks SET cancel_requested = true WHERE job_id AND status = RUNNING
        API->>PG: recompute job status
        API->>PG: COMMIT
        API->>RPubSub: PUBLISH task.status and job.status
        API-->>Browser: 200
        RPubSub-->>Browser: SSE task.status CANCELED, job.status
    end

    Note over RStream,Worker: A QUEUED task already in the stream is still delivered later. The claim UPDATE ... WHERE status = QUEUED updates 0 rows, so the worker XACKs and skips it.

    loop heartbeat every 10s
        Worker->>PG: extend lease, write progress, read cancel_requested
    end
    PG-->>Worker: cancel_requested = true
    Worker->>FFmpeg: kill process group
    FFmpeg-->>Worker: exits
    Worker->>PG: BEGIN
    Worker->>PG: UPDATE tasks SET CANCELED, finished_at WHERE id AND status = RUNNING
    Worker->>PG: INSERT/UPDATE task_attempts outcome canceled
    Worker->>PG: SELECT job FOR UPDATE then recompute job status
    Worker->>PG: COMMIT
    Worker->>RPubSub: PUBLISH task.status CANCELED and job.status
    RPubSub-->>Browser: SSE update via api
    Worker->>Worker: delete scratch dir
```

## Notes
- If the task finishes (SUCCESS) between the API flagging it and the worker noticing, the worker's conditional update decides which transition wins.
- Cancel is not retryable, so the task never goes to RETRYING.
- The API only forwards pub/sub events to the browser. Workers never talk to the API directly.

# Worker Crash Recovery

Covers the two places a worker can die plus duplicate delivery. Window (a) is between XREADGROUP and the Postgres claim, where the message is left pending and another worker takes it with XAUTOCLAIM after 60s idle. Window (b) is after the claim, where heartbeats stop and the lease reaper retries or fails the task. The last section shows the same task_id delivered twice and the conditional claim making the second delivery a no-op. Reflects the Queue and Scheduler loops sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    participant Worker1 as Go worker 1
    participant Worker2 as Go worker 2
    participant RStream as Redis stream
    participant PG as Postgres
    participant Sched as Go scheduler
    participant RPubSub as Redis pub/sub
    participant MinIO

    rect rgb(245, 245, 245)
    Note over Worker1,MinIO: Window (a) crash after XREADGROUP but before the claim
    Worker1->>RStream: XREADGROUP (task_id)
    RStream-->>Worker1: message, now pending for Worker1
    Worker1-xWorker1: crash
    Note over RStream: message stays in the pending list, never ACKed
    Worker2->>RStream: XAUTOCLAIM messages idle more than 60s
    RStream-->>Worker2: task_id
    Worker2->>PG: UPDATE tasks SET RUNNING, worker_id, lease 30s, attempt + 1 WHERE id AND status = QUEUED
    PG-->>Worker2: 1 row
    Worker2->>RStream: XACK
    Note over Worker2: proceeds with the transcode
    end

    rect rgb(245, 245, 245)
    Note over Worker1,MinIO: Window (b) crash after the claim, mid transcode
    Worker1->>PG: claim task (RUNNING, lease 30s)
    Worker1->>RStream: XACK
    loop every 10s while alive
        Worker1->>PG: extend lease_expires_at, write progress
    end
    Worker1-xWorker1: crash, heartbeats stop
    loop every 15s (lease reaper)
        Sched->>PG: SELECT RUNNING tasks with lease_expires_at before now
    end
    alt cancel_requested = true
        Sched->>PG: UPDATE tasks SET CANCELED, error_code canceled WHERE id AND status = RUNNING
    else attempts left
        Sched->>PG: UPDATE tasks SET RETRYING, next_attempt_at, progress = 0 WHERE id AND status = RUNNING
    else out of attempts
        Sched->>PG: UPDATE tasks SET FAILED, error_code WHERE id AND status = RUNNING
    end
    Sched->>PG: INSERT task_attempts outcome lease_expired and recompute job status (FOR UPDATE)
    Sched->>RPubSub: PUBLISH task.status and job.status
    Note over Sched: Retry scheduler moves RETRYING to QUEUED later and the dispatcher re-dispatches. See 06-task-failure-and-retry.md and 03-dispatch-and-outbox.md
    Worker2->>PG: claim again on re-delivery (attempt + 1)
    Worker2->>MinIO: upload output to outputs bucket, key user_id/task_id.ext (overwrites any partial earlier output)
    end

    rect rgb(245, 245, 245)
    Note over Worker1,MinIO: Duplicate delivery of the same task_id
    RStream-->>Worker1: task_id (first copy)
    RStream-->>Worker2: task_id (second copy)
    Worker1->>PG: UPDATE ... SET RUNNING WHERE id AND status = QUEUED
    PG-->>Worker1: 1 row, proceeds
    Worker2->>PG: UPDATE ... SET RUNNING WHERE id AND status = QUEUED
    PG-->>Worker2: 0 rows
    Worker2->>RStream: XACK
    Note over Worker2: skips the task
    end
```

## Notes
- The output key is deterministic (bucket outputs, key {user_id}/{task_id}.{ext}), so a rerun simply overwrites any earlier partial or complete output.
- XACK happens right after the claim because the Postgres lease is the guarantee from then on.
- The reaper checks cancel_requested first. A worker that died mid cancel must not have its task retried.
- The outbox relay can also cause duplicates (crash between XADD and setting published_at). The same conditional claim handles it.

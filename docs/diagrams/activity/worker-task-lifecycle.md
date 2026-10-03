# Worker Task Lifecycle

This is the loop of a single worker slot, from waiting for capacity to cleaning up scratch space. A slot only reads from the stream when it is free, and the conditional claim in postgres is what guarantees one owner per task. Note the parallel heartbeat during ffmpeg, the five outcome branches, and that the scratch directory is always deleted. Reflects the Queue, CPU Management, Progress, Storage and Statuses sections of IMPLEMENTATION_NOTES.md.

```mermaid
flowchart TD
    W(["Wait for free slot"]) --> R["XREADGROUP, and periodically XAUTOCLAIM of messages idle over 60s"]
    R --> C{"Conditional claim: UPDATE to RUNNING WHERE status = QUEUED. Rows updated?"}
    C -- "0 rows" --> X1["XACK and skip"]
    X1 --> W
    C -- "1 row" --> X2["XACK. Lease is now 30s, attempt incremented"]
    X2 --> D["Download input to /scratch/task_id"]
    D --> P["Re-run ffprobe"]
    P --> B["Build ffmpeg args from typed struct"]
    B --> F

    subgraph F["Run ffmpeg"]
        direction LR
        F1["ffmpeg in own process group with progress parsing"]
        F2["Heartbeat every 10s: extend lease, write progress, check cancel_requested"]
    end

    F --> O{"Outcome"}
    O -- success --> S1["Upload output to outputs/user_id/task_id.ext"]
    S1 --> S2["Task SUCCESS and set output_expires_at"]
    S2 --> S3["Recompute job status and publish events"]
    S3 --> S4["Delete input"]
    O -- "cancel_requested seen" --> C1["Kill process group"]
    C1 --> C2["Task CANCELED and recompute job"]
    O -- "task timeout" --> T1["Task FAILED, not retryable"]
    O -- error --> E1{"Classified retryable and attempts left?"}
    E1 -- yes --> E2["Task RETRYING with next_attempt_at, backoff 10s, 30s, 90s plus jitter"]
    E1 -- no --> E3["Task FAILED with error_code"]
    S4 --> A["Write task_attempts row"]
    C2 --> A
    T1 --> A
    E2 --> A
    E3 --> A
    A --> Z["Always delete scratch dir"]
    Z --> W
```

## Notes

- A crashed worker never reaches the outcome branches. The lease expires and the lease reaper moves the task to RETRYING or FAILED and writes a task_attempts row with outcome lease_expired.
- Progress is published to redis at most once per second and written to postgres only on the heartbeat. Status changes are written to postgres first, then published.
- The input object is deleted once the task is terminal. A RETRYING task keeps its input, since the retry needs it.
- Task timeout is max of 10 min and 3 times the input duration.
- Graceful shutdown on SIGTERM stops reading and kills ffmpeg, then returns the task to QUEUED without counting the attempt. It is a separate path from the per-task loop, so it is drawn in 12-worker-graceful-shutdown.md instead of here.
- The ffmpeg and heartbeat subgraph runs concurrently. The heartbeat can also stop the run when it finds cancel_requested.

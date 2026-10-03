# Task Processing (Success Path)

A worker with a free slot reads a task id from the stream, claims it with a conditional update in Postgres, runs ffmpeg while streaming progress and heartbeating, then uploads the output and finalizes everything in one transaction. Note the two concurrent activities during ffmpeg: throttled progress publishing to Redis and the 10s heartbeat that writes to Postgres. Reflects the Queue, Storage, Progress and Statuses sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    participant Worker as Go worker
    participant RStream as Redis stream
    participant PG as Postgres
    participant MinIO
    participant FFmpeg as ffmpeg/ffprobe
    participant RPubSub as Redis pub/sub

    Worker->>RStream: XREADGROUP group workers (free slot)
    RStream-->>Worker: task_id
    Worker->>PG: UPDATE tasks SET RUNNING, worker_id, lease_expires_at = now()+30s, attempt = attempt+1 WHERE id AND status = QUEUED
    alt 0 rows updated
        Note over Worker,PG: Someone else has it or it was canceled
        Worker->>RStream: XACK
        Note over Worker: Skip this message
    else Claimed
        Worker->>RStream: XACK
        Worker->>PG: INSERT task_attempts row
        Worker->>MinIO: GET input object
        MinIO-->>Worker: video bytes
        Note over Worker: Saved to /scratch/{task_id}/input
        Worker->>FFmpeg: ffprobe re-check of local input
        FFmpeg-->>Worker: metadata (duration)
        Worker->>FFmpeg: Start ffmpeg -progress pipe:1 -nostats
        par Progress
            loop Each out_time_us line
                FFmpeg-->>Worker: progress line
                Worker->>Worker: progress = out_time / duration
                opt At most once per second
                    Worker->>RPubSub: PUBLISH task.progress to user:{user_id}:events
                end
            end
        and Heartbeat
            loop Every 10s
                Worker->>PG: Extend lease_expires_at and write progress
                Worker->>PG: Read cancel_requested
                PG-->>Worker: false
            end
        end
        FFmpeg-->>Worker: exit 0
        Worker->>MinIO: PUT outputs/{user_id}/{task_id}.{ext}
        MinIO-->>Worker: ok
        rect rgb(235, 245, 255)
            Note over Worker,PG: Single transaction
            Worker->>PG: UPDATE task to SUCCESS, output_key, output_expires_at = now()+24h
            Worker->>PG: Finish task_attempts row (outcome success)
            Worker->>PG: SELECT job row FOR UPDATE
            Worker->>PG: Recompute job status
        end
        Worker->>RPubSub: PUBLISH task.status to user:{user_id}:events
        Worker->>RPubSub: PUBLISH job.status to user:{user_id}:events
        Worker->>MinIO: DELETE input object
        Worker->>Worker: Delete /scratch/{task_id}/ (also runs on failure via defer)
    end
```

## Notes
- XACK happens right after the claim because the Postgres lease is the guarantee from then on. If the worker dies later the lease expires and the reaper handles it.
- ffmpeg runs in its own process group with a timeout of max(10 min, 3x input duration).
- Status changes are always written to Postgres first and published second.
- If the heartbeat sees cancel_requested = true, the worker kills ffmpeg and the task goes to CANCELED. That branch is not drawn here, this diagram is the success path only.
- Input is deleted only once the task is terminal because retries need it.

# Job Creation and Upload

The user submits a job, the api validates and writes the job and its tasks as PENDING_UPLOAD in one transaction, and returns presigned PUT urls. The browser then uploads each video straight to MinIO (never through the api) and confirms each one, which triggers server side validation and the move to QUEUED. Reflects the Job Creation, Storage, Input Validation, Rate Limiting and Progress sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    actor User
    participant Browser as Next.js frontend
    participant API as Go api
    participant RKV as Redis sessions/limits
    participant PG as Postgres
    participant MinIO
    participant FFmpeg as ffmpeg/ffprobe
    participant RPubSub as Redis pub/sub

    User->>Browser: Fill form and submit
    Browser->>API: POST /jobs (name, params per video, file name + size, idempotency key)
    API->>RKV: Rate limit check (token bucket lua)
    alt Rate limited
        API-->>Browser: 429 with Retry-After
    else Allowed
        API->>API: Validate params against allowlist
        API->>PG: Look up job by user_id + idempotency_key
        alt Job already exists for this key
            PG-->>API: existing job
            API-->>Browser: Existing job (no new job created)
        else New key
            rect rgb(235, 245, 255)
                Note over API,PG: Single transaction
                API->>PG: INSERT job and tasks (PENDING_UPLOAD)
            end
            PG-->>API: committed
            API->>MinIO: Presign PUT url per task (15 min expiry)
            API-->>Browser: 201 job, tasks, presigned upload urls
        end
    end

    loop For each video
        Browser->>MinIO: PUT file to presigned url
        MinIO-->>Browser: Upload progress then 200
        Browser-->>User: Show upload progress
        Browser->>API: POST /tasks/{id}/uploaded
        API->>MinIO: StatObject (real size, must be 2GB or less)
        MinIO-->>API: size
        API->>MinIO: Presign GET url
        API->>FFmpeg: ffprobe against presigned GET (10s timeout)
        FFmpeg-->>API: stream and format metadata
        alt Valid input
            rect rgb(235, 245, 255)
                Note over API,PG: Single transaction
                API->>PG: UPDATE task to QUEUED if PENDING_UPLOAD, set queued_at, input_metadata
                API->>PG: Recompute job status (job row locked)
                API->>PG: INSERT outbox row (task.status event)
            end
            API-->>Browser: 200 task QUEUED
        else Invalid or probe failed
            API->>PG: UPDATE task to FAILED with error_code, recompute job status
            API-->>Browser: 4xx with error_code
        end
        API->>RPubSub: PUBLISH task.status to user:{user_id}:events
    end
```

## Notes
- Validation checks: size at most 2GB, ffprobe succeeds, at least one video stream, format in mp4/mov/mkv/webm/avi, duration at most 30 min, resolution at most 4K, fps at most 60.
- Rate limits applied here include 5 jobs/min per user, 10 videos per job and 50 queued tasks per user. All are checked before the transaction.
- The notes list the outbox row only in the QUEUED branch of validation. The task.status publish to the user channel is shown for both branches.
- The dispatcher later pushes the QUEUED task to the stream, see diagram 03.

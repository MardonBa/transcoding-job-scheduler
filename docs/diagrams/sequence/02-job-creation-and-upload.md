# Job Creation and Upload

The user submits a job. The api checks the idempotency key, validates, writes the job and its tasks as PENDING_UPLOAD in one transaction, and returns one presigned POST form per task with a 30 min upload window. The browser then uploads each video straight to MinIO through nginx (never through the api) and confirms each one. Confirming triggers server side validation and the move to QUEUED, and the response always reports the task's resulting status. Reflects the Job Creation, Storage, Input Validation and Rate Limiting sections of IMPLEMENTATION_NOTES.md and docs/API.md.

```mermaid
sequenceDiagram
    actor User
    participant Browser as Next.js frontend
    participant API as Go api
    participant RKV as Redis sessions/limits
    participant PG as Postgres
    participant MinIO
    participant FFmpeg as ffprobe
    participant RPubSub as Redis pub/sub

    User->>Browser: Fill form and submit
    Browser->>API: POST /api/jobs, header Idempotency-Key, body name + per video filename, size_bytes, params
    API->>RKV: Rate limit check, general and job creation buckets (token bucket lua)
    alt Rate limited
        API-->>Browser: 429 rate_limited with Retry-After
    else Allowed
        API->>PG: Look up job by user_id + idempotency_key
        alt Key exists, same request hash
            PG-->>API: existing job and tasks
            API->>API: Re-sign upload forms with the original upload_expires_at
            API-->>Browser: 200 original job and tasks (replay)
        else Key exists, different request hash
            API-->>Browser: 422 idempotency_key_reused
        else New key
            API->>API: Validate params and limits (400 validation_failed)
            API->>PG: Count unfinished tasks of user
            alt Unfinished + new over 50
                API-->>Browser: 429 quota_exceeded
            else Within quota
                rect rgb(235, 245, 255)
                    Note over API,PG: Single transaction
                    API->>PG: INSERT job (idempotency key + request hash)
                    API->>PG: INSERT tasks (PENDING_UPLOAD, position, upload_expires_at = now + 30 min)
                end
                API->>API: Sign presigned POST per task: exact key, content-length-range 1..size_bytes, expiration upload_expires_at
                API-->>Browser: 201 job summary + tasks with upload forms
            end
        end
    end

    loop For each video
        Browser->>MinIO: POST multipart form to /uploads (fields, then file)
        alt Larger than declared or window passed
            MinIO-->>Browser: 403 policy error
        else Accepted
            MinIO-->>Browser: Upload progress, then 204
        end
        Browser-->>User: Show upload progress
        Browser->>API: POST /api/tasks/{id}/uploaded
        alt Task no longer PENDING_UPLOAD (already confirmed, canceled, failed)
            API-->>Browser: 200 current task, nothing changes
        else Object missing
            API->>MinIO: StatObject
            MinIO-->>API: not found
            API-->>Browser: 409 upload_not_found, task stays PENDING_UPLOAD
        else Object present
            API->>MinIO: StatObject (real size, at most declared and 500 MB)
            API->>FFmpeg: ffprobe via internal presigned GET (10s timeout)
            FFmpeg-->>API: stream and format metadata
            alt Valid input
                rect rgb(235, 245, 255)
                    Note over API,PG: Single transaction
                    API->>PG: UPDATE task to QUEUED WHERE status = PENDING_UPLOAD, set queued_at, input_metadata, notices, effective params
                    API->>PG: SELECT job FOR UPDATE, recompute job status
                end
                API-->>Browser: 200 task QUEUED
            else Invalid or probe failed
                API->>PG: UPDATE task to FAILED with error_code, recompute job status
                API->>MinIO: Best effort delete of input
                API-->>Browser: 200 task FAILED with error
            end
            API->>RPubSub: PUBLISH task.status and job.status to user:{user_id}:events
        end
    end
```

## Notes
- Validation checks: size at most the declared size and 500 MB, ffprobe succeeds, at least one video stream, format in mp4/mov/mkv/webm/avi, duration at most 30 min, resolution at most 4K, fps at most 60.
- No outbox row is written here. The outbox only feeds the Redis stream, and only the dispatcher writes to it (diagram 03). Status events go straight to pub/sub after commit.
- There is no route for a new upload form. Once the window passes, cleanup fails the task with upload_timeout (diagram 11).
- The browser upload goes through nginx to MinIO. The api signs it with the public MinIO endpoint, see docs/NGINX.md.

# Rate Limited Request

Shows POST /api/jobs passing through the rate limit middleware. A Redis Lua token bucket keyed by user makes the check and decrement atomic across API instances. Allowed requests also face the handler-level limits (max 50 unfinished tasks per user, max 10 videos per job). Token bucket rejections return 429 rate_limited with Retry-After and the frontend shows when the user can try again. Reflects the Rate Limiting and UI sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    participant Browser as Next.js frontend
    participant API as Go api
    participant RStream as Redis
    participant PG as Postgres

    Browser->>API: POST /api/jobs
    API->>RStream: EVAL token bucket lua script (key per user)
    RStream-->>API: allowed or retry_after
    alt allowed
        API->>PG: count unfinished tasks for user (PENDING_UPLOAD, QUEUED, RUNNING, RETRYING)
        API->>API: check videos per job at most 10
        alt more than 10 videos
            API-->>Browser: 400 validation_failed (tasks, too_many)
        else unfinished + new over 50
            API-->>Browser: 429 quota_exceeded (no Retry-After, frees up as tasks finish)
        else within limits
            API->>PG: create job and tasks (PENDING_UPLOAD) in one transaction
            API-->>Browser: 201 with presigned upload forms
        end
    else bucket empty
        API-->>Browser: 429 rate_limited, Retry-After header and details.retry_after_s
    end
    Browser->>Browser: on 429 show message, with retry time when Retry-After is present
```

## Notes
- Job creation uses a 5 jobs per minute per user bucket on top of the general 60 requests per minute per user bucket. Limits are configurable via env.
- Each rejection increments rate_limit_rejections_total by limit.

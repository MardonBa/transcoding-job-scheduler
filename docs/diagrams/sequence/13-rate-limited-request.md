# Rate Limited Request

Shows POST /jobs passing through the rate limit middleware. A Redis Lua token bucket keyed by user makes the check and decrement atomic across API instances. Allowed requests also face the handler-level limits (max 50 queued tasks per user, max 10 videos per job). Rejections return 429 with Retry-After and the frontend shows when the user can try again. Reflects the Rate Limiting and UI sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    participant Browser as Next.js frontend
    participant API as Go api
    participant RStream as Redis
    participant PG as Postgres

    Browser->>API: POST /jobs
    API->>RStream: EVAL token bucket lua script (key per user)
    RStream-->>API: allowed or retry_after
    alt allowed
        API->>PG: count queued tasks for user (tasks user_id, status)
        API->>API: check videos per job at most 10
        alt queued tasks at most 50 and videos at most 10
            API->>PG: create job and tasks (PENDING_UPLOAD) in one transaction
            API-->>Browser: 201 with presigned upload urls
        else over a limit
            API-->>Browser: 429
        end
    else bucket empty
        API-->>Browser: 429 with Retry-After header
    end
    Browser->>Browser: on 429 show message with retry time from Retry-After
```

## Notes
- Job creation uses a 5 jobs per minute per user bucket on top of the general 60 requests per minute per user bucket. Limits are configurable via env.
- Each rejection increments rate_limit_rejections_total by limit.

# Progress Updates over SSE

The browser opens one EventSource to `GET /events`. Each api instance holds a single Redis `PSUBSCRIBE user:*:events` and fans messages out in memory to that user's connections only. Redis pub/sub is fire and forget, so Postgres stays the source of truth and the browser refetches `GET /jobs` on reconnect and for queue positions. Reflects the Progress, UI and Queue sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    participant Browser as Next.js frontend
    participant API as Go api
    participant RKV as Redis sessions/limits
    participant RPubSub as Redis pub/sub
    participant Worker as Go worker
    participant PG as Postgres

    Note over API,RPubSub: At api instance startup
    API->>RPubSub: PSUBSCRIBE user:*:events

    Browser->>API: GET /events (session cookie)
    API->>RKV: Validate session
    RKV-->>API: user_id
    API->>RKV: Check SSE connection limit (5 per user)
    alt Over limit
        API-->>Browser: 429
    else Allowed
        API->>API: Register connection in in-memory hub under user_id
        API-->>Browser: 200 text/event-stream
        Browser->>API: GET /jobs (initial or post-reconnect refetch)
        API->>PG: Query jobs, tasks, queue positions (scoped by user_id)
        PG-->>API: current state
        API-->>Browser: jobs
    end

    par Event delivery
        loop Task running
            Worker->>RPubSub: PUBLISH user:{user_id}:events (task.progress, task.status, job.status)
            RPubSub-->>API: pmessage for user:{user_id}:events
            API->>API: Hub looks up that user's connections
            API-->>Browser: SSE event only on that user's connections
            Browser->>Browser: Update UI
            opt Event is task.status
                Browser->>API: GET /jobs (refresh queue positions)
                API-->>Browser: jobs with queue positions
            end
        end
    and Keepalive
        loop Every 15s
            API-->>Browser: SSE comment line
        end
    and Queue position poll
        loop Every approx 10s
            Browser->>API: GET /jobs
            API->>PG: Count QUEUED tasks with earlier queued_at
            PG-->>API: positions
            API-->>Browser: jobs with approximate queue positions
        end
    end

    Note over Browser,API: Connection drops (network, deploy, proxy)
    Browser-xAPI: connection lost
    API->>API: Remove connection from hub
    Browser->>API: EventSource auto reconnects GET /events
    Browser->>API: GET /jobs to catch missed events
    API-->>Browser: current state from Postgres
```

## Notes
- Queue position is computed when `GET /jobs` runs and is never pushed over SSE. It is approximate because per-user fairness lets other tasks skip ahead.
- Events carried over SSE are task.status, task.progress and job.status. Progress is throttled to at most 1 per second per task by the worker.
- Workers never talk to the api directly. They only write to Postgres and publish to Redis.
- Losing a pub/sub message is acceptable since the reconnect refetch and the periodic poll restore the truth from Postgres.

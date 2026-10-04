# Progress Updates over SSE

The browser opens one EventSource to `GET /api/events`. Each api instance holds a single Redis `PSUBSCRIBE user:*:events` and fans messages out in memory to that user's connections only. Redis pub/sub is fire and forget, so Postgres stays the source of truth: the browser refetches whenever it receives a `ready` event, which happens on every connect and reconnect, and polls for queue positions. Payloads are defined in docs/SSE.md. Reflects the Progress, UI and Queue sections of IMPLEMENTATION_NOTES.md.

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

    Browser->>API: GET /api/events (sid cookie)
    API->>RKV: Validate session
    alt No session
        API-->>Browser: 401 (EventSource closes, frontend checks /api/me)
    else Valid
        API->>RKV: INCR sse_conns:{user_id}
        alt Over 5
            API->>RKV: DECR sse_conns:{user_id}
            API-->>Browser: 429 rate_limited (EventSource closes, frontend backs off)
        else Allowed
            API->>API: Register connection in hub under user_id
            API-->>Browser: 200 text/event-stream, retry 3000, event ready
            Browser->>API: GET /api/jobs?scope=open (or GET /api/jobs/{id})
            API->>PG: Jobs, tasks, queue positions (scoped by user_id)
            API-->>Browser: current state
        end
    end

    par Task progress
        loop At most once per second per task
            Worker->>RPubSub: PUBLISH task.progress
            RPubSub-->>API: pmessage
            API-->>Browser: event task.progress (only on that user's connections)
        end
    and Job progress
        loop Every heartbeat (10s)
            Worker->>PG: Extend lease, write task progress
            Worker->>PG: Recompute job progress from all tasks in the job
            Worker->>RPubSub: PUBLISH job.progress
            RPubSub-->>API: pmessage
            API-->>Browser: event job.progress
            Browser->>Browser: Tween job bar to the new value over 10s
        end
    and Status changes
        Worker->>RPubSub: PUBLISH task.status then job.status (after commit)
        RPubSub-->>API: pmessage
        API-->>Browser: events task.status, job.status
        Browser->>API: GET /api/jobs?scope=open (debounced 1s, refresh queue positions)
    and Keepalive
        loop Every 15s
            API->>RKV: Session still exists? Refresh sse_conns TTL
            API-->>Browser: comment line ": ping"
        end
    and Queue position poll
        loop Every 10s while a job is QUEUED
            Browser->>API: GET /api/jobs?scope=open
            API-->>Browser: jobs with queue_ahead
        end
    end

    Note over Browser,API: Connection drops (network, deploy, proxy)
    Browser-xAPI: connection lost
    API->>API: Remove connection from hub
    API->>RKV: DECR sse_conns:{user_id}
    Browser->>API: EventSource auto reconnects after 3s
    API-->>Browser: event ready
    Browser->>API: Refetch to catch missed events
```

## Notes
- Queue position is computed when `GET /api/jobs` runs and is never pushed over SSE. It is approximate because per-user fairness lets other tasks skip ahead.
- Events: ready, task.status, task.progress, job.status, job.progress. Every task and job event carries job_id.
- The client drops events older than the latest `ts` it has for a task or job, and drops progress events from older attempts.
- Workers never talk to the api directly. They only write to Postgres and publish to Redis.
- If the session disappears (logout or expiry), the next keepalive closes the stream, and the reconnect gets a 401.

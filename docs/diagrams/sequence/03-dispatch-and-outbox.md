# Dispatch and Outbox Relay

Two independent loops in the single scheduler instance move QUEUED tasks onto the Redis stream. The dispatcher decides who goes next (round robin across users, at most 2 in flight per user) and records that decision plus an outbox row in one transaction. The outbox relay then publishes outbox rows to the stream, which avoids the dual write problem. Reflects the "Scheduler loops" and "Queue" sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    participant Sched as Go scheduler
    participant PG as Postgres
    participant RStream as Redis stream

    par Dispatcher loop
        loop Every 1s
            Sched->>PG: SELECT QUEUED tasks with dispatched_at null
            PG-->>Sched: candidate tasks
            Sched->>Sched: Round robin across users
            Sched->>Sched: Skip users with 2 or more tasks in flight (dispatched or running)
            opt At least one task selected
                rect rgb(235, 245, 255)
                    Note over Sched,PG: Single transaction
                    Sched->>PG: UPDATE tasks SET dispatched_at = now()
                    Sched->>PG: INSERT outbox row (topic tasks, payload task_id)
                end
            end
        end
    and Outbox relay loop
        loop Every 500ms
            Sched->>PG: SELECT outbox rows WHERE published_at IS NULL ORDER BY id
            PG-->>Sched: unpublished rows
            loop Each row
                Sched->>RStream: XADD tasks task_id
                RStream-->>Sched: message id
                Note over Sched,RStream: Crash here means published_at is not set yet, the row is sent again next run. The duplicate message is harmless because the worker claim is conditional on status = QUEUED
                Sched->>PG: UPDATE outbox SET published_at = now()
            end
        end
    end
```

## Notes
- The stream message carries only the task_id. The worker loads everything else from Postgres.
- Writing the state change and the outbox row in one transaction means a task can never be marked dispatched without a message eventually reaching the stream.
- If Redis is wiped, the queue can be rebuilt from Postgres (QUEUED tasks and the outbox).
- The retry scheduler clears dispatched_at on retried tasks so this dispatcher picks them up again.

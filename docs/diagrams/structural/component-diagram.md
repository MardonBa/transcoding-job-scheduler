# Component Diagram

This diagram shows the logical components and the data that flows between them. Notice that the browser uploads and downloads video bytes directly to and from MinIO using presigned URLs, and that workers never call the api. Workers write to Postgres and publish to Redis, and the api relays those events to the browser over SSE. It reflects the "Backend", "Queue", "Storage", "Auth", "Rate Limiting" and "Tech Stack" sections of IMPLEMENTATION_NOTES.md.

```mermaid
flowchart LR
    Browser["Browser - Next.js frontend"]
    Google["Google OIDC"]
    Nginx["nginx reverse proxy - one origin"]

    subgraph API["Go api"]
        direction TB
        Auth["Auth and sessions"]
        RL["Rate limit middleware"]
        Handlers["Job and task handlers"]
        Valid["Input validation"]
        SSE["SSE hub"]
        DL["Download redirect"]
    end

    subgraph SCH["Go scheduler - single instance"]
        direction TB
        Relay["Outbox relay"]
        Disp["Dispatcher"]
        Reaper["Lease reaper"]
        Retry["Retry scheduler"]
        Clean["Cleanup"]
    end

    subgraph WRK["Go workers - scaled xN"]
        direction TB
        Slots["Slot pool"]
        FF["ffmpeg and ffprobe runner"]
        HB["Heartbeat"]
    end

    PG[("Postgres - source of truth")]

    subgraph RDS["Redis"]
        direction TB
        Stream["Stream tasks - group workers"]
        PubSub["Pub/sub user:id:events"]
        Sess["Sessions"]
        Buckets["Rate limit buckets"]
    end

    subgraph MIN["MinIO"]
        direction TB
        Up[["uploads bucket"]]
        Out[["outputs bucket"]]
    end

    Obs["Prometheus and Grafana"]

    Browser -->|"OIDC login"| Google
    Browser ==>|"all HTTP on localhost"| Nginx
    Nginx -->|"/api REST and cookie"| RL
    RL --> Auth
    RL --> Handlers
    Handlers --> Valid
    Auth -->|"verify id_token"| Google
    Auth -->|"session create and get"| Sess
    RL -->|"token bucket lua"| Buckets
    Handlers -->|"jobs tasks outbox tx"| PG
    Handlers -->|"presign POST and GET, Stat"| MIN
    Valid -->|"ffprobe via presigned GET"| Up
    Nginx ==>|"/uploads presigned POST"| Up
    Nginx -.->|"/api/tasks/id/download, 302"| DL
    Nginx ==>|"/outputs presigned GET"| Out
    SSE ==>|"/api/events via nginx"| Browser
    PubSub -->|"PSUBSCRIBE user:star:events"| SSE

    Relay -->|"read unpublished outbox"| PG
    Relay -->|"XADD"| Stream
    Disp -->|"dispatched_at and outbox row tx"| PG
    Reaper -->|"expired leases to RETRYING"| PG
    Retry -->|"RETRYING to QUEUED"| PG
    Clean -->|"expire and delete"| PG
    Clean -->|"delete objects"| MIN

    Stream -->|"XREADGROUP and XAUTOCLAIM"| Slots
    Slots -->|"conditional claim"| PG
    Slots --> FF
    FF -->|"download input"| Up
    FF -->|"upload output"| Out
    FF --> HB
    HB -->|"lease progress cancel check"| PG
    Slots -->|"PUBLISH status and progress"| PubSub
    Handlers -->|"PUBLISH status after commit"| PubSub
    SCH -->|"PUBLISH status after commit"| PubSub

    API -.->|"metrics scrape"| Obs
    SCH -.->|"metrics scrape"| Obs
    WRK -.->|"metrics scrape"| Obs
```

## Notes

- Thick arrows are the bulk-data and live-event paths: uploads and downloads go through nginx straight to MinIO without touching the api, and SSE goes from the api to the browser through nginx.
- nginx serves the frontend, the api and the two MinIO buckets on one origin. See docs/NGINX.md.
- The outbox carries only stream dispatch messages. Status events from the api, the scheduler and the workers go straight to pub/sub.
- The api only issues presigned URLs and a 302 redirect; video bytes never pass through the Go api.
- There is no edge from workers to the api by design.
- Redis can be rebuilt from Postgres; the dispatcher and outbox relay re-enqueue QUEUED tasks.
- The download edge is drawn as redirect then direct fetch from the outputs bucket after ownership check.

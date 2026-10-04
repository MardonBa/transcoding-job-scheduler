# Class Diagrams

Two diagrams are shown. The first is the Go domain model: entities mirroring the tables, the status and error enums, and the TranscodeParams value object with its ffmpeg and progress helpers. The second is the service layer: repository and infrastructure interfaces, the worker, the scheduler loops, and the API SSE hub. These reflect the "Database Schema", "Statuses", "Queue", "Scheduler loops", "Input Validation" and "Progress" sections of IMPLEMENTATION_NOTES.md.

## Domain model

```mermaid
classDiagram
    class User {
        +uuid ID
        +string GoogleSub
        +string Email
        +string Name
        +string AvatarURL
        +time CreatedAt
        +time UpdatedAt
    }

    class Job {
        +uuid ID
        +uuid UserID
        +string Name
        +JobStatus Status
        +int TaskCount
        +string IdempotencyKey
        +string IdempotencyRequestHash
        +time CreatedAt
        +time UpdatedAt
        +time FinishedAt
    }

    class Task {
        +uuid ID
        +uuid JobID
        +uuid UserID
        +int Position
        +TaskStatus Status
        +string InputKey
        +string InputFilename
        +int64 InputSizeBytes
        +json InputMetadata
        +TranscodeParams Params
        +Notice[] Notices
        +string OutputKey
        +int64 OutputSizeBytes
        +float32 Progress
        +int Attempt
        +int MaxAttempts
        +ErrorCode ErrorCode
        +string ErrorMessage
        +string WorkerID
        +time LeaseExpiresAt
        +time NextAttemptAt
        +bool CancelRequested
        +time DispatchedAt
        +time UploadExpiresAt
        +time InputDeletedAt
        +time CreatedAt
        +time QueuedAt
        +time StartedAt
        +time FinishedAt
        +time OutputExpiresAt
        +CanTransition(to TaskStatus) bool
    }

    class TaskAttempt {
        +int64 ID
        +uuid TaskID
        +int Attempt
        +string WorkerID
        +time StartedAt
        +time FinishedAt
        +string Outcome
        +string ErrorMessage
        +string FFmpegStderrTail
    }

    class OutboxMessage {
        +int64 ID
        +string Topic
        +json Payload
        +time CreatedAt
        +time PublishedAt
    }

    class JobStatus {
        <<enumeration>>
        PENDING_UPLOAD
        QUEUED
        RUNNING
        SUCCESS
        PARTIAL_SUCCESS
        FAILED
        CANCELED
        EXPIRED
    }

    class TaskStatus {
        <<enumeration>>
        PENDING_UPLOAD
        QUEUED
        RUNNING
        RETRYING
        SUCCESS
        FAILED
        CANCELED
        EXPIRED
    }

    class ErrorCode {
        <<enumeration>>
        upload_too_large
        unsupported_format
        no_video_stream
        duration_too_long
        resolution_too_high
        fps_too_high
        invalid_input
        unsupported_codec
        decode_error
        timeout
        lease_expired
        oom_or_signal
        storage_error
        canceled
        upload_timeout
        +Retryable() bool
    }

    class TranscodeParams {
        <<value object>>
        +string Container
        +string VideoCodec
        +string Resolution
        +Quality Quality
        +string FPS
        +string Audio
        +Validate() error
    }

    class Quality {
        <<value object>>
        +string Mode
        +int CRF
        +int BitrateKbps
    }

    class Notice {
        <<value object>>
        +string Code
        +string Message
    }

    class FFmpegCommandBuilder {
        +Build(params TranscodeParams, inPath string, outPath string) string[]
    }

    class ProgressParser {
        +Parse(line string) float32
        +DurationUs int64
    }

    User "1" --> "*" Job : owns
    User "1" --> "*" Task : owns
    Job "1" --> "*" Task : contains
    Task "1" --> "*" TaskAttempt : history
    Job --> JobStatus
    Task --> TaskStatus
    Task --> ErrorCode
    Task *-- TranscodeParams : params
    Task *-- Notice : notices
    TranscodeParams *-- Quality
    FFmpegCommandBuilder ..> TranscodeParams : reads
    ProgressParser ..> Task : feeds progress
```

## Services and infrastructure

```mermaid
classDiagram
    class JobRepository {
        <<interface>>
        +Create(job, tasks) error
        +Get(userID, jobID) Job
        +GetByIdempotencyKey(userID, key) Job
        +ListOpen(userID) Job[]
        +ListHistory(userID, cursor, limit) Job[]
        +RecomputeStatus(jobID) JobStatus
        +Progress(jobID) float32
    }

    class TaskRepository {
        <<interface>>
        +Get(userID, taskID) Task
        +Transition(id, from, to) bool
        +Claim(id, workerID, lease) bool
        +ExtendLease(id, lease, progress) error
        +ListExpiredLeases() Task[]
        +ListRetryDue() Task[]
        +ListUndispatched() Task[]
        +ListOutputsExpired() Task[]
        +ListUploadsTimedOut() Task[]
        +ListInputsToDelete() Task[]
        +RequestCancel(userID, taskIDs) int
        +CountUnfinished(userID) int
        +QueuePosition(id) int
        +AddAttempt(attempt) error
    }

    class OutboxRepository {
        <<interface>>
        +Insert(tx, topic, payload) error
        +ListUnpublished(limit) OutboxMessage[]
        +MarkPublished(id) error
    }

    class Queue {
        <<interface>>
        +Add(taskID) error
        +Read(consumer) string
        +Ack(id) error
        +AutoClaim(minIdle) string[]
    }

    class EventPublisher {
        <<interface>>
        +Publish(userID, eventType, payload) error
    }

    class ObjectStorage {
        <<interface>>
        +PresignPost(key, maxBytes, expiresAt) UploadForm
        +PresignGet(key, ttl, filename) string
        +Stat(key) ObjectInfo
        +Download(key, path) error
        +Upload(path, key) error
        +Delete(key) error
    }

    class RateLimiter {
        <<interface>>
        +Allow(key, limit) Decision
    }

    class SessionStore {
        <<interface>>
        +Create(userID, ttl) string
        +Get(sessionID) uuid
        +Delete(sessionID) error
    }

    class Worker {
        +string ID
        +int Slots
        +int FFmpegThreads
        +Run(ctx) error
        -runTask(taskID) error
        -heartbeat(taskID) error
        +Shutdown() void
    }

    class OutboxRelay {
        +Run(ctx) error
    }
    class Dispatcher {
        +Run(ctx) error
    }
    class LeaseReaper {
        +Run(ctx) error
    }
    class RetryScheduler {
        +Run(ctx) error
    }
    class CleanupLoop {
        +Run(ctx) error
    }

    class SSEHub {
        +Subscribe(userID) Conn
        +Unsubscribe(conn) void
        +FanOut(userID, event) void
        +Run(ctx) error
    }

    Worker ..> Queue : XREADGROUP and XAUTOCLAIM
    Worker ..> TaskRepository : claim and heartbeat
    Worker ..> ObjectStorage : download and upload
    Worker ..> EventPublisher : progress and status
    Worker ..> FFmpegCommandBuilder
    Worker ..> ProgressParser

    OutboxRelay ..> OutboxRepository
    OutboxRelay ..> Queue : XADD
    Dispatcher ..> TaskRepository
    Dispatcher ..> OutboxRepository : writes in same tx
    LeaseReaper ..> TaskRepository
    LeaseReaper ..> JobRepository
    RetryScheduler ..> TaskRepository
    CleanupLoop ..> TaskRepository
    CleanupLoop ..> ObjectStorage

    SSEHub ..> SessionStore : auth via handler
    SSEHub ..> EventPublisher : same channel
    JobRepository ..> TaskRepository : same transaction
```

## Notes

- Loop intervals: OutboxRelay ~500ms, Dispatcher 1s, LeaseReaper 15s, RetryScheduler 5s, CleanupLoop 5 min. SSEHub holds one PSUBSCRIBE user:*:events per api instance.
- Enum and interface method sets are illustrative; they follow the behaviors in the notes, not a prescribed Go API.
- ErrorCode values match docs/API.md. Retryable: lease_expired, oom_or_signal, storage_error. Everything else is not retryable.
- ObjectStorage has an internal and a public implementation. Presigned forms and URLs for the browser are signed with the public endpoint, see docs/NGINX.md.
- The Worker and API do not call each other; both talk only through Postgres and Redis.
- Dispatcher and the transition methods use conditional updates (UPDATE ... WHERE status = expected).

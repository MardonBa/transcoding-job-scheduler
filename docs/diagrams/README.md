# Diagrams

UML diagrams for the transcoding job scheduler. Each file has a short description followed by a Mermaid diagram.
Source of truth for the design is [../IMPLEMENTATION_NOTES.md](../IMPLEMENTATION_NOTES.md). If a diagram and the notes disagree, the notes win and the diagram should be fixed.

## Structural

What the system is made of.

- [ER diagram](structural/er-diagram.md) - postgres tables, columns, relationships, indexes
- [Class diagram](structural/class-diagram.md) - Go domain types, enums, and service interfaces
- [Component diagram](structural/component-diagram.md) - logical components and what flows between them
- [Deployment diagram](structural/deployment-diagram.md) - docker compose containers, networks, volumes

## State

Lifecycle of the core entities.

- [Task state machine](state/task-state-machine.md) - every allowed task transition and who triggers it
- [Job state machine](state/job-state-machine.md) - job status derived from its tasks

## Activity

Decision logic inside a single component.

- [Job status derivation](activity/job-status-derivation.md)
- [Input validation](activity/input-validation.md)
- [Worker task lifecycle](activity/worker-task-lifecycle.md)
- [Rate limiting](activity/rate-limiting.md)

## Sequence

Interactions across components, in roughly the order a job experiences them.

Happy path
- [01 Login](sequence/01-login.md)
- [02 Job creation and upload](sequence/02-job-creation-and-upload.md)
- [03 Dispatch and outbox](sequence/03-dispatch-and-outbox.md)
- [04 Task processing (success)](sequence/04-task-processing-success.md)
- [05 Progress over SSE](sequence/05-progress-sse.md)

Failure and edge paths
- [06 Task failure and retry](sequence/06-task-failure-and-retry.md)
- [07 Worker crash recovery](sequence/07-worker-crash-recovery.md)
- [08 Cancel job](sequence/08-cancel-job.md)
- [09 Task timeout](sequence/09-task-timeout.md)
- [10 Download](sequence/10-download.md)
- [11 Cleanup](sequence/11-cleanup.md)
- [12 Worker graceful shutdown](sequence/12-worker-graceful-shutdown.md)
- [13 Rate limited request](sequence/13-rate-limited-request.md)

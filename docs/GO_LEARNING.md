# Learning Go for This Backend

A reading list for building the api, worker and scheduler, in the order Phase 1 of [IMPLEMENTATION_PLAN.md](../IMPLEMENTATION_PLAN.md) needs them. Each section says what to learn, why this project needs it, and where to read. Links were checked on 2026-10-04. Latest Go at that time: 1.27.1.

Legend: **core** = read before writing that part, *deeper* = read when you get stuck or want more.

---

## 0. Learning path

You don't need all of this before writing code. A reasonable order:

1. **Week 1, the language.** Tour of Go, then Go by Example as a reference. Write a tiny CLI.
2. **Project skeleton.** Module layout, config from env, slog, one `http.Server` with `/healthz`, graceful shutdown. Run it against compose.
3. **Postgres.** pgx + migrations + (optionally) sqlc. Create a job in a transaction.
4. **Redis + MinIO clients.** Presigned POST, XADD / XREADGROUP by hand in a scratch program first.
5. **Worker.** Goroutines, channels, context, `os/exec`. This is where Go gets interesting.
6. **Auth, SSE, rate limiting.** Mostly `net/http` and middleware once the basics are in place.

For a single book that covers most of steps 2–3 and 6, see *Let's Go Further* (section 1).

---

## 1. The language

| | Resource | Why |
|---|---|---|
| **core** | [A Tour of Go](https://go.dev/tour/) | Official interactive intro. Do all of it, including concurrency. |
| **core** | [Go by Example](https://gobyexample.com) | Short runnable examples. Keep it open while coding (tickers, worker pools, signals, exec, JSON). |
| **core** | [Effective Go](https://go.dev/doc/effective_go) | How idiomatic Go is written. Read after the tour. |
| **core** | [Tutorial: Create a Go module](https://go.dev/doc/tutorial/create-module) | `go mod init`, packages, imports. |
| *deeper* | [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments) | Common style mistakes, the ones a reviewer would point out. |
| *deeper* | [Learn Go with Tests](https://quii.gitbook.io/learn-go-with-tests) | Teaches the language through TDD. Good for Phase 7 too. |
| *deeper* | [go.dev/learn](https://go.dev/learn/) | Official index of more material. |

**Books (paid, highly relevant):**
- [Let's Go](https://lets-go.alexedwards.net) by Alex Edwards: a web app with only the stdlib. Covers routing, middleware, sessions, DB access.
- [Let's Go Further](https://lets-go-further.alexedwards.net): a JSON API. It covers config, structured errors, migrations, **rate limiting**, **graceful shutdown**, metrics, and auth. Of anything here, this book matches the `api` binary most closely.

**Things that trip up people coming from TS/Python:**
- Errors are values: `if err != nil { return fmt.Errorf("claim task: %w", err) }`. Read [Error handling and Go](https://go.dev/blog/error-handling-and-go) and [Working with errors in 1.13](https://go.dev/blog/go1.13-errors) (`%w`, `errors.Is`, `errors.As`). You'll use `errors.Is(err, pgx.ErrNoRows)` a lot.
- Interfaces are satisfied implicitly. Define small interfaces where you *use* them, not where you implement them.
- Zero values matter (`nil` slice vs empty slice changes JSON output: `null` vs `[]`, relevant for `notices`).
- Pointers for optional DB columns (`*time.Time` for `finished_at`), or pgx's `pgtype` types.

---

## 2. Project layout, config, logging

Plan items: Go module layout, config via env vars, slog from day one.

| | Resource | Why |
|---|---|---|
| **core** | [Organizing a Go module](https://go.dev/doc/modules/layout) | Official guidance. Covers exactly your shape: several commands under `cmd/`, shared code in `internal/`. |
| **core** | [How I write HTTP services in Go after 13 years](https://grafana.com/blog/2024/02/09/how-i-write-http-services-in-go-after-13-years/) (Mat Ryer) | A `run(ctx, args, getenv, stdout) error` main, `NewServer` taking dependencies, handlers that return `http.Handler`. A strong template for all three binaries. |
| **core** | [Structured logging with slog](https://go.dev/blog/slog) | `log/slog` in the stdlib. Use `slog.NewJSONHandler` and `logger.With("task_id", id)` for the Phase 6 log fields. |
| *deeper* | [golang-standards/project-layout](https://github.com/golang-standards/project-layout) | Popular but **not** official, and heavier than you need. Read it only for ideas. The official doc above is enough. |

Suggested shape (matches the plan). Everything Go lives in `backend/`, which is its own module:

```
backend/
  go.mod                module github.com/MardonBa/transcoding-job-scheduler/backend
  cmd/api/main.go
  cmd/worker/main.go
  cmd/scheduler/main.go
  internal/config/      env parsing, one struct per binary or a shared one
  internal/db/          pgx pool, queries, transactions
  internal/queue/       redis stream helpers
  internal/storage/     minio clients (internal + public signer)
  internal/transcode/   params struct, allowlist, ffmpeg arg builder, progress parser
  internal/jobs/        state machine, job status derivation
  internal/httpapi/     handlers, middleware, errors
  migrations/
```

Run `go` commands from `backend/` (or from the root with `go -C backend ...`).

Config: plain `os.Getenv` + `strconv` into a struct, failing fast on missing values, is fine. Go's `os.LookupEnv` tells you "unset" apart from "empty".

---

## 3. HTTP server (`api`)

Plan items: routes in API.md, JSON error envelope, request id middleware, Origin check, healthz/readyz.

| | Resource | Why |
|---|---|---|
| **core** | [Routing enhancements for Go 1.22](https://go.dev/blog/routing-enhancements) | The stdlib `http.ServeMux` now matches `"GET /api/jobs/{id}"` and gives you `r.PathValue("id")`. **You don't need chi or gin.** |
| **core** | [`net/http` package docs](https://pkg.go.dev/net/http) | `http.Server` timeouts, `Shutdown`, `ResponseController`, `CrossOriginProtection`. |
| **core** | [Go Concurrency Patterns: Context](https://go.dev/blog/context) | Every request, DB call and ffmpeg run takes a `context.Context`. Learn this early. |
| *deeper* | [Go 1.25 release notes](https://go.dev/doc/go1.25) | Adds `http.CrossOriginProtection`, a stdlib middleware that rejects cross-origin non-safe requests. It may replace your hand-written "Origin check on POST". |

Concepts to know:
- **Middleware** is just `func(http.Handler) http.Handler`. Request id, auth, rate limit and logging are all this shape. Store request-scoped values (user id, request id) in `context` with unexported key types.
- **JSON**: `encoding/json`, struct tags (`json:"task_count"`). Use `json.NewDecoder(r.Body)` with `DisallowUnknownFields()` and `http.MaxBytesReader` for request bodies.
- **Graceful shutdown**: `signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)` → `srv.Shutdown(ctx)`. Go by Example has a signals page, and Let's Go Further has a full chapter.
- **Gotcha:** a server-wide `WriteTimeout` will kill long-lived SSE connections. Set it per request with `http.NewResponseController(w).SetWriteDeadline(time.Time{})` on the SSE route.

---

## 4. Postgres

Plan items: migrations, pgx pool, job + tasks in one transaction, conditional updates, `SELECT ... FOR UPDATE`, outbox, UUIDv7, cursor pagination.

| | Resource | Why |
|---|---|---|
| **core** | [Tutorial: Accessing a relational database](https://go.dev/doc/tutorial/database-access) + [Accessing databases guide](https://go.dev/doc/database/) | The `database/sql` mental model: pools, rows, scanning, transactions. pgx works the same way. |
| **core** | [jackc/pgx](https://github.com/jackc/pgx) (v5) | The Postgres driver to use. Use `pgxpool` directly, not via `database/sql`. Look at `pgx.BeginFunc` for transactions and `CommandTag.RowsAffected()` for your conditional claims (0 rows = someone else won). |
| **core** | Migrations: [goose](https://pressly.github.io/goose/) ([repo](https://github.com/pressly/goose)) or [golang-migrate](https://github.com/golang-migrate/migrate) | Both use plain `.sql` files. My pick is **goose**: simple CLI, SQL files with up/down in one file, and it can be embedded in a Go binary later. |
| *deeper* | [sqlc docs](https://docs.sqlc.dev) | You write SQL, it generates typed Go functions. Fits your design well, since all your tricky logic (conditional UPDATEs, FOR UPDATE, partial indexes) is SQL you'd want to write by hand anyway. Optional: raw pgx is fine to start, so learn pgx first. |
| *deeper* | [Postgres `SELECT` docs, locking clause](https://www.postgresql.org/docs/current/sql-select.html) | `FOR UPDATE` (job status recompute) and `SKIP LOCKED` (handy if the dispatcher/reaper ever runs more than one instance). |
| *deeper* | [Transactional outbox pattern](https://microservices.io/patterns/data/transactional-outbox.html) | The pattern behind your outbox + relay. |
| *deeper* | [Postgres job queues & failure](https://brandur.org/postgres-queues) and [Idempotency keys](https://brandur.org/idempotency-keys) (Brandur Leach) | The second one is basically your `Idempotency-Key` + request hash design, explained in depth. |

UUIDv7: [`github.com/google/uuid`](https://pkg.go.dev/github.com/google/uuid) has `uuid.NewV7()`.

---

## 5. Redis: streams, pub/sub, sessions, rate limiting

| | Resource | Why |
|---|---|---|
| **core** | [go-redis guide](https://redis.io/docs/latest/develop/clients/go/) + [redis/go-redis](https://github.com/redis/go-redis) (v9) | Official Go client. Every command is a method: `rdb.XAdd`, `rdb.XReadGroup`, `rdb.XAck`, `rdb.XAutoClaim`, `rdb.PSubscribe`. |
| **core** | [Redis Streams intro](https://redis.io/docs/latest/develop/data-types/streams/) | Consumer groups, pending entries list, acking. Read all of it, since your queue design depends on this. |
| **core** | [XAUTOCLAIM](https://redis.io/docs/latest/commands/xautoclaim/) | Recovering messages stuck in pending (worker died between read and claim). |
| **core** | [Redis Pub/Sub](https://redis.io/docs/latest/develop/pubsub/) | Fire-and-forget delivery semantics, pattern subscriptions (`PSUBSCRIBE user:*:events`). |
| *deeper* | [Scripting with Lua](https://redis.io/docs/latest/develop/programmability/eval-intro/) | For the atomic token bucket. In go-redis use `redis.NewScript(...)`, which handles EVALSHA caching for you. |
| *deeper* | [Rate limiting glossary](https://redis.io/glossary/rate-limiting/), [go-redis/redis_rate](https://github.com/go-redis/redis_rate) | Algorithm overview. `redis_rate` is a small, readable GCRA implementation to learn from before writing your own Lua. |
| *deeper* | [How to rate limit HTTP requests](https://www.alexedwards.net/blog/how-to-rate-limit-http-requests) (Alex Edwards) | In-memory version, useful for the middleware shape. |

Tip: before wiring streams into the worker, write a 50-line throwaway program that does XGROUP CREATE → XADD → XREADGROUP → XACK, and watch it with `redis-cli XINFO GROUPS tasks` / `XPENDING`. Doing it by hand once makes the failure cases in your sequence diagrams concrete.

---

## 6. MinIO / S3

| | Resource | Why |
|---|---|---|
| **core** | [minio/minio-go](https://github.com/minio/minio-go) + [API docs on pkg.go.dev](https://pkg.go.dev/github.com/minio/minio-go/v7) | Look at `NewPostPolicy` + `PresignedPostPolicy` (uploads with key + size cap), `PresignedGetObject` with `response-content-disposition` in reqParams (downloads), `StatObject`, `FGetObject`/`FPutObject` (worker scratch), `RemoveObject`. The repo's `examples/s3/` folder has a runnable file per call. |

Why minio-go rather than the AWS SDK: presigned **POST** policies are first-class in minio-go. The AWS Go SDK v2 is built around presigned PUT/GET, which can't cap upload size, so it doesn't fit your design.

Remember the two-client setup from NGINX.md: one client for the internal endpoint (`minio:9000`) and one created with the public host, used only for signing.

---

## 7. Auth: Google OIDC

| | Resource | Why |
|---|---|---|
| **core** | [Google: OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect) | The protocol from Google's side: endpoints, `state`, `nonce`, id_token claims (`sub` is your `google_sub`). |
| **core** | [`golang.org/x/oauth2`](https://pkg.go.dev/golang.org/x/oauth2) | `AuthCodeURL`, `Exchange`, plus built-in PKCE: `GenerateVerifier()`, `S256ChallengeOption(v)`, `VerifierOption(v)`. |
| **core** | [coreos/go-oidc](https://github.com/coreos/go-oidc) (v3) | Discovers Google's keys and verifies the id_token signature, audience, expiry. You check `nonce` yourself against what you stored. The README example is almost exactly your callback handler. |

Sessions are just `crypto/rand` → 32 bytes → base64url for the cookie, `sha256` of it as the Redis key. All stdlib.

---

## 8. Concurrency: worker and scheduler

This is the most Go-specific part, and the most worth learning carefully.

| | Resource | Why |
|---|---|---|
| **core** | Tour of Go concurrency section + Go by Example pages on goroutines, channels, select, tickers, worker pools, WaitGroups, context | Building blocks for the slot pool and the scheduler loops. |
| **core** | [Go Concurrency Patterns: Pipelines and cancellation](https://go.dev/blog/pipelines) | Fan-out, closing channels, stopping goroutines cleanly. |
| **core** | [`golang.org/x/sync/errgroup`](https://pkg.go.dev/golang.org/x/sync/errgroup) | Run several loops (relay, dispatcher, reaper, retry, cleanup) and stop them all together when the context is canceled. `SetLimit(n)` is one way to build the worker slot pool. |
| **core** | [`os/exec`](https://pkg.go.dev/os/exec) | `exec.CommandContext`, `cmd.StdoutPipe()` (read `-progress pipe:1` line by line with `bufio.Scanner`), `cmd.Cancel` and `cmd.WaitDelay` to control how the process is killed. |
| **core** | [Data race detector](https://go.dev/doc/articles/race_detector) | Run tests and local binaries with `-race`. It catches a lot of beginner concurrency bugs. |
| *deeper* | [Container-aware GOMAXPROCS](https://go.dev/blog/container-aware-gomaxprocs) | Since Go 1.25 the runtime respects Docker CPU limits. Relevant to your worker container limits and `WORKER_SLOTS` math. |
| *deeper* | [Go 1.25 notes](https://go.dev/doc/go1.25): `sync.WaitGroup.Go`, `testing/synctest` | `synctest` lets you test ticker/timeout code (heartbeats, backoff) without real sleeps. |

Concepts to know for the worker:
- **Process groups.** Set `cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}` and in `cmd.Cancel`, kill `-pid` (negative pid = whole group) so ffmpeg's children die too. This is Unix-only, which is fine inside Docker.
- **One context per task**, derived from the worker's root context, with the timeout from your notes. Cancel it on SIGTERM, on cancel_requested, or on timeout. Then record *which* one happened (check `context.Cause` or a flag) so you pick the right outcome (`interrupted` vs `canceled` vs `timeout`).
- **Heartbeat goroutine** per running task: a `time.Ticker` in a `select` with `ctx.Done()`.
- **`defer os.RemoveAll(scratchDir)`** right after creating it.

---

## 9. SSE

| | Resource | Why |
|---|---|---|
| **core** | [MDN: Using server-sent events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events) | Wire format (`event:`, `data:`, `:` comments, blank-line terminator) and EventSource behavior. |
| **core** | [`net/http`](https://pkg.go.dev/net/http): `ResponseController.Flush` | Write an event → flush. Detect disconnect via `r.Context().Done()`. |

The fan-out hub is a classic Go exercise: one goroutine owns a `map[userID]map[*client]struct{}` and receives register/unregister/publish over channels (or uses a mutex). Each client gets a **buffered** channel. If it's full, drop the event or the client rather than block, since a slow browser must not stall everyone.

---

## 10. Testing and tooling

| | Resource | Why |
|---|---|---|
| **core** | `go test`, table-driven tests (Go by Example "Testing", Learn Go with Tests) | Phase 7 unit tests: params validation, arg builder, progress parser, status derivation. All pure functions, easy to start with. |
| **core** | [golangci-lint](https://golangci-lint.run) | Bundles linters. Catches unchecked errors, shadowing, etc. |
| *deeper* | [Testcontainers for Go](https://golang.testcontainers.org) | Real postgres/redis/minio in integration tests. |
| *deeper* | [Go 1.24 notes](https://go.dev/doc/go1.24): `tool` directives | `go get -tool github.com/pressly/goose/v3/cmd/goose` pins CLI tools (goose, sqlc) in `go.mod`, run with `go tool goose`. |

Editor: VS Code's Go extension (uses `gopls`), with format on save (`gofmt`/`goimports`).

---

## 11. Codebases worth reading

You're building the queue yourself, so read these for ideas, not to use as dependencies:

- [riverqueue/river](https://github.com/riverqueue/river): Postgres-backed job queue in Go. Good for how leases, retries with backoff, and job state are handled, and for idiomatic pgx usage.
- [hibiken/asynq](https://github.com/hibiken/asynq): Redis-backed task queue in Go. Covers worker pools, graceful shutdown, retry scheduling and a lease-like "deadline" mechanism.
- The *Let's Go Further* "Greenlight" app if you buy the book.

---

## 12. Suggested first milestone

A concrete target before touching auth or the queue:

1. `cd backend && go mod init github.com/MardonBa/transcoding-job-scheduler/backend`, then `cmd/api/main.go` using the Mat Ryer `run()` shape.
2. Config struct from env, JSON slog logger.
3. `GET /api/healthz` and `GET /api/readyz` (pings postgres, redis, minio).
4. Graceful shutdown on Ctrl-C.
5. First goose migration (`users` table) run against compose.
6. `GET /api/config` returning the transcode allowlist from a Go value. This is your first real route, and the frontend can use it right away.

Bring it back for review once that runs.

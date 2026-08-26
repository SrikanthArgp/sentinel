# Build Plan: 7-Day Sequence

Status: planning doc, pre-implementation. Implements the design in `docs/ARCHITECTURE.md`. Each day builds on a *runnable* system from the day before — nothing is "wire it all up at the end."

## Cross-cutting rules for the week

- **Instrument as you build, not at the end.** Each service gets OpenTelemetry SDK + structured logging the day it's created, even before the collector/backends exist (logs to stdout, traces no-op'd). Day 6 is about wiring the *pipeline*, not retrofitting instrumentation into five services at once.
- **Every day ends with something running in Docker Compose**, not just code that compiles. If a day's work isn't runnable, it isn't done.
- **Proto contracts are written before the services that implement them** — they're the interface, not an afterthought.
- **Unit tests are part of each day's work, not a separate pass.** Every day's task list ends with a "Unit tests" step for the logic written that day, and that day isn't done until those tests pass in CI-equivalent form (`pytest` locally at minimum). Testing gRPC/Kafka *plumbing* end-to-end is covered by each day's integration-style "Definition of done" check — unit tests target the pure logic underneath it (rules, scoring math, aggregate windows, validation), which is what's actually easy to get subtly wrong and hard to catch by eyeballing a demo.
- **Commit at the end of each day** with the system in a working state, so any day can be a checkpoint to roll back to.

---

## Day 1 — Foundation: infra, contracts, skeletons

**Goal**: `docker compose up` brings up every piece of infrastructure the platform needs, and four empty-but-healthy services register on it.

- Repo scaffold: `services/{ingestion,scoring,feature-store,case-management}`, `proto/`, `docker/`, `docs/`.
- `docker-compose.yml`: Kafka (KRaft mode), Redis, Postgres, OTel Collector, Loki, Mimir, Tempo, Grafana — all with health checks.
- Postgres init: `cases` schema, `feature_history` schema (migrations via Alembic, one per service).
- Write proto contracts: `feature_store.proto` (`GetFeatures`), `scoring.proto` (`ScoreTransaction`). Generate Python stubs, wire into a shared `proto/` package both services import.
- Each of the 4 FastAPI services: skeleton app, `/healthz`, Dockerfile, OTel SDK wired to log to stdout (collector not yet consuming).
- **Unit tests**: request/response schema validation (Pydantic models) for each service's skeleton endpoints; a test that generated proto stubs import cleanly and match the `.proto` field names (catches codegen drift early, before real handlers depend on it).

**Definition of done**: `docker compose up` → all containers healthy, all 4 services respond `200` on `/healthz`, Grafana loads (empty dashboards okay), `pytest` passes across all 4 service packages.

---

## Day 2 — `feature-store`: the platform's core differentiator

**Goal**: a working gRPC service that serves real feature aggregates out of Redis, backed durably by Postgres.

- Redis schema for rolling-window aggregates: per-account and per-merchant transaction count/sum over 5m/1h/24h windows (sorted sets or Redis time-series pattern — pick one, document why in code comments only where non-obvious).
- Postgres `feature_history` table: durable snapshot on every update (source of truth, Redis rebuild path).
- Implement `GetFeatures` gRPC handler: reads Redis, falls back to computing from Postgres if a cache miss (and repopulates Redis) — this fallback path is what makes the cache safe to lose.
- A small seed/backfill script to populate Redis + Postgres with synthetic historical transactions, so Day 3's scoring service has real data to call against immediately.
- **Unit tests**: aggregate window math (boundary conditions — a transaction exactly at the 5m/1h/24h edge, empty-window/no-history accounts, decay calculation) and the cache-miss-falls-back-to-Postgres-and-repopulates-Redis path — this fallback is the piece most likely to look right in a demo and be wrong under a real cache eviction.

**Definition of done**: `grpcurl` (or a test client) against `feature-store` returns real, correct aggregates for seeded accounts. Latency of `GetFeatures` measured locally (should be low-single-digit ms — this is your SLA budget check). `pytest` passes, including the boundary and fallback cases above.

---

## Day 3 — `scoring`: the hot path

**Goal**: transactions get scored with real reasons, calling `feature-store` over gRPC.

- gRPC client to `feature-store` (connection pooling / channel reuse — don't open a channel per call).
- Rules engine: a small, explicit set of rules (velocity threshold, amount-vs-historical-average deviation, new-merchant-for-account, etc.) — each rule that fires contributes to `reasons[]`. This is the explainability requirement from the architecture doc.
- Scoring function: combine rule signals into a `score` (0–100) and `decision` (APPROVE/FLAG/DECLINE) via explicit thresholds — no ML model in v1, the pipeline and contract are what matter, not model sophistication.
- Kafka consumer on `transaction.received` (topic doesn't have producers yet — test by producing manually via `kafka-console-producer` or a test script) → calls `feature-store` → produces `transaction.scored`.
- Also expose `ScoreTransaction` as a direct gRPC endpoint for synchronous testing without going through Kafka at all.
- **Unit tests**: each rule in isolation (fires / doesn't fire at its threshold, off-by-one at the boundary), the score/decision combination function against known rule-signal combinations (table-driven: given these rules fired, expect this score and decision), and that every fired rule shows up in `reasons[]` — explainability is a testable contract, not just a nice-to-have field. Use a fake/mocked `feature-store` client so these tests don't depend on gRPC or Kafka being up.

**Definition of done**: hand-publish a `transaction.received` event to Kafka, observe `scoring` consume it, call `feature-store`, and produce a `transaction.scored` event with populated `reasons[]`. Direct gRPC call to `ScoreTransaction` also works standalone. `pytest` passes with the rules engine fully covered against a mocked feature-store.

---

## Day 4 — `ingestion` + end-to-end hot path

**Goal**: a real HTTP request produces a score, entirely through the event pipeline, within budget.

- `ingestion`: `POST /transactions`, request validation, produce `transaction.received`, return `202` with a transaction ID.
- Wire the full chain: `ingestion` → Kafka → `scoring` → gRPC → `feature-store` → Kafka `transaction.scored`.
- Since nothing consumes `transaction.scored` yet, add a minimal `GET /transactions/{id}` on `ingestion` (or a temp debug endpoint) backed by a short-lived consumer/cache, purely so you can observe results end-to-end before `case-management` exists tomorrow. (This gets superseded by `case-management` on Day 5 — fine to be throwaway.)
- Run a basic load test (k6 or locust) against `POST /transactions` — this is your first real read on whether the p99 < 100ms target for the scoring path is achievable, *before* four more days of feature-building make it harder to isolate regressions.
- **Unit tests**: `ingestion` request validation (malformed amount, missing account, bad timestamp — each rejected with a clear `4xx` before anything is published to Kafka) and the Kafka message serialization/deserialization round-trip (produced payload → consumed payload is byte-for-byte the same shape) — this is the seam most likely to silently drift once multiple services touch the same event schema.

**Definition of done**: `curl -X POST /transactions` with a real payload results in an observable score within the chain, and you have a first latency number (even if it's not yet meeting target — better to know now). `pytest` passes for validation and (de)serialization.

---

## Day 5 — `case-management`: analyst loop + feedback

**Goal**: flagged transactions are reviewable, and analyst verdicts flow back into the system.

- `case-management`: Kafka consumer on `transaction.scored`, persists `FLAGGED`/`DECLINE` transactions into the `cases` Postgres table (approved transactions are not persisted here — high volume, no analyst action needed).
- REST API: `GET /cases` (list, filterable), `GET /cases/{id}` (detail with the `reasons[]` from scoring — this is where explainability becomes visible to a human), `POST /cases/{id}/verdict` (analyst confirms fraud / false positive).
- On verdict submission: persist it, produce `verdict.recorded` to Kafka.
- Extend `feature-store`'s Kafka consumer to also handle `verdict.recorded` — a confirmed-fraud verdict should adjust that account's future feature computation (e.g., a flag/weight consulted by the rules engine). This closes the feedback loop described in the architecture doc.
- Remove the Day 4 throwaway debug endpoint on `ingestion` now that `case-management` is the real read path.
- **Unit tests**: verdict-submission state transitions (a case can only move OPEN → RESOLVED once, a verdict on an already-resolved case is rejected or clearly handled — decide and test the behavior, don't leave it implicit), and `feature-store`'s verdict-driven adjustment logic (a confirmed-fraud verdict measurably changes what `GetFeatures` returns for that account, tested against a mocked/in-memory Redis or a test container).

**Definition of done**: a flagged transaction appears in `GET /cases`, submitting a verdict via `POST /cases/{id}/verdict` produces `verdict.recorded`, and you can observe `feature-store`'s state change as a result (e.g., re-query `GetFeatures` for that account and see the effect). `pytest` passes, including the verdict state-machine and feedback-adjustment cases.

---

## Day 6 — Celery + full observability pipeline

**Goal**: async workflows exist, and the OTel Collector → Loki/Mimir/Tempo/Grafana pipeline is fully wired with a demonstrable end-to-end trace.

- Celery: Redis-backed broker/result backend, worker container in Compose.
- Kafka → Celery hand-off consumer: a lightweight consumer on `transaction.scored`/`verdict.recorded` that enqueues Celery tasks rather than processing inline.
- Implement 2–3 real Celery tasks: scheduled batch re-scoring (re-run current rules against last-N-hours of transactions, useful after a rules change), retraining-signal aggregation (bundle `verdict.recorded` events into a dataset snapshot file/table), and an analyst digest report.
- Point every service's OTel SDK at the real Collector (swap from stdout-only). Configure the Collector to fan out to Tempo (traces), Mimir (metrics via remote-write), Loki (logs).
- Propagate trace context through Kafka message headers so a trace spans `ingestion` → `scoring` → `feature-store` (gRPC) → `case-management`/Celery as one connected trace — this is the hardest and most valuable piece of the observability story per the architecture doc.
- Grafana dashboards: one RED-metrics dashboard per service, one Kafka consumer-lag dashboard, one domain dashboard (score decision distribution, cache hit rate).
- **Unit tests**: each Celery task's core logic run directly (not through the broker) — batch re-scoring against a fixed set of transactions produces expected decisions, retraining-signal aggregation produces the expected snapshot shape from a known set of `verdict.recorded` events; and a trace-context propagation test (a trace ID injected into a Kafka message header comes back out unchanged on the consumer side).

**Definition of done**: fire one transaction through the full system, find its trace in Tempo, and see it as a single connected span tree from HTTP request through gRPC and Kafka to the Celery hand-off — with an exemplar link from a Grafana metrics panel into that trace, and log lines in Loki correlated by `trace_id`. `pytest` passes for all Celery task logic and the header propagation round-trip.

---

## Day 7 — Load, resilience, polish

**Goal**: prove the SLA under load, prove the system degrades sanely under failure, and leave the repo in a state someone else (or future-you) can pick up.

- Load test (k6/locust) at a realistic sustained rate against `POST /transactions`; capture p50/p95/p99 for the scoring path, compare against the <100ms target from `docs/ARCHITECTURE.md`, and record the result (numbers, not vibes).
- One deliberate failure scenario, observed through the observability stack rather than guessed at: e.g., kill `feature-store` briefly and confirm `scoring` fails closed/degrades predictably (define what "predictably" means — reject with a clear reason, don't silently approve), then watch Kafka consumer lag spike and recover in Grafana once it's back.
- Fill in `CLAUDE.md`'s "Status" section with real build/run/test commands (this was explicitly deferred until code existed).
- README: what this is, how to run it (`docker compose up`, seed script, example `curl`), link to `docs/ARCHITECTURE.md`.
- **Unit tests**: no new logic this day, but run the *full* suite across all 4 services plus Celery as a single regression pass, and fix anything that's gone stale from six days of changes (a Day 2 test asserting on a schema Day 5 quietly changed, etc.) — a passing full-suite run is part of what "done" means for the whole week, not just each day in isolation.
- Buffer time for whichever day ran over — treat Day 7 morning as unscheduled slack, not additional scope.

**Definition of done**: documented load-test numbers against the stated SLA, one documented failure-mode behavior, a README that lets a stranger run the whole stack from a clean checkout, and a full `pytest` run (all services) passing green.

---

## Explicitly out of scope for week one (phase two candidates)

- Kubernetes manifests / Helm charts (Compose is the week-one deployment target — see `docs/ARCHITECTURE.md` §8).
- A real ML model for scoring (the rules-engine + explainability pipeline is the deliverable; swapping in a model later is a `scoring` internals change, not an architecture change — see `docs/ARCHITECTURE.md` §9 for how it'd reuse the `reasons[]` explainability contract and why it still has to stay inside the p99 hot-path budget).
- An agentic analyst-copilot in `case-management` that drafts investigation summaries/recommended verdicts from feature history and past cases (see `docs/ARCHITECTURE.md` §9) — lives entirely on the human-review side, so it doesn't touch the hot-path latency constraint.
- Auth/authz on the analyst API.
- React frontend (explicitly a later phase per `CLAUDE.md`).

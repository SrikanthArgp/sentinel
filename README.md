# Sentinel

A real-time **Fraud & Risk Scoring Platform** — a fintech-grade microservices backend that decisions financial transactions (approve/flag/decline) under a hard latency SLA (p99 < 100ms).

## What it does

A transaction comes in, gets scored for fraud risk against live behavioral features (recent velocity, historical account/merchant patterns), and is approved, flagged for human review, or declined — with the specific reasons behind the decision attached, not just a number. Flagged transactions go to an analyst; their verdict (confirmed fraud / false positive) feeds back into the platform's future scoring. Four services carry this: `ingestion` (accepts transactions), `scoring` (hot-path decisioning), `feature-store` (live behavioral features), and `case-management` (analyst review + feedback loop), connected by gRPC on the latency-critical path and Kafka on the event-driven path.

See `docs/ARCHITECTURE.md` for the full design, including a step-by-step walkthrough of a transaction's journey through the system.

## Status

No source code exists yet — architecture is decided (`docs/ARCHITECTURE.md`), implementation has not started. See `docs/plan.md` for the day-by-day build sequence.

## Planned Directory Structure

Sentinel is a monorepo: four independently deployable FastAPI services, a Celery worker pool, and a shared protobuf contract layer, all brought up together via Docker Compose. Layout, once implementation starts:

```
sentinel/
├── backend/                         # everything that isn't the analyst-dashboard frontend
│   ├── proto/                       # gRPC contracts — source of truth for the sync path
│   │   ├── feature_store.proto      #   GetFeatures(AccountId, MerchantId, Window) → FeatureSet
│   │   └── scoring.proto            #   ScoreTransaction(Transaction) → ScoreResult
│   │
│   ├── services/
│   │   ├── ingestion/                # REST front door — validates + publishes, never scores
│   │   │   ├── app/
│   │   │   │   ├── api/               # POST /transactions, /healthz
│   │   │   │   ├── kafka/             # producer: transaction.received
│   │   │   │   ├── models/            # Pydantic request/response schemas
│   │   │   │   └── core/              # config, OTel SDK bootstrap
│   │   │   ├── tests/
│   │   │   └── Dockerfile
│   │   │
│   │   ├── scoring/                   # hot path — the p99 < 100ms SLA lives here
│   │   │   ├── app/
│   │   │   │   ├── grpc/               # ScoreTransaction server + feature-store client
│   │   │   │   ├── kafka/              # consumer: transaction.received / producer: transaction.scored
│   │   │   │   ├── rules/              # explicit rules engine → reasons[]
│   │   │   │   ├── scoring/            # rule-signals → score + decision
│   │   │   │   └── core/
│   │   │   ├── tests/
│   │   │   └── Dockerfile
│   │   │
│   │   ├── feature-store/              # live behavioral features — Redis hot path + Postgres system of record
│   │   │   ├── app/
│   │   │   │   ├── grpc/                # GetFeatures server
│   │   │   │   ├── kafka/               # consumer: transaction.scored, verdict.recorded
│   │   │   │   ├── redis/               # rolling-window aggregate read/write
│   │   │   │   ├── db/                  # SQLAlchemy models (schema itself managed via backend/supabase/migrations)
│   │   │   │   └── core/
│   │   │   ├── tests/
│   │   │   └── Dockerfile
│   │   │
│   │   └── case-management/            # analyst-facing REST — the feedback-loop origin
│   │       ├── app/
│   │       │   ├── api/                 # GET/POST /cases
│   │       │   ├── kafka/               # consumer: transaction.scored / producer: verdict.recorded
│   │       │   ├── db/                  # SQLAlchemy models (schema itself managed via backend/supabase/migrations)
│   │       │   └── core/
│   │       ├── tests/
│   │       └── Dockerfile
│   │
│   ├── workers/
│   │   └── celery/                     # batch re-scoring, retraining-signal aggregation, reports
│   │       ├── tasks/
│   │       ├── kafka_handoff.py         # thin consumer that enqueues Celery tasks
│   │       └── Dockerfile
│   │
│   ├── shared/                          # cross-service library — imported, not duplicated
│   │   ├── proto_gen/                    # generated Python stubs from proto/
│   │   └── observability/                # common OTel/structlog setup, trace-context propagation helpers
│   │
│   ├── local/                           # everything actually run locally via Docker Compose
│   │   ├── docker-compose.yml           # Kafka (KRaft), Redis, OTel Collector, Loki, Mimir, Tempo, Grafana
│   │   ├── otel-collector-config.yaml
│   │   └── grafana/dashboards/          # RED-metrics, Kafka consumer-lag, domain dashboards
│   │
│   ├── supabase/                        # hosted Postgres — cases + feature_history schemas
│   │   ├── config.toml                  # Supabase CLI project config
│   │   └── migrations/                  # versioned SQL migrations (Supabase CLI convention)
│   │
│   └── scripts/
│       └── seed.py                      # synthetic historical transactions for feature-store
│
├── frontend/                        # phase two — React analyst review dashboard
│   └── Dockerfile
│
├── docs/
│   ├── ARCHITECTURE.md
│   ├── plan.md
│   └── deployment-aws.md
│
├── docker-compose.yml                # root — includes backend/local/docker-compose.yml + frontend service
├── README.md
├── CLAUDE.md
└── .gitignore
```

**Why this shape:**
- `backend/` is the top-level split: everything that's Python/services/infra lives under it, `frontend/` sits beside it as its own independently-built app (different language, different tooling, different deploy target) — this is a monorepo of two halves, not four-services-plus-a-loose-frontend.
- `backend/proto/` sits outside every service because both `scoring` and `feature-store` depend on it — one contract, generated once into `backend/shared/proto_gen/`, imported by both, so codegen drift is a build-time failure, not a runtime surprise (see the Day 1 proto-import test in `docs/plan.md`).
- Each service under `backend/services/` is a self-contained package (own `Dockerfile`, own `tests/`) so it can be built, tested, and eventually deployed independently — mirroring the service boundaries in `docs/ARCHITECTURE.md` §1, not an arbitrary folder split.
- `backend/shared/observability/` exists because trace-context propagation (HTTP → Kafka headers → gRPC → Celery) has to be implemented identically everywhere to produce one connected trace — duplicating it per service is exactly the kind of drift that would quietly break the observability story.
- `backend/local/` holds everything about *running the local dev stack* (Compose, collector config, dashboards) separately from the services' own code, so the week-one Compose topology (`docs/ARCHITECTURE.md` §8) can evolve into Kubernetes manifests later without reshuffling service code. Postgres is **not** in here — it's hosted on Supabase, not a local container.
- `backend/supabase/` holds the hosted-Postgres schema (`cases`, `feature_history`) as versioned migrations, using the Supabase CLI's own folder convention — kept separate from `backend/local/` because it isn't part of the Compose stack and isn't disposable the way local containers are.
- `backend/workers/celery/` is separate from `backend/services/` because it isn't a request-driven service — no API, no `Dockerfile`-per-endpoint pattern, just a worker pool and a Kafka hand-off consumer.
- `frontend/` is stubbed but empty until the phase-two React dashboard begins, per the project vision in `CLAUDE.md` — it stays outside `backend/` since it will get its own `package.json`/build pipeline, not a Python one.
- The root `docker-compose.yml` runs the whole stack (backend + frontend) with one `docker compose up`, via Compose's `include:` directive pulling in `backend/local/docker-compose.yml` and adding a `frontend` service — backend-only dev keeps working by running `backend/local/docker-compose.yml` directly, without needing frontend tooling installed.

## Tooling

- **Python (backend)**: [`uv`](https://docs.astral.sh/uv/) for dependency management and virtualenvs — one `pyproject.toml`/`uv.lock` per service under `backend/services/*` and `backend/workers/celery`.
- **Node (frontend)**: `pnpm` for package management once `frontend/` gets real code.

## Getting Started

Once implementation begins, update this README with:
- Setup / installation instructions
- Build, run, and test commands

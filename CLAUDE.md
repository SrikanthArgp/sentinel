# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Vision

**A real-time Fraud & Risk Scoring Platform** — a fintech-grade microservices backend that decisions transactions (approve/flag/decline) under a hard latency SLA, built to demonstrate principal/chief-architect-level distributed systems design.

Chosen over alternative ideas (e-commerce order/fulfillment saga, workflow automation engine, media transcode pipeline) because it forces the hardest problems: low-latency decisioning, stream processing with freshness guarantees, a human-in-the-loop feedback loop, and explainability — versus commoditized CRUD-style microservice demos.

### Core domain requirements
- Score incoming transactions in real time (target: p99 < 100ms end-to-end).
- Maintain a live feature store (recent transaction velocity, historical behavior) that stays fresh under streaming updates.
- Support analyst review/override of flagged transactions, feeding back into future scoring (feedback loop).
- Explainability: every score must carry the reasons/features that drove it, not just a number.
- Full observability under load: traces must span gRPC calls, Kafka hops, and Celery tasks end-to-end.

### Target stack
- **API layer**: FastAPI
- **Inter-service sync calls**: gRPC (protobuf contracts as the service interface source of truth)
- **Event backbone**: Kafka (transaction stream, scoring events, analyst-verdict feedback events)
- **Async/background work**: Celery (batch re-scoring, model/rule retraining triggers, report generation)
- **Logging**: Loki
- **Metrics**: Mimir (Prometheus-compatible)
- **Tracing**: Tempo
- **Frontend (later phase)**: React — analyst review dashboard, case management UI, live monitoring views

## Architecture

Full design doc: `docs/ARCHITECTURE.md` — service boundaries (ingestion, scoring, feature-store, case-management), gRPC vs Kafka communication decisions, data store ownership, and the observability pipeline (OTel Collector → Loki/Mimir/Tempo).

Build sequence: `docs/plan.md` — day-by-day plan (Day 1: infra/contracts/skeletons → Day 7: load test + resilience + polish), each day ending in a runnable Compose state.

AWS deployment (phase two): `docs/deployment-aws.md` — ECS Fargate + MSK Serverless + RDS + ElastiCache + SQS-backed Celery + self-hosted LGTM stack on S3, with Terraform/CI-CD approach and cost/environment strategy.

## Status

No source code or build tooling exist yet — architecture is decided (`docs/ARCHITECTURE.md`), implementation has not started. Once code is added, this file should be expanded with actual build/lint/test commands and regenerated via the `init` skill rather than relying on this placeholder-level description.

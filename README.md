# Sentinel

A real-time **Fraud & Risk Scoring Platform** — a fintech-grade microservices backend that decisions financial transactions (approve/flag/decline) under a hard latency SLA (p99 < 100ms).

## What it does

A transaction comes in, gets scored for fraud risk against live behavioral features (recent velocity, historical account/merchant patterns), and is approved, flagged for human review, or declined — with the specific reasons behind the decision attached, not just a number. Flagged transactions go to an analyst; their verdict (confirmed fraud / false positive) feeds back into the platform's future scoring. Four services carry this: `ingestion` (accepts transactions), `scoring` (hot-path decisioning), `feature-store` (live behavioral features), and `case-management` (analyst review + feedback loop), connected by gRPC on the latency-critical path and Kafka on the event-driven path.

See `docs/ARCHITECTURE.md` for the full design, including a step-by-step walkthrough of a transaction's journey through the system.

## Status

No source code exists yet — architecture is decided (`docs/ARCHITECTURE.md`), implementation has not started. See `docs/plan.md` for the day-by-day build sequence.

## Getting Started

Once implementation begins, update this README with:
- Setup / installation instructions
- Build, run, and test commands

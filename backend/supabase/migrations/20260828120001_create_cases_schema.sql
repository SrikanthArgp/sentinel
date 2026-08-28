-- case-management's durable record of every flagged/declined transaction
-- and its analyst verdict (see docs/ARCHITECTURE.md §6, Day 5 of
-- docs/plan.md). Approved transactions are not persisted here.
create schema if not exists cases;

create type cases.decision as enum ('FLAG', 'DECLINE');
create type cases.case_status as enum ('OPEN', 'RESOLVED');
create type cases.verdict as enum ('CONFIRMED_FRAUD', 'FALSE_POSITIVE');

create table cases.cases (
    id uuid primary key default gen_random_uuid(),
    transaction_id text not null unique,
    account_id text not null,
    merchant_id text not null,
    amount numeric(12, 2) not null,
    currency text not null,
    score smallint not null check (score between 0 and 100),
    decision cases.decision not null,
    -- explainability: the reasons[] that drove the score, verbatim from scoring
    reasons jsonb not null default '[]'::jsonb,
    status cases.case_status not null default 'OPEN',
    verdict cases.verdict,
    verdict_notes text,
    verdict_at timestamptz,
    created_at timestamptz not null default now(),
    -- a case can only move OPEN -> RESOLVED once; enforce it here, not just in app code
    constraint cases_status_verdict_consistency check (
        (status = 'OPEN' and verdict is null and verdict_at is null)
        or (status = 'RESOLVED' and verdict is not null and verdict_at is not null)
    )
);

create index idx_cases_status on cases.cases (status);
create index idx_cases_account_id on cases.cases (account_id);

-- feature-store's durable source of truth: every transaction event that
-- feeds the Redis rolling-window aggregates, plus the verdict-driven
-- fraud flag that adjusts future scoring (see docs/ARCHITECTURE.md §6,
-- Day 2/Day 5 of docs/plan.md).
create schema if not exists feature_history;

create table feature_history.transactions (
    id uuid primary key default gen_random_uuid(),
    transaction_id text not null unique,
    account_id text not null,
    merchant_id text not null,
    amount numeric(12, 2) not null,
    currency text not null,
    occurred_at timestamptz not null,
    created_at timestamptz not null default now()
);

-- Rebuilding an account's rolling-window aggregates after a Redis cache
-- miss means scanning this table by account_id ordered by recency.
create index idx_feature_history_transactions_account_occurred
    on feature_history.transactions (account_id, occurred_at desc);

-- Set from case-management's verdict.recorded events; consulted by
-- feature-store's rules-relevant feature computation.
create table feature_history.account_fraud_flags (
    account_id text primary key,
    has_confirmed_fraud boolean not null default false,
    updated_at timestamptz not null default now()
);

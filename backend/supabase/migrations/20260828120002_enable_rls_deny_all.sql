-- These tables are only ever touched by backend services over a direct
-- service_role Postgres connection (asyncpg), never through the Supabase
-- client/anon key. Enabling RLS with zero policies denies anon/authenticated
-- entirely by default; service_role bypasses RLS regardless, so backend
-- access is unaffected.
alter table feature_history.transactions enable row level security;
alter table feature_history.account_fraud_flags enable row level security;
alter table cases.cases enable row level security;

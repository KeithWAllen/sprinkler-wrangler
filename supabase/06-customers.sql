-- =====================================================================
-- Sprinkler Wrangler: customer profiles
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again. Run 05-chief-admin.sql first.
--
-- Customer profiles are created first (by admins / dispatch); jobs hang off them.
-- Team can read, add and edit customers; only the chief admin can delete one.
-- =====================================================================

create table if not exists public.customers (
  id         text primary key,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.customers enable row level security;

drop policy if exists "team read"    on public.customers;
drop policy if exists "team add"     on public.customers;
drop policy if exists "team edit"    on public.customers;
drop policy if exists "chief delete" on public.customers;
create policy "team read"    on public.customers for select using (public.is_tech());
create policy "team add"     on public.customers for insert with check (public.is_tech());
create policy "team edit"    on public.customers for update using (public.is_tech()) with check (public.is_tech());
create policy "chief delete" on public.customers for delete using (public.is_chief());

do $$ begin
  begin alter publication supabase_realtime add table public.customers; exception when others then null; end;
end $$;

select 'Customer profiles ready' as result, (select count(*) from public.customers) as customers;

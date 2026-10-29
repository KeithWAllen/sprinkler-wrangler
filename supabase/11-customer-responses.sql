-- =====================================================================
-- Sprinkler Wrangler: customers approve (or decline) the estimate in the portal
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again. Run 08 first.
-- =====================================================================

-- Option totals saved with each issued report, for the portal
alter table public.reports add column if not exists options jsonb;

create table if not exists public.customer_responses (
  id             bigserial primary key,
  job_id         text not null,
  report_id      text not null,
  rev            int,
  choice         text not null check (choice in ('fix','all','decline')),
  note           text,
  customer_email text not null,
  created_at     timestamptz not null default now()
);
create index if not exists customer_responses_job_idx on public.customer_responses (job_id);

alter table public.customer_responses enable row level security;

drop policy if exists "team read"      on public.customer_responses;
drop policy if exists "owner read"     on public.customer_responses;
drop policy if exists "owner respond"  on public.customer_responses;
create policy "team read"  on public.customer_responses for select using (public.is_tech());
create policy "owner read" on public.customer_responses for select using (customer_email = lower(auth.jwt() ->> 'email'));
-- an approved customer can answer only for their own issued report
create policy "owner respond" on public.customer_responses for insert with check (
  public.is_approved_owner()
  and customer_email = lower(auth.jwt() ->> 'email')
  and exists (select 1 from public.reports r where r.id = report_id and r.job_id = job_id and r.customer_email = lower(auth.jwt() ->> 'email'))
);

do $$ begin
  begin alter publication supabase_realtime add table public.customer_responses; exception when others then null; end;
end $$;

select 'Customer responses ready' as result;

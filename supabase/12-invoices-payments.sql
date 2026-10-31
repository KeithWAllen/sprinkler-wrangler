-- =====================================================================
-- Sprinkler Wrangler: invoice management + Stripe online payments
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again.
-- =====================================================================

-- Invoice summary the customer portal shows (the app keeps these up to date).
alter table public.invoices add column if not exists balance    numeric;
alter table public.invoices add column if not exists paid_total numeric default 0;
alter table public.invoices add column if not exists due_date   date;
alter table public.invoices add column if not exists pay_online boolean default false;

-- Online payments land here. Only the Stripe webhook (server side) can add rows.
create table if not exists public.payments (
  id         bigserial primary key,
  job_id     text not null,
  amount     numeric not null,
  method     text,
  ref        text unique,            -- Stripe checkout session id (stops double-counting)
  paid_at    timestamptz not null default now(),
  imported   boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.payments enable row level security;
drop policy if exists "team read payments" on public.payments;
drop policy if exists "team mark payments" on public.payments;
create policy "team read payments" on public.payments for select using (public.is_tech());
create policy "team mark payments" on public.payments for update using (public.is_tech()) with check (public.is_tech());
-- No insert or delete policies: customers and the app can't add or remove payments directly.

-- Called only by the Stripe webhook. Records the payment once and updates the invoice the customer sees.
create or replace function public.record_stripe_payment(p_job_id text, p_amount numeric, p_ref text, p_method text)
returns void language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into public.payments (job_id, amount, method, ref) values (p_job_id, p_amount, p_method, p_ref)
  on conflict (ref) do nothing;
  get diagnostics n = row_count;
  if n > 0 then
    update public.invoices
       set paid_total = coalesce(paid_total, 0) + p_amount,
           balance    = greatest(coalesce(balance, total) - p_amount, 0),
           status     = case when greatest(coalesce(balance, total) - p_amount, 0) <= 0.004 then 'paid' else 'partial' end,
           updated_at = now()
     where job_id = p_job_id;
  end if;
end $$;
revoke all on function public.record_stripe_payment(text, numeric, text, text) from public, anon, authenticated;
grant execute on function public.record_stripe_payment(text, numeric, text, text) to service_role;

select 'Invoices & payments update complete' as result;

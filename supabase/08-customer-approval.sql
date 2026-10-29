-- =====================================================================
-- Sprinkler Wrangler: approve customer (property owner) accounts
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again. Run 05, 06 and 07 first.
--
-- Customers who sign up wait for an admin to approve them. Until then
-- they can't see any reports or invoices. Approval links the account to
-- a customer profile.
-- =====================================================================

alter table public.profiles add column if not exists approved boolean not null default false;
alter table public.profiles add column if not exists cust_id  text;
alter table public.profiles add column if not exists approved_at timestamptz;

create or replace function public.is_approved_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'owner' and approved);
$$;

-- Admins approve, link or switch off a customer account
create or replace function public.set_customer_access(p_email text, p_approve boolean, p_cust text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can approve customer accounts'; end if;
  p_email := lower(trim(p_email));
  if not exists (select 1 from public.profiles where email = p_email and role = 'owner') then
    raise exception 'No customer account with that email';
  end if;
  update public.profiles
     set approved = p_approve,
         cust_id = case when p_approve then coalesce(p_cust, cust_id) else cust_id end,
         approved_at = case when p_approve then now() else null end
   where email = p_email and role = 'owner';
end $$;

-- Customers only see their reports and invoices once approved
drop policy if exists "owners read" on public.reports;
drop policy if exists "owners read" on public.invoices;
create policy "owners read" on public.reports  for select using (public.is_approved_owner() and customer_email = lower(auth.jwt() ->> 'email'));
create policy "owners read" on public.invoices for select using (public.is_approved_owner() and customer_email = lower(auth.jwt() ->> 'email'));

select 'Customer approval ready' as result,
       (select count(*) from public.profiles where role = 'owner' and not approved) as waiting_for_approval;

-- =====================================================================
-- Sprinkler Wrangler: let an approved customer see their own profile
-- (name, customer number, address, phone) at the top of their portal.
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again. Run 08 first.
-- =====================================================================

drop policy if exists "owner reads own profile" on public.customers;
create policy "owner reads own profile" on public.customers for select using (
  id = (select cust_id from public.profiles where id = auth.uid() and role = 'owner' and approved)
);

select 'Portal customer card ready' as result;

-- =====================================================================
-- Sprinkler Wrangler: one-time fix for customers sharing the same number
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again (does nothing once numbers are unique). Run 07 first.
--
-- When two customers have the same number, the profile an admin created
-- keeps it; automatic profiles (made from older jobs) get the next free number.
-- =====================================================================

alter table public.customers disable trigger customer_number;

with ranked as (
  select id,
         row_number() over (
           partition by data->>'custNo'
           order by (case when id like 'cl%' then 1 else 0 end),
                    coalesce((data->>'createdAt')::bigint, 0), id) as rn
  from public.customers
  where coalesce(data->>'custNo','') <> ''
)
update public.customers c
   set data = jsonb_set(c.data, '{custNo}', to_jsonb(nextval('public.customer_no_seq')::text))
  from ranked r
 where r.id = c.id and r.rn > 1;

alter table public.customers enable trigger customer_number;

select 'Duplicate numbers fixed' as result,
       (select string_agg((data->>'customer') || ' = ' || (data->>'custNo'), ', ' order by (data->>'custNo')) from public.customers) as customers;

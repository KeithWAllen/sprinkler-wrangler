-- =====================================================================
-- Sprinkler Wrangler: customer numbers handed out by the database
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again. Run 06-customers.sql first.
--
-- One counter for everyone, so two devices can never give out the same
-- number, and a customer's number never changes once it's set.
-- =====================================================================

create sequence if not exists public.customer_no_seq start 1001;

-- Make sure the counter starts after any number already in use
select setval('public.customer_no_seq',
  greatest(1000, coalesce((select max((regexp_replace(data->>'custNo','\D','','g'))::int)
                           from public.customers where data->>'custNo' ~ '\d'), 1000)));

create or replace function public.customer_number() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- a save of an existing customer arrives as insert-then-update; let the update step handle it
  if tg_op = 'INSERT' and exists (select 1 from public.customers where id = new.id) then
    return new;
  end if;
  -- an existing number is permanent
  if tg_op = 'UPDATE' and old.data ? 'custNo' and coalesce(old.data->>'custNo','') <> '' then
    new.data := jsonb_set(new.data, '{custNo}', old.data->'custNo');
    return new;
  end if;
  -- new customer (any number sent by a device is ignored), or one that never got a number
  if tg_op = 'INSERT' or coalesce(new.data->>'custNo','') = '' then
    new.data := jsonb_set(new.data, '{custNo}', to_jsonb(nextval('public.customer_no_seq')::text));
  end if;
  return new;
end $$;

drop trigger if exists customer_number on public.customers;
create trigger customer_number before insert or update on public.customers
  for each row execute function public.customer_number();

-- Give a number to any customer saved without one
update public.customers set data = data where coalesce(data->>'custNo','') = '';

select 'Customer numbers ready' as result,
       (select string_agg((data->>'customer') || ' = ' || (data->>'custNo'), ', ' order by (data->>'custNo')) from public.customers) as customers;

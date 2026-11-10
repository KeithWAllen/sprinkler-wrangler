-- =====================================================================
-- Sprinkler Wrangler: yearly invoice numbers
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again (it never lowers a count that's already higher).
--
-- Invoice numbers end in a 4-digit count for the year: INV-<job date>-<customer #>-0165.
-- The count is kept on the server so two phones never hand out the same number.
-- It starts again at 0001 every January 1 (Central time): each year has its own count.
-- Bradley's last invoice outside the app was 0164, so 2026 continues at 0165.
-- =====================================================================

create table if not exists public.invoice_counters (
  company_id uuid not null references public.companies (id),
  year int not null,
  last int not null default 0,
  primary key (company_id, year)
);
alter table public.invoice_counters enable row level security;
-- No direct access: only through the functions below.

-- Next number for this year (team members only). Returns e.g. 165.
create or replace function public.next_invoice_seq() returns int
language plpgsql security definer set search_path = public as $$
declare y int := extract(year from (now() at time zone 'America/Chicago'))::int; co uuid := public.my_company(); n int;
begin
  if not public.is_tech() or co is null then raise exception 'Only the team can create invoices'; end if;
  insert into public.invoice_counters (company_id, year, last) values (co, y, 1)
    on conflict (company_id, year) do update set last = invoice_counters.last + 1
    returning last into n;
  return n;
end $$;

-- What the next number will be (for Admin settings).
create or replace function public.peek_invoice_seq() returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select last from public.invoice_counters
                    where company_id = public.my_company()
                      and year = extract(year from (now() at time zone 'America/Chicago'))::int), 0) + 1
   where public.is_tech();
$$;

-- Admins can set the next number (e.g. to carry on from Zoho). Never below 1.
create or replace function public.set_next_invoice_seq(p_next int) returns void
language plpgsql security definer set search_path = public as $$
declare y int := extract(year from (now() at time zone 'America/Chicago'))::int; co uuid := public.my_company();
begin
  if not public.is_admin() or co is null then raise exception 'Only admins can change the invoice number'; end if;
  if p_next is null or p_next < 1 or p_next > 9999 then raise exception 'Pick a number from 1 to 9999'; end if;
  insert into public.invoice_counters (company_id, year, last) values (co, y, p_next - 1)
    on conflict (company_id, year) do update set last = p_next - 1;
end $$;

revoke all on function public.next_invoice_seq() from public;
revoke all on function public.peek_invoice_seq() from public;
revoke all on function public.set_next_invoice_seq(int) from public;
grant execute on function public.next_invoice_seq() to authenticated;
grant execute on function public.peek_invoice_seq() to authenticated;
grant execute on function public.set_next_invoice_seq(int) to authenticated;

-- Bradley's company (the first company): 2026 carries on after his last invoice, 0164.
insert into public.invoice_counters (company_id, year, last)
select public.founder_company(), 2026, 164
where public.founder_company() is not null
on conflict (company_id, year) do update set last = greatest(invoice_counters.last, 164);

select 'Invoice numbers update complete: next 2026 invoice is ' ||
       lpad(((select last from public.invoice_counters where company_id = public.founder_company() and year = 2026) + 1)::text, 4, '0') as result;

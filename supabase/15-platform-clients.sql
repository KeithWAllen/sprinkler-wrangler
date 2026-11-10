-- =====================================================================
-- Sprinkler Wrangler: platform owner + Clients page
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again.
--
-- The platform owner (Keith) sits above every company. The Clients page lists each
-- company (Bradley's Sprinkler Wrangler is client #1): business & license details,
-- team, customer and job counts, invoiced and collected totals.
-- Only summaries leave a company; nobody else can call these functions.
-- =====================================================================

create table if not exists public.platform_admins (
  user_id  uuid primary key references auth.users on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.platform_admins enable row level security;
drop policy if exists "see self" on public.platform_admins;
create policy "see self" on public.platform_admins for select using (user_id = auth.uid());

-- Keith's account becomes the platform owner. (Only his email: company chiefs such as Bradley are not platform owners.)
insert into public.platform_admins (user_id)
select id from public.profiles where lower(email) = 'slrmasterkwa@gmail.com'
on conflict do nothing;

create or replace function public.is_platform() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;

alter table public.companies add column if not exists notes text;

-- One row per company for the Clients page.
create or replace function public.platform_companies() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform() then raise exception 'Only the platform owner can see clients'; end if;
  return coalesce((select jsonb_agg(x order by (x ->> 'created_at')) from (
    select jsonb_build_object(
      'id', c.id, 'name', c.name, 'slug', c.slug, 'plan', c.plan, 'status', c.status, 'notes', c.notes, 'created_at', c.created_at,
      'business', coalesce((select data -> 'biz' from public.settings where company_id = c.id and key = 'business'), '{}'::jsonb),
      'legacy_business', coalesce((select jsonb_strip_nulls(jsonb_build_object(
          '_biz_name', data -> 'prices' -> '_biz_name', '_biz_irrigator', data -> 'prices' -> '_biz_irrigator',
          '_biz_lic', data -> 'prices' -> '_biz_lic', '_biz_addr', data -> 'prices' -> '_biz_addr',
          '_biz_phone', data -> 'prices' -> '_biz_phone', '_biz_email', data -> 'prices' -> '_biz_email'))
        from public.settings where company_id = c.id and key = 'pricing'), '{}'::jsonb),
      'latest_doc', (select jsonb_build_object('no', i.no, 'kind', i.kind, 'html', i.html, 'at', i.updated_at)
                       from public.invoices i where i.company_id = c.id and coalesce(i.html, '') <> ''
                      order by i.updated_at desc limit 1),
      'team', coalesce((select jsonb_agg(jsonb_build_object('name', p.name, 'email', p.email, 'admin', p.is_admin, 'chief', p.is_chief) order by p.created_at)
                         from public.profiles p where p.company_id = c.id and p.role = 'tech'), '[]'::jsonb),
      'portal_accounts', (select count(*) from public.profiles p where p.company_id = c.id and p.role = 'owner'),
      'customers', (select count(*) from public.customers x where x.company_id = c.id and coalesce(x.data ->> 'mergedInto', '') = ''),
      'jobs', (select count(*) from public.jobs x where x.company_id = c.id),
      'last_job_at', (select max(updated_at) from public.jobs x where x.company_id = c.id),
      'invoiced', (select coalesce(sum(total), 0) from public.invoices x where x.company_id = c.id and x.kind = 'invoice' and coalesce(x.status, '') not in ('void', 'draft')),
      'open_balance', (select coalesce(sum(coalesce(balance, total)), 0) from public.invoices x where x.company_id = c.id and x.kind = 'invoice' and x.status in ('sent', 'partial', 'pastdue')),
      'collected_online', (select coalesce(sum(amount), 0) from public.payments x where x.company_id = c.id)
    ) as x, c.created_at
    from public.companies c) t), '[]'::jsonb);
end $$;

-- Rename / set status, plan, notes.
create or replace function public.platform_update_company(p_id uuid, p_name text, p_status text, p_plan text, p_notes text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform() then raise exception 'Only the platform owner can change clients'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the company name'; end if;
  update public.companies set name = trim(p_name), status = coalesce(nullif(p_status, ''), status),
         plan = coalesce(nullif(p_plan, ''), plan), notes = p_notes where id = p_id;
end $$;

-- Save a company's business & license details (e.g. pulled from one of its estimates or invoices).
create or replace function public.platform_set_business(p_id uuid, p_biz jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform() then raise exception 'Only the platform owner can change clients'; end if;
  insert into public.settings (company_id, key, data, updated_at)
  values (p_id, 'business', jsonb_build_object('biz', p_biz, 'updatedAt', (extract(epoch from now()) * 1000)::bigint, 'by', 'Platform owner'), now())
  on conflict (company_id, key) do update set data = excluded.data, updated_at = now();
end $$;

revoke all on function public.platform_companies() from public;
revoke all on function public.platform_update_company(uuid, text, text, text, text) from public;
revoke all on function public.platform_set_business(uuid, jsonb) from public;
grant execute on function public.platform_companies() to authenticated;
grant execute on function public.platform_update_company(uuid, text, text, text, text) to authenticated;
grant execute on function public.platform_set_business(uuid, jsonb) to authenticated;
grant execute on function public.is_platform() to authenticated;

select 'Platform update complete' as result,
       (select string_agg(p.email, ', ') from public.platform_admins a join public.profiles p on p.id = a.user_id) as platform_owner,
       (select string_agg(name, ', ') from public.companies) as clients;

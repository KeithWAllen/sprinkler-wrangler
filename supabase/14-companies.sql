-- =====================================================================
-- Sprinkler Wrangler: separate companies (ready for subscriptions)
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again.
--
-- Every job, customer, invoice, price sheet, setting, payment and customer link
-- now belongs to ONE company. Database rules keep companies completely apart:
-- a team member only ever sees their own company's records.
-- Everyone already here (Bradley's team and customers) becomes company #1.
--
-- Also: customers can no longer read their own full record (it holds the
-- team's private notes and gate codes). The portal gets a safe card instead.
-- =====================================================================

create table if not exists public.companies (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  slug       text unique,                 -- short name used in sign-up links later
  plan       text not null default 'founder',
  status     text not null default 'active' check (status in ('active', 'trial', 'past_due', 'canceled')),
  created_at timestamptz not null default now()
);
alter table public.companies enable row level security;

alter table public.profiles add column if not exists company_id uuid references public.companies (id);

-- Company #1 = the business already using the app; everyone here joins it.
do $$ declare c uuid; nm text;
begin
  select id into c from public.companies order by created_at limit 1;
  if c is null then
    nm := coalesce(
      (select nullif(data -> 'biz' ->> '_biz_name', '') from public.settings where key = 'business' limit 1),
      (select nullif(data -> 'prices' ->> '_biz_name', '') from public.settings where key = 'pricing' limit 1),
      'Sprinkler Wrangler');
    insert into public.companies (name, slug) values (nm, 'founder') returning id into c;
  end if;
  update public.profiles set company_id = c where company_id is null;
end $$;

create or replace function public.my_company() returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from public.profiles where id = auth.uid();
$$;
create or replace function public.founder_company() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.companies order by created_at limit 1;
$$;

drop policy if exists "own company" on public.companies;
drop policy if exists "admins rename" on public.companies;
create policy "own company" on public.companies for select using (id = (select public.my_company()));
create policy "admins rename" on public.companies for update using (id = (select public.my_company()) and public.is_admin()) with check (id = (select public.my_company()));
revoke update on public.companies from authenticated, anon;
grant update (name) on public.companies to authenticated;

-- company_id on every business table + a rule that ANDs with every other rule:
-- you only see and write rows of your own company.
do $$ declare t text; c uuid := public.founder_company();
begin
  foreach t in array array['jobs', 'customers', 'settings', 'reports', 'invoices', 'payments', 'share_links',
                           'share_responses', 'customer_responses', 'staff_emails'] loop
    execute format('alter table public.%I add column if not exists company_id uuid references public.companies (id)', t);
    execute format('update public.%I set company_id = %L where company_id is null', t, c);
    execute format('alter table public.%I alter column company_id set default public.my_company()', t);
    execute format('alter table public.%I alter column company_id set not null', t);
    execute format('create index if not exists %I on public.%I (company_id)', t || '_company_idx', t);
    execute format('drop policy if exists "same company" on public.%I', t);
    execute format('create policy "same company" on public.%I as restrictive for all using (company_id = (select public.my_company())) with check (company_id = (select public.my_company()))', t);
  end loop;
end $$;

-- Settings: one price sheet / business record / terms per company.
alter table public.settings drop constraint if exists settings_pkey;
alter table public.settings add primary key (company_id, key);
-- The sign-up page (not signed in yet) may read company #1's terms.
drop policy if exists "same company" on public.settings;
create policy "same company" on public.settings as restrictive for all
  using (company_id = (select public.my_company()) or (key = 'terms' and company_id = public.founder_company()))
  with check (company_id = (select public.my_company()));
drop policy if exists "terms public read" on public.settings;
create policy "terms public read" on public.settings for select to anon, authenticated
  using (key = 'terms' and company_id = public.founder_company());

-- Team list: admins see only their own company's people.
drop policy if exists "same company" on public.profiles;
create policy "same company" on public.profiles as restrictive for all
  using (id = auth.uid() or company_id = (select public.my_company()))
  with check (id = auth.uid() or company_id = (select public.my_company()));

-- New accounts: invited team members join the inviting company; customers join the
-- company whose link they signed up from (company #1 until sign-up links exist).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare r text := 'owner'; adm boolean := false; co uuid;
begin
  select company_id into co from public.staff_emails where email = lower(new.email) limit 1;
  if co is not null then
    r := 'tech';
  else
    select id into co from public.companies where slug = nullif(new.raw_user_meta_data ->> 'company', '');
    if co is null then co := public.founder_company(); end if;
  end if;
  if co is null then
    insert into public.companies (name, slug) values ('My company', 'founder') returning id into co;
  end if;
  if not exists (select 1 from public.profiles where role = 'tech' and company_id = co) then r := 'tech'; adm := true; end if;
  insert into public.profiles (id, email, role, is_admin, company_id) values (new.id, lower(new.email), r, adm, co)
  on conflict (id) do nothing;
  return new;
end $$;

create or replace function public.set_staff(p_email text, p_staff boolean) returns void
language plpgsql security definer set search_path = public as $$
declare co uuid := public.my_company();
begin
  if not public.is_admin() then raise exception 'Only admins can manage the team'; end if;
  p_email := lower(trim(p_email));
  if p_email = '' then raise exception 'Enter an email'; end if;
  if p_staff then
    if exists (select 1 from public.staff_emails where email = p_email and company_id <> co)
       or exists (select 1 from public.profiles where email = p_email and role = 'tech' and company_id <> co) then
      raise exception 'That email is already on another company''s team';
    end if;
    insert into public.staff_emails (email, company_id) values (p_email, co) on conflict do nothing;
    update public.profiles set role = 'tech', company_id = co where email = p_email;
  else
    if p_email = (select email from public.profiles where id = auth.uid()) then
      raise exception 'You can''t remove yourself';
    end if;
    if exists (select 1 from public.profiles where email = p_email and is_chief and company_id = co) then
      raise exception 'The chief admin can''t be removed';
    end if;
    if exists (select 1 from public.profiles where email = p_email and is_admin and company_id = co) and not public.is_chief() then
      raise exception 'Only the chief admin can remove an admin';
    end if;
    delete from public.staff_emails where email = p_email and company_id = co;
    update public.profiles set role = 'owner', is_admin = false where email = p_email and company_id = co;
  end if;
end $$;

create or replace function public.set_admin(p_email text, p_admin boolean) returns void
language plpgsql security definer set search_path = public as $$
declare co uuid := public.my_company();
begin
  if not public.is_chief() then raise exception 'Only the chief admin can change admin access'; end if;
  p_email := lower(trim(p_email));
  if exists (select 1 from public.profiles where email = p_email and is_chief and company_id = co) then
    raise exception 'The chief admin can''t be changed';
  end if;
  if p_admin then
    if not exists (select 1 from public.profiles where email = p_email and role = 'tech' and company_id = co) then
      raise exception 'Add them to the team and have them sign up first';
    end if;
    update public.profiles set is_admin = true where email = p_email and company_id = co;
  else
    update public.profiles set is_admin = false where email = p_email and company_id = co;
  end if;
end $$;

create or replace function public.set_customer_access(p_email text, p_approve boolean, p_cust text default null) returns void
language plpgsql security definer set search_path = public as $$
declare co uuid := public.my_company();
begin
  if not public.is_admin() then raise exception 'Only admins can approve customer accounts'; end if;
  p_email := lower(trim(p_email));
  if not exists (select 1 from public.profiles where email = p_email and role = 'owner' and company_id = co) then
    raise exception 'No customer account with that email';
  end if;
  update public.profiles
     set approved = p_approve,
         cust_id = case when p_approve then coalesce(p_cust, cust_id) else cust_id end,
         approved_at = case when p_approve then now() else null end
   where email = p_email and role = 'owner' and company_id = co;
end $$;

-- Customer numbers count up separately for each company (company #1 keeps its numbers).
create or replace function public.customer_number() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if tg_op = 'INSERT' and exists (select 1 from public.customers where id = new.id) then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.data ? 'custNo' and coalesce(old.data ->> 'custNo', '') <> '' then
    new.data := jsonb_set(new.data, '{custNo}', old.data -> 'custNo');
    return new;
  end if;
  if tg_op = 'INSERT' or coalesce(new.data ->> 'custNo', '') = '' then
    perform pg_advisory_xact_lock(hashtext('custno:' || new.company_id::text));
    select coalesce(max(nullif(regexp_replace(data ->> 'custNo', '\D', '', 'g'), '')::int), 1000) + 1 into n
      from public.customers where company_id = new.company_id;
    new.data := jsonb_set(new.data, '{custNo}', to_jsonb(n::text));
  end if;
  return new;
end $$;

-- Stripe payments and link answers are written by the server, so they carry the company explicitly.
create or replace function public.record_stripe_payment(p_job_id text, p_amount numeric, p_ref text, p_method text)
returns void language plpgsql security definer set search_path = public as $$
declare n int; co uuid;
begin
  select company_id into co from public.invoices where job_id = p_job_id;
  if co is null then select company_id into co from public.jobs where id = p_job_id; end if;
  insert into public.payments (job_id, amount, method, ref, company_id) values (p_job_id, p_amount, p_method, p_ref, co)
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

create or replace function public.submit_share(p_token text, p_items jsonb, p_name text, p_sig text, p_agree boolean, p_total numeric, p_ua text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.share_links; hdr json; ip text;
begin
  select * into l from public.share_links where token = p_token for update;
  if not found or l.kind <> 'estimate' then raise exception 'This link is not valid.'; end if;
  if l.status = 'answered' then raise exception 'This estimate has already been answered. Please contact us to make changes.'; end if;
  if l.status <> 'open' then raise exception 'This estimate was updated. Please ask for the new link.'; end if;
  if l.expires_at is not null and l.expires_at < now() then raise exception 'This estimate has expired. Please contact us for an updated one.'; end if;
  if coalesce(length(trim(p_name)), 0) < 3 or length(p_name) > 120 then raise exception 'Please type your full name.'; end if;
  if p_sig is null or left(p_sig, 22) <> 'data:image/png;base64,' or length(p_sig) > 400000 then raise exception 'Please sign in the box.'; end if;
  if p_agree is not true then raise exception 'Please tick the approval statement.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 300 then raise exception 'Please choose Accept or Decline for each item.'; end if;
  begin hdr := current_setting('request.headers', true)::json; exception when others then hdr := null; end;
  ip := split_part(coalesce(hdr ->> 'x-forwarded-for', hdr ->> 'x-real-ip', ''), ',', 1);
  insert into public.share_responses (token, job_id, kind, fp, items, name, signature, agreed, total, user_agent, ip, company_id)
  values (p_token, l.job_id, l.kind, l.fp, p_items, trim(p_name), p_sig, true, p_total, left(coalesce(p_ua, ''), 400), nullif(trim(ip), ''), l.company_id);
  update public.share_links set status = 'answered', answered_at = now() where token = p_token;
  return jsonb_build_object('ok', true, 'at', now());
end $$;
revoke all on function public.submit_share(text, jsonb, text, text, boolean, numeric, text) from public;
grant execute on function public.submit_share(text, jsonb, text, text, boolean, numeric, text) to anon, authenticated;

-- Private notes stay private: customers no longer read their own full record.
-- The portal asks for this safe card instead (name, contact, addresses, customer number).
drop policy if exists "owner reads own profile" on public.customers;
create or replace function public.my_customer_card() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'customer', c.data ->> 'customer', 'custNo', c.data ->> 'custNo', 'phone', c.data ->> 'phone',
    'email', c.data ->> 'email', 'address', c.data ->> 'address', 'city', c.data ->> 'city',
    'properties', (select coalesce(jsonb_agg(jsonb_build_object('id', p ->> 'id', 'label', p ->> 'label',
                     'address', p ->> 'address', 'city', p ->> 'city')), '[]'::jsonb)
                   from jsonb_array_elements(coalesce(c.data -> 'properties', '[]'::jsonb)) p))
  from public.profiles pr join public.customers c on c.id = pr.cust_id and c.company_id = pr.company_id
  where pr.id = auth.uid() and pr.role = 'owner' and pr.approved;
$$;
revoke all on function public.my_customer_card() from public;
grant execute on function public.my_customer_card() to authenticated;

-- Photos: team members see only photos uploaded by their own company's team.
do $$
declare col text;
begin
  select case when exists (select 1 from information_schema.columns where table_schema = 'storage' and table_name = 'objects' and column_name = 'owner_id')
              then 'coalesce(storage.objects.owner_id, storage.objects.owner::text)'
              when exists (select 1 from information_schema.columns where table_schema = 'storage' and table_name = 'objects' and column_name = 'owner')
              then 'storage.objects.owner::text' end into col;
  if col is not null then
    execute 'drop policy if exists "techs photos" on storage.objects';
    execute format($p$create policy "techs photos" on storage.objects for all
      using (bucket_id = 'photos' and public.is_tech()
             and (%1$s is null or exists (select 1 from public.profiles p where p.id::text = %1$s and p.company_id = public.my_company())))
      with check (bucket_id = 'photos' and public.is_tech())$p$, col);
  end if;
end $$;

select 'Companies update complete' as result,
       (select string_agg(name || ' (' || (select count(*) from public.profiles p where p.company_id = c.id) || ' people)', ', ') from public.companies c) as companies;

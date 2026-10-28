-- =====================================================================
-- Sprinkler Wrangler — database setup
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again; it won't duplicate anything.
-- =====================================================================

-- ---------- People ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users on delete cascade,
  email      text unique,
  name       text not null default '',
  role       text not null default 'owner' check (role in ('tech','owner')),
  created_at timestamptz not null default now()
);

-- Emails allowed to be technicians (managed from the app's Team page)
create table if not exists public.staff_emails (
  email    text primary key,
  added_at timestamptz not null default now()
);

create or replace function public.is_tech() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'tech');
$$;

-- New sign-ups: the very first account becomes a technician,
-- staff emails become technicians, everyone else is a property owner.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare r text;
begin
  if not exists (select 1 from public.profiles where role = 'tech') then r := 'tech';
  elsif exists (select 1 from public.staff_emails where email = lower(new.email)) then r := 'tech';
  else r := 'owner';
  end if;
  insert into public.profiles (id, email, role) values (new.id, lower(new.email), r)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Technicians add/remove other technicians by email
create or replace function public.set_staff(p_email text, p_staff boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_tech() then raise exception 'Only technicians can manage the team'; end if;
  p_email := lower(trim(p_email));
  if p_email = '' then raise exception 'Enter an email'; end if;
  if p_staff then
    insert into public.staff_emails (email) values (p_email) on conflict do nothing;
    update public.profiles set role = 'tech' where email = p_email;
  else
    if p_email = (select email from public.profiles where id = auth.uid()) then
      raise exception 'You can''t remove yourself';
    end if;
    delete from public.staff_emails where email = p_email;
    update public.profiles set role = 'owner' where email = p_email;
  end if;
end $$;

-- ---------- Work ----------
create table if not exists public.jobs (
  id             text primary key,
  data           jsonb not null,
  customer_email text,
  updated_at     timestamptz not null default now(),
  updated_by     uuid default auth.uid()
);

create table if not exists public.settings (
  key        text primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);

-- Issued report revisions (locked copies, photos included) — what owners see
create table if not exists public.reports (
  id             text primary key,
  job_id         text not null,
  rev            int  not null,
  html           text not null,
  total          numeric,
  customer_email text,
  customer_name  text,
  address        text,
  issued_at      timestamptz not null default now(),
  issued_by      text
);

-- Latest estimate / invoice per job — what owners see and pay
create table if not exists public.invoices (
  job_id         text primary key,
  no             text,
  kind           text,
  status         text,
  total          numeric,
  html           text,
  customer_email text,
  customer_name  text,
  address        text,
  updated_at     timestamptz not null default now()
);

create index if not exists reports_job_idx   on public.reports (job_id);
create index if not exists reports_email_idx on public.reports (customer_email);
create index if not exists invoices_email_idx on public.invoices (customer_email);

-- ---------- Security (row level) ----------
alter table public.profiles     enable row level security;
alter table public.staff_emails enable row level security;
alter table public.jobs         enable row level security;
alter table public.settings     enable row level security;
alter table public.reports      enable row level security;
alter table public.invoices     enable row level security;

drop policy if exists "profiles read"   on public.profiles;
drop policy if exists "profiles update" on public.profiles;
create policy "profiles read"   on public.profiles for select using (id = auth.uid() or public.is_tech());
create policy "profiles update" on public.profiles for update using (id = auth.uid());
-- people can change their own name, never their own role
revoke update on public.profiles from authenticated, anon;
grant  update (name) on public.profiles to authenticated;

drop policy if exists "staff read" on public.staff_emails;
create policy "staff read" on public.staff_emails for select using (public.is_tech());

drop policy if exists "techs all" on public.jobs;
create policy "techs all" on public.jobs for all using (public.is_tech()) with check (public.is_tech());

drop policy if exists "techs all" on public.settings;
create policy "techs all" on public.settings for all using (public.is_tech()) with check (public.is_tech());

drop policy if exists "techs all"   on public.reports;
drop policy if exists "owners read" on public.reports;
create policy "techs all"   on public.reports for all using (public.is_tech()) with check (public.is_tech());
create policy "owners read" on public.reports for select using (customer_email = lower(auth.jwt() ->> 'email'));

drop policy if exists "techs all"   on public.invoices;
drop policy if exists "owners read" on public.invoices;
create policy "techs all"   on public.invoices for all using (public.is_tech()) with check (public.is_tech());
create policy "owners read" on public.invoices for select using (customer_email = lower(auth.jwt() ->> 'email'));

-- ---------- Photo storage (private) ----------
insert into storage.buckets (id, name, public) values ('photos', 'photos', false)
on conflict (id) do nothing;

drop policy if exists "techs photos" on storage.objects;
create policy "techs photos" on storage.objects for all
  using (bucket_id = 'photos' and public.is_tech())
  with check (bucket_id = 'photos' and public.is_tech());

-- ---------- Live updates between devices ----------
do $$ begin
  begin alter publication supabase_realtime add table public.jobs;     exception when others then null; end;
  begin alter publication supabase_realtime add table public.settings; exception when others then null; end;
end $$;

select 'Sprinkler Wrangler setup complete' as result;

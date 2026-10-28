-- =====================================================================
-- Sprinkler Wrangler — update 2: Admins
-- Admins (owner/developer) change prices and manage the team.
-- Technicians do jobs and see prices but can't change them.
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- =====================================================================

alter table public.profiles add column if not exists is_admin boolean not null default false;

-- Whoever is already a technician right now (the first account) becomes admin
update public.profiles set is_admin = true
where role = 'tech' and not exists (select 1 from public.profiles where is_admin);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'tech' and is_admin);
$$;

-- New sign-ups: very first account = technician + admin
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare r text; adm boolean := false;
begin
  if not exists (select 1 from public.profiles where role = 'tech') then r := 'tech'; adm := true;
  elsif exists (select 1 from public.staff_emails where email = lower(new.email)) then r := 'tech';
  else r := 'owner';
  end if;
  insert into public.profiles (id, email, role, is_admin) values (new.id, lower(new.email), r, adm)
  on conflict (id) do nothing;
  return new;
end $$;

-- Only admins add/remove technicians
create or replace function public.set_staff(p_email text, p_staff boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can manage the team'; end if;
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
    update public.profiles set role = 'owner', is_admin = false where email = p_email;
  end if;
end $$;

-- Only admins make or remove admins; there must always be one admin left
create or replace function public.set_admin(p_email text, p_admin boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can change admin access'; end if;
  p_email := lower(trim(p_email));
  if p_admin then
    if not exists (select 1 from public.profiles where email = p_email and role = 'tech') then
      raise exception 'Add them as a technician and have them sign up first';
    end if;
    update public.profiles set is_admin = true where email = p_email;
  else
    if (select count(*) from public.profiles where is_admin and role = 'tech') <= 1
       and exists (select 1 from public.profiles where email = p_email and is_admin) then
      raise exception 'There must always be at least one admin';
    end if;
    update public.profiles set is_admin = false where email = p_email;
  end if;
end $$;

-- Prices & business settings: technicians read, only admins write
drop policy if exists "techs all"    on public.settings;
drop policy if exists "techs read"   on public.settings;
drop policy if exists "admins write" on public.settings;
create policy "techs read"   on public.settings for select using (public.is_tech());
create policy "admins write" on public.settings for all    using (public.is_admin()) with check (public.is_admin());

-- people still can only change their own name
revoke update on public.profiles from authenticated, anon;
grant  update (name) on public.profiles to authenticated;

select 'Admin update complete' as result,
       (select string_agg(email, ', ') from public.profiles where is_admin) as admins;

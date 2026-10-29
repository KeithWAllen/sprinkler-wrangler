-- =====================================================================
-- Sprinkler Wrangler: chief admin + job assignment
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again.
--
-- Chief admin (Keith, the developer):
--   * the only one who can delete jobs (and their reports & invoices)
--   * the only one who can make or remove admins
--   * can't be removed or demoted by anyone else
-- Admins (Bradley, dispatch): customers, creating/assigning jobs, prices, adding technicians
-- =====================================================================

alter table public.profiles add column if not exists is_chief boolean not null default false;

-- The chief is the very first admin account (the one that set the app up).
update public.profiles set is_chief = true
where id = (select id from public.profiles where is_admin order by created_at limit 1)
  and not exists (select 1 from public.profiles where is_chief);

create or replace function public.is_chief() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'tech' and is_admin and is_chief);
$$;

-- Only the chief can make or remove admins; nobody can change the chief.
create or replace function public.set_admin(p_email text, p_admin boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_chief() then raise exception 'Only the chief admin can change admin access'; end if;
  p_email := lower(trim(p_email));
  if exists (select 1 from public.profiles where email = p_email and is_chief) then
    raise exception 'The chief admin can''t be changed';
  end if;
  if p_admin then
    if not exists (select 1 from public.profiles where email = p_email and role = 'tech') then
      raise exception 'Add them to the team and have them sign up first';
    end if;
    update public.profiles set is_admin = true where email = p_email;
  else
    update public.profiles set is_admin = false where email = p_email;
  end if;
end $$;

-- Admins can add/remove technicians, but only the chief can remove an admin, and nobody can remove the chief.
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
    if exists (select 1 from public.profiles where email = p_email and is_chief) then
      raise exception 'The chief admin can''t be removed';
    end if;
    if exists (select 1 from public.profiles where email = p_email and is_admin) and not public.is_chief() then
      raise exception 'Only the chief admin can remove an admin';
    end if;
    delete from public.staff_emails where email = p_email;
    update public.profiles set role = 'owner', is_admin = false where email = p_email;
  end if;
end $$;

-- Jobs: the team can read, add and edit; only the chief can delete.
drop policy if exists "techs all"    on public.jobs;
drop policy if exists "team read"    on public.jobs;
drop policy if exists "team add"     on public.jobs;
drop policy if exists "team edit"    on public.jobs;
drop policy if exists "chief delete" on public.jobs;
create policy "team read"    on public.jobs for select using (public.is_tech());
create policy "team add"     on public.jobs for insert with check (public.is_tech());
create policy "team edit"    on public.jobs for update using (public.is_tech()) with check (public.is_tech());
-- (A technician may also delete a job he started himself by mistake, while it's still empty.)
create policy "chief delete" on public.jobs for delete using (
  public.is_chief()
  or (public.is_tech()
      and data->>'createdBy' = auth.uid()::text
      and jsonb_array_length(coalesce(data->'controllers', '[]'::jsonb)) = 0
      and jsonb_array_length(coalesce(data->'revs', '[]'::jsonb)) = 0));

-- Issued reports & invoices: same rule.
do $$ declare t text; begin
  foreach t in array array['reports','invoices'] loop
    execute format('drop policy if exists "techs all" on public.%I', t);
    execute format('drop policy if exists "team read" on public.%I', t);
    execute format('drop policy if exists "team add" on public.%I', t);
    execute format('drop policy if exists "team edit" on public.%I', t);
    execute format('drop policy if exists "chief delete" on public.%I', t);
    execute format('create policy "team read" on public.%I for select using (public.is_tech())', t);
    execute format('create policy "team add" on public.%I for insert with check (public.is_tech())', t);
    execute format('create policy "team edit" on public.%I for update using (public.is_tech()) with check (public.is_tech())', t);
    execute format('create policy "chief delete" on public.%I for delete using (public.is_chief())', t);
  end loop;
end $$;

select 'Chief admin update complete' as result,
       (select email from public.profiles where is_chief) as chief_admin,
       (select string_agg(email, ', ') from public.profiles where is_admin and not is_chief) as other_admins;

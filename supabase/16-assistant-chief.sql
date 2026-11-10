-- =====================================================================
-- Sprinkler Wrangler: assistant chief
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again.
--
-- Assistant chief (e.g. Bradley, the company owner):
--   * an admin who can also DELETE jobs (with their reports & invoices) and customers
--   * can NOT make or remove admins or change the chief (those stay with the chief admin, Keith)
-- Only the chief admin can make someone an assistant chief, and only an admin of the same company.
-- =====================================================================

alter table public.profiles add column if not exists can_delete boolean not null default false;

-- Who may delete: the chief, or an admin the chief made assistant chief.
create or replace function public.can_delete() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'tech' and is_admin and (is_chief or can_delete));
$$;

-- Jobs: chief / assistant chief, or a technician removing an empty job he started by mistake.
drop policy if exists "chief delete" on public.jobs;
create policy "chief delete" on public.jobs for delete using (
  public.can_delete()
  or (public.is_tech()
      and data->>'createdBy' = auth.uid()::text
      and jsonb_array_length(coalesce(data->'controllers', '[]'::jsonb)) = 0
      and jsonb_array_length(coalesce(data->'revs', '[]'::jsonb)) = 0));

-- Reports, invoices and customers: chief or assistant chief.
do $$ declare t text; begin
  foreach t in array array['reports','invoices','customers'] loop
    execute format('drop policy if exists "chief delete" on public.%I', t);
    execute format('create policy "chief delete" on public.%I for delete using (public.can_delete())', t);
  end loop;
end $$;

-- Only the chief can give or take assistant-chief rights.
create or replace function public.set_assistant_chief(p_email text, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_chief() then raise exception 'Only the chief admin can change assistant chief rights'; end if;
  p_email := lower(trim(p_email));
  if exists (select 1 from public.profiles where lower(email) = p_email and is_chief) then
    raise exception 'The chief admin already has these rights';
  end if;
  update public.profiles set can_delete = p_on
   where lower(email) = p_email and is_admin and role = 'tech'
     and company_id = (select company_id from public.profiles where id = auth.uid());
  if not found then raise exception 'Make them an admin first'; end if;
end $$;
revoke all on function public.set_assistant_chief(text, boolean) from public;
grant execute on function public.set_assistant_chief(text, boolean) to authenticated;
grant execute on function public.can_delete() to authenticated;

select 'Assistant chief update complete' as result;

-- =====================================================================
-- Sprinkler Wrangler — update 3: team privacy
-- Technicians see only their own account. Only admins see the team list
-- (names and emails) and the invited-technician list.
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- =====================================================================

drop policy if exists "profiles read" on public.profiles;
create policy "profiles read" on public.profiles for select
  using (id = auth.uid() or public.is_admin());

drop policy if exists "staff read" on public.staff_emails;
create policy "staff read" on public.staff_emails for select
  using (public.is_admin());

select 'Team privacy update complete' as result;

-- Sprinkler Wrangler: let the sign-up page show the current Terms of Service.
-- Anyone (even before signing in) may READ only the 'terms' row of settings.
-- Prices stay technician-only; only admins can change any setting.
drop policy if exists "terms public read" on public.settings;
create policy "terms public read" on public.settings
  for select to anon, authenticated
  using (key = 'terms');

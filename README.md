# Sprinkler Wrangler

Field app for evaluating irrigation jobs in Texas: mainline, controller and zone inspections, property map, required trouble photos, customer report with revisions, and estimates/invoices with the TCEQ notice.

## Hosting
Static site. Vercel deploys it straight from this repo — no build step. `index.html` is the whole app.

## Data (current phase)
Jobs, pricing, revisions and photos are saved in the browser on the device being used (localStorage + IndexedDB). Nothing syncs between devices yet.

## Next phase
Supabase for email-code sign-in (technicians and property owners), synced jobs, private photo storage and the owner portal.

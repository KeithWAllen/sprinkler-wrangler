# Company accounts + importing customers

## What changed
- **Company accounts.** Every job, customer, invoice, price sheet and setting now belongs to one company. The database keeps companies completely apart. Bradley's business is company #1, and everyone already using the app is in it. This is the foundation for selling subscriptions to other irrigation businesses later.
- **Private notes stay private.** Customers with a portal account can no longer read their own full record, so notes and gate codes are team-only. The portal shows them a safe card (name, contact, addresses).
- **Several properties per customer.** Each customer can have a main property plus any number of others, and each property has its own gate code, type, notes and job history. When you start a new job, the app asks which property.
- **Bill to.** Any property can bill someone else, such as a property manager, project manager or LLC. Estimates and invoices then show "Bill to" separately from the service address, and emails go to the Bill-to contact.
- **Customer import.** Customers → **Import customers** reads a Zoho export (or a similar spreadsheet) and shows a preview before anything is saved.
- **Property-type check.** After an import, the Customers page lists every property so Bradley can switch commercial ones.

## Steps
1. **Back up first.** Admin settings → **Download data backup**.
2. **Run the database update.** In Supabase, open **SQL Editor → New query**, paste all of `supabase/14-companies.sql`, and click **Run**. If Supabase warns that the query has destructive operations, choose **Run this query**. (The warning is about replacing old security rules; no data is deleted.) You should see "Companies update complete".
3. **Reload the app** and check that jobs, customers and prices all look the same.
4. **Import.** Customers → **Import customers** → choose the Zoho file → review the preview → **Import**.
5. **Property types.** On the Customers page, open **Check property types**, switch any commercial properties, and tap **Confirm**.

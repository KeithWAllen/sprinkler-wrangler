# Turning on online payments (Stripe)

Customers get a **Pay now** button on unpaid invoices in their account. They pay by card or bank transfer (ACH) through your existing Stripe account, and the payment lands on the invoice by itself.

You keep every secret key yourself. They go into Supabase and Stripe, never into the app or a chat.

Do the whole setup in **Stripe test mode** first. Switch to live mode when a test payment works end to end.

---

## 1. Run the database update
In Supabase, open **SQL Editor → New query**, paste all of `supabase/12-invoices-payments.sql`, and click **Run**.

## 2. Create the two functions
In Supabase, open **Edge Functions → Deploy a new function → Via editor**.

1. Name it `create-checkout`, paste all of `supabase/functions/create-checkout/index.ts`, and click **Deploy**.
2. Create a second function named `stripe-webhook` and paste `supabase/functions/stripe-webhook/index.ts`.
   - Open its **Settings** and turn **"Verify JWT with legacy secret" / "Enforce JWT verification" OFF**. Stripe can't sign in to Supabase, and the function checks Stripe's own signature instead.
   - Deploy.

## 3. Add your Stripe secret key to Supabase
1. In Stripe, open **Developers → API keys**.
2. Create a **restricted key** with the **Checkout Sessions: Write** permission. A restricted key is safer than the full secret key.
3. In Supabase, open **Edge Functions → Secrets** and add:
   - `STRIPE_SECRET_KEY` = the restricted key. It starts with `rk_test_` in test mode and `rk_live_` in live mode.
   - `SITE_URL` = `https://sprinkler-wrangler.vercel.app`

## 4. Tell Stripe where to send "paid" notices
1. In Stripe, open **Developers → Webhooks → Add endpoint**.
2. Set the endpoint URL to `https://jbqcjindvjmswdcuavme.supabase.co/functions/v1/stripe-webhook`.
3. Select these events:
   - `checkout.session.completed`
   - `checkout.session.async_payment_succeeded`
   - `checkout.session.async_payment_failed`
4. Save. Then copy the endpoint's **Signing secret** (starts with `whsec_`).
5. In Supabase **Edge Functions → Secrets**, add `STRIPE_WEBHOOK_SECRET` = that signing secret.

## 5. Payment methods: nothing to change
Checkout offers whatever payment methods are already turned on in your Stripe account's own settings (card, and ACH if you use it). No changes are needed.

## 6. Switch it on in the app
In **Admin settings → Invoices & payments**, set **Online payments through Stripe** to **On**.

## 7. Test it
1. Make an invoice for a test customer and **Email invoice** or **Mark as sent**.
2. Sign in as that customer and tap **Pay now**.
3. Pay with Stripe's test card `4242 4242 4242 4242`, any future date and any CVC.
4. Within a minute or two, the invoice shows **Paid** for the customer. The team's app records the payment on the invoice ledger as "paid online".

## 8. Go live
Repeat steps 3 and 4 with your **live** Stripe keys, a new restricted key and a new webhook endpoint in live mode. Then replace both secrets in Supabase.

---

### Notes
- **Bank (ACH) payments** take a few business days to clear. The invoice updates when Stripe confirms them.
- **Fees** are Stripe's standard rates. For year-end, Stripe's processing fees and its 1099-K are under **Stripe → Reports**.
- **Refunds and disputes** are handled in the Stripe dashboard. Record a matching adjustment on the invoice.

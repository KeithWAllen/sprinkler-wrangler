# Customer links (no login) for estimates and invoices

Bradley sends each estimate or invoice as a private link, by email or text. The customer opens it with **no account or password**.

- **Estimate link:** the customer accepts or declines each item, sees the total, types their name, signs with a finger and ticks the approval statement. The answer comes back into the job by itself, on the Status tab, and the job shows as approved.
- **Invoice link:** the customer views and prints the invoice and taps **Pay now** (Stripe).

**Legal basis.** Under the federal ESIGN Act and the Texas Uniform Electronic Transactions Act (Bus. & Com. Code ch. 322), an electronic signature is valid when:
1. The person shows intent to sign.
2. The person agrees to sign electronically.
3. The signature can be tied to the person.
4. A record is kept.

The link page records the customer's typed name, signature, choices, date and time, device and internet address, plus the exact estimate version they saw. They can print or save a copy.

---

## 1. Run the database update
In Supabase, open **SQL Editor → New query**, paste all of `supabase/13-share-links.sql`, and click **Run**. You should see "Share links update complete".

## 2. Update the payment function
In Supabase, open **Edge Functions → create-checkout → Code**. Replace all the code with `supabase/functions/create-checkout/index.ts` and click **Deploy**. This lets **Pay now** work from an invoice link.

## 3. Try it
1. Open a job, go to the **Estimate** tab and create the estimate.
2. Under **Send to the customer**, tap **Copy link** and open the link on your phone in a private/incognito window.
3. Accept or decline the items, sign, and tap **Approve and sign**.
4. Back in the app, within a minute or two (or after a refresh), the Estimate tab shows **"… approved online"**, and the Status tab shows the signed confirmation.

## How links behave
- **Estimate links last 30 days.** Invoice links last a year.
- **If the estimate changes after the link was sent,** the old link tells the customer it was updated. Tapping Email, Text or Copy link again makes a fresh link.
- **Each estimate link can be answered once.** To change an answer, the customer contacts Bradley.
- **Links are long and random,** so they can't be guessed. Anyone holding a link can see that one document, the same as Jobber or Zoho links. That's why the page asks customers not to forward it.

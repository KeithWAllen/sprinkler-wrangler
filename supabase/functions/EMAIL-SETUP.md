# Sending emails from the app (Gmail)

With this on, **Send now** in the app's email window emails estimates, invoices and payment reminders straight from the company Gmail (sprinklerwrangler@gmail.com). No other app opens. The customer gets an email with a big **View & pay invoice** (or **Review & approve estimate**) button, which works on iPhones.

The email shows in that Gmail's **Sent** folder, and customer replies come back to the same inbox. Gmail allows about 500 emails a day.

The Gmail password never goes into the app or a chat. Only a Gmail **app password** goes into Supabase's private secrets.

---

## 1. Turn on 2-Step Verification (Bradley, on the Gmail account)
1. Sign in to sprinklerwrangler@gmail.com and open **myaccount.google.com/security**.
2. Under **How you sign in to Google**, turn on **2-Step Verification** and follow the prompts.

## 2. Make an app password
1. Open **myaccount.google.com/apppasswords** (signed in as sprinklerwrangler@gmail.com).
2. Type a name such as `Sprinkler Wrangler` and tap **Create**.
3. Google shows a 16-letter code. Keep that screen open for step 4. Google won't show it again; if it's lost, delete it and make a new one.

## 3. Create the function
In Supabase, open **Edge Functions → Deploy a new function → Via editor**.
1. Name it `send-email`.
2. Paste all of `supabase/functions/send-email/index.ts`.
3. Leave JWT verification **on** (only signed-in team members may send).
4. Click **Deploy**.

## 4. Add the two secrets
In Supabase, open **Edge Functions → Secrets** and add:
- `GMAIL_USER` = `sprinklerwrangler@gmail.com`
- `GMAIL_APP_PASSWORD` = the 16-letter code from step 2 (spaces are fine)

## 5. Switch it on in the app
In **Admin settings → Invoices & payments**:
1. Set **Send emails from the app** to **On**.
2. Type `sprinklerwrangler@gmail.com` in **Sending address** (this is only the label the team sees).

## 6. Test it
1. Open a job with an invoice and set the customer email to your own address.
2. Tap **Email**, then **Send now**.
3. You should see "Email sent", the invoice is marked as sent, and the email arrives with the button. It also shows in sprinklerwrangler@gmail.com → Sent.

---

### If something goes wrong
- **"Gmail rejected the app password"**: re-check both secrets. Make a fresh app password if needed.
- **"email sending isn't set up yet"**: the function isn't deployed, or the secrets are missing.
- To stop sending from the app, set **Send emails from the app** to **Off**. The email window goes back to opening the phone's email app.
- If the Gmail password is ever changed, Google cancels app passwords. Make a new one and update `GMAIL_APP_PASSWORD`.

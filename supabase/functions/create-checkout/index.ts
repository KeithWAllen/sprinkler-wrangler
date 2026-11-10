// Sprinkler Wrangler: start a Stripe Checkout payment for one invoice.
// Called by the "Pay now" button in the customer portal (signed in) or on an invoice link (no login).
// The amount always comes from the database, never from the browser.
// - Portal: the invoice is read AS THE SIGNED-IN CUSTOMER, so the database's own rules decide.
// - Link:   the invoice is found only through the link's long random token (share_invoice()).
// Secrets (Supabase → Edge Functions → Secrets): STRIPE_SECRET_KEY, SITE_URL (optional)

const SITE = Deno.env.get("SITE_URL") ?? "https://sprinkler-wrangler.vercel.app";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const auth = req.headers.get("Authorization") ?? "";
    const { job_id, token } = await req.json().catch(() => ({}));
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    let r: Response;
    if (token) {
      // Server-side key (built into every Supabase function); only used to call share_invoice().
      const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? anon;
      r = await fetch(`${url}/rest/v1/rpc/share_invoice`, {
        method: "POST",
        headers: { apikey: svc, Authorization: `Bearer ${svc}`, "Content-Type": "application/json" },
        body: JSON.stringify({ p_token: String(token) }),
      });
    } else {
      if (!job_id || !auth) return json({ error: "Missing invoice." }, 400);
      r = await fetch(
        `${url}/rest/v1/invoices?job_id=eq.${encodeURIComponent(job_id)}&select=job_id,no,kind,status,total,balance,customer_email,pay_online`,
        { headers: { apikey: anon, Authorization: auth } },
      );
    }
    const rows = await r.json();
    const inv = Array.isArray(rows) ? rows[0] : null;
    if (!inv) return json({ error: "Invoice not found." }, 404);
    if (inv.kind !== "invoice" || !inv.pay_online || !["sent", "partial", "pastdue"].includes(inv.status)) {
      return json({ error: "This invoice can't be paid online. Please use the contact details on the invoice." }, 400);
    }
    const cents = Math.round(Number(inv.balance ?? inv.total) * 100);
    if (!(cents >= 50)) return json({ error: "Nothing is due on this invoice." }, 400);

    const f = new URLSearchParams();
    f.set("mode", "payment");
    // Card and US bank transfer (ACH) only (Bradley): no Cash App, Affirm, Klarna, Amazon Pay or other
    // wallets, whatever is switched on in the Stripe account. If ACH isn't turned on there, it falls back to card only.
    f.set("line_items[0][quantity]", "1");
    f.set("line_items[0][price_data][currency]", "usd");
    f.set("line_items[0][price_data][unit_amount]", String(cents));
    f.set("line_items[0][price_data][product_data][name]", `Invoice ${inv.no}`);
    if (inv.customer_email) f.set("customer_email", inv.customer_email);
    f.set("metadata[job_id]", inv.job_id);
    f.set("metadata[invoice_no]", inv.no ?? "");
    f.set("payment_intent_data[metadata][job_id]", inv.job_id);
    f.set("payment_intent_data[description]", `Invoice ${inv.no}`);
    if (token) {
      f.set("success_url", `${SITE}/#s=${encodeURIComponent(token)}&paid=1`);
      f.set("cancel_url", `${SITE}/#s=${encodeURIComponent(token)}`);
    } else {
      f.set("success_url", `${SITE}/?paid=${encodeURIComponent(inv.job_id)}`);
      f.set("cancel_url", `${SITE}/`);
    }

    const create = (types: string[]) => {
      const g = new URLSearchParams(f);
      types.forEach((t, i) => g.set(`payment_method_types[${i}]`, t));
      return fetch("https://api.stripe.com/v1/checkout/sessions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${Deno.env.get("STRIPE_SECRET_KEY")}`,
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: g,
      });
    };
    let s = await create(["card", "us_bank_account"]);
    let sess = await s.json();
    if (!s.ok && /us_bank_account|payment method type/i.test(sess?.error?.message ?? "")) {
      s = await create(["card"]);
      sess = await s.json();
    }
    if (!s.ok) return json({ error: sess?.error?.message ?? "Stripe error" }, 502);
    return json({ url: sess.url });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

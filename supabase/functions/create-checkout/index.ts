// Sprinkler Wrangler: start a Stripe Checkout payment for one invoice.
// Called by the customer portal's "Pay now" button. The amount always comes from the database,
// never from the browser. The invoice is read AS THE SIGNED-IN CUSTOMER, so the database's own
// rules decide whether they may pay it.
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
    const { job_id } = await req.json().catch(() => ({}));
    if (!job_id || !auth) return json({ error: "Missing invoice." }, 400);

    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const r = await fetch(
      `${url}/rest/v1/invoices?job_id=eq.${encodeURIComponent(job_id)}&select=job_id,no,kind,status,total,balance,customer_email,pay_online`,
      { headers: { apikey: anon, Authorization: auth } },
    );
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
    f.append("payment_method_types[]", "card");
    f.append("payment_method_types[]", "us_bank_account");
    f.set("line_items[0][quantity]", "1");
    f.set("line_items[0][price_data][currency]", "usd");
    f.set("line_items[0][price_data][unit_amount]", String(cents));
    f.set("line_items[0][price_data][product_data][name]", `Invoice ${inv.no}`);
    if (inv.customer_email) f.set("customer_email", inv.customer_email);
    f.set("metadata[job_id]", inv.job_id);
    f.set("metadata[invoice_no]", inv.no ?? "");
    f.set("payment_intent_data[metadata][job_id]", inv.job_id);
    f.set("payment_intent_data[description]", `Invoice ${inv.no}`);
    f.set("success_url", `${SITE}/?paid=${encodeURIComponent(inv.job_id)}`);
    f.set("cancel_url", `${SITE}/`);

    const s = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${Deno.env.get("STRIPE_SECRET_KEY")}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: f,
    });
    const sess = await s.json();
    if (!s.ok) return json({ error: sess?.error?.message ?? "Stripe error" }, 502);
    return json({ url: sess.url });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

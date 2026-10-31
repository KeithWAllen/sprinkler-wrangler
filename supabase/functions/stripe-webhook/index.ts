// Sprinkler Wrangler: Stripe tells us when an invoice is paid.
// Verifies Stripe's signature, then records the payment once (database function record_stripe_payment).
// Card payments arrive as checkout.session.completed; bank (ACH) payments as
// checkout.session.async_payment_succeeded a few days later.
// Secrets: STRIPE_WEBHOOK_SECRET. Deploy with "Verify JWT" turned OFF (Stripe has no Supabase login).

const enc = new TextEncoder();

async function verify(body: string, header: string, secret: string): Promise<boolean> {
  const parts = header.split(",").map((p) => p.split("="));
  const t = parts.find(([k]) => k === "t")?.[1];
  const sigs = parts.filter(([k]) => k === "v1").map(([, v]) => v);
  if (!t || !sigs.length) return false;
  if (Math.abs(Date.now() / 1000 - Number(t)) > 300) return false; // older than 5 minutes
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${body}`));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return sigs.includes(hex);
}

Deno.serve(async (req) => {
  const body = await req.text();
  const ok = await verify(body, req.headers.get("stripe-signature") ?? "", Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "");
  if (!ok) return new Response("bad signature", { status: 400 });

  const ev = JSON.parse(body);
  const s = ev?.data?.object ?? {};
  const paid = (ev.type === "checkout.session.completed" && s.payment_status === "paid") ||
    ev.type === "checkout.session.async_payment_succeeded";

  if (paid && s.metadata?.job_id) {
    const url = Deno.env.get("SUPABASE_URL")!;
    const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!; // provided to Edge Functions by Supabase
    const r = await fetch(`${url}/rest/v1/rpc/record_stripe_payment`, {
      method: "POST",
      headers: { apikey: svc, Authorization: `Bearer ${svc}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        p_job_id: s.metadata.job_id,
        p_amount: (s.amount_total ?? 0) / 100,
        p_ref: s.id,
        p_method: ev.type === "checkout.session.async_payment_succeeded" ? "Bank (ACH)" : "Card",
      }),
    });
    if (!r.ok) return new Response("database error", { status: 500 }); // Stripe will retry
  }
  return new Response("ok");
});

// Sprinkler Wrangler: send an email to a customer from the company Gmail.
// Called by "Send now" in the app's email window (estimates, invoices, payment reminders).
// - Only signed-in team members (technicians, office, admins) can send. Customers can't.
// - Sends through Gmail with an app password, so the email lands in that Gmail's Sent folder
//   and customer replies come back to the same inbox.
// - The link to the estimate/invoice becomes a big button, which works on iPhones
//   (iPhones block links texted from unknown numbers, but not links in email).
// Secrets (Supabase → Edge Functions → Secrets): GMAIL_USER, GMAIL_APP_PASSWORD
// Supabase blocks outgoing ports 25 and 587, so this uses Gmail's port 465 (SSL).

import nodemailer from "npm:nodemailer@6.9.16";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const EMAIL_RE = /^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$/;

// Plain-text message → simple, phone-friendly HTML. The line holding the link becomes a button.
function toHtml(text: string, link: string, button: string, biz: string): string {
  const paras = text.split(/\n{2,}/).map((p) => {
    const t = p.trim();
    if (link && t === link) return btn(link, button);
    if (link && t.includes(link)) {
      const rest = t.split(link).map((x) => x.trim().replace(/[:\s]+$/, "")).filter(Boolean).join(" ");
      return (rest ? `<p style="margin:0 0 16px">${esc(rest).replace(/\n/g, "<br>")}</p>` : "") + btn(link, button);
    }
    return `<p style="margin:0 0 16px">${esc(t).replace(/\n/g, "<br>")}</p>`;
  }).join("");
  return `<!doctype html><html><body style="margin:0;padding:0;background:#EEF2EE">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#EEF2EE;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:12px;overflow:hidden">
<tr><td style="background:#1D6B47;color:#ffffff;padding:16px 24px;font:700 20px Arial,Helvetica,sans-serif">${esc(biz || "Sprinkler Wrangler")}</td></tr>
<tr><td style="padding:24px;font:16px/1.5 Arial,Helvetica,sans-serif;color:#16211A">${paras}</td></tr>
</table></td></tr></table></body></html>`;
}
function btn(link: string, label: string): string {
  return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 20px"><tr><td style="background:#1D6B47;border-radius:8px">
<a href="${esc(link)}" style="display:inline-block;padding:14px 26px;color:#ffffff;text-decoration:none;font:700 17px Arial,Helvetica,sans-serif">${esc(label || "Open")}</a></td></tr></table>
<p style="margin:0 0 16px;font-size:13px;color:#58665C">If the button doesn't work, copy this link into your browser:<br><a href="${esc(link)}" style="color:#1D6B47;word-break:break-all">${esc(link)}</a></p>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const auth = req.headers.get("Authorization") ?? "";
    if (!auth) return json({ error: "Please sign in again." }, 401);
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;

    // Team members only: ask the database, as the signed-in person, whether they're a technician/staff.
    const r = await fetch(`${url}/rest/v1/rpc/is_tech`, {
      method: "POST",
      headers: { apikey: anon, Authorization: auth, "Content-Type": "application/json" },
      body: "{}",
    });
    if (!r.ok || (await r.json()) !== true) return json({ error: "Only the team can send emails." }, 403);

    const user = Deno.env.get("GMAIL_USER");
    const pass = (Deno.env.get("GMAIL_APP_PASSWORD") ?? "").replace(/\s+/g, "");
    if (!user || !pass) return json({ error: "email sending isn't set up yet (Gmail secrets missing)" }, 500);

    const b = await req.json().catch(() => ({}));
    const to = String(b.to ?? "").trim();
    const subject = String(b.subject ?? "").replace(/[\r\n]+/g, " ").trim().slice(0, 200);
    const text = String(b.text ?? "").slice(0, 20000);
    const link = String(b.link ?? "").trim();
    const button = String(b.button ?? "").slice(0, 60);
    const fromName = String(b.from_name ?? "").replace(/["\r\n<>]/g, "").trim().slice(0, 80);
    if (!EMAIL_RE.test(to)) return json({ error: "That email address doesn't look right." }, 400);
    if (!subject || !text) return json({ error: "The email needs a subject and a message." }, 400);
    if (link && !/^https:\/\//.test(link)) return json({ error: "Bad link." }, 400);

    const mail = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user, pass } });
    await mail.sendMail({
      from: fromName ? `"${fromName}" <${user}>` : user,
      to,
      replyTo: user,
      subject,
      text,
      html: toHtml(text, link, button, fromName),
    });
    return json({ ok: true });
  } catch (e) {
    const msg = String((e as Error)?.message ?? e);
    if (/535|Username and Password not accepted|Invalid login/i.test(msg)) {
      return json({ error: "Gmail rejected the app password. Check GMAIL_USER and GMAIL_APP_PASSWORD." }, 502);
    }
    return json({ error: msg }, 500);
  }
});

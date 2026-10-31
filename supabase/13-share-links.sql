-- =====================================================================
-- Sprinkler Wrangler: no-login share links for estimates and invoices
-- Run once in Supabase: SQL Editor → New query → paste all → Run.
-- Safe to run again.
--
-- A link looks like  https://sprinkler-wrangler.vercel.app/#s=<long random token>
-- Anyone holding the link can view that ONE document (like Jobber / Zoho links).
-- Customers approve estimates there with their name, a finger signature and an
-- approval statement (ESIGN Act + Texas UETA, Bus. & Com. Code ch. 322).
-- The tables are team-only; the public can reach them only through the
-- three functions below, and only with the exact token.
-- =====================================================================

create table if not exists public.share_links (
  token       text primary key check (length(token) >= 24),
  job_id      text not null,
  kind        text not null check (kind in ('estimate', 'invoice')),
  doc_no      text,
  html        text,                       -- the document exactly as the customer sees it
  items       jsonb not null default '[]',-- estimate lines the customer accepts or declines
  meta        jsonb not null default '{}',-- business, customer, fee, tax rate
  fp          text,                       -- version of the estimate the link shows
  status      text not null default 'open' check (status in ('open', 'answered', 'replaced', 'void')),
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz,
  viewed_at   timestamptz,
  view_count  int not null default 0,
  answered_at timestamptz
);
create index if not exists share_links_job on public.share_links (job_id, kind);
alter table public.share_links enable row level security;
drop policy if exists "team manage share links" on public.share_links;
create policy "team manage share links" on public.share_links for all using (public.is_tech()) with check (public.is_tech());

create table if not exists public.share_responses (
  id         bigserial primary key,
  token      text not null references public.share_links (token) on delete cascade,
  job_id     text not null,
  kind       text not null,
  fp         text,
  items      jsonb not null,             -- [[line key, "accept" | "decline"], ...]
  name       text not null,
  signature  text not null,              -- PNG of the finger signature
  agreed     boolean not null,
  total      numeric,
  user_agent text,
  ip         text,
  created_at timestamptz not null default now(),
  imported   boolean not null default false
);
alter table public.share_responses enable row level security;
drop policy if exists "team read share responses" on public.share_responses;
drop policy if exists "team mark share responses" on public.share_responses;
create policy "team read share responses" on public.share_responses for select using (public.is_tech());
create policy "team mark share responses" on public.share_responses for update using (public.is_tech()) with check (public.is_tech());
-- No insert policy: customers can only answer through submit_share() below.

-- Open a link: returns the document (and the live invoice balance) for that token only.
create or replace function public.get_share(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.share_links; inv public.invoices; r public.share_responses;
begin
  if p_token is null or length(p_token) < 24 then return null; end if;
  select * into l from public.share_links where token = p_token;
  if not found then return null; end if;
  update public.share_links set viewed_at = coalesce(viewed_at, now()), view_count = view_count + 1 where token = p_token;
  if l.status = 'void' then return jsonb_build_object('status', 'void'); end if;
  if l.status = 'replaced' then return jsonb_build_object('status', 'replaced', 'kind', l.kind, 'doc_no', l.doc_no, 'meta', l.meta); end if;
  select * into r from public.share_responses where token = p_token order by created_at desc limit 1;
  if l.kind = 'invoice' then select * into inv from public.invoices where job_id = l.job_id; end if;
  return jsonb_build_object(
    'status', case when l.status = 'open' and l.expires_at is not null and l.expires_at < now() then 'expired' else l.status end,
    'kind', l.kind, 'doc_no', l.doc_no, 'html', l.html, 'items', l.items, 'meta', l.meta, 'created_at', l.created_at,
    'expires_at', l.expires_at,
    'answer', case when r.id is null then null else jsonb_build_object('name', r.name, 'at', r.created_at, 'items', r.items, 'total', r.total) end,
    'invoice', case when inv.job_id is null then null else jsonb_build_object(
      'status', inv.status, 'total', inv.total, 'balance', coalesce(inv.balance, inv.total), 'pay_online', coalesce(inv.pay_online, false), 'html', inv.html) end);
end $$;

-- Approve / decline an estimate through its link.
create or replace function public.submit_share(p_token text, p_items jsonb, p_name text, p_sig text, p_agree boolean, p_total numeric, p_ua text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.share_links; hdr json; ip text;
begin
  select * into l from public.share_links where token = p_token for update;
  if not found or l.kind <> 'estimate' then raise exception 'This link is not valid.'; end if;
  if l.status = 'answered' then raise exception 'This estimate has already been answered. Please contact us to make changes.'; end if;
  if l.status <> 'open' then raise exception 'This estimate was updated. Please ask for the new link.'; end if;
  if l.expires_at is not null and l.expires_at < now() then raise exception 'This estimate has expired. Please contact us for an updated one.'; end if;
  if coalesce(length(trim(p_name)), 0) < 3 or length(p_name) > 120 then raise exception 'Please type your full name.'; end if;
  if p_sig is null or left(p_sig, 22) <> 'data:image/png;base64,' or length(p_sig) > 400000 then raise exception 'Please sign in the box.'; end if;
  if p_agree is not true then raise exception 'Please tick the approval statement.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 300 then raise exception 'Please choose Accept or Decline for each item.'; end if;
  begin hdr := current_setting('request.headers', true)::json; exception when others then hdr := null; end;
  ip := split_part(coalesce(hdr ->> 'x-forwarded-for', hdr ->> 'x-real-ip', ''), ',', 1);
  insert into public.share_responses (token, job_id, kind, fp, items, name, signature, agreed, total, user_agent, ip)
  values (p_token, l.job_id, l.kind, l.fp, p_items, trim(p_name), p_sig, true, p_total, left(coalesce(p_ua, ''), 400), nullif(trim(ip), ''));
  update public.share_links set status = 'answered', answered_at = now() where token = p_token;
  return jsonb_build_object('ok', true, 'at', now());
end $$;

-- Used by the create-checkout function so a customer can pay an invoice from its link without signing in.
create or replace function public.share_invoice(p_token text)
returns table (job_id text, no text, kind text, status text, total numeric, balance numeric, customer_email text, pay_online boolean)
language sql security definer set search_path = public as $$
  select i.job_id, i.no, i.kind, i.status, i.total, i.balance, i.customer_email, i.pay_online
    from public.share_links l join public.invoices i on i.job_id = l.job_id
   where l.token = p_token and length(p_token) >= 24 and l.kind = 'invoice' and l.status = 'open'
     and (l.expires_at is null or l.expires_at > now());
$$;

revoke all on function public.get_share(text) from public;
revoke all on function public.submit_share(text, jsonb, text, text, boolean, numeric, text) from public;
revoke all on function public.share_invoice(text) from public;
grant execute on function public.get_share(text) to anon, authenticated;
grant execute on function public.submit_share(text, jsonb, text, text, boolean, numeric, text) to anon, authenticated;
grant execute on function public.share_invoice(text) to anon, authenticated, service_role;

select 'Share links update complete' as result;

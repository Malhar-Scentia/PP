// Triggered by a Database Webhook on INSERT into public.booking_events.
// Deploy: supabase functions deploy notify-booking --no-verify-jwt
// Secrets: RESEND_API_KEY, NOTIFY_FROM, WEBHOOK_SECRET, optional NOTIFY_TO (overrides clients.contact_email)
import { createClient } from "jsr:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

type Sess = {
  start_date: string; end_date: string; session_count: number; limited: boolean;
  locations: { name: string; is_virtual: boolean } | null;
} | null;

const pd = (s: string) => { const [y, m, d] = s.split("-").map(Number); return new Date(Date.UTC(y, m - 1, d)); };
const day = (d: Date) => d.toLocaleDateString("en-AU", { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const n = (x: number) => x.toLocaleString("en-AU");

function when(s: NonNullable<Sess>) {
  return s.start_date === s.end_date ? day(pd(s.start_date)) : `${day(pd(s.start_date))} to ${day(pd(s.end_date))}`;
}
function length(s: NonNullable<Sess>) {
  const c = s.session_count;
  if (!c) return "";
  if (s.locations?.is_virtual) return c === 1 ? "1 session" : `${c} sessions`;
  const days = Math.round((pd(s.end_date).getTime() - pd(s.start_date).getTime()) / 864e5) + 1;
  return c === 1 ? "1 day" : days === c ? `${c} days` : `${c} sessions`;
}
const describe = (s: Sess) =>
  s ? [when(s), s.locations?.name, length(s), s.limited ? "limited places" : ""].filter(Boolean).join(", ") : "";

Deno.serve(async (req) => {
  if (req.headers.get("x-webhook-secret") !== Deno.env.get("WEBHOOK_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }
  const { type, record } = await req.json();
  if (type !== "INSERT" || !record?.id) return new Response("ignored");

  const sessCols = "start_date,end_date,session_count,limited,locations(name,is_virtual)";
  const { data: ev, error } = await sb
    .from("booking_events")
    .select(`id,kind,seats_purchased,seats_used,created_at,emailed_at,
      clients(name,contact_email),
      learners(full_name,email,team),
      allocations(id,source,courses(name)),
      session:sessions!booking_events_session_id_fkey(${sessCols}),
      prev:sessions!booking_events_previous_session_id_fkey(${sessCols})`)
    .eq("id", record.id)
    .single();
  if (error || !ev) return new Response(error?.message ?? "not found", { status: 500 });
  if (ev.emailed_at) return new Response("already sent"); // webhook retries

  const client = ev.clients as unknown as { name: string; contact_email: string | null };
  const p = ev.learners as unknown as { full_name: string; email: string; team: string | null };
  const alloc = ev.allocations as unknown as { id: string; source: string; courses: { name: string } } | null;
  const course = alloc?.courses?.name ?? "Unknown course";
  const session = ev.session as unknown as Sess, prev = ev.prev as unknown as Sess;
  const remaining = Math.max(ev.seats_purchased - ev.seats_used, 0);

  const verb = { booked: "New booking", rescheduled: "Booking moved", cancelled: "Booking cancelled" }[ev.kind as string];
  const subject = `${verb}: ${course}, ${p.full_name} (${client.name})`;

  const rows: [string, string][] = [
    ["Course", course],
    ...(session ? [["Date and location", describe(session)] as [string, string]] : []),
    ...(prev ? [[ev.kind === "cancelled" ? "Cancelled date" : "Previous date", describe(prev)] as [string, string]] : []),
    ["Attendee", p.full_name],
    ["Email", p.email],
    ...(p.team ? [["Team", p.team] as [string, string]] : []),
    ["Organisation", client.name],
    ["Allocated by", alloc?.source === "self" ? "Employee self-booking" : "Client training admin"],
    ["Seats used", `${n(ev.seats_used)} of ${n(ev.seats_purchased)}`],
    ["Seats remaining", n(remaining)],
    ["Reference", alloc?.id ?? String(ev.id)],
  ];

  const text = `${verb}\n\n` + rows.map(([k, v]) => `${k}: ${v}`).join("\n");
  const html = `<!doctype html><body style="margin:0;background:#F1F3FC;font-family:Arial,Helvetica,sans-serif;color:#0A1A5C">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#fff;border-radius:10px;overflow:hidden">
<tr><td style="background:#0000CC;color:#fff;padding:20px 24px;font-size:22px;font-weight:bold">${esc(verb)}</td></tr>
<tr><td style="padding:20px 24px 8px;font-size:15px;line-height:1.5">${esc(p.full_name)} at ${esc(client.name)}: <strong>${esc(course)}</strong></td></tr>
<tr><td style="padding:8px 24px 4px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;line-height:1.45">
${rows.map(([k, v]) => `<tr><td style="padding:7px 12px 7px 0;color:#4A5378;border-bottom:1px solid #D8DCEE;width:160px;vertical-align:top">${esc(k)}</td><td style="padding:7px 0;border-bottom:1px solid #D8DCEE">${esc(v)}</td></tr>`).join("")}
</table></td></tr>
<tr><td style="padding:16px 24px 24px;font-size:13px;color:#4A5378">Reply to this email to reach ${esc(p.full_name)} directly.</td></tr>
</table></td></tr></table></body>`;

  const to = Deno.env.get("NOTIFY_TO") || client.contact_email;
  if (!to) return new Response("no recipient", { status: 500 });

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: Deno.env.get("NOTIFY_FROM"), to: [to], reply_to: p.email, subject, html, text }),
  });
  if (!res.ok) return new Response(await res.text(), { status: 502 });

  await sb.from("booking_events").update({ emailed_at: new Date().toISOString() }).eq("id", ev.id);
  return new Response("sent");
});

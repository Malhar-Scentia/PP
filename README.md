# AIM short course calendar on Supabase

```
index.html            public calendar (same UI, data from Supabase)
admin.html            client admin: people + course allocations
config.js             Supabase URL, anon key, default client slug
assets/aim-logo.png   pulled out of the inline base64
supabase/001_schema.sql
supabase/002_seed.sql generated from the original embedded DATA/CONFIG
supabase/003_self_service.sql   seats, employee booking RPCs, booking_events outbox
supabase/functions/notify-booking   emails AIM on every employee booking/change/cancel
```

## Setup

1. Run `supabase/001_schema.sql`, then `supabase/002_seed.sql` in the SQL editor.
2. Fill in `config.js` (Project Settings > API: URL + anon key).
3. Auth > URL Configuration: add the deployed `admin.html` URL to Redirect URLs.
4. Auth > Users > Invite user with the admin's email, then grant access:

   ```sql
   insert into public.client_admins (client_id, user_id)
   select c.id, u.id from public.clients c, auth.users u
   where c.slug = 'delta' and u.email = 'admin@deltagroup.com.au';
   ```
5. Run `supabase/003_self_service.sql` (sets Delta to 1,500 seats).
6. Auth > Providers > Email: keep "Allow new users to sign up" on (employees sign in with a magic link on first visit). Add the calendar URL to Redirect URLs too.
7. Email notifications (Resend; any provider works with a small change in the function):
   ```bash
   supabase secrets set RESEND_API_KEY=re_xxx NOTIFY_FROM="AIM bookings <bookings@yourdomain>" WEBHOOK_SECRET=$(openssl rand -hex 24)
   # optional: NOTIFY_TO=bookings@aim.com.au   (default: clients.contact_email)
   supabase functions deploy notify-booking --no-verify-jwt
   ```
   Database > Webhooks > Create: table `booking_events`, event `INSERT`, type Supabase Edge Function `notify-booking`, header `x-webhook-secret: <same secret>`.
8. Host the folder on any static host. Branded calendar link: `index.html?client=delta` (admin page has a "Copy booking link" button).

## Model

- `courses`, `subjects`, `locations`, `sessions`: AIM catalog, public read, edited via dashboard or service role.
- `clients`: branding/contact used by the calendar hero and footer.
- `client_admins`: which auth users manage which client. One user can manage several; admin page shows a switcher.
- `learners`: the client's people. Plain records, not auth accounts.
- `allocations`: learner to course, optionally to a specific session. `session_id = null` means "date not chosen yet". `source` is `admin` or `self`.
- `booking_events`: one row per employee book/move/cancel with a seat snapshot taken inside the same transaction. Drives the email; `emailed_at` makes webhook retries idempotent.

## Employee booking

- Access list = the admin's People list. Anyone can request a magic link, but `book_session` only works when the verified email matches a learner for that client.
- Booking a course the admin already allocated (no date) fills in the date; booking a different date for a course already booked moves the booking. Neither uses an extra seat.
- Cancelling: self-booked allocations are cancelled and the seat is freed; admin allocations just lose the date and keep the seat. Same-day or past sessions can't be cancelled from the calendar.

## Seats

- Every non-cancelled allocation holds one seat, dated or not.
- Enforced by a trigger on `allocations` that locks the client row, so admin inserts and concurrent employee bookings can't oversell. Batch admin inserts fail whole if they exceed the remaining count.
- `seats_purchased` is hidden from the browser by column grants; admins read it through `seat_summary()`. Top-ups: `update clients set seats_purchased = seats_purchased + 500 where slug = 'delta';`

RLS: anon reads catalog + branding only. Employees read their own learner row and allocations; all employee writes go through `book_session` / `cancel_booking`. Admins read/write `learners`/`allocations` for their own client via `is_client_admin()`. The composite FK on `allocations (learner_id, client_id)` stops cross-client allocation even if a client id is spoofed.

## Behaviour changes

- `TODAY` is now the real date, and only sessions starting today or later are fetched.
- Footer "correct as at" date comes from the latest `sessions.updated_at`.
- Sessions are paged in 1000-row chunks (PostgREST default cap; there are 1,579).

## Data quirks carried over as-is

- Near-duplicate course names: `Fast Thinking - Confident Speaking` vs en-dash variant, `Government Writing for Impact` vs lowercase `writing`, `People  Leadership` with a double space. Merge them by repointing `sessions.course_id` and deleting the spare.
- Subject is per session because two courses appear under two subjects.
- One exact duplicate session row (no unique constraint on sessions for that reason).
- Client logo is seeded as a data URI. Move it to a public Storage bucket and update `clients.logo_url` when convenient.

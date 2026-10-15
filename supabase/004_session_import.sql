-- Session updates from the Salesforce "AIM Campus Upcoming" report.
-- Run once, after 003. Each new report is then loaded with a generated import file (see tools/import_sessions.py).

-- ─── Columns ─────────────────────────────────────────────────────────────────

alter table public.sessions
  add column external_ref text unique,          -- Salesforce Course Offering Name, e.g. "Mini MBA SY 20-10-2026"
  add column active       boolean not null default true,
  add column capacity     integer,
  add column occupancy    integer;
create index sessions_active_start_idx on public.sessions (active, start_date);

-- Withdrawn sessions stay in the table (allocations may point at them) but disappear from the calendar.

-- ─── Merge near-duplicate course names ───────────────────────────────────────

do $$
declare r record; k smallint; d smallint;
begin
  for r in select * from (values
      ('Fast Thinking - Confident Speaking', 'Fast Thinking – Confident Speaking'),
      ('Government Writing for Impact',      'Government writing for Impact'),
      ('People Leadership',                  'People  Leadership')
    ) v(keep, dup)
  loop
    select id into k from public.courses where name = r.keep;
    select id into d from public.courses where name = r.dup;
    continue when k is null or d is null;
    update public.sessions    set course_id = k where course_id = d;
    update public.allocations set course_id = k where course_id = d;
    delete from public.courses where id = d;
  end loop;
end $$;

-- ─── Import ──────────────────────────────────────────────────────────────────

create or replace function public.norm_name(t text)
returns text language sql immutable as $$
  select lower(regexp_replace(translate(trim(t), '–—', '--'), '\s+', ' ', 'g'));
$$;

-- p: [{ref, course, location, start_date, end_date, n, occupancy, capacity}, ...]
-- The report is the full list of upcoming sessions: anything upcoming that is missing from it is withdrawn.
create or replace function public.apply_session_import(p jsonb, p_limited_at numeric default 0.75)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_today   date := (now() at time zone 'Australia/Sydney')::date;
  v_other   smallint;
  v_bad     text;
  v_courses int; v_backfilled int; v_updated int; v_inserted int; v_withdrawn int; v_restored int;
  v_affected jsonb;
begin
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) = 0 then
    raise exception 'import is empty';
  end if;

  drop table if exists pg_temp.imp;
  create temp table imp on commit drop as
  select x.ref, trim(x.course) as course, x.location, x.start_date, x.end_date, x.n, x.occupancy, x.capacity,
         null::smallint as course_id, null::smallint as location_id
    from jsonb_to_recordset(p) as x(ref text, course text, location text, start_date date, end_date date,
                                    n int, occupancy int, capacity int);

  if exists (select ref from imp group by ref having count(*) > 1) then
    raise exception 'duplicate refs in import';
  end if;

  update imp set location_id = l.id from locations l where l.name = imp.location;
  select string_agg(distinct location, ', ') into v_bad from imp where location_id is null;
  if v_bad is not null then raise exception 'unknown locations: %', v_bad; end if;

  -- New courses
  insert into courses (name)
  select distinct on (norm_name(i.course)) i.course from imp i
   where not exists (select 1 from courses c where norm_name(c.name) = norm_name(i.course));
  get diagnostics v_courses = row_count;
  update imp set course_id = (select min(c.id) from courses c where norm_name(c.name) = norm_name(imp.course));

  -- First run only: attach refs to the seeded sessions, pairing duplicates in order.
  with s as (
    select id, course_id, location_id, start_date,
           row_number() over (partition by course_id, location_id, start_date order by id) rn
      from sessions where external_ref is null
  ), i as (
    select ref, course_id, location_id, start_date,
           row_number() over (partition by course_id, location_id, start_date order by ref) rn
      from imp where not exists (select 1 from sessions x where x.external_ref = imp.ref)
  )
  update sessions t set external_ref = i.ref
    from s join i using (course_id, location_id, start_date, rn)
   where t.id = s.id;
  get diagnostics v_backfilled = row_count;

  -- Bring back anything previously withdrawn that is in the report again
  select count(*) into v_restored from sessions s join imp i on i.ref = s.external_ref where not s.active;

  update sessions s set
      start_date    = i.start_date,
      end_date      = i.end_date,
      session_count = i.n,
      capacity      = i.capacity,
      occupancy     = i.occupancy,
      limited       = coalesce(i.capacity > 0 and i.occupancy::numeric / i.capacity >= p_limited_at, false),
      active        = true,
      updated_at    = now()
    from imp i where s.external_ref = i.ref;
  get diagnostics v_updated = row_count;

  select id into v_other from subjects where name = 'Other';
  insert into sessions (course_id, subject_id, location_id, start_date, end_date, session_count,
                        limited, capacity, occupancy, external_ref)
  select i.course_id,
         coalesce(
           -- most common subject for this course
           (select s2.subject_id from sessions s2 where s2.course_id = i.course_id
             group by s2.subject_id order by count(*) desc limit 1),
           -- variant of an existing course, e.g. "New Leader (Blended)" -> "New Leader"
           (select s3.subject_id from sessions s3 join courses c3 on c3.id = s3.course_id
             where norm_name(c3.name) = norm_name(regexp_replace(i.course, '\s*\([^)]*\)\s*$', ''))
             group by s3.subject_id order by count(*) desc limit 1),
           v_other),
         i.location_id, i.start_date, i.end_date, i.n,
         coalesce(i.capacity > 0 and i.occupancy::numeric / i.capacity >= p_limited_at, false),
         i.capacity, i.occupancy, i.ref
    from imp i
   where not exists (select 1 from sessions s where s.external_ref = i.ref);
  get diagnostics v_inserted = row_count;

  update sessions set active = false, updated_at = now()
   where active and start_date >= v_today
     and (external_ref is null or not exists (select 1 from imp i where i.ref = sessions.external_ref));
  get diagnostics v_withdrawn = row_count;

  -- People booked on a withdrawn date: AIM should contact them
  select coalesce(jsonb_agg(jsonb_build_object(
           'client', cl.name, 'person', l.full_name, 'email', l.email,
           'course', co.name, 'date', s.start_date, 'location', lo.name) order by s.start_date), '[]'::jsonb)
    into v_affected
    from allocations a
    join sessions s  on s.id = a.session_id
    join learners l  on l.id = a.learner_id
    join clients cl  on cl.id = a.client_id
    join courses co  on co.id = s.course_id
    join locations lo on lo.id = s.location_id
   where not s.active and s.start_date >= v_today and a.status in ('allocated', 'booked');

  return jsonb_build_object(
    'rows_in_report', jsonb_array_length(p),
    'new_courses', v_courses,
    'matched_first_time', v_backfilled,
    'updated', v_updated - v_restored,
    'restored', v_restored,
    'new_sessions', v_inserted,
    'withdrawn', v_withdrawn,
    'bookings_on_withdrawn_dates', v_affected);
end $$;

revoke all on function public.apply_session_import(jsonb, numeric) from public, anon, authenticated;

-- ─── Booking must reject withdrawn sessions ──────────────────────────────────

create or replace function public.book_session(p_client uuid, p_session bigint)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_learner learners;
  v_sess    sessions;
  v_alloc   allocations;
  v_prev    bigint;
  v_kind    text;
begin
  select * into v_learner from learners where client_id = p_client and email = jwt_email();
  if not found then raise exception 'not_on_list' using errcode = 'P0001'; end if;

  select * into v_sess from sessions where id = p_session;
  if not found or not v_sess.active or v_sess.start_date < (now() at time zone 'Australia/Sydney')::date then
    raise exception 'session_unavailable' using errcode = 'P0001';
  end if;

  select * into v_alloc from allocations
   where learner_id = v_learner.id and course_id = v_sess.course_id and status <> 'cancelled'
   for update;

  if found then
    if v_alloc.status = 'completed' then raise exception 'already_completed' using errcode = 'P0001'; end if;
    if v_alloc.session_id = p_session then raise exception 'already_booked' using errcode = 'P0001'; end if;
    v_prev := v_alloc.session_id;
    v_kind := case when v_prev is null then 'booked' else 'rescheduled' end;
    update allocations set session_id = p_session, status = 'booked'
     where id = v_alloc.id returning * into v_alloc;
  else
    insert into allocations (client_id, learner_id, course_id, session_id, status, source)
    values (p_client, v_learner.id, v_sess.course_id, p_session, 'booked', 'self')
    returning * into v_alloc;
    v_kind := 'booked';
  end if;

  perform log_booking_event(v_alloc, v_kind, p_session, v_prev);
  return json_build_object('allocation_id', v_alloc.id, 'kind', v_kind);
end $$;

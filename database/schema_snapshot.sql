-- ============================================================================
-- schema_snapshot.sql
--
-- The whole database STRUCTURE in one file: every table, key, constraint,
-- index, view, function, trigger, row-level-security policy and grant, as
-- PostgreSQL itself reports it after all 19 migrations are applied. No data.
--
-- Read this file to see the finished schema in one place. It is a reference
-- snapshot, produced with:
--     pg_dump --schema-only --no-owner --no-comments smartpark
-- The migrations in db/migrations/ remain the source of truth: they build the
-- database in order (./setup.sh) and also load the sample data. To load this
-- file on its own you need the extensions btree_gist and citext and the three
-- roles parking_admin / parking_operator / parking_customer (migration 001).
-- ============================================================================



-- Dumped from database version 17.11 (Homebrew)
-- Dumped by pg_dump version 17.11 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: bill_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.bill_status AS ENUM (
    'unpaid',
    'partly_paid',
    'paid',
    'waived'
);


--
-- Name: pass_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.pass_status AS ENUM (
    'active',
    'expired',
    'cancelled'
);


--
-- Name: payment_method; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_method AS ENUM (
    'cash',
    'card',
    'upi',
    'netbanking',
    'pass',
    'wallet'
);


--
-- Name: reservation_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.reservation_status AS ENUM (
    'held',
    'confirmed',
    'expired',
    'cancelled',
    'fulfilled'
);


--
-- Name: user_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.user_role AS ENUM (
    'admin',
    'operator',
    'customer'
);


--
-- Name: violation_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.violation_type AS ENUM (
    'overstay',
    'wrong_slot_type',
    'no_valid_pass',
    'unpaid_exit',
    'reservation_no_show'
);


--
-- Name: fn_allocate_slot(bigint, bigint, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_allocate_slot(p_facility_id bigint, p_vehicle_type_id bigint, p_at timestamp with time zone DEFAULT now()) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_slot_id BIGINT;
BEGIN
    SELECT s.slot_id
      INTO v_slot_id
      FROM slot  s
      JOIN zone  z  ON z.zone_id  = s.zone_id
      JOIN floor fl ON fl.floor_id = z.floor_id
     WHERE fl.facility_id     = p_facility_id
       AND s.vehicle_type_id  = p_vehicle_type_id
       AND s.is_active
       -- not currently occupied
       AND NOT EXISTS (
             SELECT 1 FROM parking_session ps
              WHERE ps.slot_id = s.slot_id
                AND ps.exit_time IS NULL
           )
       -- not held by a live reservation covering this instant
       AND NOT EXISTS (
             SELECT 1 FROM reservation r
              WHERE r.slot_id = s.slot_id
                AND r.status IN ('held', 'confirmed')
                AND tstzrange(r.reserved_from, r.reserved_until) @> p_at
           )
     -- Lowest floor first, then zone, then slot code: send drivers to the
     -- nearest bay rather than scattering them up the building.
     ORDER BY fl.level_number, z.code, s.code
     LIMIT 1
     -- The lock. SKIP LOCKED means a concurrent operator who already holds
     -- this row does not block us — we simply take the next free bay, which is
     -- the behaviour an operator actually wants at a busy gate.
     FOR UPDATE OF s SKIP LOCKED;

    RETURN v_slot_id;   -- NULL when nothing is available
END;
$$;


--
-- Name: fn_applicable_tariff(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_applicable_tariff(p_session_id bigint) RETURNS bigint
    LANGUAGE sql STABLE
    AS $$
    SELECT t.tariff_id
      FROM parking_session ps
      JOIN slot     s  ON s.slot_id   = ps.slot_id
      JOIN zone     z  ON z.zone_id   = s.zone_id
      JOIN floor    fl ON fl.floor_id = z.floor_id
      JOIN tariff   t  ON t.facility_id     = fl.facility_id
                      AND t.vehicle_type_id = ps.vehicle_type_id
                      AND t.effective_from <= ps.entry_time
                      AND (t.effective_to IS NULL OR t.effective_to > ps.entry_time)
     WHERE ps.session_id = p_session_id;
$$;


--
-- Name: fn_audit_row(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_audit_row() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_new     JSONB := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
    v_old     JSONB := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
    v_changes JSONB;
    v_actor   BIGINT := fn_current_user_id();
BEGIN
    -- Bulk maintenance (db/scripts/refresh_demo_history.sql) switches this off
    -- for its own transaction only.
    IF current_setting('smartpark.audit', true) = 'off' THEN
        RETURN NULL;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(n.key, jsonb_build_object('from', v_old -> n.key, 'to', n.value))
          INTO v_changes
          FROM jsonb_each(v_new) n
         WHERE (v_old -> n.key) IS DISTINCT FROM n.value;
        IF v_changes IS NULL THEN
            RETURN NULL;            -- an UPDATE that changed nothing
        END IF;
    ELSE
        v_changes := COALESCE(v_new, v_old);
    END IF;

    INSERT INTO audit_log (actor_user_id, actor_role, table_name, row_id, action, changes)
    VALUES (v_actor,
            (SELECT u.role FROM app_user u WHERE u.user_id = v_actor),
            TG_TABLE_NAME,
            (COALESCE(v_new, v_old) ->> TG_ARGV[0])::BIGINT,
            TG_OP,
            v_changes);
    RETURN NULL;
END;
$$;


--
-- Name: fn_bill_enforce_amounts(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_bill_enforce_amounts() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_tax_rate NUMERIC(5,2);
    v_entry    TIMESTAMPTZ;
    v_exit     TIMESTAMPTZ;
BEGIN
    NEW.base_amount := fn_calculate_charge(NEW.session_id);
    NEW.tariff_id   := COALESCE(fn_applicable_tariff(NEW.session_id), NEW.tariff_id);

    SELECT f.tax_rate_pct, ps.entry_time, ps.exit_time
      INTO v_tax_rate, v_entry, v_exit
      FROM parking_session ps
      JOIN slot     s  ON s.slot_id   = ps.slot_id
      JOIN zone     z  ON z.zone_id   = s.zone_id
      JOIN floor    fl ON fl.floor_id = z.floor_id
      JOIN facility f  ON f.facility_id = fl.facility_id
     WHERE ps.session_id = NEW.session_id;

    NEW.tax_amount := ROUND(NEW.base_amount * v_tax_rate / 100.0, 2);
    NEW.billable_minutes := GREATEST(
        0,
        FLOOR(EXTRACT(EPOCH FROM (COALESCE(v_exit, now()) - v_entry)) / 60.0)::INTEGER
    );

    -- Nothing owed means nothing outstanding.
    IF NEW.base_amount + NEW.tax_amount = 0 AND NEW.status = 'unpaid' THEN
        NEW.status := 'paid';
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: fn_calculate_charge(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_calculate_charge(p_session_id bigint) RETURNS numeric
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_entry        TIMESTAMPTZ;
    v_exit         TIMESTAMPTZ;
    v_vtype        BIGINT;
    v_facility     BIGINT;
    v_pass_id      BIGINT;
    v_tariff       tariff%ROWTYPE;
    v_minutes      NUMERIC;
    v_chargeable   NUMERIC;
    v_full_days    INTEGER;
    v_rem_minutes  NUMERIC;
    v_rem_hours    NUMERIC;
    v_day_amount   NUMERIC;
    v_total        NUMERIC := 0;
BEGIN
    -- Pull the session together with the facility it belongs to. The join
    -- chain slot -> zone -> floor -> facility is why tariff is keyed on
    -- facility rather than duplicated onto the slot.
    SELECT ps.entry_time, ps.exit_time, ps.vehicle_type_id, f.facility_id, ps.pass_id
      INTO v_entry, v_exit, v_vtype, v_facility, v_pass_id
      FROM parking_session ps
      JOIN slot     s  ON s.slot_id  = ps.slot_id
      JOIN zone     z  ON z.zone_id  = s.zone_id
      JOIN floor    fl ON fl.floor_id = z.floor_id
      JOIN facility f  ON f.facility_id = fl.facility_id
     WHERE ps.session_id = p_session_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_calculate_charge: no such session %', p_session_id
            USING ERRCODE = 'no_data_found';
    END IF;

    -- A pass covers the stay entirely.
    IF v_pass_id IS NOT NULL THEN
        RETURN 0.00;
    END IF;

    -- An open session is priced as at this moment.
    v_minutes := EXTRACT(EPOCH FROM (COALESCE(v_exit, now()) - v_entry)) / 60.0;
    IF v_minutes < 0 THEN
        v_minutes := 0;
    END IF;

    -- The tariff in force when the vehicle arrived. ex_tariff_no_overlap in
    -- migration 003 guarantees this matches at most one row.
    SELECT * INTO v_tariff
      FROM tariff t
     WHERE t.facility_id     = v_facility
       AND t.vehicle_type_id = v_vtype
       AND t.effective_from <= v_entry
       AND (t.effective_to IS NULL OR t.effective_to > v_entry);

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'fn_calculate_charge: no tariff in force for facility % / vehicle type % at %',
            v_facility, v_vtype, v_entry
            USING ERRCODE = 'no_data_found';
    END IF;

    -- Grace period.
    IF v_minutes <= v_tariff.free_minutes THEN
        RETURN 0.00;
    END IF;

    v_chargeable := v_minutes - v_tariff.free_minutes;

    -- Whole 24-hour blocks are charged at the daily cap.
    v_full_days   := FLOOR(v_chargeable / 1440.0);
    v_rem_minutes := v_chargeable - (v_full_days * 1440.0);
    v_total       := v_full_days * v_tariff.daily_cap;

    -- The remainder is charged hour by hour, rounding a part hour up, then
    -- capped so a 23-hour tail never costs more than a whole day.
    IF v_rem_minutes > 0 THEN
        v_rem_hours := CEIL(v_rem_minutes / 60.0);
        IF v_rem_hours <= 1 THEN
            v_day_amount := v_tariff.first_hour_rate;
        ELSE
            v_day_amount := v_tariff.first_hour_rate
                          + (v_rem_hours - 1) * v_tariff.subsequent_hour_rate;
        END IF;
        v_total := v_total + LEAST(v_day_amount, v_tariff.daily_cap);
    END IF;

    RETURN ROUND(v_total, 2);
END;
$$;


--
-- Name: fn_current_customer_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_current_customer_id() RETURNS bigint
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
    SELECT c.customer_id FROM customer c WHERE c.user_id = fn_current_user_id();
$$;


--
-- Name: fn_current_facility_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_current_facility_id() RETURNS bigint
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
    SELECT u.facility_id FROM app_user u WHERE u.user_id = fn_current_user_id();
$$;


--
-- Name: fn_current_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_current_role() RETURNS public.user_role
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
    SELECT CASE current_user
             WHEN 'parking_admin'    THEN 'admin'::user_role
             WHEN 'parking_operator' THEN 'operator'::user_role
             WHEN 'parking_customer' THEN 'customer'::user_role
           END;
$$;


--
-- Name: fn_current_user_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_current_user_id() RETURNS bigint
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $_$
    SELECT CASE
             WHEN current_setting('app.current_user_id', true) ~ '^[0-9]+$'
             THEN current_setting('app.current_user_id', true)::BIGINT
           END;
$_$;


--
-- Name: fn_expire_stale_reservations(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_expire_stale_reservations() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_count INTEGER;
BEGIN
    WITH expired AS (
        UPDATE reservation
           SET status = 'expired'
         WHERE status IN ('held', 'confirmed')
           AND reserved_until <= now()
           -- A reservation whose vehicle actually arrived is fulfilled, not
           -- expired; fn_gate_entry has already set that.
           AND NOT EXISTS (
                 SELECT 1 FROM parking_session ps
                  WHERE ps.reservation_id = reservation.reservation_id
               )
        RETURNING 1
    )
    SELECT count(*) INTO v_count FROM expired;

    -- A hold that lapsed without the driver turning up is a reportable no-show.
    INSERT INTO violation (kind, vehicle_id, slot_id, detected_at, penalty_amount, notes)
    SELECT 'reservation_no_show', r.vehicle_id, r.slot_id, r.reserved_until, 0,
           format('Reservation %s expired without arrival', r.reservation_id)
      FROM reservation r
     WHERE r.status = 'expired'
       AND r.reserved_until <= now()
       AND r.reserved_until > now() - INTERVAL '1 day'
       AND NOT EXISTS (
             SELECT 1 FROM violation v
              WHERE v.vehicle_id = r.vehicle_id
                AND v.kind = 'reservation_no_show'
                AND v.detected_at = r.reserved_until
           );

    RETURN v_count;
END;
$$;


--
-- Name: fn_gate_entry(text, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_gate_entry(p_plate text, p_facility_id bigint, p_operator_id bigint DEFAULT NULL::bigint) RETURNS TABLE(session_id bigint, ticket_no text, slot_id bigint, slot_code text, pass_id bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_caller_role     user_role;
    v_caller_facility BIGINT;
    v_vehicle_id BIGINT;
    v_vtype      BIGINT;
    v_slot_id    BIGINT;
    v_slot_code  TEXT;
    v_res_id     BIGINT;
    v_pass_id    BIGINT;
    v_ticket     TEXT;
    v_session_id BIGINT;
    v_open_slot_code     TEXT;
    v_open_facility_name TEXT;
    v_now        TIMESTAMPTZ := now();
BEGIN
    -- 0. Authorisation. RLS cannot do this for us inside a SECURITY DEFINER
    --    body, so the rule is stated explicitly: an operator works one gate.
    SELECT u.role, u.facility_id INTO v_caller_role, v_caller_facility
      FROM app_user u WHERE u.user_id = p_operator_id;

    IF v_caller_role = 'operator' AND v_caller_facility IS DISTINCT FROM p_facility_id THEN
        RAISE EXCEPTION
            'You are posted to facility %, not facility %', v_caller_facility, p_facility_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- 1. The vehicle must be registered. Registering at the gate is a separate
    --    call so that this function has one job.
    SELECT v.vehicle_id, v.vehicle_type_id
      INTO v_vehicle_id, v_vtype
      FROM vehicle v
     WHERE v.plate_number = upper(btrim(p_plate));

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No vehicle is registered with plate %', upper(btrim(p_plate))
            USING ERRCODE = 'no_data_found',
                  HINT    = 'Register the vehicle and its owner first.';
    END IF;

    -- Fail early with a readable message rather than letting the partial
    -- unique index produce a raw index name at INSERT time.
    --
    -- The message names the bay AND the site. That matters: this function is
    -- SECURITY DEFINER, so it sees open sessions at every facility, while the
    -- operator's own queries are scoped by RLS to their own site. Without the
    -- site in the message an operator at Central is told a car is already
    -- parked while their own screens show it as away, which looks like a bug.
    SELECT s.code, f.name
      INTO v_open_slot_code, v_open_facility_name
      FROM parking_session ps
      JOIN slot     s  ON s.slot_id     = ps.slot_id
      JOIN zone     z  ON z.zone_id     = s.zone_id
      JOIN floor    fl ON fl.floor_id   = z.floor_id
      JOIN facility f  ON f.facility_id = fl.facility_id
     WHERE ps.vehicle_id = v_vehicle_id AND ps.exit_time IS NULL
     LIMIT 1;

    IF v_open_slot_code IS NOT NULL THEN
        RAISE EXCEPTION 'Vehicle % is already parked in bay % at %',
            upper(btrim(p_plate)), v_open_slot_code, v_open_facility_name
            USING ERRCODE = 'unique_violation',
                  HINT    = 'Record its exit at that facility before admitting it here.';
    END IF;

    -- 2. A live reservation wins over automatic allocation.
    SELECT r.reservation_id, r.slot_id
      INTO v_res_id, v_slot_id
      FROM reservation r
      JOIN slot  s  ON s.slot_id  = r.slot_id
      JOIN zone  z  ON z.zone_id  = s.zone_id
      JOIN floor fl ON fl.floor_id = z.floor_id
     WHERE r.vehicle_id = v_vehicle_id
       AND r.status IN ('held', 'confirmed')
       AND fl.facility_id = p_facility_id
       AND tstzrange(r.reserved_from, r.reserved_until) @> v_now
     ORDER BY r.reserved_from
     LIMIT 1
     FOR UPDATE OF r;

    IF v_slot_id IS NOT NULL THEN
        -- 3a. Lock the reserved bay so nothing else can take it between here
        --     and the INSERT. The alias is not optional: `slot_id` unqualified
        --     resolves to this function's OUT parameter, not to the column.
        PERFORM 1 FROM slot s WHERE s.slot_id = v_slot_id FOR UPDATE;
    ELSE
        -- 3b. No reservation: allocate and lock in one step.
        v_slot_id := fn_allocate_slot(p_facility_id, v_vtype, v_now);
        IF v_slot_id IS NULL THEN
            RAISE EXCEPTION 'No free slot available for this vehicle type at facility %', p_facility_id
                USING ERRCODE = 'insufficient_resources';
        END IF;
    END IF;

    -- 4. A pass covering this instant makes the stay free (fn_calculate_charge
    --    returns 0 when pass_id is set).
    SELECT pp.pass_id
      INTO v_pass_id
      FROM parking_pass pp
     WHERE pp.vehicle_id  = v_vehicle_id
       AND pp.facility_id = p_facility_id
       AND pp.cancelled_at IS NULL
       AND v_now >= pp.valid_from
       AND v_now <  pp.valid_to
     LIMIT 1;

    -- 5. Ticket number. The retry loop covers the astronomically unlikely
    --    collision on the UNIQUE constraint rather than trusting randomness.
    LOOP
        v_ticket := 'TK-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
        EXIT WHEN NOT EXISTS (SELECT 1 FROM parking_session WHERE parking_session.ticket_no = v_ticket);
    END LOOP;

    INSERT INTO parking_session
        (ticket_no, slot_id, vehicle_id, vehicle_type_id, entry_time,
         reservation_id, pass_id, entry_operator_id)
    VALUES
        (v_ticket, v_slot_id, v_vehicle_id, v_vtype, v_now,
         v_res_id, v_pass_id, p_operator_id)
    RETURNING parking_session.session_id INTO v_session_id;

    -- 6. Close the reservation out.
    IF v_res_id IS NOT NULL THEN
        UPDATE reservation SET status = 'fulfilled' WHERE reservation_id = v_res_id;
    END IF;

    SELECT s.code INTO v_slot_code FROM slot s WHERE s.slot_id = v_slot_id;

    -- OUT parameters are assigned only here, from locals, so that no column
    -- reference anywhere above can be captured by one of their names.
    session_id := v_session_id;
    ticket_no  := v_ticket;
    slot_id    := v_slot_id;
    slot_code  := v_slot_code;
    pass_id    := v_pass_id;
    RETURN NEXT;
END;
$$;


--
-- Name: fn_gate_exit(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_gate_exit(p_lookup text, p_operator_id bigint DEFAULT NULL::bigint) RETURNS TABLE(session_id bigint, bill_id bigint, billable_minutes integer, base_amount numeric, tax_amount numeric, total_amount numeric, slot_code text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_caller_role     user_role;
    v_caller_facility BIGINT;
    v_session_facility BIGINT;
    v_sid      BIGINT;
    v_bill     BIGINT;   -- local, so the name never collides with the OUT
                         -- parameter bill_id inside a query referencing bill
    v_slot     BIGINT;
    v_vehicle  BIGINT;
    v_entry    TIMESTAMPTZ;
    v_tariff   BIGINT;
    v_now      TIMESTAMPTZ := now();
    v_hours    NUMERIC;
BEGIN
    SELECT u.role, u.facility_id INTO v_caller_role, v_caller_facility
      FROM app_user u WHERE u.user_id = p_operator_id;

    -- 1. Lock the session row for the duration of the transaction.
    SELECT ps.session_id, ps.slot_id, ps.vehicle_id, ps.entry_time, fl.facility_id
      INTO v_sid, v_slot, v_vehicle, v_entry, v_session_facility
      FROM parking_session ps
      JOIN vehicle v ON v.vehicle_id = ps.vehicle_id
      JOIN slot  s2 ON s2.slot_id = ps.slot_id
      JOIN zone  z2 ON z2.zone_id = s2.zone_id
      JOIN floor fl ON fl.floor_id = z2.floor_id
     WHERE ps.exit_time IS NULL
       AND (ps.ticket_no = upper(btrim(p_lookup))
            OR v.plate_number = upper(btrim(p_lookup)))
     LIMIT 1
     FOR UPDATE OF ps;

    IF v_sid IS NULL THEN
        RAISE EXCEPTION 'No open parking session found for "%"', p_lookup
            USING ERRCODE = 'no_data_found';
    END IF;

    -- An operator may only release a bay at their own site.
    IF v_caller_role = 'operator' AND v_caller_facility IS DISTINCT FROM v_session_facility THEN
        RAISE EXCEPTION 'That vehicle is parked at facility %, not your facility %',
            v_session_facility, v_caller_facility
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- 2. Close the session.
    UPDATE parking_session
       SET exit_time = v_now,
           exit_operator_id = p_operator_id
     WHERE parking_session.session_id = v_sid;

    -- 3. Raise the bill. base_amount/tax_amount/billable_minutes passed here
    --    are placeholders — trg_bill_enforce_amounts overwrites all three.
    v_tariff := fn_applicable_tariff(v_sid);
    INSERT INTO bill (session_id, tariff_id, billable_minutes, base_amount, tax_amount)
    VALUES (v_sid, v_tariff, 0, 0, 0)
    RETURNING bill.bill_id INTO v_bill;

    -- 4. Overstay: more than 24 hours in a bay without a pass.
    v_hours := EXTRACT(EPOCH FROM (v_now - v_entry)) / 3600.0;
    IF v_hours > 24 THEN
        INSERT INTO violation (kind, session_id, vehicle_id, slot_id, detected_at, penalty_amount, notes)
        VALUES ('overstay', v_sid, v_vehicle, v_slot, v_now, 200.00,
                format('Stay of %s hours exceeded the 24 hour limit', round(v_hours, 1)));
    END IF;

    SELECT b.billable_minutes, b.base_amount, b.tax_amount, b.total_amount
      INTO billable_minutes, base_amount, tax_amount, total_amount
      FROM bill b WHERE b.bill_id = v_bill;

    SELECT s.code INTO slot_code FROM slot s WHERE s.slot_id = v_slot;

    session_id := v_sid;
    bill_id    := v_bill;
    RETURN NEXT;
END;
$$;


--
-- Name: fn_payment_sync_bill_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_payment_sync_bill_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_bill_id BIGINT := COALESCE(NEW.bill_id, OLD.bill_id);
    v_paid    NUMERIC(10,2);
    v_total   NUMERIC(10,2);
BEGIN
    SELECT COALESCE(SUM(p.amount), 0) INTO v_paid
      FROM payment p WHERE p.bill_id = v_bill_id;

    SELECT b.total_amount INTO v_total FROM bill b WHERE b.bill_id = v_bill_id;

    UPDATE bill
       SET status = CASE
                      WHEN v_total = 0        THEN 'paid'::bill_status
                      WHEN v_paid  >= v_total THEN 'paid'::bill_status
                      WHEN v_paid  > 0        THEN 'partly_paid'::bill_status
                      ELSE 'unpaid'::bill_status
                    END
     WHERE bill_id = v_bill_id
       AND status <> 'waived';   -- an explicit waiver is not overridden

    RETURN NULL;
END;
$$;


--
-- Name: fn_payment_within_balance(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_payment_within_balance() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_total  NUMERIC(10,2);
    v_status bill_status;
    v_paid   NUMERIC(10,2);
BEGIN
    SELECT b.total_amount, b.status INTO v_total, v_status
      FROM bill b WHERE b.bill_id = NEW.bill_id
       FOR UPDATE;

    IF v_status = 'waived' THEN
        RAISE EXCEPTION 'This bill was waived; nothing is owed on it.'
              USING ERRCODE = 'check_violation', CONSTRAINT = 'trg_payment_within_balance';
    END IF;

    SELECT COALESCE(SUM(p.amount), 0) INTO v_paid
      FROM payment p
     WHERE p.bill_id = NEW.bill_id
       AND (TG_OP = 'INSERT' OR p.payment_id <> NEW.payment_id);

    IF v_paid + NEW.amount > v_total THEN
        RAISE EXCEPTION 'That is more than the ₹% still owed on this bill.',
              to_char(GREATEST(v_total - v_paid, 0), 'FM9999990.00')
              USING ERRCODE = 'check_violation', CONSTRAINT = 'trg_payment_within_balance';
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: fn_reservation_prepare(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_reservation_prepare() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.vehicle_type_id IS NULL THEN
        SELECT v.vehicle_type_id INTO NEW.vehicle_type_id
          FROM vehicle v WHERE v.vehicle_id = NEW.vehicle_id;
    END IF;

    IF NOT (SELECT s.is_active FROM slot s WHERE s.slot_id = NEW.slot_id) THEN
        RAISE EXCEPTION 'That bay is out of service and cannot be reserved.'
              USING ERRCODE = 'check_violation',
                    CONSTRAINT = 'trg_reservation_prepare';
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: fn_set_slot_service(bigint, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_set_slot_service(p_slot_id bigint, p_in_service boolean, p_note text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_role     user_role := fn_current_role();
    v_code     TEXT;
    v_facility BIGINT;
BEGIN
    IF v_role IS NULL OR v_role = 'customer' THEN
        RAISE EXCEPTION 'Only staff can change a bay''s service status.'
              USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT s.code, fl.facility_id
      INTO v_code, v_facility
      FROM slot s
      JOIN zone  z  ON z.zone_id   = s.zone_id
      JOIN floor fl ON fl.floor_id = z.floor_id
     WHERE s.slot_id = p_slot_id
       FOR UPDATE OF s;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Bay % does not exist.', p_slot_id USING ERRCODE = 'no_data_found';
    END IF;

    IF v_role = 'operator' AND v_facility IS DISTINCT FROM fn_current_facility_id() THEN
        RAISE EXCEPTION 'You can only manage bays at your own facility.'
              USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NOT p_in_service THEN
        IF EXISTS (SELECT 1 FROM parking_session ps
                    WHERE ps.slot_id = p_slot_id AND ps.exit_time IS NULL) THEN
            RAISE EXCEPTION 'Bay % has a vehicle in it. Record its exit first.', v_code
                  USING ERRCODE = 'object_in_use';
        END IF;
        IF EXISTS (SELECT 1 FROM reservation r
                    WHERE r.slot_id = p_slot_id
                      AND r.status IN ('held', 'confirmed')
                      AND r.reserved_until > now()) THEN
            RAISE EXCEPTION 'Bay % is held for a reservation. Cancel the reservation first.', v_code
                  USING ERRCODE = 'object_in_use';
        END IF;
    END IF;

    UPDATE slot
       SET is_active    = p_in_service,
           service_note = CASE WHEN p_in_service THEN NULL
                               ELSE NULLIF(btrim(p_note), '') END
     WHERE slot_id = p_slot_id;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: app_user; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_user (
    user_id bigint NOT NULL,
    email public.citext NOT NULL,
    password_hash text NOT NULL,
    full_name text NOT NULL,
    role public.user_role DEFAULT 'customer'::public.user_role NOT NULL,
    facility_id bigint,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_app_user_email_shape CHECK ((email OPERATOR(public.~) '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'::public.citext)),
    CONSTRAINT ck_app_user_name_not_blank CHECK ((length(btrim(full_name)) > 0)),
    CONSTRAINT ck_app_user_operator_has_facility CHECK (((role = 'operator'::public.user_role) = (facility_id IS NOT NULL)))
);


--
-- Name: app_user_user_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.app_user ALTER COLUMN user_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.app_user_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    audit_id bigint NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    actor_user_id bigint,
    actor_role public.user_role,
    table_name text NOT NULL,
    row_id bigint NOT NULL,
    action text NOT NULL,
    changes jsonb NOT NULL,
    CONSTRAINT ck_audit_action CHECK ((action = ANY (ARRAY['INSERT'::text, 'UPDATE'::text, 'DELETE'::text])))
);


--
-- Name: audit_log_audit_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ALTER COLUMN audit_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.audit_log_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: bill; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bill (
    bill_id bigint NOT NULL,
    session_id bigint NOT NULL,
    tariff_id bigint NOT NULL,
    billable_minutes integer NOT NULL,
    base_amount numeric(10,2) NOT NULL,
    tax_amount numeric(10,2) NOT NULL,
    total_amount numeric(10,2) GENERATED ALWAYS AS ((base_amount + tax_amount)) STORED,
    status public.bill_status DEFAULT 'unpaid'::public.bill_status NOT NULL,
    generated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_bill_base_non_negative CHECK ((base_amount >= (0)::numeric)),
    CONSTRAINT ck_bill_minutes_non_negative CHECK ((billable_minutes >= 0)),
    CONSTRAINT ck_bill_tax_non_negative CHECK ((tax_amount >= (0)::numeric))
);


--
-- Name: bill_bill_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.bill ALTER COLUMN bill_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.bill_bill_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: customer; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer (
    customer_id bigint NOT NULL,
    user_id bigint,
    full_name text NOT NULL,
    phone text NOT NULL,
    email public.citext,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_customer_email_shape CHECK (((email IS NULL) OR (email OPERATOR(public.~) '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'::public.citext))),
    CONSTRAINT ck_customer_name_not_blank CHECK ((length(btrim(full_name)) > 0)),
    CONSTRAINT ck_customer_phone_shape CHECK ((phone ~ '^[0-9]{10}$'::text))
);


--
-- Name: customer_customer_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.customer ALTER COLUMN customer_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.customer_customer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: facility; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.facility (
    facility_id bigint NOT NULL,
    name text NOT NULL,
    address_line text NOT NULL,
    city text NOT NULL,
    opens_at time without time zone DEFAULT '00:00:00'::time without time zone NOT NULL,
    closes_at time without time zone DEFAULT '23:59:00'::time without time zone NOT NULL,
    tax_rate_pct numeric(5,2) DEFAULT 18.00 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_facility_name_not_blank CHECK ((length(btrim(name)) > 0)),
    CONSTRAINT ck_facility_tax_rate CHECK (((tax_rate_pct >= (0)::numeric) AND (tax_rate_pct <= (100)::numeric)))
);


--
-- Name: facility_facility_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.facility ALTER COLUMN facility_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.facility_facility_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: floor; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.floor (
    floor_id bigint NOT NULL,
    facility_id bigint NOT NULL,
    level_number integer NOT NULL,
    name text NOT NULL,
    CONSTRAINT ck_floor_level_range CHECK (((level_number >= '-5'::integer) AND (level_number <= 50)))
);


--
-- Name: floor_floor_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.floor ALTER COLUMN floor_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.floor_floor_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: parking_pass; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parking_pass (
    pass_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    vehicle_id bigint NOT NULL,
    pass_type_id bigint NOT NULL,
    facility_id bigint NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    valid_to timestamp with time zone NOT NULL,
    price_paid numeric(10,2) NOT NULL,
    cancelled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_pass_price CHECK ((price_paid >= (0)::numeric)),
    CONSTRAINT ck_pass_window CHECK ((valid_to > valid_from))
);


--
-- Name: parking_pass_pass_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.parking_pass ALTER COLUMN pass_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.parking_pass_pass_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: parking_session; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parking_session (
    session_id bigint NOT NULL,
    ticket_no text NOT NULL,
    slot_id bigint NOT NULL,
    vehicle_id bigint NOT NULL,
    vehicle_type_id bigint NOT NULL,
    entry_time timestamp with time zone DEFAULT now() NOT NULL,
    exit_time timestamp with time zone,
    reservation_id bigint,
    pass_id bigint,
    entry_operator_id bigint,
    exit_operator_id bigint,
    CONSTRAINT ck_session_exit_after_entry CHECK (((exit_time IS NULL) OR (exit_time > entry_time))),
    CONSTRAINT ck_session_ticket_shape CHECK ((ticket_no ~ '^TK-[0-9A-Z]{6,12}$'::text))
);


--
-- Name: parking_session_session_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.parking_session ALTER COLUMN session_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.parking_session_session_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: pass_type; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pass_type (
    pass_type_id bigint NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    duration_days integer NOT NULL,
    price numeric(10,2) NOT NULL,
    vehicle_type_id bigint NOT NULL,
    CONSTRAINT ck_pass_type_duration CHECK (((duration_days >= 1) AND (duration_days <= 366))),
    CONSTRAINT ck_pass_type_price CHECK ((price >= (0)::numeric))
);


--
-- Name: pass_type_pass_type_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.pass_type ALTER COLUMN pass_type_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.pass_type_pass_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: payment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment (
    payment_id bigint NOT NULL,
    bill_id bigint NOT NULL,
    amount numeric(10,2) NOT NULL,
    method public.payment_method NOT NULL,
    reference_no text,
    paid_at timestamp with time zone DEFAULT now() NOT NULL,
    received_by bigint,
    CONSTRAINT ck_payment_amount_positive CHECK ((amount > (0)::numeric))
);


--
-- Name: payment_payment_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.payment ALTER COLUMN payment_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.payment_payment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: reservation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reservation (
    reservation_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    vehicle_id bigint NOT NULL,
    slot_id bigint NOT NULL,
    reserved_from timestamp with time zone NOT NULL,
    reserved_until timestamp with time zone NOT NULL,
    status public.reservation_status DEFAULT 'held'::public.reservation_status NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    vehicle_type_id bigint NOT NULL,
    CONSTRAINT ck_reservation_window CHECK ((reserved_until > reserved_from))
);


--
-- Name: reservation_reservation_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.reservation ALTER COLUMN reservation_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.reservation_reservation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: slot; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slot (
    slot_id bigint NOT NULL,
    zone_id bigint NOT NULL,
    code text NOT NULL,
    vehicle_type_id bigint NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    grid_row smallint,
    grid_col smallint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    service_note text,
    CONSTRAINT ck_slot_code_shape CHECK ((code ~ '^[A-Z0-9-]{2,16}$'::text)),
    CONSTRAINT ck_slot_note_only_when_out CHECK (((service_note IS NULL) OR ((NOT is_active) AND ((char_length(service_note) >= 1) AND (char_length(service_note) <= 200)))))
);


--
-- Name: slot_slot_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.slot ALTER COLUMN slot_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.slot_slot_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tariff; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tariff (
    tariff_id bigint NOT NULL,
    facility_id bigint NOT NULL,
    vehicle_type_id bigint NOT NULL,
    name text NOT NULL,
    free_minutes integer DEFAULT 15 NOT NULL,
    first_hour_rate numeric(10,2) NOT NULL,
    subsequent_hour_rate numeric(10,2) NOT NULL,
    daily_cap numeric(10,2) NOT NULL,
    effective_from timestamp with time zone DEFAULT now() NOT NULL,
    effective_to timestamp with time zone,
    CONSTRAINT ck_tariff_cap_sane CHECK ((daily_cap >= first_hour_rate)),
    CONSTRAINT ck_tariff_free_minutes CHECK (((free_minutes >= 0) AND (free_minutes <= 1440))),
    CONSTRAINT ck_tariff_rates_non_negative CHECK (((first_hour_rate >= (0)::numeric) AND (subsequent_hour_rate >= (0)::numeric) AND (daily_cap >= (0)::numeric))),
    CONSTRAINT ck_tariff_window_valid CHECK (((effective_to IS NULL) OR (effective_to > effective_from)))
);


--
-- Name: tariff_tariff_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tariff ALTER COLUMN tariff_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.tariff_tariff_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: vehicle; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vehicle (
    vehicle_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    plate_number text NOT NULL,
    vehicle_type_id bigint NOT NULL,
    make text,
    model text,
    colour text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_vehicle_plate_shape CHECK ((plate_number ~ '^[A-Z]{2}[0-9]{1,2}[A-Z]{1,3}[0-9]{4}$'::text))
);


--
-- Name: vehicle_type; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vehicle_type (
    vehicle_type_id bigint NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    footprint_units smallint DEFAULT 1 NOT NULL,
    CONSTRAINT ck_vehicle_type_code_shape CHECK ((code ~ '^[A-Z]{2,10}$'::text)),
    CONSTRAINT ck_vehicle_type_footprint CHECK (((footprint_units >= 1) AND (footprint_units <= 4)))
);


--
-- Name: zone; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.zone (
    zone_id bigint NOT NULL,
    floor_id bigint NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    CONSTRAINT ck_zone_code_shape CHECK ((code ~ '^[A-Z]{1,3}$'::text))
);


--
-- Name: v_current_occupancy; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_current_occupancy WITH (security_invoker='true') AS
 SELECT f.facility_id,
    f.name AS facility_name,
    fl.floor_id,
    fl.level_number,
    fl.name AS floor_name,
    z.zone_id,
    z.code AS zone_code,
    s.slot_id,
    s.code AS slot_code,
    s.grid_row,
    s.grid_col,
    vt.vehicle_type_id,
    vt.code AS vehicle_type_code,
    vt.name AS vehicle_type_name,
        CASE
            WHEN (NOT s.is_active) THEN 'out_of_service'::text
            WHEN (ps.session_id IS NOT NULL) THEN 'occupied'::text
            WHEN (r.reservation_id IS NOT NULL) THEN 'reserved'::text
            ELSE 'free'::text
        END AS slot_state,
    ps.session_id,
    ps.ticket_no,
    ps.entry_time,
    v.plate_number,
    c.full_name AS customer_name,
        CASE
            WHEN (ps.session_id IS NOT NULL) THEN public.fn_calculate_charge(ps.session_id)
            ELSE NULL::numeric
        END AS running_charge
   FROM ((((((((public.slot s
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
     JOIN public.facility f ON ((f.facility_id = fl.facility_id)))
     JOIN public.vehicle_type vt ON ((vt.vehicle_type_id = s.vehicle_type_id)))
     LEFT JOIN public.parking_session ps ON (((ps.slot_id = s.slot_id) AND (ps.exit_time IS NULL))))
     LEFT JOIN public.vehicle v ON ((v.vehicle_id = ps.vehicle_id)))
     LEFT JOIN public.customer c ON ((c.customer_id = v.customer_id)))
     LEFT JOIN public.reservation r ON (((r.slot_id = s.slot_id) AND (r.status = ANY (ARRAY['held'::public.reservation_status, 'confirmed'::public.reservation_status])) AND (tstzrange(r.reserved_from, r.reserved_until) @> now()))));


--
-- Name: v_free_slots; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_free_slots WITH (security_invoker='true') AS
 SELECT facility_id,
    facility_name,
    floor_id,
    level_number,
    floor_name,
    zone_id,
    zone_code,
    slot_id,
    slot_code,
    vehicle_type_id,
    vehicle_type_code,
    vehicle_type_name
   FROM public.v_current_occupancy
  WHERE (slot_state = 'free'::text);


--
-- Name: v_pass_usage; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_pass_usage WITH (security_invoker='true') AS
 SELECT pp.pass_id,
    pp.facility_id,
    c.customer_id,
    c.full_name AS customer_name,
    v.plate_number,
    pt.name AS pass_type_name,
    pt.duration_days,
    pp.valid_from,
    pp.valid_to,
    pp.price_paid,
        CASE
            WHEN (pp.cancelled_at IS NOT NULL) THEN 'cancelled'::text
            WHEN (now() >= pp.valid_to) THEN 'expired'::text
            WHEN (now() < pp.valid_from) THEN 'scheduled'::text
            ELSE 'active'::text
        END AS pass_state,
    COALESCE(u.sessions_used, (0)::bigint) AS sessions_used,
    COALESCE(u.minutes_used, 0) AS minutes_used,
    GREATEST(0, (EXTRACT(day FROM (pp.valid_to - now())))::integer) AS days_remaining
   FROM ((((public.parking_pass pp
     JOIN public.customer c ON ((c.customer_id = pp.customer_id)))
     JOIN public.vehicle v ON ((v.vehicle_id = pp.vehicle_id)))
     JOIN public.pass_type pt ON ((pt.pass_type_id = pp.pass_type_id)))
     LEFT JOIN LATERAL ( SELECT count(*) AS sessions_used,
            (COALESCE(sum((EXTRACT(epoch FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0)), (0)::numeric))::integer AS minutes_used
           FROM public.parking_session ps
          WHERE (ps.pass_id = pp.pass_id)) u ON (true));


--
-- Name: v_peak_hours; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_peak_hours WITH (security_invoker='true') AS
 SELECT fl.facility_id,
    (EXTRACT(hour FROM ps.entry_time))::integer AS hour_of_day,
    count(*) AS entries,
    count(*) FILTER (WHERE (ps.exit_time IS NULL)) AS still_parked,
    round(avg((EXTRACT(epoch FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0)), 1) AS avg_stay_minutes,
    rank() OVER (PARTITION BY fl.facility_id ORDER BY (count(*)) DESC) AS busyness_rank
   FROM (((public.parking_session ps
     JOIN public.slot s ON ((s.slot_id = ps.slot_id)))
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
  GROUP BY fl.facility_id, (EXTRACT(hour FROM ps.entry_time));


--
-- Name: violation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.violation (
    violation_id bigint NOT NULL,
    kind public.violation_type NOT NULL,
    session_id bigint,
    vehicle_id bigint NOT NULL,
    slot_id bigint,
    detected_at timestamp with time zone DEFAULT now() NOT NULL,
    penalty_amount numeric(10,2) DEFAULT 0 NOT NULL,
    notes text,
    resolved_at timestamp with time zone,
    CONSTRAINT ck_violation_penalty CHECK ((penalty_amount >= (0)::numeric)),
    CONSTRAINT ck_violation_resolved_after CHECK (((resolved_at IS NULL) OR (resolved_at >= detected_at)))
);


--
-- Name: v_recent_activity; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_recent_activity WITH (security_invoker='true') AS
 SELECT ps.entry_time AS occurred_at,
    'entry'::text AS kind,
    fl.facility_id,
    ps.session_id AS ref_id,
    v.plate_number,
    s.code AS slot_code,
    NULL::numeric AS amount,
    ps.ticket_no AS detail
   FROM ((((public.parking_session ps
     JOIN public.slot s ON ((s.slot_id = ps.slot_id)))
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
     JOIN public.vehicle v ON ((v.vehicle_id = ps.vehicle_id)))
UNION ALL
 SELECT ps.exit_time AS occurred_at,
    'exit'::text AS kind,
    fl.facility_id,
    ps.session_id AS ref_id,
    v.plate_number,
    s.code AS slot_code,
    NULL::numeric AS amount,
    ps.ticket_no AS detail
   FROM ((((public.parking_session ps
     JOIN public.slot s ON ((s.slot_id = ps.slot_id)))
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
     JOIN public.vehicle v ON ((v.vehicle_id = ps.vehicle_id)))
  WHERE (ps.exit_time IS NOT NULL)
UNION ALL
 SELECT p.paid_at AS occurred_at,
    'payment'::text AS kind,
    fl.facility_id,
    p.payment_id AS ref_id,
    v.plate_number,
    s.code AS slot_code,
    p.amount,
    (p.method)::text AS detail
   FROM ((((((public.payment p
     JOIN public.bill b ON ((b.bill_id = p.bill_id)))
     JOIN public.parking_session ps ON ((ps.session_id = b.session_id)))
     JOIN public.slot s ON ((s.slot_id = ps.slot_id)))
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
     JOIN public.vehicle v ON ((v.vehicle_id = ps.vehicle_id)))
UNION ALL
 SELECT r.created_at AS occurred_at,
    'reservation'::text AS kind,
    fl.facility_id,
    r.reservation_id AS ref_id,
    v.plate_number,
    s.code AS slot_code,
    NULL::numeric AS amount,
    (r.status)::text AS detail
   FROM ((((public.reservation r
     JOIN public.slot s ON ((s.slot_id = r.slot_id)))
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
     JOIN public.vehicle v ON ((v.vehicle_id = r.vehicle_id)))
UNION ALL
 SELECT vi.detected_at AS occurred_at,
    'violation'::text AS kind,
    fl.facility_id,
    vi.violation_id AS ref_id,
    v.plate_number,
    s.code AS slot_code,
    vi.penalty_amount AS amount,
    (vi.kind)::text AS detail
   FROM ((((public.violation vi
     JOIN public.vehicle v ON ((v.vehicle_id = vi.vehicle_id)))
     LEFT JOIN public.slot s ON ((s.slot_id = vi.slot_id)))
     LEFT JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     LEFT JOIN public.floor fl ON ((fl.floor_id = z.floor_id)));


--
-- Name: v_revenue_daily; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_revenue_daily WITH (security_invoker='true') AS
 SELECT fl.facility_id,
    ((b.generated_at AT TIME ZONE 'Asia/Kolkata'::text))::date AS revenue_date,
    count(DISTINCT b.bill_id) AS bills_raised,
    sum(b.base_amount) AS base_revenue,
    sum(b.tax_amount) AS tax_collected,
    sum(b.total_amount) AS billed_total,
    COALESCE(sum(p.paid), (0)::numeric) AS collected_total,
    (sum(b.total_amount) - COALESCE(sum(p.paid), (0)::numeric)) AS outstanding_total,
    round(avg(b.total_amount), 2) AS avg_bill_value
   FROM (((((public.bill b
     JOIN public.parking_session ps ON ((ps.session_id = b.session_id)))
     JOIN public.slot s ON ((s.slot_id = ps.slot_id)))
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
     LEFT JOIN LATERAL ( SELECT COALESCE(sum(pay.amount), (0)::numeric) AS paid
           FROM public.payment pay
          WHERE (pay.bill_id = b.bill_id)) p ON (true))
  GROUP BY fl.facility_id, (((b.generated_at AT TIME ZONE 'Asia/Kolkata'::text))::date);


--
-- Name: v_session_duration; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_session_duration WITH (security_invoker='true') AS
 SELECT ps.session_id,
    ps.ticket_no,
    fl.facility_id,
    v.plate_number,
    c.customer_id,
    c.full_name AS customer_name,
    vt.name AS vehicle_type_name,
    s.code AS slot_code,
    ps.entry_time,
    ps.exit_time,
    (ps.exit_time IS NULL) AS is_active,
    (round((EXTRACT(epoch FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0)))::integer AS duration_minutes,
        CASE
            WHEN ((EXTRACT(epoch FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0) < (30)::numeric) THEN 'under_30m'::text
            WHEN ((EXTRACT(epoch FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0) < (120)::numeric) THEN '30m_2h'::text
            WHEN ((EXTRACT(epoch FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0) < (480)::numeric) THEN '2h_8h'::text
            WHEN ((EXTRACT(epoch FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0) < (1440)::numeric) THEN '8h_24h'::text
            ELSE 'over_24h'::text
        END AS duration_bucket,
    b.total_amount
   FROM (((((((public.parking_session ps
     JOIN public.slot s ON ((s.slot_id = ps.slot_id)))
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
     JOIN public.vehicle v ON ((v.vehicle_id = ps.vehicle_id)))
     JOIN public.vehicle_type vt ON ((vt.vehicle_type_id = ps.vehicle_type_id)))
     JOIN public.customer c ON ((c.customer_id = v.customer_id)))
     LEFT JOIN public.bill b ON ((b.session_id = ps.session_id)));


--
-- Name: v_violations; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_violations WITH (security_invoker='true') AS
 SELECT vi.violation_id,
    vi.kind,
    vi.detected_at,
    vi.penalty_amount,
    vi.notes,
    (vi.resolved_at IS NOT NULL) AS is_resolved,
    vi.resolved_at,
    fl.facility_id,
    v.vehicle_id,
    v.plate_number,
    c.customer_id,
    c.full_name AS customer_name,
    c.phone AS customer_phone,
    s.code AS slot_code,
    ps.ticket_no,
    ps.entry_time,
    ps.exit_time
   FROM ((((((public.violation vi
     JOIN public.vehicle v ON ((v.vehicle_id = vi.vehicle_id)))
     JOIN public.customer c ON ((c.customer_id = v.customer_id)))
     LEFT JOIN public.slot s ON ((s.slot_id = vi.slot_id)))
     LEFT JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     LEFT JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
     LEFT JOIN public.parking_session ps ON ((ps.session_id = vi.session_id)));


--
-- Name: vehicle_type_vehicle_type_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.vehicle_type ALTER COLUMN vehicle_type_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.vehicle_type_vehicle_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: vehicle_vehicle_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.vehicle ALTER COLUMN vehicle_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.vehicle_vehicle_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: violation_violation_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.violation ALTER COLUMN violation_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.violation_violation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: zone_zone_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.zone ALTER COLUMN zone_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.zone_zone_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: app_user app_user_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user
    ADD CONSTRAINT app_user_email_key UNIQUE (email);


--
-- Name: app_user app_user_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user
    ADD CONSTRAINT app_user_pkey PRIMARY KEY (user_id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (audit_id);


--
-- Name: bill bill_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bill
    ADD CONSTRAINT bill_pkey PRIMARY KEY (bill_id);


--
-- Name: bill bill_session_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bill
    ADD CONSTRAINT bill_session_id_key UNIQUE (session_id);


--
-- Name: customer customer_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_email_key UNIQUE (email);


--
-- Name: customer customer_phone_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_phone_key UNIQUE (phone);


--
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (customer_id);


--
-- Name: customer customer_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_user_id_key UNIQUE (user_id);


--
-- Name: parking_pass ex_pass_no_overlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_pass
    ADD CONSTRAINT ex_pass_no_overlap EXCLUDE USING gist (vehicle_id WITH =, facility_id WITH =, tstzrange(valid_from, valid_to) WITH &&) WHERE ((cancelled_at IS NULL));


--
-- Name: reservation ex_reservation_no_overlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservation
    ADD CONSTRAINT ex_reservation_no_overlap EXCLUDE USING gist (slot_id WITH =, tstzrange(reserved_from, reserved_until) WITH &&) WHERE ((status = ANY (ARRAY['held'::public.reservation_status, 'confirmed'::public.reservation_status])));


--
-- Name: tariff ex_tariff_no_overlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tariff
    ADD CONSTRAINT ex_tariff_no_overlap EXCLUDE USING gist (facility_id WITH =, vehicle_type_id WITH =, tstzrange(effective_from, effective_to) WITH &&);


--
-- Name: facility facility_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facility
    ADD CONSTRAINT facility_name_key UNIQUE (name);


--
-- Name: facility facility_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facility
    ADD CONSTRAINT facility_pkey PRIMARY KEY (facility_id);


--
-- Name: floor floor_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floor
    ADD CONSTRAINT floor_pkey PRIMARY KEY (floor_id);


--
-- Name: parking_pass parking_pass_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_pass
    ADD CONSTRAINT parking_pass_pkey PRIMARY KEY (pass_id);


--
-- Name: parking_session parking_session_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_session
    ADD CONSTRAINT parking_session_pkey PRIMARY KEY (session_id);


--
-- Name: parking_session parking_session_reservation_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_session
    ADD CONSTRAINT parking_session_reservation_id_key UNIQUE (reservation_id);


--
-- Name: parking_session parking_session_ticket_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_session
    ADD CONSTRAINT parking_session_ticket_no_key UNIQUE (ticket_no);


--
-- Name: pass_type pass_type_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pass_type
    ADD CONSTRAINT pass_type_code_key UNIQUE (code);


--
-- Name: pass_type pass_type_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pass_type
    ADD CONSTRAINT pass_type_pkey PRIMARY KEY (pass_type_id);


--
-- Name: payment payment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment
    ADD CONSTRAINT payment_pkey PRIMARY KEY (payment_id);


--
-- Name: reservation reservation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservation
    ADD CONSTRAINT reservation_pkey PRIMARY KEY (reservation_id);


--
-- Name: slot slot_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slot
    ADD CONSTRAINT slot_pkey PRIMARY KEY (slot_id);


--
-- Name: tariff tariff_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tariff
    ADD CONSTRAINT tariff_pkey PRIMARY KEY (tariff_id);


--
-- Name: floor uq_floor_facility_level; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floor
    ADD CONSTRAINT uq_floor_facility_level UNIQUE (facility_id, level_number);


--
-- Name: slot uq_slot_id_vehicle_type; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slot
    ADD CONSTRAINT uq_slot_id_vehicle_type UNIQUE (slot_id, vehicle_type_id);


--
-- Name: slot uq_slot_zone_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slot
    ADD CONSTRAINT uq_slot_zone_code UNIQUE (zone_id, code);


--
-- Name: vehicle uq_vehicle_id_customer; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicle
    ADD CONSTRAINT uq_vehicle_id_customer UNIQUE (vehicle_id, customer_id);


--
-- Name: vehicle uq_vehicle_id_vehicle_type; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicle
    ADD CONSTRAINT uq_vehicle_id_vehicle_type UNIQUE (vehicle_id, vehicle_type_id);


--
-- Name: zone uq_zone_floor_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zone
    ADD CONSTRAINT uq_zone_floor_code UNIQUE (floor_id, code);


--
-- Name: vehicle vehicle_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicle
    ADD CONSTRAINT vehicle_pkey PRIMARY KEY (vehicle_id);


--
-- Name: vehicle vehicle_plate_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicle
    ADD CONSTRAINT vehicle_plate_number_key UNIQUE (plate_number);


--
-- Name: vehicle_type vehicle_type_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicle_type
    ADD CONSTRAINT vehicle_type_code_key UNIQUE (code);


--
-- Name: vehicle_type vehicle_type_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicle_type
    ADD CONSTRAINT vehicle_type_pkey PRIMARY KEY (vehicle_type_id);


--
-- Name: violation violation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.violation
    ADD CONSTRAINT violation_pkey PRIMARY KEY (violation_id);


--
-- Name: zone zone_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zone
    ADD CONSTRAINT zone_pkey PRIMARY KEY (zone_id);


--
-- Name: ix_audit_occurred; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_audit_occurred ON public.audit_log USING btree (occurred_at DESC);


--
-- Name: ix_audit_row; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_audit_row ON public.audit_log USING btree (table_name, row_id);


--
-- Name: ix_bill_status_generated; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_bill_status_generated ON public.bill USING btree (status, generated_at DESC);


--
-- Name: ix_customer_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_customer_user ON public.customer USING btree (user_id);


--
-- Name: ix_floor_facility; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_floor_facility ON public.floor USING btree (facility_id);


--
-- Name: ix_pass_vehicle_window; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pass_vehicle_window ON public.parking_pass USING btree (vehicle_id, valid_from, valid_to) WHERE (cancelled_at IS NULL);


--
-- Name: ix_payment_bill; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_payment_bill ON public.payment USING btree (bill_id);


--
-- Name: ix_payment_paid_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_payment_paid_at ON public.payment USING btree (paid_at DESC);


--
-- Name: ix_reservation_slot_window; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_reservation_slot_window ON public.reservation USING gist (slot_id, tstzrange(reserved_from, reserved_until)) WHERE (status = ANY (ARRAY['held'::public.reservation_status, 'confirmed'::public.reservation_status]));


--
-- Name: ix_reservation_status_until; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_reservation_status_until ON public.reservation USING btree (status, reserved_until);


--
-- Name: ix_session_entry_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_session_entry_time ON public.parking_session USING btree (entry_time DESC);


--
-- Name: ix_session_open_by_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_session_open_by_slot ON public.parking_session USING btree (slot_id) WHERE (exit_time IS NULL);


--
-- Name: ix_session_open_by_vehicle; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_session_open_by_vehicle ON public.parking_session USING btree (vehicle_id) WHERE (exit_time IS NULL);


--
-- Name: ix_slot_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_slot_type ON public.slot USING btree (vehicle_type_id);


--
-- Name: ix_slot_zone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_slot_zone ON public.slot USING btree (zone_id);


--
-- Name: ix_vehicle_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_vehicle_customer ON public.vehicle USING btree (customer_id);


--
-- Name: ix_vehicle_plate_upper; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_vehicle_plate_upper ON public.vehicle USING btree (upper(plate_number));


--
-- Name: ix_violation_detected; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_violation_detected ON public.violation USING btree (detected_at DESC);


--
-- Name: ix_violation_unresolved; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_violation_unresolved ON public.violation USING btree (kind, detected_at DESC) WHERE (resolved_at IS NULL);


--
-- Name: ix_zone_floor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_zone_floor ON public.zone USING btree (floor_id);


--
-- Name: uq_active_session_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_active_session_slot ON public.parking_session USING btree (slot_id) WHERE (exit_time IS NULL);


--
-- Name: uq_active_session_vehicle; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_active_session_vehicle ON public.parking_session USING btree (vehicle_id) WHERE (exit_time IS NULL);


--
-- Name: bill trg_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit AFTER INSERT OR DELETE OR UPDATE ON public.bill FOR EACH ROW EXECUTE FUNCTION public.fn_audit_row('bill_id');


--
-- Name: customer trg_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit AFTER INSERT OR DELETE OR UPDATE ON public.customer FOR EACH ROW EXECUTE FUNCTION public.fn_audit_row('customer_id');


--
-- Name: parking_pass trg_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit AFTER INSERT OR DELETE OR UPDATE ON public.parking_pass FOR EACH ROW EXECUTE FUNCTION public.fn_audit_row('pass_id');


--
-- Name: parking_session trg_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit AFTER INSERT OR DELETE OR UPDATE ON public.parking_session FOR EACH ROW EXECUTE FUNCTION public.fn_audit_row('session_id');


--
-- Name: payment trg_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit AFTER INSERT OR DELETE OR UPDATE ON public.payment FOR EACH ROW EXECUTE FUNCTION public.fn_audit_row('payment_id');


--
-- Name: reservation trg_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit AFTER INSERT OR DELETE OR UPDATE ON public.reservation FOR EACH ROW EXECUTE FUNCTION public.fn_audit_row('reservation_id');


--
-- Name: slot trg_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit AFTER INSERT OR DELETE OR UPDATE ON public.slot FOR EACH ROW EXECUTE FUNCTION public.fn_audit_row('slot_id');


--
-- Name: tariff trg_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit AFTER INSERT OR DELETE OR UPDATE ON public.tariff FOR EACH ROW EXECUTE FUNCTION public.fn_audit_row('tariff_id');


--
-- Name: vehicle trg_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit AFTER INSERT OR DELETE OR UPDATE ON public.vehicle FOR EACH ROW EXECUTE FUNCTION public.fn_audit_row('vehicle_id');


--
-- Name: violation trg_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit AFTER INSERT OR DELETE OR UPDATE ON public.violation FOR EACH ROW EXECUTE FUNCTION public.fn_audit_row('violation_id');


--
-- Name: bill trg_bill_enforce_amounts; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_bill_enforce_amounts BEFORE INSERT OR UPDATE OF session_id, base_amount, tax_amount ON public.bill FOR EACH ROW EXECUTE FUNCTION public.fn_bill_enforce_amounts();


--
-- Name: payment trg_payment_sync_bill_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_payment_sync_bill_status AFTER INSERT OR DELETE OR UPDATE ON public.payment FOR EACH ROW EXECUTE FUNCTION public.fn_payment_sync_bill_status();


--
-- Name: payment trg_payment_within_balance; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_payment_within_balance BEFORE INSERT OR UPDATE OF amount, bill_id ON public.payment FOR EACH ROW EXECUTE FUNCTION public.fn_payment_within_balance();


--
-- Name: reservation trg_reservation_prepare; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_reservation_prepare BEFORE INSERT OR UPDATE OF slot_id, vehicle_id ON public.reservation FOR EACH ROW EXECUTE FUNCTION public.fn_reservation_prepare();


--
-- Name: app_user fk_app_user_facility; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user
    ADD CONSTRAINT fk_app_user_facility FOREIGN KEY (facility_id) REFERENCES public.facility(facility_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: audit_log fk_audit_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT fk_audit_actor FOREIGN KEY (actor_user_id) REFERENCES public.app_user(user_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: bill fk_bill_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bill
    ADD CONSTRAINT fk_bill_session FOREIGN KEY (session_id) REFERENCES public.parking_session(session_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: bill fk_bill_tariff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bill
    ADD CONSTRAINT fk_bill_tariff FOREIGN KEY (tariff_id) REFERENCES public.tariff(tariff_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: customer fk_customer_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT fk_customer_user FOREIGN KEY (user_id) REFERENCES public.app_user(user_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: floor fk_floor_facility; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floor
    ADD CONSTRAINT fk_floor_facility FOREIGN KEY (facility_id) REFERENCES public.facility(facility_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: parking_pass fk_pass_customer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_pass
    ADD CONSTRAINT fk_pass_customer FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: parking_pass fk_pass_facility; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_pass
    ADD CONSTRAINT fk_pass_facility FOREIGN KEY (facility_id) REFERENCES public.facility(facility_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: parking_pass fk_pass_type; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_pass
    ADD CONSTRAINT fk_pass_type FOREIGN KEY (pass_type_id) REFERENCES public.pass_type(pass_type_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: pass_type fk_pass_type_vehicle_type; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pass_type
    ADD CONSTRAINT fk_pass_type_vehicle_type FOREIGN KEY (vehicle_type_id) REFERENCES public.vehicle_type(vehicle_type_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: parking_pass fk_pass_vehicle; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_pass
    ADD CONSTRAINT fk_pass_vehicle FOREIGN KEY (vehicle_id) REFERENCES public.vehicle(vehicle_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: parking_pass fk_pass_vehicle_owner; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_pass
    ADD CONSTRAINT fk_pass_vehicle_owner FOREIGN KEY (vehicle_id, customer_id) REFERENCES public.vehicle(vehicle_id, customer_id);


--
-- Name: payment fk_payment_bill; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment
    ADD CONSTRAINT fk_payment_bill FOREIGN KEY (bill_id) REFERENCES public.bill(bill_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: payment fk_payment_received_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment
    ADD CONSTRAINT fk_payment_received_by FOREIGN KEY (received_by) REFERENCES public.app_user(user_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: reservation fk_reservation_customer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservation
    ADD CONSTRAINT fk_reservation_customer FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: reservation fk_reservation_slot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservation
    ADD CONSTRAINT fk_reservation_slot FOREIGN KEY (slot_id) REFERENCES public.slot(slot_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: reservation fk_reservation_slot_type_match; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservation
    ADD CONSTRAINT fk_reservation_slot_type_match FOREIGN KEY (slot_id, vehicle_type_id) REFERENCES public.slot(slot_id, vehicle_type_id);


--
-- Name: reservation fk_reservation_vehicle; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservation
    ADD CONSTRAINT fk_reservation_vehicle FOREIGN KEY (vehicle_id) REFERENCES public.vehicle(vehicle_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: reservation fk_reservation_vehicle_owner; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservation
    ADD CONSTRAINT fk_reservation_vehicle_owner FOREIGN KEY (vehicle_id, customer_id) REFERENCES public.vehicle(vehicle_id, customer_id);


--
-- Name: reservation fk_reservation_vehicle_type_match; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservation
    ADD CONSTRAINT fk_reservation_vehicle_type_match FOREIGN KEY (vehicle_id, vehicle_type_id) REFERENCES public.vehicle(vehicle_id, vehicle_type_id);


--
-- Name: parking_session fk_session_entry_operator; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_session
    ADD CONSTRAINT fk_session_entry_operator FOREIGN KEY (entry_operator_id) REFERENCES public.app_user(user_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: parking_session fk_session_exit_operator; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_session
    ADD CONSTRAINT fk_session_exit_operator FOREIGN KEY (exit_operator_id) REFERENCES public.app_user(user_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: parking_session fk_session_pass; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_session
    ADD CONSTRAINT fk_session_pass FOREIGN KEY (pass_id) REFERENCES public.parking_pass(pass_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: parking_session fk_session_reservation; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_session
    ADD CONSTRAINT fk_session_reservation FOREIGN KEY (reservation_id) REFERENCES public.reservation(reservation_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: parking_session fk_session_slot_type_match; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_session
    ADD CONSTRAINT fk_session_slot_type_match FOREIGN KEY (slot_id, vehicle_type_id) REFERENCES public.slot(slot_id, vehicle_type_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: parking_session fk_session_vehicle_type_match; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parking_session
    ADD CONSTRAINT fk_session_vehicle_type_match FOREIGN KEY (vehicle_id, vehicle_type_id) REFERENCES public.vehicle(vehicle_id, vehicle_type_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: slot fk_slot_vehicle_type; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slot
    ADD CONSTRAINT fk_slot_vehicle_type FOREIGN KEY (vehicle_type_id) REFERENCES public.vehicle_type(vehicle_type_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: slot fk_slot_zone; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slot
    ADD CONSTRAINT fk_slot_zone FOREIGN KEY (zone_id) REFERENCES public.zone(zone_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: tariff fk_tariff_facility; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tariff
    ADD CONSTRAINT fk_tariff_facility FOREIGN KEY (facility_id) REFERENCES public.facility(facility_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: tariff fk_tariff_vehicle_type; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tariff
    ADD CONSTRAINT fk_tariff_vehicle_type FOREIGN KEY (vehicle_type_id) REFERENCES public.vehicle_type(vehicle_type_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: vehicle fk_vehicle_customer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicle
    ADD CONSTRAINT fk_vehicle_customer FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: vehicle fk_vehicle_vehicle_type; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicle
    ADD CONSTRAINT fk_vehicle_vehicle_type FOREIGN KEY (vehicle_type_id) REFERENCES public.vehicle_type(vehicle_type_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: violation fk_violation_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.violation
    ADD CONSTRAINT fk_violation_session FOREIGN KEY (session_id) REFERENCES public.parking_session(session_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: violation fk_violation_slot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.violation
    ADD CONSTRAINT fk_violation_slot FOREIGN KEY (slot_id) REFERENCES public.slot(slot_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: violation fk_violation_vehicle; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.violation
    ADD CONSTRAINT fk_violation_vehicle FOREIGN KEY (vehicle_id) REFERENCES public.vehicle(vehicle_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: zone fk_zone_floor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zone
    ADD CONSTRAINT fk_zone_floor FOREIGN KEY (floor_id) REFERENCES public.floor(floor_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: app_user; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_user ENABLE ROW LEVEL SECURITY;

--
-- Name: bill; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bill ENABLE ROW LEVEL SECURITY;

--
-- Name: customer; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer ENABLE ROW LEVEL SECURITY;

--
-- Name: bill p_bill_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_bill_admin ON public.bill USING ((public.fn_current_role() = 'admin'::public.user_role)) WITH CHECK ((public.fn_current_role() = 'admin'::public.user_role));


--
-- Name: bill p_bill_operator; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_bill_operator ON public.bill USING (((public.fn_current_role() = 'operator'::public.user_role) AND (EXISTS ( SELECT 1
   FROM (((public.parking_session ps
     JOIN public.slot s ON ((s.slot_id = ps.slot_id)))
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
  WHERE ((ps.session_id = bill.session_id) AND (fl.facility_id = public.fn_current_facility_id())))))) WITH CHECK ((public.fn_current_role() = 'operator'::public.user_role));


--
-- Name: bill p_bill_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_bill_own ON public.bill FOR SELECT USING ((EXISTS ( SELECT 1
   FROM (public.parking_session ps
     JOIN public.vehicle v ON ((v.vehicle_id = ps.vehicle_id)))
  WHERE ((ps.session_id = bill.session_id) AND (v.customer_id = public.fn_current_customer_id())))));


--
-- Name: customer p_customer_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_customer_admin ON public.customer USING ((public.fn_current_role() = 'admin'::public.user_role)) WITH CHECK ((public.fn_current_role() = 'admin'::public.user_role));


--
-- Name: customer p_customer_operator; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_customer_operator ON public.customer USING ((public.fn_current_role() = 'operator'::public.user_role)) WITH CHECK ((public.fn_current_role() = 'operator'::public.user_role));


--
-- Name: customer p_customer_self; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_customer_self ON public.customer FOR SELECT USING ((user_id = public.fn_current_user_id()));


--
-- Name: parking_pass p_pass_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_pass_admin ON public.parking_pass USING ((public.fn_current_role() = 'admin'::public.user_role)) WITH CHECK ((public.fn_current_role() = 'admin'::public.user_role));


--
-- Name: parking_pass p_pass_operator; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_pass_operator ON public.parking_pass USING (((public.fn_current_role() = 'operator'::public.user_role) AND (facility_id = public.fn_current_facility_id()))) WITH CHECK (((public.fn_current_role() = 'operator'::public.user_role) AND (facility_id = public.fn_current_facility_id())));


--
-- Name: parking_pass p_pass_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_pass_own ON public.parking_pass USING ((customer_id = public.fn_current_customer_id())) WITH CHECK ((customer_id = public.fn_current_customer_id()));


--
-- Name: payment p_payment_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_payment_admin ON public.payment USING ((public.fn_current_role() = 'admin'::public.user_role)) WITH CHECK ((public.fn_current_role() = 'admin'::public.user_role));


--
-- Name: payment p_payment_operator; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_payment_operator ON public.payment USING (((public.fn_current_role() = 'operator'::public.user_role) AND (EXISTS ( SELECT 1
   FROM ((((public.bill b
     JOIN public.parking_session ps ON ((ps.session_id = b.session_id)))
     JOIN public.slot s ON ((s.slot_id = ps.slot_id)))
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
  WHERE ((b.bill_id = payment.bill_id) AND (fl.facility_id = public.fn_current_facility_id())))))) WITH CHECK (((public.fn_current_role() = 'operator'::public.user_role) AND (EXISTS ( SELECT 1
   FROM ((((public.bill b
     JOIN public.parking_session ps ON ((ps.session_id = b.session_id)))
     JOIN public.slot s ON ((s.slot_id = ps.slot_id)))
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
  WHERE ((b.bill_id = payment.bill_id) AND (fl.facility_id = public.fn_current_facility_id()))))));


--
-- Name: payment p_payment_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_payment_own ON public.payment FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ((public.bill b
     JOIN public.parking_session ps ON ((ps.session_id = b.session_id)))
     JOIN public.vehicle v ON ((v.vehicle_id = ps.vehicle_id)))
  WHERE ((b.bill_id = payment.bill_id) AND (v.customer_id = public.fn_current_customer_id())))));


--
-- Name: reservation p_reservation_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_reservation_admin ON public.reservation USING ((public.fn_current_role() = 'admin'::public.user_role)) WITH CHECK ((public.fn_current_role() = 'admin'::public.user_role));


--
-- Name: reservation p_reservation_operator; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_reservation_operator ON public.reservation USING (((public.fn_current_role() = 'operator'::public.user_role) AND (EXISTS ( SELECT 1
   FROM ((public.slot s
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
  WHERE ((s.slot_id = reservation.slot_id) AND (fl.facility_id = public.fn_current_facility_id())))))) WITH CHECK ((public.fn_current_role() = 'operator'::public.user_role));


--
-- Name: reservation p_reservation_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_reservation_own ON public.reservation USING ((customer_id = public.fn_current_customer_id())) WITH CHECK ((customer_id = public.fn_current_customer_id()));


--
-- Name: parking_session p_session_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_session_admin ON public.parking_session USING ((public.fn_current_role() = 'admin'::public.user_role)) WITH CHECK ((public.fn_current_role() = 'admin'::public.user_role));


--
-- Name: parking_session p_session_operator; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_session_operator ON public.parking_session USING (((public.fn_current_role() = 'operator'::public.user_role) AND (EXISTS ( SELECT 1
   FROM ((public.slot s
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
  WHERE ((s.slot_id = parking_session.slot_id) AND (fl.facility_id = public.fn_current_facility_id())))))) WITH CHECK ((public.fn_current_role() = 'operator'::public.user_role));


--
-- Name: parking_session p_session_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_session_own ON public.parking_session FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.vehicle v
  WHERE ((v.vehicle_id = parking_session.vehicle_id) AND (v.customer_id = public.fn_current_customer_id())))));


--
-- Name: app_user p_user_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_user_admin_all ON public.app_user USING ((public.fn_current_role() = 'admin'::public.user_role)) WITH CHECK ((public.fn_current_role() = 'admin'::public.user_role));


--
-- Name: app_user p_user_self_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_user_self_read ON public.app_user FOR SELECT USING ((user_id = public.fn_current_user_id()));


--
-- Name: vehicle p_vehicle_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_vehicle_admin ON public.vehicle USING ((public.fn_current_role() = 'admin'::public.user_role)) WITH CHECK ((public.fn_current_role() = 'admin'::public.user_role));


--
-- Name: vehicle p_vehicle_operator; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_vehicle_operator ON public.vehicle USING ((public.fn_current_role() = 'operator'::public.user_role)) WITH CHECK ((public.fn_current_role() = 'operator'::public.user_role));


--
-- Name: vehicle p_vehicle_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_vehicle_own ON public.vehicle USING ((customer_id = public.fn_current_customer_id())) WITH CHECK ((customer_id = public.fn_current_customer_id()));


--
-- Name: violation p_violation_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_violation_admin ON public.violation USING ((public.fn_current_role() = 'admin'::public.user_role)) WITH CHECK ((public.fn_current_role() = 'admin'::public.user_role));


--
-- Name: violation p_violation_operator; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_violation_operator ON public.violation USING (((public.fn_current_role() = 'operator'::public.user_role) AND (EXISTS ( SELECT 1
   FROM ((public.slot s
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
  WHERE ((s.slot_id = COALESCE(violation.slot_id, ( SELECT ps.slot_id
           FROM public.parking_session ps
          WHERE (ps.session_id = violation.session_id)))) AND (fl.facility_id = public.fn_current_facility_id())))))) WITH CHECK (((public.fn_current_role() = 'operator'::public.user_role) AND (EXISTS ( SELECT 1
   FROM ((public.slot s
     JOIN public.zone z ON ((z.zone_id = s.zone_id)))
     JOIN public.floor fl ON ((fl.floor_id = z.floor_id)))
  WHERE ((s.slot_id = COALESCE(violation.slot_id, ( SELECT ps.slot_id
           FROM public.parking_session ps
          WHERE (ps.session_id = violation.session_id)))) AND (fl.facility_id = public.fn_current_facility_id()))))));


--
-- Name: violation p_violation_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY p_violation_own ON public.violation FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.vehicle v
  WHERE ((v.vehicle_id = violation.vehicle_id) AND (v.customer_id = public.fn_current_customer_id())))));


--
-- Name: parking_pass; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.parking_pass ENABLE ROW LEVEL SECURITY;

--
-- Name: parking_session; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.parking_session ENABLE ROW LEVEL SECURITY;

--
-- Name: payment; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payment ENABLE ROW LEVEL SECURITY;

--
-- Name: reservation; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reservation ENABLE ROW LEVEL SECURITY;

--
-- Name: vehicle; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vehicle ENABLE ROW LEVEL SECURITY;

--
-- Name: violation; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.violation ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO parking_admin;
GRANT USAGE ON SCHEMA public TO parking_operator;
GRANT USAGE ON SCHEMA public TO parking_customer;


--
-- Name: FUNCTION fn_allocate_slot(p_facility_id bigint, p_vehicle_type_id bigint, p_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_allocate_slot(p_facility_id bigint, p_vehicle_type_id bigint, p_at timestamp with time zone) TO parking_admin;
GRANT ALL ON FUNCTION public.fn_allocate_slot(p_facility_id bigint, p_vehicle_type_id bigint, p_at timestamp with time zone) TO parking_operator;


--
-- Name: FUNCTION fn_applicable_tariff(p_session_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_applicable_tariff(p_session_id bigint) TO parking_admin;
GRANT ALL ON FUNCTION public.fn_applicable_tariff(p_session_id bigint) TO parking_operator;
GRANT ALL ON FUNCTION public.fn_applicable_tariff(p_session_id bigint) TO parking_customer;


--
-- Name: FUNCTION fn_calculate_charge(p_session_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_calculate_charge(p_session_id bigint) TO parking_admin;
GRANT ALL ON FUNCTION public.fn_calculate_charge(p_session_id bigint) TO parking_operator;
GRANT ALL ON FUNCTION public.fn_calculate_charge(p_session_id bigint) TO parking_customer;


--
-- Name: FUNCTION fn_current_customer_id(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_current_customer_id() TO parking_admin;
GRANT ALL ON FUNCTION public.fn_current_customer_id() TO parking_operator;
GRANT ALL ON FUNCTION public.fn_current_customer_id() TO parking_customer;


--
-- Name: FUNCTION fn_current_facility_id(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_current_facility_id() TO parking_admin;
GRANT ALL ON FUNCTION public.fn_current_facility_id() TO parking_operator;
GRANT ALL ON FUNCTION public.fn_current_facility_id() TO parking_customer;


--
-- Name: FUNCTION fn_current_role(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_current_role() TO parking_admin;
GRANT ALL ON FUNCTION public.fn_current_role() TO parking_operator;
GRANT ALL ON FUNCTION public.fn_current_role() TO parking_customer;


--
-- Name: FUNCTION fn_current_user_id(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_current_user_id() TO parking_admin;
GRANT ALL ON FUNCTION public.fn_current_user_id() TO parking_operator;
GRANT ALL ON FUNCTION public.fn_current_user_id() TO parking_customer;


--
-- Name: FUNCTION fn_expire_stale_reservations(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_expire_stale_reservations() TO parking_admin;
GRANT ALL ON FUNCTION public.fn_expire_stale_reservations() TO parking_operator;
GRANT ALL ON FUNCTION public.fn_expire_stale_reservations() TO parking_customer;


--
-- Name: FUNCTION fn_gate_entry(p_plate text, p_facility_id bigint, p_operator_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_gate_entry(p_plate text, p_facility_id bigint, p_operator_id bigint) TO parking_admin;
GRANT ALL ON FUNCTION public.fn_gate_entry(p_plate text, p_facility_id bigint, p_operator_id bigint) TO parking_operator;


--
-- Name: FUNCTION fn_gate_exit(p_lookup text, p_operator_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_gate_exit(p_lookup text, p_operator_id bigint) TO parking_admin;
GRANT ALL ON FUNCTION public.fn_gate_exit(p_lookup text, p_operator_id bigint) TO parking_operator;


--
-- Name: FUNCTION fn_set_slot_service(p_slot_id bigint, p_in_service boolean, p_note text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_set_slot_service(p_slot_id bigint, p_in_service boolean, p_note text) TO parking_admin;
GRANT ALL ON FUNCTION public.fn_set_slot_service(p_slot_id bigint, p_in_service boolean, p_note text) TO parking_operator;


--
-- Name: TABLE app_user; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.app_user TO parking_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.app_user TO parking_operator;
GRANT SELECT ON TABLE public.app_user TO parking_customer;


--
-- Name: SEQUENCE app_user_user_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.app_user_user_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.app_user_user_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.app_user_user_id_seq TO parking_customer;


--
-- Name: TABLE audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.audit_log TO parking_admin;


--
-- Name: TABLE bill; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bill TO parking_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bill TO parking_operator;
GRANT SELECT ON TABLE public.bill TO parking_customer;


--
-- Name: SEQUENCE bill_bill_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.bill_bill_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.bill_bill_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.bill_bill_id_seq TO parking_customer;


--
-- Name: TABLE customer; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.customer TO parking_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.customer TO parking_operator;
GRANT SELECT ON TABLE public.customer TO parking_customer;


--
-- Name: SEQUENCE customer_customer_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.customer_customer_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.customer_customer_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.customer_customer_id_seq TO parking_customer;


--
-- Name: TABLE facility; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.facility TO parking_admin;
GRANT SELECT ON TABLE public.facility TO parking_operator;
GRANT SELECT ON TABLE public.facility TO parking_customer;


--
-- Name: SEQUENCE facility_facility_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.facility_facility_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.facility_facility_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.facility_facility_id_seq TO parking_customer;


--
-- Name: TABLE floor; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.floor TO parking_admin;
GRANT SELECT ON TABLE public.floor TO parking_operator;
GRANT SELECT ON TABLE public.floor TO parking_customer;


--
-- Name: SEQUENCE floor_floor_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.floor_floor_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.floor_floor_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.floor_floor_id_seq TO parking_customer;


--
-- Name: TABLE parking_pass; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.parking_pass TO parking_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.parking_pass TO parking_operator;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.parking_pass TO parking_customer;


--
-- Name: SEQUENCE parking_pass_pass_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.parking_pass_pass_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.parking_pass_pass_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.parking_pass_pass_id_seq TO parking_customer;


--
-- Name: TABLE parking_session; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.parking_session TO parking_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.parking_session TO parking_operator;
GRANT SELECT ON TABLE public.parking_session TO parking_customer;


--
-- Name: SEQUENCE parking_session_session_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.parking_session_session_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.parking_session_session_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.parking_session_session_id_seq TO parking_customer;


--
-- Name: TABLE pass_type; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pass_type TO parking_admin;
GRANT SELECT ON TABLE public.pass_type TO parking_operator;
GRANT SELECT ON TABLE public.pass_type TO parking_customer;


--
-- Name: SEQUENCE pass_type_pass_type_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.pass_type_pass_type_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.pass_type_pass_type_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.pass_type_pass_type_id_seq TO parking_customer;


--
-- Name: TABLE payment; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.payment TO parking_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.payment TO parking_operator;
GRANT SELECT ON TABLE public.payment TO parking_customer;


--
-- Name: SEQUENCE payment_payment_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.payment_payment_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.payment_payment_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.payment_payment_id_seq TO parking_customer;


--
-- Name: TABLE reservation; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.reservation TO parking_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.reservation TO parking_operator;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.reservation TO parking_customer;


--
-- Name: SEQUENCE reservation_reservation_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.reservation_reservation_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.reservation_reservation_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.reservation_reservation_id_seq TO parking_customer;


--
-- Name: TABLE slot; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.slot TO parking_admin;
GRANT SELECT ON TABLE public.slot TO parking_operator;
GRANT SELECT ON TABLE public.slot TO parking_customer;


--
-- Name: COLUMN slot.is_active; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(is_active) ON TABLE public.slot TO parking_admin;
GRANT UPDATE(is_active) ON TABLE public.slot TO parking_operator;


--
-- Name: COLUMN slot.service_note; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(service_note) ON TABLE public.slot TO parking_admin;
GRANT UPDATE(service_note) ON TABLE public.slot TO parking_operator;


--
-- Name: SEQUENCE slot_slot_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.slot_slot_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.slot_slot_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.slot_slot_id_seq TO parking_customer;


--
-- Name: TABLE tariff; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.tariff TO parking_admin;
GRANT SELECT ON TABLE public.tariff TO parking_operator;
GRANT SELECT ON TABLE public.tariff TO parking_customer;


--
-- Name: SEQUENCE tariff_tariff_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.tariff_tariff_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.tariff_tariff_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.tariff_tariff_id_seq TO parking_customer;


--
-- Name: TABLE vehicle; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.vehicle TO parking_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.vehicle TO parking_operator;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.vehicle TO parking_customer;


--
-- Name: TABLE vehicle_type; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.vehicle_type TO parking_admin;
GRANT SELECT ON TABLE public.vehicle_type TO parking_operator;
GRANT SELECT ON TABLE public.vehicle_type TO parking_customer;


--
-- Name: TABLE zone; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.zone TO parking_admin;
GRANT SELECT ON TABLE public.zone TO parking_operator;
GRANT SELECT ON TABLE public.zone TO parking_customer;


--
-- Name: TABLE v_current_occupancy; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_current_occupancy TO parking_admin;
GRANT SELECT ON TABLE public.v_current_occupancy TO parking_operator;
GRANT SELECT ON TABLE public.v_current_occupancy TO parking_customer;


--
-- Name: TABLE v_free_slots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_free_slots TO parking_admin;
GRANT SELECT ON TABLE public.v_free_slots TO parking_operator;
GRANT SELECT ON TABLE public.v_free_slots TO parking_customer;


--
-- Name: TABLE v_pass_usage; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_pass_usage TO parking_admin;
GRANT SELECT ON TABLE public.v_pass_usage TO parking_operator;
GRANT SELECT ON TABLE public.v_pass_usage TO parking_customer;


--
-- Name: TABLE v_peak_hours; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_peak_hours TO parking_admin;
GRANT SELECT ON TABLE public.v_peak_hours TO parking_operator;
GRANT SELECT ON TABLE public.v_peak_hours TO parking_customer;


--
-- Name: TABLE violation; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.violation TO parking_admin;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.violation TO parking_operator;
GRANT SELECT ON TABLE public.violation TO parking_customer;


--
-- Name: TABLE v_recent_activity; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_recent_activity TO parking_admin;
GRANT SELECT ON TABLE public.v_recent_activity TO parking_operator;
GRANT SELECT ON TABLE public.v_recent_activity TO parking_customer;


--
-- Name: TABLE v_revenue_daily; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_revenue_daily TO parking_admin;
GRANT SELECT ON TABLE public.v_revenue_daily TO parking_operator;
GRANT SELECT ON TABLE public.v_revenue_daily TO parking_customer;


--
-- Name: TABLE v_session_duration; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_session_duration TO parking_admin;
GRANT SELECT ON TABLE public.v_session_duration TO parking_operator;
GRANT SELECT ON TABLE public.v_session_duration TO parking_customer;


--
-- Name: TABLE v_violations; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_violations TO parking_admin;
GRANT SELECT ON TABLE public.v_violations TO parking_operator;
GRANT SELECT ON TABLE public.v_violations TO parking_customer;


--
-- Name: SEQUENCE vehicle_type_vehicle_type_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.vehicle_type_vehicle_type_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.vehicle_type_vehicle_type_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.vehicle_type_vehicle_type_id_seq TO parking_customer;


--
-- Name: SEQUENCE vehicle_vehicle_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.vehicle_vehicle_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.vehicle_vehicle_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.vehicle_vehicle_id_seq TO parking_customer;


--
-- Name: SEQUENCE violation_violation_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.violation_violation_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.violation_violation_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.violation_violation_id_seq TO parking_customer;


--
-- Name: SEQUENCE zone_zone_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.zone_zone_id_seq TO parking_admin;
GRANT SELECT,USAGE ON SEQUENCE public.zone_zone_id_seq TO parking_operator;
GRANT SELECT,USAGE ON SEQUENCE public.zone_zone_id_seq TO parking_customer;


--
-- PostgreSQL database dump complete
--



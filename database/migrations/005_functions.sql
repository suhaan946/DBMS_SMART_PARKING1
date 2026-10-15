-- ============================================================================
-- 005_functions.sql
--
-- Purpose: the behaviour that must live in the database rather than the API —
--          charge calculation, the locking slot allocation, gate exit, and the
--          reservation expiry sweep.
--
-- Everything here is written so that the API is a thin caller. Moving any of it
-- into Python would reintroduce the race conditions and the client-supplied
-- amounts the schema is designed to prevent.
-- ============================================================================

-- Idempotent DROP IF EXISTS guards below emit "does not exist, skipping"
-- notices on a first run. They are harmless, but they read like failures to
-- someone running this for the first time, so notices are quietened here.
-- Warnings and errors still come through.
SET client_min_messages = warning;


-- ---------------------------------------------------------------------------
-- BUSINESS RULE 5 — tariff-based charges.
--
-- fn_calculate_charge(session_id) is the single source of truth for money.
-- It reads the tariff that was in force at the session's entry_time (not the
-- tariff in force today), applies the grace period, the first-hour rate, the
-- subsequent-hour rate and the 24-hour cap, and returns the base amount.
--
-- A session covered by a valid pass returns 0.
-- A session still open is charged as if it ended now, so the gate screen can
-- show a live running total using exactly the same arithmetic as the final
-- bill — there is no second, approximate formula anywhere in the codebase.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_calculate_charge(p_session_id BIGINT)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
STABLE
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

COMMENT ON FUNCTION fn_calculate_charge(BIGINT) IS
  'BUSINESS RULE 5: the only place a parking charge is computed. Reads the tariff in force at entry_time.';


-- ---------------------------------------------------------------------------
-- fn_applicable_tariff — which tariff row a session will be billed against.
-- Split out so the bill trigger can record tariff_id without recomputing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_applicable_tariff(p_session_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
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


-- ---------------------------------------------------------------------------
-- Trigger: a bill's money is always the database's number, never the caller's.
--
-- Whatever base_amount a client sends is discarded and replaced with
-- fn_calculate_charge(session_id); tax is derived from the facility's rate.
-- This is what makes "bill.amount must derive from it, never from a
-- client-supplied number" true rather than merely intended.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_bill_enforce_amounts()
RETURNS TRIGGER
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
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_bill_enforce_amounts ON bill;
CREATE TRIGGER trg_bill_enforce_amounts
    BEFORE INSERT OR UPDATE OF session_id, base_amount, tax_amount ON bill
    FOR EACH ROW EXECUTE FUNCTION fn_bill_enforce_amounts();

COMMENT ON FUNCTION fn_bill_enforce_amounts() IS
  'Overwrites any client-supplied bill amount with the value from fn_calculate_charge.';


-- ---------------------------------------------------------------------------
-- Trigger: keep bill.status honest as payments arrive.
--
-- status is a function of SUM(payment.amount) against total_amount, so letting
-- a caller set it independently would allow a bill marked 'paid' with no
-- payments behind it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_payment_sync_bill_status()
RETURNS TRIGGER
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

DROP TRIGGER IF EXISTS trg_payment_sync_bill_status ON payment;
CREATE TRIGGER trg_payment_sync_bill_status
    AFTER INSERT OR UPDATE OR DELETE ON payment
    FOR EACH ROW EXECUTE FUNCTION fn_payment_sync_bill_status();

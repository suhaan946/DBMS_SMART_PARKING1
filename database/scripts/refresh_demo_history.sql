-- ============================================================================
-- refresh_demo_history.sql
--
-- The seed in 011_seed_history.sql writes 30 days of history ending at the
-- moment it runs. A database seeded weeks ago therefore shows an empty "today"
-- and an empty 14-day chart. This script moves every operational timestamp
-- forward by the same interval so the newest event lands at now().
--
--   psql -d smartpark -f db/scripts/refresh_demo_history.sql
--
-- Safe to re-run: it does nothing if the history is already current.
-- Durations, amounts and every relationship are unchanged; only the calendar
-- moves. Tariffs are left alone: stored bills already carry their amounts, and
-- new bills are priced at the tariff in force now.
-- ============================================================================
BEGIN;

DO $$
DECLARE
    v_delta INTERVAL;
    r       RECORD;
BEGIN
    -- A demo-data shift is maintenance, not activity worth auditing. The
    -- third argument scopes the setting to this transaction.
    PERFORM set_config('smartpark.audit', 'off', true);

    SELECT now() - GREATEST(
               (SELECT max(entry_time) FROM parking_session),
               (SELECT max(exit_time)  FROM parking_session),
               (SELECT max(paid_at)    FROM payment))
      INTO v_delta;

    IF v_delta IS NULL OR v_delta < INTERVAL '1 hour' THEN
        RAISE NOTICE 'Demo history is already current; nothing to shift.';
        RETURN;
    END IF;

    RAISE NOTICE 'Shifting demo history forward by %', date_trunc('minute', v_delta);

    -- Tables with no time-window exclusion constraint: one statement each.
    UPDATE parking_session SET entry_time = entry_time + v_delta,
                               exit_time  = exit_time  + v_delta;
    UPDATE bill            SET generated_at = generated_at + v_delta;
    UPDATE payment         SET paid_at      = paid_at      + v_delta;
    UPDATE violation       SET detected_at  = detected_at  + v_delta,
                               resolved_at  = resolved_at  + v_delta;

    -- Passes and reservations carry EXCLUDE constraints on their windows,
    -- checked row by row. Moving the newest row first means each row moves
    -- into space its successor has already vacated, so no intermediate state
    -- ever overlaps.
    FOR r IN SELECT pass_id FROM parking_pass ORDER BY valid_from DESC LOOP
        UPDATE parking_pass
           SET valid_from   = valid_from   + v_delta,
               valid_to     = valid_to     + v_delta,
               cancelled_at = cancelled_at + v_delta,
               created_at   = created_at   + v_delta
         WHERE pass_id = r.pass_id;
    END LOOP;

    FOR r IN SELECT reservation_id FROM reservation ORDER BY reserved_from DESC LOOP
        UPDATE reservation
           SET reserved_from  = reserved_from  + v_delta,
               reserved_until = reserved_until + v_delta,
               created_at     = created_at     + v_delta
         WHERE reservation_id = r.reservation_id;
    END LOOP;
END $$;

COMMIT;

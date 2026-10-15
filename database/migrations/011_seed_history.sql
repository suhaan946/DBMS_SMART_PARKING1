-- ============================================================================
-- 011_seed_history.sql
--
-- Purpose: 30 days of operating history — sessions, bills, payments,
--          reservations, passes and violations.
--
-- The arrival curve is the point of this file. Sessions are not scattered
-- uniformly: weekdays have a morning peak around 09:00-11:00 and an evening
-- peak around 17:00-20:00, weekends are flatter and lighter, and the small
-- hours are nearly empty. Without that shape the peak-hours report is a
-- straight line and proves nothing.
--
-- Slot reuse is tracked chronologically in a temporary table so no two cars
-- ever occupy one bay at the same moment. The partial unique index only
-- constrains currently-open sessions, so an incoherent history would have been
-- accepted by the database — it just would not survive a viva question.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Chronological slot-availability tracker.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE slot_free_at ON COMMIT DROP AS
SELECT s.slot_id,
       s.vehicle_type_id,
       fl.facility_id,
       (now() - INTERVAL '31 days') AS free_at
  FROM slot s
  JOIN zone  z  ON z.zone_id  = s.zone_id
  JOIN floor fl ON fl.floor_id = z.floor_id
 WHERE s.is_active;

CREATE INDEX ON slot_free_at (facility_id, vehicle_type_id, free_at);


-- ---------------------------------------------------------------------------
-- Historical sessions
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    -- Relative arrival weight per hour of day, index 0..23.
    -- Two peaks on a weekday; the array is scaled down at weekends below.
    w_weekday INTEGER[] := ARRAY[0,0,0,0,0,1,2,4,7,10,9,7,6,6,5,6,8,10,9,7,4,2,1,0];
    w_weekend INTEGER[] := ARRAY[0,0,0,0,0,0,1,2,3,4,5,6,6,6,5,5,6,6,5,4,3,2,1,0];

    d            INTEGER;
    h            INTEGER;
    k            INTEGER;
    v_day        DATE;
    v_dow        INTEGER;
    v_weight     INTEGER;
    v_arrivals   INTEGER;
    v_entry      TIMESTAMPTZ;
    v_exit       TIMESTAMPTZ;
    v_minutes    INTEGER;
    v_vehicle    RECORD;
    v_slot_id    BIGINT;
    v_facility   BIGINT;
    v_ticket     TEXT;
    v_operator   BIGINT;
    v_made       INTEGER := 0;
BEGIN
    -- 30 days back to yesterday.
    FOR d IN REVERSE 30..1 LOOP
        v_day := (now() - (d || ' days')::INTERVAL)::DATE;
        v_dow := EXTRACT(ISODOW FROM v_day);          -- 6,7 = Sat,Sun

        FOR h IN 0..23 LOOP
            v_weight := CASE WHEN v_dow >= 6 THEN w_weekend[h+1] ELSE w_weekday[h+1] END;
            IF v_weight = 0 THEN CONTINUE; END IF;

            -- Arrivals this hour: the weight, jittered, so no two days are
            -- identical and the chart does not look generated.
            v_arrivals := GREATEST(0, v_weight - 3 + floor(random() * 4)::INTEGER);

            FOR k IN 1..v_arrivals LOOP
                -- Riverside is the smaller site and takes roughly a quarter
                -- of the traffic.
                v_facility := CASE WHEN random() < 0.75 THEN 1 ELSE 2 END;

                SELECT vh.vehicle_id, vh.vehicle_type_id
                  INTO v_vehicle
                  FROM vehicle vh
                 ORDER BY random()
                 LIMIT 1;

                v_entry := v_day
                         + (h || ' hours')::INTERVAL
                         + (floor(random() * 60) || ' minutes')::INTERVAL;

                -- Stay length: a long tail. Most people are under four hours,
                -- office parkers sit for eight or nine, and a couple of cars a
                -- month are abandoned past the 24-hour overstay threshold.
                v_minutes := CASE
                    WHEN random() < 0.30 THEN 20  + floor(random() *  40)::INTEGER   -- quick errand
                    WHEN random() < 0.70 THEN 60  + floor(random() * 180)::INTEGER   -- shopping
                    WHEN random() < 0.94 THEN 300 + floor(random() * 300)::INTEGER   -- work day
                    ELSE                      1500 + floor(random() * 900)::INTEGER  -- overstay
                END;
                v_exit := v_entry + (v_minutes || ' minutes')::INTERVAL;

                -- Do not create history in the future.
                CONTINUE WHEN v_exit >= now() - INTERVAL '3 hours';

                -- Nearest bay of the right type that is free by then.
                SELECT sf.slot_id INTO v_slot_id
                  FROM slot_free_at sf
                 WHERE sf.facility_id     = v_facility
                   AND sf.vehicle_type_id = v_vehicle.vehicle_type_id
                   AND sf.free_at <= v_entry
                 ORDER BY sf.free_at
                 LIMIT 1;

                CONTINUE WHEN v_slot_id IS NULL;

                -- The same vehicle cannot already be parked at this instant.
                CONTINUE WHEN EXISTS (
                    SELECT 1 FROM parking_session ps
                     WHERE ps.vehicle_id = v_vehicle.vehicle_id
                       AND ps.entry_time < v_exit
                       AND COALESCE(ps.exit_time, now()) > v_entry
                );

                v_ticket := 'TK-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
                CONTINUE WHEN EXISTS (SELECT 1 FROM parking_session WHERE ticket_no = v_ticket);

                SELECT user_id INTO v_operator
                  FROM app_user
                 WHERE role = 'operator' AND facility_id = v_facility
                 ORDER BY random() LIMIT 1;

                INSERT INTO parking_session
                    (ticket_no, slot_id, vehicle_id, vehicle_type_id,
                     entry_time, exit_time, entry_operator_id, exit_operator_id)
                VALUES
                    (v_ticket, v_slot_id, v_vehicle.vehicle_id, v_vehicle.vehicle_type_id,
                     v_entry, v_exit, v_operator, v_operator);

                -- Bay is busy until the car leaves, plus a few minutes of
                -- manoeuvring.
                UPDATE slot_free_at
                   SET free_at = v_exit + INTERVAL '4 minutes'
                 WHERE slot_id = v_slot_id;

                v_made := v_made + 1;
            END LOOP;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'seeded % completed sessions', v_made;
END $$;


-- ---------------------------------------------------------------------------
-- Currently open sessions — the cars in the building right now.
-- Twenty of them, arriving over the last nine hours, each on its own bay and
-- each a different vehicle, so the two partial unique indexes are satisfied.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_vehicle  RECORD;
    v_slot_id  BIGINT;
    v_facility BIGINT;
    v_entry    TIMESTAMPTZ;
    v_ticket   TEXT;
    v_operator BIGINT;
    n          INTEGER := 0;
BEGIN
    FOR v_vehicle IN
        SELECT vh.vehicle_id, vh.vehicle_type_id
          FROM vehicle vh
         WHERE NOT EXISTS (
                 SELECT 1 FROM parking_session ps
                  WHERE ps.vehicle_id = vh.vehicle_id AND ps.exit_time IS NULL
               )
         ORDER BY random()
    LOOP
        EXIT WHEN n >= 20;

        v_facility := CASE WHEN random() < 0.8 THEN 1 ELSE 2 END;
        v_entry    := now() - ((10 + floor(random() * 520)) || ' minutes')::INTERVAL;

        SELECT s.slot_id INTO v_slot_id
          FROM slot s
          JOIN zone  z  ON z.zone_id  = s.zone_id
          JOIN floor fl ON fl.floor_id = z.floor_id
         WHERE fl.facility_id    = v_facility
           AND s.vehicle_type_id = v_vehicle.vehicle_type_id
           AND s.is_active
           AND NOT EXISTS (
                 SELECT 1 FROM parking_session ps
                  WHERE ps.slot_id = s.slot_id AND ps.exit_time IS NULL
               )
           -- Do not collide with the tail of the generated history.
           AND NOT EXISTS (
                 SELECT 1 FROM parking_session ps
                  WHERE ps.slot_id = s.slot_id AND ps.exit_time > v_entry
               )
         ORDER BY random()
         LIMIT 1;

        CONTINUE WHEN v_slot_id IS NULL;

        v_ticket := 'TK-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
        CONTINUE WHEN EXISTS (SELECT 1 FROM parking_session WHERE ticket_no = v_ticket);

        SELECT user_id INTO v_operator
          FROM app_user WHERE role='operator' AND facility_id = v_facility
         ORDER BY random() LIMIT 1;

        INSERT INTO parking_session
            (ticket_no, slot_id, vehicle_id, vehicle_type_id, entry_time, entry_operator_id)
        VALUES
            (v_ticket, v_slot_id, v_vehicle.vehicle_id, v_vehicle.vehicle_type_id,
             v_entry, v_operator);

        n := n + 1;
    END LOOP;

    RAISE NOTICE 'seeded % open sessions', n;
END $$;


-- ---------------------------------------------------------------------------
-- Bills for every completed session.
--
-- The zeros below are placeholders. trg_bill_enforce_amounts replaces
-- base_amount, tax_amount and billable_minutes with values derived from
-- fn_calculate_charge and the facility tax rate, so nothing on any report is a
-- number this file invented.
-- ---------------------------------------------------------------------------
INSERT INTO bill (session_id, tariff_id, billable_minutes, base_amount, tax_amount, generated_at)
SELECT ps.session_id,
       fn_applicable_tariff(ps.session_id),
       0, 0, 0,
       ps.exit_time
  FROM parking_session ps
 WHERE ps.exit_time IS NOT NULL
   AND fn_applicable_tariff(ps.session_id) IS NOT NULL;


-- ---------------------------------------------------------------------------
-- Payments.
--
-- Roughly 78% settled in full, 10% part-paid, 12% still outstanding - so the
-- revenue report has a real receivable to show rather than a tidy zero.
--
-- The bucket is chosen from a hash of bill_id, not from random(). A bare
-- random() in a non-correlated subquery is folded to a single constant for the
-- whole statement, which puts every row in the same bucket; hashing the key
-- gives a genuinely per-row spread and makes the seed reproducible.
--
-- bill.status is maintained by trg_payment_sync_bill_status, never set here.
-- ---------------------------------------------------------------------------
INSERT INTO payment (bill_id, amount, method, reference_no, paid_at, received_by)
SELECT b.bill_id,
       CASE WHEN r.bucket < 78 THEN b.total_amount
            ELSE ROUND(b.total_amount * 0.5, 2) END,
       (ARRAY['cash','card','upi','netbanking','wallet']::payment_method[])
           [1 + (abs(hashtext('m' || b.bill_id::TEXT)) % 5)],
       'RCPT-' || lpad(b.bill_id::TEXT, 6, '0'),
       b.generated_at + INTERVAL '2 minutes',
       (SELECT user_id FROM app_user WHERE role = 'operator'
         ORDER BY md5('op' || b.bill_id::TEXT) LIMIT 1)
  FROM bill b
  CROSS JOIN LATERAL (
      SELECT abs(hashtext('pay' || b.bill_id::TEXT)) % 100 AS bucket
  ) r
 WHERE b.total_amount > 0
   AND r.bucket < 88;

-- Sessions covered by a pass produce a zero bill; the trigger marks those paid.
UPDATE bill SET status = 'paid' WHERE total_amount = 0;


-- ---------------------------------------------------------------------------
-- Reservations in every status.
--
-- ex_reservation_no_overlap forbids two live holds on one slot at overlapping
-- times, so live holds are placed on distinct slots at staggered windows.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v RECORD;
    v_slot BIGINT;
    n INTEGER := 0;
    v_from TIMESTAMPTZ;
BEGIN
    -- Live holds, in the near future, on free bays.
    FOR v IN
        SELECT vh.vehicle_id, vh.customer_id, vh.vehicle_type_id
          FROM vehicle vh ORDER BY random() LIMIT 14
    LOOP
        -- The first five holds straddle this moment, so the floor map has a
        -- genuine 'reserved' state to render on load rather than only after
        -- half an hour has passed. The rest are staggered into the afternoon.
        IF n < 5 THEN
            v_from := now() - ((30 + n * 10) || ' minutes')::INTERVAL;
        ELSE
            v_from := now() + (((n - 5) * 90) + 30 || ' minutes')::INTERVAL;
        END IF;

        SELECT s.slot_id INTO v_slot
          FROM slot s
          JOIN zone  z  ON z.zone_id  = s.zone_id
          JOIN floor fl ON fl.floor_id = z.floor_id
         WHERE s.vehicle_type_id = v.vehicle_type_id
           AND s.is_active
           AND fl.facility_id = 1
           -- A bay that already has a car in it would render as 'occupied',
           -- which is correct but hides the state this seed is demonstrating.
           AND NOT EXISTS (
                 SELECT 1 FROM parking_session ps
                  WHERE ps.slot_id = s.slot_id AND ps.exit_time IS NULL
               )
           AND NOT EXISTS (
                 SELECT 1 FROM reservation r
                  WHERE r.slot_id = s.slot_id
                    AND r.status IN ('held','confirmed')
                    AND tstzrange(r.reserved_from, r.reserved_until)
                        && tstzrange(v_from, v_from + INTERVAL '2 hours')
               )
         ORDER BY random() LIMIT 1;

        CONTINUE WHEN v_slot IS NULL;

        INSERT INTO reservation (customer_id, vehicle_id, slot_id, reserved_from, reserved_until, status)
        VALUES (v.customer_id, v.vehicle_id, v_slot,
                v_from, v_from + INTERVAL '2 hours',
                CASE WHEN n % 2 = 0 THEN 'held'::reservation_status
                     ELSE 'confirmed'::reservation_status END);
        n := n + 1;
    END LOOP;

    -- Historical reservations: expired, cancelled and fulfilled. These do not
    -- participate in the exclusion constraint, so they can sit anywhere.
    INSERT INTO reservation (customer_id, vehicle_id, slot_id, reserved_from, reserved_until, status, created_at)
    SELECT vh.customer_id, vh.vehicle_id, s.slot_id,
           now() - ((g * 26) || ' hours')::INTERVAL,
           now() - ((g * 26) || ' hours')::INTERVAL + INTERVAL '2 hours',
           (ARRAY['expired','cancelled','fulfilled']::reservation_status[])[1 + (g % 3)],
           now() - ((g * 27) || ' hours')::INTERVAL
      FROM generate_series(1, 18) g
      CROSS JOIN LATERAL (
           SELECT vehicle_id, customer_id, vehicle_type_id
             FROM vehicle ORDER BY md5(g::text || vehicle_id::text) LIMIT 1
      ) vh
      CROSS JOIN LATERAL (
           SELECT s2.slot_id FROM slot s2
            WHERE s2.vehicle_type_id = vh.vehicle_type_id AND s2.is_active
            ORDER BY md5(g::text || s2.slot_id::text) LIMIT 1
      ) s;
END $$;


-- ---------------------------------------------------------------------------
-- Passes — active, scheduled, expired and cancelled.
-- ex_pass_no_overlap forbids two live passes on one vehicle at one facility,
-- so each vehicle below gets at most one live window.
-- ---------------------------------------------------------------------------
INSERT INTO parking_pass (customer_id, vehicle_id, pass_type_id, facility_id,
                          valid_from, valid_to, price_paid, created_at)
SELECT vh.customer_id, vh.vehicle_id, pt.pass_type_id, 1,
       date_trunc('day', now()) - INTERVAL '5 days',
       date_trunc('day', now()) - INTERVAL '5 days' + (pt.duration_days || ' days')::INTERVAL,
       pt.price,
       now() - INTERVAL '5 days'
  FROM (SELECT vehicle_id, customer_id, vehicle_type_id FROM vehicle ORDER BY vehicle_id LIMIT 9) vh
  JOIN pass_type pt ON pt.vehicle_type_id = vh.vehicle_type_id AND pt.code LIKE 'MONTH!_%' ESCAPE '!';

-- Expired monthly passes from last quarter.
INSERT INTO parking_pass (customer_id, vehicle_id, pass_type_id, facility_id,
                          valid_from, valid_to, price_paid, created_at)
SELECT vh.customer_id, vh.vehicle_id, pt.pass_type_id, 1,
       date_trunc('day', now()) - INTERVAL '80 days',
       date_trunc('day', now()) - INTERVAL '50 days',
       pt.price,
       now() - INTERVAL '80 days'
  FROM (SELECT vehicle_id, customer_id, vehicle_type_id FROM vehicle ORDER BY vehicle_id LIMIT 12) vh
  JOIN pass_type pt ON pt.vehicle_type_id = vh.vehicle_type_id AND pt.code LIKE 'MONTH!_%' ESCAPE '!';

-- Weekly passes at the second facility, so pass usage is not single-site.
INSERT INTO parking_pass (customer_id, vehicle_id, pass_type_id, facility_id,
                          valid_from, valid_to, price_paid, created_at)
SELECT vh.customer_id, vh.vehicle_id, pt.pass_type_id, 2,
       date_trunc('day', now()) - INTERVAL '2 days',
       date_trunc('day', now()) + INTERVAL '5 days',
       pt.price, now() - INTERVAL '2 days'
  FROM (SELECT vehicle_id, customer_id, vehicle_type_id FROM vehicle ORDER BY vehicle_id DESC LIMIT 6) vh
  JOIN pass_type pt ON pt.vehicle_type_id = vh.vehicle_type_id AND pt.code LIKE 'WEEK!_%' ESCAPE '!';

-- One cancelled pass, so the cancelled branch of v_pass_usage has a row.
UPDATE parking_pass
   SET cancelled_at = now() - INTERVAL '1 day'
 WHERE pass_id = (SELECT MIN(pass_id) FROM parking_pass);

-- Attach passes to the sessions they actually covered, so v_pass_usage counts
-- real usage rather than showing every pass as unused.
UPDATE parking_session ps
   SET pass_id = pp.pass_id
  FROM parking_pass pp
 WHERE ps.vehicle_id = pp.vehicle_id
   AND pp.cancelled_at IS NULL
   AND ps.entry_time >= pp.valid_from
   AND ps.entry_time <  pp.valid_to;


-- ---------------------------------------------------------------------------
-- Violations.
--
-- Overstays are derived from the history rather than invented: any completed
-- session longer than 24 hours is a genuine overstay in the data above.
-- ---------------------------------------------------------------------------
INSERT INTO violation (kind, session_id, vehicle_id, slot_id, detected_at, penalty_amount, notes)
SELECT 'overstay', ps.session_id, ps.vehicle_id, ps.slot_id, ps.exit_time, 200.00,
       format('Stay of %s hours exceeded the 24 hour limit',
              round(EXTRACT(EPOCH FROM (ps.exit_time - ps.entry_time))/3600.0, 1))
  FROM parking_session ps
 WHERE ps.exit_time IS NOT NULL
   AND ps.exit_time - ps.entry_time > INTERVAL '24 hours';

-- Wrong slot type: recorded by an operator who noticed a car in a bike bay
-- before the system was in place. Kept as a historical log entry.
INSERT INTO violation (kind, session_id, vehicle_id, slot_id, detected_at, penalty_amount, notes)
SELECT 'wrong_slot_type', NULL, v.vehicle_id, s.slot_id,
       now() - ((g * 3) || ' days')::INTERVAL, 150.00,
       'Vehicle parked in a bay allocated to another vehicle type'
  FROM generate_series(1, 4) g
  CROSS JOIN LATERAL (SELECT vehicle_id FROM vehicle ORDER BY md5(g::text||vehicle_id::text) LIMIT 1) v
  CROSS JOIN LATERAL (SELECT slot_id   FROM slot    ORDER BY md5(g::text||slot_id::text)    LIMIT 1) s;

-- No valid pass: entered a pass-holder bay without one.
INSERT INTO violation (kind, session_id, vehicle_id, slot_id, detected_at, penalty_amount, notes)
SELECT 'no_valid_pass', NULL, v.vehicle_id, NULL,
       now() - ((g * 5) || ' days')::INTERVAL, 100.00,
       'Claimed a pass at the gate; no valid pass found on file'
  FROM generate_series(1, 3) g
  CROSS JOIN LATERAL (SELECT vehicle_id FROM vehicle ORDER BY md5('p'||g::text||vehicle_id::text) LIMIT 1) v;

-- Unpaid exit: the bill was never settled.
INSERT INTO violation (kind, session_id, vehicle_id, slot_id, detected_at, penalty_amount, notes)
SELECT 'unpaid_exit', ps.session_id, ps.vehicle_id, ps.slot_id, ps.exit_time, 0,
       format('Bill %s left unpaid at exit', b.bill_id)
  FROM bill b
  JOIN parking_session ps ON ps.session_id = b.session_id
 WHERE b.status = 'unpaid' AND b.total_amount > 0
 ORDER BY b.generated_at DESC
 LIMIT 5;

-- Resolve a few, so the violations report has both states.
UPDATE violation
   SET resolved_at = detected_at + INTERVAL '2 days'
 WHERE violation_id IN (SELECT violation_id FROM violation ORDER BY detected_at LIMIT 4);

-- Run the expiry sweep once so no stale hold is left in the seed.
SELECT fn_expire_stale_reservations();

COMMIT;

-- ---------------------------------------------------------------------------
-- Refresh planner statistics.
--
-- Not cosmetic. On a freshly built database PostgreSQL has no statistics, so
-- it falls back to defaults (750 rows for any table) and picks nested loops
-- over what it thinks are single-row scans. Combined with row-level security
-- filters - whose selectivity it cannot estimate at all - that produced a
-- dashboard query taking 82 seconds against 1,600 rows. After ANALYZE the same
-- query runs in 38 ms.
--
-- Autovacuum would get here eventually; a demo that is opened two minutes
-- after seeding would not wait for it.
-- ---------------------------------------------------------------------------
ANALYZE;

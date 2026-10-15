-- ============================================================================
-- lifecycle_tests.sql
--
-- The time-driven rules that the constraint tests cannot show by rejection:
-- a hold that lapses, a stay that runs too long, and a pass that covers or has
-- run out. Everything happens inside one transaction that is rolled back, so
-- the demo data is untouched.
--
--     psql -d smartpark -f db/tests/lifecycle_tests.sql
--
-- Each check prints PASS or FAIL with the value it saw.
-- ============================================================================
\set ON_ERROR_STOP on
\pset pager off
\pset footer off

BEGIN;

-- A fresh customer with one car, so no seeded history interferes.
WITH c AS (
    INSERT INTO customer (full_name, phone, email)
    VALUES ('Lifecycle Test', '9000000001', 'lifecycle.test@example.com')
    RETURNING customer_id
)
INSERT INTO vehicle (customer_id, vehicle_type_id, plate_number, make, model)
SELECT customer_id, 2, 'KA01LT0001', 'Test', 'Car' FROM c;

SELECT vehicle_id AS vid, customer_id AS cid FROM vehicle WHERE plate_number = 'KA01LT0001' \gset

\echo ''
\echo 'LIFECYCLE 1  A lapsed reservation expires and is logged as a no-show'
-- Book a free car bay at Central for a window that has already ended. The
-- window CHECK only needs until > from; a past window stands in for a hold
-- the driver never turned up for.
SELECT s.slot_id AS sid
  FROM slot s JOIN zone z USING (zone_id) JOIN floor f USING (floor_id)
 WHERE f.facility_id = 1 AND s.vehicle_type_id = 2 AND s.is_active
   AND NOT EXISTS (SELECT 1 FROM parking_session ps WHERE ps.slot_id = s.slot_id AND ps.exit_time IS NULL)
   AND NOT EXISTS (SELECT 1 FROM reservation r WHERE r.slot_id = s.slot_id AND r.status IN ('held','confirmed'))
 ORDER BY s.slot_id LIMIT 1 \gset
INSERT INTO reservation (customer_id, vehicle_id, slot_id, reserved_from, reserved_until)
VALUES (:cid, :vid, :sid, now() - interval '2 hours', now() - interval '1 hour')
RETURNING reservation_id AS rid \gset
SELECT fn_expire_stale_reservations() AS expired_now;
SELECT CASE WHEN status = 'expired' THEN 'PASS' ELSE 'FAIL' END AS result,
       'reservation status is ' || status AS detail
  FROM reservation WHERE reservation_id = :rid;
SELECT CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS result,
       count(*) || ' no-show violation logged' AS detail
  FROM violation WHERE vehicle_id = :vid AND kind = 'reservation_no_show';
SELECT CASE WHEN fn_expire_stale_reservations() = 0
             AND (SELECT count(*) FROM violation WHERE vehicle_id = :vid) = 1
            THEN 'PASS' ELSE 'FAIL' END AS result,
       'running the sweep again changes nothing' AS detail;

\echo ''
\echo 'LIFECYCLE 2  A stay over 24 hours is billed and logged as an overstay'
SELECT session_id AS s1 FROM fn_gate_entry('KA01LT0001', 1, 1) \gset
-- Wind the entry back 30 hours, as if the car had been left overnight.
UPDATE parking_session SET entry_time = now() - interval '30 hours' WHERE session_id = :s1;
SELECT bill_id AS b1, billable_minutes, total_amount FROM fn_gate_exit('KA01LT0001', 1) \gset
SELECT CASE WHEN :total_amount > 0 AND :billable_minutes >= 1800 THEN 'PASS' ELSE 'FAIL' END AS result,
       format('%s minutes billed at Rs %s', :billable_minutes, :total_amount) AS detail;
SELECT CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS result,
       count(*) || ' overstay violation, penalty Rs ' || coalesce(max(penalty_amount), 0) AS detail
  FROM violation WHERE session_id = :s1 AND kind = 'overstay';
SELECT CASE WHEN exit_time IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS result,
       'the bay is released (session closed)' AS detail
  FROM parking_session WHERE session_id = :s1;

\echo ''
\echo 'LIFECYCLE 3  A live pass makes the stay free and the bill settles itself'
INSERT INTO parking_pass (customer_id, vehicle_id, pass_type_id, facility_id, valid_from, valid_to, price_paid)
VALUES (:cid, :vid, 7, 1, now() - interval '1 day', now() + interval '6 days', 1100)
RETURNING pass_id AS p1 \gset
SELECT session_id AS s2, pass_id AS used_pass FROM fn_gate_entry('KA01LT0001', 1, 1) \gset
SELECT CASE WHEN :'used_pass' = :'p1' THEN 'PASS' ELSE 'FAIL' END AS result,
       'entry attached pass ' || :'used_pass' AS detail;
UPDATE parking_session SET entry_time = now() - interval '3 hours' WHERE session_id = :s2;
SELECT bill_id AS b2, total_amount AS pass_total FROM fn_gate_exit('KA01LT0001', 1) \gset
SELECT CASE WHEN b.total_amount = 0 AND b.status = 'paid' THEN 'PASS' ELSE 'FAIL' END AS result,
       format('3-hour stay billed Rs %s, status %s', b.total_amount, b.status) AS detail
  FROM bill b WHERE b.bill_id = :b2;

\echo ''
\echo 'LIFECYCLE 4  An expired pass no longer covers the stay'
UPDATE parking_pass SET valid_from = now() - interval '8 days', valid_to = now() - interval '1 day'
 WHERE pass_id = :p1;
SELECT session_id AS s3, coalesce(pass_id::text, 'none') AS used_pass3 FROM fn_gate_entry('KA01LT0001', 1, 1) \gset
SELECT CASE WHEN :'used_pass3' = 'none' THEN 'PASS' ELSE 'FAIL' END AS result,
       'pass attached at entry: ' || :'used_pass3' AS detail;
UPDATE parking_session SET entry_time = now() - interval '3 hours' WHERE session_id = :s3;
SELECT bill_id AS b3 FROM fn_gate_exit('KA01LT0001', 1) \gset
SELECT CASE WHEN b.total_amount > 0 AND b.status = 'unpaid' THEN 'PASS' ELSE 'FAIL' END AS result,
       format('same 3-hour stay now billed Rs %s, status %s', b.total_amount, b.status) AS detail
  FROM bill b WHERE b.bill_id = :b3;

\echo ''
\echo 'LIFECYCLE 5  Billing is derived from the tariff, not typed in'
SELECT CASE WHEN b.base_amount = fn_calculate_charge(b.session_id)
             AND b.total_amount = b.base_amount + b.tax_amount
            THEN 'PASS' ELSE 'FAIL' END AS result,
       format('base Rs %s = fn_calculate_charge, tax Rs %s, total Rs %s',
              b.base_amount, b.tax_amount, b.total_amount) AS detail
  FROM bill b WHERE b.bill_id = :b3;

ROLLBACK;
\echo ''
\echo 'Rolled back - no demo data was changed.'

-- ============================================================================
-- constraint_tests.sql
--
-- Each block below deliberately violates one business rule and lets the
-- database reject it. Every statement runs inside its own savepoint so one
-- expected failure does not abort the rest of the script.
--
-- Run with:   psql -d smartpark -f db/tests/constraint_tests.sql
--
-- A constraint that has never been tested to failure is a constraint you
-- cannot defend in a viva. The captured output lives in docs/TESTING.md.
-- ============================================================================
\set ON_ERROR_STOP off
\timing off

\echo ''
\echo '=========================================================='
\echo 'TEST 1  BUSINESS RULE 1 - one active vehicle per slot'
\echo '  Attempt: open a second session on a slot that is already occupied.'
\echo '  Expect : unique violation on uq_active_session_slot'
\echo '=========================================================='
BEGIN;
INSERT INTO parking_session (ticket_no, slot_id, vehicle_id, vehicle_type_id, entry_time)
SELECT 'TK-DUP00001',
       ps.slot_id,                       -- a slot that is currently occupied
       v.vehicle_id,                     -- a different vehicle of the same type
       ps.vehicle_type_id,
       now()
  FROM parking_session ps
  JOIN vehicle v ON v.vehicle_type_id = ps.vehicle_type_id
                AND v.vehicle_id <> ps.vehicle_id
 WHERE ps.exit_time IS NULL
   AND NOT EXISTS (SELECT 1 FROM parking_session o
                    WHERE o.vehicle_id = v.vehicle_id AND o.exit_time IS NULL)
 LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 2  BUSINESS RULE 1 (mirror) - one active slot per vehicle'
\echo '  Attempt: park an already-parked vehicle in a second free bay.'
\echo '  Expect : unique violation on uq_active_session_vehicle'
\echo '=========================================================='
BEGIN;
INSERT INTO parking_session (ticket_no, slot_id, vehicle_id, vehicle_type_id, entry_time)
SELECT 'TK-DUP00002', fs.slot_id, ps.vehicle_id, ps.vehicle_type_id, now()
  FROM parking_session ps
  JOIN v_free_slots fs ON fs.vehicle_type_id = ps.vehicle_type_id
 WHERE ps.exit_time IS NULL
 LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 3  BUSINESS RULE 2 - slot / vehicle-type match'
\echo '  Attempt: put a CAR into a BIKE bay.'
\echo '  Expect : foreign key violation on fk_session_slot_type_match'
\echo '           (the composite key (slot_id, CAR) does not exist in slot)'
\echo '=========================================================='
BEGIN;
INSERT INTO parking_session (ticket_no, slot_id, vehicle_id, vehicle_type_id, entry_time)
SELECT 'TK-MISMATCH1',
       bike.slot_id,                                  -- a bike bay
       car.vehicle_id,                                -- a car
       car.vehicle_type_id,                           -- claiming CAR
       now()
  FROM (SELECT s.slot_id FROM slot s
          JOIN vehicle_type vt ON vt.vehicle_type_id = s.vehicle_type_id
         WHERE vt.code = 'BIKE' AND s.is_active
           AND NOT EXISTS (SELECT 1 FROM parking_session ps
                            WHERE ps.slot_id = s.slot_id AND ps.exit_time IS NULL)
         LIMIT 1) bike
  CROSS JOIN (SELECT v.vehicle_id, v.vehicle_type_id FROM vehicle v
                JOIN vehicle_type vt ON vt.vehicle_type_id = v.vehicle_type_id
               WHERE vt.code = 'CAR'
                 AND NOT EXISTS (SELECT 1 FROM parking_session ps
                                  WHERE ps.vehicle_id = v.vehicle_id AND ps.exit_time IS NULL)
               LIMIT 1) car;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 3b BUSINESS RULE 2 - lying about the vehicle type'
\echo '  Attempt: claim a CAR is a BIKE so the slot type appears to match.'
\echo '  Expect : foreign key violation on fk_session_vehicle_type_match'
\echo '           (the composite key (vehicle_id, BIKE) does not exist in vehicle)'
\echo '  This is the half a single trigger would usually miss.'
\echo '=========================================================='
BEGIN;
INSERT INTO parking_session (ticket_no, slot_id, vehicle_id, vehicle_type_id, entry_time)
SELECT 'TK-MISMATCH2',
       bike.slot_id,
       car.vehicle_id,
       bike.vehicle_type_id,                          -- claiming BIKE
       now()
  FROM (SELECT s.slot_id, s.vehicle_type_id FROM slot s
          JOIN vehicle_type vt ON vt.vehicle_type_id = s.vehicle_type_id
         WHERE vt.code = 'BIKE' AND s.is_active
           AND NOT EXISTS (SELECT 1 FROM parking_session ps
                            WHERE ps.slot_id = s.slot_id AND ps.exit_time IS NULL)
         LIMIT 1) bike
  CROSS JOIN (SELECT v.vehicle_id FROM vehicle v
                JOIN vehicle_type vt ON vt.vehicle_type_id = v.vehicle_type_id
               WHERE vt.code = 'CAR'
                 AND NOT EXISTS (SELECT 1 FROM parking_session ps
                                  WHERE ps.vehicle_id = v.vehicle_id AND ps.exit_time IS NULL)
               LIMIT 1) car;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 4  BUSINESS RULE 3 - exit after entry'
\echo '  Attempt: stamp an exit one hour BEFORE the entry.'
\echo '  Expect : check violation on ck_session_exit_after_entry'
\echo '=========================================================='
BEGIN;
UPDATE parking_session
   SET exit_time = entry_time - INTERVAL '1 hour'
 WHERE session_id = (SELECT session_id FROM parking_session
                      WHERE exit_time IS NULL LIMIT 1);
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 5  BUSINESS RULE 4 - reservation window must be forward'
\echo '  Attempt: reserve until BEFORE the reservation starts.'
\echo '  Expect : check violation on ck_reservation_window'
\echo '=========================================================='
BEGIN;
INSERT INTO reservation (customer_id, vehicle_id, slot_id, reserved_from, reserved_until)
SELECT v.customer_id, v.vehicle_id, s.slot_id,
       now() + INTERVAL '4 hours', now() + INTERVAL '2 hours'
  FROM vehicle v
  JOIN slot s ON s.vehicle_type_id = v.vehicle_type_id
 LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 6  BUSINESS RULE 4 - two live holds may not overlap'
\echo '  Attempt: book a slot for a window that overlaps a live hold.'
\echo '  Expect : exclusion violation on ex_reservation_no_overlap'
\echo '=========================================================='
BEGIN;
INSERT INTO reservation (customer_id, vehicle_id, slot_id, reserved_from, reserved_until, status)
SELECT v.customer_id, v.vehicle_id, r.slot_id,
       r.reserved_from + INTERVAL '30 minutes',      -- lands inside the existing hold
       r.reserved_until + INTERVAL '30 minutes',
       'held'
  FROM reservation r
  JOIN slot s    ON s.slot_id = r.slot_id
  JOIN vehicle v ON v.vehicle_type_id = s.vehicle_type_id
 WHERE r.status IN ('held','confirmed')
 LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 7  BUSINESS RULE 5 - a bill amount may not be negative'
\echo '  Attempt: write a bill with a negative base amount.'
\echo '  Expect : check violation on ck_bill_base_non_negative'
\echo '           (forced past the amount-enforcing trigger with a direct UPDATE)'
\echo '=========================================================='
BEGIN;
ALTER TABLE bill DISABLE TRIGGER trg_bill_enforce_amounts;
UPDATE bill SET base_amount = -500.00
 WHERE bill_id = (SELECT bill_id FROM bill LIMIT 1);
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 8  BUSINESS RULE 5 - a client cannot dictate the charge'
\echo '  Attempt: insert a bill claiming the parking cost 1 rupee.'
\echo '  Expect : NO error. The row is accepted but trg_bill_enforce_amounts'
\echo '           silently replaces the amount with fn_calculate_charge output.'
\echo '           The printed comparison is the proof.'
\echo '=========================================================='
BEGIN;
-- Every completed session already has a bill, so remove one inside this
-- transaction (rolled back below) to get a clean session to re-bill.
CREATE TEMP TABLE t8 ON COMMIT DROP AS
SELECT b.session_id, b.total_amount AS correct_total
  FROM bill b JOIN parking_session ps ON ps.session_id = b.session_id
 WHERE b.total_amount > 0
 ORDER BY b.bill_id LIMIT 1;

DELETE FROM bill WHERE session_id = (SELECT session_id FROM t8);

WITH attempted AS (
    INSERT INTO bill (session_id, tariff_id, billable_minutes, base_amount, tax_amount)
    SELECT t8.session_id, fn_applicable_tariff(t8.session_id), 1, 1.00, 0.00 FROM t8
    RETURNING base_amount, tax_amount, total_amount
)
SELECT 'client claimed'  AS source, 1.00 AS base, 0.00 AS tax, 1.00 AS total FROM attempted
UNION ALL
SELECT 'database stored', base_amount, tax_amount, total_amount FROM attempted;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 9  Referential integrity - a session needs a real slot'
\echo '  Attempt: reference a slot_id that does not exist.'
\echo '  Expect : foreign key violation'
\echo '=========================================================='
BEGIN;
INSERT INTO parking_session (ticket_no, slot_id, vehicle_id, vehicle_type_id, entry_time)
SELECT 'TK-NOSLOT01', 999999, v.vehicle_id, v.vehicle_type_id, now()
  FROM vehicle v
 WHERE NOT EXISTS (SELECT 1 FROM parking_session ps
                    WHERE ps.vehicle_id = v.vehicle_id AND ps.exit_time IS NULL)
 LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 10 Input validation - plate number format'
\echo '  Attempt: register a vehicle with the plate "HELLO".'
\echo '  Expect : check violation on ck_vehicle_plate_shape'
\echo '=========================================================='
BEGIN;
INSERT INTO vehicle (customer_id, plate_number, vehicle_type_id)
SELECT 1, 'HELLO', vehicle_type_id FROM vehicle_type LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 11 Input validation - duplicate plate number'
\echo '  Attempt: register a plate that already exists.'
\echo '  Expect : unique violation on vehicle_plate_number_key'
\echo '=========================================================='
BEGIN;
INSERT INTO vehicle (customer_id, plate_number, vehicle_type_id)
SELECT 1, plate_number, vehicle_type_id FROM vehicle LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 12 Payment integrity - a payment must be positive'
\echo '  Attempt: record a payment of zero.'
\echo '  Expect : check violation on ck_payment_amount_positive'
\echo '=========================================================='
BEGIN;
INSERT INTO payment (bill_id, amount, method)
SELECT bill_id, 0, 'cash' FROM bill LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 13 Tariff integrity - overlapping price lists'
\echo '  Attempt: open a second tariff for a facility/type already priced.'
\echo '  Expect : exclusion violation on ex_tariff_no_overlap'
\echo '=========================================================='
BEGIN;
INSERT INTO tariff (facility_id, vehicle_type_id, name, first_hour_rate,
                    subsequent_hour_rate, daily_cap, effective_from)
SELECT facility_id, vehicle_type_id, 'Conflicting tariff', 10, 10, 100, now()
  FROM tariff WHERE effective_to IS NULL LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 14 Operator scoping - an operator must have a facility'
\echo '  Attempt: create an operator with no facility_id.'
\echo '  Expect : check violation on ck_app_user_operator_has_facility'
\echo '=========================================================='
BEGIN;
INSERT INTO app_user (email, password_hash, full_name, role, facility_id)
VALUES ('rogue.operator@smartpark.in', 'x', 'Rogue Operator', 'operator', NULL);
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 15 Pass integrity - two live passes on one vehicle'
\echo '  Attempt: sell a second overlapping pass for the same vehicle/facility.'
\echo '  Expect : exclusion violation on ex_pass_no_overlap'
\echo '=========================================================='
BEGIN;
INSERT INTO parking_pass (customer_id, vehicle_id, pass_type_id, facility_id,
                          valid_from, valid_to, price_paid)
SELECT pp.customer_id, pp.vehicle_id, pp.pass_type_id, pp.facility_id,
       pp.valid_from + INTERVAL '1 day', pp.valid_to + INTERVAL '1 day', pp.price_paid
  FROM parking_pass pp WHERE pp.cancelled_at IS NULL LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 16 Ownership - a booking must use the customer''s own vehicle'
\echo '  Attempt: reserve for customer A using customer B''s car.'
\echo '  Expect : foreign key violation on fk_reservation_vehicle_owner'
\echo '=========================================================='
BEGIN;
INSERT INTO reservation (customer_id, vehicle_id, slot_id, reserved_from, reserved_until)
SELECT other.customer_id, v.vehicle_id, s.slot_id,
       now() + INTERVAL '60 days', now() + INTERVAL '60 days 2 hours'
  FROM vehicle v
  JOIN slot s ON s.vehicle_type_id = v.vehicle_type_id AND s.is_active
  JOIN customer other ON other.customer_id <> v.customer_id
 LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 17 Ownership - a pass must cover the customer''s own vehicle'
\echo '  Attempt: sell customer A a pass on customer B''s car.'
\echo '  Expect : foreign key violation on fk_pass_vehicle_owner'
\echo '=========================================================='
BEGIN;
INSERT INTO parking_pass (customer_id, vehicle_id, pass_type_id, facility_id,
                          valid_from, valid_to, price_paid)
SELECT other.customer_id, pp.vehicle_id, pp.pass_type_id, pp.facility_id,
       now() + INTERVAL '400 days', now() + INTERVAL '430 days', pp.price_paid
  FROM parking_pass pp
  JOIN customer other ON other.customer_id <> pp.customer_id
 LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 18 BUSINESS RULE 2 at booking time - bay / vehicle type'
\echo '  Attempt: reserve a bay built for a different vehicle type.'
\echo '  Expect : foreign key violation on fk_reservation_slot_type_match'
\echo '=========================================================='
BEGIN;
INSERT INTO reservation (customer_id, vehicle_id, slot_id, reserved_from, reserved_until)
SELECT v.customer_id, v.vehicle_id, s.slot_id,
       now() + INTERVAL '61 days', now() + INTERVAL '61 days 2 hours'
  FROM vehicle v
  JOIN slot s ON s.vehicle_type_id <> v.vehicle_type_id AND s.is_active
 LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 19 Bay servicing - an out-of-service bay cannot be booked'
\echo '  Attempt: take a free bay out of service, then reserve it.'
\echo '  Expect : check violation raised by trg_reservation_prepare'
\echo '=========================================================='
BEGIN;
CREATE TEMP TABLE t19 ON COMMIT DROP AS
SELECT s.slot_id, s.vehicle_type_id FROM slot s
 WHERE s.is_active
   AND NOT EXISTS (SELECT 1 FROM parking_session ps WHERE ps.slot_id = s.slot_id AND ps.exit_time IS NULL)
   AND NOT EXISTS (SELECT 1 FROM reservation r WHERE r.slot_id = s.slot_id AND r.status IN ('held','confirmed'))
 LIMIT 1;
UPDATE slot SET is_active = FALSE, service_note = 'Test 19' WHERE slot_id = (SELECT slot_id FROM t19);
INSERT INTO reservation (customer_id, vehicle_id, slot_id, reserved_from, reserved_until)
SELECT v.customer_id, v.vehicle_id, t19.slot_id,
       now() + INTERVAL '62 days', now() + INTERVAL '62 days 2 hours'
  FROM t19 JOIN vehicle v ON v.vehicle_type_id = t19.vehicle_type_id
 LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 20 Bay servicing - an occupied bay cannot be taken out'
\echo '  Attempt: as admin, take a bay with a parked car out of service.'
\echo '  Expect : "Bay ... has a vehicle in it" from fn_set_slot_service'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '1';
SET LOCAL ROLE parking_admin;
SELECT fn_set_slot_service(
         (SELECT slot_id FROM parking_session WHERE exit_time IS NULL LIMIT 1),
         FALSE, 'Test 20');
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 21 Bay servicing - a note only describes an idle bay'
\echo '  Attempt: attach a service note to a bay that is in service.'
\echo '  Expect : check violation on ck_slot_note_only_when_out'
\echo '=========================================================='
BEGIN;
UPDATE slot SET service_note = 'Paint is fresh'
 WHERE slot_id = (SELECT slot_id FROM slot WHERE is_active LIMIT 1);
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 22 Operator scoping - bays at another facility'
\echo '  Attempt: operator posted to facility 1 services a facility 2 bay.'
\echo '  Expect : "You can only manage bays at your own facility."'
\echo '=========================================================='
BEGIN;
CREATE TEMP TABLE t22 ON COMMIT DROP AS
SELECT s.slot_id FROM slot s
  JOIN zone z ON z.zone_id = s.zone_id JOIN floor fl ON fl.floor_id = z.floor_id
 WHERE fl.facility_id = 2 LIMIT 1;
GRANT SELECT ON t22 TO parking_operator;
SET LOCAL app.current_user_id = '2';
SET LOCAL ROLE parking_operator;
SELECT fn_set_slot_service((SELECT slot_id FROM t22), FALSE, 'Test 22');
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 23 Audit trail - the history cannot be erased'
\echo '  Attempt: as admin, delete rows from audit_log.'
\echo '  Expect : permission denied for table audit_log'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '1';
SET LOCAL ROLE parking_admin;
DELETE FROM audit_log;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST 24 Payment integrity - no paying past the balance'
\echo '  Attempt: pay one rupee more than an unpaid bill''s total.'
\echo '  Expect : "That is more than the ₹... still owed on this bill."'
\echo '=========================================================='
BEGIN;
INSERT INTO payment (bill_id, amount, method)
SELECT b.bill_id, b.total_amount + 1, 'cash'
  FROM bill b
 WHERE b.status = 'unpaid' AND b.total_amount > 0
   AND NOT EXISTS (SELECT 1 FROM payment p WHERE p.bill_id = b.bill_id)
 LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'ALL CONSTRAINT TESTS COMPLETE'
\echo '=========================================================='

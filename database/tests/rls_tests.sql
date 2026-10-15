-- ============================================================================
-- rls_tests.sql
--
-- Proves the row-level security policies actually restrict, rather than merely
-- existing. Run with:  psql -d smartpark -f db/tests/rls_tests.sql
--
-- Note on the table owner: PostgreSQL exempts a table's owner from its own RLS
-- policies unless FORCE ROW LEVEL SECURITY is set. The API therefore never
-- queries as the owner - it issues SET LOCAL ROLE to one of the three
-- application roles first. These tests do the same thing, so they exercise the
-- policies exactly as a real request does.
-- ============================================================================
\set ON_ERROR_STOP off
\pset pager off

\echo ''
\echo '=========================================================='
\echo 'BASELINE - as the table owner (RLS bypassed by ownership)'
\echo '=========================================================='
SELECT count(*) AS all_customers FROM customer;
SELECT count(*) AS all_vehicles  FROM vehicle;
SELECT count(*) AS all_bills     FROM bill;

\echo ''
\echo '=========================================================='
\echo 'TEST A - customer 1 (Rahul Sharma, user_id 5)'
\echo '  Expect: sees only their own customer row, their own vehicles,'
\echo '          and only bills for their own parking sessions.'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '5';
SET LOCAL ROLE parking_customer;

SELECT current_user AS acting_as, fn_current_user_id() AS user_id,
       fn_current_role() AS role, fn_current_customer_id() AS customer_id;

SELECT count(*) AS customers_visible FROM customer;
SELECT customer_id, full_name, phone FROM customer;
SELECT count(*) AS vehicles_visible  FROM vehicle;
SELECT plate_number FROM vehicle ORDER BY plate_number;
SELECT count(*) AS bills_visible     FROM bill;
SELECT count(*) AS sessions_visible  FROM parking_session;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST B - customer 2 (Priya Nair, user_id 6)'
\echo '  Expect: a DIFFERENT set of vehicles from Test A.'
\echo '          If these two lists overlap, the policies do not work.'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '6';
SET LOCAL ROLE parking_customer;
SELECT fn_current_customer_id() AS customer_id;
SELECT plate_number FROM vehicle ORDER BY plate_number;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST C - customer 1 tries to read another customer directly'
\echo '  Expect: 0 rows. Not an error - the row is invisible, which is'
\echo '          the correct RLS behaviour (leaking existence would itself'
\echo '          be an information disclosure).'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '5';
SET LOCAL ROLE parking_customer;
SELECT count(*) AS other_customer_rows_visible FROM customer WHERE customer_id = 2;
SELECT count(*) AS other_customers_vehicles    FROM vehicle  WHERE customer_id = 2;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST D - a customer tries to WRITE a vehicle onto someone else'
\echo '  Expect: policy violation on the WITH CHECK clause.'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '5';
SET LOCAL ROLE parking_customer;
INSERT INTO vehicle (customer_id, plate_number, vehicle_type_id)
VALUES (2, 'TS99ZZ9999', 1);
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST E - a customer tries to record a payment against themselves'
\echo '  Expect: permission denied. Customers hold SELECT on payment only;'
\echo '          money is recorded by the gate, not by the person paying.'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '5';
SET LOCAL ROLE parking_customer;
INSERT INTO payment (bill_id, amount, method)
SELECT bill_id, 1, 'cash' FROM bill LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST F - operator at facility 1 (Rohit, user_id 2)'
\echo '  Expect: sees sessions and reservations for facility 1 ONLY.'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '2';
SET LOCAL ROLE parking_operator;
SELECT fn_current_role() AS role, fn_current_facility_id() AS facility;
SELECT count(*) AS sessions_visible FROM parking_session;
SELECT fl.facility_id, count(*) AS sessions_by_facility
  FROM parking_session ps
  JOIN slot s ON s.slot_id = ps.slot_id
  JOIN zone z ON z.zone_id = s.zone_id
  JOIN floor fl ON fl.floor_id = z.floor_id
 GROUP BY fl.facility_id ORDER BY 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST G - operator at facility 2 (Imran, user_id 4)'
\echo '  Expect: a different, smaller session count, all facility 2.'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '4';
SET LOCAL ROLE parking_operator;
SELECT fn_current_facility_id() AS facility;
SELECT fl.facility_id, count(*) AS sessions_by_facility
  FROM parking_session ps
  JOIN slot s ON s.slot_id = ps.slot_id
  JOIN zone z ON z.zone_id = s.zone_id
  JOIN floor fl ON fl.floor_id = z.floor_id
 GROUP BY fl.facility_id ORDER BY 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST H - views honour RLS (security_invoker = true)'
\echo '  Expect: a customer sees only their OWN rows through the view.'
\echo '          Without security_invoker the view would run as its owner'
\echo '          and return every row - the classic RLS bypass.'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '5';
SET LOCAL ROLE parking_customer;
SELECT count(*) AS duration_rows_visible_to_customer FROM v_session_duration;
SELECT count(*) AS violations_visible_to_customer    FROM v_violations;
ROLLBACK;

\echo ''
\echo '  ... and the same views as an admin:'
BEGIN;
SET LOCAL app.current_user_id = '1';
SET LOCAL ROLE parking_admin;
SELECT count(*) AS duration_rows_visible_to_admin FROM v_session_duration;
SELECT count(*) AS violations_visible_to_admin    FROM v_violations;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST I - no identity set at all'
\echo '  Expect: 0 rows everywhere. fn_current_user_id() returns NULL and'
\echo '          every policy evaluates false - the system fails CLOSED.'
\echo '=========================================================='
BEGIN;
SET LOCAL ROLE parking_customer;
SELECT fn_current_user_id() AS user_id_when_unset;
SELECT count(*) AS customers_visible FROM customer;
SELECT count(*) AS vehicles_visible  FROM vehicle;
SELECT count(*) AS bills_visible     FROM bill;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST J - activity feed respects RLS (security_invoker view)'
\echo '  Expect: customer 1 sees only plates they own;'
\echo '          the facility-2 operator sees only facility 2.'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '5';
SET LOCAL ROLE parking_customer;
SELECT count(*) AS events_visible,
       count(*) FILTER (WHERE plate_number NOT IN (SELECT plate_number FROM vehicle))
           AS events_for_other_peoples_cars
  FROM v_recent_activity;
ROLLBACK;

BEGIN;
SET LOCAL app.current_user_id = '4';
SET LOCAL ROLE parking_operator;
SELECT array_agg(DISTINCT facility_id) AS facilities_visible FROM v_recent_activity;
-- Payments and violations reach the operator through their own policies too.
SELECT count(*) AS payments_visible,
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM bill b WHERE b.bill_id = payment.bill_id))
           AS payments_for_bills_not_visible
  FROM payment;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST K - only an admin can read the audit trail'
\echo '  Expect: permission denied for the customer and the operator.'
\echo '=========================================================='
BEGIN;
SET LOCAL app.current_user_id = '5';
SET LOCAL ROLE parking_customer;
SELECT count(*) FROM audit_log;
ROLLBACK;

BEGIN;
SET LOCAL app.current_user_id = '2';
SET LOCAL ROLE parking_operator;
SELECT count(*) FROM audit_log;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'TEST L - the audit trail names the person, not the role'
\echo '  Operator user 2 takes a free facility-1 bay out of service.'
\echo '  Expect: one audit row, actor_user_id 2, actor_role operator,'
\echo '          changes show is_active true -> false and the note.'
\echo '=========================================================='
BEGIN;
CREATE TEMP TABLE th ON COMMIT DROP AS
SELECT s.slot_id FROM slot s
  JOIN zone z ON z.zone_id = s.zone_id JOIN floor fl ON fl.floor_id = z.floor_id
 WHERE fl.facility_id = 1 AND s.is_active
   AND NOT EXISTS (SELECT 1 FROM parking_session ps WHERE ps.slot_id = s.slot_id AND ps.exit_time IS NULL)
   AND NOT EXISTS (SELECT 1 FROM reservation r WHERE r.slot_id = s.slot_id
                    AND r.status IN ('held','confirmed') AND r.reserved_until > now())
 LIMIT 1;
GRANT SELECT ON th TO parking_operator;
SET LOCAL app.current_user_id = '2';
SET LOCAL ROLE parking_operator;
SELECT fn_set_slot_service((SELECT slot_id FROM th), FALSE, 'Barrier arm damaged');
RESET ROLE;
SELECT actor_user_id, actor_role, table_name, action, changes
  FROM audit_log
 WHERE table_name = 'slot' AND row_id = (SELECT slot_id FROM th)
 ORDER BY audit_id DESC LIMIT 1;
ROLLBACK;

\echo ''
\echo '=========================================================='
\echo 'RLS TESTS COMPLETE'
\echo '=========================================================='

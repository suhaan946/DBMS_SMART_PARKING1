-- ============================================================================
-- 009_rls.sql
--
-- Purpose: row-level security. Every table holding user data has RLS enabled
--          and policies that genuinely restrict.
--
-- How identity reaches the database:
--   The API opens a connection as the owner role, then per request issues
--       SET LOCAL app.current_user_id = '<id>';
--       SET LOCAL ROLE parking_customer;   -- or _operator / _admin
--   SET LOCAL scopes both to the transaction, so a pooled connection cannot
--   leak one request's identity into the next.
--
--   fn_current_user_id() reads that setting. It returns NULL rather than
--   raising when the setting is absent, so a policy evaluates to false and the
--   row is hidden — failing closed, not open.
--
-- There is no USING (true) policy anywhere in this file. The admin role is
-- granted broad access explicitly and separately, which is a different thing
-- from a policy that lets everyone through.
-- ============================================================================

-- Idempotent DROP IF EXISTS guards below emit "does not exist, skipping"
-- notices on a first run. They are harmless, but they read like failures to
-- someone running this for the first time, so notices are quietened here.
-- Warnings and errors still come through.
SET client_min_messages = warning;


-- ---------------------------------------------------------------------------
-- Identity helpers
-- ---------------------------------------------------------------------------
-- fn_current_user_id - who is asking, from the transaction-local setting.
--
-- Plain SQL and STABLE so PostgreSQL can INLINE it into a policy expression.
-- This matters enormously: a policy calls its helpers once per candidate row,
-- and a non-inlinable helper turns a row-level filter into hundreds of
-- thousands of function calls. An earlier PL/pgSQL version of this function,
-- with an exception block, made the dashboard take 82 seconds.
--
-- The `true` second argument to current_setting means "return NULL if unset"
-- rather than raising, and the regex guard means a malformed value also
-- yields NULL. Both paths fail CLOSED: a NULL user id makes every policy
-- false and the caller sees no rows.
CREATE OR REPLACE FUNCTION fn_current_user_id()
RETURNS BIGINT
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT CASE
             WHEN current_setting('app.current_user_id', true) ~ '^[0-9]+$'
             THEN current_setting('app.current_user_id', true)::BIGINT
           END;
$$;

-- fn_current_role - what the caller is allowed to be.
--
-- Read from current_user, the actual PostgreSQL role the API switched into
-- with SET LOCAL ROLE. Deliberately NOT read from app_user.role:
--
--   * Correctness - reading app_user from inside a policy ON app_user is
--     mutual recursion. The previous version worked around that with
--     SECURITY DEFINER, which then could not be inlined (see above).
--   * Security - a GUC the application sets could be set wrongly. The database
--     role cannot: a connection that did SET ROLE parking_customer cannot
--     answer 'admin' here, whatever the application believes.
CREATE OR REPLACE FUNCTION fn_current_role()
RETURNS user_role
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT CASE current_user
             WHEN 'parking_admin'    THEN 'admin'::user_role
             WHEN 'parking_operator' THEN 'operator'::user_role
             WHEN 'parking_customer' THEN 'customer'::user_role
           END;
$$;

-- The customer row belonging to the caller, if any.
CREATE OR REPLACE FUNCTION fn_current_customer_id()
RETURNS BIGINT
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT c.customer_id FROM customer c WHERE c.user_id = fn_current_user_id();
$$;

-- The facility an operator is posted to. NULL for everyone else, which makes
-- every operator-scoped policy false for a non-operator.
CREATE OR REPLACE FUNCTION fn_current_facility_id()
RETURNS BIGINT
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT u.facility_id FROM app_user u WHERE u.user_id = fn_current_user_id();
$$;


-- ---------------------------------------------------------------------------
-- Enable RLS on every table holding user data.
-- ---------------------------------------------------------------------------
ALTER TABLE app_user        ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer        ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle         ENABLE ROW LEVEL SECURITY;
ALTER TABLE reservation     ENABLE ROW LEVEL SECURITY;
ALTER TABLE parking_session ENABLE ROW LEVEL SECURITY;
ALTER TABLE parking_pass    ENABLE ROW LEVEL SECURITY;
ALTER TABLE bill            ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment         ENABLE ROW LEVEL SECURITY;
ALTER TABLE violation       ENABLE ROW LEVEL SECURITY;

-- Reference data (facility, floor, zone, slot, vehicle_type, tariff, pass_type)
-- is deliberately readable by all three roles: a customer must be able to see
-- which slots exist to book one. Write access is restricted by GRANT below
-- rather than by RLS, because the rule there is "which role", not "which row".


-- ---------------------------------------------------------------------------
-- app_user
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS p_user_self_read  ON app_user;
DROP POLICY IF EXISTS p_user_admin_all  ON app_user;

-- A person reads their own row and nobody else's.
CREATE POLICY p_user_self_read ON app_user
    FOR SELECT
    USING (user_id = fn_current_user_id());

CREATE POLICY p_user_admin_all ON app_user
    FOR ALL
    USING      (fn_current_role() = 'admin')
    WITH CHECK (fn_current_role() = 'admin');


-- ---------------------------------------------------------------------------
-- customer
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS p_customer_self     ON customer;
DROP POLICY IF EXISTS p_customer_operator ON customer;
DROP POLICY IF EXISTS p_customer_admin    ON customer;

CREATE POLICY p_customer_self ON customer
    FOR SELECT
    USING (user_id = fn_current_user_id());

-- An operator works the gate and must be able to look up whoever drives in.
CREATE POLICY p_customer_operator ON customer
    FOR ALL
    USING      (fn_current_role() = 'operator')
    WITH CHECK (fn_current_role() = 'operator');

CREATE POLICY p_customer_admin ON customer
    FOR ALL
    USING      (fn_current_role() = 'admin')
    WITH CHECK (fn_current_role() = 'admin');


-- ---------------------------------------------------------------------------
-- vehicle — a customer sees only their own cars
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS p_vehicle_own      ON vehicle;
DROP POLICY IF EXISTS p_vehicle_operator ON vehicle;
DROP POLICY IF EXISTS p_vehicle_admin    ON vehicle;

CREATE POLICY p_vehicle_own ON vehicle
    FOR ALL
    USING      (customer_id = fn_current_customer_id())
    WITH CHECK (customer_id = fn_current_customer_id());

CREATE POLICY p_vehicle_operator ON vehicle
    FOR ALL
    USING      (fn_current_role() = 'operator')
    WITH CHECK (fn_current_role() = 'operator');

CREATE POLICY p_vehicle_admin ON vehicle
    FOR ALL
    USING      (fn_current_role() = 'admin')
    WITH CHECK (fn_current_role() = 'admin');


-- ---------------------------------------------------------------------------
-- reservation
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS p_reservation_own      ON reservation;
DROP POLICY IF EXISTS p_reservation_operator ON reservation;
DROP POLICY IF EXISTS p_reservation_admin    ON reservation;

CREATE POLICY p_reservation_own ON reservation
    FOR ALL
    USING      (customer_id = fn_current_customer_id())
    WITH CHECK (customer_id = fn_current_customer_id());

-- Operators see only reservations for slots in their own facility. This is the
-- policy that proves the operator scoping is real: an operator at facility 2
-- cannot read facility 1's bookings.
CREATE POLICY p_reservation_operator ON reservation
    FOR ALL
    USING (
        fn_current_role() = 'operator'
        AND EXISTS (
            SELECT 1 FROM slot s
              JOIN zone  z  ON z.zone_id  = s.zone_id
              JOIN floor fl ON fl.floor_id = z.floor_id
             WHERE s.slot_id = reservation.slot_id
               AND fl.facility_id = fn_current_facility_id()
        )
    )
    WITH CHECK (fn_current_role() = 'operator');

CREATE POLICY p_reservation_admin ON reservation
    FOR ALL
    USING      (fn_current_role() = 'admin')
    WITH CHECK (fn_current_role() = 'admin');


-- ---------------------------------------------------------------------------
-- parking_session
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS p_session_own      ON parking_session;
DROP POLICY IF EXISTS p_session_operator ON parking_session;
DROP POLICY IF EXISTS p_session_admin    ON parking_session;

CREATE POLICY p_session_own ON parking_session
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM vehicle v
             WHERE v.vehicle_id = parking_session.vehicle_id
               AND v.customer_id = fn_current_customer_id()
        )
    );

CREATE POLICY p_session_operator ON parking_session
    FOR ALL
    USING (
        fn_current_role() = 'operator'
        AND EXISTS (
            SELECT 1 FROM slot s
              JOIN zone  z  ON z.zone_id  = s.zone_id
              JOIN floor fl ON fl.floor_id = z.floor_id
             WHERE s.slot_id = parking_session.slot_id
               AND fl.facility_id = fn_current_facility_id()
        )
    )
    WITH CHECK (fn_current_role() = 'operator');

CREATE POLICY p_session_admin ON parking_session
    FOR ALL
    USING      (fn_current_role() = 'admin')
    WITH CHECK (fn_current_role() = 'admin');


-- ---------------------------------------------------------------------------
-- parking_pass
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS p_pass_own      ON parking_pass;
DROP POLICY IF EXISTS p_pass_operator ON parking_pass;
DROP POLICY IF EXISTS p_pass_admin    ON parking_pass;

CREATE POLICY p_pass_own ON parking_pass
    FOR ALL
    USING      (customer_id = fn_current_customer_id())
    WITH CHECK (customer_id = fn_current_customer_id());

CREATE POLICY p_pass_operator ON parking_pass
    FOR ALL
    USING      (fn_current_role() = 'operator' AND facility_id = fn_current_facility_id())
    WITH CHECK (fn_current_role() = 'operator' AND facility_id = fn_current_facility_id());

CREATE POLICY p_pass_admin ON parking_pass
    FOR ALL
    USING      (fn_current_role() = 'admin')
    WITH CHECK (fn_current_role() = 'admin');


-- ---------------------------------------------------------------------------
-- bill — reachable only through the session, so the policy walks that chain
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS p_bill_own      ON bill;
DROP POLICY IF EXISTS p_bill_operator ON bill;
DROP POLICY IF EXISTS p_bill_admin    ON bill;

CREATE POLICY p_bill_own ON bill
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
              FROM parking_session ps
              JOIN vehicle v ON v.vehicle_id = ps.vehicle_id
             WHERE ps.session_id = bill.session_id
               AND v.customer_id = fn_current_customer_id()
        )
    );

CREATE POLICY p_bill_operator ON bill
    FOR ALL
    USING (
        fn_current_role() = 'operator'
        AND EXISTS (
            SELECT 1
              FROM parking_session ps
              JOIN slot  s  ON s.slot_id  = ps.slot_id
              JOIN zone  z  ON z.zone_id  = s.zone_id
              JOIN floor fl ON fl.floor_id = z.floor_id
             WHERE ps.session_id = bill.session_id
               AND fl.facility_id = fn_current_facility_id()
        )
    )
    WITH CHECK (fn_current_role() = 'operator');

CREATE POLICY p_bill_admin ON bill
    FOR ALL
    USING      (fn_current_role() = 'admin')
    WITH CHECK (fn_current_role() = 'admin');


-- ---------------------------------------------------------------------------
-- payment
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS p_payment_own      ON payment;
DROP POLICY IF EXISTS p_payment_operator ON payment;
DROP POLICY IF EXISTS p_payment_admin    ON payment;

CREATE POLICY p_payment_own ON payment
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
              FROM bill b
              JOIN parking_session ps ON ps.session_id = b.session_id
              JOIN vehicle v ON v.vehicle_id = ps.vehicle_id
             WHERE b.bill_id = payment.bill_id
               AND v.customer_id = fn_current_customer_id()
        )
    );

CREATE POLICY p_payment_operator ON payment
    FOR ALL
    USING      (fn_current_role() = 'operator')
    WITH CHECK (fn_current_role() = 'operator');

CREATE POLICY p_payment_admin ON payment
    FOR ALL
    USING      (fn_current_role() = 'admin')
    WITH CHECK (fn_current_role() = 'admin');


-- ---------------------------------------------------------------------------
-- violation
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS p_violation_own      ON violation;
DROP POLICY IF EXISTS p_violation_operator ON violation;
DROP POLICY IF EXISTS p_violation_admin    ON violation;

CREATE POLICY p_violation_own ON violation
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM vehicle v
             WHERE v.vehicle_id = violation.vehicle_id
               AND v.customer_id = fn_current_customer_id()
        )
    );

CREATE POLICY p_violation_operator ON violation
    FOR ALL
    USING      (fn_current_role() = 'operator')
    WITH CHECK (fn_current_role() = 'operator');

CREATE POLICY p_violation_admin ON violation
    FOR ALL
    USING      (fn_current_role() = 'admin')
    WITH CHECK (fn_current_role() = 'admin');


-- ---------------------------------------------------------------------------
-- Table privileges.
--
-- RLS filters rows; GRANT decides who may touch the table at all. Both are
-- needed: RLS without GRANT is unreachable, GRANT without RLS is unrestricted.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO parking_admin, parking_operator, parking_customer;

-- Reference data: everyone reads, only admin writes.
GRANT SELECT ON facility, floor, zone, slot, vehicle_type, tariff, pass_type
    TO parking_admin, parking_operator, parking_customer;
GRANT INSERT, UPDATE, DELETE ON facility, floor, zone, slot, vehicle_type, tariff, pass_type
    TO parking_admin;

-- Operational data: RLS decides which rows.
GRANT SELECT, INSERT, UPDATE, DELETE
    ON app_user, customer, vehicle, reservation, parking_session,
       parking_pass, bill, payment, violation
    TO parking_admin, parking_operator;

-- A customer may read their own data and create their own bookings, vehicles
-- and passes. They may not write sessions, bills, payments or violations —
-- those are recorded by the gate, not by the person being charged.
GRANT SELECT ON app_user, customer, parking_session, bill, payment, violation
    TO parking_customer;
GRANT SELECT, INSERT, UPDATE, DELETE ON vehicle, reservation, parking_pass
    TO parking_customer;

-- Views inherit the caller's rights because of security_invoker.
GRANT SELECT ON v_current_occupancy, v_free_slots, v_peak_hours,
                v_session_duration, v_pass_usage, v_violations, v_revenue_daily
    TO parking_admin, parking_operator, parking_customer;

-- Identity sequences must be usable by anyone allowed to INSERT.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public
    TO parking_admin, parking_operator, parking_customer;

GRANT EXECUTE ON FUNCTION
    fn_calculate_charge(BIGINT), fn_applicable_tariff(BIGINT),
    fn_current_user_id(), fn_current_customer_id(),
    fn_current_facility_id(), fn_current_role(),
    fn_expire_stale_reservations()
    TO parking_admin, parking_operator, parking_customer;

-- Gate operations belong to staff only.
GRANT EXECUTE ON FUNCTION
    fn_gate_entry(TEXT, BIGINT, BIGINT),
    fn_gate_exit(TEXT, BIGINT),
    fn_allocate_slot(BIGINT, BIGINT, TIMESTAMPTZ)
    TO parking_admin, parking_operator;

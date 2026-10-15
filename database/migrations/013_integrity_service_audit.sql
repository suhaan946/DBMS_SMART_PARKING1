-- ============================================================================
-- 013_integrity_service_audit.sql
--
-- Purpose: close two integrity gaps found in the pre-merge audit, add bay
--          servicing, an append-only audit trail and a unified activity feed.
--
--   1. A reservation or pass may only name a vehicle its customer owns.
--   2. A reservation may only hold a bay built for that vehicle's type.
--   3. An out-of-service bay cannot be reserved, and a bay that is occupied or
--      held cannot be taken out of service.
--   4. audit_log: every write to an operational table is recorded by trigger.
--   5. v_recent_activity: entries, exits, payments, bookings and violations
--      as one time-ordered stream (UNION ALL).
--
-- Additive and idempotent: safe to run on a database that already holds data.
-- Runs as one transaction, so a failure leaves the database untouched.
-- ============================================================================
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. VEHICLE OWNERSHIP
--
-- reservation.customer_id and parking_pass.customer_id are functionally
-- determined by vehicle_id (vehicle_id -> customer_id). Nothing tied them
-- together, so a booking could name customer A with customer B's car.
--
-- The fix is the same pattern migration 003 uses for vehicle type: expose
-- (vehicle_id, customer_id) as a candidate key on vehicle and point a composite
-- foreign key at it. The referenced row only exists when the pair is true.
-- ---------------------------------------------------------------------------
ALTER TABLE reservation  DROP CONSTRAINT IF EXISTS fk_reservation_vehicle_owner;
ALTER TABLE parking_pass DROP CONSTRAINT IF EXISTS fk_pass_vehicle_owner;
ALTER TABLE vehicle      DROP CONSTRAINT IF EXISTS uq_vehicle_id_customer;

ALTER TABLE vehicle
    ADD CONSTRAINT uq_vehicle_id_customer UNIQUE (vehicle_id, customer_id);

-- NO ACTION on update: re-assigning a car that has bookings or passes must not
-- silently rewrite who made those bookings.
ALTER TABLE reservation
    ADD CONSTRAINT fk_reservation_vehicle_owner
    FOREIGN KEY (vehicle_id, customer_id) REFERENCES vehicle (vehicle_id, customer_id);

ALTER TABLE parking_pass
    ADD CONSTRAINT fk_pass_vehicle_owner
    FOREIGN KEY (vehicle_id, customer_id) REFERENCES vehicle (vehicle_id, customer_id);


-- ---------------------------------------------------------------------------
-- 2. RESERVATION / BAY TYPE MATCH
--
-- parking_session already refuses a car in a bike bay through two composite
-- foreign keys. A reservation had no such rule, so the mismatch was only
-- discovered at the gate, when the driver had already arrived. The same
-- mechanism now applies at booking time.
-- ---------------------------------------------------------------------------
ALTER TABLE reservation ADD COLUMN IF NOT EXISTS vehicle_type_id BIGINT;

UPDATE reservation r
   SET vehicle_type_id = v.vehicle_type_id
  FROM vehicle v
 WHERE v.vehicle_id = r.vehicle_id
   AND r.vehicle_type_id IS DISTINCT FROM v.vehicle_type_id;

ALTER TABLE reservation ALTER COLUMN vehicle_type_id SET NOT NULL;

ALTER TABLE reservation DROP CONSTRAINT IF EXISTS fk_reservation_slot_type_match;
ALTER TABLE reservation DROP CONSTRAINT IF EXISTS fk_reservation_vehicle_type_match;

ALTER TABLE reservation
    ADD CONSTRAINT fk_reservation_slot_type_match
    FOREIGN KEY (slot_id, vehicle_type_id) REFERENCES slot (slot_id, vehicle_type_id);

ALTER TABLE reservation
    ADD CONSTRAINT fk_reservation_vehicle_type_match
    FOREIGN KEY (vehicle_id, vehicle_type_id) REFERENCES vehicle (vehicle_id, vehicle_type_id);

COMMENT ON COLUMN reservation.vehicle_type_id IS
  'Join column for the two type-match foreign keys; forced equal to both the slot''s and the vehicle''s type.';


-- ---------------------------------------------------------------------------
-- 3. BAY SERVICING
-- ---------------------------------------------------------------------------
ALTER TABLE slot ADD COLUMN IF NOT EXISTS service_note TEXT;

ALTER TABLE slot DROP CONSTRAINT IF EXISTS ck_slot_note_only_when_out;
ALTER TABLE slot
    ADD CONSTRAINT ck_slot_note_only_when_out
    CHECK (service_note IS NULL OR (NOT is_active AND char_length(service_note) BETWEEN 1 AND 200));

COMMENT ON COLUMN slot.service_note IS
  'Why the bay is out of service. Only allowed while is_active is FALSE.';

-- Before a reservation is written:
--   * fill vehicle_type_id from the vehicle when the caller leaves it out. A
--     caller that supplies a wrong value is still refused by the foreign key.
--   * refuse a bay that is out of service: a booking there could never be
--     honoured. That is state in another table, so it cannot be a CHECK.
CREATE OR REPLACE FUNCTION fn_reservation_prepare()
RETURNS TRIGGER
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

DROP TRIGGER IF EXISTS trg_reservation_prepare ON reservation;
CREATE TRIGGER trg_reservation_prepare
    BEFORE INSERT OR UPDATE OF slot_id, vehicle_id ON reservation
    FOR EACH ROW EXECUTE FUNCTION fn_reservation_prepare();

-- Taking a bay out of service, or returning it. Locks the slot row so a gate
-- entry cannot slip in between the checks and the update.
CREATE OR REPLACE FUNCTION fn_set_slot_service(
    p_slot_id    BIGINT,
    p_in_service BOOLEAN,
    p_note       TEXT DEFAULT NULL
)
RETURNS VOID
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

COMMENT ON FUNCTION fn_set_slot_service(BIGINT, BOOLEAN, TEXT) IS
  'Take a bay out of service or return it. Refuses an occupied or held bay; operators are limited to their facility.';

-- Column-level privilege: staff may flip these two columns and nothing else.
GRANT UPDATE (is_active, service_note) ON slot TO parking_admin, parking_operator;
GRANT EXECUTE ON FUNCTION fn_set_slot_service(BIGINT, BOOLEAN, TEXT)
    TO parking_admin, parking_operator;


-- ---------------------------------------------------------------------------
-- 4. AUDIT TRAIL
--
-- Append-only. No application role holds INSERT, UPDATE or DELETE on it; rows
-- are written only by fn_audit_row, which runs as the table owner
-- (SECURITY DEFINER). The actor is read from the same app.current_user_id the
-- RLS policies use, so the log names the person, not the database role.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
    audit_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_user_id BIGINT,
    actor_role    user_role,
    table_name    TEXT   NOT NULL,
    row_id        BIGINT NOT NULL,
    action        TEXT   NOT NULL,
    changes       JSONB  NOT NULL,

    CONSTRAINT fk_audit_actor
        FOREIGN KEY (actor_user_id) REFERENCES app_user (user_id)
        -- SET NULL: removing a login must not erase what that person did.
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT ck_audit_action CHECK (action IN ('INSERT', 'UPDATE', 'DELETE'))
);

CREATE INDEX IF NOT EXISTS ix_audit_occurred ON audit_log (occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_row      ON audit_log (table_name, row_id);

COMMENT ON TABLE audit_log IS
  'Append-only change history written by trigger. changes holds the full row for INSERT/DELETE and {column: {from, to}} for UPDATE.';

CREATE OR REPLACE FUNCTION fn_audit_row()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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

-- app_user is deliberately not audited: its rows carry password hashes.
DO $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN SELECT * FROM (VALUES
        ('customer',        'customer_id'),
        ('vehicle',         'vehicle_id'),
        ('slot',            'slot_id'),
        ('tariff',          'tariff_id'),
        ('reservation',     'reservation_id'),
        ('parking_pass',    'pass_id'),
        ('parking_session', 'session_id'),
        ('bill',            'bill_id'),
        ('payment',         'payment_id'),
        ('violation',       'violation_id')
    ) AS x(tbl, pk)
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_audit ON %I', t.tbl);
        EXECUTE format(
            'CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit_row(%L)', t.tbl, t.pk);
    END LOOP;
END $$;

REVOKE ALL ON audit_log FROM PUBLIC;
GRANT SELECT ON audit_log TO parking_admin;


-- ---------------------------------------------------------------------------
-- 5. v_recent_activity
--
-- One stream of everything that happened, newest first. UNION ALL rather than
-- UNION: the branches can never produce identical rows (kind differs), so the
-- duplicate-removing sort UNION would add is pure cost.
-- security_invoker: RLS on the underlying tables still applies, so a customer
-- sees only their own events and an operator only their facility's.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_recent_activity
WITH (security_invoker = true) AS
SELECT ps.entry_time      AS occurred_at,
       'entry'::TEXT      AS kind,
       fl.facility_id,
       ps.session_id      AS ref_id,
       v.plate_number,
       s.code             AS slot_code,
       NULL::NUMERIC      AS amount,
       ps.ticket_no       AS detail
  FROM parking_session ps
  JOIN slot    s  ON s.slot_id    = ps.slot_id
  JOIN zone    z  ON z.zone_id    = s.zone_id
  JOIN floor   fl ON fl.floor_id  = z.floor_id
  JOIN vehicle v  ON v.vehicle_id = ps.vehicle_id
UNION ALL
SELECT ps.exit_time, 'exit', fl.facility_id, ps.session_id, v.plate_number, s.code,
       NULL::NUMERIC, ps.ticket_no
  FROM parking_session ps
  JOIN slot    s  ON s.slot_id    = ps.slot_id
  JOIN zone    z  ON z.zone_id    = s.zone_id
  JOIN floor   fl ON fl.floor_id  = z.floor_id
  JOIN vehicle v  ON v.vehicle_id = ps.vehicle_id
 WHERE ps.exit_time IS NOT NULL
UNION ALL
SELECT p.paid_at, 'payment', fl.facility_id, p.payment_id, v.plate_number, s.code,
       p.amount, p.method::TEXT
  FROM payment p
  JOIN bill            b  ON b.bill_id     = p.bill_id
  JOIN parking_session ps ON ps.session_id = b.session_id
  JOIN slot    s  ON s.slot_id    = ps.slot_id
  JOIN zone    z  ON z.zone_id    = s.zone_id
  JOIN floor   fl ON fl.floor_id  = z.floor_id
  JOIN vehicle v  ON v.vehicle_id = ps.vehicle_id
UNION ALL
SELECT r.created_at, 'reservation', fl.facility_id, r.reservation_id, v.plate_number, s.code,
       NULL::NUMERIC, r.status::TEXT
  FROM reservation r
  JOIN slot    s  ON s.slot_id    = r.slot_id
  JOIN zone    z  ON z.zone_id    = s.zone_id
  JOIN floor   fl ON fl.floor_id  = z.floor_id
  JOIN vehicle v  ON v.vehicle_id = r.vehicle_id
UNION ALL
SELECT vi.detected_at, 'violation', fl.facility_id, vi.violation_id, v.plate_number, s.code,
       vi.penalty_amount, vi.kind::TEXT
  FROM violation vi
  JOIN vehicle   v  ON v.vehicle_id = vi.vehicle_id
  LEFT JOIN slot  s  ON s.slot_id   = vi.slot_id
  LEFT JOIN zone  z  ON z.zone_id   = s.zone_id
  LEFT JOIN floor fl ON fl.floor_id = z.floor_id;

COMMENT ON VIEW v_recent_activity IS
  'Report: every gate, payment, booking and violation event as one stream (UNION ALL of five branches).';

GRANT SELECT ON v_recent_activity TO parking_admin, parking_operator, parking_customer;


-- ---------------------------------------------------------------------------
-- 6. OPERATOR SCOPING FOR PAYMENTS AND VIOLATIONS
--
-- Migration 009 posts each operator to one facility and scopes sessions,
-- bills and reservations accordingly, but its payment and violation policies
-- only checked the role. An operator at one facility could therefore read and
-- write every other facility's payments and violations. Both policies now
-- resolve the row to a facility the same way the bill policy does.
--
-- A violation names a bay directly, or through its session. One with neither
-- (a pass check at no particular bay) belongs to no facility and is visible to
-- admins only. Every violation the gate functions raise carries its bay.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS p_payment_operator ON payment;
CREATE POLICY p_payment_operator ON payment
    FOR ALL
    USING (
        fn_current_role() = 'operator'
        AND EXISTS (
            SELECT 1
              FROM bill b
              JOIN parking_session ps ON ps.session_id = b.session_id
              JOIN slot  s  ON s.slot_id   = ps.slot_id
              JOIN zone  z  ON z.zone_id   = s.zone_id
              JOIN floor fl ON fl.floor_id = z.floor_id
             WHERE b.bill_id = payment.bill_id
               AND fl.facility_id = fn_current_facility_id()
        )
    )
    WITH CHECK (
        fn_current_role() = 'operator'
        AND EXISTS (
            SELECT 1
              FROM bill b
              JOIN parking_session ps ON ps.session_id = b.session_id
              JOIN slot  s  ON s.slot_id   = ps.slot_id
              JOIN zone  z  ON z.zone_id   = s.zone_id
              JOIN floor fl ON fl.floor_id = z.floor_id
             WHERE b.bill_id = payment.bill_id
               AND fl.facility_id = fn_current_facility_id()
        )
    );

DROP POLICY IF EXISTS p_violation_operator ON violation;
CREATE POLICY p_violation_operator ON violation
    FOR ALL
    USING (
        fn_current_role() = 'operator'
        AND EXISTS (
            SELECT 1
              FROM slot s
              JOIN zone  z  ON z.zone_id   = s.zone_id
              JOIN floor fl ON fl.floor_id = z.floor_id
             WHERE s.slot_id = COALESCE(
                       violation.slot_id,
                       (SELECT ps.slot_id FROM parking_session ps
                         WHERE ps.session_id = violation.session_id))
               AND fl.facility_id = fn_current_facility_id()
        )
    )
    WITH CHECK (
        fn_current_role() = 'operator'
        AND EXISTS (
            SELECT 1
              FROM slot s
              JOIN zone  z  ON z.zone_id   = s.zone_id
              JOIN floor fl ON fl.floor_id = z.floor_id
             WHERE s.slot_id = COALESCE(
                       violation.slot_id,
                       (SELECT ps.slot_id FROM parking_session ps
                         WHERE ps.session_id = violation.session_id))
               AND fl.facility_id = fn_current_facility_id()
        )
    );

COMMIT;

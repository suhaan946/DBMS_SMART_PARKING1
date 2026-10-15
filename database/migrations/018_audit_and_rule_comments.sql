-- ============================================================================
-- 018_audit_and_rule_comments.sql
--
-- Purpose: document the objects added in 013-016, so the generated data
-- dictionary (docs/database/DATA_DICTIONARY.md) explains them. Comments only;
-- no structure or data changes. Self-evident key and name columns are left
-- uncommented, as in 012.
-- ============================================================================

COMMENT ON COLUMN audit_log.audit_id      IS 'Surrogate key, in insertion order.';
COMMENT ON COLUMN audit_log.occurred_at   IS 'When the change was committed by the statement that made it.';
COMMENT ON COLUMN audit_log.actor_user_id IS 'The signed-in user (app.current_user_id) who made the change. NULL for a direct database session; SET NULL if the user is later removed, so history survives.';
COMMENT ON COLUMN audit_log.actor_role    IS 'Role of the actor at the time, kept even if the user''s role changes later.';
COMMENT ON COLUMN audit_log.table_name    IS 'Table the changed row belongs to.';
COMMENT ON COLUMN audit_log.row_id        IS 'Primary key of the changed row in table_name.';
COMMENT ON COLUMN audit_log.action        IS 'INSERT, UPDATE or DELETE.';
COMMENT ON COLUMN audit_log.changes       IS 'INSERT/DELETE: the whole row. UPDATE: only the columns that changed, as {column: {from, to}}.';

COMMENT ON CONSTRAINT ck_audit_action ON audit_log IS
  'The three DML verbs only.';
COMMENT ON CONSTRAINT fk_reservation_vehicle_owner ON reservation IS
  'Ownership: a customer can only book with their own vehicle. Composite FK onto vehicle(vehicle_id, customer_id).';
COMMENT ON CONSTRAINT fk_pass_vehicle_owner ON parking_pass IS
  'Ownership: a pass can only cover the buying customer''s own vehicle.';
COMMENT ON CONSTRAINT fk_reservation_slot_type_match ON reservation IS
  'BUSINESS RULE 2 at booking time: the bay''s vehicle type must equal reservation.vehicle_type_id.';
COMMENT ON CONSTRAINT fk_reservation_vehicle_type_match ON reservation IS
  'Pins reservation.vehicle_type_id to the vehicle''s real type, so the copied column cannot drift.';
COMMENT ON CONSTRAINT fk_session_vehicle_type_match ON parking_session IS
  'Pins parking_session.vehicle_type_id to the vehicle''s real type, so the copied column cannot drift.';
COMMENT ON CONSTRAINT ck_slot_note_only_when_out ON slot IS
  'A service note describes why a bay is out of service, so it may exist only while is_active is FALSE.';
COMMENT ON CONSTRAINT ck_customer_email_shape ON customer IS
  'Basic shape check: something@something.tld, no spaces.';

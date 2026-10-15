-- ============================================================================
-- 008_indexes.sql
--
-- Purpose: index the attributes the application actually searches on.
--
-- Every index below names the query it serves. An index that no query uses is
-- a write cost with no read benefit, so there are no speculative ones here.
-- Primary keys and UNIQUE constraints already create their own indexes and are
-- not repeated.
-- ============================================================================

-- Idempotent DROP IF EXISTS guards below emit "does not exist, skipping"
-- notices on a first run. They are harmless, but they read like failures to
-- someone running this for the first time, so notices are quietened here.
-- Warnings and errors still come through.
SET client_min_messages = warning;


-- SERVES: the gate operator typing a plate into the entry or exit box, and
--         fn_gate_exit's lookup by plate. Highest-frequency lookup in the app.
--         (plate_number is already UNIQUE, which indexes it; this adds the
--          case-folded form so an operator typing 'mh12ab1234' still hits it.)
CREATE INDEX IF NOT EXISTS ix_vehicle_plate_upper
    ON vehicle (upper(plate_number));
COMMENT ON INDEX ix_vehicle_plate_upper IS 'SERVES: gate lookup by plate, case-insensitively.';

-- SERVES: "recent activity" on the gate screen, and every report that filters
--         sessions to a date window (revenue, peak hours, duration).
CREATE INDEX IF NOT EXISTS ix_session_entry_time
    ON parking_session (entry_time DESC);
COMMENT ON INDEX ix_session_entry_time IS 'SERVES: recent-activity feed and all date-windowed session reports.';

-- SERVES: v_current_occupancy's LEFT JOIN from slot to the open session, which
--         runs on every render of the floor map. Partial, because the join
--         only ever looks for open rows — a full index would be mostly dead
--         weight once the history grows.
CREATE INDEX IF NOT EXISTS ix_session_open_by_slot
    ON parking_session (slot_id)
    WHERE exit_time IS NULL;
COMMENT ON INDEX ix_session_open_by_slot IS 'SERVES: v_current_occupancy slot -> open session join.';

-- SERVES: fn_gate_exit and the "is this vehicle already in?" guard in
--         fn_gate_entry.
CREATE INDEX IF NOT EXISTS ix_session_open_by_vehicle
    ON parking_session (vehicle_id)
    WHERE exit_time IS NULL;
COMMENT ON INDEX ix_session_open_by_vehicle IS 'SERVES: open-session lookup by vehicle in fn_gate_entry / fn_gate_exit.';

-- SERVES: the reservations page filtering by state, and
--         fn_expire_stale_reservations scanning for lapsed holds.
CREATE INDEX IF NOT EXISTS ix_reservation_status_until
    ON reservation (status, reserved_until);
COMMENT ON INDEX ix_reservation_status_until IS 'SERVES: reservations list filter and the expiry sweep.';

-- SERVES: fn_allocate_slot's NOT EXISTS against live holds, and
--         v_current_occupancy's reserved-slot join.
CREATE INDEX IF NOT EXISTS ix_reservation_slot_window
    ON reservation USING gist (slot_id, tstzrange(reserved_from, reserved_until))
    WHERE status IN ('held', 'confirmed');
COMMENT ON INDEX ix_reservation_slot_window IS 'SERVES: live-hold overlap checks in fn_allocate_slot and v_current_occupancy.';

-- SERVES: the billing page's status filter and the unpaid-bills tile.
CREATE INDEX IF NOT EXISTS ix_bill_status_generated
    ON bill (status, generated_at DESC);
COMMENT ON INDEX ix_bill_status_generated IS 'SERVES: billing list filtered by status, newest first.';

-- SERVES: v_revenue_daily's per-bill payment rollup.
CREATE INDEX IF NOT EXISTS ix_payment_bill
    ON payment (bill_id);
COMMENT ON INDEX ix_payment_bill IS 'SERVES: payment rollup per bill in v_revenue_daily and the status trigger.';

-- SERVES: the revenue report's date grouping and the payments-by-method chart.
CREATE INDEX IF NOT EXISTS ix_payment_paid_at
    ON payment (paid_at DESC);
COMMENT ON INDEX ix_payment_paid_at IS 'SERVES: payments over time and method breakdown.';

-- SERVES: every slot-map query, which filters slots to one facility via
--         zone -> floor. Indexing the join columns keeps the 120-slot grid a
--         index scan rather than a sequential scan of every slot ever built.
CREATE INDEX IF NOT EXISTS ix_slot_zone      ON slot (zone_id);
CREATE INDEX IF NOT EXISTS ix_slot_type      ON slot (vehicle_type_id);
CREATE INDEX IF NOT EXISTS ix_zone_floor     ON zone (floor_id);
CREATE INDEX IF NOT EXISTS ix_floor_facility ON floor (facility_id);
COMMENT ON INDEX ix_slot_zone IS 'SERVES: slot -> zone -> floor -> facility chain behind the floor map.';

-- SERVES: fn_gate_entry's pass lookup, which runs on every arrival.
CREATE INDEX IF NOT EXISTS ix_pass_vehicle_window
    ON parking_pass (vehicle_id, valid_from, valid_to)
    WHERE cancelled_at IS NULL;
COMMENT ON INDEX ix_pass_vehicle_window IS 'SERVES: valid-pass check during gate entry.';

-- SERVES: the violations report, which is almost always read newest-first and
--         filtered to unresolved.
CREATE INDEX IF NOT EXISTS ix_violation_detected
    ON violation (detected_at DESC);
CREATE INDEX IF NOT EXISTS ix_violation_unresolved
    ON violation (kind, detected_at DESC)
    WHERE resolved_at IS NULL;
COMMENT ON INDEX ix_violation_unresolved IS 'SERVES: outstanding-violations list by kind.';

-- SERVES: the customer list search box, and RLS policy lookups that resolve
--         a logged-in user to their customer row on every query.
CREATE INDEX IF NOT EXISTS ix_customer_user   ON customer (user_id);
CREATE INDEX IF NOT EXISTS ix_vehicle_customer ON vehicle (customer_id);
COMMENT ON INDEX ix_customer_user IS 'SERVES: RLS policies resolving app_user -> customer on every customer-scoped query.';

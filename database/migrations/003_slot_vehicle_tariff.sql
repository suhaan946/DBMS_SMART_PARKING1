-- ============================================================================
-- 003_slot_vehicle_tariff.sql
--
-- Purpose: the three tables that meet at a parking session — the space, the
--          car, and the price list.
--
-- Design note that matters for the viva: `slot` carries no `status` column.
-- Whether a slot is occupied is derivable from parking_session (a slot is busy
-- exactly when it has a session with no exit_time). Storing it as well would
-- create an update anomaly — two places to change on every gate event, and
-- nothing in the schema forcing them to agree. Occupancy is served by the
-- v_current_occupancy view instead. See docs/database/NORMALIZATION.md §4.
-- ============================================================================

-- Idempotent DROP IF EXISTS guards below emit "does not exist, skipping"
-- notices on a first run. They are harmless, but they read like failures to
-- someone running this for the first time, so notices are quietened here.
-- Warnings and errors still come through.
SET client_min_messages = warning;


-- ---------------------------------------------------------------------------
-- slot — one parking space
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS slot (
    slot_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    zone_id         BIGINT NOT NULL,
    code            TEXT   NOT NULL,          -- 'G-A-07'
    vehicle_type_id BIGINT NOT NULL,
    -- FALSE = out of service (maintenance, blocked, reserved for signage).
    -- An inactive slot must never be allocated; enforced in fn_allocate_slot.
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    -- Physical position on the floor map, so the grid renders as a plan rather
    -- than an arbitrary list. Nullable: not every slot needs coordinates.
    grid_row        SMALLINT,
    grid_col        SMALLINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_slot_zone
        FOREIGN KEY (zone_id) REFERENCES zone (zone_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_slot_vehicle_type
        FOREIGN KEY (vehicle_type_id) REFERENCES vehicle_type (vehicle_type_id)
        -- RESTRICT: deleting a vehicle type that slots are built for would
        -- leave those slots unallocatable and their history unexplainable.
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT uq_slot_zone_code UNIQUE (zone_id, code),
    CONSTRAINT ck_slot_code_shape CHECK (code ~ '^[A-Z0-9-]{2,16}$'),

    -- ------------------------------------------------------------------
    -- BUSINESS RULE 2 (part 1 of 3) — slot / vehicle-type match.
    -- Redundant on its own (slot_id is already unique), but it gives
    -- parking_session a composite key to point a foreign key at. Together
    -- with the matching key on `vehicle` and the two composite FKs on
    -- parking_session, a session physically cannot name a slot and a vehicle
    -- whose types differ. No trigger, no application check: the constraint
    -- is unfalsifiable because the referenced row does not exist.
    -- ------------------------------------------------------------------
    CONSTRAINT uq_slot_id_vehicle_type UNIQUE (slot_id, vehicle_type_id)
);

COMMENT ON TABLE  slot IS 'One parking space. Occupancy is NOT stored here - it is derived from parking_session via v_current_occupancy.';
COMMENT ON CONSTRAINT uq_slot_id_vehicle_type ON slot IS 'Target for the composite FK on parking_session that makes slot/vehicle type mismatch structurally impossible.';


-- ---------------------------------------------------------------------------
-- vehicle — a registered car, bike or truck
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vehicle (
    vehicle_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT NOT NULL,
    -- UNIQUE because a plate identifies a vehicle nationally; it is also the
    -- attribute the gate operator types, so it carries its own index (008).
    plate_number    TEXT   NOT NULL UNIQUE,
    vehicle_type_id BIGINT NOT NULL,
    make            TEXT,
    model           TEXT,
    colour          TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_vehicle_customer
        FOREIGN KEY (customer_id) REFERENCES customer (customer_id)
        -- RESTRICT: a vehicle with parking history cannot be silently removed
        -- with its owner; the operator must reassign or archive it first.
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_vehicle_vehicle_type
        FOREIGN KEY (vehicle_type_id) REFERENCES vehicle_type (vehicle_type_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,

    -- Indian plate format: MH 12 AB 1234, stored without spaces.
    CONSTRAINT ck_vehicle_plate_shape
        CHECK (plate_number ~ '^[A-Z]{2}[0-9]{1,2}[A-Z]{1,3}[0-9]{4}$'),

    -- BUSINESS RULE 2 (part 2 of 3) — see the note on slot above.
    CONSTRAINT uq_vehicle_id_vehicle_type UNIQUE (vehicle_id, vehicle_type_id)
);

COMMENT ON TABLE vehicle IS 'A customer vehicle. plate_number is UNIQUE and is the operator search key.';
COMMENT ON CONSTRAINT ck_vehicle_plate_shape ON vehicle IS 'Indian registration format, e.g. MH12AB1234, stored unspaced and uppercase.';


-- ---------------------------------------------------------------------------
-- tariff — the price list a bill is computed from
--
-- Priced per (facility, vehicle_type, validity window) rather than per slot,
-- because rate is a property of what you drive and where you park, not of the
-- individual bay. A tariff is never edited in place once bills reference it —
-- it is closed with effective_to and a new row is opened, so an old bill can
-- always be re-derived. That is why fn_calculate_charge picks the tariff that
-- was in force at the session's entry_time, not the one in force today.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tariff (
    tariff_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facility_id          BIGINT NOT NULL,
    vehicle_type_id      BIGINT NOT NULL,
    name                 TEXT   NOT NULL,
    -- Grace period: leave within this many minutes and the charge is zero.
    free_minutes         INTEGER NOT NULL DEFAULT 15,
    -- First hour is usually dearer than the ones after it.
    first_hour_rate      NUMERIC(10,2) NOT NULL,
    subsequent_hour_rate NUMERIC(10,2) NOT NULL,
    -- Upper bound per 24 hours, so an overnight stay cannot run away.
    daily_cap            NUMERIC(10,2) NOT NULL,
    effective_from       TIMESTAMPTZ NOT NULL DEFAULT now(),
    effective_to         TIMESTAMPTZ,          -- NULL = still in force

    CONSTRAINT fk_tariff_facility
        FOREIGN KEY (facility_id) REFERENCES facility (facility_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_tariff_vehicle_type
        FOREIGN KEY (vehicle_type_id) REFERENCES vehicle_type (vehicle_type_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,

    -- BUSINESS RULE 5 (part 1) — a charge can never be negative, because the
    -- inputs it is built from cannot be.
    CONSTRAINT ck_tariff_rates_non_negative
        CHECK (first_hour_rate >= 0 AND subsequent_hour_rate >= 0 AND daily_cap >= 0),
    CONSTRAINT ck_tariff_free_minutes CHECK (free_minutes >= 0 AND free_minutes <= 1440),
    -- A daily cap below the first hour would make the cap meaningless.
    CONSTRAINT ck_tariff_cap_sane      CHECK (daily_cap >= first_hour_rate),
    CONSTRAINT ck_tariff_window_valid  CHECK (effective_to IS NULL OR effective_to > effective_from)
);

COMMENT ON TABLE tariff IS 'Versioned price list. Superseded rows are closed with effective_to so historical bills stay reproducible.';

-- Only one tariff may be in force for a given facility and vehicle type at any
-- instant. Declared as an exclusion constraint rather than a unique index
-- because "in force at the same time" is a range-overlap test, not an equality
-- test. Without it, fn_calculate_charge could find two candidate tariffs and
-- silently pick one.
ALTER TABLE tariff DROP CONSTRAINT IF EXISTS ex_tariff_no_overlap;
ALTER TABLE tariff
    ADD CONSTRAINT ex_tariff_no_overlap
    EXCLUDE USING gist (
        facility_id     WITH =,
        vehicle_type_id WITH =,
        tstzrange(effective_from, effective_to) WITH &&
    );

COMMENT ON CONSTRAINT ex_tariff_no_overlap ON tariff IS 'Guarantees fn_calculate_charge finds exactly one applicable tariff for any instant.';

-- ============================================================================
-- 002_core_tables.sql
--
-- Purpose: the structural spine of the model — who uses the system, what a
--          facility is made of, and what kinds of vehicle it accepts.
--
-- Every table declares a primary key, explicit NOT NULL on each attribute that
-- is required by the domain, considered DEFAULTs, and foreign keys whose
-- ON DELETE behaviour is chosen deliberately (see the note above each one).
-- ============================================================================

-- Idempotent DROP IF EXISTS guards below emit "does not exist, skipping"
-- notices on a first run. They are harmless, but they read like failures to
-- someone running this for the first time, so notices are quietened here.
-- Warnings and errors still come through.
SET client_min_messages = warning;


-- ---------------------------------------------------------------------------
-- app_user — authentication and authorisation subject
--
-- Separate from `customer` on purpose: an operator or admin is a user with no
-- customer record, and a walk-in customer is a customer with no login. Merging
-- them would force NULLable password columns on people who never sign in.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS app_user (
    user_id        BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email          CITEXT      NOT NULL UNIQUE,
    password_hash  TEXT        NOT NULL,
    full_name      TEXT        NOT NULL,
    role           user_role   NOT NULL DEFAULT 'customer',
    -- An operator is scoped to exactly one facility; admins and customers are
    -- not. The CHECK makes that rule structural rather than conventional.
    facility_id    BIGINT,
    is_active      BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_app_user_email_shape
        CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
    CONSTRAINT ck_app_user_name_not_blank
        CHECK (length(btrim(full_name)) > 0),
    CONSTRAINT ck_app_user_operator_has_facility
        CHECK ((role = 'operator') = (facility_id IS NOT NULL))
);

COMMENT ON TABLE  app_user IS 'Login identity and role. Drives every row-level security policy.';
COMMENT ON COLUMN app_user.facility_id IS 'Required for operators, forbidden for admins and customers (ck_app_user_operator_has_facility).';


-- ---------------------------------------------------------------------------
-- facility — one physical parking building
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS facility (
    facility_id   BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          TEXT        NOT NULL UNIQUE,
    address_line  TEXT        NOT NULL,
    city          TEXT        NOT NULL,
    opens_at      TIME        NOT NULL DEFAULT '00:00',
    closes_at     TIME        NOT NULL DEFAULT '23:59',
    -- Percentage added to every bill raised at this facility. Held here rather
    -- than on `bill` because it is a property of the facility, not of the bill;
    -- storing it per bill would be a transitive dependency (see NORMALIZATION).
    tax_rate_pct  NUMERIC(5,2) NOT NULL DEFAULT 18.00,
    is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_facility_tax_rate  CHECK (tax_rate_pct >= 0 AND tax_rate_pct <= 100),
    CONSTRAINT ck_facility_name_not_blank CHECK (length(btrim(name)) > 0)
);

COMMENT ON TABLE facility IS 'A parking building. Owns floors, tariffs and operators.';

-- Deferred until facility exists. RESTRICT: a facility with staff attached must
-- have those staff reassigned first; silently orphaning an operator's scope
-- would leave rows an RLS policy can no longer evaluate.
ALTER TABLE app_user
    DROP CONSTRAINT IF EXISTS fk_app_user_facility;
ALTER TABLE app_user
    ADD CONSTRAINT fk_app_user_facility
        FOREIGN KEY (facility_id) REFERENCES facility (facility_id)
        ON UPDATE CASCADE ON DELETE RESTRICT;


-- ---------------------------------------------------------------------------
-- floor — a level within a facility
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS floor (
    floor_id     BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facility_id  BIGINT      NOT NULL,
    level_number INTEGER     NOT NULL,   -- 0 = ground, negative = basement
    name         TEXT        NOT NULL,

    CONSTRAINT fk_floor_facility
        FOREIGN KEY (facility_id) REFERENCES facility (facility_id)
        -- CASCADE: a floor has no meaning without its building.
        ON UPDATE CASCADE ON DELETE CASCADE,
    -- Two floors cannot share a level number within one building.
    CONSTRAINT uq_floor_facility_level UNIQUE (facility_id, level_number),
    CONSTRAINT ck_floor_level_range CHECK (level_number BETWEEN -5 AND 50)
);

COMMENT ON TABLE floor IS 'A level within a facility. level_number 0 is ground, negatives are basements.';


-- ---------------------------------------------------------------------------
-- zone — a named block of slots on a floor
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS zone (
    zone_id   BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    floor_id  BIGINT      NOT NULL,
    code      TEXT        NOT NULL,      -- 'A', 'B', 'C'
    name      TEXT        NOT NULL,

    CONSTRAINT fk_zone_floor
        FOREIGN KEY (floor_id) REFERENCES floor (floor_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT uq_zone_floor_code UNIQUE (floor_id, code),
    CONSTRAINT ck_zone_code_shape CHECK (code ~ '^[A-Z]{1,3}$')
);

COMMENT ON TABLE zone IS 'A block of slots on one floor, e.g. Zone A. Used for aisle grouping in the slot map.';


-- ---------------------------------------------------------------------------
-- vehicle_type — Car, Bike, SUV, EV, Truck
--
-- A lookup table rather than a CHECK list of strings, because tariffs and slots
-- both reference it and a text list would have to be kept in step in three
-- places. Adding a vehicle type is a data change, not a schema change.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vehicle_type (
    vehicle_type_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            TEXT   NOT NULL UNIQUE,   -- 'CAR', 'BIKE'
    name            TEXT   NOT NULL,
    -- Drives the slot footprint drawn on the floor map.
    footprint_units SMALLINT NOT NULL DEFAULT 1,

    CONSTRAINT ck_vehicle_type_code_shape CHECK (code ~ '^[A-Z]{2,10}$'),
    CONSTRAINT ck_vehicle_type_footprint  CHECK (footprint_units BETWEEN 1 AND 4)
);

COMMENT ON TABLE vehicle_type IS 'Vehicle categories. Referenced by slot, vehicle, tariff and pass_type.';


-- ---------------------------------------------------------------------------
-- customer — a person who parks here
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS customer (
    customer_id BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Optional: a walk-in customer recorded at the gate has no login.
    user_id     BIGINT      UNIQUE,
    full_name   TEXT        NOT NULL,
    phone       TEXT        NOT NULL UNIQUE,
    email       CITEXT      UNIQUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_customer_user
        FOREIGN KEY (user_id) REFERENCES app_user (user_id)
        -- SET NULL: deleting a login must not erase the parking history
        -- attached to that person, which bills and sessions still reference.
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT ck_customer_phone_shape CHECK (phone ~ '^[0-9]{10}$'),
    CONSTRAINT ck_customer_name_not_blank CHECK (length(btrim(full_name)) > 0)
);

COMMENT ON TABLE customer IS 'A parking customer. user_id is NULL for walk-ins recorded at the gate.';

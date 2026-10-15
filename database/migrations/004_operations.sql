-- ============================================================================
-- 004_operations.sql
--
-- Purpose: reservations, passes and parking sessions — the tables that record
--          what actually happens at the gate.
--
-- Four of the five graded business rules are declared here. The fifth
-- (tariff-based charging) lands in 006 with fn_calculate_charge.
-- ============================================================================

-- Idempotent DROP IF EXISTS guards below emit "does not exist, skipping"
-- notices on a first run. They are harmless, but they read like failures to
-- someone running this for the first time, so notices are quietened here.
-- Warnings and errors still come through.
SET client_min_messages = warning;


-- ---------------------------------------------------------------------------
-- pass_type — the products on sale (Daily / Weekly / Monthly)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pass_type (
    pass_type_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            TEXT   NOT NULL UNIQUE,
    name            TEXT   NOT NULL,
    duration_days   INTEGER NOT NULL,
    price           NUMERIC(10,2) NOT NULL,
    vehicle_type_id BIGINT NOT NULL,

    CONSTRAINT fk_pass_type_vehicle_type
        FOREIGN KEY (vehicle_type_id) REFERENCES vehicle_type (vehicle_type_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ck_pass_type_duration CHECK (duration_days BETWEEN 1 AND 366),
    CONSTRAINT ck_pass_type_price    CHECK (price >= 0)
);

COMMENT ON TABLE pass_type IS 'Sellable pass products. A pass is an instance of a pass_type bought by a customer.';


-- ---------------------------------------------------------------------------
-- parking_pass — a pass a customer has bought
--
-- Named parking_pass, not pass: PASS is a reserved word in SQL.
--
-- Note there is no `status` column. A pass is active exactly when now() falls
-- inside [valid_from, valid_to) and it has not been cancelled — so status is
-- derivable from data already present, and storing it would need a nightly job
-- to keep it honest. `cancelled_at` is stored because cancellation is an event
-- that cannot be inferred from the dates. v_pass_usage does the derivation.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS parking_pass (
    pass_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  BIGINT NOT NULL,
    vehicle_id   BIGINT NOT NULL,
    pass_type_id BIGINT NOT NULL,
    facility_id  BIGINT NOT NULL,
    valid_from   TIMESTAMPTZ NOT NULL,
    valid_to     TIMESTAMPTZ NOT NULL,
    -- Price is copied from pass_type at purchase time on purpose. It is NOT a
    -- redundant duplicate: pass_type.price is today's shelf price, this is the
    -- price this customer actually paid, and the two must be free to diverge
    -- when the shelf price changes. See NORMALIZATION.md §5.
    price_paid   NUMERIC(10,2) NOT NULL,
    cancelled_at TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_pass_customer
        FOREIGN KEY (customer_id) REFERENCES customer (customer_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_pass_vehicle
        FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_pass_type
        FOREIGN KEY (pass_type_id) REFERENCES pass_type (pass_type_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_pass_facility
        FOREIGN KEY (facility_id) REFERENCES facility (facility_id)
        ON UPDATE CASCADE ON DELETE CASCADE,

    CONSTRAINT ck_pass_window   CHECK (valid_to > valid_from),
    CONSTRAINT ck_pass_price    CHECK (price_paid >= 0)
);

COMMENT ON TABLE parking_pass IS 'A purchased pass. Active-ness is derived from the date window and cancelled_at, not stored.';

-- One vehicle cannot hold two live passes at the same facility over the same
-- period — that would let a customer double-pay and would make "which pass was
-- used?" ambiguous in the violations report.
ALTER TABLE parking_pass DROP CONSTRAINT IF EXISTS ex_pass_no_overlap;
ALTER TABLE parking_pass
    ADD CONSTRAINT ex_pass_no_overlap
    EXCLUDE USING gist (
        vehicle_id  WITH =,
        facility_id WITH =,
        tstzrange(valid_from, valid_to) WITH &&
    ) WHERE (cancelled_at IS NULL);


-- ---------------------------------------------------------------------------
-- reservation — a slot held for a future arrival
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reservation (
    reservation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id    BIGINT NOT NULL,
    vehicle_id     BIGINT NOT NULL,
    slot_id        BIGINT NOT NULL,
    reserved_from  TIMESTAMPTZ NOT NULL,
    reserved_until TIMESTAMPTZ NOT NULL,
    status         reservation_status NOT NULL DEFAULT 'held',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_reservation_customer
        FOREIGN KEY (customer_id) REFERENCES customer (customer_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_reservation_vehicle
        FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_reservation_slot
        FOREIGN KEY (slot_id) REFERENCES slot (slot_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,

    -- ------------------------------------------------------------------
    -- BUSINESS RULE 4 (part 1) — reservation expiry.
    -- A booking that ends before it starts is not a booking.
    -- ------------------------------------------------------------------
    CONSTRAINT ck_reservation_window CHECK (reserved_until > reserved_from)
);

COMMENT ON TABLE reservation IS 'A slot held for a future arrival. Stale holds are expired by fn_expire_stale_reservations.';

-- ------------------------------------------------------------------
-- BUSINESS RULE 4 (part 2) — two live holds cannot cover the same slot at
-- overlapping times. Only 'held' and 'confirmed' block the slot; an expired,
-- cancelled or fulfilled row is history and must not stop a rebooking.
--
-- This is the constraint an application-level "is it free?" SELECT cannot
-- provide: two concurrent transactions both read "free" and both insert. The
-- exclusion constraint makes the second one fail at COMMIT.
-- ------------------------------------------------------------------
ALTER TABLE reservation DROP CONSTRAINT IF EXISTS ex_reservation_no_overlap;
ALTER TABLE reservation
    ADD CONSTRAINT ex_reservation_no_overlap
    EXCLUDE USING gist (
        slot_id WITH =,
        tstzrange(reserved_from, reserved_until) WITH &&
    ) WHERE (status IN ('held', 'confirmed'));

COMMENT ON CONSTRAINT ex_reservation_no_overlap ON reservation IS 'BUSINESS RULE 4: no two live reservations may overlap on one slot.';


-- ---------------------------------------------------------------------------
-- parking_session — a vehicle physically in a slot
--
-- No `status` column: a session is active exactly when exit_time IS NULL.
-- Deriving it removes the possibility of a row that says 'active' while
-- carrying an exit_time, and lets the partial unique indexes below express
-- "one active X" directly.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS parking_session (
    session_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_no       TEXT   NOT NULL UNIQUE,
    slot_id         BIGINT NOT NULL,
    vehicle_id      BIGINT NOT NULL,
    -- Denormalised on purpose. It is the join column that makes the two
    -- composite foreign keys below able to compare the slot's type against the
    -- vehicle's type. It is not independent data: both FKs force it to equal
    -- slot.vehicle_type_id AND vehicle.vehicle_type_id simultaneously, so it
    -- cannot drift. See NORMALIZATION.md §5 for why this is not a 3NF breach.
    vehicle_type_id BIGINT NOT NULL,
    entry_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    exit_time       TIMESTAMPTZ,
    -- Which reservation this arrival fulfilled, if any.
    reservation_id  BIGINT UNIQUE,
    -- Which pass covered it, if any. NULL means it is chargeable by tariff.
    pass_id         BIGINT,
    entry_operator_id BIGINT,
    exit_operator_id  BIGINT,

    CONSTRAINT fk_session_reservation
        FOREIGN KEY (reservation_id) REFERENCES reservation (reservation_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_session_pass
        FOREIGN KEY (pass_id) REFERENCES parking_pass (pass_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_session_entry_operator
        FOREIGN KEY (entry_operator_id) REFERENCES app_user (user_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_session_exit_operator
        FOREIGN KEY (exit_operator_id) REFERENCES app_user (user_id)
        ON UPDATE CASCADE ON DELETE SET NULL,

    -- ------------------------------------------------------------------
    -- BUSINESS RULE 2 (part 3 of 3) — slot / vehicle-type match.
    -- These two composite foreign keys are the whole mechanism. To insert a
    -- session the database must find a slot row with (this slot_id, this
    -- vehicle_type_id) AND a vehicle row with (this vehicle_id, this
    -- vehicle_type_id). Put a car in a bike bay and one of those rows does not
    -- exist, so the INSERT fails with a foreign key violation. There is no
    -- trigger to disable and no code path that can skip it.
    -- ------------------------------------------------------------------
    CONSTRAINT fk_session_slot_type_match
        FOREIGN KEY (slot_id, vehicle_type_id)
        REFERENCES slot (slot_id, vehicle_type_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_session_vehicle_type_match
        FOREIGN KEY (vehicle_id, vehicle_type_id)
        REFERENCES vehicle (vehicle_id, vehicle_type_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,

    -- ------------------------------------------------------------------
    -- BUSINESS RULE 3 — exit after entry.
    -- ------------------------------------------------------------------
    CONSTRAINT ck_session_exit_after_entry
        CHECK (exit_time IS NULL OR exit_time > entry_time),

    CONSTRAINT ck_session_ticket_shape CHECK (ticket_no ~ '^TK-[0-9A-Z]{6,12}$')
);

COMMENT ON TABLE parking_session IS 'A vehicle occupying a slot. Active when exit_time IS NULL; there is deliberately no status column.';
COMMENT ON CONSTRAINT fk_session_slot_type_match ON parking_session IS 'BUSINESS RULE 2: composite FK making a car-in-bike-bay session structurally impossible.';
COMMENT ON CONSTRAINT ck_session_exit_after_entry ON parking_session IS 'BUSINESS RULE 3: exit must be strictly later than entry.';

-- ------------------------------------------------------------------
-- BUSINESS RULE 1 — one active vehicle per slot, and one active slot per
-- vehicle. Partial unique indexes: the uniqueness applies only to rows that
-- are still open, so a slot can be reused any number of times over its life
-- but can hold only one car right now.
-- ------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_active_session_slot
    ON parking_session (slot_id)
    WHERE exit_time IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_active_session_vehicle
    ON parking_session (vehicle_id)
    WHERE exit_time IS NULL;

COMMENT ON INDEX uq_active_session_slot    IS 'BUSINESS RULE 1: at most one open session per slot.';
COMMENT ON INDEX uq_active_session_vehicle IS 'BUSINESS RULE 1 (mirror): a vehicle cannot occupy two slots at once.';


-- ---------------------------------------------------------------------------
-- bill — what a completed session costs
--
-- One bill per session (session_id is UNIQUE). total_amount is a GENERATED
-- column, not a stored number a client can post: it is always exactly
-- base_amount + tax_amount, so the arithmetic cannot be wrong in the database
-- even if it is wrong in a caller.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bill (
    bill_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id       BIGINT NOT NULL UNIQUE,
    tariff_id        BIGINT NOT NULL,
    billable_minutes INTEGER NOT NULL,
    base_amount      NUMERIC(10,2) NOT NULL,
    tax_amount       NUMERIC(10,2) NOT NULL,
    total_amount     NUMERIC(10,2)
                     GENERATED ALWAYS AS (base_amount + tax_amount) STORED,
    status           bill_status NOT NULL DEFAULT 'unpaid',
    generated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_bill_session
        FOREIGN KEY (session_id) REFERENCES parking_session (session_id)
        -- CASCADE: a bill has no meaning without the session it bills for.
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_bill_tariff
        FOREIGN KEY (tariff_id) REFERENCES tariff (tariff_id)
        -- RESTRICT: the tariff a bill was computed from must remain readable
        -- so the figure can be defended later.
        ON UPDATE CASCADE ON DELETE RESTRICT,

    -- BUSINESS RULE 5 (part 2) — a charge is never negative.
    CONSTRAINT ck_bill_base_non_negative CHECK (base_amount >= 0),
    CONSTRAINT ck_bill_tax_non_negative  CHECK (tax_amount  >= 0),
    CONSTRAINT ck_bill_minutes_non_negative CHECK (billable_minutes >= 0)
);

COMMENT ON TABLE bill IS 'One bill per completed session. base_amount is overwritten from fn_calculate_charge by trigger; total_amount is generated.';


-- ---------------------------------------------------------------------------
-- payment — money recorded against a bill
--
-- Records only. No gateway is integrated and no card, CVV or UPI credential
-- is stored or collected anywhere in this system. reference_no is the free-text
-- receipt or transaction string an operator reads off a terminal.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payment (
    payment_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bill_id      BIGINT NOT NULL,
    amount       NUMERIC(10,2) NOT NULL,
    method       payment_method NOT NULL,
    reference_no TEXT,
    paid_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    received_by  BIGINT,

    CONSTRAINT fk_payment_bill
        FOREIGN KEY (bill_id) REFERENCES bill (bill_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_payment_received_by
        FOREIGN KEY (received_by) REFERENCES app_user (user_id)
        ON UPDATE CASCADE ON DELETE SET NULL,

    CONSTRAINT ck_payment_amount_positive CHECK (amount > 0)
);

COMMENT ON TABLE payment IS 'A recorded receipt against a bill. Several payments may settle one bill (partly_paid). No payment credentials are stored.';


-- ---------------------------------------------------------------------------
-- violation — the Review-2 violations report is built on this
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS violation (
    violation_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind           violation_type NOT NULL,
    session_id     BIGINT,
    vehicle_id     BIGINT NOT NULL,
    slot_id        BIGINT,
    detected_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    penalty_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
    notes          TEXT,
    resolved_at    TIMESTAMPTZ,

    CONSTRAINT fk_violation_session
        FOREIGN KEY (session_id) REFERENCES parking_session (session_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_violation_vehicle
        FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_violation_slot
        FOREIGN KEY (slot_id) REFERENCES slot (slot_id)
        ON UPDATE CASCADE ON DELETE SET NULL,

    CONSTRAINT ck_violation_penalty CHECK (penalty_amount >= 0),
    CONSTRAINT ck_violation_resolved_after CHECK (resolved_at IS NULL OR resolved_at >= detected_at)
);

COMMENT ON TABLE violation IS 'Logged infringements: overstay, wrong slot type, no valid pass, unpaid exit, reservation no-show.';

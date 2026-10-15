# Normalization to Third Normal Form

Smart Parking Lot Allocation & Billing System — DBMS PBL Project 20.

This document does the derivation rather than asserting the result. It starts
from the unnormalised ticket that the manual system actually produces, lists
the functional dependencies, and shows what each normal form forces out.

---

## 1. The starting point: one flat parking record

A manual parking operation keeps one row per ticket. Everything is on the slip:

```
PARKING_RECORD(
    ticket_no, facility_name, facility_address, facility_tax_rate,
    floor_name, zone_code, slot_code, slot_vehicle_type,
    customer_name, customer_phone, customer_email,
    plate_number, vehicle_type, vehicle_make, vehicle_model,
    entry_time, exit_time,
    tariff_first_hour, tariff_next_hour, tariff_daily_cap, tariff_free_minutes,
    base_amount, tax_amount, total_amount,
    payment_methods_and_amounts,      -- often several, written in one box
    pass_type, pass_valid_from, pass_valid_to, pass_price
)
```

Three problems are visible before any theory is applied:

* **Update anomaly.** The facility's tax rate is written on every ticket. A rate
  change means rewriting every future ticket and leaves old ones disagreeing
  with each other for no recorded reason.
* **Insertion anomaly.** A new bay cannot be recorded until a car parks in it,
  because a bay only exists as a column on a ticket.
* **Deletion anomaly.** Deleting the last ticket for a customer erases the
  customer's phone number, which nothing else stores.

---

## 2. Functional dependencies

Written as `determinant → dependent`. These are the real dependencies of the
domain, and every decomposition below is justified by one of them.

**Facility structure**

```
F1   facility_id            → name, address_line, city, opens_at, closes_at, tax_rate_pct
F2   name                   → facility_id                       (name is UNIQUE, a candidate key)
F3   floor_id               → facility_id, level_number, name
F4   {facility_id, level_number} → floor_id                     (candidate key)
F5   zone_id                → floor_id, code, name
F6   {floor_id, code}       → zone_id                           (candidate key)
F7   slot_id                → zone_id, code, vehicle_type_id, is_active, service_note,
                              grid_row, grid_col
F8   {zone_id, code}        → slot_id                           (candidate key)
```

**People and vehicles**

```
F9   user_id                → email, password_hash, full_name, role, facility_id
F10  email                  → user_id                           (candidate key)
F11  customer_id            → user_id, full_name, phone, email
F12  phone                  → customer_id                       (candidate key)
F13  vehicle_id             → customer_id, plate_number, vehicle_type_id, make, model, colour
F14  plate_number           → vehicle_id                        (candidate key)
F15  vehicle_type_id        → code, name, footprint_units
```

**Pricing**

```
F16  tariff_id              → facility_id, vehicle_type_id, name, free_minutes,
                              first_hour_rate, subsequent_hour_rate, daily_cap,
                              effective_from, effective_to
F17  {facility_id, vehicle_type_id, instant}
                            → tariff_id
     -- "the tariff in force for this facility and type at this moment".
     -- Enforced by the exclusion constraint ex_tariff_no_overlap, which is what
     -- makes this a function rather than a relation. Without it the same
     -- determinant could yield two tariffs and fn_calculate_charge would have
     -- to guess.
F18  pass_type_id           → code, name, duration_days, price, vehicle_type_id
```

**Operations**

```
F19  session_id             → ticket_no, slot_id, vehicle_id, vehicle_type_id,
                              entry_time, exit_time, reservation_id, pass_id,
                              entry_operator_id, exit_operator_id
F20  ticket_no              → session_id                        (candidate key)
F21  {slot_id}   where exit_time IS NULL → session_id           (partial key: rule 1)
F22  {vehicle_id} where exit_time IS NULL → session_id          (partial key: rule 1)
F23  reservation_id         → customer_id, vehicle_id, slot_id, vehicle_type_id,
                              reserved_from, reserved_until, status
F24  pass_id                → customer_id, vehicle_id, pass_type_id, facility_id,
                              valid_from, valid_to, price_paid, cancelled_at
```

**Money**

```
F25  bill_id                → session_id, tariff_id, billable_minutes,
                              base_amount, tax_amount, status, generated_at
F26  session_id             → bill_id                           (one bill per session)
F27  payment_id             → bill_id, amount, method, reference_no, paid_at, received_by
F28  violation_id           → kind, session_id, vehicle_id, slot_id,
                              detected_at, penalty_amount, resolved_at
```

**History**

```
F29  audit_id               → occurred_at, actor_user_id, actor_role,
                              table_name, row_id, action, changes
```

`actor_role` looks derivable from `actor_user_id` (F9 gives a user's role), but
it is the role **at the time of the change**, a separate fact that must not
follow later role changes, for the same reason as `price_paid` below.

**Derived, and therefore deliberately not stored**

```
D1   {base_amount, tax_amount}    → total_amount
     -- implemented as a GENERATED ALWAYS column, so it cannot disagree.
D2   {session_id}                 → base_amount
     -- via fn_calculate_charge(session_id); a trigger overwrites whatever a
     -- client sends, so the dependency holds in fact, not just on paper.
D3   {exit_time}                  → session is active / completed
D4   {valid_from, valid_to, cancelled_at, now()} → pass state
D5   {slot_id, open sessions, live reservations} → slot state
```

---

## 3. The three normal forms

### 1NF — atomic values, no repeating groups

The flat record fails 1NF in two places.

`payment_methods_and_amounts` holds a list: *"₹200 cash, ₹150 UPI"*. A list in a
column cannot be summed, filtered by method, or constrained to be positive.

**Decomposition.** Split the repeating group into its own relation, keyed by the
bill it settles (F27):

```
BILL(bill_id, …)
PAYMENT(payment_id, bill_id, amount, method, reference_no, paid_at, received_by)
```

`SUM(amount) GROUP BY method` becomes a query rather than string parsing, and
`CHECK (amount > 0)` becomes expressible.

The second 1NF violation is subtler: **the tariff itself is a repeating group
over time**. One price list per facility per vehicle type is not one value — it
is a series of values, each valid for a period. Flattening it means a rate
change destroys the ability to re-derive an old bill.

**Decomposition.** Give the tariff a validity interval and let rows accumulate:

```
TARIFF(tariff_id, facility_id, vehicle_type_id, …, effective_from, effective_to)
```

`effective_to IS NULL` marks the current row. Superseding a tariff closes the
old row rather than overwriting it.

**After 1NF:** all attributes atomic; `PAYMENT` and a temporal `TARIFF` extracted.

---

### 2NF — no partial dependency on part of a composite key

2NF only bites where a candidate key is composite. Two places in this model have
one.

**(a) The physical hierarchy.** Identify a bay naturally and the key is
`{facility_name, level_number, zone_code, slot_code}`. Against that composite
key:

```
{facility_name}                          → facility_address, facility_tax_rate
{facility_name, level_number}            → floor_name
{facility_name, level_number, zone_code} → zone_name
```

Each is a **partial** dependency — determined by a proper subset of the key. So
the facility's address sits on a row keyed by an individual bay, repeated once
per bay: 134 copies of one address in this seed, and 134 rows to update if the
facility moves.

**Decomposition** into the containment chain, each level keyed by its own
surrogate with the natural key preserved as UNIQUE (F1–F8):

```
FACILITY(facility_id, name, address_line, city, opens_at, closes_at, tax_rate_pct)
FLOOR   (floor_id, facility_id, level_number, name)   UNIQUE(facility_id, level_number)
ZONE    (zone_id, floor_id, code, name)               UNIQUE(floor_id, code)
SLOT    (slot_id, zone_id, code, vehicle_type_id, …)  UNIQUE(zone_id, code)
```

**(b) The pass.** Keyed naturally by `{plate_number, valid_from}`:

```
{plate_number} → customer_name, customer_phone, vehicle_make
```

— partial again, since the owner does not depend on when the pass starts.

**Decomposition** into `PARKING_PASS` referencing `VEHICLE` and `CUSTOMER` by key
(F24), with owner attributes left in their own relations.

**After 2NF:** every non-key attribute depends on a whole candidate key.

---

### 3NF — no transitive dependency on a non-key attribute

Four transitive dependencies survive 2NF. Each is `key → X → Y` where `X` is not
a key, which is exactly the 3NF violation.

**(a) Tax rate on the bill**

```
bill_id → session_id → … → facility_id → tax_rate_pct
```

Storing `tax_rate_pct` on `bill` makes the rate depend on the bill only through
the facility. Two bills raised the same day at the same site could then carry
different rates with nothing to say which is right.

*Resolved:* `tax_rate_pct` lives on `FACILITY` (F1). `bill.tax_amount` is a
computed money figure, not a rate — `fn_bill_enforce_amounts` reads the rate
through the join at the moment the bill is raised.

**(b) Vehicle type name on the session**

```
session_id → vehicle_id → vehicle_type_id → vehicle_type_name
```

*Resolved:* `VEHICLE_TYPE` is a lookup table (F15). Sessions carry
`vehicle_type_id`; the human-readable name is joined, never copied.

**(c) Customer details on the reservation**

```
reservation_id → customer_id → full_name, phone, email
```

*Resolved:* `RESERVATION` stores `customer_id` only (F23).

**(d) Tariff rates on the bill**

```
bill_id → tariff_id → first_hour_rate, subsequent_hour_rate, daily_cap
```

*Resolved:* `bill` stores `tariff_id`, so the rates that produced the figure
remain readable without being copied. `fk_bill_tariff` is `ON DELETE RESTRICT`
precisely so that reference can never dangle — an old bill must always be
explainable.

**After 3NF:** every non-key attribute depends on the key, the whole key, and
nothing but the key. All sixteen tables satisfy 3NF.

---

## 4. Three attributes deliberately not stored

These are not oversights. Each would be a stored copy of something already
determined by other data (D3–D5), which is the same redundancy 3NF exists to
remove — it simply shows up as a *derived* attribute rather than a transitive
one.

### `slot.status`

An occupancy flag on `slot` duplicates what `parking_session` already says. It
creates a two-place update on every gate event with no constraint forcing the
two to agree: crash between the session insert and the flag update and the bay
is occupied and free simultaneously.

*Instead:* `v_current_occupancy` derives state from open sessions and live
holds. `fn_gate_exit` frees a bay by stamping `exit_time` — nothing has to
remember to flip a flag, which is why nothing can forget.

### `parking_session.status`

`exit_time IS NULL` **is** the status. A separate column permits the
contradictory row `status='active', exit_time='2026-09-13'`. Removing it also
lets business rule 1 be stated directly as a partial unique index:

```sql
CREATE UNIQUE INDEX uq_active_session_slot
    ON parking_session (slot_id) WHERE exit_time IS NULL;
```

With a status column that index would have to read
`WHERE status = 'active'` — trusting the very column that can be wrong.

### `parking_pass.status`

Derivable from `valid_from`, `valid_to` and `cancelled_at` against `now()`. A
stored copy is stale the moment a pass expires and needs a scheduled job to
correct it. `cancelled_at` *is* stored, because cancellation is an event that
cannot be inferred from the dates.

---

## 5. Three denormalisations, and why they are not breaches

### `parking_session.vehicle_type_id`

Derivable from `vehicle_id`, so at first glance a transitive dependency.

It is carried anyway because it is the join column that makes business rule 2
structural. `parking_session` holds composite foreign keys to
`slot (slot_id, vehicle_type_id)` **and** `vehicle (vehicle_id, vehicle_type_id)`
simultaneously. Both must resolve, so the column is pinned to the slot's type
and the vehicle's type at once — it cannot hold a third value, and it cannot
drift.

The usual objection to a derived column is that it can disagree with its source.
Here disagreement is rejected by the constraint system, so the objection does
not apply. The alternative — a trigger comparing two types — is weaker: triggers
can be disabled, and `ALTER TABLE ... DISABLE TRIGGER` is one statement.

### `reservation.vehicle_type_id`

The same device, applied at booking time (migration 013). `reservation` carries
`vehicle_type_id` with composite foreign keys to `slot (slot_id, vehicle_type_id)`
and `vehicle (vehicle_id, vehicle_type_id)`, so a car cannot even be *booked*
into a bike bay. The column is filled by `trg_reservation_prepare` from the
vehicle, and both keys pin it, so it cannot disagree with either source.

### `parking_pass.price_paid`

`pass_type.price` is today's shelf price. `price_paid` is what this customer was
actually charged. When the shelf price changes, the two **must** diverge, so
this is not a copy of the same fact — it is a different fact that happens to
share a value on the day of sale. Copying it is what makes historical pass
revenue reproducible.

---

## 6. Result

| Table | 1NF | 2NF | 3NF | Note |
|---|:--:|:--:|:--:|---|
| `facility` | ✓ | ✓ | ✓ | |
| `floor` | ✓ | ✓ | ✓ | UNIQUE(facility_id, level_number) |
| `zone` | ✓ | ✓ | ✓ | UNIQUE(floor_id, code) |
| `slot` | ✓ | ✓ | ✓ | no status column, by design (§4) |
| `vehicle_type` | ✓ | ✓ | ✓ | lookup, resolves 3NF(b) |
| `app_user` | ✓ | ✓ | ✓ | |
| `customer` | ✓ | ✓ | ✓ | |
| `vehicle` | ✓ | ✓ | ✓ | |
| `tariff` | ✓ | ✓ | ✓ | temporal, resolves the 1NF time-series |
| `pass_type` | ✓ | ✓ | ✓ | |
| `parking_pass` | ✓ | ✓ | ✓ | `price_paid` is a distinct fact (§5) |
| `reservation` | ✓ | ✓ | ✓ | `vehicle_type_id` constrained, not copied (§5) |
| `parking_session` | ✓ | ✓ | ✓ | `vehicle_type_id` constrained, not copied (§5) |
| `bill` | ✓ | ✓ | ✓ | `total_amount` GENERATED, not stored twice |
| `payment` | ✓ | ✓ | ✓ | resolves the 1NF repeating group |
| `violation` | ✓ | ✓ | ✓ | |
| `audit_log` | ✓ | ✓ | ✓ | `changes` is JSONB, treated as one opaque value: a snapshot, never queried by key in normal operation |

**BCNF.** Every table is also in Boyce–Codd Normal Form: in each, the only
determinants of a non-trivial FD are candidate keys. No table has two
overlapping composite candidate keys, which is the usual source of a 3NF table
that fails BCNF.

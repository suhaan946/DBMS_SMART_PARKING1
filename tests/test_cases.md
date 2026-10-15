# Testing

Smart Parking Lot Allocation & Billing System — DBMS PBL Project 20.

Every result below is captured output from a real run, not a description
of what the code is expected to do. Regenerate the whole document with:

```bash
./.venv/bin/python tests/gen_testing_doc.py
```

| Suite | What it proves | Result |
|---|---|---|
| Constraint tests | Each business rule rejects its violation | **24 of 25 attempts refused by the database**; 1 accepted and silently corrected (TEST 8's point) |
| Lifecycle tests | Expiry, overstay, passes, derived billing | **11 of 11 pass** |
| RLS tests | Policies restrict rows, and fail closed | **Pass** |
| End-to-end smoke | Sign-in → reserve → entry → exit → bill → payment → reports | **40 checks, 0 failures** |
| API tests (pytest) | CRUD, ownership, servicing, payments, scoping | **18 passed, 0 failed** |
| Browser: every page | Console errors and failed requests, 1440×900 | **No errors on any page** |
| Browser: components | Keyboard, dialogs, tabs, reduced motion | **17 of 17 pass** |
| Browser: contrast | Text below WCAG AA on all 10 pages | **0 elements** |

---

## 1. Constraint tests — trying to break each business rule

```bash
psql -d smartpark -f db/tests/constraint_tests.sql
```

Each block deliberately violates one rule inside its own transaction,
which is then rolled back. The error text is exactly what PostgreSQL
returned. A constraint that has never been tested to failure is one you
cannot defend in a viva.

### TEST 1 — BUSINESS RULE 1 - one active vehicle per slot

**Attempt.** open a second session on a slot that is already occupied.

**Expected.** unique violation on uq_active_session_slot

**PostgreSQL returned:**

```
ERROR:  duplicate key value violates unique constraint "uq_active_session_slot"
DETAIL:  Key (slot_id)=(39) already exists.
```

**Result: REFUSED by the database.**

### TEST 2 — BUSINESS RULE 1 (mirror) - one active slot per vehicle

**Attempt.** park an already-parked vehicle in a second free bay.

**Expected.** unique violation on uq_active_session_vehicle

**PostgreSQL returned:**

```
ERROR:  duplicate key value violates unique constraint "uq_active_session_vehicle"
DETAIL:  Key (vehicle_id)=(33) already exists.
```

**Result: REFUSED by the database.**

### TEST 3 — BUSINESS RULE 2 - slot / vehicle-type match

**Attempt.** put a CAR into a BIKE bay.

**Expected.** foreign key violation on fk_session_slot_type_match (the composite key (slot_id, CAR) does not exist in slot)

**PostgreSQL returned:**

```
ERROR:  insert or update on table "parking_session" violates foreign key constraint "fk_session_slot_type_match"
DETAIL:  Key (slot_id, vehicle_type_id)=(1, 2) is not present in table "slot".
```

**Result: REFUSED by the database.**

### TEST 3b — BUSINESS RULE 2 - lying about the vehicle type

**Attempt.** claim a CAR is a BIKE so the slot type appears to match.

**Expected.** foreign key violation on fk_session_vehicle_type_match (the composite key (vehicle_id, BIKE) does not exist in vehicle)

**PostgreSQL returned:**

```
ERROR:  insert or update on table "parking_session" violates foreign key constraint "fk_session_vehicle_type_match"
DETAIL:  Key (vehicle_id, vehicle_type_id)=(1, 1) is not present in table "vehicle".
```

**Result: REFUSED by the database.**

### TEST 4 — BUSINESS RULE 3 - exit after entry

**Attempt.** stamp an exit one hour BEFORE the entry.

**Expected.** check violation on ck_session_exit_after_entry

**PostgreSQL returned:**

```
ERROR:  new row for relation "parking_session" violates check constraint "ck_session_exit_after_entry"
DETAIL:  Failing row contains (1583, TK-6137CF29, 39, 33, 2, 2026-10-05 14:23:29.480893+05:30, 2026-10-05 13:23:29.480893+05:30, null, null, 3, null).
```

**Result: REFUSED by the database.**

### TEST 5 — BUSINESS RULE 4 - reservation window must be forward

**Attempt.** reserve until BEFORE the reservation starts.

**Expected.** check violation on ck_reservation_window

**PostgreSQL returned:**

```
ERROR:  new row for relation "reservation" violates check constraint "ck_reservation_window"
DETAIL:  Failing row contains (49, 1, 2, 1, 2026-10-05 23:47:06.534391+05:30, 2026-10-05 21:47:06.534391+05:30, held, 2026-10-05 19:47:06.534391+05:30, 1).
```

**Result: REFUSED by the database.**

### TEST 6 — BUSINESS RULE 4 - two live holds may not overlap

**Attempt.** book a slot for a window that overlaps a live hold.

**Expected.** exclusion violation on ex_reservation_no_overlap

**PostgreSQL returned:**

```
ERROR:  conflicting key value violates exclusion constraint "ex_reservation_no_overlap"
DETAIL:  Key (slot_id, tstzrange(reserved_from, reserved_until))=(2, ["2026-10-05 21:36:29.480893+05:30","2026-10-05 23:36:29.480893+05:30")) conflicts with existing key (slot_id, tstzrange(reserved_from, reserved_until))=(2, ["2026-10-05 21:06:29.480893+05:30","2026-10-05 23:06:29.480893+05:30")).
```

**Result: REFUSED by the database.**

### TEST 7 — BUSINESS RULE 5 - a bill amount may not be negative

**Attempt.** write a bill with a negative base amount.

**Expected.** check violation on ck_bill_base_non_negative (forced past the amount-enforcing trigger with a direct UPDATE)

**PostgreSQL returned:**

```
ERROR:  new row for relation "bill" violates check constraint "ck_bill_base_non_negative"
DETAIL:  Failing row contains (1583, 1585, 3, 413, -500.00, 34.20, -465.80, unpaid, 2026-10-05 16:07:20.995433+05:30).
```

**Result: REFUSED by the database.**

### TEST 8 — BUSINESS RULE 5 - a client cannot dictate the charge

**Attempt.** insert a bill claiming the parking cost 1 rupee.

**Expected.** NO error. The row is accepted but trg_bill_enforce_amounts silently replaces the amount with fn_calculate_charge output. The printed comparison is the proof.

**PostgreSQL returned:**

```
     source      | base  |  tax  | total
 client claimed  |  1.00 |  0.00 |  1.00
 database stored | 80.00 | 14.40 | 94.40
```

**Result: accepted, then silently corrected by the trigger — which is exactly what this test exists to show.**

### TEST 9 — Referential integrity - a session needs a real slot

**Attempt.** reference a slot_id that does not exist.

**Expected.** foreign key violation

**PostgreSQL returned:**

```
ERROR:  insert or update on table "parking_session" violates foreign key constraint "fk_session_slot_type_match"
DETAIL:  Key (slot_id, vehicle_type_id)=(999999, 2) is not present in table "slot".
```

**Result: REFUSED by the database.**

### TEST 10 — Input validation - plate number format

**Attempt.** register a vehicle with the plate "HELLO".

**Expected.** check violation on ck_vehicle_plate_shape

**PostgreSQL returned:**

```
ERROR:  new row for relation "vehicle" violates check constraint "ck_vehicle_plate_shape"
DETAIL:  Failing row contains (61, 1, HELLO, 1, null, null, null, 2026-10-05 19:47:06.548158+05:30).
```

**Result: REFUSED by the database.**

### TEST 11 — Input validation - duplicate plate number

**Attempt.** register a plate that already exists.

**Expected.** unique violation on vehicle_plate_number_key

**PostgreSQL returned:**

```
ERROR:  duplicate key value violates unique constraint "vehicle_plate_number_key"
DETAIL:  Key (plate_number)=(TS09AB1234) already exists.
```

**Result: REFUSED by the database.**

### TEST 12 — Payment integrity - a payment must be positive

**Attempt.** record a payment of zero.

**Expected.** check violation on ck_payment_amount_positive

**PostgreSQL returned:**

```
ERROR:  new row for relation "payment" violates check constraint "ck_payment_amount_positive"
DETAIL:  Failing row contains (1383, 1583, 0.00, cash, null, 2026-10-05 19:47:06.548723+05:30, null).
```

**Result: REFUSED by the database.**

### TEST 13 — Tariff integrity - overlapping price lists

**Attempt.** open a second tariff for a facility/type already priced.

**Expected.** exclusion violation on ex_tariff_no_overlap

**PostgreSQL returned:**

```
ERROR:  conflicting key value violates exclusion constraint "ex_tariff_no_overlap"
DETAIL:  Key (facility_id, vehicle_type_id, tstzrange(effective_from, effective_to))=(1, 1, ["2026-10-05 19:47:06.549143+05:30",)) conflicts with existing key (facility_id, vehicle_type_id, tstzrange(effective_from, effective_to))=(1, 1, ["2026-07-07 16:06:29.457995+05:30",)).
```

**Result: REFUSED by the database.**

### TEST 14 — Operator scoping - an operator must have a facility

**Attempt.** create an operator with no facility_id.

**Expected.** check violation on ck_app_user_operator_has_facility

**PostgreSQL returned:**

```
ERROR:  new row for relation "app_user" violates check constraint "ck_app_user_operator_has_facility"
DETAIL:  Failing row contains (11, rogue.operator@smartpark.in, x, Rogue Operator, operator, null, t, 2026-10-05 19:47:06.549456+05:30).
```

**Result: REFUSED by the database.**

### TEST 15 — Pass integrity - two live passes on one vehicle

**Attempt.** sell a second overlapping pass for the same vehicle/facility.

**Expected.** exclusion violation on ex_pass_no_overlap

**PostgreSQL returned:**

```
ERROR:  conflicting key value violates exclusion constraint "ex_pass_no_overlap"
DETAIL:  Key (vehicle_id, facility_id, tstzrange(valid_from, valid_to))=(2, 1, ["2026-10-01 00:00:00+05:30","2026-10-31 00:00:00+05:30")) conflicts with existing key (vehicle_id, facility_id, tstzrange(valid_from, valid_to))=(2, 1, ["2026-09-30 00:00:00+05:30","2026-10-30 00:00:00+05:30")).
```

**Result: REFUSED by the database.**

### TEST 16 — Ownership - a booking must use the customer's own vehicle

**Attempt.** reserve for customer A using customer B's car.

**Expected.** foreign key violation on fk_reservation_vehicle_owner

**PostgreSQL returned:**

```
ERROR:  insert or update on table "reservation" violates foreign key constraint "fk_reservation_vehicle_owner"
DETAIL:  Key (vehicle_id, customer_id)=(2, 5) is not present in table "vehicle".
```

**Result: REFUSED by the database.**

### TEST 17 — Ownership - a pass must cover the customer's own vehicle

**Attempt.** sell customer A a pass on customer B's car.

**Expected.** foreign key violation on fk_pass_vehicle_owner

**PostgreSQL returned:**

```
ERROR:  insert or update on table "parking_pass" violates foreign key constraint "fk_pass_vehicle_owner"
DETAIL:  Key (vehicle_id, customer_id)=(2, 5) is not present in table "vehicle".
```

**Result: REFUSED by the database.**

### TEST 18 — BUSINESS RULE 2 at booking time - bay / vehicle type

**Attempt.** reserve a bay built for a different vehicle type.

**Expected.** foreign key violation on fk_reservation_slot_type_match

**PostgreSQL returned:**

```
ERROR:  insert or update on table "reservation" violates foreign key constraint "fk_reservation_slot_type_match"
DETAIL:  Key (slot_id, vehicle_type_id)=(1, 2) is not present in table "slot".
```

**Result: REFUSED by the database.**

### TEST 19 — Bay servicing - an out-of-service bay cannot be booked

**Attempt.** take a free bay out of service, then reserve it.

**Expected.** check violation raised by trg_reservation_prepare

**PostgreSQL returned:**

```
ERROR:  That bay is out of service and cannot be reserved.
```

**Result: REFUSED by the database.**

### TEST 20 — Bay servicing - an occupied bay cannot be taken out

**Attempt.** as admin, take a bay with a parked car out of service.

**Expected.** "Bay ... has a vehicle in it" from fn_set_slot_service

**PostgreSQL returned:**

```
ERROR:  Bay G-B-05 has a vehicle in it. Record its exit first.
```

**Result: REFUSED by the database.**

### TEST 21 — Bay servicing - a note only describes an idle bay

**Attempt.** attach a service note to a bay that is in service.

**Expected.** check violation on ck_slot_note_only_when_out

**PostgreSQL returned:**

```
ERROR:  new row for relation "slot" violates check constraint "ck_slot_note_only_when_out"
DETAIL:  Failing row contains (1, 1, B-A-01, 1, t, 1, 1, 2026-10-05 16:06:29.457995+05:30, Paint is fresh).
```

**Result: REFUSED by the database.**

### TEST 22 — Operator scoping - bays at another facility

**Attempt.** operator posted to facility 1 services a facility 2 bay.

**Expected.** "You can only manage bays at your own facility."

**PostgreSQL returned:**

```
ERROR:  You can only manage bays at your own facility.
```

**Result: REFUSED by the database.**

### TEST 23 — Audit trail - the history cannot be erased

**Attempt.** as admin, delete rows from audit_log.

**Expected.** permission denied for table audit_log

**PostgreSQL returned:**

```
ERROR:  permission denied for table audit_log
```

**Result: REFUSED by the database.**

### TEST 24 — Payment integrity - no paying past the balance

**Attempt.** pay one rupee more than an unpaid bill's total.

**Expected.** "That is more than the ₹... still owed on this bill."

**PostgreSQL returned:**

```
ERROR:  That is more than the ₹224.20 still owed on this bill.
```

**Result: REFUSED by the database.**

---

## 2. Row-level security — proving the policies restrict

```bash
psql -d smartpark -f db/tests/rls_tests.sql
```

PostgreSQL exempts a table's owner from its own RLS policies unless
`FORCE ROW LEVEL SECURITY` is set, so the API never queries as the owner.
It issues `SET LOCAL app.current_user_id` and `SET LOCAL ROLE` per
request, and these tests do the same — they exercise the policies exactly
as real traffic does.

### Visibility by role

| Acting as | Customers | Vehicles | Bills | Sessions |
|---|--:|--:|--:|--:|
| Table owner (RLS bypassed by ownership) | 33 | 48 | 1592 | — |
| Customer 1 — Rahul Sharma | 1 | 3 | 111 | 112 |
| **No identity set** | **0** | **0** | **0** | — |

The last row is the important one. With `app.current_user_id` unset,
`fn_current_user_id()` returns NULL, every policy evaluates false, and the
caller sees nothing. The system fails **closed**.

### Two customers see disjoint data

| Rahul Sharma (user 5) sees | Priya Nair (user 6) sees |
|---|---|
| `TS09AB1234` | `TS10CD5678` |
| `TS09EF4444` | `TS11GH5555` |
| `TS09XY7788` |  |

Plates in common: **0**. Rahul querying
`customer_id = 2` directly returns 0 rows — the row is invisible
rather than forbidden, which is correct: an error would itself
disclose that the row exists.

### Writes are restricted too

| Attempt | Result |
|---|---|
| Customer writes a vehicle onto another customer | `ERROR:  new row violates row-level security policy for table "vehicle"` |
| Customer records a payment against their own bill | `ERROR:  permission denied for table payment` |

### Operators are scoped to their own facility

```
Rohit  (operator, facility 1):
           1 |                 1237
Imran  (operator, facility 2):
           2 |                  371
```

Each operator's query returns rows for their own site only — the grouping
proves it, since a leak would show a second facility_id.

### Views honour RLS (`security_invoker = true`)

| Query | As customer 1 | As admin |
|---|--:|--:|
| `SELECT count(*) FROM v_session_duration` | 112 | 1608 |
| `SELECT count(*) FROM v_violations` | 4 | 39 |

Without `security_invoker = true` a view executes as its owner and both
columns above would read the same. That is the classic way an RLS policy
is bypassed by the convenience layer built on top of it.

---

## 3. End-to-end smoke test

```bash
./.venv/bin/python tests/e2e_smoke.py
```

Drives the running API over HTTP: sign in, search a bay, register a
customer and vehicle, reserve, gate entry onto both an allocated and a
reserved bay, gate exit, bill, payment, every report, and the
authorisation boundaries. Safe to run repeatedly.

```
========================================================================
END-TO-END SMOKE TEST
========================================================================
1. Sign in
  [PASS] operator signs in  -> role=operator
  [PASS] customer signs in  -> customer
  [PASS] wrong password rejected  -> Email or password is incorrect.
  [PASS] no token rejected  -> Sign in to continue.
2. Search a free slot
  [PASS] free-slot search returns rows  -> 47 free car bays
3. Register a customer and vehicle
  [PASS] create customer  -> {'customer_id': 37, 'full_name': 'E2E Test Driver', 'phone': '9194709999', 'email': None}
  [PASS] create vehicle  -> {'vehicle_id': 65, 'plate_number': 'TS01ZZ4709'}
4. Validation is enforced
  [PASS] bad plate rejected  -> That does not look like a valid registration number. Use the format TS09AB1234.
  [PASS] duplicate plate rejected  -> A vehicle with that registration number is already on file.
5. Reserve a slot
  [PASS] create reservation  -> {'reservation_id': 55, 'status': 'held'}
  [PASS] overlapping reservation rejected  -> That slot is already reserved for an overlapping period. Pick another slot or time.
6. Gate entry
  [PASS] gate entry allocates a slot  -> ticket TK-D0235EC8 -> slot B-A-04
  [PASS] double entry rejected  -> That change conflicts with records already on file.
  [PASS] unknown plate rejected  -> No vehicle is registered with plate XX99XX9999
6b. Arrival onto a RESERVED bay
  [PASS] arrival honours the reservation  -> skipped: no live hold whose vehicle is currently away
7. Look up the open session
  [PASS] lookup finds the session  -> running charge Rs 0.0
8. Gate exit raises a bill
  [PASS] gate exit succeeds  -> bill 1605 total Rs 0.0
  [PASS] bill total = base + tax  -> 0.0 + 0.0 = 0.0
  [PASS] second exit rejected  -> No open parking session found for "TK-D0235EC8"
8b. A chargeable exit (a vehicle parked for hours, not minutes)
  [PASS] found a chargeable open session  -> KA51YZ2233
  [PASS] long session has a running charge  -> 381 min -> Rs 190.0
  [PASS] chargeable exit bills a real amount  -> base Rs 190.0 + tax Rs 34.2 = Rs 224.2
  [PASS] quoted charge matches the bill  -> quoted 190.0 vs billed 190.0
  [PASS] half payment marks the bill partly_paid  -> partly_paid
9. Record a payment
  [PASS] bill detail loads  -> status partly_paid
  [PASS] balance payment recorded  -> Rs 112.1, bill now paid
  [PASS] bill marked paid by trigger  -> paid
  [PASS] payment beyond the balance rejected  -> That is more than the ₹0.00 still owed on this bill.
  [PASS] negative payment rejected  -> rejected
10. Every report renders with real data
  [PASS] report: occupancy  -> 12 rows
  [PASS] report: peak hours  -> 18 rows
  [PASS] report: revenue  -> 36 rows
  [PASS] report: duration  -> 5 rows
  [PASS] report: pass usage  -> 27 rows
  [PASS] report: violations  -> 44 rows
  [PASS] report: free slots  -> 32 rows
11. Authorisation holds through the API
  [PASS] customer cannot work the gate  -> This action is restricted to staff.
  [PASS] customer cannot record payments  -> This action is restricted to staff.
  [PASS] customer sees fewer vehicles than admin  -> 3 vs 49
  [PASS] operator cannot change tariffs  -> This action is restricted to administrators.
========================================================================
ALL END-TO-END CHECKS PASSED
========================================================================
```

---

## 3b. Lifecycle tests — rules that depend on time

```bash
psql -d smartpark -f db/tests/lifecycle_tests.sql
```

A lapsed hold, a stay over 24 hours, a live pass and an expired pass,
driven through the real gate functions inside one transaction that is
rolled back.

| Test | Result | What the database did |
|---|---|---|
| 1. A lapsed reservation expires and is logged as a no-show | **PASS** | reservation status is expired |
| ″ | **PASS** | 1 no-show violation logged |
| ″ | **PASS** | running the sweep again changes nothing |
| 2. A stay over 24 hours is billed and logged as an overstay | **PASS** | 1800 minutes billed at Rs 489.70 |
| ″ | **PASS** | 1 overstay violation, penalty Rs 200.00 |
| ″ | **PASS** | the bay is released (session closed) |
| 3. A live pass makes the stay free and the bill settles itself | **PASS** | entry attached pass 36 |
| ″ | **PASS** | 3-hour stay billed Rs 0.00, status paid |
| 4. An expired pass no longer covers the stay | **PASS** | pass attached at entry: none |
| ″ | **PASS** | same 3-hour stay now billed Rs 106.20, status unpaid |
| 5. Billing is derived from the tariff, not typed in | **PASS** | base Rs 90.00 = fn_calculate_charge, tax Rs 16.20, total Rs 106.20 |

---

## 3c. API tests (pytest)

```bash
SMARTPARK_DATABASE_URL=postgresql:///smartpark_test ./.venv/bin/pytest -q
```

Run in-process against a separate `smartpark_test` database built from
the same migrations.

| Test | Result |
|---|---|
| `test_health_needs_no_sign_in` | PASSED |
| `test_errors_are_plain_english` | PASSED |
| `test_customer_lifecycle` | PASSED |
| `test_customer_with_vehicles_cannot_be_deleted` | PASSED |
| `test_vehicle_edit_respects_ownership` | PASSED |
| `test_vehicle_with_history_reports_the_real_reason` | PASSED |
| `test_reservation_rejects_someone_elses_vehicle` | PASSED |
| `test_reservation_rejects_wrong_bay_type` | PASSED |
| `test_customer_can_list_reservations` | PASSED |
| `test_bay_service_round_trip` | PASSED |
| `test_bay_service_refusals` | PASSED |
| `test_payment_cannot_exceed_the_balance` | PASSED |
| `test_a_free_stay_is_settled_not_unpaid` | PASSED |
| `test_payments_are_scoped_to_the_operators_facility` | PASSED |
| `test_activity_feed_is_newest_first_and_private` | PASSED |
| `test_audit_is_admin_only` | PASSED |
| `test_vehicle_history_report` | PASSED |
| `test_dashboard_figures_are_scoped` | PASSED |

---

## 4. Validation and error handling

Client-side validation exists for responsiveness; the database is the real
gate. The message a user sees is the mapped constraint message from
`api/errors.py`, keyed on the PostgreSQL constraint name.

| Where | Bad input | Caught by | Message shown to the user |
|---|---|---|---|
| Gate — arrival | `HELLO` as a registration | `ck_vehicle_plate_shape` | That does not look like a valid registration number. Use the format TS09AB1234. |
| Gate — arrival | A plate not on file | `fn_gate_entry` RAISE, SQLSTATE `no_data_found` | No vehicle is registered with plate XX99XX9999 |
| Gate — arrival | A vehicle already inside | `uq_active_session_vehicle` | Vehicle TS09AB1234 is already parked and has not exited |
| Gate — arrival | Facility full for that type | `fn_allocate_slot` returns NULL → RAISE | No free slot available for this vehicle type at facility 1 |
| Gate — arrival | Operator posted to another site | `fn_gate_entry` facility guard | You are posted to facility 2, not facility 1 |
| Gate — departure | Ticket with no open session | `fn_gate_exit` RAISE | No open parking session found for "TK-XXXXXXXX" |
| Reservations | End time before start | `ck_reservation_window` | The reservation must end after it starts. |
| Reservations | Bay already held for that window | `ex_reservation_no_overlap` | That slot is already reserved for an overlapping period. Pick another slot or time. |
| Passes | Second live pass, same vehicle and site | `ex_pass_no_overlap` | This vehicle already holds a pass covering those dates at this facility. |
| Billing | Payment of zero or less | `ck_payment_amount_positive` | A payment must be greater than zero. |
| Billing | Payment exceeding the balance | `trg_payment_within_balance` | That is more than the ₹236.00 still owed on this bill. |
| Customers | Phone that is not ten digits | `ck_customer_phone_shape` | Enter a 10 digit phone number with no spaces or country code. |
| Customers | Registration already on file | `vehicle_plate_number_key` | A vehicle with that registration number is already on file. |
| Customers | Removing a vehicle with history | `ON DELETE RESTRICT` | The database's own message, surfaced verbatim |
| Settings | Daily cap below the first-hour rate | `ck_tariff_cap_sane` | The daily cap cannot be lower than the first hour rate. |
| Settings | Second tariff for a priced facility/type | `ex_tariff_no_overlap` | A tariff is already in force for this facility and vehicle type. |
| Sign in | Wrong password | bcrypt verify fails | Email or password is incorrect. |
| Sign in | Unknown email | same message, deliberately | Email or password is incorrect. *(identical, so responses cannot be used to enumerate accounts)* |
| Any screen | Expired or missing token | `api/auth.py` | Your session has expired. Sign in again. *(and a redirect to sign-in)* |
| Any screen | API not running | fetch throws | Cannot reach the server. Check that the API is running. |

---

## 5. Interface checks (Chrome via Playwright, 1440×900)

### Every page loads cleanly

```bash
./.venv/bin/python tests/page_smoke.py
```

```
  index.html             ok        errors:0 http4xx5xx:0 errorPanels:0 textLen:6683
  dashboard.html         ok        errors:0 http4xx5xx:0 errorPanels:0 textLen:6683
  slots.html             ok        errors:0 http4xx5xx:0 errorPanels:0 textLen:5125
  gate.html              ok        errors:0 http4xx5xx:0 errorPanels:0 textLen:2044
  reservations.html      ok        errors:0 http4xx5xx:0 errorPanels:0 textLen:2370
  passes.html            ok        errors:0 http4xx5xx:0 errorPanels:0 textLen:3278
  billing.html           ok        errors:0 http4xx5xx:0 errorPanels:0 textLen:2596
  reports.html           ok        errors:0 http4xx5xx:0 errorPanels:0 textLen:1516
  customers.html         ok        errors:0 http4xx5xx:0 errorPanels:0 textLen:1660
  settings.html          ok        errors:0 http4xx5xx:0 errorPanels:0 textLen:2999
FAILING PAGES: none
```

### Components: keyboard, dialogs, tabs, reduced motion

```bash
./.venv/bin/python tests/a11y_components.py
```

```
Skip link and landmarks
  [PASS] first Tab lands on the skip link  -> Skip to content
  [PASS] skip link moves focus to main
  [PASS] breadcrumb is a labelled nav
Data table
  [PASS] header sorts by keyboard and reports aria-sort  -> ascending -> descending
  [PASS] table exposes ARIA roles
  [PASS] '/' focuses the page search
  [PASS] no-match state is announced via the live count
Actions menu
  [PASS] Enter opens the menu with focus on the first item  -> {'menu': True, 'expanded': True, 'focus': 'menuitem'}
  [PASS] ArrowDown moves between items  -> Edit details
  [PASS] Escape closes and returns focus to the trigger
Dialog
  [PASS] edit dialog is modal, labelled, and takes focus  -> {'modal': 'true', 'labelled': True, 'focusInside': True}
  [PASS] Tab stays trapped inside the dialog
  [PASS] Escape closes the dialog
Tabs
  [PASS] ArrowRight selects the next tab with a roving tabindex  -> {'focus': 'tab-ledger', 'selected': 'true', 'roving': '-10', 'panelShown': True}
Shortcuts
  [PASS] '?' opens the shortcut list
  [PASS] G then C navigates to Customers  -> http://127.0.0.1:8077/customers.html
Reduced motion
  [PASS] figures appear at their final value with no count-up  -> ['11%', '83', '22', '₹1,062', '₹23,703']
17/17 component checks passed
```

### Text contrast against WCAG AA

Every visible text element on every page, foreground against its
actual composited background.

```
  index.html           0 below AA
  dashboard.html       0 below AA
  slots.html           0 below AA
  gate.html            0 below AA
  reservations.html    0 below AA
  passes.html          0 below AA
  billing.html         0 below AA
  reports.html         0 below AA
  customers.html       0 below AA
  settings.html        0 below AA
TOTAL below AA: 0
```

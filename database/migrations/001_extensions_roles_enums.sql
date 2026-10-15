-- ============================================================================
-- 001_extensions_roles_enums.sql
-- Smart Parking Lot Allocation & Billing System
--
-- Purpose: enable the extensions the integrity rules depend on, create the
--          three application roles that row-level security is written against,
--          and declare the enumerated domains used by later tables.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- Idempotent DROP IF EXISTS guards below emit "does not exist, skipping"
-- notices on a first run. They are harmless, but they read like failures to
-- someone running this for the first time, so notices are quietened here.
-- Warnings and errors still come through.
SET client_min_messages = warning;


-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
-- btree_gist lets a GiST index mix a scalar equality operator (slot_id WITH =)
-- with a range overlap operator (tstzrange WITH &&) inside one EXCLUDE
-- constraint. Without it, the no-overlapping-reservations rule in migration 005
-- cannot be declared and would have to be enforced by an application query,
-- which two concurrent transactions can defeat.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- citext gives case-insensitive equality for email addresses, so
-- 'Sid@Example.com' and 'sid@example.com' cannot both be registered.
CREATE EXTENSION IF NOT EXISTS citext;


-- ---------------------------------------------------------------------------
-- Application roles
--
-- These are real PostgreSQL roles, not rows in a table. The RLS policies in
-- migration 009 are written against them, so the database enforces the
-- authorisation model even if a client connects with psql and bypasses the API.
-- NOLOGIN: the API connects as its own owner role and switches to one of these
-- with SET ROLE for the duration of a request.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'parking_admin') THEN
    CREATE ROLE parking_admin NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'parking_operator') THEN
    CREATE ROLE parking_operator NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'parking_customer') THEN
    CREATE ROLE parking_customer NOLOGIN;
  END IF;
END
$$;


-- ---------------------------------------------------------------------------
-- Enumerated domains
--
-- Modelled as native ENUM types rather than free-text columns so that an
-- invalid value is rejected by the type system at INSERT time. Each is created
-- conditionally so the migration can be replayed.
-- ---------------------------------------------------------------------------

-- Who a person is to the system. Drives every RLS policy.
DO $$ BEGIN
  CREATE TYPE user_role AS ENUM ('admin', 'operator', 'customer');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Lifecycle of a slot booking.
--   held      - created, not yet paid/confirmed, still blocks the slot
--   confirmed - customer committed, still blocks the slot
--   expired   - reserved_until passed with no vehicle arriving
--   cancelled - withdrawn by the customer or an operator
--   fulfilled - the vehicle arrived and a parking_session was opened
-- Only 'held' and 'confirmed' participate in the overlap exclusion constraint.
DO $$ BEGIN
  CREATE TYPE reservation_status AS ENUM
    ('held', 'confirmed', 'expired', 'cancelled', 'fulfilled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Lifecycle of a purchased parking pass.
DO $$ BEGIN
  CREATE TYPE pass_status AS ENUM ('active', 'expired', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Settlement state of a bill. 'partly_paid' exists because the payment table
-- allows several payments against one bill.
DO $$ BEGIN
  CREATE TYPE bill_status AS ENUM ('unpaid', 'partly_paid', 'paid', 'waived');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- How money was recorded. The system records payments; it does not process
-- them, and stores no card, CVV or UPI credential of any kind.
DO $$ BEGIN
  CREATE TYPE payment_method AS ENUM ('cash', 'card', 'upi', 'netbanking', 'pass', 'wallet');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- The violation categories the Review-2 violations report is built on.
DO $$ BEGIN
  CREATE TYPE violation_type AS ENUM
    ('overstay', 'wrong_slot_type', 'no_valid_pass', 'unpaid_exit', 'reservation_no_show');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

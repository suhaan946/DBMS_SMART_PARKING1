-- ============================================================================
-- 015_customer_email_shape.sql
--
-- app_user.email has had a shape check since migration 002; customer.email,
-- which is optional, had none. Same pattern, applied only when present.
-- Idempotent.
-- ============================================================================
ALTER TABLE customer DROP CONSTRAINT IF EXISTS ck_customer_email_shape;
ALTER TABLE customer
    ADD CONSTRAINT ck_customer_email_shape
    CHECK (email IS NULL OR email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

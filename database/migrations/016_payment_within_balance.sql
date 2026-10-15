-- ============================================================================
-- 016_payment_within_balance.sql
--
-- A payment may not take a bill past its total. Without this, a ₹0 bill (a
-- stay inside the free minutes) could be "paid" ₹1, and the receivable report
-- would show a negative balance that no one owes.
--
-- The rule spans rows (the sum of every payment against one bill), so it
-- cannot be a CHECK constraint. The trigger locks the bill row first, so two
-- payments arriving at once queue behind each other instead of both reading
-- the old balance and both passing.
-- Idempotent.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_payment_within_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_total  NUMERIC(10,2);
    v_status bill_status;
    v_paid   NUMERIC(10,2);
BEGIN
    SELECT b.total_amount, b.status INTO v_total, v_status
      FROM bill b WHERE b.bill_id = NEW.bill_id
       FOR UPDATE;

    IF v_status = 'waived' THEN
        RAISE EXCEPTION 'This bill was waived; nothing is owed on it.'
              USING ERRCODE = 'check_violation', CONSTRAINT = 'trg_payment_within_balance';
    END IF;

    SELECT COALESCE(SUM(p.amount), 0) INTO v_paid
      FROM payment p
     WHERE p.bill_id = NEW.bill_id
       AND (TG_OP = 'INSERT' OR p.payment_id <> NEW.payment_id);

    IF v_paid + NEW.amount > v_total THEN
        RAISE EXCEPTION 'That is more than the ₹% still owed on this bill.',
              to_char(GREATEST(v_total - v_paid, 0), 'FM9999990.00')
              USING ERRCODE = 'check_violation', CONSTRAINT = 'trg_payment_within_balance';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payment_within_balance ON payment;
CREATE TRIGGER trg_payment_within_balance
    BEFORE INSERT OR UPDATE OF amount, bill_id ON payment
    FOR EACH ROW EXECUTE FUNCTION fn_payment_within_balance();

COMMENT ON FUNCTION fn_payment_within_balance() IS
  'Refuses a payment that would take a bill past its total. Locks the bill row so concurrent payments serialise.';

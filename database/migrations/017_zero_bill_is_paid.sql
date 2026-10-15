-- ============================================================================
-- 017_zero_bill_is_paid.sql
--
-- A stay inside the free minutes produces a ₹0 bill. bill.status was only ever
-- recalculated when a payment arrived (trg_payment_sync_bill_status), and no
-- payment can arrive for ₹0 (016 refuses it), so such a bill stayed 'unpaid'
-- forever and inflated the unpaid count. The amount-enforcing trigger, which
-- already computes the total, now settles a zero bill as it is written.
-- Idempotent.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_bill_enforce_amounts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_tax_rate NUMERIC(5,2);
    v_entry    TIMESTAMPTZ;
    v_exit     TIMESTAMPTZ;
BEGIN
    NEW.base_amount := fn_calculate_charge(NEW.session_id);
    NEW.tariff_id   := COALESCE(fn_applicable_tariff(NEW.session_id), NEW.tariff_id);

    SELECT f.tax_rate_pct, ps.entry_time, ps.exit_time
      INTO v_tax_rate, v_entry, v_exit
      FROM parking_session ps
      JOIN slot     s  ON s.slot_id   = ps.slot_id
      JOIN zone     z  ON z.zone_id   = s.zone_id
      JOIN floor    fl ON fl.floor_id = z.floor_id
      JOIN facility f  ON f.facility_id = fl.facility_id
     WHERE ps.session_id = NEW.session_id;

    NEW.tax_amount := ROUND(NEW.base_amount * v_tax_rate / 100.0, 2);
    NEW.billable_minutes := GREATEST(
        0,
        FLOOR(EXTRACT(EPOCH FROM (COALESCE(v_exit, now()) - v_entry)) / 60.0)::INTEGER
    );

    -- Nothing owed means nothing outstanding.
    IF NEW.base_amount + NEW.tax_amount = 0 AND NEW.status = 'unpaid' THEN
        NEW.status := 'paid';
    END IF;
    RETURN NEW;
END;
$$;

-- Repair bills written before this rule existed.
UPDATE bill b
   SET status = 'paid'
 WHERE b.total_amount = 0
   AND b.status = 'unpaid'
   AND NOT EXISTS (SELECT 1 FROM payment p WHERE p.bill_id = b.bill_id);

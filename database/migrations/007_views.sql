-- ============================================================================
-- 007_views.sql
--
-- Purpose: one view per report named in the project statement — occupancy,
--          peak hours, duration, pass usage, violations, free slots, revenue.
--
-- Every view is created WITH (security_invoker = true). Without it a view runs
-- with the privileges of its owner, which silently bypasses the row-level
-- security policies in migration 009: a customer querying v_session_duration
-- would see everybody's sessions. With it, the policies are evaluated as the
-- querying role, so the view is a convenience, not a hole.
-- ============================================================================

-- Idempotent DROP IF EXISTS guards below emit "does not exist, skipping"
-- notices on a first run. They are harmless, but they read like failures to
-- someone running this for the first time, so notices are quietened here.
-- Warnings and errors still come through.
SET client_min_messages = warning;


-- ---------------------------------------------------------------------------
-- v_current_occupancy — live state of every slot in the building.
-- LEFT JOIN so that free slots appear too; an INNER JOIN here would show only
-- the occupied ones and make the floor map look empty at quiet times.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_current_occupancy
WITH (security_invoker = true) AS
SELECT
    f.facility_id,
    f.name              AS facility_name,
    fl.floor_id,
    fl.level_number,
    fl.name             AS floor_name,
    z.zone_id,
    z.code              AS zone_code,
    s.slot_id,
    s.code              AS slot_code,
    s.grid_row,
    s.grid_col,
    vt.vehicle_type_id,
    vt.code             AS vehicle_type_code,
    vt.name             AS vehicle_type_name,
    CASE
        WHEN NOT s.is_active            THEN 'out_of_service'
        WHEN ps.session_id IS NOT NULL  THEN 'occupied'
        WHEN r.reservation_id IS NOT NULL THEN 'reserved'
        ELSE 'free'
    END                 AS slot_state,
    ps.session_id,
    ps.ticket_no,
    ps.entry_time,
    v.plate_number,
    c.full_name         AS customer_name,
    -- Live running charge, using the same function the final bill uses.
    CASE WHEN ps.session_id IS NOT NULL
         THEN fn_calculate_charge(ps.session_id) END AS running_charge
FROM slot s
JOIN zone         z  ON z.zone_id   = s.zone_id
JOIN floor        fl ON fl.floor_id = z.floor_id
JOIN facility     f  ON f.facility_id = fl.facility_id
JOIN vehicle_type vt ON vt.vehicle_type_id = s.vehicle_type_id
LEFT JOIN parking_session ps
       ON ps.slot_id = s.slot_id AND ps.exit_time IS NULL
LEFT JOIN vehicle  v ON v.vehicle_id  = ps.vehicle_id
LEFT JOIN customer c ON c.customer_id = v.customer_id
LEFT JOIN reservation r
       ON r.slot_id = s.slot_id
      AND r.status IN ('held', 'confirmed')
      AND tstzrange(r.reserved_from, r.reserved_until) @> now();

COMMENT ON VIEW v_current_occupancy IS 'Live state of every slot. Drives the floor map. Occupancy is derived here, never stored.';


-- ---------------------------------------------------------------------------
-- v_free_slots — what an operator can allocate right now.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_free_slots
WITH (security_invoker = true) AS
SELECT facility_id, facility_name, floor_id, level_number, floor_name,
       zone_id, zone_code, slot_id, slot_code,
       vehicle_type_id, vehicle_type_code, vehicle_type_name
FROM v_current_occupancy
WHERE slot_state = 'free';

COMMENT ON VIEW v_free_slots IS 'Report: free slots. Subset of v_current_occupancy.';


-- ---------------------------------------------------------------------------
-- v_peak_hours — arrivals by hour of day, with a busiest-hour flag.
-- GROUP BY with a window function over the aggregate, so the report can say
-- "this is the peak" without a second query.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_peak_hours
WITH (security_invoker = true) AS
SELECT
    fl.facility_id,
    EXTRACT(HOUR FROM ps.entry_time)::INTEGER AS hour_of_day,
    COUNT(*)                                  AS entries,
    COUNT(*) FILTER (WHERE ps.exit_time IS NULL) AS still_parked,
    ROUND(AVG(EXTRACT(EPOCH FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0), 1)
                                              AS avg_stay_minutes,
    RANK() OVER (PARTITION BY fl.facility_id ORDER BY COUNT(*) DESC) AS busyness_rank
FROM parking_session ps
JOIN slot  s  ON s.slot_id  = ps.slot_id
JOIN zone  z  ON z.zone_id  = s.zone_id
JOIN floor fl ON fl.floor_id = z.floor_id
GROUP BY fl.facility_id, EXTRACT(HOUR FROM ps.entry_time);

COMMENT ON VIEW v_peak_hours IS 'Report: peak hours. GROUP BY hour with a RANK() window over the aggregate.';


-- ---------------------------------------------------------------------------
-- v_session_duration — how long vehicles stay, bucketed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_session_duration
WITH (security_invoker = true) AS
SELECT
    ps.session_id,
    ps.ticket_no,
    fl.facility_id,
    v.plate_number,
    c.customer_id,
    c.full_name AS customer_name,
    vt.name     AS vehicle_type_name,
    s.code      AS slot_code,
    ps.entry_time,
    ps.exit_time,
    (ps.exit_time IS NULL) AS is_active,
    ROUND(EXTRACT(EPOCH FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0)::INTEGER
        AS duration_minutes,
    CASE
        WHEN EXTRACT(EPOCH FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0 <  30   THEN 'under_30m'
        WHEN EXTRACT(EPOCH FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0 <  120  THEN '30m_2h'
        WHEN EXTRACT(EPOCH FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0 <  480  THEN '2h_8h'
        WHEN EXTRACT(EPOCH FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0 < 1440  THEN '8h_24h'
        ELSE 'over_24h'
    END AS duration_bucket,
    b.total_amount
FROM parking_session ps
JOIN slot         s  ON s.slot_id  = ps.slot_id
JOIN zone         z  ON z.zone_id  = s.zone_id
JOIN floor        fl ON fl.floor_id = z.floor_id
JOIN vehicle      v  ON v.vehicle_id = ps.vehicle_id
JOIN vehicle_type vt ON vt.vehicle_type_id = ps.vehicle_type_id
JOIN customer     c  ON c.customer_id = v.customer_id
LEFT JOIN bill    b  ON b.session_id = ps.session_id;

COMMENT ON VIEW v_session_duration IS 'Report: session duration with CASE bucketing and a LEFT JOIN to bill.';


-- ---------------------------------------------------------------------------
-- v_pass_usage — did the pass pay for itself?
-- Correlated aggregate per pass: how many sessions used it and what those
-- stays would have cost at tariff.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_pass_usage
WITH (security_invoker = true) AS
SELECT
    pp.pass_id,
    pp.facility_id,
    c.customer_id,
    c.full_name    AS customer_name,
    v.plate_number,
    pt.name        AS pass_type_name,
    pt.duration_days,
    pp.valid_from,
    pp.valid_to,
    pp.price_paid,
    CASE
        WHEN pp.cancelled_at IS NOT NULL       THEN 'cancelled'
        WHEN now() >= pp.valid_to              THEN 'expired'
        WHEN now() <  pp.valid_from            THEN 'scheduled'
        ELSE 'active'
    END AS pass_state,
    COALESCE(u.sessions_used, 0)      AS sessions_used,
    COALESCE(u.minutes_used, 0)       AS minutes_used,
    -- Days remaining, floored at zero.
    GREATEST(0, EXTRACT(DAY FROM (pp.valid_to - now()))::INTEGER) AS days_remaining
FROM parking_pass pp
JOIN customer     c  ON c.customer_id = pp.customer_id
JOIN vehicle      v  ON v.vehicle_id  = pp.vehicle_id
JOIN pass_type    pt ON pt.pass_type_id = pp.pass_type_id
LEFT JOIN LATERAL (
    SELECT COUNT(*) AS sessions_used,
           COALESCE(SUM(
             EXTRACT(EPOCH FROM (COALESCE(ps.exit_time, now()) - ps.entry_time)) / 60.0
           ), 0)::INTEGER AS minutes_used
      FROM parking_session ps
     WHERE ps.pass_id = pp.pass_id
) u ON TRUE;

COMMENT ON VIEW v_pass_usage IS 'Report: pass usage. LATERAL subquery aggregating the sessions each pass covered.';


-- ---------------------------------------------------------------------------
-- v_violations — the infringement log, resolved and outstanding.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_violations
WITH (security_invoker = true) AS
SELECT
    vi.violation_id,
    vi.kind,
    vi.detected_at,
    vi.penalty_amount,
    vi.notes,
    (vi.resolved_at IS NOT NULL) AS is_resolved,
    vi.resolved_at,
    fl.facility_id,
    v.vehicle_id,
    v.plate_number,
    c.customer_id,
    c.full_name AS customer_name,
    c.phone     AS customer_phone,
    s.code      AS slot_code,
    ps.ticket_no,
    ps.entry_time,
    ps.exit_time
FROM violation vi
JOIN vehicle  v  ON v.vehicle_id  = vi.vehicle_id
JOIN customer c  ON c.customer_id = v.customer_id
LEFT JOIN slot            s  ON s.slot_id  = vi.slot_id
LEFT JOIN zone            z  ON z.zone_id  = s.zone_id
LEFT JOIN floor           fl ON fl.floor_id = z.floor_id
LEFT JOIN parking_session ps ON ps.session_id = vi.session_id;

COMMENT ON VIEW v_violations IS 'Report: violations, joined out to vehicle, customer, slot and session.';


-- ---------------------------------------------------------------------------
-- v_revenue_daily — money by day, billed vs collected.
-- The two are different numbers and the gap is exactly the receivable, which
-- is the figure the statement calls "revenue leakage".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_revenue_daily
WITH (security_invoker = true) AS
SELECT
    fl.facility_id,
    (b.generated_at AT TIME ZONE 'Asia/Kolkata')::DATE AS revenue_date,
    COUNT(DISTINCT b.bill_id)                          AS bills_raised,
    SUM(b.base_amount)                                 AS base_revenue,
    SUM(b.tax_amount)                                  AS tax_collected,
    SUM(b.total_amount)                                AS billed_total,
    COALESCE(SUM(p.paid), 0)                           AS collected_total,
    SUM(b.total_amount) - COALESCE(SUM(p.paid), 0)     AS outstanding_total,
    ROUND(AVG(b.total_amount), 2)                      AS avg_bill_value
FROM bill b
JOIN parking_session ps ON ps.session_id = b.session_id
JOIN slot  s  ON s.slot_id  = ps.slot_id
JOIN zone  z  ON z.zone_id  = s.zone_id
JOIN floor fl ON fl.floor_id = z.floor_id
LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(pay.amount), 0) AS paid
      FROM payment pay WHERE pay.bill_id = b.bill_id
) p ON TRUE
GROUP BY fl.facility_id, (b.generated_at AT TIME ZONE 'Asia/Kolkata')::DATE;

COMMENT ON VIEW v_revenue_daily IS 'Report: daily revenue. Separates billed from collected so the receivable is visible.';

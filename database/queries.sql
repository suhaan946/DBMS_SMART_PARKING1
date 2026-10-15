-- ============================================================================
-- queries.sql
-- Smart Parking Lot Allocation & Billing System — DBMS PBL Project 20
--
-- Demonstration queries for Review 2: joins, subqueries, aggregation, views.
-- Each is commented with the rubric line it answers and the SQL feature it
-- demonstrates. All of them run against the seeded database as shipped:
--
--     psql -d smartpark -f docs/database/queries.sql
--
-- Every query returns rows on the seed data. None of them is illustrative
-- pseudo-SQL.
-- ============================================================================

\pset pager off
\timing on

-- ---------------------------------------------------------------------------
-- Q1. INNER JOIN across three tables
-- RUBRIC: "data retrieval, joins"
-- Who is parked right now, and where.
-- ---------------------------------------------------------------------------
\echo '=== Q1  Inner join (3 tables): vehicles currently parked ==='
SELECT v.plate_number,
       c.full_name  AS customer,
       s.code       AS bay,
       ps.entry_time
  FROM parking_session ps
  INNER JOIN vehicle  v ON v.vehicle_id  = ps.vehicle_id
  INNER JOIN customer c ON c.customer_id = v.customer_id
  INNER JOIN slot     s ON s.slot_id     = ps.slot_id
 WHERE ps.exit_time IS NULL
 ORDER BY ps.entry_time
 LIMIT 10;


-- ---------------------------------------------------------------------------
-- Q2. LEFT OUTER JOIN
-- RUBRIC: "joins"
-- Customers who have never parked. An INNER JOIN cannot answer this at all —
-- the rows we want are exactly the ones with no match on the right.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q2  Left outer join: customers who have never parked ==='
SELECT c.customer_id, c.full_name, c.phone,
       COUNT(ps.session_id) AS sessions
  FROM customer c
  LEFT JOIN vehicle         v  ON v.customer_id = c.customer_id
  LEFT JOIN parking_session ps ON ps.vehicle_id = v.vehicle_id
 GROUP BY c.customer_id, c.full_name, c.phone
HAVING COUNT(ps.session_id) = 0
 ORDER BY c.full_name;


-- ---------------------------------------------------------------------------
-- Q3. Five-table join down the containment chain
-- RUBRIC: "joins" (3+ tables)
-- Bay inventory by floor, zone and vehicle type. Demonstrates that a slot
-- resolves to its facility only by walking slot -> zone -> floor -> facility,
-- which is why tariff is keyed on facility rather than duplicated per bay.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q3  Five-table join: bay inventory by floor, zone and type ==='
SELECT f.name          AS facility,
       fl.name         AS floor,
       z.code          AS zone,
       vt.name         AS fits,
       COUNT(*)        AS bays,
       COUNT(*) FILTER (WHERE NOT s.is_active) AS out_of_service
  FROM slot s
  JOIN zone         z  ON z.zone_id         = s.zone_id
  JOIN floor        fl ON fl.floor_id       = z.floor_id
  JOIN facility     f  ON f.facility_id     = fl.facility_id
  JOIN vehicle_type vt ON vt.vehicle_type_id = s.vehicle_type_id
 GROUP BY f.name, fl.level_number, fl.name, z.code, vt.name
 ORDER BY f.name, fl.level_number, z.code, vt.name;


-- ---------------------------------------------------------------------------
-- Q4. GROUP BY with HAVING
-- RUBRIC: "aggregate functions"
-- Customers who owe money: those whose unpaid balance exceeds ₹500. HAVING
-- filters the aggregate, which WHERE cannot do.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q4  GROUP BY ... HAVING: customers owing more than Rs 500 ==='
SELECT c.full_name,
       c.phone,
       COUNT(DISTINCT b.bill_id)                       AS unpaid_bills,
       SUM(b.total_amount)                             AS billed,
       SUM(b.total_amount - COALESCE(p.paid, 0))       AS outstanding
  FROM bill b
  JOIN parking_session ps ON ps.session_id  = b.session_id
  JOIN vehicle         v  ON v.vehicle_id   = ps.vehicle_id
  JOIN customer        c  ON c.customer_id  = v.customer_id
  LEFT JOIN LATERAL (
      SELECT SUM(amount) AS paid FROM payment WHERE bill_id = b.bill_id
  ) p ON TRUE
 WHERE b.status <> 'paid'
 GROUP BY c.customer_id, c.full_name, c.phone
HAVING SUM(b.total_amount - COALESCE(p.paid, 0)) > 500
 ORDER BY outstanding DESC
 LIMIT 15;


-- ---------------------------------------------------------------------------
-- Q5. Correlated subquery
-- RUBRIC: "nested queries"
-- Each vehicle's most recent stay. The inner query references the outer row
-- (v.vehicle_id), so it is re-evaluated per vehicle — that is what makes it
-- correlated rather than a plain subquery.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q5  Correlated subquery: each vehicle last visit and lifetime spend ==='
SELECT v.plate_number,
       (SELECT MAX(ps.entry_time)
          FROM parking_session ps
         WHERE ps.vehicle_id = v.vehicle_id)            AS last_visit,
       (SELECT COUNT(*)
          FROM parking_session ps
         WHERE ps.vehicle_id = v.vehicle_id)            AS total_visits,
       (SELECT COALESCE(SUM(b.total_amount), 0)
          FROM parking_session ps
          JOIN bill b ON b.session_id = ps.session_id
         WHERE ps.vehicle_id = v.vehicle_id)            AS lifetime_spend
  FROM vehicle v
 ORDER BY lifetime_spend DESC
 LIMIT 12;


-- ---------------------------------------------------------------------------
-- Q6. Subquery in the FROM clause (a derived table)
-- RUBRIC: "nested queries"
-- Busiest day per facility. The inner query aggregates to one row per day; the
-- outer one then aggregates those rows again — a two-level aggregation that
-- cannot be written as a single GROUP BY.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q6  Subquery in FROM: busiest day per facility ==='
SELECT d.facility,
       MAX(d.arrivals)                              AS busiest_day_arrivals,
       ROUND(AVG(d.arrivals), 1)                    AS mean_daily_arrivals,
       COUNT(*)                                     AS days_with_traffic
  FROM (
        SELECT f.name                       AS facility,
               ps.entry_time::date          AS day,
               COUNT(*)                     AS arrivals
          FROM parking_session ps
          JOIN slot     s  ON s.slot_id     = ps.slot_id
          JOIN zone     z  ON z.zone_id     = s.zone_id
          JOIN floor    fl ON fl.floor_id   = z.floor_id
          JOIN facility f  ON f.facility_id = fl.facility_id
         GROUP BY f.name, ps.entry_time::date
       ) AS d
 GROUP BY d.facility
 ORDER BY d.facility;


-- ---------------------------------------------------------------------------
-- Q7. NOT EXISTS
-- RUBRIC: "nested queries", "meaningful reports - free slots"
-- Bays that have taken no vehicle today. NOT EXISTS stops at the first match
-- rather than counting them all, which is the right tool for a pure existence
-- test - and unlike a LEFT JOIN ... IS NULL it says what it means.
--
-- Note the window is "today" rather than "ever": in the seeded database every
-- bay has been used at some point in the last 30 days, so the wider question
-- honestly returns nothing. Asking a question the data can answer is better
-- than shipping a query that prints an empty table.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q7  NOT EXISTS: bays that have taken no vehicle today ==='
SELECT s.code AS bay, fl.name AS floor, z.code AS zone, vt.name AS fits,
       (SELECT MAX(ps.entry_time)::date
          FROM parking_session ps WHERE ps.slot_id = s.slot_id) AS last_used
  FROM slot s
  JOIN zone         z  ON z.zone_id          = s.zone_id
  JOIN floor        fl ON fl.floor_id        = z.floor_id
  JOIN vehicle_type vt ON vt.vehicle_type_id = s.vehicle_type_id
 WHERE s.is_active
   AND NOT EXISTS (
         SELECT 1
           FROM parking_session ps
          WHERE ps.slot_id = s.slot_id
            AND ps.entry_time >= date_trunc('day', now())
       )
 ORDER BY last_used NULLS FIRST, fl.level_number, z.code, s.code
 LIMIT 20;


-- ---------------------------------------------------------------------------
-- Q8. IN with a subquery
-- RUBRIC: "nested queries"
-- Customers who hold at least one pass that is live right now.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q8  IN (subquery): customers holding a live pass ==='
SELECT c.customer_id, c.full_name, c.phone
  FROM customer c
 WHERE c.customer_id IN (
         SELECT pp.customer_id
           FROM parking_pass pp
          WHERE pp.cancelled_at IS NULL
            AND now() >= pp.valid_from
            AND now() <  pp.valid_to
       )
 ORDER BY c.full_name;


-- ---------------------------------------------------------------------------
-- Q9. Window function: RANK and a running total
-- RUBRIC: "aggregate functions" (beyond GROUP BY)
-- Daily revenue with its rank and a cumulative total. A window function keeps
-- every detail row while adding an aggregate beside it; GROUP BY would collapse
-- them.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q9  Window functions: daily revenue, rank and running total ==='
SELECT day,
       bills,
       revenue,
       RANK()   OVER (ORDER BY revenue DESC)                       AS revenue_rank,
       SUM(revenue) OVER (ORDER BY day
                          ROWS BETWEEN UNBOUNDED PRECEDING
                                   AND CURRENT ROW)                AS running_total,
       ROUND(AVG(revenue) OVER (ORDER BY day
                                ROWS BETWEEN 6 PRECEDING
                                         AND CURRENT ROW), 2)      AS seven_day_average
  FROM (
        SELECT b.generated_at::date AS day,
               COUNT(*)             AS bills,
               SUM(b.total_amount)  AS revenue
          FROM bill b
         WHERE b.generated_at > now() - INTERVAL '30 days'
         GROUP BY b.generated_at::date
       ) AS daily
 ORDER BY day;


-- ---------------------------------------------------------------------------
-- Q10. CASE expression
-- RUBRIC: "meaningful reports — duration"
-- Length-of-stay distribution. CASE turns a continuous measure into the
-- reportable buckets the statement asks for.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q10  CASE: length-of-stay distribution ==='
SELECT CASE
         WHEN mins <   30 THEN '1. under 30 min'
         WHEN mins <  120 THEN '2. 30 min to 2 h'
         WHEN mins <  480 THEN '3. 2 h to 8 h'
         WHEN mins < 1440 THEN '4. 8 h to 24 h'
         ELSE                  '5. over 24 h'
       END                              AS stay_length,
       COUNT(*)                         AS sessions,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_all,
       ROUND(AVG(mins))                 AS avg_minutes
  FROM (
        SELECT EXTRACT(EPOCH FROM (exit_time - entry_time)) / 60.0 AS mins
          FROM parking_session
         WHERE exit_time IS NOT NULL
       ) AS s
 GROUP BY stay_length
 ORDER BY stay_length;


-- ---------------------------------------------------------------------------
-- Q11. Date arithmetic and interval extraction
-- RUBRIC: "meaningful reports — peak hours", "date handling"
-- Weekday versus weekend arrival patterns by hour, which is the shape the
-- peak-hours chart plots.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q11  Date arithmetic: weekday vs weekend arrivals by hour ==='
SELECT EXTRACT(HOUR FROM entry_time)::int AS hour_of_day,
       COUNT(*) FILTER (WHERE EXTRACT(ISODOW FROM entry_time) <= 5) AS weekday,
       COUNT(*) FILTER (WHERE EXTRACT(ISODOW FROM entry_time) >= 6) AS weekend,
       ROUND(AVG(EXTRACT(EPOCH FROM
              (COALESCE(exit_time, now()) - entry_time)) / 60.0)) AS avg_stay_min
  FROM parking_session
 WHERE entry_time > now() - INTERVAL '30 days'
 GROUP BY EXTRACT(HOUR FROM entry_time)
HAVING COUNT(*) > 0
 ORDER BY hour_of_day;


-- ---------------------------------------------------------------------------
-- Q12. Set operation: UNION ALL
-- RUBRIC: "data retrieval"
-- A single revenue statement combining two sources that live in different
-- tables — parking bills and pass sales.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q12  UNION ALL: combined revenue from parking and passes ==='
SELECT 'Parking bills' AS source,
       COUNT(*)        AS transactions,
       SUM(total_amount) AS revenue
  FROM bill
 WHERE generated_at > now() - INTERVAL '30 days'
UNION ALL
SELECT 'Pass sales',
       COUNT(*),
       SUM(price_paid)
  FROM parking_pass
 WHERE created_at > now() - INTERVAL '30 days'
   AND cancelled_at IS NULL
UNION ALL
SELECT 'Violation penalties',
       COUNT(*),
       SUM(penalty_amount)
  FROM violation
 WHERE detected_at > now() - INTERVAL '30 days';


-- ---------------------------------------------------------------------------
-- Q13. Self-join
-- RUBRIC: "joins"
-- Vehicles that returned within 24 hours of leaving. Needs the session table
-- joined to itself, once as the earlier visit and once as the later one.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q13  Self-join: vehicles that returned within 24 hours ==='
SELECT v.plate_number,
       earlier.exit_time                                   AS left_at,
       later.entry_time                                    AS returned_at,
       ROUND(EXTRACT(EPOCH FROM (later.entry_time - earlier.exit_time)) / 3600.0, 1)
                                                           AS hours_away
  FROM parking_session earlier
  JOIN parking_session later
       ON later.vehicle_id  = earlier.vehicle_id
      AND later.entry_time  > earlier.exit_time
      AND later.entry_time  < earlier.exit_time + INTERVAL '24 hours'
  JOIN vehicle v ON v.vehicle_id = earlier.vehicle_id
 WHERE earlier.exit_time IS NOT NULL
 ORDER BY hours_away
 LIMIT 12;


-- ---------------------------------------------------------------------------
-- Q14. The seven report views
-- RUBRIC: "views for: occupancy, peak hours, duration, pass usage, violations,
--          free slots and revenue"
-- Each view is defined in db/migrations/007_views.sql with
-- security_invoker = true, so row-level security still applies through it.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q14  The seven required report views ==='
SELECT 'v_current_occupancy' AS view_name, COUNT(*) AS rows FROM v_current_occupancy
UNION ALL SELECT 'v_free_slots',       COUNT(*) FROM v_free_slots
UNION ALL SELECT 'v_peak_hours',       COUNT(*) FROM v_peak_hours
UNION ALL SELECT 'v_session_duration', COUNT(*) FROM v_session_duration
UNION ALL SELECT 'v_pass_usage',       COUNT(*) FROM v_pass_usage
UNION ALL SELECT 'v_violations',       COUNT(*) FROM v_violations
UNION ALL SELECT 'v_revenue_daily',    COUNT(*) FROM v_revenue_daily;

\echo ''
\echo '--- occupancy right now ---'
SELECT slot_state, COUNT(*) FROM v_current_occupancy GROUP BY slot_state ORDER BY 2 DESC;

\echo ''
\echo '--- the three busiest hours ---'
SELECT hour_of_day, entries, avg_stay_minutes, busyness_rank
  FROM v_peak_hours WHERE facility_id = 1 AND busyness_rank <= 3
 ORDER BY busyness_rank;

\echo ''
\echo '--- last seven days of revenue ---'
SELECT revenue_date, bills_raised, billed_total, collected_total, outstanding_total
  FROM v_revenue_daily WHERE facility_id = 1
 ORDER BY revenue_date DESC LIMIT 7;

\echo ''
\echo '--- violations by kind ---'
SELECT kind, COUNT(*) AS n, COUNT(*) FILTER (WHERE is_resolved) AS resolved,
       SUM(penalty_amount) AS penalties
  FROM v_violations GROUP BY kind ORDER BY n DESC;

\echo ''
\echo '--- pass usage ---'
SELECT pass_state, COUNT(*) AS passes, SUM(sessions_used) AS stays_covered,
       SUM(price_paid) AS revenue
  FROM v_pass_usage GROUP BY pass_state ORDER BY passes DESC;

\echo ''
\echo '--- free bays by type ---'
SELECT vehicle_type_name, COUNT(*) AS free_now
  FROM v_free_slots WHERE facility_id = 1
 GROUP BY vehicle_type_name ORDER BY free_now DESC;


-- ---------------------------------------------------------------------------
-- Q15. The charge function, checked against the tariff by hand
-- RUBRIC: "tariff-based charges"
-- Proves fn_calculate_charge is not a black box: the tariff that produced each
-- figure is shown beside it.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q15  fn_calculate_charge shown against the tariff that produced it ==='
SELECT ps.session_id,
       v.plate_number,
       vt.name                                        AS vehicle_type,
       ROUND(EXTRACT(EPOCH FROM (ps.exit_time - ps.entry_time)) / 60.0) AS minutes,
       t.free_minutes,
       t.first_hour_rate,
       t.subsequent_hour_rate,
       t.daily_cap,
       fn_calculate_charge(ps.session_id)             AS computed_charge,
       b.base_amount                                  AS stored_on_bill,
       (fn_calculate_charge(ps.session_id) = b.base_amount) AS agrees
  FROM parking_session ps
  JOIN bill         b  ON b.session_id      = ps.session_id
  JOIN tariff       t  ON t.tariff_id       = b.tariff_id
  JOIN vehicle      v  ON v.vehicle_id      = ps.vehicle_id
  JOIN vehicle_type vt ON vt.vehicle_type_id = ps.vehicle_type_id
 WHERE ps.exit_time IS NOT NULL
   AND ps.pass_id IS NULL
 ORDER BY ps.exit_time DESC
 LIMIT 10;


-- ---------------------------------------------------------------------------
-- Q16. Index usage evidence
-- RUBRIC: "indexing of frequently searched attributes"
-- The plan for the single most frequent query in the application — an operator
-- typing a registration at the gate. It must be an index scan, not a seq scan.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Q16a  Plate lookup: why this one is HONESTLY a sequential scan ==='
\echo '     vehicle holds ~50 rows, which fit in a single 8 KB page. Reading'
\echo '     that page is cheaper than reading an index page AND then the heap'
\echo '     page, so the planner declines the index. That is the correct'
\echo '     decision, not a missing index - see Q16b.'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT vehicle_id, plate_number FROM vehicle WHERE plate_number = 'TS09AB1234';

\echo ''
\echo '=== Q16b  The same lookup with the sequential scan removed ==='
\echo '     Proves the index EXISTS and SERVES this predicate; the planner was'
\echo '     choosing between two valid plans, not falling back to the only one.'
SET enable_seqscan = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT vehicle_id, plate_number FROM vehicle WHERE plate_number = 'TS09AB1234';
RESET enable_seqscan;

\echo ''
\echo '=== Q16c  A table large enough that the index genuinely wins ==='
\echo '     parking_session holds ~1,600 rows. Here the planner chooses the'
\echo '     partial index unprompted - this is the floor-map lookup that runs'
\echo '     once per bay on every render.'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT session_id FROM parking_session WHERE slot_id = 55 AND exit_time IS NULL;

\echo ''
\echo '--- and a date-windowed scan over the same table ---'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT session_id, entry_time FROM parking_session
 WHERE entry_time > now() - INTERVAL '2 days'
 ORDER BY entry_time DESC LIMIT 20;

\echo ''
\echo '--- index inventory, each with the query it serves ---'
SELECT i.indexrelid::regclass::text AS index_name,
       t.relname                    AS table_name,
       COALESCE(obj_description(i.indexrelid, 'pg_class'), '') AS serves
  FROM pg_index i
  JOIN pg_class t ON t.oid = i.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
 WHERE n.nspname = 'public'
   AND obj_description(i.indexrelid, 'pg_class') IS NOT NULL
 ORDER BY t.relname, index_name;

-- ----------------------------------------------------------------------------
-- Q17. JSONB: the audit trail - who changed a bill's status, from what to what
--      The ->/->> operators read inside the {column: {from, to}} document the
--      trg_audit trigger writes.
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== Q17  JSONB: status changes on bills, newest first ==='
SELECT a.occurred_at::timestamp(0)              AS at,
       COALESCE(u.full_name, 'database session') AS who,
       a.row_id                                  AS bill_id,
       a.changes -> 'status' ->> 'from'          AS status_from,
       a.changes -> 'status' ->> 'to'            AS status_to
  FROM audit_log a
  LEFT JOIN app_user u ON u.user_id = a.actor_user_id
 WHERE a.table_name = 'bill' AND a.action = 'UPDATE' AND a.changes ? 'status'
 ORDER BY a.occurred_at DESC
 LIMIT 10;

-- ----------------------------------------------------------------------------
-- Q18. The live activity view (UNION ALL of five event kinds)
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== Q18  View: the ten most recent events at facility 1 ==='
SELECT occurred_at::timestamp(0) AS at, kind, plate_number, slot_code, amount, detail
  FROM v_recent_activity
 WHERE facility_id = 1
 ORDER BY occurred_at DESC
 LIMIT 10;

\timing off
\echo ''
\echo '=== queries.sql complete ==='

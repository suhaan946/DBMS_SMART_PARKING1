-- ============================================================================
-- 019_planned_facilities.sql
--
-- Purpose: three sites that are planned but not yet open. They are stored
-- with is_active = FALSE, so every screen and report (which read
-- `facility WHERE is_active`) ignores them until they open; no floors, bays or
-- tariffs exist for them yet. They bring `facility` to five rows, the
-- minimum sample size the course asks for in every table.
-- Idempotent: the facility name is UNIQUE.
-- ============================================================================

INSERT INTO facility (name, address_line, city, opens_at, closes_at, tax_rate_pct, is_active) VALUES
    ('SmartPark HITEC City',   'Plot 7, Madhapur Main Road',      'Hyderabad', '06:00', '23:00', 18.00, FALSE),
    ('SmartPark Secunderabad', '21 Station Road, near Platform 1', 'Hyderabad', '00:00', '23:59', 18.00, FALSE),
    ('SmartPark Gachibowli',   '3 Financial District Avenue',     'Hyderabad', '07:00', '22:00', 18.00, FALSE)
ON CONFLICT (name) DO NOTHING;

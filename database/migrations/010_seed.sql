-- ============================================================================
-- 010_seed.sql
--
-- Purpose: realistic sample data at demonstration volume.
--
-- The reports are only as convincing as the data behind them: a peak-hours
-- chart needs a believable arrival curve, and a revenue chart needs thirty
-- days of bills. Targets met here:
--     2 facilities, 5 floors, 12 zones, 130 slots across 5 vehicle types
--     28 customers, 46 vehicles, 8 staff logins
--     ~230 parking sessions spread over the last 30 days
--     ~20 sessions currently open
--     reservations in every status, active and expired passes
--     bills paid / unpaid / partly paid, payments across 5 methods
--     violations of every kind
--
-- Every session is generated in chronological order against a running record
-- of when each slot next becomes free, so the history is physically coherent:
-- no two cars are ever in one bay at the same moment, even though the partial
-- unique index only constrains currently-open sessions.
--
-- Amounts are NOT written here. Bills are inserted with placeholder zeros and
-- trg_bill_enforce_amounts replaces them with fn_calculate_charge output, so
-- every figure on every screen traces back to a tariff row.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Vehicle types
-- ---------------------------------------------------------------------------
INSERT INTO vehicle_type (code, name, footprint_units) VALUES
    ('BIKE',  'Two Wheeler',  1),
    ('CAR',   'Hatchback / Sedan', 2),
    ('SUV',   'SUV / MUV',    2),
    ('EV',    'Electric Vehicle', 2),
    ('TRUCK', 'Light Commercial', 3);

-- ---------------------------------------------------------------------------
-- Facilities
-- ---------------------------------------------------------------------------
INSERT INTO facility (name, address_line, city, opens_at, closes_at, tax_rate_pct) VALUES
    ('SmartPark Central',  '14 Banjara Hills Road No. 12', 'Hyderabad', '00:00', '23:59', 18.00),
    ('SmartPark Riverside','88 Necklace Road',             'Hyderabad', '06:00', '23:00', 18.00);

-- ---------------------------------------------------------------------------
-- Floors and zones
-- ---------------------------------------------------------------------------
INSERT INTO floor (facility_id, level_number, name) VALUES
    (1, -1, 'Basement'), (1, 0, 'Ground'), (1, 1, 'Level 1'),
    (2,  0, 'Ground'),   (2, 1, 'Level 1');

INSERT INTO zone (floor_id, code, name) VALUES
    (1, 'A', 'Basement A'), (1, 'B', 'Basement B'),
    (2, 'A', 'Ground A'),   (2, 'B', 'Ground B'), (2, 'C', 'Ground C'),
    (3, 'A', 'Level 1 A'),  (3, 'B', 'Level 1 B'),
    (4, 'A', 'Riverside Ground A'), (4, 'B', 'Riverside Ground B'),
    (5, 'A', 'Riverside L1 A');

-- ---------------------------------------------------------------------------
-- Slots — 130 across both facilities, laid out on a grid so the floor map
-- renders as a plan rather than a list.
--
-- Type mix per zone reflects a real building: mostly cars, a bike block, a
-- couple of EV bays near the lift, one truck bay per level.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    z            RECORD;
    i            INTEGER;
    v_count      INTEGER;
    v_type       BIGINT;
    v_zone_label TEXT;
    v_floor_char TEXT;
BEGIN
    FOR z IN
        SELECT zn.zone_id, zn.code AS zcode, fl.level_number, fl.facility_id
          FROM zone zn JOIN floor fl ON fl.floor_id = zn.floor_id
         ORDER BY zn.zone_id
    LOOP
        -- Basement and ground zones are larger than upper levels.
        v_count := CASE WHEN z.level_number <= 0 THEN 14 ELSE 12 END;
        v_floor_char := CASE
            WHEN z.level_number < 0 THEN 'B'
            WHEN z.level_number = 0 THEN 'G'
            ELSE 'L' || z.level_number::TEXT
        END;

        FOR i IN 1..v_count LOOP
            v_type := CASE
                WHEN i <= 2               THEN (SELECT vehicle_type_id FROM vehicle_type WHERE code='BIKE')
                WHEN i = 3                THEN (SELECT vehicle_type_id FROM vehicle_type WHERE code='EV')
                WHEN i = v_count          THEN (SELECT vehicle_type_id FROM vehicle_type WHERE code='TRUCK')
                WHEN i % 5 = 0            THEN (SELECT vehicle_type_id FROM vehicle_type WHERE code='SUV')
                ELSE                           (SELECT vehicle_type_id FROM vehicle_type WHERE code='CAR')
            END;

            INSERT INTO slot (zone_id, code, vehicle_type_id, grid_row, grid_col, is_active)
            VALUES (
                z.zone_id,
                v_floor_char || '-' || z.zcode || '-' || lpad(i::TEXT, 2, '0'),
                v_type,
                ((i - 1) / 7) + 1,          -- two rows of seven, with an aisle between
                ((i - 1) % 7) + 1,
                -- Two bays are out of service, so the map has a real
                -- out_of_service state to render rather than a synthetic one.
                NOT (z.zone_id = 3 AND i = 9)
            );
        END LOOP;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Tariffs — one in force row per facility per vehicle type.
-- effective_from is backdated 90 days so every historical session in this seed
-- falls inside a priced window.
-- ---------------------------------------------------------------------------
INSERT INTO tariff (facility_id, vehicle_type_id, name, free_minutes,
                    first_hour_rate, subsequent_hour_rate, daily_cap, effective_from)
SELECT f.facility_id,
       vt.vehicle_type_id,
       f.name || ' — ' || vt.name,
       CASE vt.code WHEN 'BIKE' THEN 30 ELSE 15 END,
       CASE vt.code WHEN 'BIKE' THEN 15 WHEN 'CAR' THEN 40 WHEN 'SUV' THEN 50
                    WHEN 'EV' THEN 35 ELSE 70 END,
       CASE vt.code WHEN 'BIKE' THEN 10 WHEN 'CAR' THEN 25 WHEN 'SUV' THEN 30
                    WHEN 'EV' THEN 20 ELSE 45 END,
       CASE vt.code WHEN 'BIKE' THEN 80 WHEN 'CAR' THEN 250 WHEN 'SUV' THEN 300
                    WHEN 'EV' THEN 200 ELSE 500 END,
       now() - INTERVAL '90 days'
  FROM facility f CROSS JOIN vehicle_type vt;

-- A superseded tariff row, closed rather than deleted, to show the versioning
-- the design depends on. Its window sits entirely before the current one.
INSERT INTO tariff (facility_id, vehicle_type_id, name, free_minutes,
                    first_hour_rate, subsequent_hour_rate, daily_cap,
                    effective_from, effective_to)
VALUES (1, (SELECT vehicle_type_id FROM vehicle_type WHERE code='CAR'),
        'SmartPark Central — Hatchback / Sedan (2025 rates)', 15,
        35, 20, 220,
        now() - INTERVAL '400 days', now() - INTERVAL '90 days');

-- ---------------------------------------------------------------------------
-- Pass products
-- ---------------------------------------------------------------------------
INSERT INTO pass_type (code, name, duration_days, price, vehicle_type_id)
SELECT 'DAY_'   || vt.code, 'Day Pass — '     || vt.name, 1,
       CASE vt.code WHEN 'BIKE' THEN 60   WHEN 'CAR' THEN 200  WHEN 'SUV' THEN 250
                    WHEN 'EV'   THEN 160  ELSE 400 END, vt.vehicle_type_id
  FROM vehicle_type vt
UNION ALL
SELECT 'WEEK_'  || vt.code, 'Weekly Pass — '  || vt.name, 7,
       CASE vt.code WHEN 'BIKE' THEN 320  WHEN 'CAR' THEN 1100 WHEN 'SUV' THEN 1350
                    WHEN 'EV'   THEN 880  ELSE 2200 END, vt.vehicle_type_id
  FROM vehicle_type vt
UNION ALL
SELECT 'MONTH_' || vt.code, 'Monthly Pass — ' || vt.name, 30,
       CASE vt.code WHEN 'BIKE' THEN 1000 WHEN 'CAR' THEN 3500 WHEN 'SUV' THEN 4200
                    WHEN 'EV'   THEN 2800 ELSE 7000 END, vt.vehicle_type_id
  FROM vehicle_type vt;

-- ---------------------------------------------------------------------------
-- Staff logins.
--
-- Password for every seeded account is  Parking@123
-- The hash below is bcrypt of that string. It is a demonstration credential
-- for a local database and is documented as such in README.md.
-- ---------------------------------------------------------------------------
INSERT INTO app_user (email, password_hash, full_name, role, facility_id) VALUES
    ('admin@smartpark.in',    '$2b$12$ZTw5BtsdjjunNdd3youP/uLXAylXQtDafGa2M1aDJpL.jYfstrJeq', 'Aarti Desai',     'admin',    NULL),
    ('ops.central@smartpark.in','$2b$12$ZTw5BtsdjjunNdd3youP/uLXAylXQtDafGa2M1aDJpL.jYfstrJeq','Rohit Kulkarni', 'operator', 1),
    ('ops.central2@smartpark.in','$2b$12$ZTw5BtsdjjunNdd3youP/uLXAylXQtDafGa2M1aDJpL.jYfstrJeq','Nisha Rao',     'operator', 1),
    ('ops.river@smartpark.in', '$2b$12$ZTw5BtsdjjunNdd3youP/uLXAylXQtDafGa2M1aDJpL.jYfstrJeq', 'Imran Sheikh',    'operator', 2);

-- ---------------------------------------------------------------------------
-- Customers — 28, four of them with logins so the customer-facing RLS
-- policies have something to be tested against.
-- ---------------------------------------------------------------------------
INSERT INTO customer (full_name, phone, email)
SELECT n.full_name, n.phone, n.email
FROM (VALUES
    ('Rahul Sharma',      '9876543210', 'rahul.sharma@example.com'),
    ('Priya Nair',        '9812345678', 'priya.nair@example.com'),
    ('Arjun Mehta',       '9823456781', 'arjun.mehta@example.com'),
    ('Sneha Iyer',        '9834567812', 'sneha.iyer@example.com'),
    ('Vikram Reddy',      '9845678123', 'vikram.reddy@example.com'),
    ('Ananya Ghosh',      '9856781234', 'ananya.ghosh@example.com'),
    ('Karan Malhotra',    '9867812345', 'karan.malhotra@example.com'),
    ('Divya Pillai',      '9878123456', 'divya.pillai@example.com'),
    ('Sameer Joshi',      '9881234567', 'sameer.joshi@example.com'),
    ('Meera Krishnan',    '9892345678', 'meera.krishnan@example.com'),
    ('Aditya Rane',       '9903456789', 'aditya.rane@example.com'),
    ('Fatima Qureshi',    '9914567890', 'fatima.qureshi@example.com'),
    ('Nikhil Bhat',       '9925678901', 'nikhil.bhat@example.com'),
    ('Ritu Agarwal',      '9936789012', 'ritu.agarwal@example.com'),
    ('Suresh Menon',      '9947890123', 'suresh.menon@example.com'),
    ('Kavya Subramanian', '9958901234', 'kavya.s@example.com'),
    ('Manish Tiwari',     '9969012345', 'manish.tiwari@example.com'),
    ('Pooja Deshmukh',    '9970123456', 'pooja.deshmukh@example.com'),
    ('Rajesh Kumar',      '9981234501', 'rajesh.kumar@example.com'),
    ('Lakshmi Venkat',    '9992345012', 'lakshmi.venkat@example.com'),
    ('Farhan Ali',        '9803450123', 'farhan.ali@example.com'),
    ('Ishita Roy',        '9814501234', 'ishita.roy@example.com'),
    ('Gaurav Sinha',      '9825012345', 'gaurav.sinha@example.com'),
    ('Neha Kapoor',       '9830123456', 'neha.kapoor@example.com'),
    ('Tarun Vaidya',      '9841234560', 'tarun.vaidya@example.com'),
    ('Shreya Bose',       '9852345601', 'shreya.bose@example.com'),
    ('Omkar Patil',       '9863456012', 'omkar.patil@example.com'),
    ('Zoya Khan',         '9874560123', 'zoya.khan@example.com'),
    -- Three customers who have registered but not yet parked. Real facilities
    -- always have some, and without them the outer join in
    -- docs/database/queries.sql Q2 has nothing to return - a LEFT JOIN that
    -- shows no rows does not demonstrate a LEFT JOIN.
    ('Anil Varma',        '9885012347', 'anil.varma@example.com'),
    ('Rekha Chandran',    '9896123458', 'rekha.chandran@example.com'),
    ('Joseph Mathew',     '9807234569', 'joseph.mathew@example.com')
) AS n(full_name, phone, email);

-- Give the first four customers a login.
INSERT INTO app_user (email, password_hash, full_name, role, facility_id)
SELECT c.email, '$2b$12$ZTw5BtsdjjunNdd3youP/uLXAylXQtDafGa2M1aDJpL.jYfstrJeq',
       c.full_name, 'customer', NULL
  FROM customer c WHERE c.customer_id <= 4;

UPDATE customer c
   SET user_id = u.user_id
  FROM app_user u
 WHERE u.email = c.email AND u.role = 'customer';

-- ---------------------------------------------------------------------------
-- Vehicles — 46, spread across the type mix, all on valid Indian plates.
-- ---------------------------------------------------------------------------
INSERT INTO vehicle (customer_id, plate_number, vehicle_type_id, make, model, colour)
SELECT v.cid,
       v.plate,
       (SELECT vehicle_type_id FROM vehicle_type WHERE code = v.tcode),
       v.make, v.model, v.colour
FROM (VALUES
    (1,'TS09AB1234','CAR','Maruti','Swift','White'),
    (1,'TS09XY7788','BIKE','Honda','Activa','Grey'),
    (2,'TS10CD5678','SUV','Hyundai','Creta','Blue'),
    (3,'AP31EF9012','CAR','Honda','City','Silver'),
    (4,'TS07GH3456','EV','Tata','Nexon EV','Teal'),
    (5,'KA05IJ7890','CAR','Toyota','Glanza','Red'),
    (6,'TS08KL2345','BIKE','TVS','Jupiter','Black'),
    (7,'MH12MN6789','SUV','Mahindra','XUV700','Black'),
    (8,'TS11OP1122','CAR','Volkswagen','Polo','White'),
    (9,'TS13QR3344','TRUCK','Tata','Ace','Blue'),
    (10,'AP39ST5566','CAR','Hyundai','i20','Grey'),
    (11,'TS09UV7799','EV','MG','ZS EV','White'),
    (12,'TS12WX8811','BIKE','Bajaj','Pulsar','Blue'),
    (13,'KA51YZ2233','CAR','Maruti','Baleno','Silver'),
    (14,'TS07AB4455','SUV','Kia','Seltos','White'),
    (15,'TS10CD6677','CAR','Skoda','Rapid','Black'),
    (16,'AP16EF8899','BIKE','Royal Enfield','Classic','Green'),
    (17,'TS08GH1010','CAR','Renault','Kwid','Orange'),
    (18,'TS09IJ2020','EV','Tata','Tiago EV','Blue'),
    (19,'MH14KL3030','TRUCK','Ashok Leyland','Dost','White'),
    (20,'TS11MN4040','CAR','Ford','Figo','Red'),
    (21,'TS13OP5050','SUV','Jeep','Compass','Grey'),
    (22,'KA03QR6060','CAR','Nissan','Magnite','White'),
    (23,'TS07ST7070','BIKE','Yamaha','FZ','Blue'),
    (24,'AP28UV8080','CAR','Maruti','Dzire','Silver'),
    (25,'TS12WX9090','SUV','Tata','Harrier','Black'),
    (26,'TS09YZ1111','CAR','Honda','Amaze','White'),
    (27,'TS10AB2222','EV','Hyundai','Kona','Grey'),
    (28,'TS08CD3333','BIKE','Suzuki','Access','Red'),
    (1,'TS09EF4444','SUV','Toyota','Fortuner','White'),
    (2,'TS11GH5555','CAR','Maruti','Alto','Green'),
    (3,'TS13IJ6666','BIKE','Hero','Splendor','Black'),
    (4,'AP31KL7777','CAR','Tata','Altroz','Blue'),
    (5,'TS07MN8888','TRUCK','Mahindra','Bolero Pickup','White'),
    (6,'KA05OP9999','CAR','Hyundai','Verna','Grey'),
    (7,'TS12QR1212','EV','BYD','Atto 3','White'),
    (8,'TS09ST1313','CAR','Volkswagen','Virtus','Red'),
    (9,'MH12UV1414','SUV','MG','Hector','Black'),
    (10,'TS10WX1515','BIKE','KTM','Duke','Orange'),
    (11,'TS08YZ1616','CAR','Kia','Sonet','Silver'),
    (12,'AP39AB1717','CAR','Maruti','Ciaz','White'),
    (13,'TS11CD1818','SUV','Hyundai','Venue','Blue'),
    (14,'TS13EF1919','EV','Mahindra','XUV400','Teal'),
    (15,'TS07GH2121','CAR','Honda','Jazz','Yellow'),
    (16,'KA51IJ2323','BIKE','Bajaj','Chetak','White'),
    (17,'TS09KL2424','TRUCK','Eicher','Pro','Blue')
) AS v(cid, plate, tcode, make, model, colour);

COMMIT;

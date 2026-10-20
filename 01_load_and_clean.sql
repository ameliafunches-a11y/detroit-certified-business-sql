-- =====================================================================
-- 01_load_and_clean.sql
-- Detroit Certified Business Register: staging -> clean relational model
--
-- Prerequisite: a raw staging table `stg_register` (all TEXT columns, one
-- row per CSV row, in file order). run_all.py creates it; in the sqlite3 CLI:
--     .mode csv
--     .import --skip 1 data/Certified_Business_Register_data.csv stg_register
--   (create stg_register first with the column names used below)
--
-- Dialect: SQLite 3.25+ (window functions, recursive CTEs)
--
-- Model (star-ish / normalized):
--   business ──< business_industry >── industry
--   business ──< business_certification >── certification
-- =====================================================================

PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS business_certification;
DROP TABLE IF EXISTS business_industry;
DROP TABLE IF EXISTS certification;
DROP TABLE IF EXISTS industry;
DROP TABLE IF EXISTS business;

-- ---------------------------------------------------------------------
-- 1. Core table. Constraints make bad data fail loudly instead of silently.
-- ---------------------------------------------------------------------
CREATE TABLE business (
    business_id      INTEGER PRIMARY KEY,          -- = row number in the source file
    business_name    TEXT    NOT NULL UNIQUE,
    address          TEXT,
    city             TEXT    NOT NULL,
    state            TEXT    NOT NULL CHECK (length(state) = 2),
    zip_code         TEXT,                          -- NULL when missing in source
    council_district INTEGER CHECK (council_district BETWEEN 1 AND 7),  -- NULL = "Not Applicable"
    email            TEXT,
    cert_expires     TEXT    NOT NULL
                     CHECK (cert_expires GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
    in_detroit       INTEGER NOT NULL CHECK (in_detroit IN (0, 1))
);

-- Cleaning rules applied below:
--   * city     : upper-case, trim, strip a trailing ", MI"  ("DETROIT, MI" -> "DETROIT")
--   * state    : 9 spellings (MI, Michigan, MICHIGAN, Mi., Michgan, ...) -> 2-letter code
--   * zip      : empty string -> NULL
--   * district : "Not Applicable" -> NULL
--   * expires  : M/D/YYYY text -> ISO-8601 date text (sorts and compares correctly)
--   * the always-empty "Blank" column is dropped
WITH step1 AS (
    SELECT
        rowid                                             AS business_id,
        TRIM(business_name)                               AS business_name,
        TRIM(address)                                     AS address,
        TRIM(REPLACE(UPPER(city), ', MI', ''))            AS city,
        UPPER(TRIM(state))                                AS state_raw,
        NULLIF(TRIM(zip_code), '')                        AS zip_code,
        CASE WHEN TRIM(council_district) GLOB '[1-7]'
             THEN CAST(TRIM(council_district) AS INTEGER) END AS council_district,
        NULLIF(TRIM(email), '')                           AS email,
        TRIM(cert_expires)                                AS d
    FROM stg_register
),
step2 AS (   -- split "M/D/YYYY" into pieces
    SELECT *,
           CAST(substr(d, 1, instr(d, '/') - 1) AS INTEGER) AS mo,
           substr(d, instr(d, '/') + 1)                     AS rest
    FROM step1
),
step3 AS (
    SELECT *,
           CAST(substr(rest, 1, instr(rest, '/') - 1) AS INTEGER) AS dy,
           substr(rest, instr(rest, '/') + 1)                     AS yr
    FROM step2
)
INSERT INTO business
    (business_id, business_name, address, city, state, zip_code,
     council_district, email, cert_expires, in_detroit)
SELECT
    business_id,
    business_name,
    address,
    city,
    CASE state_raw
        WHEN 'MI'       THEN 'MI'
        WHEN 'MICHIGAN' THEN 'MI'
        WHEN 'MI.'      THEN 'MI'
        WHEN 'MICHGAN'  THEN 'MI'     -- typo in source
        WHEN 'MISSOURI' THEN 'MO'
        WHEN 'ILLINOIS' THEN 'IL'
    END,                              -- unmapped value -> NULL -> NOT NULL violation (fails loudly)
    zip_code,
    council_district,
    email,
    printf('%04d-%02d-%02d', yr, mo, dy),
    CASE WHEN city = 'DETROIT' THEN 1 ELSE 0 END
FROM step3;

-- ---------------------------------------------------------------------
-- 2. Industry: category names contain commas ("Real Estate, Planning, & Development"),
--    so a naive split on ',' would shred them. Instead, keep an explicit list of the
--    27 categories seen in the register and match each one against the delimited string.
-- ---------------------------------------------------------------------
CREATE TABLE industry (
    industry_id   INTEGER PRIMARY KEY,
    industry_name TEXT NOT NULL UNIQUE
);

INSERT INTO industry (industry_name) VALUES
    ('Clothing, Uniforms, & Accessories'),
    ('Communications & Media'),
    ('Construction'),
    ('Demolition & Trashout'),
    ('Energy'),
    ('Environment'),
    ('Events, Arts, & Culture'),
    ('Food'),
    ('Grounds, Recreation, & Outdoors'),
    ('Health & Science'),
    ('Human Resources'),
    ('Human Services'),
    ('Industry'),
    ('Information Technology'),
    ('Miscellaneous Goods & Services'),
    ('Office & Promotional Items'),
    ('Police, Fire, & Rescue (EXCLUDING vehicles)'),
    ('Printing'),
    ('Professional Services & Consulting'),
    ('Property & Facility Services & Skilled Trades'),
    ('Real Estate, Planning, & Development'),
    ('Rentals & Leases'),
    ('Safety & Security'),
    ('Tools, Materials, & Supplies'),
    ('Vehicles & Transportation'),
    ('Waste Management'),
    ('Water & Sewage');

CREATE TABLE business_industry (
    business_id INTEGER NOT NULL REFERENCES business (business_id),
    industry_id INTEGER NOT NULL REFERENCES industry (industry_id),
    PRIMARY KEY (business_id, industry_id)
);

-- Wrapping both sides in ", " makes the match whole-token only; the source file
-- quotes the comma-containing categories, so strip the quote characters first.
INSERT INTO business_industry (business_id, industry_id)
SELECT s.rowid, i.industry_id
FROM stg_register AS s
JOIN industry     AS i
  ON ', ' || REPLACE(s.industry_type, '"', '') || ', '
     LIKE '%, ' || i.industry_name || ', %';

-- ---------------------------------------------------------------------
-- 3. Certifications: plain codes separated by ", " (no embedded commas), so a
--    recursive CTE can split them one token at a time.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE tmp_cert_split AS
WITH RECURSIVE split (business_id, code, rest) AS (
    SELECT rowid, NULL, certifications || ',' FROM stg_register
    UNION ALL
    SELECT business_id,
           TRIM(substr(rest, 1, instr(rest, ',') - 1)),
           substr(rest, instr(rest, ',') + 1)
    FROM split
    WHERE rest <> ''
)
SELECT DISTINCT business_id, code AS cert_code
FROM split
WHERE code IS NOT NULL AND code <> '';

CREATE TABLE certification (
    cert_code TEXT PRIMARY KEY
);
INSERT INTO certification SELECT DISTINCT cert_code FROM tmp_cert_split;

CREATE TABLE business_certification (
    business_id INTEGER NOT NULL REFERENCES business (business_id),
    cert_code   TEXT    NOT NULL REFERENCES certification (cert_code),
    PRIMARY KEY (business_id, cert_code)
);
INSERT INTO business_certification SELECT business_id, cert_code FROM tmp_cert_split;

DROP TABLE tmp_cert_split;

CREATE INDEX idx_business_district ON business (council_district);
CREATE INDEX idx_business_expires  ON business (cert_expires);

-- ---------------------------------------------------------------------
-- 4. Validation: each check should return the stated result.
-- ---------------------------------------------------------------------

-- V1: Industry parsing is lossless. Rebuild the expected string length from the matched
--     categories (name lengths + ", " separators) and compare to the source string.
--     EXPECTED: 0 rows.
SELECT s.rowid AS business_id, s.business_name, s.industry_type
FROM stg_register AS s
LEFT JOIN (
    SELECT bi.business_id,
           SUM(length(i.industry_name)) + 2 * (COUNT(*) - 1) AS rebuilt_len
    FROM business_industry bi
    JOIN industry i USING (industry_id)
    GROUP BY bi.business_id
) AS r ON r.business_id = s.rowid
WHERE r.rebuilt_len IS NULL
   OR r.rebuilt_len <> length(REPLACE(s.industry_type, '"', ''));

-- V2: Every business has at least one industry and one certification. EXPECTED: 0 rows.
SELECT b.business_id, b.business_name
FROM business b
WHERE NOT EXISTS (SELECT 1 FROM business_industry      WHERE business_id = b.business_id)
   OR NOT EXISTS (SELECT 1 FROM business_certification WHERE business_id = b.business_id);

-- V3: Row counts reconcile with the source. EXPECTED: staging = business = 132.
SELECT (SELECT COUNT(*) FROM stg_register) AS staging_rows,
       (SELECT COUNT(*) FROM business)     AS business_rows;

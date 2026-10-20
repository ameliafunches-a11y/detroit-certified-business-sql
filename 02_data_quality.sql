-- =====================================================================
-- 02_data_quality.sql
-- Profiling the raw staging table and auditing the cleaned model.
-- Findings from this file are summarized in the README.
-- =====================================================================

-- Q1: Row counts for every table in the model.
SELECT 'stg_register' AS table_name, COUNT(*) AS row_count FROM stg_register
UNION ALL SELECT 'business',               COUNT(*) FROM business
UNION ALL SELECT 'industry',               COUNT(*) FROM industry
UNION ALL SELECT 'business_industry',      COUNT(*) FROM business_industry
UNION ALL SELECT 'certification',          COUNT(*) FROM certification
UNION ALL SELECT 'business_certification', COUNT(*) FROM business_certification;

-- Q2: Missing values per source column (empty string counts as missing).
SELECT
    SUM(TRIM(business_name)    = '') AS missing_name,
    SUM(TRIM(address)          = '') AS missing_address,
    SUM(TRIM(zip_code)         = '') AS missing_zip,
    SUM(TRIM(email)            = '') AS missing_email,
    SUM(TRIM(blank)            = '' OR blank IS NULL) AS empty_blank_column
FROM stg_register;

-- Q3: Raw state spellings that collapse into 3 clean codes.
SELECT s.state AS raw_state, b.state AS clean_state, COUNT(*) AS firms
FROM stg_register AS s
JOIN business     AS b ON b.business_id = s.rowid
GROUP BY s.state, b.state
ORDER BY clean_state, firms DESC;

-- Q4: Raw city spellings that collapse after cleaning (before vs after).
SELECT s.city AS raw_city, b.city AS clean_city, COUNT(*) AS firms
FROM stg_register AS s
JOIN business     AS b ON b.business_id = s.rowid
WHERE s.city <> b.city
GROUP BY s.city, b.city
ORDER BY firms DESC;

-- Q5: Firms that share an email address (likely one owner / parent company).
--     Matters because the register counts them as separate firms.
SELECT LOWER(email) AS shared_email,
       COUNT(*)     AS firms,
       GROUP_CONCAT(business_name, ' | ') AS firm_names
FROM business
WHERE email IS NOT NULL
GROUP BY LOWER(email)
HAVING COUNT(*) > 1
ORDER BY firms DESC, shared_email;

-- Q6: Malformed email addresses (no characters before the "@").
SELECT business_id, business_name, email
FROM business
WHERE email IS NOT NULL
  AND email NOT LIKE '_%@_%._%';

-- Q7: Council-district vs address conflicts.
--     (a) Addresses outside Detroit that still carry a council district.
--     (b) Detroit addresses with no council district.
SELECT 'outside Detroit but has district' AS issue,
       business_name, city, state, council_district
FROM business
WHERE in_detroit = 0 AND council_district IS NOT NULL
UNION ALL
SELECT 'Detroit address but no district',
       business_name, city, state, council_district
FROM business
WHERE in_detroit = 1 AND council_district IS NULL;

-- Q8: Detroit firms with no zip code.
SELECT business_id, business_name, address
FROM business
WHERE zip_code IS NULL;

-- Q9: Geography of the register: Detroit vs. metro Detroit vs. out of state.
SELECT CASE
           WHEN in_detroit = 1 THEN '1. Detroit'
           WHEN state = 'MI'   THEN '2. Elsewhere in Michigan'
           ELSE                     '3. Out of state'
       END AS location_group,
       COUNT(*) AS firms,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM business
GROUP BY location_group
ORDER BY location_group;

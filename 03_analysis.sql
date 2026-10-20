-- =====================================================================
-- 03_analysis.sql
-- Business question:
--   Where is Detroit's certified-business base concentrated, which industries
--   and council districts are thin, and how much of the register is about to
--   lapse?
--
-- Conventions
--   * "Detroit firms" = in_detroit = 1 AND council_district IS NOT NULL
--     (district analysis excludes out-of-city addresses and the one Detroit
--     firm with no district; see 02_data_quality.sql Q7).
--   * A firm can list several industries, so industry counts overlap and
--     percentages across industries add up to more than 100%.
--   * Renewal analysis uses a fixed as-of date so results are reproducible.
--     Change it in the `params` CTE to re-run for a different date.
-- =====================================================================

-- Q1: Concentration by council district, with share and cumulative share.
--     Skills: aggregation, window functions (SUM OVER, RANK).
WITH district_counts AS (
    SELECT council_district, COUNT(*) AS firms
    FROM business
    WHERE in_detroit = 1 AND council_district IS NOT NULL
    GROUP BY council_district
)
SELECT council_district,
       firms,
       ROUND(100.0 * firms / SUM(firms) OVER (), 1)                                     AS pct_of_detroit_firms,
       ROUND(100.0 * SUM(firms) OVER (ORDER BY firms DESC, council_district)
                   / SUM(firms) OVER (), 1)                                              AS cumulative_pct,
       RANK() OVER (ORDER BY firms DESC)                                                 AS rank_by_firms
FROM district_counts
ORDER BY firms DESC, council_district;

-- Q2: Industry representation across the whole register.
--     LEFT JOIN from the dimension so industries with zero firms would still appear.
SELECT i.industry_name,
       COUNT(bi.business_id)                                                  AS firms,
       ROUND(100.0 * COUNT(bi.business_id) / (SELECT COUNT(*) FROM business), 1) AS pct_of_all_firms,
       RANK() OVER (ORDER BY COUNT(bi.business_id) DESC)                      AS rank_by_firms
FROM industry AS i
LEFT JOIN business_industry AS bi ON bi.industry_id = i.industry_id
GROUP BY i.industry_id, i.industry_name
ORDER BY firms DESC, i.industry_name;

-- Q3: The leading industry (ties included) in each council district.
--     Skills: CTEs, joins across a bridge table, RANK() with PARTITION BY.
WITH district_industry AS (
    SELECT b.council_district, i.industry_name, COUNT(*) AS firms
    FROM business AS b
    JOIN business_industry AS bi ON bi.business_id = b.business_id
    JOIN industry          AS i  ON i.industry_id  = bi.industry_id
    WHERE b.in_detroit = 1 AND b.council_district IS NOT NULL
    GROUP BY b.council_district, i.industry_name
),
ranked AS (
    SELECT *, RANK() OVER (PARTITION BY council_district ORDER BY firms DESC) AS rnk
    FROM district_industry
)
SELECT council_district,
       GROUP_CONCAT(industry_name, ' | ') AS leading_industries,
       MAX(firms)                         AS firms_in_leading_industry
FROM ranked
WHERE rnk = 1
GROUP BY council_district
ORDER BY council_district;

-- Q4: District x industry matrix for the 8 biggest industries (pivot with conditional
--     aggregation). Zeros mark places with no certified supplier in that trade.
WITH detroit_firms AS (
    SELECT business_id, council_district
    FROM business
    WHERE in_detroit = 1 AND council_district IS NOT NULL
),
top_industries AS (
    SELECT bi.industry_id, i.industry_name, COUNT(*) AS total_firms
    FROM business_industry AS bi
    JOIN industry AS i USING (industry_id)
    JOIN detroit_firms USING (business_id)
    GROUP BY bi.industry_id, i.industry_name
    ORDER BY total_firms DESC, i.industry_name
    LIMIT 8
)
SELECT t.industry_name,
       SUM(df.council_district = 1) AS d1,
       SUM(df.council_district = 2) AS d2,
       SUM(df.council_district = 3) AS d3,
       SUM(df.council_district = 4) AS d4,
       SUM(df.council_district = 5) AS d5,
       SUM(df.council_district = 6) AS d6,
       SUM(df.council_district = 7) AS d7,
       t.total_firms
FROM top_industries AS t
JOIN business_industry AS bi ON bi.industry_id = t.industry_id
JOIN detroit_firms     AS df ON df.business_id = bi.business_id
GROUP BY t.industry_id, t.industry_name, t.total_firms
ORDER BY t.total_firms DESC, t.industry_name;

-- Q5: Coverage gaps: industry x district combinations with zero certified firms, limited to
--     industries with at least 8 Detroit firms. Skills: CROSS JOIN to build the full grid,
--     LEFT JOIN to find what is missing.
WITH districts (council_district) AS (
    VALUES (1), (2), (3), (4), (5), (6), (7)
),
detroit_firms AS (
    SELECT business_id, council_district
    FROM business
    WHERE in_detroit = 1 AND council_district IS NOT NULL
),
counts AS (
    SELECT bi.industry_id, df.council_district, COUNT(*) AS firms
    FROM business_industry AS bi
    JOIN detroit_firms AS df USING (business_id)
    GROUP BY bi.industry_id, df.council_district
),
big_industries AS (
    SELECT industry_id, SUM(firms) AS total_firms
    FROM counts
    GROUP BY industry_id
    HAVING SUM(firms) >= 8
)
SELECT i.industry_name, d.council_district, bi.total_firms AS citywide_firms
FROM big_industries AS bi
JOIN industry AS i USING (industry_id)
CROSS JOIN districts AS d
LEFT JOIN counts AS c
       ON c.industry_id = bi.industry_id AND c.council_district = d.council_district
WHERE c.firms IS NULL
ORDER BY bi.total_firms DESC, i.industry_name, d.council_district;

-- Q6: Renewal risk: how many certifications are expired or close to expiring?
--     Skills: parameter CTE, date math, CASE bucketing.
WITH params AS (
    SELECT DATE('2026-10-19') AS as_of
),
aged AS (
    SELECT b.*,
           CAST(julianday(b.cert_expires) - julianday(p.as_of) AS INTEGER) AS days_left
    FROM business AS b
    CROSS JOIN params AS p
)
SELECT CASE
           WHEN days_left < 0    THEN '1. Expired before as-of date'
           WHEN days_left <= 30  THEN '2. Expires in 0-30 days'
           WHEN days_left <= 90  THEN '3. Expires in 31-90 days'
           WHEN days_left <= 180 THEN '4. Expires in 91-180 days'
           ELSE                       '5. Expires in 181+ days'
       END AS renewal_bucket,
       COUNT(*) AS firms,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM aged
GROUP BY renewal_bucket
ORDER BY renewal_bucket;

-- Q7: Renewal risk by council district: share of each district's firms that are expired or
--     expire within 90 days. Skills: conditional aggregation, ratio per group.
WITH params AS (
    SELECT DATE('2026-10-19') AS as_of
)
SELECT b.council_district,
       COUNT(*) AS firms,
       SUM(julianday(b.cert_expires) - julianday(p.as_of) <= 90) AS at_risk_90d,
       ROUND(100.0 * SUM(julianday(b.cert_expires) - julianday(p.as_of) <= 90) / COUNT(*), 1) AS at_risk_pct
FROM business AS b
CROSS JOIN params AS p
WHERE b.in_detroit = 1 AND b.council_district IS NOT NULL
GROUP BY b.council_district
ORDER BY at_risk_pct DESC, b.council_district;

-- Q8: Expiry calendar: firms expiring each month, running total, and change from prior month.
--     Skills: strftime, window functions (SUM OVER, LAG).
WITH monthly AS (
    SELECT strftime('%Y-%m', cert_expires) AS expiry_month, COUNT(*) AS expiring
    FROM business
    GROUP BY expiry_month
)
SELECT expiry_month,
       expiring,
       SUM(expiring) OVER (ORDER BY expiry_month)             AS running_total,
       expiring - LAG(expiring) OVER (ORDER BY expiry_month)  AS change_vs_prev_month
FROM monthly
ORDER BY expiry_month;

-- Q9: Dual-certified (MBE + WBE) share by industry, industries with 8+ firms only.
--     Skills: EXISTS / conditional aggregation over a bridge table.
SELECT i.industry_name,
       COUNT(*) AS firms,
       SUM(EXISTS (SELECT 1 FROM business_certification c
                   WHERE c.business_id = bi.business_id AND c.cert_code = 'WBE')) AS also_wbe,
       ROUND(100.0 * SUM(EXISTS (SELECT 1 FROM business_certification c
                                 WHERE c.business_id = bi.business_id AND c.cert_code = 'WBE'))
                   / COUNT(*), 1) AS pct_also_wbe
FROM business_industry AS bi
JOIN industry AS i USING (industry_id)
GROUP BY i.industry_id, i.industry_name
HAVING COUNT(*) >= 8
ORDER BY pct_also_wbe DESC, firms DESC;

-- Q10: Which certification codes travel together? Pair counts via a self-join on the bridge
--      table (a.cert_code < b.cert_code avoids duplicate and mirrored pairs).
SELECT a.cert_code AS cert_a,
       b.cert_code AS cert_b,
       COUNT(*)    AS firms_with_both
FROM business_certification AS a
JOIN business_certification AS b
  ON a.business_id = b.business_id AND a.cert_code < b.cert_code
GROUP BY a.cert_code, b.cert_code
ORDER BY firms_with_both DESC, cert_a, cert_b
LIMIT 10;

-- Q11: Generalists: firms certified in 4+ industries.
--      Skills: GROUP BY / HAVING, GROUP_CONCAT.
SELECT b.business_name,
       b.council_district,
       COUNT(*) AS industries,
       GROUP_CONCAT(i.industry_name, ' | ') AS industry_list
FROM business AS b
JOIN business_industry AS bi ON bi.business_id = b.business_id
JOIN industry          AS i  ON i.industry_id  = bi.industry_id
GROUP BY b.business_id, b.business_name, b.council_district
HAVING COUNT(*) >= 4
ORDER BY industries DESC, b.business_name;

-- Q12: Thin supply: industries with 0-2 Detroit-based certified firms, and who they are.
--      The Detroit filter sits inside a subquery so that industries with ZERO Detroit firms
--      still appear (a plain inner join + WHERE would silently drop them).
--      Skills: LEFT JOIN to a filtered subquery, COUNT(col) vs COUNT(*), COALESCE.
SELECT i.industry_name,
       COUNT(d.business_name) AS detroit_firms,
       COALESCE(GROUP_CONCAT(d.business_name, ' | '), '(none)') AS firms
FROM industry AS i
LEFT JOIN (
    SELECT bi.industry_id, b.business_name
    FROM business_industry AS bi
    JOIN business AS b ON b.business_id = bi.business_id
    WHERE b.in_detroit = 1
) AS d ON d.industry_id = i.industry_id
GROUP BY i.industry_id, i.industry_name
HAVING COUNT(d.business_name) <= 2
ORDER BY detroit_firms, i.industry_name;

-- =====================================================================
-- 04_wbe_analysis.sql
-- Deep dive: Woman-Owned Business Enterprises (WBE) in the certified register.
--
-- Business question:
--   How large is the WBE segment, where and in which industries is it
--   concentrated or thin, how does it differ from non-WBE firms, and which WBE
--   certifications need renewal attention soonest?
--
-- Important scope note: every firm in this register also holds an MBE
-- certification, so "WBE" here means certified firms that are BOTH minority-owned
-- and woman-owned. Women-owned firms without MBE certification are not in this data.
--
-- Conventions: same as 03_analysis.sql. Detroit district analysis uses
-- in_detroit = 1 AND council_district IS NOT NULL. Renewal analysis uses a fixed
-- as-of date (2026-10-19) so results are reproducible.
-- =====================================================================

-- A reusable view: one row per firm plus a 0/1 WBE flag.
DROP VIEW IF EXISTS business_flags;
CREATE VIEW business_flags AS
SELECT b.*,
       EXISTS (SELECT 1
               FROM business_certification AS c
               WHERE c.business_id = b.business_id
                 AND c.cert_code = 'WBE') AS is_wbe
FROM business AS b;

-- Q1: Size of the WBE segment overall and within Detroit.
SELECT COUNT(*)                                          AS total_firms,
       SUM(is_wbe)                                       AS wbe_firms,
       ROUND(100.0 * SUM(is_wbe) / COUNT(*), 1)          AS wbe_pct_of_register,
       SUM(is_wbe AND in_detroit = 1)                    AS wbe_in_detroit,
       SUM(in_detroit = 1)                               AS detroit_firms,
       ROUND(100.0 * SUM(is_wbe AND in_detroit = 1)
                   / SUM(in_detroit = 1), 1)             AS wbe_pct_of_detroit_firms
FROM business_flags;

-- Q2: WBE share by council district, compared with the Detroit average.
--     Skills: aggregation, window functions over the whole result (SUM OVER ()), RANK.
WITH district_counts AS (
    SELECT council_district,
           COUNT(*)    AS firms,
           SUM(is_wbe) AS wbe_firms
    FROM business_flags
    WHERE in_detroit = 1 AND council_district IS NOT NULL
    GROUP BY council_district
)
SELECT council_district,
       firms,
       wbe_firms,
       ROUND(100.0 * wbe_firms / firms, 1)                                         AS wbe_pct_in_district,
       ROUND(100.0 * SUM(wbe_firms) OVER () / SUM(firms) OVER (), 1)               AS detroit_avg_pct,
       ROUND(100.0 * wbe_firms / firms
             - 100.0 * SUM(wbe_firms) OVER () / SUM(firms) OVER (), 1)             AS pts_vs_detroit_avg,
       RANK() OVER (ORDER BY 1.0 * wbe_firms / firms DESC)                         AS rank_by_wbe_share
FROM district_counts
ORDER BY wbe_pct_in_district DESC, council_district;

-- Q3: WBE presence by industry (industries with 5+ firms).
--     Two different denominators on purpose:
--       pct_of_industry   = how WBE-heavy the industry is
--       pct_of_all_wbe    = where WBE firms actually are
SELECT i.industry_name,
       COUNT(*)                                                                   AS firms,
       SUM(bf.is_wbe)                                                             AS wbe_firms,
       ROUND(100.0 * SUM(bf.is_wbe) / COUNT(*), 1)                                AS pct_of_industry,
       ROUND(100.0 * SUM(bf.is_wbe)
                   / (SELECT SUM(is_wbe) FROM business_flags), 1)                 AS pct_of_all_wbe,
       ROUND(100.0 * SUM(bf.is_wbe) / COUNT(*)
             - (SELECT 100.0 * SUM(is_wbe) / COUNT(*) FROM business_flags), 1)    AS pts_vs_register_avg
FROM business_industry AS bi
JOIN industry       AS i  ON i.industry_id  = bi.industry_id
JOIN business_flags AS bf ON bf.business_id = bi.business_id
GROUP BY i.industry_id, i.industry_name
HAVING COUNT(*) >= 5
ORDER BY wbe_firms DESC, pct_of_industry DESC;

-- Q4: How do WBE firms differ from non-WBE firms in their other certifications?
--     Skills: joining the dimension (certification) to the bridge and the flag view,
--     conditional aggregation, scalar subqueries for the denominators.
WITH group_sizes AS (
    SELECT is_wbe, COUNT(*) AS n
    FROM business_flags
    GROUP BY is_wbe
)
SELECT c.cert_code,
       COALESCE(c.description, '(definition not confirmed)')                       AS description,
       SUM(bf.is_wbe = 1)                                                          AS wbe_firms_holding,
       ROUND(100.0 * SUM(bf.is_wbe = 1) / (SELECT n FROM group_sizes WHERE is_wbe = 1), 1) AS pct_of_wbe_firms,
       ROUND(100.0 * SUM(bf.is_wbe = 0) / (SELECT n FROM group_sizes WHERE is_wbe = 0), 1) AS pct_of_non_wbe_firms
FROM business_certification AS bc
JOIN certification  AS c  ON c.cert_code    = bc.cert_code
JOIN business_flags AS bf ON bf.business_id = bc.business_id
WHERE c.cert_code NOT IN ('MBE', 'WBE')
GROUP BY c.cert_code, c.description
ORDER BY pct_of_wbe_firms DESC;

-- Q5: Side-by-side profile: WBE vs non-WBE firms.
--     Skills: correlated subqueries per firm, then AVG per group.
WITH per_firm AS (
    SELECT bf.business_id,
           bf.is_wbe,
           bf.in_detroit,
           (SELECT COUNT(*) FROM business_industry      WHERE business_id = bf.business_id) AS n_industries,
           (SELECT COUNT(*) FROM business_certification WHERE business_id = bf.business_id) AS n_certs
    FROM business_flags AS bf
)
SELECT CASE is_wbe WHEN 1 THEN 'WBE' ELSE 'Not WBE' END AS firm_group,
       COUNT(*)                                          AS firms,
       ROUND(AVG(n_industries), 2)                       AS avg_industries_per_firm,
       ROUND(AVG(n_certs), 2)                            AS avg_certifications_per_firm,
       ROUND(100.0 * AVG(in_detroit), 1)                 AS pct_in_detroit
FROM per_firm
GROUP BY is_wbe
ORDER BY is_wbe DESC;

-- Q6: Start-ups and micro/small businesses: how WBE-heavy are the youngest and smallest
--     segments? One row per size/stage certification.
SELECT c.cert_code,
       c.description,
       COUNT(*)                                       AS firms_with_cert,
       SUM(bf.is_wbe)                                 AS wbe_firms,
       ROUND(100.0 * SUM(bf.is_wbe) / COUNT(*), 1)    AS wbe_pct
FROM business_certification AS bc
JOIN certification  AS c  ON c.cert_code    = bc.cert_code
JOIN business_flags AS bf ON bf.business_id = bc.business_id
WHERE c.cert_code IN ('DSU', 'DBMB', 'DSB')
GROUP BY c.cert_code, c.description
ORDER BY wbe_pct DESC;

-- Q7: Renewal outreach list: WBE firms that are expired or expire within 90 days.
--     Skills: parameter CTE, date arithmetic, CASE labels, ORDER BY urgency.
WITH params AS (
    SELECT DATE('2026-10-19') AS as_of
)
SELECT b.business_name,
       b.council_district,
       b.cert_expires,
       CAST(julianday(b.cert_expires) - julianday(p.as_of) AS INTEGER) AS days_left,
       CASE WHEN b.cert_expires < p.as_of THEN 'Expired' ELSE 'Expiring within 90 days' END AS status
FROM business_flags AS b
CROSS JOIN params AS p
WHERE b.is_wbe = 1
  AND julianday(b.cert_expires) - julianday(p.as_of) <= 90
ORDER BY b.cert_expires, b.business_name;

-- Q8: WBE renewal pipeline by month: WBE expiries each month, running total, and what share
--     of all that month's expiries are WBE. Skills: strftime, SUM OVER, ratio of two counts.
SELECT strftime('%Y-%m', cert_expires)                                AS expiry_month,
       COUNT(*)                                                       AS all_expiring,
       SUM(is_wbe)                                                    AS wbe_expiring,
       SUM(SUM(is_wbe)) OVER (ORDER BY strftime('%Y-%m', cert_expires)) AS wbe_running_total,
       ROUND(100.0 * SUM(is_wbe) / COUNT(*), 1)                       AS wbe_share_of_month
FROM business_flags
GROUP BY expiry_month
ORDER BY expiry_month;

# Detroit Certified Business Register: SQL Analysis

**Question:** Where is Detroit's certified-business base concentrated, which industries and council districts are thin, and how much of the register is about to lapse?

**Tools:** SQL (SQLite 3.25+), Python standard library only for loading.
**Data:** Certified Business Register, 132 firms, 11 columns. Source: *https://data.detroitmi.gov/datasets/9f6b399045dd4f5991835a65a1b20b7f_0/explore?location=42.361858%2C-83.099691%2C10 9/28/2026*.

## What this project demonstrates

| Skill | Where |
|---|---|
| Staging table, then a cleaned and constrained relational model | `sql/01_load_and_clean.sql` |
| Data cleaning in SQL (case, spelling variants, nulls, date parsing) | `sql/01_load_and_clean.sql` |
| Normalizing multi-value text columns (recursive CTE and token matching) | `sql/01_load_and_clean.sql` |
| Validation queries that prove the cleaning did not lose data | end of `01`, plus `02` |
| Data quality profiling and audit | `sql/02_data_quality.sql` |
| Joins, CTEs, window functions (`RANK`, `SUM OVER`, `LAG`), pivots, `CROSS JOIN` gap analysis | `sql/03_analysis.sql` |

## Data model

```
business ──< business_industry >── industry
    │
    └──< business_certification >── certification
```

The source file packs several industries and certification codes into single comma-separated cells. Those become two bridge tables so that "how many firms are in industry X" is a plain `GROUP BY`.

Two different splitting techniques were needed, on purpose:

- **Certifications** (`DBB, DHB, MBE`) have no embedded commas, so a recursive CTE splits them.
- **Industries** contain commas inside category names (`Real Estate, Planning, & Development`), so splitting on commas would break them. Instead each of the 27 known categories is matched against the delimited string. A validation query rebuilds each firm's industry string from the matches and confirms nothing was lost or misread (0 mismatches).

## Cleaning decisions

| Problem in raw data | Fix |
|---|---|
| 9 spellings of the state (`MI`, `Michigan`, `MICHIGAN`, `Mi.`, `Michgan`, ...) | Mapped to `MI` / `MO` / `IL`; an unmapped value would fail a `NOT NULL` constraint |
| City casing and suffixes (`Detroit`, `DETROIT`, `detroit`, `DETROIT, MI`) | Upper-cased, `, MI` stripped |
| 5 missing zip codes | Stored as `NULL`, not guessed |
| Council district `Not Applicable` | `NULL`; district analysis is limited to Detroit addresses |
| Expiry dates as `M/D/YYYY` text | Converted to ISO dates so they sort and compare correctly |
| `Blank` column is 100% empty | Dropped |

## Findings

All numbers come from the queries in `sql/` (run `python3 run_all.py`).

1. **The register is overwhelmingly Detroit-based:** 119 of 132 firms (90.2%) have a Detroit address; 11 are elsewhere in Michigan and 2 are out of state.
2. **Two districts hold two-thirds of the firms.** Of the 118 Detroit firms with a council district, District 5 has 42 (35.6%) and District 6 has 35 (29.7%), 65.3% combined. District 7 has just 6 (5.1%).
3. **Construction and professional services dominate.** Construction appears in 50 firms (37.9%) and professional services in 44 (33.3%). Professional services leads in Districts 5 and 6; construction leads in the rest.
4. **Several trades are concentrated in one or two districts.** All 9 Detroit IT firms are in Districts 5 and 6 (3 and 6), with none in the other five. Property and facility services has no firms in Districts 1, 2 or 7. Demolition has 20 Detroit firms but none in District 6.
5. **Some industries have almost no Detroit supply.** Food and Police, Fire & Rescue have zero Detroit-based firms; Human Services and Industry each have one.
6. **Renewal risk is material.** As of 2026-10-19, 7 certifications are already past their expiry date and 23 more expire within 90 days: 30 firms (22.7%) in total. By district, the share expired or expiring within 90 days is highest in District 3 (40%) and District 4 (33%).
7. **Expiries cluster.** April 2027 is the largest month (23 firms), then September 2027 (18) and January 2027 (16).
8. **Dual MBE and WBE certification varies a lot by trade:** 64% of real estate firms hold both, versus 10% in IT.
9. **Some firms are not independent.** Nine firms share three email addresses (for example four firms under one Brinker address), so the register's firm count slightly overstates the number of distinct owners.

## Caveats

- This is a register of *certified* firms. Every one of the 132 holds an MBE certification, so it describes the certified supplier pool, not all Detroit businesses. Conclusions about "gaps" mean gaps in certified supplier coverage.
- The extract date is unknown. Certifications shown as expired may have been renewed since the file was exported.
- Certification codes (DBB, DHB, DSB, DBMB, DRB, DSU, CWDB, CWIB) are used as-is. Check their definitions against the source's legend before publishing and add them to the `certification` table.
- Four rows have district or address conflicts (three out-of-city addresses carry a council district, one Detroit address has none). They are flagged in `02_data_quality.sql` (Q7) and handled by the Detroit-only filter in the district analysis.
- With 132 rows, percentages move a lot when one firm is added or removed. Treat them as descriptive, not statistical.

## How to run

```bash
python3 run_all.py          # builds detroit_business.db and prints every query result
python3 run_all.py 03       # only show the analysis results
```

To use the `sqlite3` command-line tool or another SQLite client instead, create `stg_register` with the 11 text columns listed in `run_all.py`, import the CSV into it (skipping the header), then run the three scripts in order.

## Repository layout

```
data/        raw CSV (unchanged)
sql/         01_load_and_clean.sql, 02_data_quality.sql, 03_analysis.sql
run_all.py   loader and query runner
README.md
```
## Deep dive: Woman-Owned Business Enterprises (WBE)

`sql/04_wbe_analysis.sql` focuses on the 49 firms (37.1% of the register) that hold a WBE certification. It answers: how big is the WBE segment, where and in which industries is it concentrated or thin, how do WBE firms differ from the rest, and which WBE certifications need renewal attention first?

**Scope note:** every firm in this register also holds an MBE certification, so "WBE" here means certified firms that are both minority-owned and woman-owned. Women-owned firms without MBE certification are not in this data.

### Certification codes

| Code | Meaning |
|---|---|
| DBB | Detroit Based Business |
| DHB | Detroit Headquartered Business |
| DRB | Detroit Resident Business |
| DSB | Detroit Small Business |
| DBMB | Detroit Based Micro Business |
| DSU | Detroit Start-Up |
| MBE | Minority-Owned Business Enterprise |
| WBE | Woman-Owned Business Enterprise |

CWDB and CWIB appear on a handful of firms, but their definitions have not been confirmed, so they are left blank in the `certification` table.

### Additional skills shown

| Skill | Where |
|---|---|
| Reusable view with a computed flag (`EXISTS`) | `business_flags` view |
| Comparing each group to the overall average with window functions | Q2, Q3 |
| Two different denominators in one query (share *of industry* vs share *of all WBE firms*) | Q3 |
| Group-vs-group profiling with conditional aggregation | Q4, Q5, Q6 |
| A ready-to-use action list (renewal outreach) | Q7 |

### Findings

1. **WBE firms are over a third of the register.** 49 of 132 firms (37.1%) hold WBE; 44 of 119 Detroit firms (37.0%).
2. **WBE share varies by council district.** Districts 1, 2 and 7 are each 50% WBE (4 of 8, 4 of 8, 3 of 6). District 3 is lowest at 30% (3 of 10), and District 6, which has the second-most firms overall, is 31.4% (11 of 35). District counts are small, so treat differences as directional.
3. **WBE firms cluster in a few industries by count.** Professional services (18 WBE firms), construction (14) and demolition (11) account for most of them. By share, Events, Arts & Culture (4 of 5), Real Estate (7 of 11) and Water & Sewage (4 of 7) are the most WBE-heavy, while Information Technology (1 of 10), Energy (1 of 5) and Safety & Security (2 of 9) are the thinnest.
4. **WBE firms skew toward start-ups.** 6 of the 8 Detroit Start-Up (DSU) firms are WBE (75%). 12.2% of WBE firms hold DSU, versus 2.4% of other firms.
5. **WBE firms hold fewer of the "Detroit-based" designations.** 57.1% of WBE firms hold DBB versus 74.7% of non-WBE firms (DHB 51.0% vs 68.7%; DSB 26.5% vs 38.6%), even though the share with a Detroit address is almost identical (89.8% vs 90.4%). This is an open question worth investigating: whether these designations are separate eligibility tracks, and whether WBE firms are less likely to apply for or qualify for them.
6. **WBE firms are slightly broader.** On average they list 2.16 industries and 3.84 certifications, compared with 1.78 and 3.13 for other firms (small sample, so treat as indicative).
7. **11 WBE firms need renewal attention now.** As of 2026-10-19, 3 WBE certifications are already past their expiry date and 8 more expire within 90 days. The query returns them in order of urgency. June 2027 stands out later in the pipeline: 7 of the 10 certifications expiring that month are WBE.

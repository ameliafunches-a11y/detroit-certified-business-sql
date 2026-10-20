"""Build the SQLite database and run the SQL scripts, printing every query result.

Usage:  python3 run_all.py            (builds detroit_business.db, runs all scripts)
        python3 run_all.py 03         (only print results for scripts starting with 03)

Only the Python standard library is needed.
"""
import csv
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).parent
CSV_PATH = ROOT / "data" / "Certified_Business_Register_data.csv"
DB_PATH = ROOT / "detroit_business.db"
SQL_DIR = ROOT / "sql"

STG_COLUMNS = [
    "business_name", "industry_type", "certifications", "address", "city",
    "state", "zip_code", "council_district", "email", "cert_expires", "blank",
]


def load_staging(con):
    """Raw load: every column TEXT, nothing cleaned. Cleaning happens in SQL."""
    con.execute("DROP TABLE IF EXISTS stg_register")
    con.execute("CREATE TABLE stg_register (%s)" % ", ".join(f"{c} TEXT" for c in STG_COLUMNS))
    with open(CSV_PATH, newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        next(reader)  # skip header
        rows = [r for r in reader if any(cell.strip() for cell in r)]
    con.executemany(
        "INSERT INTO stg_register VALUES (%s)" % ", ".join("?" * len(STG_COLUMNS)), rows
    )
    con.commit()


def split_statements(sql_text):
    """Split a script into statements, keeping the comment block directly above each."""
    statements, buf = [], ""
    for line in sql_text.splitlines(keepends=True):
        buf += line
        if sqlite3.complete_statement(buf):
            statements.append(buf.strip())
            buf = ""
    return statements


def print_table(cur):
    if cur.description is None:
        return
    headers = [d[0] for d in cur.description]
    rows = cur.fetchall()
    widths = [max(len(str(h)), *(len(str(r[i])) for r in rows)) if rows else len(str(h))
              for i, h in enumerate(headers)]
    widths = [min(w, 60) for w in widths]
    line = " | ".join(str(h).ljust(w) for h, w in zip(headers, widths))
    print(line)
    print("-+-".join("-" * w for w in widths))
    for r in rows:
        print(" | ".join(str(v)[:60].ljust(w) for v, w in zip(r, widths)))
    print(f"({len(rows)} rows)\n")


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    con = sqlite3.connect(DB_PATH)
    load_staging(con)
    for script in sorted(SQL_DIR.glob("*.sql")):
        if only and not script.name.startswith(only) and not script.name.startswith("01"):
            continue
        show = (only is None) or script.name.startswith(only)
        print("=" * 70)
        print(script.name)
        print("=" * 70)
        for stmt in split_statements(script.read_text()):
            first = next((l for l in stmt.splitlines() if l.startswith("-- Q") or l.startswith("-- V")), None)
            cur = con.execute(stmt)
            if cur.description is not None and show:
                if first:
                    print(first)
                print_table(cur)
        con.commit()
    con.close()
    print(f"Database written to {DB_PATH}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
weekly_refresh.py
=================
The automated weekly reporting cycle, end to end:

    1. Extract   take this week's extract (here: regenerate the synthetic source as of today)
    2. Validate  run the data-quality gate (pipeline/validate.py)
    3. Load      if the gate passed, reload SQL Server in one transaction
    4. Refresh   Power BI picks the new data up on its scheduled refresh

If validation fails, steps 3-4 are skipped and the dashboards keep showing
last week's good data. The DQ report in reports/ says what went wrong.

Usage
-----
    python pipeline/weekly_refresh.py                         # extract + validate only
    python pipeline/weekly_refresh.py --load                  # also load SQL Server
    python pipeline/weekly_refresh.py --as-of 2026-10-19 --load

SQL Server connection (only needed with --load) comes from the environment:
    set EAA_SQL_CONN=Driver={ODBC Driver 18 for SQL Server};Server=localhost;Database=EngineeringActivity;Trusted_Connection=yes;TrustServerCertificate=yes

Schedule it weekly with Windows Task Scheduler (see docs/automation.md).
"""
from __future__ import annotations

import argparse
import logging
import os
import subprocess
import sys
from datetime import date
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate  # noqa: E402

PROCESSED = ROOT / "data" / "processed"
LOG_DIR = ROOT / "logs"

# load order: parents before children (FK constraints); delete in reverse
LOAD_ORDER = [
    "dim_unit", "dim_platform", "dim_function", "dim_location", "dim_state", "dim_date",
    "dim_engineer", "dim_project",
    "fact_activity", "activity_state_history", "fact_timesheet", "fact_escalation",
]


def setup_logging() -> logging.Logger:
    LOG_DIR.mkdir(exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s  %(levelname)-7s %(message)s",
        handlers=[logging.FileHandler(LOG_DIR / "weekly_refresh.log", encoding="utf-8"),
                  logging.StreamHandler(sys.stdout)],
    )
    return logging.getLogger("weekly_refresh")


def extract(as_of: str, log: logging.Logger) -> None:
    """In a real deployment this step would query the source system.
    Here it regenerates the synthetic extract for the given as-of date."""
    log.info("Step 1/3 extract: as of %s", as_of)
    subprocess.run([sys.executable, str(ROOT / "data" / "generate_data.py"), "--as-of", as_of],
                   check=True, capture_output=True, text=True)


def to_rows(df: pd.DataFrame) -> list[tuple]:
    df = df.astype(object).where(df.notna(), None)
    return [tuple(r) for r in df.itertuples(index=False)]


def load_sql(conn_str: str, log: logging.Logger) -> None:
    """Full reload inside a single transaction: either everything loads or nothing changes."""
    import pyodbc  # imported here so extract/validate work without an ODBC driver

    log.info("Step 3/3 load: SQL Server")
    cn = pyodbc.connect(conn_str, autocommit=False)
    try:
        cur = cn.cursor()
        cur.fast_executemany = True
        for table in reversed(LOAD_ORDER):
            cur.execute(f"DELETE FROM dbo.{table};")
        for table in LOAD_ORDER:
            df = pd.read_csv(PROCESSED / f"{table}.csv", dtype=str, keep_default_na=False, na_values=[""])
            cols = ", ".join(f"[{c}]" for c in df.columns)
            marks = ", ".join("?" * len(df.columns))
            cur.executemany(f"INSERT INTO dbo.{table} ({cols}) VALUES ({marks});", to_rows(df))
            log.info("  %-24s %7d rows", table, len(df))

        info = pd.read_csv(PROCESSED / "refresh_info.csv").iloc[0]
        cur.execute(
            "INSERT INTO dbo.etl_refresh_log (as_of_date, dq_status, activities_loaded, rows_quarantined) "
            "VALUES (?, ?, ?, ?);",
            str(info.as_of_date), str(info.dq_status), int(info.clean_activities), int(info.rows_quarantined))
        dq = pd.read_csv(PROCESSED / "dq_check_results.csv", dtype=str)
        cur.execute("SELECT MAX(refresh_id) FROM dbo.etl_refresh_log;")
        refresh_id = cur.fetchone()[0]
        dq.insert(0, "refresh_id", refresh_id)
        cols = ", ".join(f"[{c}]" for c in dq.columns)
        cur.executemany(f"INSERT INTO dbo.dq_check_results ({cols}) VALUES ({', '.join('?' * len(dq.columns))});",
                        to_rows(dq))
        cn.commit()
        log.info("  committed (refresh_id %s)", refresh_id)
    except Exception:
        cn.rollback()
        log.exception("  load failed, rolled back; SQL Server still holds last week's data")
        raise
    finally:
        cn.close()


def main() -> int:
    ap = argparse.ArgumentParser(description="Run the weekly extract -> validate -> load cycle.")
    ap.add_argument("--as-of", default=date.today().isoformat())
    ap.add_argument("--skip-extract", action="store_true", help="validate the existing data/raw extract")
    ap.add_argument("--load", action="store_true", help="load SQL Server (needs EAA_SQL_CONN)")
    args = ap.parse_args()
    log = setup_logging()

    if not args.skip_extract:
        extract(args.as_of, log)

    log.info("Step 2/3 validate")
    try:
        s = validate.run()
    except validate.ExtractError as e:
        log.error("  extract unusable: %s. Nothing loaded.", e)
        return 2
    log.info("  [%s] %d clean activities, %d quarantined (%.1f%%), %d timesheet rows quarantined",
             s["status"], s["clean_activities"], s["rejected_activities"], s["reject_pct"], s["rejected_timesheets"])
    if s["status"] == "FAIL":
        log.error("  too many rejected rows: load skipped, dashboards keep last week's data. See reports/.")
        return 1

    if args.load:
        conn = os.environ.get("EAA_SQL_CONN")
        if not conn:
            log.error("  --load given but EAA_SQL_CONN is not set")
            return 3
        load_sql(conn, log)
    else:
        log.info("Step 3/3 load: skipped (run with --load, or run sql/02_load.sql in SSMS)")

    log.info("Done. Power BI picks up the new data on its next scheduled refresh.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""
validate.py
===========
Data-quality gate between the raw extract (data/raw/) and the clean,
load-ready tables (data/processed/).

For every weekly run it:
  1. checks the extract has every expected table and column (stops if not)
  2. removes exact duplicate rows
  3. quarantines activity rows that break a rule (missing keys, invalid state,
     orphan foreign keys, impossible dates, state/date mismatch, conflicting duplicates)
  4. fixes rows where the correction is unambiguous (percent_complete clipped to 0-100)
  5. drops child rows (history, timesheets, escalations) whose activity was quarantined
  6. reconciles the activity table against the state-history table
  7. compares this week's volume with last week's and warns on a big swing
  8. stops the refresh (circuit breaker) if too many rows are rejected,
     so a bad extract never overwrites last week's good data

Outputs
  data/processed/*.csv              clean tables, ready to load into SQL Server
  data/processed/dq_check_results.csv   this run's check results (loaded to SQL for the DQ page)
  data/quarantine/*.csv             rejected rows with the reason they were rejected
  reports/dq_report_<as_of>.md      human-readable summary
  reports/dq_run_log.csv            one line per run, used for the week-on-week volume check
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]

VALID_STATES = ["Proposed", "Planning", "Active", "Review", "Report", "Closed"]
IN_FLIGHT = {"Active", "Review", "Report"}

DIM_TABLES = ["dim_unit", "dim_platform", "dim_function", "dim_location", "dim_state",
              "dim_engineer", "dim_project", "dim_date"]
FACT_TABLES = ["fact_activity", "activity_state_history", "fact_timesheet", "fact_escalation"]

REQUIRED_COLUMNS = {
    "fact_activity": ["activity_id", "project_id", "activity_title", "function_id", "activity_engineer_id",
                      "guide_approver_id", "location_id", "state", "created_date", "start_date",
                      "deadline_date", "report_date", "closed_date", "percent_complete", "planned_hours"],
    "activity_state_history": ["activity_id", "state", "valid_from", "valid_to"],
    "fact_timesheet": ["timesheet_id", "week_start", "engineer_id", "activity_id", "hours"],
    "fact_escalation": ["escalation_id", "activity_id", "escalation_date", "reason", "raised_by"],
    "dim_engineer": ["engineer_id", "engineer_name", "home_function_id", "location_id", "role",
                     "capacity_activities", "is_active"],
    "dim_project": ["project_id", "project_title", "unit_id", "platform_id", "project_start_date"],
}
ACTIVITY_DATES = ["created_date", "start_date", "deadline_date", "report_date", "closed_date"]

MAX_REJECT_PCT = 5.0      # circuit breaker: stop if more than this % of activities is rejected
MAX_VOLUME_SWING = 0.20   # warn if clean activity count moves more than 20% week on week


@dataclass
class CheckLog:
    as_of: str
    results: list[dict] = field(default_factory=list)

    def add(self, table: str, check: str, severity: str, rows: int, action: str) -> None:
        self.results.append({"as_of_date": self.as_of, "table_name": table, "check_name": check,
                             "severity": severity, "rows_affected": int(rows), "action": action,
                             "status": "PASS" if rows == 0 else severity})

    def frame(self) -> pd.DataFrame:
        return pd.DataFrame(self.results)


class ExtractError(Exception):
    """Raised when the extract is structurally unusable."""


def read(raw_dir: Path, name: str) -> pd.DataFrame:
    path = raw_dir / f"{name}.csv"
    if not path.exists():
        raise ExtractError(f"missing table: {path.name}")
    return pd.read_csv(path, dtype=str, keep_default_na=False, na_values=[""])


def check_columns(name: str, df: pd.DataFrame) -> None:
    missing = [c for c in REQUIRED_COLUMNS.get(name, []) if c not in df.columns]
    if missing:
        raise ExtractError(f"{name} is missing columns: {missing}")


def flag(reasons: pd.Series, mask: pd.Series, reason: str) -> int:
    """Append a reason to every row where mask is True. Returns number of rows newly hit."""
    mask = mask.fillna(False)
    reasons.loc[mask] = reasons.loc[mask].where(reasons.loc[mask] == "", reasons.loc[mask] + "; ") + reason
    return int(mask.sum())


def validate_activities(act: pd.DataFrame, dims: dict, log: CheckLog):
    """Returns (clean activities, rejected activities with reason column)."""
    n_raw = len(act)

    # exact duplicates: same row sent twice -> keep one copy
    exact_dupes = act.duplicated(keep="first")
    log.add("fact_activity", "Exact duplicate rows", "WARN", exact_dupes.sum(), "removed (kept first copy)")
    act = act[~exact_dupes].copy()

    
    # standardise state spelling: 'closed ' -> 'Closed' (unambiguous fix, logged)
    cleaned = act["state"].str.strip().str.capitalize()
    changed = act["state"].notna() & (cleaned != act["state"]) & cleaned.isin(VALID_STATES)
    log.add("fact_activity", "State spelling standardised", "WARN", changed.sum(), "fixed (trim + capitalise)")
    act["state"] = cleaned

    dates = {c: pd.to_datetime(act[c], errors="coerce") for c in ACTIVITY_DATES}
    pct = pd.to_numeric(act["percent_complete"], errors="coerce")
    reasons = pd.Series("", index=act.index)

    checks = [
        ("Conflicting duplicate activity_id", act.duplicated("activity_id", keep=False),
         "duplicate activity_id with different values"),
        ("Missing mandatory field",
         act[["activity_id", "project_id", "function_id", "activity_engineer_id", "state", "created_date"]].isna().any(axis=1),
         "mandatory field missing"),
        ("Invalid state value", act["state"].notna() & ~act["state"].isin(VALID_STATES), "state not in allowed list"),
        ("Orphan project_id", act["project_id"].notna() & ~act["project_id"].isin(dims["dim_project"]["project_id"]),
         "project not found"),
        ("Orphan function_id", act["function_id"].notna() & ~act["function_id"].isin(dims["dim_function"]["function_id"]),
         "function not found"),
        ("Orphan activity engineer",
         act["activity_engineer_id"].notna() & ~act["activity_engineer_id"].isin(dims["dim_engineer"]["engineer_id"]),
         "activity engineer not found"),
        ("Orphan guide/approver",
         act["guide_approver_id"].notna() & ~act["guide_approver_id"].isin(dims["dim_engineer"]["engineer_id"]),
         "guide/approver not found"),
        ("Start date before created date", dates["start_date"] < dates["created_date"], "started before it was created"),
        ("Closed date before start date", dates["closed_date"] < dates["start_date"], "closed before it started"),
        ("Closed without closed date", (act["state"] == "Closed") & dates["closed_date"].isna(), "Closed but no closed_date"),
        ("In-flight without start date", act["state"].isin(IN_FLIGHT) & dates["start_date"].isna(),
         "in-flight state but no start_date"),
    ]
    for check, mask, reason in checks:
        hit = flag(reasons, mask, reason)
        log.add("fact_activity", check, "ERROR", hit, "quarantined")

    rejected_mask = reasons != ""
    rejected = act[rejected_mask].assign(reject_reason=reasons[rejected_mask])
    clean = act[~rejected_mask].copy()

    # unambiguous fix: clip percent_complete into range
    pct_clean = pd.to_numeric(clean["percent_complete"], errors="coerce")
    out_of_range = (pct_clean < 0) | (pct_clean > 100)
    log.add("fact_activity", "percent_complete outside 0-100", "WARN", out_of_range.sum(), "clipped to 0-100")
    clean["percent_complete"] = pct_clean.clip(0, 100).astype("Int64")

    # soft rule: deadline before created date is suspicious but not fatal
    dl_before = pd.to_datetime(clean["deadline_date"]) < pd.to_datetime(clean["created_date"])
    log.add("fact_activity", "Deadline before created date", "WARN", dl_before.sum(), "kept, flagged for owner")

    log.add("fact_activity", "Rows received", "INFO", 0, f"{n_raw} raw rows -> {len(clean)} clean")
    return clean, rejected


def validate_children(raw: dict, clean_ids: set, all_ids: set, dims: dict, log: CheckLog):
    """History, timesheets and escalations: drop rows of quarantined activities, check their own rules."""
    out, quarantined = {}, {}

    # --- state history
    hist = raw["activity_state_history"].drop_duplicates()
    parent_out = ~hist["activity_id"].isin(clean_ids)
    log.add("activity_state_history", "Parent activity quarantined", "INFO", parent_out.sum(), "excluded")
    out["activity_state_history"] = hist[~parent_out]

    # --- timesheets
    ts = raw["fact_timesheet"]
    dupes = ts.duplicated(keep="first")
    log.add("fact_timesheet", "Exact duplicate rows", "WARN", dupes.sum(), "removed (kept first copy)")
    ts = ts[~dupes].copy()
    hours = pd.to_numeric(ts["hours"], errors="coerce")
    reasons = pd.Series("", index=ts.index)
    log.add("fact_timesheet", "Hours not positive", "ERROR",
            flag(reasons, ~(hours > 0), "hours <= 0 or not a number"), "quarantined")
    log.add("fact_timesheet", "Hours above 60 in a week", "ERROR",
            flag(reasons, hours > 60, "more than 60 hours in one week"), "quarantined")
    log.add("fact_timesheet", "Orphan activity_id", "ERROR",
            flag(reasons, ~ts["activity_id"].isin(all_ids), "activity not found"), "quarantined")
    log.add("fact_timesheet", "Orphan engineer_id", "ERROR",
            flag(reasons, ~ts["engineer_id"].isin(dims["dim_engineer"]["engineer_id"]), "engineer not found"),
            "quarantined")
    bad = reasons != ""
    quarantined["fact_timesheet"] = ts[bad].assign(reject_reason=reasons[bad])
    ts = ts[~bad]
    parent_out = ~ts["activity_id"].isin(clean_ids)
    log.add("fact_timesheet", "Parent activity quarantined", "INFO", parent_out.sum(), "excluded")
    out["fact_timesheet"] = ts[~parent_out]

    # --- escalations
    esc = raw["fact_escalation"].drop_duplicates()
    orphan = ~esc["activity_id"].isin(all_ids)
    log.add("fact_escalation", "Orphan activity_id", "ERROR", orphan.sum(), "quarantined")
    quarantined["fact_escalation"] = esc[orphan].assign(reject_reason="activity not found")
    esc = esc[~orphan]
    parent_out = ~esc["activity_id"].isin(clean_ids)
    log.add("fact_escalation", "Parent activity quarantined", "INFO", parent_out.sum(), "excluded")
    out["fact_escalation"] = esc[~parent_out]

    return out, quarantined


def reconcile(clean_act: pd.DataFrame, hist: pd.DataFrame, log: CheckLog) -> None:
    """Current state in the activity table must match the open row in the history table."""
    current = hist[hist["valid_to"].isna()][["activity_id", "state"]].rename(columns={"state": "history_state"})
    merged = clean_act[["activity_id", "state"]].merge(current, on="activity_id", how="left")
    mismatch = merged["history_state"].isna() | (merged["state"] != merged["history_state"])
    log.add("fact_activity", "State does not match history", "WARN", mismatch.sum(), "kept, flagged for owner")


def volume_check(n_clean: int, run_log_path: Path, log: CheckLog) -> None:
    if not run_log_path.exists():
        log.add("fact_activity", "Week-on-week volume swing > 20%", "WARN", 0, "first run, no baseline")
        return
    hist = pd.read_csv(run_log_path)
    hist = hist[hist["dq_status"] != "FAIL"]
    if hist.empty:
        return
    prev = int(hist.iloc[-1]["clean_activities"])
    swing = abs(n_clean - prev) / max(prev, 1)
    log.add("fact_activity", "Week-on-week volume swing > 20%", "WARN", int(swing > MAX_VOLUME_SWING),
            f"previous run {prev}, this run {n_clean} ({swing:+.0%})")


def write_report(path: Path, log: CheckLog, status: str, summary: dict) -> None:
    df = log.frame()
    lines = [
        f"# Data quality report — extract as of {log.as_of}",
        "",
        f"**Status: {status}**  ",
        f"Run at {datetime.now():%Y-%m-%d %H:%M}",
        "",
        f"- Raw activity rows: {summary['raw_activities']}",
        f"- Clean activities loaded: {summary['clean_activities']}",
        f"- Activities quarantined: {summary['rejected_activities']} ({summary['reject_pct']:.1f}%, limit {MAX_REJECT_PCT}%)",
        f"- Timesheet rows quarantined: {summary['rejected_timesheets']}",
        "",
        "| Table | Check | Severity | Rows | Action |",
        "|---|---|---|---:|---|",
    ]
    for r in df.itertuples():
        sev = "PASS" if r.rows_affected == 0 and r.severity != "INFO" else r.severity
        lines.append(f"| {r.table_name} | {r.check_name} | {sev} | {r.rows_affected} | {r.action} |")
    lines += ["", "Quarantined rows, with the reason for each, are in `data/quarantine/`."]
    path.write_text("\n".join(lines), encoding="utf-8")


def run(raw_dir: Path = ROOT / "data" / "raw",
        processed_dir: Path = ROOT / "data" / "processed",
        quarantine_dir: Path = ROOT / "data" / "quarantine",
        reports_dir: Path = ROOT / "reports",
        max_reject_pct: float = MAX_REJECT_PCT) -> dict:
    for d in (processed_dir, quarantine_dir, reports_dir):
        d.mkdir(parents=True, exist_ok=True)

    info = read(raw_dir, "extract_info")
    as_of = info.loc[0, "as_of_date"]
    log = CheckLog(as_of=as_of)

    raw = {name: read(raw_dir, name) for name in DIM_TABLES + FACT_TABLES}
    for name, df in raw.items():
        check_columns(name, df)
        if df.empty and name not in ("fact_escalation",):
            raise ExtractError(f"{name} is empty")

    dims = {n: raw[n] for n in DIM_TABLES}
    clean_act, rejected_act = validate_activities(raw["fact_activity"], dims, log)
    clean_ids = set(clean_act["activity_id"])
    all_ids = set(raw["fact_activity"]["activity_id"].dropna())
    children, quarantined = validate_children(raw, clean_ids, all_ids, dims, log)
    reconcile(clean_act, children["activity_state_history"], log)
    volume_check(len(clean_act), reports_dir / "dq_run_log.csv", log)

    n_received = len(raw["fact_activity"].drop_duplicates())
    reject_pct = 100 * len(rejected_act) / max(n_received, 1)
    status = "FAIL" if reject_pct > max_reject_pct else "WARN" if len(rejected_act) else "PASS"

    summary = {"raw_activities": len(raw["fact_activity"]), "clean_activities": len(clean_act),
               "rejected_activities": len(rejected_act), "reject_pct": reject_pct,
               "rejected_timesheets": len(quarantined["fact_timesheet"]), "status": status, "as_of": as_of}

    # quarantine is always written, so the owner can fix the source either way
    rejected_act.to_csv(quarantine_dir / "fact_activity_rejected.csv", index=False)
    for name, df in quarantined.items():
        df.to_csv(quarantine_dir / f"{name}_rejected.csv", index=False)
    write_report(reports_dir / f"dq_report_{as_of}.md", log, status, summary)

    if status != "FAIL":
        for name in DIM_TABLES:
            dims[name].to_csv(processed_dir / f"{name}.csv", index=False)
        clean_act.to_csv(processed_dir / "fact_activity.csv", index=False)
        for name, df in children.items():
            df.to_csv(processed_dir / f"{name}.csv", index=False)
        log.frame().to_csv(processed_dir / "dq_check_results.csv", index=False)
        pd.DataFrame([{"as_of_date": as_of, "dq_status": status, "clean_activities": len(clean_act),
                       "rows_quarantined": len(rejected_act) + len(quarantined["fact_timesheet"])}]
                     ).to_csv(processed_dir / "refresh_info.csv", index=False)

    run_log = reports_dir / "dq_run_log.csv"
    pd.DataFrame([{"run_at": datetime.now().isoformat(timespec="seconds"), "as_of_date": as_of,
                   "dq_status": status, "raw_activities": summary["raw_activities"],
                   "clean_activities": len(clean_act), "rejected_activities": len(rejected_act),
                   "rejected_timesheets": summary["rejected_timesheets"]}]
                 ).to_csv(run_log, mode="a", header=not run_log.exists(), index=False)
    return summary


def main() -> None:
    ap = argparse.ArgumentParser(description="Validate the raw extract and build load-ready tables.")
    ap.add_argument("--max-reject-pct", type=float, default=MAX_REJECT_PCT)
    args = ap.parse_args()
    s = run(max_reject_pct=args.max_reject_pct)
    print(f"[{s['status']}] as of {s['as_of']}: {s['clean_activities']} clean activities, "
          f"{s['rejected_activities']} quarantined ({s['reject_pct']:.1f}%), "
          f"{s['rejected_timesheets']} timesheet rows quarantined")
    raise SystemExit(1 if s["status"] == "FAIL" else 0)


if __name__ == "__main__":
    main()

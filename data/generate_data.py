#!/usr/bin/env python3
"""
generate_data.py
================
Creates a synthetic "source system" extract for the Engineering Activity Analytics
portfolio project and writes it to data/raw/.

The extract imitates a normalised project-tracking system: separate tables for
units, platforms, functions, locations, engineers, projects, activities, activity
state history, weekly timesheets and escalations.

Everything is synthetic. Names, IDs, units and numbers are randomly generated.

A small number of deliberate data-quality defects are injected into the raw
activity and timesheet tables (duplicates, missing values, invalid states,
orphan keys, impossible dates), so the validation step in pipeline/validate.py
has real problems to catch.

Usage
-----
    python data/generate_data.py                      # as-of 2026-09-30, seed 42
    python data/generate_data.py --as-of 2026-10-19   # simulate a newer weekly extract
    python data/generate_data.py --no-defects         # clean extract
"""
from __future__ import annotations

import argparse
from datetime import date, datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw"

HISTORY_START = date(2024, 7, 1)          # first date any project can start
FISCAL_YEAR_START_MONTH = 4               # fiscal year runs April-March

# ---------------------------------------------------------------- reference data
STATES = ["Proposed", "Planning", "Active", "Review", "Report", "Closed"]
STATE_GROUP = {
    "Proposed": "Pipeline", "Planning": "Pipeline", "Active": "In Progress",
    "Review": "Wrap-up", "Report": "Wrap-up", "Closed": "Closed",
}
# typical (min, max) days spent in each non-terminal state
STATE_DURATION = {
    "Proposed": (5, 25), "Planning": (10, 40), "Active": (60, 240),
    "Review": (10, 35), "Report": (7, 25),
}

UNITS = [
    ("U01", "Compact Machines"),
    ("U02", "Field Equipment"),
    ("U03", "Power Systems"),
    ("U04", "Material Handling"),
]
PLATFORMS = {
    "U01": ["CM-100", "CM-200"],
    "U02": ["FE-300", "FE-400", "FE-500"],
    "U03": ["PS-600", "PS-700"],
    "U04": ["MH-800", "MH-900"],
}
FUNCTIONS = [  # id, name, short code, share of activities
    ("F01", "Structural Analysis", "STR", 0.24),
    ("F02", "Dynamic Systems Modelling", "DSM", 0.18),
    ("F03", "Thermal & Fluids (CFD)", "CFD", 0.16),
    ("F04", "Noise, Vibration & Harshness", "NVH", 0.15),
    ("F05", "Tribology", "TRB", 0.10),
    ("F06", "Durability Testing", "DUR", 0.17),
]
LOCATIONS = [
    ("L01", "Hub East", "India"),
    ("L02", "Hub West", "USA"),
    ("L03", "Hub Central", "Germany"),
]
TASKS = {
    "STR": ["FEA of main frame", "Weld fatigue assessment", "Bracket redesign check", "Load case definition"],
    "DSM": ["Hydraulic circuit model", "Drivetrain dynamics model", "Control logic co-simulation", "Duty cycle simulation"],
    "CFD": ["Cooling airflow study", "Underhood thermal analysis", "Fan shroud optimisation", "Tank sloshing study"],
    "NVH": ["Cab noise survey", "Modal analysis", "Vibration isolation design", "Exterior noise prediction"],
    "TRB": ["Bearing wear assessment", "Lubricant selection study", "Gear contact analysis", "Seal friction study"],
    "DUR": ["Durability test plan", "Field data correlation", "Rig test execution", "Component life prediction"],
}
PROJECT_THEMES = [
    "Frame Upgrade", "Cab Comfort", "Cooling Improvement", "Cost Reduction",
    "Emissions Compliance", "Durability Improvement", "New Model Introduction", "Weight Reduction",
]
FIRST_NAMES = [
    "Aarav", "Maya", "Liam", "Sofia", "Noah", "Ananya", "Lukas", "Emma", "Rohan", "Clara",
    "Ethan", "Priya", "Jonas", "Olivia", "Arjun", "Hannah", "Mateo", "Isha", "Felix", "Grace",
    "Kabir", "Lena", "Samuel", "Nina", "Vikram", "Chloe", "Daniel", "Meera", "Oscar", "Zara",
]
LAST_NAMES = [
    "Sharma", "Becker", "Walker", "Iyer", "Novak", "Fischer", "Reddy", "Moore", "Kumar", "Schulz",
    "Hughes", "Patel", "Wagner", "Brooks", "Nair", "Keller", "Ortiz", "Joshi", "Hoffmann", "Bennett",
]
ESCALATION_REASONS = ["Deadline at risk", "Resource conflict", "Scope change", "Blocked dependency", "Status unclear"]
ESCALATION_SOURCES = ["Program Manager", "Engineering Supervisor", "Platform Lead"]


def days(n: int) -> timedelta:
    return timedelta(days=int(n))


def fiscal_year_label(d: date) -> str:
    """April-March fiscal year, labelled by the year it ends in (Apr 2025 -> FY2026)."""
    return f"FY{d.year + 1 if d.month >= FISCAL_YEAR_START_MONTH else d.year}"


def fiscal_month(d: date) -> int:
    return (d.month - FISCAL_YEAR_START_MONTH) % 12 + 1


# ---------------------------------------------------------------- dimensions
def build_dimensions(rng: np.random.Generator) -> dict[str, pd.DataFrame]:
    dim_unit = pd.DataFrame(UNITS, columns=["unit_id", "unit_name"])

    dim_platform = pd.DataFrame(
        [(p, p, u) for u, plist in PLATFORMS.items() for p in plist],
        columns=["platform_id", "platform_name", "unit_id"],
    )

    dim_function = pd.DataFrame(
        [(f, n, c) for f, n, c, _ in FUNCTIONS],
        columns=["function_id", "function_name", "function_code"],
    )

    dim_location = pd.DataFrame(LOCATIONS, columns=["location_id", "location_name", "country"])

    dim_state = pd.DataFrame({
        "state": STATES,
        "state_order": range(1, len(STATES) + 1),
        "state_group": [STATE_GROUP[s] for s in STATES],
        "is_open": [0 if s == "Closed" else 1 for s in STATES],
    })

    # 45 engineers; every function gets at least 5, the rest follow activity share
    n_eng = 45
    shares = np.array([f[3] for f in FUNCTIONS])
    per_func = np.maximum(5, np.round(shares * n_eng)).astype(int)
    used_names: set[str] = set()
    rows, k = [], 1
    for (fid, _, _, _), n in zip(FUNCTIONS, per_func):
        for i in range(n):
            while True:
                name = f"{rng.choice(FIRST_NAMES)} {rng.choice(LAST_NAMES)}"
                if name not in used_names:
                    used_names.add(name)
                    break
            # first engineer in each function is the Lead, next two are Senior
            role = "Lead Engineer" if i == 0 else "Senior Engineer" if i in (1, 2) else "Engineer"
            capacity = {"Lead Engineer": 4, "Senior Engineer": 7, "Engineer": 6}[role]
            rows.append({
                "engineer_id": f"E{k:03d}",
                "engineer_name": name,
                "home_function_id": fid,
                "location_id": rng.choice(["L01", "L02", "L03"], p=[0.55, 0.25, 0.20]),
                "role": role,
                "capacity_activities": capacity,
                "is_active": 1,
            })
            k += 1
    dim_engineer = pd.DataFrame(rows)

    return {
        "dim_unit": dim_unit, "dim_platform": dim_platform, "dim_function": dim_function,
        "dim_location": dim_location, "dim_state": dim_state, "dim_engineer": dim_engineer,
    }


def build_projects(rng: np.random.Generator, dim_platform: pd.DataFrame, as_of: date, n_projects: int) -> pd.DataFrame:
    span = (as_of - days(21) - HISTORY_START).days
    rows = []
    for i in range(1, n_projects + 1):
        plat = dim_platform.sample(1, random_state=int(rng.integers(1e9))).iloc[0]
        rows.append({
            "project_id": f"P{i:04d}",
            "project_title": f"{plat.platform_id} {rng.choice(PROJECT_THEMES)} #{i:03d}",
            "unit_id": plat.unit_id,
            "platform_id": plat.platform_id,
            # skewed towards recent starts so the current portfolio is busy
            "project_start_date": HISTORY_START + days(span * rng.beta(1.3, 1.0)),
        })
    return pd.DataFrame(rows)


# ---------------------------------------------------------------- activities
def build_activities(rng, projects, dim_engineer, as_of):
    """Walk each activity through the lifecycle until it closes or reaches the as-of date."""
    func_ids = [f[0] for f in FUNCTIONS]
    func_codes = {f[0]: f[2] for f in FUNCTIONS}
    func_p = np.array([f[3] for f in FUNCTIONS])
    func_p = func_p / func_p.sum()

    # uneven assignment weights so some engineers end up overloaded
    eng_by_func = {f: dim_engineer[dim_engineer.home_function_id == f] for f in func_ids}
    eng_weights = {f: rng.gamma(3.0, 1.0, len(df)) for f, df in eng_by_func.items()}
    expected_total = sum((lo + hi) / 2 for lo, hi in STATE_DURATION.values())

    acts, hist = [], []
    a = 1
    for proj in projects.itertuples():
        for _ in range(int(rng.integers(3, 9))):
            # activities are raised within ~3 months of project start, never after the extract date
            window = max(1, min(90, (as_of - proj.project_start_date).days))
            created = proj.project_start_date + days(rng.integers(0, window))

            fid = rng.choice(func_ids, p=func_p)
            pool = eng_by_func[fid]
            w = eng_weights[fid] / eng_weights[fid].sum()
            eng = pool.iloc[rng.choice(len(pool), p=w)]
            guides = pool[(pool.role != "Engineer") & (pool.engineer_id != eng.engineer_id)]
            guide_id = guides.sample(1, random_state=int(rng.integers(1e9))).iloc[0].engineer_id

            # lifecycle walk
            t, path = created, []
            for st in STATES[:-1]:
                path.append((st, t))
                nxt = t + days(rng.integers(*STATE_DURATION[st]))
                if nxt > as_of:
                    break
                t = nxt
            else:
                path.append(("Closed", t))

            entered = {st: d for st, d in path}
            state = path[-1][0]
            deadline = created + days(expected_total * rng.uniform(0.75, 1.15))

            if state == "Closed":
                pct = 100
            elif state in ("Proposed", "Planning"):
                pct = 0 if state == "Proposed" else int(rng.integers(0, 10))
            elif state == "Active":
                elapsed = (as_of - entered["Active"]).days
                pct = int(min(80, 10 + elapsed / 240 * 70))
            elif state == "Review":
                pct = int(rng.integers(80, 90))
            else:
                pct = int(rng.integers(90, 99))

            aid = f"A{a:05d}"
            acts.append({
                "activity_id": aid,
                "project_id": proj.project_id,
                "activity_title": f"{func_codes[fid]} - {rng.choice(TASKS[func_codes[fid]])}",
                "function_id": fid,
                "activity_engineer_id": eng.engineer_id,
                "guide_approver_id": guide_id,
                "location_id": eng.location_id,
                "state": state,
                "created_date": created,
                "start_date": entered.get("Active"),
                "deadline_date": deadline,
                "report_date": entered.get("Report"),
                "closed_date": entered.get("Closed"),
                "percent_complete": pct,
                "planned_hours": int(rng.integers(5, 40)) * 8,
            })
            for i, (st, d) in enumerate(path):
                hist.append({
                    "activity_id": aid, "state": st, "valid_from": d,
                    "valid_to": path[i + 1][1] if i + 1 < len(path) else None,
                })
            a += 1
    return pd.DataFrame(acts), pd.DataFrame(hist)


def week_start(d: date) -> date:
    return d - days(d.weekday())


def build_timesheets(rng, acts: pd.DataFrame, as_of: date) -> pd.DataFrame:
    """Weekly hours booked from the day an activity goes Active until it reaches Report (or as-of)."""
    rows = []
    for act in acts.itertuples():
        if pd.isna(act.start_date):
            continue
        end = act.report_date if not pd.isna(act.report_date) else as_of
        weeks = pd.date_range(week_start(act.start_date), week_start(end), freq="7D").date
        if len(weeks) == 0:
            continue
        base = act.planned_hours / len(weeks)
        for wk in weeks:
            hrs = round(float(np.clip(base * rng.uniform(0.6, 1.4), 1, 30)) * 2) / 2
            rows.append({"week_start": wk, "engineer_id": act.activity_engineer_id,
                         "activity_id": act.activity_id, "hours": hrs})
    ts = pd.DataFrame(rows)
    ts.insert(0, "timesheet_id", [f"T{i:06d}" for i in range(1, len(ts) + 1)])
    return ts


def build_escalations(rng, acts: pd.DataFrame, as_of: date) -> pd.DataFrame:
    rows, k = [], 1
    for act in acts.itertuples():
        end = act.closed_date if not pd.isna(act.closed_date) else as_of
        late = end > act.deadline_date
        n = rng.poisson(0.9 if late else 0.15)
        span = max((end - act.created_date).days, 1)
        for _ in range(n):
            d = act.created_date + days(rng.integers(0, span))
            reason = "Deadline at risk" if (late and d >= act.deadline_date - days(21)) \
                else rng.choice([r for r in ESCALATION_REASONS if r != "Deadline at risk"])
            rows.append({"escalation_id": f"ESC{k:05d}", "activity_id": act.activity_id,
                         "escalation_date": d, "reason": reason,
                         "raised_by": rng.choice(ESCALATION_SOURCES)})
            k += 1
    return pd.DataFrame(rows)


def build_dim_date(start: date, end: date) -> pd.DataFrame:
    dates = pd.date_range(start, end, freq="D")
    df = pd.DataFrame({"date": dates.date})
    df.insert(0, "date_key", dates.strftime("%Y%m%d").astype(int))
    df["year"] = dates.year
    df["month_num"] = dates.month
    df["month_name"] = dates.strftime("%B")
    df["month_short"] = dates.strftime("%b")
    df["year_month"] = dates.strftime("%Y-%m")
    df["month_start"] = dates.to_period("M").start_time.date
    df["is_month_end"] = dates.is_month_end.astype(int)
    df["fiscal_year"] = [fiscal_year_label(d) for d in df["date"]]
    df["fiscal_month"] = [fiscal_month(d) for d in df["date"]]
    df["week_start"] = [week_start(d) for d in df["date"]]
    return df


# ---------------------------------------------------------------- defects
def inject_defects(rng, acts: pd.DataFrame, ts: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame, list[str]]:
    """Add a handful of realistic extract problems. Each defect hits a different row."""
    log = []
    acts = acts.copy()
    idx = rng.choice(acts.index, size=24, replace=False)
    blocks = np.split(idx, [5, 8, 11, 14, 18, 20])  # 5 null eng, 3 bad state, 3 orphan, 3 date, 4 pct, 2 closed-no-date, 4 dupes

    acts.loc[blocks[0], "activity_engineer_id"] = None
    log.append(f"{len(blocks[0])} activities with missing activity engineer")

    acts.loc[blocks[1], "state"] = ["Actve", "In Progress", "closed "][: len(blocks[1])]
    log.append(f"{len(blocks[1])} activities with invalid state values")

    acts.loc[blocks[2], "activity_engineer_id"] = "E999"
    log.append(f"{len(blocks[2])} activities pointing at an engineer that does not exist")

    for i in blocks[3]:
        acts.loc[i, "start_date"] = acts.loc[i, "created_date"] + days(10)
        acts.loc[i, "closed_date"] = acts.loc[i, "created_date"] + days(3)
        acts.loc[i, "state"] = "Closed"
    log.append(f"{len(blocks[3])} activities closed before they started")

    acts.loc[blocks[4], "percent_complete"] = [110, -5, 120, 105][: len(blocks[4])]
    log.append(f"{len(blocks[4])} activities with percent_complete outside 0-100")

    acts.loc[blocks[5], "state"] = "Closed"
    acts.loc[blocks[5], "closed_date"] = None
    log.append(f"{len(blocks[5])} activities marked Closed with no closed date")

    dupes = acts.loc[blocks[6]]
    acts = pd.concat([acts, dupes], ignore_index=True)
    log.append(f"{len(dupes)} exact duplicate activity rows (extract re-sent rows)")

    ts = ts.copy()
    tidx = rng.choice(ts.index, size=12, replace=False)
    ts.loc[tidx[:4], "hours"] = -ts.loc[tidx[:4], "hours"]
    ts.loc[tidx[4:7], "hours"] = 99
    ts.loc[tidx[7:9], "activity_id"] = "A99999"
    ts = pd.concat([ts, ts.loc[tidx[9:12]]], ignore_index=True)
    log.append("4 negative timesheet hours, 3 impossible weekly hours (99), 2 orphan timesheet rows, 3 duplicate timesheet rows")

    return acts.sample(frac=1, random_state=int(rng.integers(1e9))).reset_index(drop=True), ts, log


# ---------------------------------------------------------------- main
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--as-of", default="2026-09-30", help="extract date (YYYY-MM-DD)")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--projects", type=int, default=140)
    ap.add_argument("--no-defects", action="store_true", help="skip injected data-quality defects")
    ap.add_argument("--out", default=str(RAW_DIR))
    args = ap.parse_args()

    as_of = datetime.strptime(args.as_of, "%Y-%m-%d").date()
    rng = np.random.default_rng(args.seed)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    dims = build_dimensions(rng)
    projects = build_projects(rng, dims["dim_platform"], as_of, args.projects)
    acts, hist = build_activities(rng, projects, dims["dim_engineer"], as_of)
    ts = build_timesheets(rng, acts, as_of)
    esc = build_escalations(rng, acts, as_of)

    max_date = max(acts["deadline_date"].max(), as_of) + days(31)
    dim_date = build_dim_date(HISTORY_START, date(max_date.year, 12, 31))

    defect_log = []
    if not args.no_defects:
        acts, ts, defect_log = inject_defects(rng, acts, ts)

    acts["percent_complete"] = acts["percent_complete"].astype("Int64")

    tables = {**dims, "dim_project": projects, "dim_date": dim_date,
              "fact_activity": acts, "activity_state_history": hist,
              "fact_timesheet": ts, "fact_escalation": esc}
    for name, df in tables.items():
        df.to_csv(out / f"{name}.csv", index=False)

    pd.DataFrame([{"as_of_date": as_of, "generated_at": datetime.now().isoformat(timespec="seconds"),
                   "seed": args.seed}]).to_csv(out / "extract_info.csv", index=False)

    print(f"Synthetic extract written to {out} (as of {as_of})")
    for name, df in tables.items():
        print(f"  {name:<24}{len(df):>7,} rows")
    if defect_log:
        print("Injected defects:")
        for line in defect_log:
            print(f"  - {line}")


if __name__ == "__main__":
    main()

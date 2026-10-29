#!/usr/bin/env python3
"""
make_edl_files.py
=================
Writes the synthetic extract as "data lake" source files in data/edl_source/,
shaped like a typical project-tracking system's raw tables:

    Unit, Platform, Function, Location, Engineer, Project,
    Activity, ActivityStateHistory, ExtractInfo

These are the raw files, data-quality defects included. The SQL layer
(sql/quick_build/quick_build.sql) loads them as-is into an
`edl` schema, checks them, and builds the reporting views Power BI uses.

Usage
-----
    python data/generate_data.py          # creates data/raw/ (seeded, reproducible)
    python data/make_edl_files.py         # creates data/edl_source/
"""
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
OUT = ROOT / "data" / "edl_source"

TABLES = {
    "Unit": ("dim_unit", {"unit_id": "UnitID", "unit_name": "UnitName"}),
    "Platform": ("dim_platform", {"platform_id": "PlatformID", "platform_name": "PlatformName", "unit_id": "UnitID"}),
    "Function": ("dim_function", {"function_id": "FunctionID", "function_name": "FunctionName",
                                  "function_code": "FunctionCode"}),
    "Location": ("dim_location", {"location_id": "LocationID", "location_name": "LocationName", "country": "Country"}),
    "Engineer": ("dim_engineer", {"engineer_id": "EngineerID", "engineer_name": "EngineerName",
                                  "home_function_id": "HomeFunctionID", "location_id": "LocationID",
                                  "role": "Role", "capacity_activities": "Capacity", "is_active": "IsActive"}),
    "Project": ("dim_project", {"project_id": "ProjectID", "project_title": "ProjectTitle", "unit_id": "UnitID",
                                "platform_id": "PlatformID", "project_start_date": "ProjectStartDate"}),
    "Activity": ("fact_activity", {"activity_id": "ActivityID", "project_id": "ProjectID",
                                   "activity_title": "ActivityTitle", "function_id": "FunctionID",
                                   "activity_engineer_id": "ActivityEngineerID",
                                   "guide_approver_id": "GuideApproverID", "location_id": "LocationID",
                                   "state": "State", "created_date": "CreatedDate", "start_date": "StartDate",
                                   "deadline_date": "Deadline", "report_date": "ReportDate",
                                   "closed_date": "CompletionDate", "percent_complete": "PercentComplete",
                                   "planned_hours": "PlannedHours"}),
    "ActivityStateHistory": ("activity_state_history", {"activity_id": "ActivityID", "state": "State",
                                                        "valid_from": "ValidFrom", "valid_to": "ValidTo"}),
    "ExtractInfo": ("extract_info", {"as_of_date": "AsOfDate"}),
}


def main() -> None:
    if not (RAW / "fact_activity.csv").exists():
        raise SystemExit("data/raw/ not found: run  python data/generate_data.py  first")
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (src, cols) in TABLES.items():
        df = pd.read_csv(RAW / f"{src}.csv", dtype=str, keep_default_na=False)
        df[list(cols)].rename(columns=cols).to_csv(OUT / f"{name}.csv", index=False)
        print(f"  {name:<22}{len(df):>6,} rows")
    print(f"EDL source files written to {OUT}")


if __name__ == "__main__":
    main()

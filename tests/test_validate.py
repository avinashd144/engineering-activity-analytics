"""Tests for the data-quality gate. Run with:  pytest -q"""
import subprocess
import sys
from pathlib import Path

import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline"))
import validate  # noqa: E402


def make_extract(tmp: Path, defects: bool) -> Path:
    raw = tmp / "raw"
    cmd = [sys.executable, str(ROOT / "data" / "generate_data.py"), "--out", str(raw), "--seed", "7"]
    if not defects:
        cmd.append("--no-defects")
    subprocess.run(cmd, check=True, capture_output=True)
    return raw


def run(tmp: Path, raw: Path, **kw) -> dict:
    return validate.run(raw_dir=raw, processed_dir=tmp / "processed", quarantine_dir=tmp / "quarantine",
                        reports_dir=tmp / "reports", **kw)


def test_clean_extract_passes(tmp_path):
    s = run(tmp_path, make_extract(tmp_path, defects=False))
    assert s["status"] == "PASS"
    assert s["rejected_activities"] == 0


def test_defects_are_caught(tmp_path):
    s = run(tmp_path, make_extract(tmp_path, defects=True))
    assert s["status"] == "WARN"
    rejected = pd.read_csv(tmp_path / "quarantine" / "fact_activity_rejected.csv")
    reasons = " ".join(rejected["reject_reason"])
    for expected in ["mandatory field missing", "state not in allowed list", "activity engineer not found",
                     "closed before it started", "Closed but no closed_date"]:
        assert expected in reasons
    clean = pd.read_csv(tmp_path / "processed" / "fact_activity.csv")
    assert clean["activity_id"].is_unique
    assert clean["percent_complete"].between(0, 100).all()


def test_children_of_rejected_activities_are_excluded(tmp_path):
    run(tmp_path, make_extract(tmp_path, defects=True))
    clean_ids = set(pd.read_csv(tmp_path / "processed" / "fact_activity.csv")["activity_id"])
    for table in ["activity_state_history", "fact_timesheet", "fact_escalation"]:
        child = pd.read_csv(tmp_path / "processed" / f"{table}.csv")
        assert set(child["activity_id"]) <= clean_ids


def test_circuit_breaker_blocks_load(tmp_path):
    raw = make_extract(tmp_path, defects=True)
    s = run(tmp_path, raw, max_reject_pct=0.5)
    assert s["status"] == "FAIL"
    assert not (tmp_path / "processed" / "fact_activity.csv").exists()


def test_missing_table_stops_run(tmp_path):
    raw = make_extract(tmp_path, defects=False)
    (raw / "dim_engineer.csv").unlink()
    with pytest.raises(validate.ExtractError):
        run(tmp_path, raw)

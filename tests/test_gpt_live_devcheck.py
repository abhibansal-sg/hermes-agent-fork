"""Regression test for `scripts/gpt_live_devcheck.sh`."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


def test_gpt_live_devcheck_prints_expected_sentinel_lines() -> None:
    script = Path(__file__).resolve().parents[1] / "scripts" / "gpt_live_devcheck.sh"
    result = subprocess.run(
        [str(script)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "PASS fixture manifest v1" in result.stdout
    assert "PASS app-server schema digest" in result.stdout
    assert "PASS dynamic tool request/response" in result.stdout
    assert "PASS transcript replay: 0 duplicates" in result.stdout
    assert "PASS redaction scan" in result.stdout
    assert "READY fixture path" in result.stdout


def test_gpt_live_devcheck_json_mode_matches_human_contract() -> None:
    script = Path(__file__).resolve().parents[1] / "scripts" / "gpt_live_devcheck.sh"
    result = subprocess.run(
        [str(script), "--json"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(result.stdout)
    assert payload["ok"] is True
    assert payload["manifest_version"] == "1"
    assert {check["name"] for check in payload["checks"]} >= {
        "fixture manifest v1",
        "fixture checksums",
        "app-server schema digest",
        "dynamic tool request/response",
        "transcript replay: 0 duplicates",
        "redaction scan",
    }


"""Focused tests for the offline GPT-Live devcheck utility."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "gpt_live_devcheck.sh"


def _run_devcheck(*args: str) -> subprocess.CompletedProcess[str]:
    command = [str(SCRIPT_PATH), *args]
    return subprocess.run(
        command,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def test_devcheck_outputs_required_human_sentinels() -> None:
    proc = _run_devcheck()
    assert proc.returncode == 0
    assert "PASS fixture manifest" in proc.stdout
    assert "PASS prompt block catalog" in proc.stdout
    assert "PASS realtime delegation structure" in proc.stdout
    assert "PASS redaction scan" in proc.stdout
    assert "WARN direct generic tool call unavailable" in proc.stdout
    assert "READY executor-handoff fixtures" in proc.stdout


def test_devcheck_json_has_warnings_not_failures_and_evidence() -> None:
    proc = _run_devcheck("--json")
    assert proc.returncode == 0
    json_start = proc.stdout.find("{")
    assert json_start >= 0
    payload = json.loads(proc.stdout[json_start:])
    assert payload["overall"] == "READY"
    assert payload["checks"], "expected checks in json payload"
    assert payload["warnings"] == ["direct generic tool call unavailable"]
    assert payload["errors"] == []
    assert payload["realtime_delegation_count"] == 42
    assert payload["path"].endswith("desktop_live_prompt_blocks.json")

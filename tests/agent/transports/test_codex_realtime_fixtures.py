from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

import pytest

from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "gpt_live"
MANIFEST_PATH = FIXTURE_DIR / "manifest.json"

FORBIDDEN_FIXTURE_FILENAMES = {
    "dynamic_tool_call_request.json",
    "dynamic_tool_call_response.json",
    "transcript_replay.jsonl",
}

SECRET_PATTERNS = [
    re.compile(r"sk-[A-Za-z0-9_-]{20,}", re.IGNORECASE),
    re.compile(r"(?i)bearer\\s+[A-Za-z0-9._-]{20,}"),
    re.compile(r"(?i)(api|auth|secret|access)[_-]?token\\s*[:=]\\s*['\\\"]?[A-Za-z0-9._~/-]{24,}['\\\"]?"),
    re.compile(r"(?i)(api|secret)[_-]?key\\s*[:=]\\s*['\\\"]?[A-Za-z0-9._~/-]{20,}['\\\"]?"),
    re.compile(r"(?i)eyJ[A-Za-z0-9_-]{20,}\\."),
]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_manifest() -> dict[str, Any]:
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def _load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def test_manifest_matches_available_fixtures() -> None:
    manifest = _load_manifest()
    fixtures = manifest["fixtures"]
    assert isinstance(fixtures, list)
    assert fixtures, "expected available fixture declarations in manifest"

    for fixture in fixtures:
        fixture_id = fixture["id"]
        source = fixture["source"]
        committed = fixture["committed"]
        source_path = Path(source["path"])
        committed_path = FIXTURE_DIR / committed["filename"]

        assert source_path.exists(), f"{fixture_id}: missing source path {source_path}"
        assert committed_path.exists(), f"{fixture_id}: missing committed file {committed_path}"

        expected_source_sha = source["sha256"]
        expected_source_size = int(source["size_bytes"])
        expected_committed_sha = committed["sha256"]
        expected_committed_size = int(committed["size_bytes"])

        assert _sha256(source_path) == expected_source_sha
        assert source_path.stat().st_size == expected_source_size
        assert _sha256(committed_path) == expected_committed_sha
        assert committed_path.stat().st_size == expected_committed_size

        assert expected_source_sha == expected_committed_sha
        assert expected_source_size == expected_committed_size
        assert fixture.get("provenance_classification") == "historical_recovered"
        assert "expected_assertions" in fixture


def test_unavailable_fixtures_recorded_and_unbound() -> None:
    manifest = _load_manifest()
    unavailable = manifest["unavailable"]
    assert isinstance(unavailable, list)
    assert unavailable, "expected unavailable fixture declarations"
    assert len(unavailable) == 6

    by_id = {entry["id"]: entry for entry in unavailable}
    expected_unavailable_ids = [
        "dynamic_tool_call_request",
        "dynamic_tool_call_response",
        "transcript_replay",
        "clientManagedHandoffs_comparison",
        "remote_expiry_measurement",
        "gpt_live_namespace_invocation",
    ]
    for entry_id in expected_unavailable_ids:
        assert entry_id in by_id
        entry = by_id[entry_id]
        assert entry["status"] == "unavailable"
        assert entry["provenance_classification"] == "missing_service_evidence"
        assert entry["committed"]["filename"] is None
        reason = str(entry.get("reason", "")).strip()
        assert reason and len(reason) > 12, reason


def test_forbidden_synthetic_fixture_filenames_absent() -> None:
    committed_names = {path.name for path in FIXTURE_DIR.iterdir()}
    assert not (committed_names & FORBIDDEN_FIXTURE_FILENAMES), (
        "synthetic fixture filenames must remain absent: "
        f"{sorted(committed_names & FORBIDDEN_FIXTURE_FILENAMES)}"
    )


def test_recovered_tool_manifest_assertions() -> None:
    fixture = _load_json(
        FIXTURE_DIR / "RECOVERED_REALTIME_DYNAMIC_TOOLS_2026-07-24.json"
    )
    dynamic_groups = fixture.get("dynamic_tools", [])
    assert isinstance(dynamic_groups, list)
    assert len(dynamic_groups) == 2

    names = [group.get("name") for group in dynamic_groups]
    assert set(names) == {"codex_app", "plugin_management"}

    group_map = {
        group["name"]: group.get("tools", []) for group in dynamic_groups
    }
    assert len(group_map["codex_app"]) == 19
    assert len(group_map["plugin_management"]) == 1
    assert len(group_map["codex_app"]) + len(group_map["plugin_management"]) == 20

    codex_tool_names = [tool["name"] for tool in group_map["codex_app"]]
    plugin_tool_names = [tool["name"] for tool in group_map["plugin_management"]]
    assert "automation_update" in codex_tool_names
    assert "uninstall_plugin" in plugin_tool_names


def test_model_catalog_assertions() -> None:
    fixture = _load_json(FIXTURE_DIR / "LIVE_MODEL_CATALOG_2026-07-25.json")
    model_names = {model["display_name"] for model in fixture.get("public_models", [])}
    assert "GPT-Live-1" in model_names
    assert "GPT-Live-1 mini" in model_names

    aliases = {entry["model"]: entry for entry in fixture.get("locally_recovered_aliases", [])}
    assert aliases["gpt-live-1-codex"]["protocol_version"] == "v3"
    assert len(aliases) >= 1

    assert "GPT-Live-1" in {route["live_model"] for route in fixture.get("intelligence_routes", [])}


def test_app_server_schema_assertions() -> None:
    fixture_path = FIXTURE_DIR / "codex_app_server_protocol.schemas.json"
    raw = fixture_path.read_text(encoding="utf-8")
    data = _load_json(fixture_path)

    assert isinstance(data, dict)
    assert '"initialize"' in raw
    assert '"thread/start"' in raw
    assert '"thread/realtime/' in raw
    assert '"item/tool/call"' in raw
    assert "DynamicToolCallParams" in raw


@pytest.mark.parametrize(
    "committed_filename",
    [
        "RECOVERED_REALTIME_DYNAMIC_TOOLS_2026-07-24.json",
        "LIVE_MODEL_CATALOG_2026-07-25.json",
        "codex_app_server_protocol.schemas.json",
    ],
)
def test_committed_fixtures_have_no_seeded_secrets(committed_filename: str) -> None:
    path = FIXTURE_DIR / committed_filename
    text = path.read_text(encoding="utf-8")

    for pattern in SECRET_PATTERNS:
        match = pattern.search(text)
        if match:
            pytest.fail(
                f"{committed_filename}: suspicious credential-like string matching "
                f"{pattern.pattern}: {match.group(0)[:40]!r}"
            )

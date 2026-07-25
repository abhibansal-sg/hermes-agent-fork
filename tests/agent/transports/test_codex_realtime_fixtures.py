"""Focused fixture manifest contract for GPT-Live P0 evidence.

These tests validate that only sanctioned evidence artifacts are bundled, that
checksums stay stable, that no scaffolded secrets leak into local fixtures, and
that small replay assertions are coherent.
"""

from __future__ import annotations

import json
import hashlib
import re
from pathlib import Path

import pytest


FIXTURE_DIR = Path(__file__).resolve().parents[2] / "fixtures" / "gpt_live"
MANIFEST_PATH = FIXTURE_DIR / "manifest.json"


def _load_manifest() -> dict:
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def _sha256_hex(path: Path) -> str:
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest()


def _scan_text_secrets(text: str) -> list[str]:
    redaction_patterns = [
        r"\bsk-[A-Za-z0-9_-]{20,}\b",
        r"\bOPENAI_API_KEY\b",
        r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b",
        r"\bghp_[A-Za-z0-9]{30,}\b",
        r"\beyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]+\b",
    ]
    hits: list[str] = []
    for pat in redaction_patterns:
        if re.search(pat, text):
            hits.append(pat)
    return hits


def _fixture_path(fixture_entry: dict) -> Path:
    return FIXTURE_DIR / fixture_entry["file"]


def _load_fixture_json(fixture_entry: dict) -> dict:
    return json.loads(_fixture_path(fixture_entry).read_text(encoding="utf-8"))


def _fixture_by_id(manifest: dict, fixture_id: str) -> dict:
    for fixture in manifest["fixtures"]:
        if fixture["id"] == fixture_id:
            return fixture
    raise KeyError(f"fixture not found: {fixture_id}")


def test_manifest_contract_is_present_and_versioned() -> None:
    manifest = _load_manifest()
    assert manifest["manifest_version"] == "1"
    assert manifest["artifact_set"] == "gpt-live-p00-h02"
    assert manifest["redaction_version"] == "2.0.0"
    assert isinstance(manifest["redaction_patterns"], list)
    assert isinstance(manifest["source_materials"], list)
    assert isinstance(manifest["fixtures"], list)
    assert manifest["fixtures"]


def test_required_fixture_ids_and_capabilities_exist() -> None:
    manifest = _load_manifest()
    required_ids = set(manifest["assertions"]["required_fixture_ids"])
    present_ids = {f["id"] for f in manifest["fixtures"]}
    assert required_ids.issubset(present_ids)
    required_caps = set(manifest["assertions"]["required_capability_groups"])
    all_caps = {cap for fixture in manifest["fixtures"] for cap in fixture["capabilities"]}
    assert required_caps.issubset(all_caps)


@pytest.mark.parametrize("fixture_id", _load_manifest()["assertions"]["required_fixture_ids"])  # type: ignore[misc]
def test_available_fixture_files_and_hashes_match_manifest(fixture_id: str) -> None:
    fixture = _fixture_by_id(_load_manifest(), fixture_id)
    assert fixture["status"] == "available"
    path = _fixture_path(fixture)
    assert path.is_file(), f"missing file for required fixture {fixture_id}: {path}"
    assert _sha256_hex(path) == fixture["sha256"], (
        f"checksum mismatch for {fixture_id}\n"
        f"expected={fixture['sha256']}\\n"
        f"actual={_sha256_hex(path)}"
    )
    assert path.stat().st_size == fixture["size_bytes"]


def test_expected_unavailable_fixtures_are_explicit() -> None:
    manifest = _load_manifest()
    unavailable = [f for f in manifest["fixtures"] if f["status"] == "unavailable"]
    assert unavailable, "at least one unavailable fixture should be explicitly tracked"
    for fixture in unavailable:
        assert not _fixture_path(fixture).exists()
        reason = fixture.get("missing_reason", "").strip()
        assert reason and len(reason) > 20
        assert fixture["expected"].get("available") is False


def test_recovered_dynamic_tools_assertions() -> None:
    manifest = _load_manifest()
    fixture = _fixture_by_id(manifest, "recovered_dynamic_tools")
    data = _load_fixture_json(fixture)
    assert isinstance(data["dynamic_tools"], list)
    assert len(data["dynamic_tools"]) == fixture["expected"]["namespace_count"]
    assert fixture["expected"]["tool_count"] == sum(
        len(ns["tools"]) for ns in data["dynamic_tools"]
    )

    namespace_names = {ns["name"] for ns in data["dynamic_tools"]}
    assert set(namespace_names) == {"codex_app", "plugin_management"}
    assert fixture["expected"]["has_plugin_management_namespace"] is True
    assert fixture["expected"]["has_capture_screen_context"] is True
    assert fixture["expected"]["has_ask_hermes"] is False

    codex_ns = next(ns for ns in data["dynamic_tools"] if ns["name"] == "codex_app")
    tool_names = {tool["name"] for tool in codex_ns["tools"]}
    assert "capture_screen_context" in tool_names
    assert "ask_hermes" not in tool_names

    assert "codex_namespace_count" in fixture["capabilities"]
    assert "plugin_management_namespace_present" in fixture["capabilities"]


def test_live_model_catalog_assertions() -> None:
    manifest = _load_manifest()
    fixture = _fixture_by_id(manifest, "live_model_catalog")
    catalog = _load_fixture_json(fixture)
    aliases = catalog["locally_recovered_aliases"]
    recovered = {entry["model"]: entry for entry in aliases}
    assert "gpt-live-1-codex" in recovered
    alias = recovered["gpt-live-1-codex"]
    assert alias["protocol_version"] == fixture["expected"]["active_protocol_version"]
    assert alias["status"] == fixture["expected"]["alias_status"]

    public_names = {entry["display_name"] for entry in catalog["public_models"]}
    assert "GPT-Live-1" in public_names
    assert "GPT-Live-1 mini" in public_names


def test_protocol_schema_manifest_assertions() -> None:
    manifest = _load_manifest()
    fixture = _fixture_by_id(manifest, "app_server_protocol_schema")
    schema = _load_fixture_json(fixture)
    assert schema["title"] == "CodexAppServerProtocol"
    assert fixture["expected"]["schema_root"] in schema
    definitions = schema.get("definitions", {})
    v2_definitions = definitions.get("v2", {})
    if not definitions:
        pytest.fail("schema definitions missing")
    assert fixture["expected"]["contains_thread_start"] is True
    assert "ThreadStartParams" in definitions or "ThreadStartParams" in v2_definitions
    assert "ThreadRealtimeStartTransport" in definitions or "ThreadRealtimeStartTransport" in v2_definitions
    assert "DynamicToolCallResponse" in definitions


def test_tool_call_request_and_response_pair_is_complete() -> None:
    manifest = _load_manifest()
    req_fixture = _fixture_by_id(manifest, "tool_call_request")
    res_fixture = _fixture_by_id(manifest, "tool_call_response")
    req = _load_fixture_json(req_fixture)
    res = _load_fixture_json(res_fixture)
    assert req["method"] == "item/tool/call"
    assert req["id"] == req_fixture["expected"]["id"]
    params = req["params"]
    assert params["tool"] == "echo_probe"
    assert isinstance(params["arguments"], dict)
    assert "text" in params["arguments"]
    assert req["id"] == res["id"]
    assert isinstance(res["result"], dict)
    assert res["result"]["success"] == res_fixture["expected"]["success"]
    assert isinstance(res["result"]["contentItems"], list)


def test_transcript_replay_is_duplicate_free_and_scanned() -> None:
    manifest = _load_manifest()
    fixture = _fixture_by_id(manifest, "transcript_replay")
    seen: set[str] = set()
    duplicate_count = 0
    item_count = 0
    for line in (FIXTURE_DIR / fixture["file"]).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        item_count += 1
        item_id = record["item_id"]
        if item_id in seen:
            duplicate_count += 1
        else:
            seen.add(item_id)

    assert item_count == fixture["expected"]["expected_items"]
    assert duplicate_count == fixture["expected"]["expected_duplicates"]

    # secret scan on all available fixture files
    for candidate in manifest["fixtures"]:
        if candidate["status"] != "available":
            continue
        path = _fixture_path(candidate)
        hits = _scan_text_secrets(path.read_text(encoding="utf-8"))
        assert hits == [], f"{path} leaked redaction patterns: {hits}"

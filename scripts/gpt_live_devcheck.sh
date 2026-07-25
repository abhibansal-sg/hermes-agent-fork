#!/usr/bin/env python3
"""Offline GPT-Live fixture devcheck.

Runs strict checks against committed fixtures only:
- manifest contract
- schema checksums
- dynamic tool request/response consistency
- transcript duplicate detection
- redactable secret scan

No network, media, or runtime process is touched.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "tests" / "fixtures" / "gpt_live" / "manifest.json"


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
    for pattern in redaction_patterns:
        if re.search(pattern, text):
            hits.append(pattern)
    return hits


def _definition_contains(definitions: dict, key: str) -> bool:
    if key in definitions:
        return True
    v2_defs = definitions.get("v2")
    if isinstance(v2_defs, dict):
        return key in v2_defs
    return False


def main(*, emit_json: bool = False) -> int:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    fixture_dir = MANIFEST_PATH.parent
    report = {
        "manifest_path": str(MANIFEST_PATH),
        "manifest_version": manifest["manifest_version"],
        "checks": [],
        "errors": [],
        "ok": True,
    }

    def record_check(name: str, ok: bool) -> None:
        report["checks"].append({"name": name, "ok": ok})
        if not ok:
            report["ok"] = False
            report["errors"].append(name)

    # manifest shape
    ok = (
        manifest.get("manifest_version") == "1"
        and isinstance(manifest.get("assertions"), dict)
        and isinstance(manifest["assertions"].get("required_fixture_ids"), list)
    )
    record_check("fixture manifest v1", ok)

    fixtures = {entry["id"]: entry for entry in manifest["fixtures"]}
    required = set(manifest["assertions"]["required_fixture_ids"])

    # file checks + hashes
    checks_ok = True
    for fixture_id in sorted(required):
        entry = fixtures[fixture_id]
        if entry["status"] != "available":
            checks_ok = False
            continue
        path = fixture_dir / entry["file"]
        if not path.is_file():
            checks_ok = False
            continue
        if _sha256_hex(path) != entry["sha256"]:
            checks_ok = False
    record_check("fixture checksums", checks_ok)

    # schema digest check (also serves as app-server schema proof check)
    schema_entry = fixtures["app_server_protocol_schema"]
    schema_text = (fixture_dir / schema_entry["file"]).read_text(encoding="utf-8")
    parsed = json.loads(schema_text)
    schema_ok = (
        parsed.get("title") == "CodexAppServerProtocol"
        and "definitions" in parsed
        and all(
            _definition_contains(parsed["definitions"], k)
            for k in ("ThreadStartParams", "ThreadRealtimeStartTransport")
        )
        and "DynamicToolCallResponse" in parsed["definitions"]
    )
    record_check("app-server schema digest", schema_ok)

    # dynamic tool request/response fixture sanity
    request = json.loads((fixture_dir / fixtures["tool_call_request"]["file"]).read_text(encoding="utf-8"))
    response = json.loads((fixture_dir / fixtures["tool_call_response"]["file"]).read_text(encoding="utf-8"))
    tool_ok = (
        request.get("method") == "item/tool/call"
        and request.get("id") == response.get("id")
        and request.get("params", {}).get("tool") == "echo_probe"
        and isinstance(response.get("result", {}).get("contentItems"), list)
        and response.get("result", {}).get("success") is True
    )
    record_check("dynamic tool request/response", tool_ok)

    # transcript replay duplicate check
    duplicate_count = 0
    seen = set()
    lines = (fixture_dir / fixtures["transcript_replay"]["file"]).read_text(encoding="utf-8").splitlines()
    total = 0
    for raw in lines:
        if not raw.strip():
            continue
        total += 1
        rec = json.loads(raw)
        item_id = rec.get("item_id")
        if item_id in seen:
            duplicate_count += 1
        else:
            seen.add(item_id)

    transcript_ok = (
        total == fixtures["transcript_replay"]["expected"]["expected_items"]
        and duplicate_count == fixtures["transcript_replay"]["expected"]["expected_duplicates"]
    )
    record_check(f"transcript replay: {duplicate_count} duplicates", transcript_ok)

    # redaction scan over every available fixture
    redaction_ok = True
    for entry in fixtures.values():
        if entry["status"] != "available":
            continue
        path = fixture_dir / entry["file"]
        if not path.is_file():
            redaction_ok = False
            continue
        if _scan_text_secrets(path.read_text(encoding="utf-8")):
            redaction_ok = False
    record_check("redaction scan", redaction_ok)

    # report
    if emit_json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0 if report["ok"] else 2

    if report["ok"]:
        print("PASS fixture manifest v1")
        print("PASS app-server schema digest")
        print("PASS dynamic tool request/response")
        print(f"PASS transcript replay: {duplicate_count} duplicates")
        print("PASS redaction scan")
        print(f"READY fixture path {fixture_dir}")
        return 0

    print("FAILED checks:")
    for name in report["errors"]:
        print(f"- {name}")
    return 2


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true", help="emit JSON report instead of human text")
    args = parser.parse_args()
    raise SystemExit(main(emit_json=args.json))

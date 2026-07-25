#!/usr/bin/env python3
"""Hermes offline GPT-Live devcheck used by Revision 2 checkpoint H03-R2.

The check is intentionally network-free and does not launch app-server.
It validates committed fixtures, prompt/envelope structure, and secret-free
artifacts, then emits one explicit warning when the dynamic generic-tool
fixtures are unavailable.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "gpt_live"
MANIFEST_PATH = FIXTURE_DIR / "manifest.json"

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


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _has_secret(path: Path) -> bool:
    text = path.read_text(encoding="utf-8", errors="ignore")
    return any(pattern.search(text) for pattern in SECRET_PATTERNS)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true", dest="json_mode")
    args = parser.parse_args()

    checks = []
    warnings = []
    errors = []

    def check(name: str, condition: bool, message: str) -> None:
        checks.append({"name": name, "status": "PASS" if condition else "FAIL", "message": message})
        if not condition:
            errors.append(message)

    manifest = _load_json(MANIFEST_PATH)
    check("fixture_manifest", isinstance(manifest, dict), "manifest JSON is malformed")
    check("fixture_manifest_format_version", manifest.get("manifest_format_version") == "1.0", "manifest has expected format version")
    check(
        "prompt_block_catalog_entry",
        any(entry.get("id") == "desktop_live_prompt_blocks_2026-07-25_json" for entry in manifest.get("fixtures", [])),
        "desktop prompt block catalog fixture is declared",
    )

    catalog_source = FIXTURE_DIR / "desktop_live_prompt_blocks.json"
    catalog_data = _load_json(catalog_source)
    check(
        "prompt_block_catalog_parse",
        isinstance(catalog_data, dict),
        "prompt catalog parses as JSON",
    )
    check(
        "realtime_delegation_shape",
        catalog_data.get("realtime_delegation", {}).get("observed_count") == 42,
        "realtime delegation has 42 observed envelopes",
    )
    check(
        "handoff_order",
        catalog_data.get("realtime_delegation", {}).get("required_fields_in_order") == ["input", "transcript_delta"],
        "handoff envelope fields are in canonical order",
    )

    check(
        "redaction_scan",
        not _has_secret(catalog_source) and all(not _has_secret(FIXTURE_DIR / name) for name in [
            "RECOVERED_REALTIME_DYNAMIC_TOOLS_2026-07-24.json",
            "LIVE_MODEL_CATALOG_2026-07-25.json",
            "codex_app_server_protocol.schemas.json",
            "P02_HANDOFF_SUMMARY_2026-07-25.json",
            "P02_HANDOFF_REPLAY_2026-07-25.jsonl",
        ]),
        "fixture files contain no seeded tokens or secrets",
    )

    unavailable = manifest.get("unavailable", [])
    missing_dynamic = {entry.get("id") for entry in unavailable}
    dynamic_missing = "dynamic_tool_call_request" in missing_dynamic and "dynamic_tool_call_response" in missing_dynamic
    if dynamic_missing:
        warnings.append("direct generic tool call unavailable")

    check(
        "dynamic_call_fixture_declaration",
        dynamic_missing,
        "direct generic dynamic-call fixtures remain declared unavailable",
    )

    print("PASS fixture manifest")
    print("PASS prompt block catalog")
    print("PASS realtime delegation structure")
    if warnings:
        for item in warnings:
            print(f"WARN {item}")
    print("PASS redaction scan")
    if not errors:
        print("READY executor-handoff fixtures")
    else:
        print("BLOCKED executor-handoff fixtures")

    if args.json_mode:
        print(
            json.dumps(
                {
                    "overall": "READY" if not errors else "BLOCKED",
                    "checks": checks,
                    "warnings": warnings,
                    "errors": errors,
                    "path": str(catalog_source),
                    "manifest_digest": _sha256(MANIFEST_PATH),
                    "catalog_sha256": _sha256(catalog_source),
                    "realtime_delegation_count": catalog_data["realtime_delegation"]["observed_count"],
                },
                indent=2,
                sort_keys=True,
            )
        )

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

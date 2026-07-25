"""Pure tests for the H05 Hermes Codex auth-source resolver."""

from __future__ import annotations

import base64
import json
import time

from agent.transports.codex_realtime import resolve_codex_live_auth_source


def _jwt(claims: dict) -> str:
    def part(value: object) -> str:
        raw = json.dumps(value, separators=(",", ":")).encode()
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    return f"{part({'alg': 'none'})}.{part(claims)}.signature"


def _resolver(token: str, **extra):
    payload = {"api_key": token, "source": "hermes-auth-store", **extra}
    return lambda: payload


def test_resolves_existing_hermes_codex_credential_and_claims():
    token = _jwt({
        "exp": time.time() + 3600,
        "https://api.openai.com/auth": {
            "chatgpt_account_id": "acct-live",
            "chatgpt_plan_type": "pro",
        },
    })

    result = resolve_codex_live_auth_source(_resolver(token))

    assert result.mode == "external"
    assert result.source == "hermes-auth-store"
    assert result.account_id == "acct-live"
    assert result.plan_type == "pro"
    assert result.access_token == token
    assert token not in repr(result)


def test_missing_credentials_selects_bundled_managed_path():
    result = resolve_codex_live_auth_source(
        lambda: (_ for _ in ()).throw(RuntimeError("no stored credential"))
    )

    assert result.mode == "managed"
    assert result.source == "bundled_codex"
    assert result.status == "unavailable"
    assert result.access_token is None


def test_expired_token_is_not_exported():
    token = _jwt({
        "exp": time.time() - 1,
        "https://api.openai.com/auth": {"chatgpt_account_id": "acct-live"},
    })

    result = resolve_codex_live_auth_source(_resolver(token))

    assert result.status == "unavailable"
    assert result.error_code == "expired_access_token"
    assert result.access_token is None


def test_quota_error_is_classified_without_fallback_account():
    from hermes_cli.auth import AuthError, CODEX_RATE_LIMITED_CODE

    result = resolve_codex_live_auth_source(
        lambda: (_ for _ in ()).throw(
            AuthError("quota", provider="openai-codex", code=CODEX_RATE_LIMITED_CODE)
        )
    )

    assert result.mode == "external"
    assert result.status == "quota_exhausted"
    assert result.error_code == CODEX_RATE_LIMITED_CODE


def test_malformed_token_is_not_treated_as_managed_external_credential():
    result = resolve_codex_live_auth_source(_resolver("not-a-jwt"))

    assert result.mode == "managed"
    assert result.error_code == "malformed_access_token"
    assert result.access_token is None


def test_flat_account_and_plan_claims_are_supported():
    token = _jwt({
        "exp": time.time() + 3600,
        "chatgpt_account_id": "acct-flat",
        "plan_type": "team",
    })

    result = resolve_codex_live_auth_source(_resolver(token, source="credential_pool"))

    assert result.available
    assert result.account_id == "acct-flat"
    assert result.plan_type == "team"
    assert result.source == "credential_pool"


def test_missing_account_claim_does_not_export_seeded_secret():
    token = _jwt({"exp": time.time() + 3600})

    result = resolve_codex_live_auth_source(_resolver(token, source="seeded-secret"))

    assert result.mode == "managed"
    assert result.error_code == "missing_account_id"
    assert result.access_token is None


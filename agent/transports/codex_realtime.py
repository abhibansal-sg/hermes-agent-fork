"""Small Hermes-owned seams used by the GPT-Live realtime adapter.

This module deliberately does not own a credential store, refresh loop, tool
registry, or realtime subprocess.  Credential resolution delegates to the
existing Hermes Codex resolver and returns only the in-memory access material
needed by the later app-server preflight.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping, Optional

from hermes_cli import auth as auth_module


@dataclass(frozen=True)
class CodexLiveAuthSource:
    """Sanitized classification of the credential source for Live.

    ``access_token`` is intentionally excluded from repr so accidental
    diagnostics cannot print it.  It is retained only in memory for the
    external ``chatgptAuthTokens`` request in H06.
    """

    mode: str
    source: str
    status: str
    account_id: Optional[str] = None
    plan_type: Optional[str] = None
    access_token: Optional[str] = field(default=None, repr=False, compare=False)
    error_code: Optional[str] = None

    @property
    def available(self) -> bool:
        return self.status == "available"

    @property
    def safe_label(self) -> str:
        return f"{self.mode}:{self.source}:{self.status}"


def _claim_string(claims: Mapping[str, Any], *names: str) -> Optional[str]:
    for name in names:
        value = claims.get(name)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _codex_claims(token: Any) -> Mapping[str, Any]:
    claims = auth_module._decode_jwt_claims(token)
    if not isinstance(claims, Mapping):
        return {}
    return claims


def _account_and_plan(claims: Mapping[str, Any]) -> tuple[Optional[str], Optional[str]]:
    auth_claim = claims.get("https://api.openai.com/auth")
    nested = auth_claim if isinstance(auth_claim, Mapping) else {}
    account_id = _claim_string(
        nested,
        "chatgpt_account_id",
        "account_id",
    ) or _claim_string(
        claims,
        "chatgpt_account_id",
        "account_id",
    )
    plan_type = _claim_string(
        nested,
        "chatgpt_plan_type",
        "plan_type",
        "plan",
    ) or _claim_string(
        claims,
        "chatgpt_plan_type",
        "plan_type",
        "plan",
    )
    return account_id, plan_type


def _token_status(token: str, claims: Mapping[str, Any]) -> Optional[str]:
    if not token:
        return "missing_access_token"
    if not claims:
        return "malformed_access_token"
    exp = claims.get("exp")
    if isinstance(exp, (int, float)) and float(exp) <= time.time():
        return "expired_access_token"
    return None


def resolve_codex_live_auth_source(
    resolver: Callable[[], Mapping[str, Any]] = auth_module.resolve_codex_runtime_credentials,
) -> CodexLiveAuthSource:
    """Resolve existing Hermes Codex OAuth for a Live preflight.

    The resolver is injectable solely for pure tests.  Production callers use
    ``hermes_cli.auth.resolve_codex_runtime_credentials`` and therefore keep
    Hermes as the refresh and credential-pool authority.
    """
    try:
        credentials = resolver()
    except auth_module.AuthError as exc:
        code = str(getattr(exc, "code", None) or "auth_error")
        if code == getattr(auth_module, "CODEX_RATE_LIMITED_CODE", "codex_rate_limited"):
            return CodexLiveAuthSource(
                mode="external", source="hermes", status="quota_exhausted", error_code=code
            )
        return CodexLiveAuthSource(
            mode="managed", source="bundled_codex", status="unavailable", error_code=code
        )
    except Exception:
        return CodexLiveAuthSource(
            mode="managed", source="bundled_codex", status="unavailable", error_code="auth_error"
        )

    if not isinstance(credentials, Mapping):
        return CodexLiveAuthSource(
            mode="managed", source="bundled_codex", status="unavailable", error_code="invalid_credentials"
        )

    token = credentials.get("api_key")
    token = token.strip() if isinstance(token, str) else ""
    claims = _codex_claims(token)
    token_error = _token_status(token, claims)
    if token_error:
        return CodexLiveAuthSource(
            mode="managed",
            source="bundled_codex",
            status="unavailable",
            error_code=token_error,
        )

    account_id, plan_type = _account_and_plan(claims)
    if not account_id:
        return CodexLiveAuthSource(
            mode="managed",
            source="bundled_codex",
            status="unavailable",
            error_code="missing_account_id",
        )

    source = str(credentials.get("source") or "hermes").strip() or "hermes"
    return CodexLiveAuthSource(
        mode="external",
        source=source,
        status="available",
        account_id=account_id,
        plan_type=plan_type,
        access_token=token,
    )


# Short alias for callers that do not need to name the implementation detail.
resolve_live_auth_source = resolve_codex_live_auth_source


LIVE_AUTH_BRIDGE_UNSUPPORTED = "live_auth_bridge_unsupported"
_SECRET_KEYS = frozenset({
    "accessToken",
    "access_token",
    "refreshToken",
    "refresh_token",
    "authorization",
    "cookie",
    "cookies",
})


@dataclass(frozen=True)
class CodexAuthPreflight:
    """Pure app-server auth plan; execution remains owned by the caller."""

    mode: str
    login_method: Optional[str]
    login_params: Optional[dict[str, str]]
    read_method: str = "account/read"
    read_params: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class CodexAccountVerification:
    ok: bool
    code: str
    account_id: Optional[str] = field(default=None, repr=False)


def build_external_login_request(source: CodexLiveAuthSource) -> dict[str, Any]:
    """Build the memory-only app-server external login request."""
    if source.mode != "external" or not source.available:
        raise ValueError("external Codex auth is not available")
    if not source.access_token or not source.account_id:
        raise ValueError("external Codex auth is incomplete")
    params: dict[str, Any] = {
        "type": "chatgptAuthTokens",
        "accessToken": source.access_token,
        "chatgptAccountId": source.account_id,
    }
    if source.plan_type:
        params["chatgptPlanType"] = source.plan_type
    return {"method": "account/login/start", "params": params}


def build_account_read_request() -> dict[str, Any]:
    return {"method": "account/read", "params": {}}


def build_auth_preflight(source: CodexLiveAuthSource) -> CodexAuthPreflight:
    """Select external memory-login or bundled managed-auth compatibility."""
    if source.mode == "external" and source.available:
        request = build_external_login_request(source)
        return CodexAuthPreflight(
            mode="external",
            login_method=request["method"],
            login_params=request["params"],
        )
    return CodexAuthPreflight(
        mode="managed",
        login_method=None,
        login_params=None,
    )


def verify_codex_account(
    response: Mapping[str, Any], expected_account_id: str
) -> CodexAccountVerification:
    """Verify account/read is a ChatGPT account for the expected identity."""
    account = response.get("account")
    if not isinstance(account, Mapping):
        account = response
    account_type = (
        account.get("type")
        or account.get("accountType")
        or account.get("account_type")
    )
    if str(account_type or "").strip().lower() not in {"chatgpt", "chatgpt_account"}:
        return CodexAccountVerification(False, "account_type_mismatch")
    account_id = _claim_string(
        account,
        "chatgptAccountId",
        "chatgpt_account_id",
        "id",
    )
    if not account_id or account_id != expected_account_id:
        return CodexAccountVerification(False, "account_identity_mismatch")
    return CodexAccountVerification(True, "verified", account_id)


def classify_external_login_error(error: BaseException) -> str:
    """Map app-server rejection to a stable, non-sensitive classification."""
    code = str(getattr(error, "code", "") or "").lower()
    message = str(getattr(error, "message", "") or error).lower()
    unsupported_markers = (
        "chatgpTauthtokens".lower(),
        "unsupported",
        "invalid params",
        "unknown auth",
        "method not found",
    )
    if code in {"-32601", "-32602", LIVE_AUTH_BRIDGE_UNSUPPORTED} or any(
        marker in message for marker in unsupported_markers
    ):
        return LIVE_AUTH_BRIDGE_UNSUPPORTED
    return "live_auth_bridge_failed"


def redact_auth_payload(value: Any) -> Any:
    """Return evidence-safe data without tokens, cookies, or auth headers."""
    if isinstance(value, Mapping):
        return {
            str(key): "[REDACTED]" if str(key) in _SECRET_KEYS else redact_auth_payload(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact_auth_payload(item) for item in value]
    if isinstance(value, tuple):
        return tuple(redact_auth_payload(item) for item in value)
    return value


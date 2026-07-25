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
    login_params: Optional[dict[str, str]] = field(repr=False)
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


# Protocol bounds are byte bounds because the app-server wire is UTF-8.
MAX_SDP_BYTES = 524_288
MAX_CONTROL_STRING_BYTES = 16_384
MAX_ATTESTATION_BYTES = 16_384
DEFAULT_QUOTA_COOLDOWN_SECONDS = 300.0
MAX_QUOTA_COOLDOWN_SECONDS = 3_600.0


def _bounded_string(value: Any, *, name: str, limit: int) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a string")
    if len(value.encode("utf-8")) > limit:
        raise ValueError(f"{name} exceeds {limit} UTF-8 bytes")
    return value


def build_initialize_request(
    *, client_name: str = "hermes", client_title: str = "Hermes Agent", client_version: str = "0.1"
) -> dict[str, Any]:
    return {
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": _bounded_string(client_name, name="client_name", limit=MAX_CONTROL_STRING_BYTES),
                "title": _bounded_string(client_title, name="client_title", limit=MAX_CONTROL_STRING_BYTES),
                "version": _bounded_string(client_version, name="client_version", limit=MAX_CONTROL_STRING_BYTES),
            },
            "capabilities": {},
        },
    }


def build_thread_start_request(
    cwd: str, *, enable_realtime: bool = True, config: Optional[Mapping[str, Any]] = None
) -> dict[str, Any]:
    params: dict[str, Any] = {"cwd": _bounded_string(cwd, name="cwd", limit=MAX_CONTROL_STRING_BYTES)}
    if enable_realtime:
        params["config"] = {
            "features.realtime_conversation": True,
            "realtime": {},
            **dict(config or {}),
        }
    elif config is not None:
        params["config"] = dict(config)
    return {"method": "thread/start", "params": params}


def build_realtime_start_request(
    thread_id: str,
    *,
    prompt: str,
    sdp: Optional[str] = None,
    model: str = "gpt-live-1-codex",
    voice: str = "sol",
    version: str = "v3",
    output_modality: str = "audio",
    initial_items: Optional[list[dict[str, str]]] = None,
    client_managed_handoffs: bool = False,
) -> dict[str, Any]:
    prompt = _bounded_string(prompt, name="prompt", limit=MAX_CONTROL_STRING_BYTES)
    params: dict[str, Any] = {
        "threadId": _bounded_string(thread_id, name="thread_id", limit=MAX_CONTROL_STRING_BYTES),
        "realtimeSessionId": None,
        "model": _bounded_string(model, name="model", limit=MAX_CONTROL_STRING_BYTES),
        "voice": _bounded_string(voice, name="voice", limit=MAX_CONTROL_STRING_BYTES),
        "version": _bounded_string(version, name="version", limit=MAX_CONTROL_STRING_BYTES),
        "outputModality": output_modality,
        "prompt": prompt,
        "initialItems": list(initial_items or []),
        "includeStartupContext": False,
        "flushTranscriptTailOnSessionEnd": True,
        "codexResponseHandoffMode": "bemTags",
        "codexResponseItemPrefix": None,
        "codexResponsesAsItems": False,
        "clientManagedHandoffs": client_managed_handoffs,
        "transport": {"type": "webrtc"},
    }
    if sdp is not None:
        params["transport"] = {
            "type": "webrtc",
            "sdp": _bounded_string(sdp, name="sdp", limit=MAX_SDP_BYTES),
        }
    return {"method": "thread/realtime/start", "params": params}


def build_realtime_sdp_request(thread_id: str, sdp: str, *, realtime_session_id: Optional[str] = None) -> dict[str, Any]:
    params: dict[str, Any] = {
        "threadId": _bounded_string(thread_id, name="thread_id", limit=MAX_CONTROL_STRING_BYTES),
        "sdp": _bounded_string(sdp, name="sdp", limit=MAX_SDP_BYTES),
    }
    if realtime_session_id is not None:
        params["realtimeSessionId"] = _bounded_string(
            realtime_session_id, name="realtime_session_id", limit=MAX_CONTROL_STRING_BYTES
        )
    return {"method": "thread/realtime/sdp", "params": params}


def build_attestation_request() -> dict[str, Any]:
    return {"method": "attestation/generate", "params": {}}


def build_realtime_control_request(
    action: str, thread_id: str, *, realtime_session_id: Optional[str] = None
) -> dict[str, Any]:
    if action not in {"detach", "reconnect", "stop"}:
        raise ValueError("unsupported realtime control action")
    params: dict[str, Any] = {
        "threadId": _bounded_string(thread_id, name="thread_id", limit=MAX_CONTROL_STRING_BYTES)
    }
    if realtime_session_id is not None:
        params["realtimeSessionId"] = _bounded_string(
            realtime_session_id, name="realtime_session_id", limit=MAX_CONTROL_STRING_BYTES
        )
    return {"method": f"thread/realtime/{action}", "params": params}


@dataclass
class RealtimeLifecycle:
    """App-server realtime transport lifecycle, without executor handoff."""

    client: Any
    thread_id: Optional[str] = None
    realtime_session_id: Optional[str] = None
    generation: int = 0
    state: str = "idle"
    cooldown_until: float = 0.0
    auth_status: str = "unverified"

    def is_current(self, generation: int) -> bool:
        return generation == self.generation

    def start(
        self,
        *,
        cwd: str,
        prompt: str,
        auth_source: Optional[CodexLiveAuthSource] = None,
        attestation: Optional[str] = None,
    ) -> dict[str, Any]:
        if self.cooldown_remaining() > 0:
            raise RuntimeError("realtime quota cooldown active")
        if auth_source is not None:
            plan = build_auth_preflight(auth_source)
            if plan.mode == "external":
                try:
                    self.client.request(plan.login_method, plan.login_params, timeout=15)
                except Exception as exc:
                    self.auth_status = classify_external_login_error(exc)
                    self.state = "stopped"
                    return {"status": self.auth_status}
                account = self.client.request("account/read", {}, timeout=15)
                verification = verify_codex_account(account, auth_source.account_id or "")
                if not verification.ok:
                    self.auth_status = verification.code
                    self.state = "stopped"
                    return {"status": verification.code}
                self.auth_status = "verified"
            else:
                self.auth_status = "managed_auth"
        self.client.initialize(client_name="hermes", client_title="Hermes Agent", client_version="r2", timeout=15)
        thread_response = self.client.request(
            "thread/start", build_thread_start_request(cwd)["params"], timeout=15
        )
        thread = thread_response.get("thread") if isinstance(thread_response, Mapping) else None
        self.thread_id = (
            (thread or {}).get("id")
            or (thread or {}).get("sessionId")
            or thread_response.get("threadId")
        )
        if not self.thread_id:
            raise RuntimeError("thread/start returned no thread id")
        start_params = build_realtime_start_request(self.thread_id, prompt=prompt)["params"]
        if attestation is not None:
            start_params["attestationToken"] = _bounded_string(
                attestation, name="attestation", limit=MAX_ATTESTATION_BYTES
            )
        started = self.client.request("thread/realtime/start", start_params, timeout=45)
        self.realtime_session_id = started.get("realtimeSessionId") if isinstance(started, Mapping) else None
        self.generation += 1
        self.state = "active"
        return {"status": "started", "generation": self.generation, "threadId": self.thread_id}

    def request_attestation(self) -> str:
        response = self.client.request("attestation/generate", {}, timeout=10)
        token = response.get("token") if isinstance(response, Mapping) else None
        return _bounded_string(token, name="attestation", limit=MAX_ATTESTATION_BYTES)

    def send_sdp(self, sdp: str) -> Mapping[str, Any]:
        request = build_realtime_sdp_request(
            self.thread_id or "", sdp, realtime_session_id=self.realtime_session_id
        )
        return self.client.request(request["method"], request["params"], timeout=45)

    def detach(self) -> Mapping[str, Any]:
        request = build_realtime_control_request(
            "detach", self.thread_id or "", realtime_session_id=self.realtime_session_id
        )
        result = self.client.request(request["method"], request["params"], timeout=15)
        self.state = "detached"
        return result

    def reconnect(self) -> Mapping[str, Any]:
        request = build_realtime_control_request(
            "reconnect", self.thread_id or "", realtime_session_id=self.realtime_session_id
        )
        result = self.client.request(request["method"], request["params"], timeout=120)
        self.state = "active"
        return result

    def stop(self) -> Mapping[str, Any]:
        request = build_realtime_control_request(
            "stop", self.thread_id or "", realtime_session_id=self.realtime_session_id
        )
        result = self.client.request(request["method"], request["params"], timeout=15)
        self.state = "stopped"
        self.generation += 1
        return result

    def record_quota_cooldown(self, retry_after: Optional[float] = None, *, now: Optional[float] = None) -> float:
        delay = DEFAULT_QUOTA_COOLDOWN_SECONDS if retry_after is None else max(0.0, float(retry_after))
        delay = min(delay, MAX_QUOTA_COOLDOWN_SECONDS)
        self.cooldown_until = (time.time() if now is None else now) + delay
        return delay

    def cooldown_remaining(self, *, now: Optional[float] = None) -> float:
        current = time.time() if now is None else now
        return max(0.0, self.cooldown_until - current)

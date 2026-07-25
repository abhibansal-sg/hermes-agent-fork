"""H07 realtime lifecycle tests with a fake app-server client."""

from __future__ import annotations

from agent.transports.codex_realtime import (
    CodexLiveAuthSource,
    LIVE_AUTH_BRIDGE_UNSUPPORTED,
    RealtimeLifecycle,
)


class FakeClient:
    def __init__(self, *, reject_login=False):
        self.calls = []
        self.reject_login = reject_login

    def initialize(self, **kwargs):
        self.calls.append(("initialize", kwargs))
        return {"userAgent": "test"}

    def request(self, method, params=None, timeout=0):
        self.calls.append((method, params, timeout))
        if method == "account/login/start" and self.reject_login:
            class Rejected(RuntimeError):
                code = -32602
                message = "chatgptAuthTokens unsupported"
            raise Rejected()
        if method == "account/read":
            return {"account": {"type": "chatgpt", "id": "acct-1"}}
        if method == "thread/start":
            return {"thread": {"id": "thread-1"}}
        if method == "thread/realtime/start":
            return {"realtimeSessionId": "rt-1"}
        if method == "attestation/generate":
            return {"token": "attestation"}
        return {}


def _source():
    return CodexLiveAuthSource(
        mode="external", source="hermes-auth-store", status="available",
        account_id="acct-1", access_token="memory-token",
    )


def test_lifecycle_auth_preflight_and_transport_start_use_one_generation():
    client = FakeClient()
    lifecycle = RealtimeLifecycle(client)

    result = lifecycle.start(cwd="/work", prompt="Be concise", auth_source=_source())

    assert result == {"status": "started", "generation": 1, "threadId": "thread-1"}
    assert lifecycle.auth_status == "verified"
    assert lifecycle.state == "active"
    assert [call[0] for call in client.calls] == [
        "account/login/start", "account/read", "initialize", "thread/start", "thread/realtime/start"
    ]


def test_unsupported_external_login_stops_without_realtime_start():
    client = FakeClient(reject_login=True)
    lifecycle = RealtimeLifecycle(client)

    result = lifecycle.start(cwd="/work", prompt="Be concise", auth_source=_source())

    assert result["status"] == LIVE_AUTH_BRIDGE_UNSUPPORTED
    assert lifecycle.state == "stopped"
    assert [call[0] for call in client.calls] == ["account/login/start"]


def test_attestation_sdp_detach_reconnect_stop_and_generation_fence():
    client = FakeClient()
    lifecycle = RealtimeLifecycle(client, thread_id="thread-1", realtime_session_id="rt-1", generation=4, state="active")

    assert lifecycle.request_attestation() == "attestation"
    assert lifecycle.send_sdp("answer") == {}
    assert lifecycle.detach() == {}
    assert lifecycle.state == "detached"
    assert lifecycle.reconnect() == {}
    assert lifecycle.state == "active"
    assert lifecycle.is_current(4)
    lifecycle.stop()
    assert lifecycle.state == "stopped"
    assert not lifecycle.is_current(4)


def test_quota_cooldown_defaults_and_caps():
    lifecycle = RealtimeLifecycle(FakeClient())

    assert lifecycle.record_quota_cooldown(now=100.0) == 300.0
    assert lifecycle.cooldown_remaining(now=200.0) == 200.0
    assert lifecycle.record_quota_cooldown(9999, now=100.0) == 3600.0
    assert lifecycle.cooldown_remaining(now=3700.0) == 0.0

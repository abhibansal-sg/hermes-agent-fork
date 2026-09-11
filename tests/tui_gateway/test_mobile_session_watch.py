import threading
import types
from tui_gateway import server

def _session(**kwargs):
    return {"history_lock": threading.Lock(), "history": [], "running": False, **kwargs}

def test_session_watch_by_key_returns_snapshot_without_rebinding(monkeypatch):
    """A read-only observer must never steal the live session's event stream."""
    owner_transport = object()
    observer_transport = object()
    session = _session(
        agent=types.SimpleNamespace(model="model-live"),
        history=[{"role": "user", "content": "keep going"}],
        inflight_turn={
            "assistant": "working",
            "streaming": True,
            "user": "keep going",
        },
        running=True,
        session_key="key-live",
        created_at=10.0,
        last_active=20.0,
        cols=91,
        transport=owner_transport,
    )
    server._sessions["sid-live"] = session
    monkeypatch.setattr(server, "_get_db", lambda: None)
    monkeypatch.setattr(server, "_session_info", lambda agent: {"model": agent.model})

    token = server.bind_transport(observer_transport)
    try:
        resp = server.handle_request(
            {
                "id": "watch",
                "method": "session.watch",
                "params": {"session_key": "key-live", "cols": 140},
            }
        )
    finally:
        server.reset_transport(token)
        server._sessions.pop("sid-live", None)

    assert resp["result"]["session_id"] == "sid-live"
    assert resp["result"]["session_key"] == "key-live"
    assert resp["result"]["running"] is True
    assert resp["result"]["inflight"] == {
        "assistant": "working",
        "streaming": True,
        "user": "keep going",
    }
    assert resp["result"]["messages"] == [{"role": "user", "text": "keep going"}]
    assert session["transport"] is owner_transport
    assert session["last_active"] == 20.0
    assert session["cols"] == 91


def test_session_watch_by_runtime_id_can_omit_messages(monkeypatch):
    session = _session(
        agent=types.SimpleNamespace(model="model-live"),
        history=[
            {"role": "user", "content": "large prompt"},
            {"role": "assistant", "content": "large answer"},
        ],
        session_key="key-live",
        created_at=10.0,
    )
    server._sessions["sid-live"] = session
    monkeypatch.setattr(server, "_session_info", lambda agent: {"model": agent.model})
    try:
        resp = server.handle_request(
            {
                "id": "watch",
                "method": "session.watch",
                "params": {
                    "session_id": "sid-live",
                    "omit_messages": True,
                    "omit_info": True,
                },
            }
        )
    finally:
        server._sessions.pop("sid-live", None)

    assert resp["result"]["messages"] == []
    assert resp["result"]["message_count"] == 2
    assert resp["result"]["messages_omitted"] is True
    assert "info" not in resp["result"]


def test_session_watch_returns_retained_terminal_failure(monkeypatch):
    """A reconnecting native client must recover the provider failure itself."""
    session = _session(
        agent=types.SimpleNamespace(model="model-live"),
        history=[{"role": "user", "content": "draft the follow-up"}],
        inflight_turn={
            "assistant": "",
            "streaming": False,
            "user": "draft the follow-up",
            "status": "error",
            "error": "HTTP 503: all accounts at capacity",
            "recoverable": True,
        },
        running=False,
        session_key="key-failed",
    )
    server._sessions["sid-failed"] = session
    monkeypatch.setattr(server, "_session_info", lambda agent: {"model": agent.model})
    try:
        resp = server.handle_request(
            {
                "id": "watch-failed",
                "method": "session.watch",
                "params": {"session_id": "sid-failed", "omit_messages": True},
            }
        )
    finally:
        server._sessions.pop("sid-failed", None)

    assert resp["result"]["running"] is False
    assert resp["result"]["inflight"] == {
        "assistant": "",
        "streaming": False,
        "user": "draft the follow-up",
        "status": "error",
        "error": "HTTP 503: all accounts at capacity",
        "recoverable": True,
    }


def test_session_watch_rejects_missing_or_finalized_session():
    missing = server.handle_request(
        {
            "id": "missing",
            "method": "session.watch",
            "params": {"session_key": "not-live"},
        }
    )
    assert missing["error"]["code"] == 4001

    dead = _session(session_key="key-dead")
    dead["_finalized"] = True
    server._sessions["sid-dead"] = dead
    try:
        finalized = server.handle_request(
            {
                "id": "finalized",
                "method": "session.watch",
                "params": {"session_id": "sid-dead"},
            }
        )
    finally:
        server._sessions.pop("sid-dead", None)
    assert finalized["error"]["code"] == 4001


def test_gateway_ready_advertises_versioned_session_watch_capability():
    payload = server.gateway_ready_payload({"name": "default"})

    assert payload["skin"] == {"name": "default"}
    assert payload["change_events"] is True
    assert "session_watch_v1" in payload["capabilities"]


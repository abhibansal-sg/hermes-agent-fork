"""Behavior contract for revisioned live-session action authority."""

from __future__ import annotations

import asyncio
import threading

import pytest

from tui_gateway import server
from tui_gateway.transport import AuthenticatedPrincipal, bind_transport, reset_transport
from tui_gateway.ws import WSTransport


class _Transport:
    def __init__(self, subject: str) -> None:
        self.authenticated_principal = AuthenticatedPrincipal(
            subject=subject,
            provider="test",
            credential="ticket",
        )
        self.frames: list[dict] = []

    def write(self, obj: dict) -> bool:
        self.frames.append(obj)
        return True

    def close(self) -> None:
        pass


@pytest.fixture(autouse=True)
def _isolated_sessions(monkeypatch):
    with server._sessions_lock:
        before = dict(server._sessions)
        server._sessions.clear()
    original = server._methods.get("prompt.submit")
    monkeypatch.setitem(
        server._methods,
        "prompt.submit",
        lambda rid, params: server._ok(rid, {"status": "streaming"}),
    )
    yield
    with server._sessions_lock:
        server._sessions.clear()
        server._sessions.update(before)
    if original is not None:
        server._methods["prompt.submit"] = original


def _session(transport=None) -> dict:
    return {
        "session_key": "stored-1",
        "transport": transport,
        "history": [],
        "history_lock": threading.Lock(),
        "created_at": 1.0,
        "last_active": 1.0,
        "running": False,
    }


def _request(transport, method: str, params: dict) -> dict:
    token = bind_transport(transport)
    try:
        response = server.handle_request(
            {"jsonrpc": "2.0", "id": "r1", "method": method, "params": params}
        )
    finally:
        reset_transport(token)
    assert response is not None
    return response


def test_first_mutation_claims_unowned_session_and_same_owner_reuses_revision():
    owner = _Transport("device-a")
    server._sessions["live-1"] = _session(owner)

    first = _request(owner, "prompt.submit", {"session_id": "live-1"})
    assert first["result"]["status"] == "streaming"
    assert server._sessions["live-1"]["action_owner"] == "test:device-a"
    assert server._sessions["live-1"]["action_revision"] == 1

    second = _request(
        owner,
        "prompt.submit",
        {"session_id": "live-1", "expected_action_revision": 1},
    )
    assert second["result"]["status"] == "streaming"
    assert server._sessions["live-1"]["action_revision"] == 1


def test_foreign_owner_and_stale_revision_are_denied_before_handler():
    owner = _Transport("device-a")
    foreign = _Transport("device-b")
    session = _session(owner)
    session.update(action_owner="test:device-a", action_revision=3)
    server._sessions["live-1"] = session

    denied = _request(foreign, "prompt.submit", {"session_id": "live-1"})
    assert denied["error"]["code"] == server.ACTION_OWNER_CONFLICT

    stale = _request(
        owner,
        "prompt.submit",
        {"session_id": "live-1", "expected_action_revision": 2},
    )
    assert stale["error"]["code"] == server.ACTION_REVISION_STALE

    fractional = _request(
        owner,
        "prompt.submit",
        {"session_id": "live-1", "expected_action_revision": 3.5},
    )
    assert fractional["error"]["code"] == -32602


def test_takeover_atomically_changes_owner_revision_and_driver_transport():
    owner = _Transport("device-a")
    successor = _Transport("device-b")
    session = _session(owner)
    session.update(action_owner="test:device-a", action_revision=4)
    server._sessions["live-1"] = session

    result = _request(
        successor,
        "session.takeover",
        {"session_id": "live-1", "expected_action_revision": 4},
    )

    assert result["result"]["action_revision"] == 5
    assert session["action_owner"] == "test:device-b"
    assert session["transport"] is successor


def test_takeover_rejects_stale_revision_without_partial_rebind():
    owner = _Transport("device-a")
    successor = _Transport("device-b")
    session = _session(owner)
    session.update(action_owner="test:device-a", action_revision=4)
    server._sessions["live-1"] = session

    result = _request(
        successor,
        "session.takeover",
        {"session_id": "live-1", "expected_action_revision": 3},
    )

    assert result["error"]["code"] == server.ACTION_REVISION_STALE
    assert session["action_owner"] == "test:device-a"
    assert session["action_revision"] == 4
    assert session["transport"] is owner


def test_resume_completion_cannot_steal_a_concurrent_foreign_claim():
    owner = _Transport("device-a")
    foreign = _Transport("device-b")
    session = _session(foreign)
    session.update(
        action_owner="test:device-a",
        action_revision=2,
        action_transport=owner,
    )
    server._sessions["live-1"] = session
    token = bind_transport(foreign)
    try:
        response = server._complete_session_action(
            "session.resume",
            {"session_id": "stored-1"},
            server._ok("r1", {"session_id": "live-1", "resumed": "stored-1"}),
        )
    finally:
        reset_transport(token)

    assert response["error"]["code"] == server.ACTION_OWNER_CONFLICT
    assert session["action_owner"] == "test:device-a"
    assert session["transport"] is owner


def test_watch_never_claims_or_rebinds_action_authority():
    driver = _Transport("device-a")
    observer = _Transport("device-b")
    session = _session(driver)
    server._sessions["live-1"] = session

    response = _request(observer, "session.watch", {"session_id": "live-1"})

    assert response["result"]["action_revision"] == 0
    assert "action_owner" not in response["result"]
    assert "action_owner" not in session
    assert session["transport"] is driver


def test_request_id_secure_response_resolves_its_owning_session():
    owner = _Transport("device-a")
    foreign = _Transport("device-b")
    session = _session(owner)
    session.update(action_owner="test:device-a", action_revision=2)
    server._sessions["live-1"] = session
    pending_event = threading.Event()
    with server._prompt_lock:
        server._pending["question-1"] = ("live-1", pending_event)
    try:
        denied = _request(
            foreign,
            "clarify.respond",
            {"request_id": "question-1", "answer": "foreign"},
        )
        assert denied["error"]["code"] == server.ACTION_OWNER_CONFLICT
        assert not pending_event.is_set()

        accepted = _request(
            owner,
            "clarify.respond",
            {
                "request_id": "question-1",
                "answer": "mine",
                "expected_action_revision": 2,
            },
        )
        assert accepted["result"]["status"] == "ok"
        assert pending_event.is_set()
    finally:
        with server._prompt_lock:
            server._pending.pop("question-1", None)
            server._answers.pop("question-1", None)


def test_remote_subagent_action_requires_owning_session_selector():
    remote = _Transport("device-a")
    response = _request(
        remote,
        "subagent.interrupt",
        {"subagent_id": "child-1"},
    )
    assert response["error"]["code"] == 4006


def test_ws_transport_carries_authenticated_principal():
    class _WS:
        async def send_text(self, _text: str) -> None:
            pass

    loop = asyncio.new_event_loop()
    try:
        principal = AuthenticatedPrincipal("device-a", "test", "ticket")
        transport = WSTransport(_WS(), loop, principal=principal)
        assert transport.authenticated_principal == principal
    finally:
        loop.close()

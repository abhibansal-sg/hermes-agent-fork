"""Focused contract tests for the Hermes-owned Bot Chat RPC."""

from __future__ import annotations

import contextlib
import threading
from dataclasses import dataclass
from pathlib import Path

import pytest

import tui_gateway.server as server


@dataclass(frozen=True)
class _ProfileInfo:
    name: str
    path: Path


class _FakeSessionDB:
    """Small SessionDB authority double used to test RPC orchestration."""

    def __init__(self) -> None:
        self.rows: dict[str, dict] = {}
        self.create_calls = 0
        self._lock = threading.RLock()

    def get_session(self, session_id: str):
        with self._lock:
            row = self.rows.get(session_id)
            return dict(row) if row else None

    def get_session_by_title(self, title: str):
        with self._lock:
            for row in self.rows.values():
                if row.get("title") == title:
                    return dict(row)
        return None

    def resolve_resume_session_id(self, session_id: str) -> str:
        return session_id

    def create_session(self, session_id: str, source: str, **kwargs) -> str:
        with self._lock:
            self.create_calls += 1
            self.rows[session_id] = {
                "id": session_id,
                "title": None,
                "source": source,
                "hidden": False,
                **kwargs,
            }
        return session_id

    def set_session_title(self, session_id: str, title: str) -> bool:
        with self._lock:
            conflict = next(
                (
                    row
                    for row in self.rows.values()
                    if row.get("id") != session_id and row.get("title") == title
                ),
                None,
            )
            if conflict:
                raise ValueError("title already in use")
            self.rows[session_id]["title"] = title
            return True

    def set_session_hidden(self, session_id: str, hidden: bool) -> bool:
        with self._lock:
            self.rows[session_id]["hidden"] = bool(hidden)
            return True


@pytest.fixture
def rpc_env(tmp_path, monkeypatch):
    profiles = {}
    databases = {}
    for name in ("default", "worker"):
        path = tmp_path / name
        path.mkdir()
        profiles[name] = _ProfileInfo(name, path)
        databases[name] = _FakeSessionDB()

    from hermes_cli import profiles as profiles_mod

    monkeypatch.setattr(
        profiles_mod,
        "list_profiles",
        lambda: list(profiles.values()),
    )

    @contextlib.contextmanager
    def profile_db(params):
        yield databases[params["profile"]]

    monkeypatch.setattr(server, "_profile_db", profile_db)
    sequence = iter(f"bot-chat-{n}" for n in range(100))
    monkeypatch.setattr(server, "_new_session_key", lambda: next(sequence))

    def call(profile: str):
        response = server._methods["profiles.ensure_bot_chat"](
            "request", {"profile": profile}
        )
        return response

    return profiles, databases, call


def _result(response):
    assert "error" not in response, response
    return response["result"]


def test_rpc_is_registered_and_contract_is_durable():
    assert "profiles.ensure_bot_chat" in server._methods


def test_reuses_existing_pinned_chat_and_enforces_hidden(rpc_env):
    profiles, databases, call = rpc_env
    db = databases["default"]
    db.rows["existing"] = {"id": "existing", "title": "Bot Chat", "hidden": False}
    (profiles["default"].path / "profile.yaml").write_text(
        "ui_meta:\n  hermes-bots:\n    chat: existing\n", encoding="utf-8"
    )

    result = _result(call("default"))

    assert result == {
        "session_id": "existing",
        "profile": "default",
        "created": False,
    }
    assert db.create_calls == 0
    assert db.rows["existing"]["hidden"] is True


def test_create_once_is_idempotent_and_pins_server_metadata(rpc_env):
    profiles, databases, call = rpc_env
    first = _result(call("default"))
    second = _result(call("default"))

    assert first["created"] is True
    assert second == {
        "session_id": first["session_id"],
        "profile": "default",
        "created": False,
    }
    db = databases["default"]
    assert db.create_calls == 1
    assert len(db.rows) == 1
    assert next(iter(db.rows.values()))["hidden"] is True
    assert first["session_id"] in (
        profiles["default"].path / "profile.yaml"
    ).read_text(encoding="utf-8")


def test_concurrent_calls_create_one_chat(rpc_env):
    _, databases, call = rpc_env
    from concurrent.futures import ThreadPoolExecutor

    with ThreadPoolExecutor(max_workers=12) as pool:
        responses = list(pool.map(lambda _: call("default"), range(12)))

    results = [_result(response) for response in responses]
    assert {result["session_id"] for result in results} == {"bot-chat-0"}
    assert {result["created"] for result in results} == {True, False}
    assert databases["default"].create_calls == 1


def test_invalid_profile_does_not_mutate_any_store(rpc_env):
    profiles, databases, call = rpc_env
    response = call("missing")

    assert response["error"]["code"] == 4068
    assert all(not db.rows for db in databases.values())
    assert not list(profiles["default"].path.glob("profile.yaml"))


def test_profile_isolation_and_ordinary_pin_recovery(rpc_env):
    profiles, databases, call = rpc_env
    db = databases["default"]
    db.rows["ordinary"] = {"id": "ordinary", "title": "My Notes", "hidden": False}
    (profiles["default"].path / "profile.yaml").write_text(
        "ui_meta:\n  hermes-bots:\n    chat: ordinary\n", encoding="utf-8"
    )

    default_result = _result(call("default"))
    worker_result = _result(call("worker"))

    assert default_result["created"] is True
    assert default_result["session_id"] != "ordinary"
    assert db.rows["ordinary"]["hidden"] is False
    assert worker_result["profile"] == "worker"
    assert worker_result["session_id"] != default_result["session_id"]
    assert databases["worker"].create_calls == 1


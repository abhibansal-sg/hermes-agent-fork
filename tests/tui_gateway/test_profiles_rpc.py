"""Focused contract tests for the Hermes-owned Bot Chat RPC."""

from __future__ import annotations

import contextlib
import multiprocessing
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

import pytest
import yaml

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
        self.delete_calls = 0
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

    def delete_session(self, session_id: str) -> bool:
        with self._lock:
            self.delete_calls += 1
            return self.rows.pop(session_id, None) is not None


class _MissingAfterHideSessionDB(_FakeSessionDB):
    """Simulate a row removed by a concurrent writer after the hide request."""

    def set_session_hidden(self, session_id: str, hidden: bool) -> bool:
        with self._lock:
            self.rows.pop(session_id, None)
        return True


class _VisibleAfterHideSessionDB(_FakeSessionDB):
    """Simulate a broken setter that reports success without applying hide."""

    def set_session_hidden(self, session_id: str, hidden: bool) -> bool:
        return False


def _increment_profile_metadata_counter(profile_dir: str, start, ready) -> None:
    """Exercise the native metadata lock in a separately spawned process."""
    from hermes_cli.profiles import profile_metadata_lock

    counter = Path(profile_dir) / "counter"
    ready.put("ready")
    start.wait(timeout=10)
    with profile_metadata_lock(Path(profile_dir)):
        value = int(counter.read_text(encoding="utf-8"))
        time.sleep(0.02)
        counter.write_text(str(value + 1), encoding="utf-8")


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
    assert "profiles.ensure_bot_chat" in server._LONG_HANDLERS


def test_generic_create_session_persists_title_and_hidden_without_clobbering(tmp_path):
    """The generic SessionDB path atomically creates the canonical row shape."""
    from hermes_state import SessionDB

    db = SessionDB(db_path=tmp_path / "state.db")
    try:
        db.create_session("canonical", "desktop", title="Bot Chat", hidden=True)

        created = db.get_session("canonical")
        assert created is not None
        assert created["title"] == "Bot Chat"
        assert bool(created["hidden"]) is True
        assert "canonical" not in {row["id"] for row in db.list_sessions_rich()}
        assert "canonical" in {
            row["id"] for row in db.list_sessions_rich(include_hidden=True)
        }

        # The generic upsert keeps established session identity/visibility
        # authoritative; a later bare creation cannot expose or retitle it.
        db.create_session("canonical", "desktop", title="Other", hidden=False)
        preserved = db.get_session("canonical")
        assert preserved is not None
        assert preserved["title"] == "Bot Chat"
        assert bool(preserved["hidden"]) is True
    finally:
        db.close()


def test_profile_metadata_lock_fails_closed_serializes_and_releases(tmp_path):
    """Use the native host lock path; never pretend this interpreter is another OS."""
    from hermes_cli.profiles import ProfileMetadataLockUnavailable, profile_metadata_lock

    missing = tmp_path / "missing"
    with pytest.raises(ProfileMetadataLockUnavailable):
        with profile_metadata_lock(missing):
            pytest.fail("a missing profile directory must never write unlocked metadata")

    profile_dir = tmp_path / "profile"
    profile_dir.mkdir()
    counter = profile_dir / "counter"
    counter.write_text("0", encoding="utf-8")
    start = threading.Barrier(12)

    def increment_under_lock() -> None:
        start.wait()
        with profile_metadata_lock(profile_dir):
            value = int(counter.read_text(encoding="utf-8"))
            # Holding the critical section across a yielding operation makes
            # a missing same-process or native lock lose increments reliably.
            time.sleep(0.005)
            counter.write_text(str(value + 1), encoding="utf-8")

    with ThreadPoolExecutor(max_workers=12) as pool:
        list(pool.map(lambda _: increment_under_lock(), range(12)))

    assert counter.read_text(encoding="utf-8") == "12"

    with pytest.raises(RuntimeError):
        with profile_metadata_lock(profile_dir):
            raise RuntimeError("exercise exceptional unlock")
    with profile_metadata_lock(profile_dir):
        counter.write_text("released", encoding="utf-8")
    assert counter.read_text(encoding="utf-8") == "released"


def test_profile_metadata_lock_serializes_native_cross_process_writers(tmp_path):
    """Every process uses its real host lock implementation, never an OS fake."""
    profile_dir = tmp_path / "profile"
    profile_dir.mkdir()
    counter = profile_dir / "counter"
    counter.write_text("0", encoding="utf-8")

    context = multiprocessing.get_context("spawn")
    start = context.Event()
    ready = context.Queue()
    writers = [
        context.Process(
            target=_increment_profile_metadata_counter,
            args=(str(profile_dir), start, ready),
        )
        for _ in range(4)
    ]

    try:
        for writer in writers:
            writer.start()
        for _ in writers:
            assert ready.get(timeout=10) == "ready"
        start.set()
        for writer in writers:
            writer.join(timeout=10)
            assert writer.exitcode == 0
    finally:
        start.set()
        for writer in writers:
            if writer.is_alive():
                writer.terminate()
                writer.join(timeout=5)
        ready.close()

    assert counter.read_text(encoding="utf-8") == str(len(writers))


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


def test_configure_and_ensure_preserve_unrelated_profile_metadata(rpc_env, monkeypatch):
    """Both metadata writers retain each other's namespaces and top-level fields."""
    profiles, _, call = rpc_env
    from hermes_cli import profiles as profiles_mod

    monkeypatch.setattr(profiles_mod, "get_profile_dir", lambda name: str(profiles[name].path))
    metadata_path = profiles["default"].path / "profile.yaml"
    metadata_path.write_text(
        "description: keep this\n"
        "ui_meta:\n"
        "  another-plugin:\n"
        "    preserved: true\n"
        "  hermes-bots:\n"
        "    color: violet\n",
        encoding="utf-8",
    )

    configured = _result(
        server._methods["profiles.configure"](
            "configure-before-ensure",
            {"name": "default", "ui_meta": {"another-plugin": {"updated": True}}},
        )
    )
    assert configured["applied"]["ui_meta"] is True

    ensured = _result(call("default"))
    configured_again = _result(
        server._methods["profiles.configure"](
            "configure-after-ensure",
            {"name": "default", "ui_meta": {"third-plugin": {"enabled": True}}},
        )
    )
    assert configured_again["applied"]["ui_meta"] is True

    metadata = yaml.safe_load(metadata_path.read_text(encoding="utf-8"))
    assert metadata["description"] == "keep this"
    assert metadata["ui_meta"]["another-plugin"] == {"updated": True}
    assert metadata["ui_meta"]["third-plugin"] == {"enabled": True}
    assert metadata["ui_meta"]["hermes-bots"] == {
        "color": "violet",
        "chat": ensured["session_id"],
    }


def test_concurrent_configure_and_ensure_merge_profile_metadata(rpc_env, monkeypatch):
    profiles, _, call = rpc_env
    from hermes_cli import profiles as profiles_mod

    monkeypatch.setattr(profiles_mod, "get_profile_dir", lambda name: str(profiles[name].path))
    metadata_path = profiles["default"].path / "profile.yaml"
    metadata_path.write_text(
        "ui_meta:\n"
        "  existing-plugin:\n"
        "    keep: true\n",
        encoding="utf-8",
    )
    start = threading.Barrier(2)

    def configure():
        start.wait()
        return server._methods["profiles.configure"](
            "configure-concurrently",
            {"name": "default", "ui_meta": {"another-plugin": {"saved": True}}},
        )

    def ensure():
        start.wait()
        return call("default")

    with ThreadPoolExecutor(max_workers=2) as pool:
        configured, ensured = list(pool.map(lambda fn: fn(), (configure, ensure)))

    assert _result(configured)["applied"]["ui_meta"] is True
    ensured_result = _result(ensured)
    metadata = yaml.safe_load(metadata_path.read_text(encoding="utf-8"))
    assert metadata["ui_meta"]["existing-plugin"] == {"keep": True}
    assert metadata["ui_meta"]["another-plugin"] == {"saved": True}
    assert metadata["ui_meta"]["hermes-bots"]["chat"] == ensured_result["session_id"]


def test_repeated_concurrent_calls_are_profile_isolated(rpc_env):
    profiles, databases, call = rpc_env
    names = ["default", "worker"] * 12

    with ThreadPoolExecutor(max_workers=len(names)) as pool:
        responses = list(pool.map(call, names))

    by_profile = {name: [] for name in profiles}
    for response in responses:
        result = _result(response)
        by_profile[result["profile"]].append(result)

    ids = {}
    for name, results in by_profile.items():
        ids[name] = {result["session_id"] for result in results}
        assert len(ids[name]) == 1
        assert sum(result["created"] for result in results) == 1
        assert databases[name].create_calls == 1
        row = databases[name].rows[next(iter(ids[name]))]
        assert row["hidden"] is True
        assert row["profile_name"] == (None if name == "default" else name)

    assert ids["default"].isdisjoint(ids["worker"])


def test_invalid_profile_does_not_mutate_any_store(rpc_env):
    profiles, databases, call = rpc_env
    response = call("missing")

    assert response["error"]["code"] == 4073
    assert all(not db.rows for db in databases.values())
    assert not list(profiles["default"].path.glob("profile.yaml"))


def test_hidden_row_is_verified_after_creation_and_for_existing_pins(rpc_env):
    profiles, databases, call = rpc_env
    missing_row_db = _MissingAfterHideSessionDB()
    databases["default"] = missing_row_db

    missing_row = call("default")
    assert missing_row["error"]["code"] == 5073
    assert missing_row_db.rows == {}
    assert missing_row_db.delete_calls == 1
    assert not (profiles["default"].path / "profile.yaml").exists()

    visible_row_db = _VisibleAfterHideSessionDB()
    visible_row_db.rows["existing"] = {
        "id": "existing",
        "title": "Bot Chat",
        "hidden": False,
    }
    databases["worker"] = visible_row_db

    visible_row = call("worker")
    assert visible_row["error"]["code"] == 5073
    assert visible_row_db.rows["existing"]["hidden"] is False
    assert visible_row_db.create_calls == 0
    assert not (profiles["worker"].path / "profile.yaml").exists()


def test_yaml_failure_cleans_a_new_row_before_a_later_retry(rpc_env, monkeypatch):
    profiles, databases, call = rpc_env
    import utils

    with monkeypatch.context() as failure:
        def fail_atomic_yaml_write(*_args, **_kwargs):
            raise OSError("disk full")

        failure.setattr(utils, "atomic_yaml_write", fail_atomic_yaml_write)
        response = call("default")

    assert response["error"]["code"] == 5073
    assert databases["default"].rows == {}
    assert databases["default"].delete_calls == 1
    assert not (profiles["default"].path / "profile.yaml").exists()

    recovered = _result(call("default"))
    assert recovered["created"] is True
    assert databases["default"].create_calls == 2
    assert databases["default"].rows[recovered["session_id"]]["hidden"] is True


def test_bot_chat_capability_requires_every_profile_scoped_session_route(monkeypatch):
    """The ready bit is withheld when open/list/watch cannot honor a profile."""
    assert server.BOT_CHAT_CAPABILITY in server.gateway_ready_payload({})["capabilities"]

    original_methods = server._methods
    original_profile_home = server._profile_home
    original_profile_db = server._profile_db
    for missing in (
        "profiles.ensure_bot_chat",
        "session.create",
        "session.list",
        "session.resume",
        "session.set_hidden",
        "session.watch",
    ):
        incomplete_methods = dict(original_methods)
        incomplete_methods.pop(missing)
        monkeypatch.setattr(server, "_methods", incomplete_methods)
        assert server.BOT_CHAT_CAPABILITY not in server.gateway_ready_payload({})["capabilities"]

    monkeypatch.setattr(server, "_methods", original_methods)
    monkeypatch.setattr(server, "_profile_home", None)
    assert server.BOT_CHAT_CAPABILITY not in server.gateway_ready_payload({})["capabilities"]
    monkeypatch.setattr(server, "_profile_home", original_profile_home)
    monkeypatch.setattr(server, "_profile_db", None)
    assert server.BOT_CHAT_CAPABILITY not in server.gateway_ready_payload({})["capabilities"]
    monkeypatch.setattr(server, "_profile_db", original_profile_db)


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

"""H3 durable prompt-admission behavior and thin SQLite provider tests."""

from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import stat
import subprocess
import sys
import threading
import uuid
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

import pytest

import hermes_state
from tui_gateway import prompt_admission, server


_STOCK_PROMPT_HANDLER = server._methods["prompt.submit"]


def _provider_module():
    path = Path(__file__).parents[2] / "plugins" / "hermes-mobile" / "prompt_receipts.py"
    spec = importlib.util.spec_from_file_location("test_mobile_prompt_receipts", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def isolated(tmp_path, monkeypatch):
    prompt_admission._reset_for_tests()
    with server._sessions_lock:
        before_sessions = dict(server._sessions)
        server._sessions.clear()
        server._sessions["live-1"] = {
            "session_key": "stored-1",
            "history": [],
            "history_lock": threading.Lock(),
            "running": False,
            "profile_home": str(tmp_path),
            "transport": server._stdio_transport,
        }
    original = server._methods["prompt.submit"]
    calls: list[dict] = []

    def handler(rid, params):
        calls.append(dict(params))
        return server._ok(rid, {"status": "streaming"})

    monkeypatch.setitem(server._methods, "prompt.submit", handler)
    yield tmp_path, calls
    prompt_admission._reset_for_tests()
    server._methods["prompt.submit"] = original
    with server._sessions_lock:
        server._sessions.clear()
        server._sessions.update(before_sessions)


def _request(client_message_id: str, *, text: str = "hello", **extra_params) -> dict:
    params = {
        "session_id": "live-1",
        "text": text,
        "client_message_id": client_message_id,
    }
    params.update(extra_params)
    response = server.handle_request(
        {
            "jsonrpc": "2.0",
            "id": uuid.uuid4().hex,
            "method": "prompt.submit",
            "params": params,
        }
    )
    assert response is not None
    return response


def test_replay_returns_original_disposition_without_second_handler_execution(isolated):
    _tmp_path, calls = isolated
    receipts = _provider_module()
    provider = receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    prompt_admission.register_prompt_receipt_provider(provider)
    message_id = str(uuid.uuid4())

    first = _request(message_id)
    second = _request(message_id)

    assert first["result"] == {
        "accepted": True,
        "client_message_id": message_id,
        "deduplicated": False,
        "status": "streaming",
    }
    assert second["result"] == {**first["result"], "deduplicated": True}
    assert len(calls) == 1
    assert calls[0]["_admitted_client_message_id"] == message_id


def test_same_id_with_changed_canonical_request_is_rejected(isolated):
    _tmp_path, calls = isolated
    receipts = _provider_module()
    prompt_admission.register_prompt_receipt_provider(
        receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    )
    message_id = str(uuid.uuid4())

    assert "result" in _request(message_id, text="first")
    conflict = _request(message_id, text="changed")

    assert conflict["error"]["code"] == server.PROMPT_ID_CONFLICT
    assert len(calls) == 1


def test_equivalent_confirmation_flag_encodings_replay(isolated):
    _tmp_path, calls = isolated
    receipts = _provider_module()
    prompt_admission.register_prompt_receipt_provider(
        receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    )
    message_id = str(uuid.uuid4())

    first = _request(message_id, confirm_truncate="false")
    second = _request(message_id, confirm_truncate=False)

    assert first["result"]["deduplicated"] is False
    assert second["result"]["deduplicated"] is True
    assert len(calls) == 1


def test_concurrent_identical_requests_execute_once_and_report_in_progress(
    isolated, monkeypatch
):
    _tmp_path, calls = isolated
    receipts = _provider_module()
    provider = receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    real_complete = provider.complete
    completing = threading.Event()
    release = threading.Event()

    def blocked_complete(reservation, disposition):
        completing.set()
        assert release.wait(timeout=5)
        real_complete(reservation, disposition)

    monkeypatch.setattr(provider, "complete", blocked_complete)
    prompt_admission.register_prompt_receipt_provider(provider)
    message_id = str(uuid.uuid4())
    responses = {}
    first = threading.Thread(
        target=lambda: responses.__setitem__("first", _request(message_id))
    )
    try:
        first.start()
        assert completing.wait(timeout=5)
        responses["second"] = _request(message_id)
        assert responses["second"]["result"]["status"] == "in_progress"
        assert responses["second"]["result"]["accepted"] is False
        assert len(calls) == 1
    finally:
        release.set()
        first.join(timeout=5)
    assert not first.is_alive()
    assert responses["first"]["result"]["status"] == "streaming"


def test_handler_rejection_releases_reservation_for_safe_retry(isolated, monkeypatch):
    _tmp_path, calls = isolated
    receipts = _provider_module()
    prompt_admission.register_prompt_receipt_provider(
        receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    )
    message_id = str(uuid.uuid4())
    attempts = 0

    def handler(rid, _params):
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            return server._err(rid, 4009, "busy")
        return server._ok(rid, {"status": "streaming"})

    monkeypatch.setitem(server._methods, "prompt.submit", handler)
    assert _request(message_id)["error"]["code"] == 4009
    assert _request(message_id)["result"]["status"] == "streaming"
    assert attempts == 2
    assert calls == []


def test_non_prompt_success_does_not_consume_prompt_identity(isolated, monkeypatch):
    _tmp_path, calls = isolated
    receipts = _provider_module()
    prompt_admission.register_prompt_receipt_provider(
        receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    )
    message_id = str(uuid.uuid4())
    attempts = 0

    def handler(rid, _params):
        nonlocal attempts
        attempts += 1
        return server._ok(rid, {"voice_stopped": True})

    monkeypatch.setitem(server._methods, "prompt.submit", handler)
    assert _request(message_id)["result"] == {"voice_stopped": True}
    assert _request(message_id)["result"] == {"voice_stopped": True}
    assert attempts == 2
    assert calls == []


def test_completion_failure_never_executes_same_id_twice_in_process(
    isolated, monkeypatch
):
    _tmp_path, calls = isolated
    receipts = _provider_module()
    provider = receipts.SQLitePromptReceiptProvider(owner_id="process-a")
    monkeypatch.setattr(
        provider,
        "complete",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(OSError("disk unavailable")),
    )
    prompt_admission.register_prompt_receipt_provider(provider)
    message_id = str(uuid.uuid4())

    assert _request(message_id)["error"]["code"] == 5037
    retry = _request(message_id)

    assert retry["result"]["status"] == "in_progress"
    assert len(calls) == 1


def test_abandoned_reservation_is_indeterminate_after_process_restart(tmp_path):
    receipts = _provider_module()
    message_id = str(uuid.uuid4())
    kwargs = {
        "profile_home": tmp_path,
        "client_message_id": message_id,
        "request_fingerprint": "f" * 64,
    }
    assert receipts.SQLitePromptReceiptProvider(owner_id="a").reserve(**kwargs)["state"] == "claimed"
    assert receipts.SQLitePromptReceiptProvider(owner_id="b").reserve(**kwargs)["state"] == "indeterminate"


def test_receipts_are_profile_scoped_and_pruned_after_thirty_days(tmp_path):
    receipts = _provider_module()
    now = [1_000_000.0]
    provider = receipts.SQLitePromptReceiptProvider(owner_id="a", clock=lambda: now[0])
    message_id = str(uuid.uuid4())
    request = {
        "client_message_id": message_id,
        "request_fingerprint": "a" * 64,
    }
    claim = provider.reserve(profile_home=tmp_path / "one", **request)
    provider.complete(claim["reservation"], {"status": "streaming"})
    assert provider.reserve(profile_home=tmp_path / "two", **request)["state"] == "claimed"

    now[0] += receipts.RETENTION_SECONDS
    assert provider.reserve(profile_home=tmp_path / "one", **request)["state"] == "replay"
    now[0] += 0.001
    changed = {**request, "request_fingerprint": "b" * 64}
    assert provider.reserve(profile_home=tmp_path / "one", **changed)["state"] == "claimed"
    with sqlite3.connect(provider.database_path(tmp_path / "one")) as conn:
        assert conn.execute("SELECT count(*) FROM prompt_receipts").fetchone()[0] == 1


def test_provider_absence_preserves_legacy_response_shape(isolated, monkeypatch):
    _tmp_path, calls = isolated
    monkeypatch.setattr(prompt_admission, "ensure_prompt_receipt_provider", lambda: None)
    response = _request("not-a-uuid")
    assert response["result"] == {"status": "streaming"}
    assert len(calls) == 1


def test_stock_prompt_handler_routes_admitted_id_as_metadata_for_busy_turn(
    isolated, monkeypatch
):
    _tmp_path, _calls = isolated
    message_id = str(uuid.uuid4())
    captured = {}
    with server._sessions_lock:
        server._sessions["live-1"]["running"] = True

    monkeypatch.setattr(server, "_voice_mode_enabled", lambda: False)
    monkeypatch.setattr(server, "_ensure_active_session_slot", lambda *_args: None)
    monkeypatch.setattr(
        server, "_load_dashboard_process_isolation_config", lambda: {}
    )

    def busy(_rid, _sid, _session, _text, _transport, **kwargs):
        captured.update(kwargs)
        return server._ok(_rid, {"status": "queued"})

    monkeypatch.setattr(server, "_handle_busy_submit", busy)
    response = _STOCK_PROMPT_HANDLER(
        "r1",
        {
            "session_id": "live-1",
            "text": "queued",
            "_admitted_client_message_id": message_id,
        },
    )

    assert response["result"]["status"] == "queued"
    assert captured["display_metadata"] == {"client_message_id": message_id}


def test_stock_prompt_handler_routes_admitted_id_to_inline_turn(isolated, monkeypatch):
    _tmp_path, _calls = isolated
    message_id = str(uuid.uuid4())
    captured = {}

    class ImmediateThread:
        def __init__(self, target=None, **_kwargs):
            self.target = target

        def start(self):
            assert self.target is not None
            self.target()

    monkeypatch.setattr(server, "_voice_mode_enabled", lambda: False)
    monkeypatch.setattr(server, "_ensure_active_session_slot", lambda *_args: None)
    monkeypatch.setattr(
        server, "_load_dashboard_process_isolation_config", lambda: {}
    )
    monkeypatch.setattr(server, "_ensure_session_db_row", lambda _session: None)
    monkeypatch.setattr(server, "_persist_branch_seed", lambda _session: None)
    monkeypatch.setattr(server, "_start_agent_build", lambda _sid, _session: None)
    monkeypatch.setattr(
        server, "_wait_agent_for_prompt", lambda _session, _rid, _sid: None
    )
    monkeypatch.setattr(server.threading, "Thread", ImmediateThread)

    def run_prompt(_rid, _sid, _session, _text, **kwargs):
        captured.update(kwargs)

    monkeypatch.setattr(server, "_run_prompt_submit", run_prompt)
    response = _STOCK_PROMPT_HANDLER(
        "r1",
        {
            "session_id": "live-1",
            "text": "inline",
            "_admitted_client_message_id": message_id,
        },
    )

    assert response["result"]["status"] == "streaming"
    assert captured["display_metadata"] == {"client_message_id": message_id}


def test_id_enabled_busy_prompts_keep_distinct_queue_envelopes():
    first_id = str(uuid.uuid4())
    second_id = str(uuid.uuid4())
    session = {}

    server._enqueue_prompt(
        session,
        "first",
        server._stdio_transport,
        display_metadata={"client_message_id": first_id},
    )
    server._enqueue_prompt(
        session,
        "second",
        server._stdio_transport,
        display_metadata={"client_message_id": second_id},
    )

    assert session["queued_prompt"]["text"] == "first"
    assert session["queued_prompt"]["display_metadata"]["client_message_id"] == first_id
    assert session["queued_prompts"][0]["text"] == "second"
    assert (
        session["queued_prompts"][0]["display_metadata"]["client_message_id"]
        == second_id
    )


def test_canonical_transcript_projects_client_id_from_display_metadata():
    message_id = str(uuid.uuid4())
    [message] = server._history_to_messages(
        [
            {
                "role": "user",
                "content": "hello",
                "display_metadata": {"client_message_id": message_id},
            }
        ]
    )

    assert message["text"] == "hello"
    assert message["client_message_id"] == message_id
    assert message["display_metadata"] == {"client_message_id": message_id}


def test_inline_turn_persists_client_id_as_user_display_metadata(
    tmp_path, monkeypatch
):
    message_id = str(uuid.uuid4())
    captured = {}

    class InlineThread:
        def __init__(self, target=None, **_kwargs):
            self.target = target

        def start(self):
            assert self.target is not None
            self.target()

        def is_alive(self):
            return False

    def run_conversation(
        _message, *, persist_user_display_metadata=None, **kwargs
    ):
        kwargs["persist_user_display_metadata"] = persist_user_display_metadata
        captured.update(kwargs)
        return {"final_response": "done", "messages": []}

    agent = SimpleNamespace(
        session_id="stored-1",
        clear_interrupt=lambda: None,
        run_conversation=run_conversation,
    )
    session = {
        "agent": agent,
        "session_key": "stored-1",
        "history": [],
        "history_lock": threading.Lock(),
        "history_version": 0,
        "running": True,
        "attached_images": [],
        "cols": 80,
        "show_reasoning": False,
        "tool_progress_mode": "all",
    }
    monkeypatch.setattr(server.threading, "Thread", InlineThread)
    monkeypatch.setattr(server, "_wire_callbacks", lambda _sid: None)
    monkeypatch.setattr(
        server, "_sync_agent_model_with_config", lambda _sid, _session: None
    )
    monkeypatch.setattr(server, "_session_cwd", lambda _session: str(tmp_path))
    monkeypatch.setattr(server, "_register_session_cwd", lambda _session: None)
    monkeypatch.setattr(server, "_tts_stream_begin", lambda: None)
    monkeypatch.setattr(server, "_sync_session_key_after_compress", lambda *a, **k: None)
    monkeypatch.setattr(server, "_get_usage", lambda _agent: {})
    monkeypatch.setattr(server, "_emit", lambda *_args, **_kwargs: None)
    server._start_inflight_turn(session, "hello")

    server._run_prompt_submit(
        "r1",
        "live-1",
        session,
        "hello",
        display_metadata={"client_message_id": message_id},
    )

    metadata = captured["persist_user_display_metadata"]
    assert metadata["client_message_id"] == message_id
    assert metadata["hermes_turn_id"]


def test_fingerprint_uses_stable_compression_lineage_root(isolated, monkeypatch):
    tmp_path, _calls = isolated
    message_id = str(uuid.uuid4())

    class CaptureProvider:
        provider_name = "capture"

        def __init__(self):
            self.fingerprint = ""

        def reserve(self, **kwargs):
            self.fingerprint = kwargs["request_fingerprint"]
            return {"state": "claimed", "reservation": kwargs}

        def complete(self, _reservation, _disposition):
            return None

        def release(self, _reservation):
            return None

    provider = CaptureProvider()
    prompt_admission.register_prompt_receipt_provider(provider)

    @contextmanager
    def fake_session_db(_session):
        yield SimpleNamespace(get_conversation_root=lambda _key: "lineage-root")

    monkeypatch.setattr(server, "_session_db", fake_session_db)
    params = {
        "session_id": "live-1",
        "text": "hello",
        "client_message_id": message_id,
    }
    admission, immediate = server._begin_prompt_admission("r1", params)

    assert immediate is None
    assert admission is not None
    assert provider.fingerprint == prompt_admission.request_fingerprint(
        session_key="lineage-root",
        text="hello",
        truncate_before_user_ordinal=None,
        confirm_truncate=False,
        confirm_empty_truncate=False,
        queued=False,
        interrupted=False,
    )
    assert admission.reservation["profile_home"] == Path(tmp_path)


def test_receipt_store_permissions_are_private(tmp_path):
    receipts = _provider_module()
    provider = receipts.SQLitePromptReceiptProvider(owner_id="a")
    provider.reserve(
        profile_home=tmp_path,
        client_message_id=str(uuid.uuid4()),
        request_fingerprint="f" * 64,
    )

    path = provider.database_path(tmp_path)
    assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_receipt_store_uses_stock_journal_mode_safety(tmp_path, monkeypatch):
    labels = []

    def apply_native_policy(conn, *, db_label):
        labels.append(db_label)
        conn.execute("PRAGMA journal_mode=DELETE")
        return "delete"

    monkeypatch.setattr(
        hermes_state, "apply_wal_with_fallback", apply_native_policy
    )
    receipts = _provider_module()
    provider = receipts.SQLitePromptReceiptProvider(owner_id="a")
    provider.reserve(
        profile_home=tmp_path,
        client_message_id=str(uuid.uuid4()),
        request_fingerprint="f" * 64,
    )

    assert labels == [str(provider.database_path(tmp_path))]


def test_fresh_gateway_discovery_advertises_bundled_receipt_provider(tmp_path):
    env = dict(os.environ)
    env["HERMES_HOME"] = str(tmp_path)
    output_path = tmp_path / "capabilities.json"
    env["PROMPT_ADMISSION_TEST_OUTPUT"] = str(output_path)
    subprocess.check_call(
        [
            sys.executable,
            "-c",
            (
                "import json; "
                "import os; "
                "from pathlib import Path; "
                "from tui_gateway import server; "
                "Path(os.environ['PROMPT_ADMISSION_TEST_OUTPUT']).write_text("
                "json.dumps(server.gateway_ready_payload({})))"
            ),
        ],
        cwd=Path(__file__).parents[2],
        env=env,
    )
    payload = json.loads(output_path.read_text())
    assert "prompt_receipt_admission_v1" in payload["capabilities"]

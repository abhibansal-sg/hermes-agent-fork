"""H1a — public append seam on the gateway session store.

Pins ``SessionStore.append_message()``: one narrow public wrapper over the
canonical ``SessionDB.append_message()`` write path, through which durable
GPT-Live events (frozen contract 2) persist with role, tool info, display
kind/metadata, a caller-provided timestamp and the ``platform_message_id``
idempotency field (Live's ``event_id``) — the shape that
``append_to_transcript()``'s dict mapping does not carry.

Coverage:
  * normal append round-trips the full event shape (incl. display fields)
  * tool info (tool_name / tool_call_id / tool_calls) is carried
  * unknown session raises ValueError and writes nothing
  * empty role is rejected
  * re-append keyed by platform_message_id is skipped (no duplicate row),
    distinct event ids both land, and None ids never dedupe
  * no-DB stores no-op (class-wide convention)
  * AsyncSessionStore proxies the seam off the event loop
"""

import json

import pytest

import hermes_state
from gateway.config import GatewayConfig
from gateway.session import AsyncSessionStore, SessionStore


@pytest.fixture()
def store(tmp_path, monkeypatch):
    monkeypatch.setattr(hermes_state, "DEFAULT_DB_PATH", tmp_path / "state.db")
    return SessionStore(sessions_dir=tmp_path, config=GatewayConfig())


class TestLiveAppendSeam:
    def test_append_message_persists_full_event_shape(self, store):
        session_id = "live_session_1"
        store._db.create_session(session_id=session_id, source="test")

        row_id = store.append_message(
            session_id,
            "assistant",
            content="Handoff finished: summary ready",
            platform_message_id="evt_001",
            display_kind="handoff_result",
            display_metadata={"call_id": "call_42", "category": "handoff"},
            timestamp=1753400000.5,
            observed=True,
        )

        assert isinstance(row_id, int)
        (msg,) = store._db.get_messages(session_id)
        assert msg["id"] == row_id
        assert msg["role"] == "assistant"
        assert msg["content"] == "Handoff finished: summary ready"
        assert msg["platform_message_id"] == "evt_001"
        assert msg["display_kind"] == "handoff_result"
        assert json.loads(msg["display_metadata"]) == {
            "call_id": "call_42",
            "category": "handoff",
        }
        assert msg["timestamp"] == pytest.approx(1753400000.5)
        assert msg["observed"] == 1

    def test_append_message_carries_tool_info(self, store):
        session_id = "live_session_tools"
        store._db.create_session(session_id=session_id, source="test")

        store.append_message(
            session_id,
            "tool",
            content="lookup result",
            tool_name="calendar.lookup",
            tool_call_id="call_abc",
            platform_message_id="evt_tool_1",
            display_kind="tool_result",
        )

        (msg,) = store._db.get_messages(session_id)
        assert msg["role"] == "tool"
        assert msg["tool_name"] == "calendar.lookup"
        assert msg["tool_call_id"] == "call_abc"
        assert msg["display_kind"] == "tool_result"

    def test_append_message_unknown_session_raises_and_writes_nothing(self, store):
        with pytest.raises(ValueError, match="Unknown session"):
            store.append_message(
                "no_such_session", "user", content="hello",
                platform_message_id="evt_x",
            )

        assert store._db.get_messages("no_such_session") == []

    def test_append_message_empty_role_rejected(self, store):
        session_id = "live_session_role"
        store._db.create_session(session_id=session_id, source="test")

        with pytest.raises(ValueError, match="role"):
            store.append_message(session_id, "", content="x")

        assert store._db.get_messages(session_id) == []

    def test_append_message_idempotent_reappend_by_platform_message_id(self, store):
        session_id = "live_session_dedupe"
        store._db.create_session(session_id=session_id, source="test")

        first = store.append_message(
            session_id, "user", content="final transcript",
            platform_message_id="evt_dup",
            display_kind="user_transcript_final",
        )
        assert isinstance(first, int)

        # Re-append of the same event_id is skipped, original row untouched.
        duplicate = store.append_message(
            session_id, "user", content="MUTATED duplicate",
            platform_message_id="evt_dup",
            display_kind="user_transcript_final",
        )
        assert duplicate is None
        rows = store._db.get_messages(session_id)
        assert len(rows) == 1
        assert rows[0]["content"] == "final transcript"
        assert store.has_platform_message_id(session_id, "evt_dup")

        # A distinct event_id lands as its own row.
        second = store.append_message(
            session_id, "assistant", content="next event",
            platform_message_id="evt_other",
        )
        assert isinstance(second, int)
        assert len(store._db.get_messages(session_id)) == 2

        # Events without an event_id never dedupe against each other.
        assert store.append_message(session_id, "system", content="a") is not None
        assert store.append_message(session_id, "system", content="b") is not None
        assert len(store._db.get_messages(session_id)) == 4

    def test_append_message_no_db_is_noop(self, store):
        store._db = None
        assert store.append_message(
            "any_session", "user", content="x", platform_message_id="evt_y"
        ) is None


@pytest.mark.asyncio
async def test_async_session_store_proxies_append_message(tmp_path, monkeypatch):
    monkeypatch.setattr(hermes_state, "DEFAULT_DB_PATH", tmp_path / "state.db")
    facade = AsyncSessionStore(
        SessionStore(sessions_dir=tmp_path, config=GatewayConfig())
    )
    session_id = "live_session_async"
    facade._store._db.create_session(session_id=session_id, source="test")

    row_id = await facade.append_message(
        session_id, "assistant", content="async event",
        platform_message_id="evt_async_1",
        display_kind="assistant_transcript_final",
    )
    assert isinstance(row_id, int)

    # The idempotency guard holds across the async boundary too.
    assert await facade.append_message(
        session_id, "assistant", content="async duplicate",
        platform_message_id="evt_async_1",
    ) is None
    assert len(facade._store._db.get_messages(session_id)) == 1

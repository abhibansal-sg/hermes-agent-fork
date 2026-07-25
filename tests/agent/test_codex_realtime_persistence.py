"""H11-R2-B exact-once native GPT-Live persistence proof."""

from __future__ import annotations

from agent import codex_runtime


class Agent:
    def __init__(self):
        self.session_id = "native-session-1"
        self.platform = "desktop"
        self._session_messages = []
        self.flushed = []
        self.calls = []

    def _flush_messages_to_session_db(self, messages):
        self.flushed.append(list(messages))

    def run_conversation(self, **kwargs):
        self.calls.append(kwargs)
        self._session_messages.extend([
            {
                "role": "user",
                "content": kwargs["persist_user_message"],
                "display_metadata": getattr(self, "_gpt_live_projection_metadata", None),
            },
            {
                "role": "assistant",
                "content": "authoritative",
                "display_metadata": getattr(self, "_gpt_live_projection_metadata", None),
            },
        ])
        self._flush_messages_to_session_db(self._session_messages)
        return {"final_response": "authoritative"}


def kwargs():
    return {
        "handoff_id": "handoff-1",
        "generation": 3,
        "call_id": "call-1",
        "input_text": "Read the answer",
        "transcript_delta": "read the answer",
        "messages": [],
        "effective_task_id": "native-session-1",
        "original_user_message": "Read the answer",
    }


def test_handoff_persists_clean_user_message_once_and_never_xml_envelope():
    agent = Agent()
    first = codex_runtime.route_realtime_handoff(agent, **kwargs())
    assert first["executor_turns"] == 1
    assert agent.calls[0]["persist_user_message"] == "Read the answer"
    assert all(
        "<realtime_delegation>" not in str(message.get("content"))
        for message in agent._session_messages
    )


def test_handoff_replay_is_idempotent_from_persisted_projection_metadata():
    agent = Agent()
    messages = [{
        "role": "user",
        "content": "Read the answer",
        "display_metadata": {
            "kind": "gpt_live",
            "handoff_id": "handoff-1",
            "call_id": "call-1",
            "generation": 3,
        },
    }]
    result = codex_runtime.route_realtime_handoff(
        agent, **{**kwargs(), "messages": messages}
    )
    assert result == {"status": "duplicate", "executor_turns": 0}
    assert agent.calls == []


def test_completed_remote_transcript_item_projects_once_through_native_flush():
    agent = Agent()
    assert codex_runtime.persist_realtime_transcript_item(
        agent,
        call_id="call-1",
        generation=3,
        remote_item_id="remote-1",
        role="user",
        content="Read the answer",
    ) is True
    assert codex_runtime.persist_realtime_transcript_item(
        agent,
        call_id="call-1",
        generation=3,
        remote_item_id="remote-1",
        role="user",
        content="Read the answer",
    ) is False
    assert len(agent._session_messages) == 1
    assert len(agent.flushed) == 1


def test_partial_remote_item_is_not_canonical():
    agent = Agent()
    assert codex_runtime.persist_realtime_transcript_item(
        agent,
        call_id="call-1",
        generation=3,
        remote_item_id="",
        role="user",
        content="partial",
    ) is False
    assert agent._session_messages == []


def test_end_overlay_is_applied_without_an_executor_turn():
    agent = Agent()
    overlay = codex_runtime.apply_realtime_conversation_end_overlay(agent)
    assert overlay == agent._gpt_live_realtime_end_overlay
    assert agent.calls == []


def test_coordinator_releases_lease_and_context_on_disconnect():
    from gateway.gpt_live_foreground import foreground_leases
    from gateway.session_context import get_gpt_live_context

    agent = Agent()
    coordinator = codex_runtime.RealtimeConversationCoordinator(agent, call_id="call-1")
    assert coordinator.start(generation=3) == {"status": "started", "generation": 3}
    assert get_gpt_live_context()["active"] is True
    coordinator.desk_disconnect()
    assert get_gpt_live_context()["active"] is False
    assert foreground_leases.snapshot() == {}


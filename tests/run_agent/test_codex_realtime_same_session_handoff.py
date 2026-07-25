"""H09 same-session GPT-Live handoff tests."""

from __future__ import annotations

import pytest

from agent import codex_runtime
from agent.realtime_prompt import build_realtime_conversation_start_overlay


class Agent:
    def __init__(self):
        self.session_id = "native-session-1"
        self.platform = "desktop"

    def run_conversation(self, **_kwargs):
        raise AssertionError("run_conversation stub called without a test override")


def _kwargs():
    return {
        "handoff_id": "handoff-1",
        "generation": 7,
        "input_text": "Find the answer",
        "transcript_delta": "find the answer",
        "messages": [{"role": "user", "content": "existing"}],
        "effective_task_id": "native-session-1",
        "original_user_message": "Find the answer",
    }


def test_backend_handoff_uses_existing_executor_once_and_preserves_session(monkeypatch):
    agent = Agent()
    calls = []

    def fake_executor(**kwargs):
        calls.append(kwargs)
        return {"final_response": "authoritative result"}

    monkeypatch.setattr(agent, "run_conversation", fake_executor)

    result = codex_runtime.route_realtime_handoff(agent, **_kwargs())

    assert result["status"] == "executor_handoff"
    assert result["executor_turns"] == 1
    assert len(calls) == 1
    assert calls[0]["user_message"].startswith("<realtime_delegation>")
    assert calls[0]["system_message"] == build_realtime_conversation_start_overlay()
    assert calls[0]["conversation_history"] == [{"role": "user", "content": "existing"}]
    assert calls[0]["persist_user_message"] == "Find the answer"
    assert agent.session_id == "native-session-1"
    assert agent.platform == "desktop"


def test_same_handoff_id_and_generation_cannot_repeat_executor_work(monkeypatch):
    agent = Agent()
    calls = []
    monkeypatch.setattr(
        agent,
        "run_conversation",
        lambda **kwargs: calls.append(kwargs) or {"final_response": "ok"},
    )

    first = codex_runtime.route_realtime_handoff(agent, **_kwargs())
    duplicate = codex_runtime.route_realtime_handoff(agent, **_kwargs())
    tail = codex_runtime.route_realtime_handoff(
        agent, **{**_kwargs(), "source": "transcript_tail_flush"}
    )

    assert first["executor_turns"] == 1
    assert duplicate["status"] == "duplicate"
    assert tail["status"] == "duplicate"
    assert len(calls) == 1


def test_direct_live_answer_creates_zero_executor_turns(monkeypatch):
    agent = Agent()
    calls = []
    monkeypatch.setattr(
        agent,
        "run_conversation",
        lambda **kwargs: calls.append(True),
    )

    result = codex_runtime.route_realtime_handoff(
        agent, **{**_kwargs(), "direct_answer": "No backend needed"}
    )

    assert result == {
        "status": "direct_answer",
        "final_response": "No backend needed",
        "executor_turns": 0,
    }
    assert calls == []


def test_new_generation_can_route_once_without_creating_a_child(monkeypatch):
    agent = Agent()
    calls = []
    monkeypatch.setattr(
        agent,
        "run_conversation",
        lambda **kwargs: calls.append(kwargs) or {"final_response": "ok"},
    )

    codex_runtime.route_realtime_handoff(agent, **_kwargs())
    agent._gpt_live_realtime_generation = 8
    result = codex_runtime.route_realtime_handoff(
        agent, **{**_kwargs(), "generation": 8, "handoff_id": "handoff-2"}
    )

    assert result["executor_turns"] == 1
    assert len(calls) == 2
    assert not hasattr(agent, "parent_session_id")
    assert not hasattr(agent, "mailroom_task")


def test_stale_generation_creates_zero_executor_turns(monkeypatch):
    agent = Agent()
    agent._gpt_live_realtime_generation = 8
    calls = []
    monkeypatch.setattr(
        agent,
        "run_conversation",
        lambda *args, **kwargs: calls.append((args, kwargs)),
    )

    result = codex_runtime.route_realtime_handoff(agent, **_kwargs())

    assert result == {
        "status": "stale_generation",
        "executor_turns": 0,
    }
    assert calls == []
    assert agent.session_id == "native-session-1"
    assert agent.platform == "desktop"


def test_executor_error_propagates_without_completing_handoff(monkeypatch):
    agent = Agent()
    calls = []

    def failing_executor(**kwargs):
        calls.append(kwargs)
        raise RuntimeError("executor failed")

    monkeypatch.setattr(agent, "run_conversation", failing_executor)

    with pytest.raises(RuntimeError, match="executor failed"):
        codex_runtime.route_realtime_handoff(agent, **_kwargs())

    assert calls and len(calls) == 1
    assert agent.session_id == "native-session-1"
    assert agent.platform == "desktop"
    assert (7, "handoff-1") not in agent._gpt_live_handoff_keys

    monkeypatch.setattr(
        agent,
        "run_conversation",
        lambda **kwargs: {"final_response": "retry succeeded"},
    )
    retry = codex_runtime.route_realtime_handoff(agent, **_kwargs())
    assert retry["status"] == "executor_handoff"


def test_cancellation_propagates_without_completing_handoff(monkeypatch):
    agent = Agent()
    calls = []

    def cancelled_executor(**kwargs):
        calls.append(kwargs)
        raise KeyboardInterrupt()

    monkeypatch.setattr(agent, "run_conversation", cancelled_executor)

    with pytest.raises(KeyboardInterrupt):
        codex_runtime.route_realtime_handoff(agent, **_kwargs())

    assert calls and len(calls) == 1
    assert agent.session_id == "native-session-1"
    assert agent.platform == "desktop"
    assert (7, "handoff-1") not in agent._gpt_live_handoff_keys


def test_successful_result_is_returned_exactly_once(monkeypatch):
    agent = Agent()
    calls = []
    executor_result = {
        "final_response": "authoritative result",
        "completed": True,
    }

    def successful_executor(**kwargs):
        calls.append(kwargs)
        return executor_result

    monkeypatch.setattr(agent, "run_conversation", successful_executor)

    first = codex_runtime.route_realtime_handoff(agent, **_kwargs())
    replay = codex_runtime.route_realtime_handoff(agent, **_kwargs())

    assert first == {
        "status": "executor_handoff",
        "executor_turns": 1,
        "result": executor_result,
    }
    assert replay == {
        "status": "duplicate",
        "executor_turns": 0,
    }
    assert "result" not in replay
    assert len(calls) == 1


def test_non_codex_provider_stays_on_existing_conversation_executor(monkeypatch):
    agent = Agent()
    calls = []

    def fake_executor(**kwargs):
        calls.append(kwargs)
        return {"final_response": "ok"}

    monkeypatch.setattr(agent, "run_conversation", fake_executor)
    monkeypatch.setattr(
        codex_runtime,
        "run_codex_app_server_turn",
        lambda *args, **kwargs: (_ for _ in ()).throw(
            AssertionError("run_codex_app_server_turn should not be used"),
        ),
    )

    result = codex_runtime.route_realtime_handoff(agent, **_kwargs())

    assert result["status"] == "executor_handoff"
    assert len(calls) == 1

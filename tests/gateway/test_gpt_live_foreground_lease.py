"""H11-R2-A process-local GPT-Live foreground lease proof."""

from __future__ import annotations

import pytest

from gateway.gpt_live_foreground import (
    ForegroundLeaseError,
    acquire_live_foreground_lease,
    acquire_text_foreground_lease,
    foreground_leases,
    scoped_executor_tool_overlay,
)
from gateway.session_context import clear_gpt_live_context, set_gpt_live_context


SESSION = "native-session"
CALL = "call-1"
GENERATION = 4


class Agent:
    def __init__(self):
        self.session_id = SESSION
        self.tools = [{"type": "function", "function": {"name": "general"}}]
        self.valid_tool_names = {"general"}


@pytest.fixture(autouse=True)
def clean_lease_and_context():
    foreground_leases.release_session(SESSION)
    clear_gpt_live_context()
    yield
    foreground_leases.release_session(SESSION)
    clear_gpt_live_context()


def test_live_lease_identity_is_idempotent_and_blocks_text():
    first = acquire_live_foreground_lease(SESSION, CALL, GENERATION)
    second = acquire_live_foreground_lease(SESSION, CALL, GENERATION)
    assert first is not None and second is not None
    assert acquire_text_foreground_lease(SESSION, "text", GENERATION) is None
    assert first.release() is True
    assert acquire_text_foreground_lease(SESSION, "text", GENERATION) is None
    assert second.release() is True
    text = acquire_text_foreground_lease(SESSION, "text", GENERATION)
    assert text is not None
    text.release()


def test_stale_call_and_generation_fail_closed():
    live = acquire_live_foreground_lease(SESSION, CALL, GENERATION)
    assert live is not None
    assert foreground_leases.allow_executor(
        session_id=SESSION, call_id="other", generation=GENERATION
    ) is None
    assert foreground_leases.allow_executor(
        session_id=SESSION, call_id=CALL, generation=GENERATION + 1
    ) is None


def test_executor_access_is_attached_to_live_owner():
    live = acquire_live_foreground_lease(SESSION, CALL, GENERATION)
    assert live is not None
    set_gpt_live_context(
        active=True,
        call_id=CALL,
        generation=GENERATION,
        native_session_id=SESSION,
    )
    access = foreground_leases.allow_executor(
        session_id=SESSION, call_id=CALL, generation=GENERATION
    )
    assert access is not None
    assert foreground_leases.snapshot()[SESSION].provider_kind == "gpt_live"


def test_overlay_restores_exact_general_tools_after_exception():
    live = acquire_live_foreground_lease(SESSION, CALL, GENERATION)
    assert live is not None
    set_gpt_live_context(
        active=True,
        call_id=CALL,
        generation=GENERATION,
        native_session_id=SESSION,
    )
    agent = Agent()
    original_tools = agent.tools
    original_valid = agent.valid_tool_names
    live_tool = {"type": "function", "function": {"name": "capture_screen_context"}}
    with pytest.raises(RuntimeError):
        with scoped_executor_tool_overlay(agent, [live_tool]):
            assert agent.tools == original_tools + [live_tool]
            assert agent.valid_tool_names == {"general", "capture_screen_context"}
            raise RuntimeError("turn failed")
    assert agent.tools is original_tools
    assert agent.valid_tool_names is original_valid


def test_overlay_requires_matching_active_context():
    live = acquire_live_foreground_lease(SESSION, CALL, GENERATION)
    assert live is not None
    with pytest.raises(ForegroundLeaseError):
        with scoped_executor_tool_overlay(Agent(), []):
            pass


def test_overlay_rejects_wrong_agent_session():
    live = acquire_live_foreground_lease(SESSION, CALL, GENERATION)
    assert live is not None
    set_gpt_live_context(
        active=True,
        call_id=CALL,
        generation=GENERATION,
        native_session_id=SESSION,
    )
    agent = Agent()
    agent.session_id = "other-session"
    with pytest.raises(ForegroundLeaseError):
        with scoped_executor_tool_overlay(agent, []):
            pass


def test_release_and_force_close_clear_the_process_local_owner():
    live = acquire_live_foreground_lease(SESSION, CALL, GENERATION)
    assert live is not None
    assert live.release() is True
    assert live.release() is False
    text = acquire_text_foreground_lease(SESSION, "text", GENERATION)
    assert text is not None
    assert foreground_leases.release_session(SESSION) is True
    assert foreground_leases.snapshot() == {}

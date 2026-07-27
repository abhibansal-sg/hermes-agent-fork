"""TDD coverage for multimodal live-vs-durable persistence policy."""

from __future__ import annotations

import tempfile
from types import SimpleNamespace
from unittest.mock import MagicMock, patch
from pathlib import Path

from agent.tool_dispatch_helpers import (
    _multimodal_persistence_content,
    _trajectory_normalize_msg,
    _validate_tool_result_persistence_content,
    make_tool_result_message,
    project_messages_for_durable_use,
)
from agent.conversation_loop import (
    _apply_context_engine_selection,
    _notify_context_engine_turn_complete,
)
from hermes_state import SessionDB
from run_agent import AIAgent


PERSISTENCE_METADATA_KEY = "_tool_result_persistence_content"
_TINY_JPEG_B64 = (
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////"
    "2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAH/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAqf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/AYf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/AYf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAY/Aqf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/IV//2gAMAwEAAgADAAAAEP/EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8QH//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8QH//EABQQAQAAAAAAAAAAAAAAAAAAABD/2gAIAQEAAT8QH//Z"
)


def _make_agent():
    tool_defs = [
        {
            "type": "function",
            "function": {
                "name": "capture_screen_context",
                "description": "capture screen context",
                "parameters": {"type": "object", "properties": {}},
            },
        }
    ]
    hermes_home = Path(tempfile.mkdtemp(prefix="hermes-multimodal-persistence-"))
    (hermes_home / "logs").mkdir(parents=True, exist_ok=True)
    with (
        patch("run_agent.get_tool_definitions", return_value=tool_defs),
        patch("run_agent.check_toolset_requirements", return_value={}),
        patch("run_agent.OpenAI"),
        patch("run_agent._hermes_home", hermes_home),
    ):
        agent = AIAgent(
            api_key="test-key",
            base_url="https://openrouter.ai/api/v1",
            model="gpt-4o",
            quiet_mode=True,
            skip_context_files=True,
            skip_memory=True,
        )
    agent.client = MagicMock()
    agent.provider = "openrouter"
    agent._model_supports_vision = lambda: True
    agent._provider_supports_vision_tool_messages = lambda: True
    return agent


def _rich_result(*, persistence_content=None, include_override=False):
    result = {
        "_multimodal": True,
        "content": [
            {"type": "text", "text": "AX: Save button is visible"},
            {
                "type": "image_url",
                "image_url": {"url": f"data:image/jpeg;base64,{_TINY_JPEG_B64}"},
            },
        ],
        "text_summary": "AX: Save button is visible",
    }
    if include_override:
        result["persistence_content"] = persistence_content
    return result


def _nonce_rich_result(*, persistence_content=None, include_override=False):
    """Rich capture payload whose AX/image bytes are easy to trace in sinks."""
    image_nonce = "IMAGE_NONCE_DURABLE_SINK"
    result = {
        "_multimodal": True,
        "content": [
            {"type": "text", "text": "AX_NONCE_DURABLE_SINK"},
            {
                "type": "image_url",
                "image_url": {
                    "url": f"data:image/jpeg;base64,{_TINY_JPEG_B64}{image_nonce}"
                },
            },
        ],
        "text_summary": "safe screen summary",
    }
    if include_override:
        result["persistence_content"] = persistence_content
    return result


def _configure_flush(agent):
    agent._session_db = MagicMock()
    agent._session_db_created = True
    agent.session_id = "multimodal-persistence"
    agent._last_flushed_db_idx = 0
    agent._flushed_db_message_ids = set()
    agent._flushed_db_message_session_id = None


def _tool_call(call_id):
    return SimpleNamespace(
        id=call_id,
        type="function",
        function=SimpleNamespace(name="capture_screen_context", arguments="{}"),
    )


def test_make_tool_result_message_propagates_persistence_override_as_internal_metadata():
    message = make_tool_result_message(
        "capture_screen_context",
        [{"type": "text", "text": "live"}],
        "call-1",
        persistence_content="safe AX",
    )

    assert message[PERSISTENCE_METADATA_KEY] == "safe AX"
    assert message["content"] == [{"type": "text", "text": "live"}]


def test_model_gets_rich_list_while_db_gets_safe_string_and_live_message_stays_rich():
    agent = _make_agent()
    result = _rich_result(persistence_content="safe AX", include_override=True)

    model_content = agent._tool_result_content_for_active_model("capture_screen_context", result)
    assert model_content == result["content"]
    assert any(part.get("type") == "image_url" for part in model_content)

    message = make_tool_result_message(
        "capture_screen_context",
        model_content,
        "call-1",
        persistence_content=result["persistence_content"],
    )
    _configure_flush(agent)
    agent._flush_messages_to_session_db([message], [])

    db_write = agent._session_db.append_message.call_args.kwargs
    assert db_write["content"] == "safe AX"
    assert PERSISTENCE_METADATA_KEY not in db_write
    assert message["content"] == result["content"]
    assert message[PERSISTENCE_METADATA_KEY] == "safe AX"


def test_explicit_list_override_persists_image_parts_exactly():
    agent = _make_agent()
    override = [
        {"type": "text", "text": "persist this AX"},
        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{_TINY_JPEG_B64}"}},
    ]
    result = _rich_result(persistence_content=override, include_override=True)
    message = make_tool_result_message(
        "capture_screen_context",
        result["content"],
        "call-2",
        persistence_content=result["persistence_content"],
    )
    _configure_flush(agent)

    agent._flush_messages_to_session_db([message], [])

    assert agent._session_db.append_message.call_args.kwargs["content"] == override


def test_no_override_keeps_legacy_image_stripping():
    agent = _make_agent()
    result = _rich_result()
    message = make_tool_result_message("capture_screen_context", result["content"], "call-3")
    _configure_flush(agent)

    agent._flush_messages_to_session_db([message], [])

    assert agent._session_db.append_message.call_args.kwargs["content"] == (
        "AX: Save button is visible\n[screenshot]"
    )


def test_malformed_override_falls_back_without_repr_persistence():
    agent = _make_agent()
    result = _rich_result(persistence_content={"not": object()}, include_override=True)
    message = make_tool_result_message(
        "capture_screen_context",
        result["content"],
        "call-4",
        persistence_content=result["persistence_content"],
    )
    _configure_flush(agent)

    agent._flush_messages_to_session_db([message], [])

    persisted = agent._session_db.append_message.call_args.kwargs["content"]
    assert persisted == "AX: Save button is visible\n[screenshot]"
    assert "object at" not in str(persisted)


def test_internal_metadata_is_removed_before_provider_messages():
    agent = _make_agent()
    live_content = _rich_result()["content"]
    message = make_tool_result_message(
        "capture_screen_context",
        live_content,
        "call-5",
        persistence_content="not provider content",
    )
    assistant = {
        "role": "assistant",
        "content": "",
        "tool_calls": [
            {
                "id": "call-5",
                "type": "function",
                "function": {"name": "capture_screen_context", "arguments": "{}"},
            }
        ],
    }

    api_messages = agent._sanitize_api_messages([assistant, message])

    provider_tool = next(item for item in api_messages if item.get("role") == "tool")
    assert PERSISTENCE_METADATA_KEY not in provider_tool
    assert provider_tool["content"] == live_content
    assert any(part.get("type") == "image_url" for part in provider_tool["content"])
    assert PERSISTENCE_METADATA_KEY in message


def test_sequential_execution_propagates_override_to_tool_message():
    agent = _make_agent()
    agent._flush_messages_to_session_db = MagicMock()
    result = _rich_result(persistence_content="sequential AX", include_override=True)
    assistant = SimpleNamespace(content="", tool_calls=[_tool_call("seq-1")])
    messages = []

    with (
        patch("run_agent.handle_function_call", return_value=result),
        patch(
            "agent.tool_executor.maybe_persist_tool_result",
            side_effect=lambda **kwargs: kwargs["content"],
        ),
    ):
        agent._execute_tool_calls_sequential(assistant, messages, "task-1")

    assert messages[0][PERSISTENCE_METADATA_KEY] == "sequential AX"
    assert messages[0]["content"] == result["content"]


def test_concurrent_execution_propagates_overrides_to_tool_messages():
    agent = _make_agent()
    agent._flush_messages_to_session_db = MagicMock()
    results = {
        "conc-1": _rich_result(persistence_content="concurrent one", include_override=True),
        "conc-2": _rich_result(persistence_content="concurrent two", include_override=True),
    }
    assistant = SimpleNamespace(
        content="",
        tool_calls=[_tool_call("conc-1"), _tool_call("conc-2")],
    )
    messages = []

    with (
        patch.object(
            agent,
            "_invoke_tool",
            side_effect=lambda name, args, task_id, tool_call_id, **kwargs: results[tool_call_id],
        ),
        patch(
            "agent.tool_executor.maybe_persist_tool_result",
            side_effect=lambda **kwargs: kwargs["content"],
        ),
    ):
        agent._execute_tool_calls_concurrent(assistant, messages, "task-1")

    assert [message[PERSISTENCE_METADATA_KEY] for message in messages] == [
        "concurrent one",
        "concurrent two",
    ]
    assert all(message["content"] == results[message["tool_call_id"]]["content"] for message in messages)


def test_repeated_flush_is_idempotent_with_override():
    agent = _make_agent()
    result = _rich_result(persistence_content="once", include_override=True)
    message = make_tool_result_message(
        "capture_screen_context",
        result["content"],
        "call-6",
        persistence_content=result["persistence_content"],
    )
    _configure_flush(agent)

    agent._flush_messages_to_session_db([message], [])
    agent._flush_messages_to_session_db([message], [])

    assert agent._session_db.append_message.call_count == 1


def test_arbitrary_tool_cannot_opt_into_persistence_override():
    result = _rich_result(persistence_content="must not persist", include_override=True)

    assert _multimodal_persistence_content("computer_use", result) is None
    assert _multimodal_persistence_content("mcp_capture", result) is None
    message = make_tool_result_message(
        "computer_use",
        result["content"],
        "call-arbitrary",
        persistence_content=result["persistence_content"],
    )
    assert PERSISTENCE_METADATA_KEY not in message


def test_persistence_override_requires_actual_trusted_function_name():
    result = _rich_result(persistence_content="trusted", include_override=True)

    assert _multimodal_persistence_content("capture_screen_context", result) == "trusted"
    assert _multimodal_persistence_content("computer_use", result) is None


def test_list_override_validation_is_strict_and_json_safe():
    valid = [
        {"type": "text", "text": "AX"},
        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{_TINY_JPEG_B64}"}},
    ]
    assert _validate_tool_result_persistence_content("capture_screen_context", valid) == valid
    assert _validate_tool_result_persistence_content("capture_screen_context", "AX") == "AX"

    invalid = [
        [],
        [{}],
        [{"type": "unknown", "text": "AX"}],
        [{"type": "text", "text": 1}],
        [{"type": "text", "text": "AX", "extra": True}],
        [{"type": "image_url", "image_url": {"url": "file:///tmp/a.jpg"}}],
        [{"type": "image_url", "image_url": {"url": "https://example.test/a.jpg"}}],
        [{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,not-base64!"}}],
        [{"type": "image_url", "image_url": {"url": "data:image/png;base64,QUJD"}}],
        [{"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{_TINY_JPEG_B64}", "extra": object()}}],
        [{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/AA=="}}],
        [{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,AAD/2Q=="}}],
    ]
    for value in invalid:
        assert _validate_tool_result_persistence_content("capture_screen_context", value) is None


def test_empty_override_list_falls_back_to_legacy_summary():
    agent = _make_agent()
    result = _rich_result(persistence_content=[], include_override=True)
    message = make_tool_result_message(
        "capture_screen_context",
        result["content"],
        "call-empty",
        persistence_content=result["persistence_content"],
    )
    _configure_flush(agent)

    agent._flush_messages_to_session_db([message], [])

    assert agent._session_db.append_message.call_args.kwargs["content"] == (
        "AX: Save button is visible\n[screenshot]"
    )
    assert PERSISTENCE_METADATA_KEY not in message


def test_context_engine_cannot_see_internal_persistence_metadata():
    agent = _make_agent()
    message = make_tool_result_message(
        "capture_screen_context",
        "live",
        "call-context",
        persistence_content="durable",
    )
    seen = {}

    class ContextEngine:
        def select_context(self, api_messages, *, conversation_messages, incoming_message, budget_tokens):
            seen["api"] = api_messages
            seen["conversation"] = conversation_messages
            seen["incoming"] = incoming_message
            return api_messages

    agent.context_compressor = ContextEngine()
    selected = _apply_context_engine_selection(
        agent,
        [dict(message)],
        [message],
        message,
        logger=MagicMock(),
    )

    assert all(PERSISTENCE_METADATA_KEY not in item for item in selected)
    assert all(PERSISTENCE_METADATA_KEY not in item for item in seen["api"])
    assert all(PERSISTENCE_METADATA_KEY not in item for item in seen["conversation"])
    assert PERSISTENCE_METADATA_KEY not in seen["incoming"]
    assert PERSISTENCE_METADATA_KEY in message


def test_durable_projection_drops_live_nonces_by_default_and_honors_explicit_ax_only():
    result = _nonce_rich_result()
    message = make_tool_result_message(
        "capture_screen_context",
        result,
        "call-projection-default",
    )

    projected = project_messages_for_durable_use([message])[0]

    assert "AX_NONCE_DURABLE_SINK" not in str(projected)
    assert "IMAGE_NONCE_DURABLE_SINK" not in str(projected)
    assert PERSISTENCE_METADATA_KEY not in projected
    assert message["content"] == result

    explicit = make_tool_result_message(
        "capture_screen_context",
        result["content"],
        "call-projection-explicit",
        persistence_content="AX_NONCE_DURABLE_SINK",
    )
    explicit_projected = project_messages_for_durable_use([explicit])[0]

    assert explicit_projected["content"] == "AX_NONCE_DURABLE_SINK"
    assert PERSISTENCE_METADATA_KEY not in explicit_projected
    assert explicit["content"] == result["content"]


def test_durable_projection_rejects_wire_name_spoof_when_tool_name_is_untrusted():
    result = _nonce_rich_result()
    message = make_tool_result_message(
        "capture_screen_context",
        result["content"],
        "call-projection-spoof",
        persistence_content="AX_NONCE_DURABLE_SINK",
    )
    message["tool_name"] = "computer_use"

    projected = project_messages_for_durable_use([message])[0]

    assert projected["content"][0] == {"type": "text", "text": "AX_NONCE_DURABLE_SINK"}
    assert projected["content"][1] == {"type": "text", "text": "[screenshot]"}
    assert PERSISTENCE_METADATA_KEY not in projected
    assert message[PERSISTENCE_METADATA_KEY] == "AX_NONCE_DURABLE_SINK"


def test_context_engine_post_turn_receives_durable_projection_without_live_nonces():
    agent = _make_agent()
    result = _nonce_rich_result()
    message = make_tool_result_message(
        "capture_screen_context",
        result,
        "call-context-post-turn",
    )
    seen = {}

    class ContextEngine:
        def on_turn_complete(self, messages, **kwargs):
            seen["messages"] = messages

    agent.context_compressor = ContextEngine()
    _notify_context_engine_turn_complete(
        agent,
        [message],
        logger=MagicMock(),
    )

    ingested = seen["messages"][0]
    assert "AX_NONCE_DURABLE_SINK" not in str(ingested)
    assert "IMAGE_NONCE_DURABLE_SINK" not in str(ingested)
    assert PERSISTENCE_METADATA_KEY not in ingested
    assert message["content"] == result


def test_external_memory_sync_receives_durable_projection_without_live_nonces():
    agent = _make_agent()
    agent._memory_manager = MagicMock()
    agent.session_id = "external-memory-projection"
    result = _nonce_rich_result()
    message = make_tool_result_message(
        "capture_screen_context",
        result,
        "call-memory-projection",
    )

    agent._sync_external_memory_for_turn(
        original_user_message="what is on screen?",
        final_response="The screen is visible.",
        interrupted=False,
        messages=[message],
    )

    synced_messages = agent._memory_manager.sync_all.call_args.kwargs["messages"]
    assert "AX_NONCE_DURABLE_SINK" not in str(synced_messages)
    assert "IMAGE_NONCE_DURABLE_SINK" not in str(synced_messages)
    assert PERSISTENCE_METADATA_KEY not in synced_messages[0]
    assert message["content"] == result


def test_explicit_persisted_ax_is_available_to_durable_sinks_but_not_trajectory_images():
    result = _nonce_rich_result(
        persistence_content="AX_NONCE_DURABLE_SINK",
        include_override=True,
    )
    message = make_tool_result_message(
        "capture_screen_context",
        result["content"],
        "call-explicit-sinks",
        persistence_content=result["persistence_content"],
    )

    durable = project_messages_for_durable_use([message])[0]
    trajectory = _trajectory_normalize_msg(message)

    assert durable["content"] == "AX_NONCE_DURABLE_SINK"
    assert "IMAGE_NONCE_DURABLE_SINK" not in str(trajectory)
    assert trajectory["content"][0] == {"type": "text", "text": "AX_NONCE_DURABLE_SINK"}
    assert PERSISTENCE_METADATA_KEY not in trajectory
    assert message["content"] == result["content"]


def test_trajectory_normalize_removes_internal_persistence_metadata():
    message = make_tool_result_message(
        "capture_screen_context",
        _rich_result()["content"],
        "call-trajectory",
        persistence_content="durable only",
    )

    normalized = _trajectory_normalize_msg(message)

    assert PERSISTENCE_METADATA_KEY not in normalized
    assert PERSISTENCE_METADATA_KEY in message
    assert normalized["content"][-1] == {"type": "text", "text": "[screenshot]"}


def test_real_session_db_round_trip_preserves_trusted_override_and_live_message(tmp_path):
    agent = _make_agent()
    db = SessionDB(db_path=tmp_path / "state.db")
    session_id = "real-multimodal-persistence"
    db.create_session(session_id, "test")
    agent._session_db = db
    agent._session_db_created = True
    agent.session_id = session_id
    agent._last_flushed_db_idx = 0
    agent._flushed_db_message_ids = set()
    agent._flushed_db_message_session_id = None
    override = [
        {"type": "text", "text": "AX: Save button is visible"},
        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{_TINY_JPEG_B64}"}},
    ]
    message = make_tool_result_message(
        "capture_screen_context",
        _rich_result()["content"],
        "call-real",
        persistence_content=override,
    )
    live_before = {"content": message["content"], "metadata": message[PERSISTENCE_METADATA_KEY]}

    agent._flush_messages_to_session_db([message], [])

    db.close()
    reloaded_db = SessionDB(db_path=tmp_path / "state.db")
    reloaded = reloaded_db.get_messages_as_conversation(session_id)
    assert reloaded[-1]["content"] == override
    assert message["content"] == live_before["content"]
    assert message[PERSISTENCE_METADATA_KEY] == live_before["metadata"]
    assert PERSISTENCE_METADATA_KEY not in reloaded[-1]
    reloaded_db.close()

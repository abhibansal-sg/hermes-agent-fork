"""H08 golden tests for product-defined Live prompt blocks."""

from __future__ import annotations

import pytest

from agent.realtime_prompt import (
    MAX_DELEGATION_ENVELOPE_BYTES,
    build_intermediary_prompt,
    build_realtime_conversation_end_overlay,
    build_realtime_conversation_start_overlay,
    build_realtime_delegation_envelope,
)


def test_intermediary_prompt_is_compact_and_excludes_private_executor_context():
    prompt = build_intermediary_prompt(
        public_pa_identity="Hermes",
        spoken_style="concise and warm",
        backend_handoff_behavior="ask Hermes for tools or authoritative context",
        native_call_behavior="use native call controls for mute and stop",
        locale="en-SG",
        timezone="Asia/Singapore",
    )

    assert prompt.splitlines() == [
        "You are GPT-Live, the realtime conversational intermediary for Hermes.",
        "Spoken style: concise and warm",
        "Backend handoff: ask Hermes for tools or authoritative context",
        "Never claim that a tool succeeded until the Hermes executor returns its result.",
        "Native call control: use native call controls for mute and stop",
        "Locale: en-SG",
        "Timezone: Asia/Singapore",
    ]
    for prohibited in ("system prompt", "workspace roots", "OAuth", "MCP", "tool registry", "CODEX_HOME"):
        assert prohibited.lower() not in prompt.lower()


def test_overlays_match_recovered_ordering():
    start = build_realtime_conversation_start_overlay()
    end = build_realtime_conversation_end_overlay()

    assert start.index("<realtime_conversation>") < start.index("The Codex executor")
    assert start.index("The executor receives") < start.index("Transcript text")
    assert start.endswith("</realtime_conversation>")
    assert end == (
        "<realtime_conversation_end>\n"
        "Realtime conversation ended.\n"
        "Subsequent typed input is not transcript-style text.\n"
        "</realtime_conversation_end>"
    )


def test_delegation_envelope_escapes_and_preserves_exact_field_order():
    envelope = build_realtime_delegation_envelope(
        "say <hello> & \"now\"",
        "你好 & continue",
    )

    assert envelope == (
        "<realtime_delegation>\n"
        "<input>say &lt;hello&gt; &amp; &quot;now&quot;</input>\n"
        "<transcript_delta>你好 &amp; continue</transcript_delta>\n"
        "</realtime_delegation>"
    )
    assert envelope.index("<input>") < envelope.index("<transcript_delta>")


def test_tail_flush_adds_only_the_observed_source_prefix():
    envelope = build_realtime_delegation_envelope(
        "finish the last request", "tail", source="transcript_tail_flush"
    )

    assert envelope.splitlines()[1:3] == [
        "<source>transcript_tail_flush</source>",
        "<input>finish the last request</input>",
    ]
    with pytest.raises(ValueError):
        build_realtime_delegation_envelope("x", "y", source="other")


def test_bounds_are_deterministic_and_unicode_is_not_dropped():
    with pytest.raises(ValueError, match="UTF-8 bytes"):
        build_realtime_delegation_envelope("x" * MAX_DELEGATION_ENVELOPE_BYTES, "y")
    value = build_realtime_delegation_envelope("继续", "说话")
    assert "继续" in value and "说话" in value


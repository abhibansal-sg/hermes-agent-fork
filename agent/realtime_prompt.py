"""Product-defined GPT-Live prompt and Hermes handoff envelopes."""

from __future__ import annotations

from typing import Optional


MAX_PROMPT_VALUE_BYTES = 16_384
MAX_DELEGATION_ENVELOPE_BYTES = 32_768


def _bounded(value: str, *, name: str, limit: int = MAX_PROMPT_VALUE_BYTES) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a string")
    if len(value.encode("utf-8")) > limit:
        raise ValueError(f"{name} exceeds {limit} UTF-8 bytes")
    return value


def xml_escape(value: str) -> str:
    """Escape text values for the product's XML-shaped prompt blocks."""
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def build_intermediary_prompt(
    *,
    public_pa_identity: str,
    spoken_style: str,
    backend_handoff_behavior: str,
    native_call_behavior: str,
    locale: Optional[str] = None,
    timezone: Optional[str] = None,
) -> str:
    """Build only the compact product-defined GPT-Live intermediary prompt."""
    identity = _bounded(public_pa_identity, name="public_pa_identity")
    style = _bounded(spoken_style, name="spoken_style")
    handoff = _bounded(backend_handoff_behavior, name="backend_handoff_behavior")
    native = _bounded(native_call_behavior, name="native_call_behavior")
    lines = [
        f"You are GPT-Live, the realtime conversational intermediary for {identity}.",
        f"Spoken style: {style}",
        f"Backend handoff: {handoff}",
        "Never claim that a tool succeeded until the Hermes executor returns its result.",
        f"Native call control: {native}",
    ]
    if locale is not None:
        lines.append(f"Locale: {_bounded(locale, name='locale')}")
    if timezone is not None:
        lines.append(f"Timezone: {_bounded(timezone, name='timezone')}")
    return "\n".join(lines)


def build_realtime_conversation_start_overlay() -> str:
    return "\n".join((
        "<realtime_conversation>",
        "The Codex executor is behind a realtime intermediary.",
        "The user does not address the executor directly.",
        "The executor receives the latest transcript and mode metadata.",
        "Transcript text may be unpunctuated or contain recognition errors.",
        "The executor should avoid work when backend help is unnecessary.",
        "Responses should be concise and action-oriented for the intermediary.",
        "</realtime_conversation>",
    ))


def build_realtime_conversation_end_overlay() -> str:
    return "\n".join((
        "<realtime_conversation_end>",
        "Realtime conversation ended.",
        "Subsequent typed input is not transcript-style text.",
        "</realtime_conversation_end>",
    ))


def build_realtime_delegation_envelope(
    input_text: str,
    transcript_delta: str,
    *,
    source: Optional[str] = None,
) -> str:
    """Build one ordered user envelope without persisting a transcript copy."""
    input_text = _bounded(input_text, name="input")
    transcript_delta = _bounded(transcript_delta, name="transcript_delta")
    if source is not None and source != "transcript_tail_flush":
        raise ValueError("unsupported realtime delegation source")
    fields = []
    if source is not None:
        fields.append(f"<source>{xml_escape(_bounded(source, name='source'))}</source>")
    fields.extend((
        f"<input>{xml_escape(input_text)}</input>",
        f"<transcript_delta>{xml_escape(transcript_delta)}</transcript_delta>",
    ))
    envelope = "<realtime_delegation>\n" + "\n".join(fields) + "\n</realtime_delegation>"
    if len(envelope.encode("utf-8")) > MAX_DELEGATION_ENVELOPE_BYTES:
        raise ValueError(
            f"realtime delegation exceeds {MAX_DELEGATION_ENVELOPE_BYTES} UTF-8 bytes"
        )
    return envelope


build_handoff_envelope = build_realtime_delegation_envelope


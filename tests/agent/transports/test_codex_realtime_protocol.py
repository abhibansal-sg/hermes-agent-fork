"""H07 realtime protocol builder tests."""

from __future__ import annotations

import pytest

from agent.transports.codex_realtime import (
    MAX_SDP_BYTES,
    build_attestation_request,
    build_initialize_request,
    build_realtime_control_request,
    build_realtime_sdp_request,
    build_realtime_start_request,
    build_thread_start_request,
)


def test_builders_preserve_required_protocol_order_and_values():
    initialize = build_initialize_request()
    thread = build_thread_start_request("/work")
    realtime = build_realtime_start_request("thread-1", prompt="Speak plainly", sdp="offer")

    assert list(initialize["params"]) == ["clientInfo", "capabilities"]
    assert list(thread["params"]) == ["cwd", "config"]
    assert realtime["method"] == "thread/realtime/start"
    assert realtime["params"]["threadId"] == "thread-1"
    assert realtime["params"]["transport"] == {"type": "webrtc", "sdp": "offer"}
    assert realtime["params"]["includeStartupContext"] is False
    assert realtime["params"]["flushTranscriptTailOnSessionEnd"] is True


def test_sdp_and_attestation_requests_are_bounded():
    sdp = build_realtime_sdp_request("thread-1", "offer", realtime_session_id="rt-1")

    assert sdp == {
        "method": "thread/realtime/sdp",
        "params": {"threadId": "thread-1", "sdp": "offer", "realtimeSessionId": "rt-1"},
    }
    assert build_attestation_request() == {"method": "attestation/generate", "params": {}}
    with pytest.raises(ValueError, match="UTF-8 bytes"):
        build_realtime_sdp_request("thread-1", "x" * (MAX_SDP_BYTES + 1))


def test_control_builders_cover_detach_reconnect_and_stop():
    assert build_realtime_control_request("detach", "thread-1")["method"] == "thread/realtime/detach"
    assert build_realtime_control_request("reconnect", "thread-1")["method"] == "thread/realtime/reconnect"
    assert build_realtime_control_request("stop", "thread-1")["method"] == "thread/realtime/stop"
    with pytest.raises(ValueError):
        build_realtime_control_request("fork", "thread-1")


def test_unicode_is_preserved_and_size_is_measured_in_utf8():
    prompt = "你好，Hermes"
    request = build_realtime_start_request("线程", prompt=prompt)

    assert request["params"]["prompt"] == prompt


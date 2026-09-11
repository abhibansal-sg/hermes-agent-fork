import threading
from tui_gateway import server

def _session(**kwargs):
    return {"history_lock": threading.Lock(), "history": [], "running": False, **kwargs}

def test_compute_host_turn_error_retains_recoverable_inflight_failure(monkeypatch):
    session = _session(
        agent=None,
        agent_ready=threading.Event(),
        _compute_host_active=True,
        running=True,
    )
    server._start_inflight_turn(session, "draft the follow-up")
    parent_turn_id = session["inflight_turn"]["turn_id"]
    parent_started_at = session["inflight_turn"]["started_at"]
    server._sessions["iso-error"] = session
    emitted = []
    monkeypatch.setattr(
        server,
        "_emit",
        lambda event, sid, payload=None: emitted.append((event, sid, payload)),
    )

    try:
        server._on_compute_host_turn_done(
            "turn-error",
            "iso-error",
            session,
            {
                "type": "turn.end",
                "sid": "iso-error",
                "request_id": "turn-error",
                "status": "error",
                "error": "HTTP 503: all accounts at capacity",
                "recoverable": True,
                "terminal_event_emitted": True,
                "inflight": {
                    "user": "draft the follow-up",
                    "assistant": "partial reply from child",
                    "corrections": ["use the shorter version"],
                    "streaming": False,
                    "turn_id": "child-turn-id-must-not-win",
                    "started_at": 1.0,
                    "status": "error",
                    "error": "HTTP 503: all accounts at capacity",
                    "recoverable": True,
                },
            },
        )

        assert session["running"] is False
        inflight = server._inflight_snapshot(session)
        assert inflight is not None
        assert inflight["assistant"] == "partial reply from child"
        assert inflight["corrections"] == ["use the shorter version"]
        assert inflight["streaming"] is False
        assert inflight["user"] == "draft the follow-up"
        assert inflight["status"] == "error"
        assert inflight["error"] == "HTTP 503: all accounts at capacity"
        assert inflight["recoverable"] is True
        assert inflight["turn_id"] == parent_turn_id
        assert inflight["started_at"] == parent_started_at
        assert not any(event == "message.complete" for event, _sid, _payload in emitted)
    finally:
        server._sessions.pop("iso-error", None)


def test_compute_host_normal_turn_end_carries_returned_provider_failure(monkeypatch):
    from tui_gateway.compute_host import ComputeHost

    sid = "iso-returned-error"
    session = _session(agent=None, agent_ready=threading.Event(), _compute_host_active=True)
    server._sessions[sid] = session
    emitted = []
    host = ComputeHost(heartbeat_secs=0)
    host.emit = emitted.append

    def _returned_error(_rid, _sid, child_session, _text, **_kwargs):
        with child_session["history_lock"]:
            server._fail_inflight_turn(child_session, "HTTP 503: all accounts at capacity")
            child_session["running"] = False

    monkeypatch.setattr(server, "_run_prompt_submit", _returned_error)
    monkeypatch.setattr(server, "_session_info", lambda *_args, **_kwargs: {})
    try:
        host._run_real_turn(
            {
                "type": "turn.start",
                "sid": sid,
                "request_id": "turn-returned-error",
                "session_key": "stored-returned-error",
                "text": "draft the follow-up",
                "history": [],
            }
        )
    finally:
        host.close()
        server._sessions.pop(sid, None)

    completed = next(frame for frame in emitted if frame.get("type") == "turn.end")
    assert completed["status"] == "error"
    assert completed["error"] == "HTTP 503: all accounts at capacity"
    assert completed["recoverable"] is True
    assert completed["terminal_event_emitted"] is True
    assert completed["inflight"]["status"] == "error"
    assert completed["inflight"]["turn_id"]

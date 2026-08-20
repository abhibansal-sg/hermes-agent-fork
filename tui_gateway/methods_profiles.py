"""Profile-scoped JSON-RPC handlers.

This module deliberately keeps Bot Mode's durable identity in Hermes' existing
profile metadata and SessionDB authorities.  It does not introduce a second
session store or a plugin-owned transcript.  Handlers are rebound onto
``tui_gateway.server`` at import time; keep request-local helpers nested so
they resolve the server's globals after that rebinding.
"""

from __future__ import annotations

import contextlib
from pathlib import Path

from .method_ctx import HandlerRegistry

_registry = HandlerRegistry()
method = _registry.method


@method("profiles.ensure_bot_chat")
def _(rid, params: dict) -> dict:
    """Return the one durable, hidden Bot Chat for a profile.

    The profile's ``profile.yaml`` ``ui_meta.hermes-bots.chat`` value is the
    same canonical pointer used by the desktop Bot Mode plugin.  A per-profile
    file lock plus the gateway's existing session lock keeps repeated calls in
    this process and concurrent gateway processes from minting two chats.

    The generic hidden-session authority was added upstream in
    ``SessionDB.set_session_hidden``.  Refuse to claim success on an older
    backend rather than silently creating a visible duplicate; this lets
    clients feature-detect the complete contract through ``gateway.ready``.
    """

    profile = params.get("profile") if isinstance(params, dict) else None
    profile = profile.strip() if isinstance(profile, str) else ""
    if not profile:
        return _err(rid, 4067, "profile required")

    try:
        from hermes_cli import profiles as profiles_mod

        # Validate against the canonical profile registry, not just a path
        # concatenation.  This rejects traversal/case aliases and ensures the
        # DB + metadata both belong to a real Hermes profile.
        profile_info = next(
            (item for item in profiles_mod.list_profiles() if item.name == profile),
            None,
        )
        if profile_info is None:
            return _err(rid, 4068, f"profile '{profile}' not found")
        profile_dir = Path(profile_info.path)
    except Exception as exc:
        return _err(rid, 5067, f"profile validation failed: {exc}")

    if not profile_dir.is_dir():
        return _err(rid, 4068, f"profile '{profile}' not found")

    # A flock handles separate Hermes gateway processes.  The existing gateway
    # session lock handles same-process threads (and also keeps metadata and DB
    # updates ordered with other local gateway session operations).
    lock_path = profile_dir / ".bot-chat.lock"
    try:
        lock_path.touch(exist_ok=True)
    except OSError as exc:
        return _err(rid, 5067, f"could not lock profile '{profile}': {exc}")

    @contextlib.contextmanager
    def _locked_profile():
        with open(lock_path, "a+", encoding="utf-8") as lock_file:
            flocked = False
            try:
                try:
                    import fcntl

                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
                    flocked = True
                except (ImportError, OSError):
                    # Windows has no fcntl; the gateway's process-local lock
                    # still protects repeated calls in one process there.
                    pass
                yield
            finally:
                if flocked:
                    try:
                        fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
                    except OSError:
                        pass

    def _read_profile_yaml() -> dict:
        path = profile_dir / "profile.yaml"
        if not path.is_file():
            return {}
        import yaml

        with open(path, "r", encoding="utf-8") as meta_file:
            loaded = yaml.safe_load(meta_file) or {}
        if not isinstance(loaded, dict):
            raise ValueError("profile.yaml must contain a mapping")
        return loaded

    def _write_profile_yaml(meta: dict) -> None:
        from utils import atomic_yaml_write

        atomic_yaml_write(profile_dir / "profile.yaml", meta, sort_keys=False)

    def _canonical_pin(meta: dict) -> str:
        ui_meta = meta.get("ui_meta")
        if not isinstance(ui_meta, dict):
            return ""
        bot_meta = ui_meta.get("hermes-bots")
        if not isinstance(bot_meta, dict):
            return ""
        pin = bot_meta.get("chat")
        return pin.strip() if isinstance(pin, str) else ""

    def _is_canonical_chat(db, row: dict, fallback_id: str = "") -> bool:
        """Accept only a Bot Chat root/current row, never an ordinary chat.

        Compression can move the live transcript to a descendant.  Mirror the
        desktop's ``root_title``/``title`` check by accepting either the
        pinned root's exact title or its resolved current tip's exact title.
        """
        if not isinstance(row, dict):
            return False
        if str(row.get("title") or "").strip() == "Bot Chat":
            return True
        source_id = str(row.get("id") or fallback_id or "").strip()
        if not source_id:
            return False
        try:
            # Preserve the desktop's root-title acceptance for a pin that was
            # updated to a compression tip by an older client.
            ancestor = row
            for _ in range(32):
                parent_id = str(ancestor.get("parent_session_id") or "").strip()
                if not parent_id:
                    break
                parent = db.get_session(parent_id)
                if not parent:
                    break
                if str(parent.get("title") or "").strip() == "Bot Chat":
                    return True
                ancestor = parent
            tip_id = db.resolve_resume_session_id(source_id)
            tip = db.get_session(tip_id) if tip_id else None
            return str((tip or {}).get("title") or "").strip() == "Bot Chat"
        except Exception:
            return False

    try:
        # Keep the lock ordering explicit: _sessions_lock first, then the
        # profile file lock.  This mirrors gateway action/session paths and
        # prevents a future handler from introducing a lock inversion.
        with _sessions_lock:
            with _locked_profile():
                meta = _read_profile_yaml()
                pinned = _canonical_pin(meta)
                with _profile_db({"profile": profile}) as db:
                    if db is None:
                        return _db_unavailable_error(rid, code=5067)

                    set_hidden = getattr(db, "set_session_hidden", None)
                    if not callable(set_hidden):
                        return _err(
                            rid,
                            5069,
                            "profiles.ensure_bot_chat requires generic hidden-session support",
                        )

                    row = db.get_session(pinned) if pinned else None
                    if row is not None and not _is_canonical_chat(db, row, pinned):
                        row = None
                    if row is None:
                        # Match desktop Bot Mode's grandfather/recovery rule:
                        # an existing exact-title Bot Chat is adopted before a
                        # new row is created.  Ordinary sessions are never
                        # adopted by title other than this exact plumbing title.
                        row = db.get_session_by_title("Bot Chat")
                        if row is not None and not _is_canonical_chat(db, row):
                            row = None

                    created = False
                    if row is None:
                        stored_id = _new_session_key()
                        db.create_session(
                            stored_id,
                            source="desktop",
                            profile_name=None if profile == "default" else profile,
                        )
                        try:
                            db.set_session_title(stored_id, "Bot Chat")
                        except Exception:
                            # A concurrent non-RPC writer may have claimed the
                            # title. Re-read the canonical title and adopt it;
                            # do not expose a second chat to the client.
                            adopted = db.get_session_by_title("Bot Chat")
                            if adopted is None:
                                raise
                            stored_id = str(adopted["id"])
                        else:
                            created = True
                        row = db.get_session(stored_id) or {"id": stored_id}
                    stored_id = str(row.get("id") or "").strip()
                    if not stored_id:
                        raise RuntimeError("Bot Chat row has no session id")

                    # ``False`` means either an already-hidden row or no
                    # changed column; both are idempotent success once the row
                    # exists.  Exceptions remain real failures.
                    set_hidden(stored_id, True)

                    ui_meta = meta.get("ui_meta")
                    if not isinstance(ui_meta, dict):
                        ui_meta = {}
                    bot_meta = ui_meta.get("hermes-bots")
                    if not isinstance(bot_meta, dict):
                        bot_meta = {}
                    if bot_meta.get("chat") != stored_id:
                        bot_meta["chat"] = stored_id
                        ui_meta["hermes-bots"] = bot_meta
                        meta["ui_meta"] = ui_meta
                        _write_profile_yaml(meta)

                    return _ok(
                        rid,
                        {
                            "session_id": stored_id,
                            "profile": profile,
                            "created": created,
                        },
                    )
    except Exception as exc:
        return _err(rid, 5069, str(exc))


def register(server) -> None:
    _registry.install(server)

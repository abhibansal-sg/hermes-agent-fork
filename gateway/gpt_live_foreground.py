"""Process-local foreground ownership for GPT-Live and native text turns."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import threading
from typing import Any, Iterator

from gateway.session_context import get_gpt_live_context


class ForegroundLeaseError(RuntimeError):
    """Raised when a caller does not own the current foreground identity."""


@dataclass(frozen=True)
class ForegroundLeaseIdentity:
    provider_kind: str
    session_id: str
    call_id: str
    generation: int


class ForegroundLease:
    def __init__(self, registry: "ForegroundLeaseRegistry", identity: ForegroundLeaseIdentity):
        self._registry = registry
        self.identity = identity
        self._released = False

    @property
    def released(self) -> bool:
        return self._released

    def release(self) -> bool:
        if self._released:
            return False
        self._released = True
        return self._registry.release(self)

    def __enter__(self) -> "ForegroundLease":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.release()


class ForegroundExecutorAccess:
    def __init__(self, identity: ForegroundLeaseIdentity):
        self.identity = identity
        self._released = False

    def release(self) -> bool:
        if self._released:
            return False
        self._released = True
        return True

    def __enter__(self) -> "ForegroundExecutorAccess":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.release()


class ForegroundLeaseRegistry:
    """One process-local provider owner per native Hermes session."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._owners: dict[str, tuple[ForegroundLeaseIdentity, int]] = {}

    def acquire(
        self,
        *,
        provider_kind: str,
        session_id: str,
        call_id: str,
        generation: int,
    ) -> ForegroundLease | None:
        if not session_id or not call_id:
            return None
        identity = ForegroundLeaseIdentity(
            provider_kind=str(provider_kind),
            session_id=str(session_id),
            call_id=str(call_id),
            generation=int(generation),
        )
        with self._lock:
            current = self._owners.get(identity.session_id)
            if current is not None and current[0] != identity:
                return None
            self._owners[identity.session_id] = (
                identity,
                (current[1] if current else 0) + 1,
            )
            return ForegroundLease(self, identity)

    def release(self, lease: ForegroundLease) -> bool:
        with self._lock:
            current = self._owners.get(lease.identity.session_id)
            if current is None or current[0] != lease.identity:
                return False
            if current[1] <= 1:
                self._owners.pop(lease.identity.session_id, None)
            else:
                self._owners[lease.identity.session_id] = (current[0], current[1] - 1)
            return True

    def allow_executor(
        self,
        *,
        session_id: str,
        call_id: str,
        generation: int,
    ) -> ForegroundExecutorAccess | None:
        identity = ForegroundLeaseIdentity(
            "gpt_live", str(session_id), str(call_id), int(generation)
        )
        with self._lock:
            current = self._owners.get(identity.session_id)
            if current is None or current[0] != identity:
                return None
            return ForegroundExecutorAccess(identity)

    def release_session(self, session_id: str) -> bool:
        with self._lock:
            return self._owners.pop(str(session_id), None) is not None

    def snapshot(self) -> dict[str, ForegroundLeaseIdentity]:
        with self._lock:
            return {
                session_id: owner[0]
                for session_id, owner in self._owners.items()
            }


foreground_leases = ForegroundLeaseRegistry()


def acquire_live_foreground_lease(
    session_id: str, call_id: str, generation: int
) -> ForegroundLease | None:
    return foreground_leases.acquire(
        provider_kind="gpt_live",
        session_id=session_id,
        call_id=call_id,
        generation=generation,
    )


def acquire_text_foreground_lease(
    session_id: str, call_id: str, generation: int
) -> ForegroundLease | None:
    return foreground_leases.acquire(
        provider_kind="hermes_text",
        session_id=session_id,
        call_id=call_id,
        generation=generation,
    )


@contextmanager
def scoped_executor_tool_overlay(
    agent: Any,
    tool_definitions: list[dict[str, Any]] | None = None,
) -> Iterator[None]:
    """Expose Live-only definitions for one attached executor turn."""
    context = get_gpt_live_context()
    session_id = str(getattr(agent, "session_id", "") or "")
    if not context["active"] or context["native_session_id"] != session_id:
        raise ForegroundLeaseError("GPT-Live executor context is not active for this session")
    access = foreground_leases.allow_executor(
        session_id=session_id,
        call_id=context["call_id"],
        generation=context["generation"],
    )
    if access is None:
        raise ForegroundLeaseError("GPT-Live foreground lease is stale or unavailable")

    original_tools = getattr(agent, "tools", None)
    original_valid = getattr(agent, "valid_tool_names", None)
    sentinel = object()
    original_valid_value = original_valid if original_valid is not None else sentinel
    existing_names = {
        item.get("function", {}).get("name")
        for item in (original_tools or [])
        if isinstance(item, dict)
    }
    additions = [
        item for item in (tool_definitions or [])
        if isinstance(item, dict)
        and item.get("function", {}).get("name") not in existing_names
    ]
    try:
        if additions:
            agent.tools = list(original_tools or []) + additions
            if original_valid is not None:
                agent.valid_tool_names = set(original_valid) | {
                    item["function"]["name"] for item in additions
                }
        yield
    finally:
        agent.tools = original_tools
        if original_valid_value is sentinel:
            try:
                del agent.valid_tool_names
            except AttributeError:
                pass
        else:
            agent.valid_tool_names = original_valid_value
        access.release()


"""Generic durable-admission provider seam for ``prompt.submit``.

Hermes owns request fingerprinting and admission ordering. Providers own only
durable reservation storage; they cannot execute, queue, rewrite, or replay a
prompt themselves.
"""

from __future__ import annotations

import hashlib
import json
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol


class PromptReceiptProvider(Protocol):
    provider_name: str

    def reserve(
        self,
        *,
        profile_home: Path,
        client_message_id: str,
        request_fingerprint: str,
    ) -> dict[str, Any]: ...

    def complete(self, reservation: Any, disposition: dict[str, Any]) -> None: ...

    def release(self, reservation: Any) -> None: ...


@dataclass(frozen=True)
class PromptAdmission:
    provider: PromptReceiptProvider
    reservation: Any
    client_message_id: str


_lock = threading.RLock()
_providers: list[PromptReceiptProvider] = []


def register_prompt_receipt_provider(provider: PromptReceiptProvider) -> None:
    """Register a structural provider once by identity or stable name."""
    if provider is None:
        return
    name = str(getattr(provider, "provider_name", "") or "").strip()
    if not name:
        raise ValueError("prompt receipt provider_name is required")
    for method_name in ("reserve", "complete", "release"):
        if not callable(getattr(provider, method_name, None)):
            raise TypeError(f"prompt receipt provider missing {method_name}()")
    with _lock:
        if any(
            existing is provider
            or str(getattr(existing, "provider_name", "") or "") == name
            for existing in _providers
        ):
            return
        _providers.append(provider)


def prompt_receipt_provider() -> PromptReceiptProvider | None:
    with _lock:
        return _providers[0] if _providers else None


def ensure_prompt_receipt_provider() -> PromptReceiptProvider | None:
    """Run stock plugin discovery once when the provider has not loaded yet."""
    provider = prompt_receipt_provider()
    if provider is not None:
        return provider
    try:
        from hermes_cli.plugins import discover_plugins

        discover_plugins()
    except Exception:
        return None
    return prompt_receipt_provider()


def request_fingerprint(
    *,
    session_key: str,
    text: Any,
    truncate_before_user_ordinal: Any,
    confirm_truncate: Any,
    confirm_empty_truncate: Any,
    queued: Any,
    interrupted: Any,
) -> str:
    """Hash every prompt parameter that can change canonical action semantics."""
    payload = {
        "confirm_empty_truncate": bool(confirm_empty_truncate),
        "confirm_truncate": bool(confirm_truncate),
        "interrupted": bool(interrupted),
        "queued": bool(queued),
        "session_key": str(session_key),
        "text": text,
        "truncate_before_user_ordinal": truncate_before_user_ordinal,
    }
    encoded = json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _reset_for_tests() -> None:
    with _lock:
        _providers.clear()

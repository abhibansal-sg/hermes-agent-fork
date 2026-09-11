"""Durable SQLite reservations for the stock Hermes prompt-admission seam."""

from __future__ import annotations

import json
import os
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any, Callable

RETENTION_SECONDS = 30 * 24 * 60 * 60
_DB_RELATIVE_PATH = Path("plugins") / "hermes-mobile" / "prompt_receipts.sqlite3"


class SQLitePromptReceiptProvider:
    """Atomic, process-aware prompt receipt storage and nothing else."""

    provider_name = "hermes-mobile.sqlite-prompt-receipts"

    def __init__(
        self,
        *,
        owner_id: str | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.owner_id = owner_id or uuid.uuid4().hex
        self._clock = clock

    @staticmethod
    def database_path(profile_home: str | os.PathLike[str]) -> Path:
        return Path(profile_home) / _DB_RELATIVE_PATH

    def _connect(self, profile_home: str | os.PathLike[str]) -> sqlite3.Connection:
        path = self.database_path(profile_home)
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(path.parent, 0o700)
        except OSError:
            pass
        conn = sqlite3.connect(str(path), timeout=30.0, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout = 30000")
        from hermes_state import apply_wal_with_fallback

        apply_wal_with_fallback(conn, db_label=str(path))
        conn.execute("PRAGMA synchronous = FULL")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS prompt_receipts (
                client_message_id TEXT PRIMARY KEY,
                request_fingerprint TEXT NOT NULL,
                state TEXT NOT NULL,
                owner_id TEXT,
                disposition_json TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        try:
            os.chmod(path, 0o600)
            for suffix in ("-wal", "-shm"):
                sidecar = Path(f"{path}{suffix}")
                if sidecar.exists():
                    os.chmod(sidecar, 0o600)
        except OSError:
            pass
        return conn

    def reserve(
        self,
        *,
        profile_home: Path,
        client_message_id: str,
        request_fingerprint: str,
    ) -> dict[str, Any]:
        now = float(self._clock())
        conn = self._connect(profile_home)
        try:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute(
                "DELETE FROM prompt_receipts WHERE created_at < ?",
                (now - RETENTION_SECONDS,),
            )
            row = conn.execute(
                "SELECT * FROM prompt_receipts WHERE client_message_id = ?",
                (client_message_id,),
            ).fetchone()
            if row is None:
                conn.execute(
                    """
                    INSERT INTO prompt_receipts (
                        client_message_id, request_fingerprint, state, owner_id,
                        disposition_json, created_at, updated_at
                    ) VALUES (?, ?, 'reserved', ?, NULL, ?, ?)
                    """,
                    (client_message_id, request_fingerprint, self.owner_id, now, now),
                )
                conn.commit()
                return {
                    "state": "claimed",
                    "reservation": {
                        "profile_home": str(profile_home),
                        "client_message_id": client_message_id,
                        "request_fingerprint": request_fingerprint,
                        "owner_id": self.owner_id,
                    },
                }

            if row["request_fingerprint"] != request_fingerprint:
                conn.commit()
                return {"state": "conflict"}
            if row["state"] == "accepted" and row["disposition_json"]:
                try:
                    disposition = json.loads(row["disposition_json"])
                except (TypeError, ValueError, json.JSONDecodeError):
                    disposition = None
                if isinstance(disposition, dict):
                    conn.commit()
                    return {"state": "replay", "disposition": disposition}
            if row["state"] == "reserved" and row["owner_id"] == self.owner_id:
                conn.commit()
                return {"state": "in_progress"}

            if row["state"] != "indeterminate":
                conn.execute(
                    """
                    UPDATE prompt_receipts
                       SET state = 'indeterminate', owner_id = NULL, updated_at = ?
                     WHERE client_message_id = ?
                    """,
                    (now, client_message_id),
                )
            conn.commit()
            return {"state": "indeterminate"}
        except Exception:
            if conn.in_transaction:
                conn.rollback()
            raise
        finally:
            conn.close()

    def complete(self, reservation: dict[str, str], disposition: dict[str, Any]) -> None:
        payload = json.dumps(
            disposition,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        conn = self._connect(reservation["profile_home"])
        try:
            conn.execute("BEGIN IMMEDIATE")
            cursor = conn.execute(
                """
                UPDATE prompt_receipts
                   SET state = 'accepted', disposition_json = ?, updated_at = ?
                 WHERE client_message_id = ?
                   AND request_fingerprint = ?
                   AND state = 'reserved'
                   AND owner_id = ?
                """,
                (
                    payload,
                    float(self._clock()),
                    reservation["client_message_id"],
                    reservation["request_fingerprint"],
                    reservation["owner_id"],
                ),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("prompt receipt reservation is no longer owned")
            conn.commit()
        except Exception:
            if conn.in_transaction:
                conn.rollback()
            raise
        finally:
            conn.close()

    def release(self, reservation: dict[str, str]) -> None:
        conn = self._connect(reservation["profile_home"])
        try:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute(
                """
                DELETE FROM prompt_receipts
                 WHERE client_message_id = ?
                   AND request_fingerprint = ?
                   AND state = 'reserved'
                   AND owner_id = ?
                """,
                (
                    reservation["client_message_id"],
                    reservation["request_fingerprint"],
                    reservation["owner_id"],
                ),
            )
            conn.commit()
        except Exception:
            if conn.in_transaction:
                conn.rollback()
            raise
        finally:
            conn.close()


PROVIDER = SQLitePromptReceiptProvider()

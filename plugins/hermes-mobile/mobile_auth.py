"""Thin native-client credential provider for Hermes Mobile.

Hermes remains authoritative for sessions, action ordering, ownership, and
takeover.  This provider owns only one-time pairing bootstraps plus opaque
access/refresh credentials carrying a stable ``Session.client_id``.
"""

from __future__ import annotations

import hashlib
import os
import secrets
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Callable

from hermes_cli.dashboard_auth.base import (
    DashboardAuthProvider,
    LoginStart,
    ProviderError,
    RefreshExpiredError,
    Session,
    TokenPrincipal,
)
from hermes_constants import get_hermes_home

BOOTSTRAP_TTL_SECONDS = 5 * 60
ACCESS_TTL_SECONDS = 15 * 60
REFRESH_TTL_SECONDS = 30 * 24 * 60 * 60
RECEIPT_RETENTION_SECONDS = 30 * 24 * 60 * 60
PAIR_EXCHANGE_SCOPE = "mobile_pair:exchange"
PAIR_EXCHANGE_PATH = "/api/plugins/hermes-mobile/pair/exchange"

_DB_RELATIVE_PATH = Path("plugins") / "hermes-mobile" / "native_auth.sqlite3"
_BOOTSTRAP_PREFIX = "hmb_"
_ACCESS_PREFIX = "hma_"
_REFRESH_PREFIX = "hmr_"


class BootstrapInvalid(Exception):
    """The pairing bootstrap is unknown, expired, consumed, or malformed."""


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _new_token(prefix: str) -> str:
    return f"{prefix}{secrets.token_urlsafe(32)}"


def _safe_device_name(value: str) -> str:
    cleaned = "".join(ch for ch in value.strip() if ch.isprintable())
    return cleaned[:64] or "iPhone"


class SQLiteNativeCredentialProvider(DashboardAuthProvider):
    """Profile-scoped opaque credentials for remote native clients."""

    name = "hermes-mobile"
    display_name = "Hermes Mobile"
    supports_session = True
    supports_interactive_login = False
    supports_token = True

    def __init__(self, *, clock: Callable[[], float] = time.time) -> None:
        self._clock = clock

    @staticmethod
    def database_path(profile_home: str | os.PathLike[str] | None = None) -> Path:
        return Path(profile_home or get_hermes_home()) / _DB_RELATIVE_PATH

    def _connect(self) -> sqlite3.Connection:
        path = self.database_path()
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
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS native_pair_bootstraps (
                token_hash TEXT PRIMARY KEY,
                client_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                device_name TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                consumed_at INTEGER
            );
            CREATE TABLE IF NOT EXISTS native_client_sessions (
                session_id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                client_id TEXT NOT NULL,
                device_name TEXT NOT NULL,
                access_hash TEXT NOT NULL UNIQUE,
                access_expires_at INTEGER NOT NULL,
                refresh_hash TEXT NOT NULL UNIQUE,
                refresh_expires_at INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                revoked_at INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_native_client_sessions_client
                ON native_client_sessions(client_id);
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

    def _identity(self) -> tuple[str, str]:
        try:
            from hermes_cli.profiles import get_active_profile_name

            profile = get_active_profile_name()
        except Exception:
            profile = "default"
        return f"local:{profile}", profile

    def _prune_locked(self, conn: sqlite3.Connection, now: int) -> None:
        conn.execute(
            """
            DELETE FROM native_pair_bootstraps
             WHERE COALESCE(consumed_at, expires_at) < ?
            """,
            (now - RECEIPT_RETENTION_SECONDS,),
        )
        conn.execute(
            """
            DELETE FROM native_client_sessions
             WHERE (revoked_at IS NOT NULL AND revoked_at < ?)
                OR refresh_expires_at < ?
            """,
            (now - RECEIPT_RETENTION_SECONDS, now - RECEIPT_RETENTION_SECONDS),
        )

    def mint_bootstrap(self, *, device_name: str = "iPhone") -> dict[str, object]:
        """Persist a hashed, short-lived, one-use pairing bootstrap."""
        now = int(self._clock())
        token = _new_token(_BOOTSTRAP_PREFIX)
        user_id, _profile = self._identity()
        client_id = f"ios:{uuid.uuid4().hex}"
        try:
            conn = self._connect()
        except Exception as exc:
            raise ProviderError("native credential store unavailable") from exc
        try:
            conn.execute("BEGIN IMMEDIATE")
            self._prune_locked(conn, now)
            conn.execute(
                """
                INSERT INTO native_pair_bootstraps (
                    token_hash, client_id, user_id, device_name,
                    created_at, expires_at, consumed_at
                ) VALUES (?, ?, ?, ?, ?, ?, NULL)
                """,
                (
                    _token_hash(token),
                    client_id,
                    user_id,
                    _safe_device_name(device_name),
                    now,
                    now + BOOTSTRAP_TTL_SECONDS,
                ),
            )
            conn.commit()
        except Exception:
            if conn.in_transaction:
                conn.rollback()
            raise
        finally:
            conn.close()
        return {
            "bootstrap": token,
            "client_id": client_id,
            "expires_at": now + BOOTSTRAP_TTL_SECONDS,
        }

    def verify_token(self, *, token: str) -> TokenPrincipal | None:
        if not token.startswith(_BOOTSTRAP_PREFIX):
            return None
        now = int(self._clock())
        try:
            conn = self._connect()
        except Exception as exc:
            raise ProviderError("native credential store unavailable") from exc
        try:
            try:
                row = conn.execute(
                    """
                    SELECT client_id
                      FROM native_pair_bootstraps
                     WHERE token_hash = ?
                       AND consumed_at IS NULL
                       AND expires_at >= ?
                    """,
                    (_token_hash(token), now),
                ).fetchone()
            except Exception as exc:
                raise ProviderError("native credential store unavailable") from exc
        finally:
            conn.close()
        if row is None:
            return None
        return TokenPrincipal(
            principal=str(row["client_id"]),
            provider=self.name,
            scopes=(PAIR_EXCHANGE_SCOPE,),
        )

    def consume_bootstrap(self, *, token: str, device_name: str) -> Session:
        """Atomically consume one bootstrap and mint its first token pair."""
        if not token.startswith(_BOOTSTRAP_PREFIX):
            raise BootstrapInvalid("invalid bootstrap")
        now = int(self._clock())
        access_token = _new_token(_ACCESS_PREFIX)
        refresh_token = _new_token(_REFRESH_PREFIX)
        session_id = uuid.uuid4().hex
        try:
            conn = self._connect()
        except Exception as exc:
            raise ProviderError("native credential store unavailable") from exc
        try:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute(
                """
                SELECT client_id, user_id, device_name
                  FROM native_pair_bootstraps
                 WHERE token_hash = ?
                   AND consumed_at IS NULL
                   AND expires_at >= ?
                """,
                (_token_hash(token), now),
            ).fetchone()
            if row is None:
                conn.rollback()
                raise BootstrapInvalid("invalid or expired bootstrap")
            resolved_name = _safe_device_name(device_name or row["device_name"])
            claimed = conn.execute(
                """
                UPDATE native_pair_bootstraps
                   SET consumed_at = ?, device_name = ?
                 WHERE token_hash = ? AND consumed_at IS NULL
                """,
                (now, resolved_name, _token_hash(token)),
            )
            if claimed.rowcount != 1:
                conn.rollback()
                raise BootstrapInvalid("bootstrap already consumed")
            conn.execute(
                """
                INSERT INTO native_client_sessions (
                    session_id, user_id, client_id, device_name,
                    access_hash, access_expires_at,
                    refresh_hash, refresh_expires_at,
                    created_at, updated_at, revoked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                (
                    session_id,
                    row["user_id"],
                    row["client_id"],
                    resolved_name,
                    _token_hash(access_token),
                    now + ACCESS_TTL_SECONDS,
                    _token_hash(refresh_token),
                    now + REFRESH_TTL_SECONDS,
                    now,
                    now,
                ),
            )
            conn.commit()
            return self._session(
                user_id=str(row["user_id"]),
                client_id=str(row["client_id"]),
                device_name=resolved_name,
                access_token=access_token,
                refresh_token=refresh_token,
                expires_at=now + ACCESS_TTL_SECONDS,
            )
        except BootstrapInvalid:
            raise
        except Exception as exc:
            if conn.in_transaction:
                conn.rollback()
            raise ProviderError("native credential store unavailable") from exc
        finally:
            conn.close()

    def verify_session(self, *, access_token: str) -> Session | None:
        if not access_token.startswith(_ACCESS_PREFIX):
            return None
        now = int(self._clock())
        try:
            conn = self._connect()
        except Exception as exc:
            raise ProviderError("native credential store unavailable") from exc
        try:
            try:
                row = conn.execute(
                    """
                    SELECT user_id, client_id, device_name, access_expires_at
                      FROM native_client_sessions
                     WHERE access_hash = ?
                       AND revoked_at IS NULL
                       AND access_expires_at >= ?
                       AND refresh_expires_at >= ?
                    """,
                    (_token_hash(access_token), now, now),
                ).fetchone()
            except Exception as exc:
                raise ProviderError("native credential store unavailable") from exc
        finally:
            conn.close()
        if row is None:
            return None
        return self._session(
            user_id=str(row["user_id"]),
            client_id=str(row["client_id"]),
            device_name=str(row["device_name"]),
            access_token=access_token,
            refresh_token="",
            expires_at=int(row["access_expires_at"]),
        )

    def refresh_session(self, *, refresh_token: str) -> Session:
        if not refresh_token.startswith(_REFRESH_PREFIX):
            raise RefreshExpiredError("refresh token rejected")
        now = int(self._clock())
        new_access = _new_token(_ACCESS_PREFIX)
        new_refresh = _new_token(_REFRESH_PREFIX)
        try:
            conn = self._connect()
        except Exception as exc:
            raise ProviderError("native credential store unavailable") from exc
        try:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute(
                """
                SELECT session_id, user_id, client_id, device_name
                  FROM native_client_sessions
                 WHERE refresh_hash = ?
                   AND revoked_at IS NULL
                   AND refresh_expires_at >= ?
                """,
                (_token_hash(refresh_token), now),
            ).fetchone()
            if row is None:
                conn.rollback()
                raise RefreshExpiredError("refresh token rejected")
            rotated = conn.execute(
                """
                UPDATE native_client_sessions
                   SET access_hash = ?, access_expires_at = ?,
                       refresh_hash = ?, refresh_expires_at = ?, updated_at = ?
                 WHERE session_id = ?
                   AND refresh_hash = ?
                   AND revoked_at IS NULL
                """,
                (
                    _token_hash(new_access),
                    now + ACCESS_TTL_SECONDS,
                    _token_hash(new_refresh),
                    now + REFRESH_TTL_SECONDS,
                    now,
                    row["session_id"],
                    _token_hash(refresh_token),
                ),
            )
            if rotated.rowcount != 1:
                conn.rollback()
                raise RefreshExpiredError("refresh token already rotated")
            conn.commit()
            return self._session(
                user_id=str(row["user_id"]),
                client_id=str(row["client_id"]),
                device_name=str(row["device_name"]),
                access_token=new_access,
                refresh_token=new_refresh,
                expires_at=now + ACCESS_TTL_SECONDS,
            )
        except RefreshExpiredError:
            raise
        except Exception as exc:
            if conn.in_transaction:
                conn.rollback()
            raise ProviderError("native credential store unavailable") from exc
        finally:
            conn.close()

    def revoke_session(self, *, refresh_token: str) -> None:
        if not refresh_token.startswith(_REFRESH_PREFIX):
            return
        now = int(self._clock())
        try:
            conn = self._connect()
        except Exception:
            return
        try:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute(
                """
                UPDATE native_client_sessions
                   SET revoked_at = ?, updated_at = ?
                 WHERE refresh_hash = ? AND revoked_at IS NULL
                """,
                (now, now, _token_hash(refresh_token)),
            )
            conn.commit()
        except Exception:
            if conn.in_transaction:
                conn.rollback()
        finally:
            conn.close()

    def start_login(self, *, redirect_uri: str) -> LoginStart:
        raise NotImplementedError("Hermes Mobile pairs through a one-time QR bootstrap")

    def complete_login(
        self,
        *,
        code: str,
        state: str,
        code_verifier: str,
        redirect_uri: str,
    ) -> Session:
        raise NotImplementedError("Hermes Mobile pairs through a one-time QR bootstrap")

    def _session(
        self,
        *,
        user_id: str,
        client_id: str,
        device_name: str,
        access_token: str,
        refresh_token: str,
        expires_at: int,
    ) -> Session:
        return Session(
            user_id=user_id,
            email="",
            display_name=device_name,
            org_id="",
            provider=self.name,
            expires_at=expires_at,
            access_token=access_token,
            refresh_token=refresh_token,
            client_id=client_id,
        )


PROVIDER = SQLiteNativeCredentialProvider()

"""Contracts for the thin Hermes Mobile native credential provider."""

from __future__ import annotations

import importlib.util
import importlib
import os
import sqlite3
import stat
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from hermes_cli.dashboard_auth import (
    assert_protocol_compliance,
    clear_providers,
    list_interactive_providers,
    list_session_providers,
    register_provider,
)
from hermes_cli.dashboard_auth.base import RefreshExpiredError
from hermes_cli.dashboard_auth.base import ProviderError


def _load_mobile_auth():
    name = "test_hermes_mobile_auth_provider"
    sys.modules.pop(name, None)
    path = Path(__file__).parents[2] / "plugins" / "hermes-mobile" / "mobile_auth.py"
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def auth_env(tmp_path, monkeypatch):
    home = tmp_path / ".hermes"
    monkeypatch.setenv("HERMES_HOME", str(home))
    module = _load_mobile_auth()
    yield module, home
    clear_providers()


def test_provider_protocol_and_hidden_login_surface(auth_env):
    module, _home = auth_env
    provider = module.SQLiteNativeCredentialProvider()
    assert assert_protocol_compliance(type(provider)) is None
    register_provider(provider)
    assert provider in list_session_providers()
    assert provider not in list_interactive_providers()


def test_bootstrap_is_hashed_private_short_lived_and_single_use(auth_env):
    module, home = auth_env
    now = [1_000_000.0]
    provider = module.SQLiteNativeCredentialProvider(clock=lambda: now[0])
    issued = provider.mint_bootstrap(device_name="Test Phone")
    bootstrap = str(issued["bootstrap"])

    db_path = provider.database_path(home)
    assert stat.S_IMODE(os.stat(db_path).st_mode) == 0o600
    assert bootstrap.encode() not in db_path.read_bytes()
    with sqlite3.connect(db_path) as conn:
        row = conn.execute(
            "SELECT token_hash, expires_at, consumed_at FROM native_pair_bootstraps"
        ).fetchone()
    assert row[0] == module._token_hash(bootstrap)
    assert row[1] - int(now[0]) == module.BOOTSTRAP_TTL_SECONDS
    assert row[2] is None

    principal = provider.verify_token(token=bootstrap)
    assert principal is not None
    assert module.PAIR_EXCHANGE_SCOPE in principal.scopes
    session = provider.consume_bootstrap(token=bootstrap, device_name="Test Phone")
    assert session.client_id == issued["client_id"]
    assert provider.verify_token(token=bootstrap) is None
    with pytest.raises(module.BootstrapInvalid):
        provider.consume_bootstrap(token=bootstrap, device_name="Replay")


def test_concurrent_bootstrap_exchange_has_one_winner(auth_env):
    module, _home = auth_env
    provider = module.SQLiteNativeCredentialProvider()
    bootstrap = str(provider.mint_bootstrap()["bootstrap"])

    def consume():
        try:
            return provider.consume_bootstrap(token=bootstrap, device_name="Phone")
        except module.BootstrapInvalid:
            return None

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _index: consume(), range(2)))
    assert sum(result is not None for result in results) == 1


def test_refresh_rotates_atomically_and_revocation_kills_both_tokens(auth_env):
    module, _home = auth_env
    provider = module.SQLiteNativeCredentialProvider()
    bootstrap = str(provider.mint_bootstrap()["bootstrap"])
    first = provider.consume_bootstrap(token=bootstrap, device_name="Phone")
    assert provider.verify_session(access_token=first.access_token) is not None

    second = provider.refresh_session(refresh_token=first.refresh_token)
    assert second.client_id == first.client_id
    assert second.access_token != first.access_token
    assert second.refresh_token != first.refresh_token
    assert provider.verify_session(access_token=first.access_token) is None
    with pytest.raises(RefreshExpiredError):
        provider.refresh_session(refresh_token=first.refresh_token)

    provider.revoke_session(refresh_token=second.refresh_token)
    assert provider.verify_session(access_token=second.access_token) is None
    with pytest.raises(RefreshExpiredError):
        provider.refresh_session(refresh_token=second.refresh_token)


def test_expired_bootstrap_and_refresh_fail_closed(auth_env):
    module, _home = auth_env
    now = [1_000_000.0]
    provider = module.SQLiteNativeCredentialProvider(clock=lambda: now[0])
    bootstrap = str(provider.mint_bootstrap()["bootstrap"])
    now[0] += module.BOOTSTRAP_TTL_SECONDS + 1
    assert provider.verify_token(token=bootstrap) is None
    with pytest.raises(module.BootstrapInvalid):
        provider.consume_bootstrap(token=bootstrap, device_name="Phone")

    fresh = str(provider.mint_bootstrap()["bootstrap"])
    session = provider.consume_bootstrap(token=fresh, device_name="Phone")
    now[0] += module.REFRESH_TTL_SECONDS + 1
    with pytest.raises(RefreshExpiredError):
        provider.refresh_session(refresh_token=session.refresh_token)


def test_store_outage_uses_stock_provider_unavailable_semantics(auth_env, monkeypatch):
    module, _home = auth_env
    provider = module.SQLiteNativeCredentialProvider()
    monkeypatch.setattr(
        provider,
        "_connect",
        lambda: (_ for _ in ()).throw(sqlite3.OperationalError("disk offline")),
    )
    with pytest.raises(ProviderError):
        provider.verify_token(token="hmb_opaque")
    with pytest.raises(ProviderError):
        provider.verify_session(access_token="hma_opaque")
    with pytest.raises(ProviderError):
        provider.refresh_session(refresh_token="hmr_opaque")
    with pytest.raises(ProviderError):
        provider.consume_bootstrap(token="hmb_opaque", device_name="Phone")


def test_pairing_cli_refuses_cleartext_public_url(auth_env):
    _module, _home = auth_env
    from hermes_cli import web_server  # noqa: F401 — mounts the bundled API package

    api_module = sys.modules["hermes_dashboard_plugin_hermes-mobile"]
    api_module._mobile_auth()
    pair = importlib.import_module("hermes_plugins.hermes_mobile.mobile_pair")
    assert pair._resolve_public_url("http://gateway.example.test") == ""
    assert (
        pair._resolve_public_url("https://gateway.example.test/hermes/")
        == "https://gateway.example.test/hermes"
    )


def test_pair_exchange_uses_stock_bearer_refresh_and_ws_ticket(auth_env):
    _module, _home = auth_env
    from hermes_cli import web_server
    from hermes_cli.dashboard_auth.ws_tickets import consume_ticket

    api_module = sys.modules.get("hermes_dashboard_plugin_hermes-mobile")
    assert api_module is not None
    auth = api_module._mobile_auth()
    clear_providers()
    register_provider(auth.PROVIDER)

    previous_required = getattr(web_server.app.state, "auth_required", False)
    previous_host = getattr(web_server.app.state, "bound_host", None)
    previous_port = getattr(web_server.app.state, "bound_port", None)
    web_server.app.state.auth_required = True
    web_server.app.state.bound_host = "gateway.example.test"
    web_server.app.state.bound_port = 443
    try:
        bootstrap = str(auth.PROVIDER.mint_bootstrap()["bootstrap"])
        client = TestClient(web_server.app, base_url="https://gateway.example.test")
        providers = client.get("/api/auth/providers")
        assert providers.status_code == 503
        hidden_login = client.get(
            "/auth/login",
            params={"provider": auth.PROVIDER.name},
            follow_redirects=False,
        )
        assert hidden_login.status_code == 404
        exchange = client.post(
            auth.PAIR_EXCHANGE_PATH,
            headers={"Authorization": f"Bearer {bootstrap}"},
            json={"device_name": "Abhi's iPhone"},
        )
        assert exchange.status_code == 200, exchange.text
        assert exchange.headers["cache-control"] == "no-store"
        bundle = exchange.json()
        assert bundle["client_id"].startswith("ios:")
        assert bundle["provider"] == auth.PROVIDER.name

        replay = client.post(
            auth.PAIR_EXCHANGE_PATH,
            headers={"Authorization": f"Bearer {bootstrap}"},
            json={"device_name": "Replay"},
        )
        assert replay.status_code == 401

        bearer = {"Authorization": f"Bearer {bundle['access_token']}"}
        me = client.get("/api/auth/me", headers=bearer)
        assert me.status_code == 200, me.text
        ticket_response = client.post("/api/auth/ws-ticket", headers=bearer)
        assert ticket_response.status_code == 200, ticket_response.text
        ticket_identity = consume_ticket(ticket_response.json()["ticket"])
        assert ticket_identity["client_id"] == bundle["client_id"]

        rotated = client.post(
            "/auth/native/refresh",
            json={
                "refresh_token": bundle["refresh_token"],
                "provider": bundle["provider"],
            },
        )
        assert rotated.status_code == 200, rotated.text
        rotated_bundle = rotated.json()
        assert rotated_bundle["refresh_token"] != bundle["refresh_token"]
        assert client.get("/api/auth/me", headers=bearer).status_code == 401
        assert client.get(
            "/api/auth/me",
            headers={"Authorization": f"Bearer {rotated_bundle['access_token']}"},
        ).status_code == 200
    finally:
        clear_providers()
        web_server.app.state.auth_required = previous_required
        web_server.app.state.bound_host = previous_host
        web_server.app.state.bound_port = previous_port

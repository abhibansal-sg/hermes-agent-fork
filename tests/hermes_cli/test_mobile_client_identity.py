from types import SimpleNamespace
from hermes_cli.dashboard_auth.ws_tickets import mint_ticket, consume_ticket
from tui_gateway import server


def test_client_identity_survives_ticket_and_namespaces_action_owner():
    ticket = mint_ticket(user_id="user-a", provider="test", client_id="device-a")
    identity = consume_ticket(ticket)
    assert identity["client_id"] == "device-a"
    assert server._request_principal(SimpleNamespace(auth_identity=identity)).key == "test:user-a/device-a"
    identity["user_id"] = "user-b"
    assert server._request_principal(SimpleNamespace(auth_identity=identity)).key == "test:user-b/device-a"


def test_legacy_ticket_keeps_user_scoped_identity():
    identity = consume_ticket(mint_ticket(user_id="user-a", provider="test"))
    assert "client_id" not in identity
    assert server._request_principal(SimpleNamespace(auth_identity=identity)).key == "test:user-a"

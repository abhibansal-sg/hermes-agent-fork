"""Operator CLI for one-time Hermes Mobile pairing bootstraps."""

from __future__ import annotations

import time
from urllib.parse import urlencode, urlparse

from .mobile_auth import PROVIDER


def setup_parser(parser) -> None:
    parser.description = (
        "Mint a short-lived, one-use pairing bootstrap and print a QR code. "
        "The phone exchanges it for standard Hermes native-session tokens."
    )
    parser.add_argument(
        "--url",
        default="",
        help="Public HTTPS URL of the gated Hermes dashboard/serve endpoint",
    )
    parser.add_argument(
        "--device-name",
        default="iPhone",
        help="Initial display label for the paired client",
    )


def _resolve_public_url(explicit: str) -> str:
    value = explicit.strip()
    if not value:
        from hermes_cli.dashboard_auth.prefix import resolve_public_url

        value = (resolve_public_url() or "").strip()
    value = value.rstrip("/")
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname:
        return ""
    if parsed.query or parsed.fragment:
        return ""
    return value


def _render_qr(payload: str) -> str | None:
    try:
        import qrcode
    except ImportError:
        return None
    qr = qrcode.QRCode(border=2)
    qr.add_data(payload)
    qr.make(fit=True)
    rows = qr.get_matrix()
    black = "██"
    white = "  "
    return "\n".join("".join(black if cell else white for cell in row) for row in rows)


def command(args) -> int:
    public_url = _resolve_public_url(getattr(args, "url", ""))
    if not public_url:
        print(
            "Could not determine a public HTTPS Hermes URL. Pass --url "
            "https://… or configure dashboard.public_url. Pairing credentials "
            "are never sent over cleartext HTTP."
        )
        return 2
    issued = PROVIDER.mint_bootstrap(device_name=getattr(args, "device_name", "iPhone"))
    deep_link = "hermesapp://pair?" + urlencode(
        {
            "kind": "provider",
            "url": public_url,
            "bootstrap": issued["bootstrap"],
        }
    )
    print("\nPair Hermes Mobile")
    print(f"Server: {public_url}")
    remaining_minutes = max(
        1, int((int(issued["expires_at"]) - time.time()) / 60) + 1
    )
    print(f"Expires in: {remaining_minutes} minutes\n")
    qr = _render_qr(deep_link)
    if qr:
        print(qr)
        print()
    print(deep_link)
    print("\nThis bootstrap is single-use. Do not share or save this screen.")
    return 0

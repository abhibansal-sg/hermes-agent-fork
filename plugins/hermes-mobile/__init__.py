"""Thin native-client providers; no transcript, file, or workflow authority."""

from __future__ import annotations

from tui_gateway.prompt_admission import register_prompt_receipt_provider

from .mobile_auth import PAIR_EXCHANGE_PATH, PROVIDER as AUTH_PROVIDER
from .prompt_receipts import PROVIDER


def register(ctx) -> None:
    register_prompt_receipt_provider(PROVIDER)
    ctx.register_dashboard_auth_provider(AUTH_PROVIDER)
    from hermes_cli.dashboard_auth.token_auth import register_token_route

    register_token_route(PAIR_EXCHANGE_PATH)
    from .mobile_pair import command, setup_parser

    ctx.register_cli_command(
        name="mobile-pair",
        help="Pair the Hermes Mobile iOS app via a one-time QR code",
        setup_fn=setup_parser,
        handler_fn=command,
        description=(
            "Mint a short-lived one-use bootstrap that the iOS app exchanges "
            "for stock Hermes native-session credentials."
        ),
    )

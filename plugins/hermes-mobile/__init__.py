"""Thin native-client providers; no transcript, file, or workflow authority."""

from __future__ import annotations

from tui_gateway.prompt_admission import register_prompt_receipt_provider

from .prompt_receipts import PROVIDER


def register(_ctx) -> None:
    register_prompt_receipt_provider(PROVIDER)

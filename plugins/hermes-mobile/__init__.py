"""Durable prompt receipts for native clients; Hermes owns everything else."""

from __future__ import annotations

from tui_gateway.prompt_admission import register_prompt_receipt_provider

from .prompt_receipts import PROVIDER


def register(ctx) -> None:
    _ = ctx
    register_prompt_receipt_provider(PROVIDER)

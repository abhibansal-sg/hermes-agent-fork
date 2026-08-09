"""Thin one-time pairing exchange for the Hermes Mobile auth provider."""

from __future__ import annotations

import asyncio
import importlib
import importlib.util
import sys
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from pydantic import Field

from hermes_cli.dashboard_auth.token_auth import (
    extract_bearer_token,
    register_token_route,
)

_PLUGIN_DIR = Path(__file__).resolve().parent.parent
_PLUGIN_PKG = "hermes_plugins.hermes_mobile"


def _mobile_auth():
    if _PLUGIN_PKG not in sys.modules:
        if "hermes_plugins" not in sys.modules:
            import types

            namespace = types.ModuleType("hermes_plugins")
            namespace.__path__ = []  # type: ignore[attr-defined]
            namespace.__package__ = "hermes_plugins"
            sys.modules["hermes_plugins"] = namespace
        spec = importlib.util.spec_from_file_location(
            _PLUGIN_PKG,
            _PLUGIN_DIR / "__init__.py",
            submodule_search_locations=[str(_PLUGIN_DIR)],
        )
        if spec is None or spec.loader is None:
            raise ImportError("cannot load hermes-mobile plugin package")
        module = importlib.util.module_from_spec(spec)
        module.__path__ = [str(_PLUGIN_DIR)]  # type: ignore[attr-defined]
        sys.modules[_PLUGIN_PKG] = module
        spec.loader.exec_module(module)
    return importlib.import_module(f"{_PLUGIN_PKG}.mobile_auth")


router = APIRouter()
_ROUTE = "/api/plugins/hermes-mobile/pair/exchange"
register_token_route(_ROUTE)


class PairExchangeBody(BaseModel):
    device_name: str = Field(default="iPhone", max_length=128)


@router.post("/pair/exchange")
async def exchange_pairing_bootstrap(request: Request, body: PairExchangeBody):
    principal = getattr(request.state, "token_principal", None)
    auth = _mobile_auth()
    if (
        principal is None
        or principal.provider != auth.PROVIDER.name
        or auth.PAIR_EXCHANGE_SCOPE not in principal.scopes
    ):
        raise HTTPException(status_code=403, detail="Pairing bootstrap not authorized")
    token = extract_bearer_token(request)
    try:
        session = await asyncio.to_thread(
            auth.PROVIDER.consume_bootstrap,
            token=token,
            device_name=body.device_name,
        )
    except auth.BootstrapInvalid:
        raise HTTPException(status_code=409, detail="Pairing bootstrap already used or expired")
    except auth.ProviderError:
        raise HTTPException(status_code=503, detail="Native credential store unavailable")
    return JSONResponse(
        {
            "access_token": session.access_token,
            "refresh_token": session.refresh_token,
            "token_type": "Bearer",
            "expires_at": session.expires_at,
            "provider": session.provider,
            "user_id": session.user_id,
            "client_id": session.client_id,
        },
        headers={"Cache-Control": "no-store"},
    )

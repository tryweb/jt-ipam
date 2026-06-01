"""OUI vendor 管理 endpoint。"""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import CurrentUser, require_admin
from app.core.db import get_session
from app.services.oui import refresh_oui_db, vendor_for_mac
from app.services.oui import stats as oui_stats

router = APIRouter(prefix="/oui", tags=["oui"])


@router.get("/stats")
async def get_stats(
    _user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> dict[str, Any]:
    return await oui_stats(session)


@router.post("/refresh", dependencies=[Depends(require_admin)])
async def refresh(
    _user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> dict[str, Any]:
    return await refresh_oui_db(session)


@router.get("/lookup")
async def lookup(
    _user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_session)],
    mac: Annotated[str, Query(min_length=6, max_length=64)],
) -> dict[str, str | None]:
    return {"mac": mac, "vendor": await vendor_for_mac(session, mac)}

"""LDAP / AD 認證 — 管理區設定（DB 覆蓋 env）。

  GET  /api/v1/system/ldap        → 目前設定（不含明文密碼，只回 password_set 旗標）
  PUT  /api/v1/system/ldap        → 寫入設定（bind_password 留空＝不變、給空字串＝清除）
  POST /api/v1/system/ldap/test   → 以目前設定（或本次送出的設定）試連 LDAP
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import CurrentUser, require_admin
from app.core.audit import append_audit
from app.core.db import get_session
from app.models.system_setting import SystemSetting
from app.schemas.base import StrictModel
from app.services import ldap_auth
from app.services.system_config import (
    LDAP_KEY,
    get_ldap_config,
    set_ldap_config,
)

admin_router = APIRouter(
    prefix="/system", tags=["system"], dependencies=[Depends(require_admin)]
)


class LdapOut(StrictModel):
    enabled: bool
    server: str | None
    port: int
    use_ssl: bool
    use_starttls: bool
    bind_dn: str | None
    password_set: bool
    search_base: str | None
    user_filter: str
    attr_email: str
    attr_display_name: str
    attr_member_of: str
    admin_groups: list[str]


class LdapPatch(StrictModel):
    enabled: bool = False
    server: Annotated[str | None, None] = None
    port: int = 389
    use_ssl: bool = False
    use_starttls: bool = True
    bind_dn: str | None = None
    bind_password: str | None = None   # None＝不變、""＝清除、其他＝更新
    search_base: str | None = None
    user_filter: str = "(sAMAccountName={username})"
    attr_email: str = "mail"
    attr_display_name: str = "displayName"
    attr_member_of: str = "memberOf"
    admin_groups: list[str] = []


async def _password_set(session: AsyncSession) -> bool:
    row = await session.get(SystemSetting, LDAP_KEY)
    return bool(row and isinstance(row.value, dict) and row.value.get("bind_password_enc"))


async def _as_out(session: AsyncSession) -> dict:  # type: ignore[type-arg]
    cfg = await get_ldap_config(session)
    return {
        "enabled": cfg.enabled, "server": cfg.server, "port": cfg.port,
        "use_ssl": cfg.use_ssl, "use_starttls": cfg.use_starttls, "bind_dn": cfg.bind_dn,
        "password_set": (await _password_set(session)) or bool(cfg.bind_password),
        "search_base": cfg.search_base, "user_filter": cfg.user_filter,
        "attr_email": cfg.attr_email, "attr_display_name": cfg.attr_display_name,
        "attr_member_of": cfg.attr_member_of, "admin_groups": cfg.admin_groups,
    }


@admin_router.get("/ldap", response_model=LdapOut)
async def get_ldap(
    _user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> dict:  # type: ignore[type-arg]
    return await _as_out(session)


@admin_router.put("/ldap", response_model=LdapOut)
async def put_ldap(
    payload: LdapPatch, user: CurrentUser, request: Request,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> dict:  # type: ignore[type-arg]
    data = payload.model_dump()
    if payload.bind_password is None:   # 不變更密碼
        data.pop("bind_password", None)
    await set_ldap_config(session, data=data, updated_by_user_id=uuid.UUID(str(user.id)))
    await append_audit(
        session, actor_user_id=str(user.id),
        actor_ip=request.client.host if request.client else None,
        actor_user_agent=request.headers.get("user-agent"),
        object_type="system_setting", object_id=None, action="update",
        diff={"setting": "ldap", "enabled": payload.enabled, "server": payload.server,
              "bind_dn": payload.bind_dn},
        request_id=getattr(request.state, "request_id", None),
    )
    await session.commit()
    return await _as_out(session)


@admin_router.post("/ldap/test")
async def ldap_test_conn(
    _user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> dict[str, object]:
    cfg = await get_ldap_config(session)
    try:
        return await ldap_auth.test_connection(cfg)
    except ldap_auth.LDAPNotConfigured as exc:
        raise HTTPException(503, detail=str(exc)) from exc
    except ldap_auth.LDAPAuthError as exc:
        raise HTTPException(502, detail=f"LDAP error: {exc}") from exc

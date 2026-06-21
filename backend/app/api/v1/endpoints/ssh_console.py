"""IP 位址 SSH 連線管理：ticket 換發 + WebSocket↔SSH 橋接（xterm.js 前端）。

安全設計（OWASP）：
- A01：ticket 與 WS 兩處都重查 `can_use_ssh`（deny-by-default）；看不到的 IP 不能連。
- A07/A09：ticket 單次用 + 60s TTL + 綁 user×ip；發放限流；session 開/關都寫稽核。
- 憑證（密碼/私鑰）只在連線過程存記憶體，用完即丟，**絕不寫 DB / 不記錄**。
- 目標主機固定為該 IP 記錄上的位址（不接受使用者指定 host）→ 防被當成通用 SSH/SSRF proxy。
- A02：host key 採 TOFU 信任後釘選（存 ip.ssh_host_key）；日後不符即警告 MITM。

WS 無法帶 Authorization header → 改用「先以 JWT 打 POST .../ssh/ticket 換 ticket，
再用 ?ticket= 開 WS」。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import secrets
import uuid
from datetime import UTC, datetime
from typing import Annotated, Any

import asyncssh
from fastapi import APIRouter, Depends, HTTPException, Request, WebSocket, WebSocketDisconnect
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import CurrentUser
from app.core.audit import append_audit
from app.core.db import SessionLocal, get_session
from app.core.rate_limit import _redis_client
from app.models.address import IPAddress
from app.models.user import User
from app.services.permission import can_use_ssh
from app.services.ssh_tunnel import (
    SSHHostKeyMismatch,
    _parse_pubkey_line,
    fetch_host_key,
    server_key_fingerprint_sha256,
)

router = APIRouter(prefix="/addresses", tags=["ssh"])

_TICKET_TTL = 60          # 秒；ticket 單次用、短壽
_CONNECT_TIMEOUT = 15.0   # SSH 連線逾時
_READ_CHUNK = 4096


def _ticket_key(ticket: str) -> str:
    return f"ssh:tk:{ticket}"


@router.post("/{address_id}/ssh/ticket")
async def issue_ssh_ticket(
    address_id: uuid.UUID,
    user: CurrentUser,
    request: Request,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> dict[str, Any]:
    """換發短期一次性 ticket；之後用它開 WebSocket。"""
    from app.core.rate_limit import limit_per_ip

    await limit_per_ip(request, name="ssh")

    ip = await session.get(IPAddress, address_id)
    if ip is None:
        raise HTTPException(status_code=404, detail="Address not found")
    if not await can_use_ssh(session, user=user, ip=ip):
        # A01：不洩漏存在性差異 — 一律 403
        raise HTTPException(status_code=403, detail="無 SSH 連線權限")

    ticket = secrets.token_urlsafe(32)
    payload = json.dumps({"user_id": str(user.id), "ip_id": str(ip.id)})
    await _redis_client().set(_ticket_key(ticket), payload, ex=_TICKET_TTL)

    return {
        "ticket": ticket,
        "ws_path": f"/api/v1/addresses/{ip.id}/ssh/ws",
        "host_key_pinned": bool(ip.ssh_host_key),
        "default_port": 22,
        "ttl": _TICKET_TTL,
    }


async def _redeem_ticket(ticket: str, address_id: uuid.UUID) -> uuid.UUID | None:
    """單次取出 ticket（getdel）；回傳通過驗證的 user_id，否則 None。"""
    if not ticket:
        return None
    raw = await _redis_client().getdel(_ticket_key(ticket))
    if not raw:
        return None
    try:
        data = json.loads(raw)
        if data.get("ip_id") != str(address_id):
            return None
        return uuid.UUID(data["user_id"])
    except (ValueError, KeyError, TypeError):
        return None


async def _audit_ssh(
    *, actor_user_id: str, actor_ip: str | None, object_id: str,
    action: str, diff: dict[str, Any],
) -> None:
    """以獨立短交易寫一筆 SSH 稽核（不含任何憑證）。"""
    async with SessionLocal() as s:
        await append_audit(
            s,
            actor_user_id=actor_user_id,
            actor_ip=actor_ip,
            actor_user_agent=None,
            object_type="ip",
            object_id=object_id,
            action=action,
            diff=diff,
            request_id=None,
        )
        await s.commit()


async def _pin_host_key(address_id: uuid.UUID, known_host: str, *, actor_user_id: str, actor_ip: str | None) -> None:
    async with SessionLocal() as s:
        ip = await s.get(IPAddress, address_id)
        if ip is not None:
            ip.ssh_host_key = known_host
            await append_audit(
                s,
                actor_user_id=actor_user_id,
                actor_ip=actor_ip,
                actor_user_agent=None,
                object_type="ip",
                object_id=str(address_id),
                action="ssh.hostkey_pin",
                diff={"fingerprint": server_key_fingerprint_sha256(_parse_pubkey_line(known_host))},
                request_id=None,
            )
            await s.commit()


def _strict_client_factory(known_host: str) -> type[asyncssh.SSHClient]:
    """回傳一個會嚴格比對釘選 host key 的 SSHClient（不符 → SSHHostKeyMismatch）。"""
    expected_fp = server_key_fingerprint_sha256(_parse_pubkey_line(known_host))

    class _StrictClient(asyncssh.SSHClient):
        def validate_host_public_key(self, host, addr, port, key):  # type: ignore[no-untyped-def]
            actual = key.export_public_key("openssh").decode("ascii").split()
            actual_fp = server_key_fingerprint_sha256(_parse_pubkey_line(f"{actual[0]} {actual[1]}"))
            if actual_fp != expected_fp:
                raise SSHHostKeyMismatch(expected_fp, actual_fp)
            return True

    return _StrictClient


@router.websocket("/{address_id}/ssh/ws")
async def ssh_ws(websocket: WebSocket, address_id: uuid.UUID, ticket: str = "") -> None:
    # 1) 驗 ticket（單次取出）
    user_id = await _redeem_ticket(ticket, address_id)
    if user_id is None:
        await websocket.close(code=4401)
        return

    # 2) 載入 user + ip，縱深重查權限
    async with SessionLocal() as s:
        user = await s.get(User, user_id)
        ip = await s.get(IPAddress, address_id)
        if user is None or not user.is_active or ip is None:
            await websocket.close(code=4403)
            return
        allowed = await can_use_ssh(s, user=user, ip=ip)
        host = str(ip.ip).split("/")[0]
        pinned = ip.ssh_host_key
    if not allowed:
        await websocket.close(code=4403)
        return

    await websocket.accept()
    actor_ip = websocket.client.host if websocket.client else None

    async def send(obj: dict[str, Any]) -> None:
        await websocket.send_text(json.dumps(obj))

    try:
        # 3) 收第一個設定訊息
        cfg = json.loads(await websocket.receive_text())
        if cfg.get("type") != "config":
            await send({"type": "error", "code": "bad_config", "message": "缺少連線設定"})
            await websocket.close()
            return
        username = (cfg.get("username") or "").strip()
        port = int(cfg.get("port") or 22)
        auth = cfg.get("auth")
        cols = int(cfg.get("cols") or 80)
        rows = int(cfg.get("rows") or 24)
        if not username:
            await send({"type": "error", "code": "bad_config", "message": "帳號必填"})
            await websocket.close()
            return
        if not (1 <= port <= 65535):
            await send({"type": "error", "code": "bad_config", "message": "連接埠須為 1–65535"})
            await websocket.close()
            return

        # 4) 認證憑證（記憶體用完即丟）
        connect_kw: dict[str, Any] = {}
        if auth == "password":
            connect_kw["password"] = cfg.get("password") or ""
        elif auth == "key":
            try:
                connect_kw["client_keys"] = [
                    asyncssh.import_private_key(
                        cfg.get("private_key") or "", passphrase=cfg.get("passphrase") or None
                    )
                ]
            except Exception:  # 私鑰格式 / passphrase 錯
                await send({"type": "error", "code": "bad_key", "message": "私鑰無法解析（格式或 passphrase 錯誤）"})
                await websocket.close()
                return
            connect_kw["preferred_auth"] = ("publickey",)
        else:
            await send({"type": "error", "code": "bad_config", "message": "不支援的認證方式"})
            await websocket.close()
            return

        # 5) host key — TOFU：未釘選先取指紋給使用者確認再釘選
        known_host = pinned
        if not known_host:
            try:
                hk = await fetch_host_key(host, port=port)
            except Exception as exc:
                await send({"type": "error", "code": "connect_failed", "message": f"無法連線取得主機金鑰：{exc}"})
                await websocket.close()
                return
            await send({"type": "hostkey", "fingerprint": hk["fingerprint"]})
            ans = json.loads(await websocket.receive_text())
            if ans.get("type") != "hostkey_accept":
                await send({"type": "error", "code": "hostkey_rejected", "message": "已取消（未信任主機金鑰）"})
                await websocket.close()
                return
            known_host = hk["known_host"]
            await _pin_host_key(address_id, known_host, actor_user_id=str(user_id), actor_ip=actor_ip)

        # 6) 連線（嚴格比對已釘選的 host key）
        await send({"type": "status", "state": "connecting"})
        try:
            async with asyncio.timeout(_CONNECT_TIMEOUT):
                conn = await asyncssh.connect(
                    host,
                    port=port,
                    username=username,
                    client_factory=_strict_client_factory(known_host),
                    known_hosts=None,
                    agent_path=None,
                    **connect_kw,
                )
        except SSHHostKeyMismatch:
            await send({"type": "error", "code": "hostkey_mismatch",
                        "message": "主機金鑰與先前釘選不符，可能遭中間人攻擊（連線中止）"})
            await websocket.close()
            return
        except asyncssh.PermissionDenied:
            await send({"type": "error", "code": "auth_failed", "message": "認證失敗（帳號 / 密碼 / 金鑰錯誤）"})
            await websocket.close()
            return
        except (TimeoutError, asyncssh.Error, OSError) as exc:
            await send({"type": "error", "code": "connect_failed", "message": f"連線失敗：{exc}"})
            await websocket.close()
            return

        # 7) 開互動 shell + 雙向橋接
        started = datetime.now(UTC)
        await _audit_ssh(
            actor_user_id=str(user_id), actor_ip=actor_ip, object_id=str(address_id),
            action="ssh.session_open",
            diff={"host": host, "port": port, "username": username, "auth": auth},
        )
        async with conn:
            await send({"type": "status", "state": "connected"})
            async with conn.create_process(
                term_type="xterm-256color", term_size=(cols, rows),
                encoding="utf-8", errors="replace",
            ) as proc:
                await _bridge(websocket, proc, send)

        dur = (datetime.now(UTC) - started).total_seconds()
        await _audit_ssh(
            actor_user_id=str(user_id), actor_ip=actor_ip, object_id=str(address_id),
            action="ssh.session_close", diff={"host": host, "duration_seconds": round(dur, 1)},
        )
        with contextlib.suppress(Exception):
            await send({"type": "status", "state": "disconnected"})
            await websocket.close()

    except WebSocketDisconnect:
        return
    except Exception:  # 任何未預期錯誤都不可洩漏堆疊給前端
        with contextlib.suppress(Exception):
            await send({"type": "error", "code": "internal", "message": "連線發生未預期錯誤"})
            await websocket.close()


async def _bridge(websocket: WebSocket, proc: Any, send: Any) -> None:
    """雙向 pump：proc.stdout→ws、ws→proc.stdin / resize。任一端結束即收掉另一端。"""

    async def pump_out() -> None:
        # shell 輸出 → ws；任一端斷線/EOF 即結束（吞例外，避免未取回的 task 例外噪音）
        with contextlib.suppress(Exception):
            while True:
                data = await proc.stdout.read(_READ_CHUNK)
                if not data:
                    break
                await send({"type": "data", "data": data})

    async def pump_in() -> None:
        with contextlib.suppress(WebSocketDisconnect, Exception):
            while True:
                msg = json.loads(await websocket.receive_text())
                t = msg.get("type")
                if t == "data":
                    proc.stdin.write(msg.get("data", ""))
                elif t == "resize":
                    proc.change_terminal_size(int(msg.get("cols", 80)), int(msg.get("rows", 24)))
                elif t == "close":
                    break

    out_task = asyncio.create_task(pump_out())
    in_task = asyncio.create_task(pump_in())
    _done, pending = await asyncio.wait({out_task, in_task}, return_when=asyncio.FIRST_COMPLETED)
    for p in pending:
        p.cancel()
    await asyncio.gather(*pending, return_exceptions=True)

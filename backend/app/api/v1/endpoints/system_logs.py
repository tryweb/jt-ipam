"""系統記錄查詢（管理員）：讀 jt-ipam 各服務的紀錄。

支援兩種後端，依執行環境自動切換：
1. systemd 主機 — 透過 journalctl 讀取 systemd unit 紀錄。
2. Docker 容器 — 透過 Docker Engine API（Unix socket /var/run/docker.sock）
   讀取 Docker Compose 服務的 stdout/stderr。需掛載 socket 至容器。

OWASP：
- 僅管理員（require_admin）。
- service 走白名單；lines 為整數夾限。
- subprocess 以 list 參數呼叫（不經 shell，無注入）。
- 僅回讀，不做任何控制（start/stop/restart 不開放）。
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import socket
from typing import Annotated

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query

from app.api.v1.dependencies import require_admin

router = APIRouter(prefix="/system/logs", tags=["system-logs"],
                   dependencies=[Depends(require_admin)])

# 可查的服務白名單（label → systemd unit）
SERVICES: dict[str, str] = {
    "backend": "jt-ipam-backend",
    "sync": "jt-ipam-sync",
    "scan-agent": "jt-ipam-scan-agent",
    "oui-refresh": "jt-ipam-oui-refresh",
    "geoip-refresh": "jt-ipam-geoip-refresh",
    "backup": "jt-ipam-backup",
}

# Docker Compose 服務名稱（與 docker-compose.yml 對應）
# 背景任務（sync, scan-agent, …）與 API server 都在同一個 backend 容器內執行。
_DOCKER_SERVICES: dict[str, str] = {
    "backend": "backend",
    "sync": "backend",
    "scan-agent": "backend",
    "oui-refresh": "backend",
    "geoip-refresh": "backend",
    "backup": "backend",
}

_DOCKER_SOCKET = "/var/run/docker.sock"

# Docker 模式 regex 過濾：依服務 log 特徵抽取對應行
# None = 回全部（不過濾）
_LOG_FILTERS: dict[str, re.Pattern[str] | None] = {
    "backend":     None,
    "sync":        re.compile(r"jt-ipam-sync"),
    "scan-agent":  None,  # 特殊處理：不寫 container log
    "oui-refresh": re.compile(r"app\.services\.oui"),
    "geoip-refresh": re.compile(r"\[geoip_refresh\]"),
    "backup":      None,  # 特殊處理：Docker 內不執行
}


def _in_docker() -> bool:
    return os.path.exists("/.dockerenv") or os.environ.get("BACKEND_TLS_MODE") == "docker-compose"


async def _docker_logs(service_label: str, lines: int) -> str:
    if not os.path.exists(_DOCKER_SOCKET):
        raise HTTPException(
            status_code=503,
            detail=(
                "Docker socket not mounted. "
                f"Add '{_DOCKER_SOCKET}:/var/run/docker.sock:ro' to the backend "
                "volumes in docker-compose.yml."
            ),
        )

    if service_label == "backup":
        return (
            "# Docker 模式：備份在 container 外執行。\n"
            "# 在主機上執行：docker compose exec postgres pg_dump -U jt_ipam jt_ipam > backup.dump"
        )
    if service_label == "scan-agent":
        return "# Scan agent 日誌產生於遠端主機，不寫入此 container。\n# 請查看 agent 主機上的 syslog / systemd journal。"

    dc_svc = _DOCKER_SERVICES.get(service_label, "backend")
    transport = httpx.AsyncHTTPTransport(uds=_DOCKER_SOCKET)
    timeout = httpx.Timeout(15.0, connect=3.0)

    async with httpx.AsyncClient(transport=transport, timeout=timeout) as client:
        # 查出自己的 project name（避免跨 Compose project 汙染）
        our_hostname = socket.gethostname()
        our_name = None
        try:
            resp = await client.get(f"http://localhost/containers/{our_hostname}/json")
            resp.raise_for_status()
            labels = resp.json()["Config"]["Labels"]
            project = labels.get("com.docker.compose.project")
            our_name = labels.get("com.docker.compose.service")
        except Exception:
            project = None

        # 依 Docker Compose project + service label 找出目標容器
        label_filters = [f"com.docker.compose.service={dc_svc}"]
        if project:
            label_filters.insert(0, f"com.docker.compose.project={project}")
        filters = json.dumps({"label": label_filters})
        resp = await client.get(
            "http://localhost/containers/json",
            params={"filters": filters, "all": "false"},
        )
        resp.raise_for_status()
        containers = resp.json()
        if not containers:
            detail = f"# Container for service '{dc_svc}' not found"
            if project:
                detail += f" in project '{project}'"
            return detail + ".\n# Ensure Docker Compose is up."

        # 優先選同 service name 的容器（如有 label 可對應）
        if our_name and dc_svc == our_name:
            same_svc = [c for c in containers
                        if c.get("Labels", {}).get("com.docker.compose.service") == our_name]
            if same_svc:
                containers = same_svc
        cid = containers[0]["Id"]

        # 取 log（Docker multiplexed stream: 8-byte header + payload per frame）
        resp = await client.get(
            f"http://localhost/containers/{cid}/logs",
            params={
                "stdout": "true",
                "stderr": "true",
                "tail": lines,
                "timestamps": "true",
            },
        )
        raw = resp.content

    # 拆 frame header（stream-type 1B + pad 3B + length 4B big-endian）
    out_parts: list[str] = []
    offset = 0
    while offset + 8 <= len(raw):
        frame_len = int.from_bytes(raw[offset + 4: offset + 8], "big")
        offset += 8
        payload = raw[offset: offset + frame_len]
        out_parts.append(payload.decode("utf-8", errors="replace"))
        offset += frame_len
    text = "".join(out_parts)

    # Docker 模式：依服務特徵過濾 log 行
    pattern = _LOG_FILTERS.get(service_label)
    if pattern is not None:
        filtered = [ln for ln in text.split("\n") if pattern.search(ln)]
        return "\n".join(filtered[-lines:])

    return text


@router.get("/services")
async def list_services() -> dict[str, list[str]]:
    return {"services": list(SERVICES.keys())}


@router.get("")
async def read_logs(
    service: Annotated[str, Query()] = "backend",
    lines: Annotated[int, Query(ge=10, le=5000)] = 300,
) -> dict[str, object]:
    unit = SERVICES.get(service)
    if unit is None:
        raise HTTPException(status_code=400, detail="Unknown service")

    journalctl = shutil.which("journalctl")
    if journalctl is None:
        if _in_docker():
            text = await _docker_logs(service, lines)
            dc_svc = _DOCKER_SERVICES.get(service, "backend")
            return {"service": service, "unit": dc_svc, "lines": lines, "text": text}
        raise HTTPException(status_code=503, detail="journalctl not available")

    # systemd 主機：journalctl
    proc = await asyncio.create_subprocess_exec(
        journalctl, "-u", unit, "-n", str(lines), "--no-pager", "--output", "short-iso",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=15)
    except TimeoutError as exc:
        proc.kill()
        raise HTTPException(status_code=504, detail="journalctl timed out") from exc
    text = out.decode("utf-8", errors="replace")
    return {"service": service, "unit": unit, "lines": lines, "text": text}

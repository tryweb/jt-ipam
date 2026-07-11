# jt-ipam（Docker 版）· v0.5.103

[![License](https://img.shields.io/github/license/jasoncheng7115/jt-ipam?color=blue)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/jasoncheng7115/jt-ipam)](https://github.com/jasoncheng7115/jt-ipam/commits/main)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-async-009688?logo=fastapi&logoColor=white)
![Vue](https://img.shields.io/badge/Vue-3-42b883?logo=vuedotjs&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)

> **Docker 優先**的 jt-ipam 部署方式——從 GitHub Container Registry 拉取預建映像，幾分鐘內即可啟動。可自架、以整合為核心的 IPAM，整合多家 DNS Server、LibreNMS、OPNsense、pfSense、Proxmox VE、Wazuh 與本地 AI。
>
> 此為 Docker-first fork。上游基於 systemd 的版本請見 [UPSTREAM_README_zh-TW.md](UPSTREAM_README_zh-TW.md)。
>
> 作者：Jason Tools Co., Ltd.（節省工具箱）｜授權：Apache-2.0｜English: [README.md](README.md)

---

## 快速開始

```bash
curl -fsSL https://raw.githubusercontent.com/tryweb/jt-ipam/main/install.sh | bash
```

安裝腳本會自動：

1. **檢查**系統需求（2+ 核心 CPU、4+ GB 記憶體、10+ GB 磁碟）
2. **確認** Docker 與 Docker Compose 已安裝並正常執行
3. **解析**目標 online release（預設 latest）
4. **下載**對應的 runtime bundle release asset（production 不需要完整 repo checkout）
5. **產生** `.env` 設定檔與安全金鑰（`SECRET_KEY`、`ENCRYPTION_KEY`、`POSTGRES_PASSWORD`）
6. **提示**輸入 `APP_PUBLIC_URL` 與管理員帳密
7. **拉取**設定好的預建映像檔（從 GitHub Container Registry）
8. **啟動**全部 5 個服務
9. **等待**健康檢查通過並顯示維護提示

等 10–20 秒讓 migration 與 health check 完成，瀏覽器開啟 **http://localhost:8080**（或 Docker 主機 IP 的 8080 埠）。

> 已安裝的環境重新執行 `install.sh` 會自動委派給本機 `upgrade.sh`。

## 安裝通道（Install channels）

- **Online** — `curl -fsSL https://raw.githubusercontent.com/tryweb/jt-ipam/main/install.sh | bash`
  - 使用 GitHub Release 的 runtime bundle asset
  - 會在 `.env` 寫入 `INSTALL_CHANNEL=online`
  - 後續用 `bash upgrade.sh` 走 online 升級流程
- **Offline** — 由 `scripts/build-docker-package.sh` 另行產生
  - 從 `images.tar` 載入映像
  - 會在 `.env` 寫入 `INSTALL_CHANNEL=offline`
  - 後續用 `bash upgrade.sh --bundle /path/to/jt-ipam-offline-*.tar.gz` 走 offline 升級流程

Online / offline 是刻意分開的兩條路徑。

## 升級

安裝完成後，請在部署目錄執行：

```bash
bash upgrade.sh
```

- Online 安裝預設檢查最新 release runtime bundle。
- `bash upgrade.sh --tag vX.Y.Z` 可把環境 pin 到指定 release tag。
- Offline 安裝需要新的 offline package，並以 `--bundle /path/to/jt-ipam-offline-*.tar.gz` 升級。

## 本機開發

從原始碼自行建置（取代拉取預建映像）：

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

`docker-compose.dev.yml` 是疊加層，為 `backend`、`sync`、`frontend` 加入 `build:` 段落。基礎設施服務（postgres、redis）維持不變。

## 服務

| 服務 | 映像檔 | 角色 |
|------|--------|------|
| `postgres` | `pgvector/pgvector:pg16` | PostgreSQL 16 + pgvector |
| `redis` | `redis:7-alpine` | Session 快取、速率限制 |
| `backend` | `ghcr.io/tryweb/jt-ipam-backend:latest` | FastAPI uvicorn（4 workers）、Alembic 啟動遷移 |
| `sync` | `ghcr.io/tryweb/jt-ipam-backend:latest` | 背景整合迴圈（DNS、LibreNMS…） |
| `frontend` | `ghcr.io/tryweb/jt-ipam-frontend:latest` | nginx:alpine 提供 SPA + `/api/` 反代 |

可透過 `BACKEND_IMAGE` / `FRONTEND_IMAGE` 環境變數覆寫映像來源。

- `.env.docker.example` 預設兩者都是 `:latest`。
- Online install/upgrade 若未指定 `--tag vX.Y.Z`，就維持 `latest`。
- 若你將官方映像 pin 到特定 release tag，後續 online 升級會沿用這種 tag-pin 管理方式。
- 自訂 registry / 自訂 image 名稱不會被自動覆蓋。

## 最低主機需求

**最低：** 2 核心 CPU · 4 GB 記憶體 · 20 GB 磁碟。**建議：** 4 核心 · 8 GB 記憶體 · 40 GB 以上磁碟。

選用的本地 LLM（Ollama）不含在上述數字內，請另跑於獨立主機。

## 預設帳密

| 欄位 | 環境變數 | 預設值 |
|------|---------|--------|
| 使用者名稱 | `BOOTSTRAP_ADMIN_USERNAME` | `admin` |
| 密碼 | `BOOTSTRAP_ADMIN_PASSWORD` | 請見 `.env` |
| Email | `BOOTSTRAP_ADMIN_EMAIL` | `admin@example.com` |

首次啟動時 entrypoint 會自動以 `--force-update` 建立管理員；在 `.env` 中變更密碼後執行 `docker compose restart backend` 即可更新。

## 環境變數

完整列表請見 [`.env.docker.example`](.env.docker.example)：

| 變數 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `POSTGRES_PASSWORD` | 是 | — | Postgres 密碼 |
| `SECRET_KEY` | 是 | — | JWT 簽章金鑰（`openssl rand -hex 32`） |
| `ENCRYPTION_KEY` | 是 | — | AES-256-GCM 金鑰（`openssl rand -hex 32`） |
| `APP_ENV` | 否 | `development` | 正式環境請設為 `production` |
| `APP_PUBLIC_URL` | 否 | — | 對外網址（OIDC/CORS 需要） |
| `API_PUBLIC_URL` | 否 | — | 對外 API 網址 |
| `BOOTSTRAP_ADMIN_USERNAME` | 否 | `admin` | 初始管理員帳號 |
| `BOOTSTRAP_ADMIN_PASSWORD` | 是* | — | *自動建立管理員需要 |
| `INSTALL_CHANNEL` | 否 | `online`/`offline` | 由 installer 寫入；決定升級流程 |
| `BACKEND_TLS_MODE` | 否 | `docker-compose` | Compose 部署鎖定為此值 |
| `BACKEND_IMAGE` | 否 | `ghcr.io/tryweb/jt-ipam-backend:latest` | Backend 與 sync 映像（自訂 registry 時覆寫） |
| `FRONTEND_IMAGE` | 否 | `ghcr.io/tryweb/jt-ipam-frontend:latest` | Frontend 映像（自訂 registry 時覆寫） |

## TLS / HTTPS

Compose 堆疊預設使用 `BACKEND_TLS_MODE=docker-compose`。後端在 Docker 內部網路綁定 `0.0.0.0:8000`（HTTP）；前端 nginx 容器將 `/api/` 反代至後端（不加密）。所有安全標頭（CSP、HSTS、X-Frame-Options）已在 nginx 層設定。

請在邊緣反向代理（Traefik、haproxy、或其他 nginx）終止 TLS，並在 `.env` 中將 `APP_PUBLIC_URL` / `API_PUBLIC_URL` 設為 `https://` 網址。`docker-compose` 模式會跳過 HTTPS URL 檢查（TLS 已在 upstream 卸載）。

其他 TLS 模式（主機 nginx 反代、uvicorn 直接 TLS、外部反代）請見 [UPSTREAM_README_zh-TW.md](UPSTREAM_README_zh-TW.md)。

## 檔案佈局

```
jt-ipam/
├── docker-compose.yml          # 正式環境服務定義（拉取預建映像）
├── docker-compose.dev.yml      # 開發疊加層（本機建置）
├── install.sh                  # Online bootstrap installer（下載 runtime release asset）
├── upgrade.sh                  # 支援 online/offline 的本機升級入口
├── .env.docker.example         # 環境變數範本
├── RELEASE                     # 已安裝 release / channel metadata（安裝時產生）
├── backend/
│   ├── Dockerfile              # 後端 build（multi-stage）
│   └── scripts/docker-entrypoint.sh  # 啟動指令稿
├── frontend/
│   └── Dockerfile              # 前端 build（pnpm + nginx:alpine）
├── deploy/
│   ├── nginx/jt-ipam-docker.conf     # Compose nginx 設定
│   └── postgres/init-docker.sh       # PG extension 初始化
└── scripts/
    ├── docker-backup.sh        # 備份腳本
    └── docker-restore.sh       # 還原腳本
```

## 正式環境考量

- **TLS 終止** — Compose 堆疊在 Docker 內部網路走 HTTP；請在邊緣（Traefik、haproxy 或其他 nginx）終止 TLS。請見上方 [TLS / HTTPS](#tls--https) 小節。
- **金鑰** — 不可把 `.env` 提交到 git。定期更換 `SECRET_KEY` 與 `ENCRYPTION_KEY`。
- **資源限制** — 在 `docker-compose.override.yml` 加入 `deploy.resources`。
- **Release channel metadata** — `.env` 與 `RELEASE` 會標示此環境是 online 或 offline 管理；除非你要重新初始化部署模型，否則不要移除它們。

## 備份、驗證與還原

[`scripts/docker-backup.sh`](scripts/docker-backup.sh) 與 [`scripts/docker-restore.sh`](scripts/docker-restore.sh) 包裝了 bind mount 相容性、連線中斷與後端重啟等步驟，建議優先使用：

```bash
bash scripts/docker-backup.sh                # 建立備份
bash scripts/docker-restore.sh <時間戳>       # 還原指定備份
```

底層的 compose 服務（可直接用，但需自行處理下列事項）：

```bash
docker compose run --rm backup                # 建立備份
docker compose run --rm backup-verify         # 驗證最新備份
docker compose run --rm restore               # 還原最新備份（或 -e BACKUP_FILE=<時間戳>）
docker compose restart backend                # 重啟後端讀取還原資料
```

### 備份 — `docker compose run --rm backup`

備份以下項目到 `./backups/`：

| 成品 | 說明 | 範例檔名 |
|------|------|----------|
| `*.sql.gz` | PostgreSQL 傾印（`pg_dump \| gzip`） | `jt-ipam-20260619_141141.sql.gz` |
| `*.env` | `.env` 設定檔備份（金鑰、密碼） | `jt-ipam-20260619_141141.env` |
| `*.uploads.tar.gz` | 上傳檔案（機房平面圖、機櫃圖） | `jt-ipam-20260619_141141.uploads.tar.gz` |

備份完成後自動執行 gzip 完整性檢查 + SQL 標頭驗證，並印出資料表列表。

**Bind mount 相容性：** 部分 Docker 29.x 在 `docker compose run --rm` 下，寫入 bind mount 的檔案可能不回寫到 host。備份腳本已自動處理此問題；若直接使用 compose 服務，請採用手動取回方式：

```bash
docker compose run --name backup-tmp backup
docker cp backup-tmp:/backups/jt-ipam-<時間戳>.* ./backups/
docker rm backup-tmp
```

### 驗證 — `docker compose run --rm backup-verify`

針對最新備份（或指定檔案 `-e BACKUP_FILE=<basename>`）執行 4 層檢查：

1. **gzip 完整性** — `gzip -t`
2. **SQL 標頭** — 確認為 `pg_dump` 格式
3. **資料表 / 索引 / 序列數**
4. **結尾完整性** — 檢查傾印結尾標記

輸出範例：
```
1/4 gzip integrity:             PASS
2/4 SQL header:                 PASS (pg_dump format)
3/4 table & index count:        Tables: 79 | Indexes: 92 | Sequences: 2
4/4 trailing completeness:      PASS (clean dump footer)
VERDICT: VALID
```

### 還原 — `docker compose run --rm restore`

> **先決條件：** `jt_ipam` 資料庫不能有作用中的連線，否則 `DROP DATABASE` 會失敗。還原腳本（`docker-restore.sh`）會自動中斷連線；若直接使用 compose 服務，請先手動執行：
> ```bash
> docker compose exec postgres psql -U jt_ipam -d postgres \
>   -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='jt_ipam' AND pid <> pg_backend_pid();"
> ```

執行 5 步驟還原（可指定 `BACKUP_FILE`，省略則還原最新）：

1. **DROP DATABASE IF EXISTS** + **CREATE DATABASE**（同一個 owner）
2. **`zcat \| psql`** 匯入 SQL 傾印
3. **重建 PG extensions**（pgcrypto, citext, pg_trgm, btree_gist, vector）— DROP DATABASE 後會遺失
4. **還原上傳檔案** 從 `*.uploads.tar.gz`
5. **驗證資料表數量** 透過 `information_schema`

完成後若有 `.env` 備份，會提示在 host 上執行：

```bash
cp ./backups/jt-ipam-<時間戳>.env  .env
docker compose restart backend
```

> **注意：** 便利腳本 `scripts/docker-restore.sh` 會自動重啟後端並等待健康檢查。

### 跨主機遷移

```bash
# 在原主機
docker compose run --rm backup
scp ./backups/jt-ipam-<時間戳>.*  新主機:/opt/jt-ipam/backups/

# 在新主機（Docker Compose 必須已在運行）
cp /opt/jt-ipam/backups/jt-ipam-<時間戳>.env  .env
docker compose run --rm -e BACKUP_FILE=<時間戳> restore
docker compose restart backend
```

## 技術堆疊

| 層 | 選用 |
|------|--------|
| 後端 | Python 3.12 · FastAPI · SQLAlchemy 2.0（async）· asyncpg · Alembic · Pydantic v2 |
| 資料庫 | PostgreSQL 16（原生 `inet`/`cidr`/`macaddr`）+ pgvector |
| 前端 | Vue 3 · TypeScript · Vite · Naive UI · Pinia · vue-i18n |
| 認證 | argon2id · TOTP · 短效 JWT + refresh |
| AI | LLM Server（本地）· pgvector · MCP server |
| 部署 | Docker Compose（5 容器，從 GHCR 拉取預建映像） |

## 上游文件

完整的上游 jt-ipam 功能文件請見 [UPSTREAM_README_zh-TW.md](UPSTREAM_README_zh-TW.md)，涵蓋：

- **為什麼是 jt-ipam？** — 完整功能列表與整合說明
- **Graylog DSV 對照表** — 即時 IP→主機名稱補實設定
- **BMC 主控台（IPMI SOL）** — 疑難排解指南
- **核心物件** — 區段、子網路、IP、VLAN、VRF 等
- **RBAC 權限** — 物件級權限與 5 種內建角色
- **安全（OWASP Top 10:2025）** — 強制 TLS、加密、稽核鏈
- **原生（systemd）安裝** — 不需 Docker 的傳統安裝方式
- **首次登入與重設管理員密碼**
- **TLS 模式 A/B/C** — nginx 反代、uvicorn 直接 TLS、外部反代
- **藍圖進度** — 階段性功能交付計畫

## 授權

Apache-2.0。商業支援請聯繫 Jason Tools。

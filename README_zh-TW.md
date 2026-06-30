# jt-ipam v0.5.60

[![License](https://img.shields.io/github/license/jasoncheng7115/jt-ipam?color=blue)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/jasoncheng7115/jt-ipam)](https://github.com/jasoncheng7115/jt-ipam/commits/main)
[![Stars](https://img.shields.io/github/stars/jasoncheng7115/jt-ipam?style=flat)](https://github.com/jasoncheng7115/jt-ipam/stargazers)
![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-async-009688?logo=fastapi&logoColor=white)
![Vue](https://img.shields.io/badge/Vue-3-42b883?logo=vuedotjs&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)
![OWASP](https://img.shields.io/badge/OWASP-Top%2010%3A2025-000000)

**🌐 [專案介紹網站 / Project site →](https://jasoncheng7115.github.io/jt-ipam/?lang=zh-TW)**

> 可自架、以整合為核心的 IPAM — 操作流程沿襲 phpIPAM 使用者熟悉的風格、全新獨立開發，整合多家 DNS Server、LibreNMS、OPNsense、pfSense、Proxmox VE、Wazuh 與本地 AI。
>
> 作者：Jason Tools Co., Ltd.（節省工具箱）｜授權：Apache-2.0｜English: [README.md](README.md)

---

## 為什麼是 jt-ipam？

phpIPAM 老使用者幾乎零學習成本；以現代技術全新打造（非基於 phpIPAM 程式碼）。深度整合：

- **DNS**：PowerDNS、BIND 9、OPNsense Unbound、Univention UCS、Microsoft Windows DNS（讀取正反解狀態，可選擇性推送記錄）
- **LibreNMS**：裝置同步、ARP / FDB 抓取、上線狀態互補、自動加入監控
- **基礎設施**：Proxmox VE、Wazuh、OPNsense / pfSense（別名 / 規則 / NAT 同步）
- **Graylog**：提供 IP→主機名稱/FQDN 的 DSV 對照表端點，供 Graylog「DSV File from HTTP」資料配接器抓取
- **本地 AI**：LLM Server 自然語言查詢 + 語意搜尋（資料不外送），並提供 MCP server（stdio / Streamable HTTP）；實測搭配 `gemma4:26b` 效果良好

也內建：**瀏覽器內遠端連線管理** —— SSH 終端機，外加 RDP、VNC 桌面（RDP/VNC 為 **Beta**），全部在瀏覽器內，連線帳密預設不儲存、可選用**個人加密憑證金庫**（by-user、AES-GCM），物件層級 RBAC、單次 ticket→WebSocket 連線與完整稽核（RDP/VNC 走選用相依，僅在有預編譯 wheel 時才安裝，不影響基礎安裝）、**IP 申請審核流程**（可設多關卡會簽 / 依序關卡，站內 + Email 通知）、**DNS 記錄檢視**（找出沒有對應 IPAM 的記錄）、**掃描代理**（ICMP/ARP/反解/NetBIOS/mDNS/OS 探測）、**憑證集中保管與派送**（商業 / 自簽憑證一次上傳，純 bash 代理依排程自動派送到 nginx/apache/caddy/haproxy/Proxmox VE·PMG·PBS/Zimbra…等服務並重載，私鑰加密保存、到期告警、可手動續簽）、**機房平面圖 + 機櫃 U 位圖**（含半 U / 正背面、SVG/PNG/draw.io 匯出）、**纜線追蹤**（多跳穿透）、IP 異動記錄與失聯 IP 回收、通用表格欄位選擇 + 多格式匯出。

## Graylog 記錄補實（DSV 對照表）

jt-ipam 會**即時**產生一份 IP → 主機名稱 / FQDN 的對照表，讓 Graylog 的「DSV File from HTTP」資料配接器直接抓取，把記錄裡只有 IP 的事件自動補上可讀名稱。

- 在 **管理 → 系統設定 → Graylog DSV** 啟用：設定路徑代稱、輸出格式（CSV / TSV）並產生存取 token
- 端點 `GET /api/v1/lookup/<路徑>?token=<token>`，每次請求即時查詢資料庫產生
- **提供的欄位**：每列兩欄 —— 第 1 欄＝IP（key），第 2 欄＝主機名稱或 FQDN（value）；只輸出「有主機名稱」的 IP
- **資料格式**：UTF-8 純文字。CSV 以逗號分隔、**每欄用雙引號包覆**並依 RFC 4180 跳脫；TSV 以 Tab 分隔（不加引號）。例如：

  ```csv
  "10.1.1.141","log1.example.com"
  "10.1.1.145","mg-host"
  ```

- 在 Graylog 的「DSV File from HTTP」配接器：URL 填上方網址、分隔符依格式選逗號或 Tab、**Key column = 0、Value column = 1**（Graylog 欄位索引從 0 起算）
- token 逐次驗證、可隨時重新產生；設定頁直接提供可複製的完整對照表網址

## 核心物件

`區段 → 子網路 → IP 位址`，外加 `裝置` / `機櫃` / `地點`、`客戶`（管理單位）、`VLAN` / `VRF`、`NAT`、OPNsense / pfSense 防火牆，以及 IEEE OUI 廠商對照表（每月更新）。

## 權限（RBAC）

物件級權限，涵蓋 **7 種物件類型**（客戶 / 區段 / 子網路 / IP / 裝置 / 機櫃 / 地點）：

- **階層繼承** — 授權上層（如某客戶或區段）自動涵蓋其下所有物件（子網路 → IP；地點 → 機櫃 → 裝置）
- 每種物件類型可用 **「全部」wildcard**
- **5 個內建角色** — 系統管理員、唯讀檢視者、網路操作員、稽核員、部門管理員
- 可見性處處強制：清單端點、全域搜尋、拓樸圖、所有下拉選單，永遠只會出現使用者可見的物件。預設關閉（deny-by-default）。

## 安全（OWASP Top 10:2025）

安全是 day-one 需求，每個模組與 PR 都對齊 **OWASP Top 10:2025**，詳見 [`SECURITY_zh-TW.md`](SECURITY_zh-TW.md)。

- **強制 TLS** — 二擇一：nginx 反代終止 TLS（`BACKEND_TLS_MODE=nginx`），或 uvicorn 直接掛自簽憑證（`BACKEND_TLS_MODE=direct`）
- A01 — deny-by-default RBAC、物件級檢查（如上）
- A02 — argon2id 密碼雜湊；儲存的敏感資料（DNS 憑證 / SNMP / API token）應用層加密
- A03 — 參數化 SQLAlchemy、嚴格 Pydantic v2 驗證、CSP + 輸出跳脫
- A05 — HSTS、CSP、X-Frame-Options、Referrer-Policy
- A07 — TOTP MFA、帳號鎖定、HttpOnly+Secure+SameSite cookie、API token TTL
- A08 — SHA-256 稽核鏈
- A09 — 結構化稽核記錄
- A10 — 所有對外整合走 SSRF 白名單；封鎖 metadata / link-local

## 技術堆疊

| 層 | 選用 |
|------|--------|
| 後端 | Python 3.12 · FastAPI · SQLAlchemy 2.0（async）· asyncpg · Alembic · Pydantic v2 |
| 資料庫 | PostgreSQL 16（原生 `inet`/`cidr`/`macaddr`）+ pgvector |
| 前端 | Vue 3 · TypeScript · Vite · Naive UI · Pinia · vue-i18n |
| 認證 | argon2id · TOTP · 短效 JWT + refresh |
| AI | LLM Server（本地）· pgvector · MCP server |
| 部署 | systemd + nginx + apt 套件 —— **不需 Docker image**（適合虛擬機 / 容器） |

## 安裝（單機 / 虛擬機 / 容器）

> Debian 12 / Ubuntu 22.04+（64 位元）。強制 HTTPS。
>
> **最低需求：** 2 核心 CPU · 4 GB 記憶體 · 20 GB 磁碟。**建議：** 4 核心 · 8 GB 記憶體 · 40 GB 以上磁碟（保留空間給 PostgreSQL 資料庫、GeoIP/OUI 資料與備份成長）。
>
> 選用的本地 LLM（Ollama）**不含**在上述數字內——請另跑於獨立主機，並依所選模型自行配足記憶體 / 顯示記憶體。

```bash
# 前置：最小化系統可能沒有 curl（一行式安裝需要它）
sudo apt-get update && sudo apt-get install -y curl
# 一行完成：自動 clone 到 /opt/jt-ipam 並安裝（不必先手動 git）
curl -fsSL https://raw.githubusercontent.com/jasoncheng7115/jt-ipam/main/scripts/bootstrap.sh | sudo bash
```

腳本會安裝 `postgresql-16` / `python3.12` / `nginx` / `redis`，建立 `jtipam` 系統帳號與 PG 角色，產生金鑰寫入 `/etc/jt-ipam/backend.env`，跑 `alembic upgrade head`，build 前端並啟用 `jt-ipam-backend.service`。

升級：`sudo bash /opt/jt-ipam/scripts/jt-ipam.sh upgrade`（**腳本內含 `git pull`**，直接跑即可），接著備份 → 相依 → alembic → build → 重啟。詳見 [`docs/INSTALL.md`](docs/INSTALL.md)。

> **選用：Docker Compose。** 另有一條次要部署路徑在 [`deploy/docker/`](deploy/docker/)（`./gen-env.sh` 後 `docker compose up -d --build`；之後用 `./update.sh` 升版）。主力且完整支援的仍是 systemd + apt。

### 首次登入與重置管理員密碼

全新安裝時，腳本會**自動建立 `admin` 帳號、產生隨機密碼並在結束時印出一次**（也存到 `/etc/jt-ipam/.admin-initial-password`，僅 root 可讀；該檔位於 `/etc` 之下、不在 web root 內，無法透過 HTTP 連到）。登入後請立即更換，之後即可安全刪除此檔：`sudo rm /etc/jt-ipam/.admin-initial-password`。

重置管理員密碼（或在尚無管理員時建立第一個），在伺服器上執行：

```bash
sudo -u jtipam bash -c 'cd /opt/jt-ipam/backend; set -a; source /etc/jt-ipam/backend.env; set +a; \
  .venv/bin/python -m app.cli.bootstrap create-admin \
    --username admin --email admin@example.com --password-stdin --force-update'
# 接著在 stdin 輸入新密碼（≥ 12 字元）
```

不加 `--force-update` 則是新建管理員，而非重置既有帳號。

## TLS / HTTPS

強制 HTTPS，兩種模式擇一（`/etc/jt-ipam/backend.env` 的 `BACKEND_TLS_MODE`）：

**模式 A — nginx 反代（預設、建議）** `BACKEND_TLS_MODE=nginx`
nginx 終止 TLS、反代到本機 uvicorn(127.0.0.1:8000)。換成正式憑證：

```bash
# 把正式憑證/私鑰覆蓋到固定路徑後 reload（路徑已寫死在 nginx 設定）
cp fullchain.pem /etc/jt-ipam/tls/server.crt
cp privkey.pem   /etc/jt-ipam/tls/server.key
chmod 600 /etc/jt-ipam/tls/server.key
nginx -t && systemctl reload nginx
```

Let's Encrypt：把 `ssl_certificate` 指到 `/etc/letsencrypt/live/<FQDN>/fullchain.pem`、`ssl_certificate_key` 指到 `…/privkey.pem`，續期後 `systemctl reload nginx`。自架 nginx 反代最小設定：

```nginx
server {
    listen 443 ssl;
    server_name ipam.example.com;
    ssl_certificate     /etc/jt-ipam/tls/server.crt;
    ssl_certificate_key /etc/jt-ipam/tls/server.key;
    root /opt/jt-ipam/frontend/dist;
    index index.html;
    location /api/ { proxy_pass http://127.0.0.1:8000; proxy_set_header Host $host; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location / { try_files $uri $uri/ /index.html; }
}
```

**模式 B — uvicorn 直接自簽** `BACKEND_TLS_MODE=direct`
uvicorn 自己掛 `--ssl-*`，安裝時 `scripts/generate-self-signed-cert.sh` 會產自簽憑證。換憑證：把正式(或自管)憑證覆蓋同一組路徑後重啟服務：

```bash
cp fullchain.pem /etc/jt-ipam/tls/server.crt
cp privkey.pem   /etc/jt-ipam/tls/server.key
chmod 600 /etc/jt-ipam/tls/server.key
systemctl restart jt-ipam-backend
```

> 兩種模式憑證路徑相同(`/etc/jt-ipam/tls/server.{crt,key}`)，差別只在「誰終止 TLS」：模式 A reload nginx、模式 B 重啟 backend。

**模式 C — 前面已有外部反向代理負責 SSL**（你自己有一台 nginx / LB 終止 TLS）
本機 nginx 只做 HTTP，套用外部代理模式範本：

```bash
sudo cp deploy/nginx/jt-ipam-external-proxy.conf         /etc/nginx/sites-available/jt-ipam
sudo cp deploy/nginx/jt-ipam-external-proxy-snippet.conf /etc/nginx/snippets/jt-ipam-proxy.conf
sudo nginx -t && sudo systemctl reload nginx
```

> ⚠️ **必要——公開邊緣的安全標頭。** 真正**為使用者終結 TLS 的那台代理**必須送出安全標頭（HSTS、CSP `frame-src 'self'`、
> X-Frame-Options、nosniff、Referrer-Policy、Permissions-Policy、COOP、CORP）與 `server_tokens off`。這些標頭**不會**
> 自動跨多一跳存活，所以如果你的邊緣機是上面這台以外的**另一台**，**那台邊緣機也要設**（內建範本已含；非 nginx 的 LB
> 請照樣複製一份）。請從真正的對外網址驗證：
> `curl -skI https://你的網域/ | grep -iE 'strict-transport|content-security|x-frame|cross-origin|^server'`
> ——每個標頭應**剛好出現一次**、`Server: nginx`（無版本）。

外部代理本身**不會**影響 OIDC / M365(Entra ID) 登入，但有三個一定要對，否則登入會被導到 `ipam.example.com` 或卡在登入頁：

1. **`/etc/jt-ipam/backend.env`** 的 `APP_PUBLIC_URL` / `API_PUBLIC_URL` / `CORS_ORIGINS` 都設成對外網域（`https://ipam.your-domain.com`），不要留預設 `ipam.example.com`（後端簽發 token、OIDC 回呼網址都看它）→ 改完 `systemctl restart jt-ipam-backend`。
2. **外部 nginx 轉發時要送** `proxy_set_header X-Forwarded-Proto $scheme;`（=https）與 `Host $host;`；本機範本會把它透傳給後端（避免後端誤判成 http、Secure cookie 設不起來）。
3. **OIDC Redirect URI** 在 IdP 與 jt-ipam UI（系統設定 → SSO → OIDC）都填 `https://ipam.your-domain.com/api/v1/auth/oidc/callback`。注意 **UI 存過的 DB 值優先於 .env**，改 .env 後要在 UI 再存一次。
> HSTS 由持有憑證的外部 nginx 送出，本機（HTTP）不送。

## Docker Compose（容器）

jt-ipam 在根目錄提供 `docker-compose.yml`，可透過 Docker 快速啟動 4 個容器：

| 服務 | 映像檔 | 角色 |
|------|--------|------|
| `postgres` | `pgvector/pgvector:pg16` | PostgreSQL 16 + pgvector |
| `redis` | `redis:7-alpine` | Session 快取、速率限制 |
| `backend` | 自行 build | FastAPI uvicorn（4 workers） |
| `frontend` | 自行 build | nginx:alpine 提供 SPA + `/api/` 反代 |

> **最低主機需求：** 2 核心 · 4 GB 記憶體。**建議：** 4 核心 · 8 GB。

### 快速開始

```bash
git clone https://github.com/jasoncheng7115/jt-ipam.git
cd jt-ipam
cp .env.docker.example .env
# 編輯 .env — 至少設定 BOOTSTRAP_ADMIN_PASSWORD（≥ 12 字元）
# 以及 SECRET_KEY / ENCRYPTION_KEY（用 `openssl rand -hex 32` 產生）
docker compose up -d --build
```

等 10–20 秒讓 migration 與 health check 完成，瀏覽器開啟 **http://localhost:8080**。

### 環境變數

| 變數 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `POSTGRES_PASSWORD` | 是 | — | Postgres 密碼 |
| `SECRET_KEY` | 是 | — | JWT 簽章金鑰（`openssl rand -hex 32`） |
| `ENCRYPTION_KEY` | 是 | — | AES-256-GCM 金鑰（`openssl rand -hex 32`） |
| `APP_PUBLIC_URL` | 否 | — | 對外網址（OIDC/CORS 需要） |
| `BOOTSTRAP_ADMIN_PASSWORD` | 是* | — | *初始管理員密碼 |

完整列表見 [`.env.docker.example`](.env.docker.example)。

### 檔案佈局

```
jt-ipam/
├── backups/                    # 備份成品 (sql.gz, env, uploads.tar.gz)
├── docker-compose.yml          # 服務定義
├── .env.docker.example         # 環境變數範本
├── backend/Dockerfile          # 後端 build（multi-stage）
├── frontend/Dockerfile         # 前端 build（pnpm + nginx:alpine）
├── deploy/nginx/jt-ipam-docker.conf     # Compose nginx 設定
└── deploy/postgres/init-docker.sh       # PG extension 初始化
```

### 正式環境考量

- **TLS 終止** — Compose 堆疊在 Docker 內部網路走 HTTP；請在邊緣（Traefik、haproxy 或其他 nginx）終止 TLS
- **金鑰** — 不可把 `.env` 提交到 git。定期更換 `SECRET_KEY` 與 `ENCRYPTION_KEY`
- **資源限制** — 在 `docker-compose.override.yml` 加入 `deploy.resources`

### 備份、驗證與還原

[`scripts/docker-backup.sh`](scripts/docker-backup.sh) 與 [`scripts/docker-restore.sh`](scripts/docker-restore.sh) 包裝了 bind mount 相容性、連線中斷與後端重啟等步驟，建議優先使用：

```bash
bash scripts/docker-backup.sh                # 建立備份
bash scripts/docker-restore.sh <時間戳>       # 還原指定備份（不給參數會列出可用備份；自動重啟後端）
```

底層的 compose 服務（可直接用，但需自行處理下面說明的事項）：

```bash
docker compose run --rm backup                # 建立備份
docker compose run --rm backup-verify         # 驗證最新備份
docker compose run --rm restore               # 還原最新備份（或 -e BACKUP_FILE=<時間戳>）
docker compose restart backend                # 重啟後端讀取還原資料
```

#### 備份 — `docker compose run --rm backup`

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

#### 驗證 — `docker compose run --rm backup-verify`

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

#### 還原 — `docker compose run --rm restore`

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

#### 跨主機遷移

```bash
# 在原主機
docker compose run --rm backup
scp ./backups/jt-ipam-<時間戳>.*  新主機:/opt/jt-ipam/backups/

# 在新主機（Docker Compose 必須已在運行）
cp /opt/jt-ipam/backups/jt-ipam-<時間戳>.env  .env
docker compose run --rm -e BACKUP_FILE=<時間戳> restore
docker compose restart backend
```

> ℹ️ 上游專案另有替代的 [Docker Compose 版本](deploy/docker/)（5 個服務、自動 HTTPS、`JT_IPAM_ADMIN_*` 環境變數），放在 `deploy/docker/` 目錄下。根目錄的 `docker-compose.yml` 是此 fork 建議使用的版本。

## 專案結構

```
jt-ipam/
├── docs/              # 規格、安全、資料模型、API 參考
├── backend/           # FastAPI app
│   └── app/
│       ├── core/      # config / db / audit / safe_http / encrypted_secret
│       ├── models/    # SQLAlchemy 2.0
│       ├── schemas/   # Pydantic v2
│       ├── api/v1/    # REST API
│       ├── services/  # 商業邏輯（ai / oui / opnsense / topology / search / permission）
│       ├── mcp/       # MCP server + tools（給 LLM 用戶端）
│       └── plugins/   # 外掛系統
├── frontend/          # Vue 3 + TS
│   └── src/{views,components,composables,api,stores,i18n,router}
├── backups/                    # 備份成品（sql.gz、env、uploads.tar.gz）
├── docker-compose.yml          # Docker Compose（4 服務）
├── .env.docker.example         # Docker 環境變數範本
├── deploy/
│   ├── nginx/
│   │   └── jt-ipam-docker.conf            # Compose nginx 設定
│   └── postgres/
│       └── init-docker.sh      # PG extension 初始化
└── scripts/           # jt-ipam.sh（install/upgrade/uninstall）、docker-backup.sh、docker-restore.sh、ci.sh、oui_refresh.py
```

## 藍圖進度

- **Phase 1（完成）** — phpIPAM 對等功能 + 改良（區段/子網路/IP/VLAN/VRF/NAT/裝置/機櫃/地點/IP 申請、TOTP/API-Token/RBAC、phpIPAM 匯入、CSV/RIPE/TWNIC、視覺化子網路格、強制 TLS）
- **Phase 2（完成）** — 多家 DNS + 深度 LibreNMS 整合（裝置/ARP/FDB/實際狀態）+ 異常偵測 + SHA-256 稽核鏈 + pgvector AI 語意搜尋
- **Phase 3（完成）** — 租戶/聯絡人/佈線/電力/VPN/虛擬化 + Proxmox VE 同步 + Cytoscape 拓樸 + OIDC/SAML SSO + OPNsense / pfSense 防火牆同步 + Wazuh agent 盤點
- **Phase 4（完成、已縮減範圍）** — MCP server + 本地 LLM 自然語言（LLM Server）+ 外掛機制

## 授權

Apache-2.0｜商業支援請聯繫 Jason Tools。

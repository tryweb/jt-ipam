# 離線 Docker 部署指南

> English: [OFFLINE_DOCKER.md](OFFLINE_DOCKER.md)

本指南涵蓋 jt-ipam **離線（無網路）Docker 部署**的完整生命週期：
**打包 → 安裝 → 備份 → 還原 → 升級**。

當目標主機**無法連線網際網路**，或者您想要在正式環境使用**確定性、預先建好的映像檔**時，
請使用離線部署方式。

---

## 目錄

1. [架構概觀](#1-架構概觀)
2. [系統需求](#2-系統需求)
3. [打包（在有網路的機器上）](#3-打包在有網路的機器上)
4. [安裝（在離線主機上）](#4-安裝在離線主機上)
5. [備份](#5-備份)
6. [還原](#6-還原)
7. [升級](#7-升級)

---

## 1. 架構概觀

離線安裝包是一個自包含的壓縮檔，包含執行 jt-ipam 所需的一切，不需要網際網路：

| 服務 | 角色 | 映像檔來源 |
|------|------|-----------|
| `postgres` | PostgreSQL 16 + pgvector | 打包時從 Docker Hub 拉取 |
| `redis` | Session 快取、速率限制 | 打包時從 Docker Hub 拉取 |
| `backend` | FastAPI uvicorn（4 workers） | 打包時建置或拉取 |
| `frontend` | nginx 提供 SPA + 反向代理 | 打包時建置或拉取 |
| `sync` | 背景整合循環 | 與 `backend` 共用同一映像檔 |

安裝包內含 **5 個服務**，由一份 `docker-compose.yml` 統一管理。

### 安裝包檔案結構

```
jt-ipam-offline/
├── images.tar                    # 所有 Docker 映像檔打包在一起
├── docker-compose.yml            # 服務定義（引用本機映像檔標籤）
├── .env.example                  # 環境變數範本
├── install.sh                    # 一鍵安裝腳本
├── deploy/
│   ├── postgres/
│   │   └── init-docker.sh        # PostgreSQL 擴充初始化
│   └── nginx/
│       └── jt-ipam-docker.conf   # Compose 用的 nginx 設定
├── scripts/
│   ├── docker-backup.sh          # 備份腳本
│   └── docker-restore.sh         # 還原腳本
└── MANIFEST.txt                  # 安裝包內容清單
```

---

## 2. 系統需求

### 打包機器（需網路）

| 項目 | 最低 | 建議 |
|------|------|------|
| 作業系統 | Linux（任一現代發行版） | Ubuntu 22.04+ / Debian 12+ |
| Docker Engine | 24.x | 27.x+ 含 `docker compose` 外掛 |
| 磁碟空間 | 10 GB 可用 | 20 GB 可用（映像檔 + 建置快取）|
| 網路 | 可連線 Docker Hub | 寬頻 |

### 目標主機（離線 / 無網路）

| 項目 | 最低 | 建議 |
|------|------|------|
| 作業系統 | Linux（任一現代發行版） | Ubuntu 22.04+ / Debian 12+ |
| Docker Engine | 24.x | 27.x+ 含 `docker compose` 外掛 |
| 磁碟空間 | 4 GB 可用 | 8 GB 可用（資料庫 + 上傳檔案）|
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |

---

## 3. 打包（在有網路的機器上）

在**有網路**的機器上，於**專案根目錄**執行打包腳本。

### 3.1 從原始碼建置（預設）

```bash
# Clone 專案
git clone https://github.com/jasoncheng7115/jt-ipam.git
cd jt-ipam

# 建置映像檔並產出離線安裝包
./scripts/build-docker-package.sh
```

腳本執行流程：
1. 從 Dockerfile 建置 `backend` 和 `frontend` 映像檔
2. 從 Docker Hub 拉取 `postgres` 和 `redis` 映像檔
3. 產生一份引用本機映像檔標籤的 `docker-compose.yml`
4. 產生 `install.sh`、`MANIFEST.txt`
5. 全部打包成 `jt-ipam-offline-<時間戳>.tar.gz`

### 3.2 從私有 Registry 拉取預先建置的映像檔

如果您有維護私有 Registry：

```bash
./scripts/build-docker-package.sh \
  --pull-from registry.example.com/jt-ipam \
  --pull-tag v0.4.207
```

這會從 `registry.example.com` 拉取 `backend` 和 `frontend` 映像檔，
重新標記為本機標籤後打包。

### 3.3 選項參考

| 選項 | 預設值 | 說明 |
|------|--------|------|
| `-t, --tag TAG` | `offline` | 映像檔標籤後綴 |
| `-o, --output FILE` | `jt-ipam-offline-<ts>.tar.gz` | 輸出壓縮檔路徑 |
| `-p, --prefix PREFIX` | `jt-ipam` | 本機映像檔名稱前綴 |
| `--no-cache` | — | `docker build` 加上 `--no-cache` |
| `--pull-from REGISTRY` | — | 從 REGISTRY 拉取預先建置的映像檔 |
| `--pull-tag TAG` | `latest` | Registry 中映像檔的標籤 |
| `-h, --help` | — | 顯示說明 |

### 3.4 產出物

```
jt-ipam-offline-20260621-143000.tar.gz
```

驗證安裝包：

```bash
tar tzf jt-ipam-offline-20260621-143000.tar.gz
# 預期包含：jt-ipam-offline/images.tar, docker-compose.yml, install.sh, ...
```

---

## 4. 安裝（在離線主機上）

將壓縮檔透過 USB、SCP 或其他帶外方式傳輸到目標主機。

### 4.1 解壓縮並安裝

```bash
# 解壓縮
tar xzf jt-ipam-offline-*.tar.gz
cd jt-ipam-offline

# 執行安裝程式（互動模式）
./install.sh
```

安裝程式 (`install.sh`) 會自動執行以下步驟：

| 步驟 | 說明 |
|------|------|
| 前置檢查 | 確認 `docker` 和 `docker compose` 可用 |
| 複製檔案 | 將所有安裝包檔案複製到安裝目錄 |
| 載入映像檔 | 執行 `docker load -i images.tar`（載入全部 4 個映像檔）|
| 設定環境 | 若 `.env` 不存在，自動產生隨機安全密鑰 |
| 啟動服務 | 詢問是否透過 `docker compose up -d --wait --timeout 120` 啟動 |

### 4.2 非互動安裝

```bash
# 指定安裝目錄（略過目錄詢問）
./install.sh -d /opt/jt-ipam
```

### 4.3 手動安裝（不使用 install.sh）

如果您想完全手動控制：

```bash
# 1. 建立安裝目錄
mkdir -p /opt/jt-ipam/backups
cp images.tar docker-compose.yml .env.example /opt/jt-ipam/
cp -r deploy/ scripts/ /opt/jt-ipam/

# 2. 載入映像檔
docker load -i /opt/jt-ipam/images.tar

# 3. 建立 .env（編輯填入您的密鑰）
cp /opt/jt-ipam/.env.example /opt/jt-ipam/.env
# 至少需要設定：
#   POSTGRES_PASSWORD、SECRET_KEY、ENCRYPTION_KEY
#   BOOTSTRAP_ADMIN_PASSWORD（≥ 12 個字元）

# 4. 啟動服務
cd /opt/jt-ipam
docker compose up -d --wait
```

### 4.4 第一次登入

服務啟動後（等待約 30 秒讓資料庫遷移完成）：

```
URL:      http://<主機IP>:8080
使用者:   admin
密碼:     <.env 中 BOOTSTRAP_ADMIN_PASSWORD 設定的值>
```

若密碼是由 `install.sh` 自動產生，請查看安裝輸出——它只會顯示一次。
您也可以隨時查看目前的 `.env`：

```bash
grep BOOTSTRAP_ADMIN_PASSWORD /opt/jt-ipam/.env
```

---

## 5. 備份

兩種方式：使用腳本（建議）或直接使用 compose 服務。

### 5.1 使用腳本（建議）

```bash
cd /opt/jt-ipam
bash scripts/docker-backup.sh
```

此腳本：
1. 執行 `backup` compose 服務（使用 `--name` 保留容器）
2. 透過 `docker cp` 將備份檔案從容器複製到 `./backups/`
3. 移除暫時容器

**產出物**（在 `./backups/` 目錄下）：

| 檔案 | 說明 |
|------|------|
| `jt-ipam-<YYYYMMDD_HHMMSS>.sql.gz` | PostgreSQL 資料庫備份（pg_dump \| gzip）|
| `jt-ipam-<YYYYMMDD_HHMMSS>.uploads.tar.gz` | 上傳檔案（平面圖、機櫃圖）|

建議同時備份 `.env` 檔案：

```bash
cp .env backups/jt-ipam-<TIMESTAMP>.env
```

### 5.2 直接使用 compose 服務

```bash
cd /opt/jt-ipam

# 建立備份（Docker 29.x 需使用 bind-mount 解決方案）
docker compose run --name backup-tmp backup
docker cp backup-tmp:/backups/. ./backups/
docker rm backup-tmp

# 驗證最新備份
docker compose run --rm backup-verify
```

### 5.3 排程定期備份

加入 cron 排程（使用 root 或有 docker 權限的使用者）：

```cron
# 每天凌晨 2 點
0 2 * * * cd /opt/jt-ipam && bash scripts/docker-backup.sh >> /var/log/jt-ipam-backup.log 2>&1
```

### 5.4 跨主機遷移

```bash
# 來源主機：建立備份
bash scripts/docker-backup.sh

# 複製到目標主機
scp ./backups/jt-ipam-<ts>* target-host:/opt/jt-ipam/backups/

# 目標主機：還原（見 §6）
cp /opt/jt-ipam/backups/jt-ipam-<ts>.env /opt/jt-ipam/.env
bash scripts/docker-restore.sh <ts>
```

---

## 6. 還原

### 6.1 使用腳本（建議）

```bash
cd /opt/jt-ipam

# 列出可用備份
bash scripts/docker-restore.sh

# 還原最新備份
bash scripts/docker-restore.sh latest

# 還原特定備份
bash scripts/docker-restore.sh 20260619_141141
```

此腳本：
1. 中斷 `jt_ipam` 資料庫的現有連線
2. 執行 `restore` compose 服務（刪除 + 重建資料庫、匯入 SQL、重建擴充、還原上傳檔案）
3. 重新啟動 backend 容器
4. 等待 backend 恢復健康狀態

> **警告：** 還原操作會**刪除**目前的資料庫並以備份內容取代。
> 執行還原前，服務堆疊必須正在執行（`docker compose up -d`）。

### 6.2 直接使用 compose 服務

```bash
cd /opt/jt-ipam

# 中斷資料庫連線
docker compose exec -T postgres psql -U jt_ipam -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='jt_ipam' AND pid <> pg_backend_pid();"

# 執行還原
docker compose run --rm -e BACKUP_FILE=20260619_141141 restore

# 重新啟動 backend
docker compose restart backend
```

### 6.3 驗證備份完整性

```bash
docker compose run --rm backup-verify

# 或驗證特定檔案
docker compose run --rm -e BACKUP_FILE=20260619_141141 backup-verify
```

---

## 7. 升級

升級既有的離線安裝，指的是將**新的離線安裝包**（包含更新的映像檔以及可能異動的 `docker-compose.yml`）
套用到正在執行的服務堆疊上。

### 7.1 升級流程

```bash
# 1.（建議但非必要）先備份
cd /opt/jt-ipam
bash scripts/docker-backup.sh
cp .env backups/jt-ipam-$(date +%Y%m%d_%H%M%S).env

# 2. 解壓縮新的安裝包
tar xzf /path/to/new/jt-ipam-offline-*.tar.gz
cd jt-ipam-offline

# 3. 載入更新的映像檔（覆蓋既有標籤）
docker load -i images.tar

# 4. 複製新的 docker-compose.yml
cp docker-compose.yml /opt/jt-ipam/docker-compose.yml

# 5.（選擇性）若腳本有更新，同步 helper 腳本
cp scripts/docker-backup.sh scripts/docker-restore.sh /opt/jt-ipam/scripts/

# 6. 使用新映像檔重建所有服務
cd /opt/jt-ipam
docker compose up -d --force-recreate

# 7. 驗證
docker compose ps
docker compose logs --tail 10 sync
```

### 7.2 `--force-recreate` 的作用

| 服務 | 行為 |
|------|------|
| `postgres` | 重建（`pgdata` volume 內的資料保留）|
| `redis` | 重建（`redis-data` volume 內的資料保留）|
| `backend` | 以新映像檔重建，啟動時自動執行 Alembic 遷移 |
| `frontend` | 以新映像檔重建 |
| `sync` | 若為新版新增的服務則建立；否則重建 |

### 7.3 哪些資料會被保留

| 資料 | 位置 | 安全？ |
|------|------|--------|
| PostgreSQL 資料 | `pgdata` volume（Docker） | ✅ 是 — volume 不會被移除 |
| Redis 資料 | `redis-data` volume（Docker） | ✅ 是 — volume 不會被移除 |
| 上傳檔案 | `uploads` volume（Docker） | ✅ 是 — volume 不會被移除 |
| `.env` 密鑰 | 主機上的檔案 | ✅ 是 — 不會被覆寫 |
| 備份檔案 | `./backups/` 目錄 | ✅ 是 — 不會被更動 |

### 7.4 升級後檢查事項

1. **資料庫遷移**：檢查 backend 日誌中的 Alembic 遷移輸出
   ```bash
   docker compose logs backend | grep -i alembic
   ```

2. **Sync 服務**：確認同步循環正常執行
   ```bash
   docker compose logs --tail 5 sync
   # 預期輸出："[sync] cycle start: ..."
   ```

3. **健康狀態**：所有服務應顯示 `(healthy)` 或 `(started)`
   ```bash
   docker compose ps
   ```

4. **功能測試**：登入網頁介面驗證核心功能

### 7.5 使用新版 install.sh 進行升級

新版本的 `install.sh` 也可當作升級工具使用，但需注意以下事項：

```bash
./install.sh -d /opt/jt-ipam
```

| 會發生什麼事 | 沒問題嗎？ |
|-------------|-----------|
| `docker-compose.yml` 被覆寫 | ✅ 需要，才能取得新服務定義 |
| `images.tar` 被載入 | ✅ 新標籤會覆蓋舊標籤 |
| `.env` 被保留（已存在） | ✅ 密鑰不會遺失 |
| `scripts/` 被覆寫 | ✅ 除非您曾自訂過這些腳本 |
| `docker compose up -d --wait --timeout 120` | ⚠️ — 不會 `--force-recreate`；正在執行的容器仍使用舊映像檔；且即使搭配 `-d` 仍會互動詢問「是否啟動」，無法全自動化 |

若使用 `install.sh` 升級，請務必額外執行：

```bash
cd /opt/jt-ipam
docker compose up -d --force-recreate
```

---

## 附錄 A：環境變數

`.env` 中的重要變數（完整列表請見 [`.env.docker.example`](../.env.docker.example)）：

| 變數 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `POSTGRES_PASSWORD` | 是 | — | Postgres 超級使用者密碼 |
| `SECRET_KEY` | 是 | — | JWT 簽章金鑰（`openssl rand -hex 32`）|
| `ENCRYPTION_KEY` | 是 | — | AES-256-GCM 金鑰（`openssl rand -base64 32`）|
| `AUDIT_CHAIN_GENESIS` | 是 | — | 稽核鏈創世雜湊（`openssl rand -hex 64`）|
| `BOOTSTRAP_ADMIN_USERNAME` | 否 | `admin` | 初始管理員帳號 |
| `BOOTSTRAP_ADMIN_PASSWORD` | 是* | — | *初次啟動自動建立管理員時必填 |
| `BOOTSTRAP_ADMIN_EMAIL` | 否 | `admin@example.com` | 初始管理員 Email |
| `APP_ENV` | 否 | `development` | 正式環境請設為 `production` |
| `APP_PUBLIC_URL` | 否 | — | 對外 URL（OIDC/CORS 需要）|
| `API_PUBLIC_URL` | 否 | — | 對外 API URL |
| `FRONTEND_PORT` | 否 | `8080` | 前端主機埠號 |
| `SYNC_INTERVAL_SECONDS` | 否 | `300` | 同步循環間隔（秒）|
| `BACKEND_TLS_MODE` | 否 | `docker-compose` | TLS 模式；Compose 環境必須設為 `docker-compose` |
| `RATE_LIMIT_ENABLED` | 否 | `true` | 啟用速率限制 |
| `OUTBOUND_ALLOW_PRIVATE` | 否 | `true` | 允許對外連線私有 IP（整合功能需要）|

## 附錄 B：故障排除

| 症狀 | 可能原因 | 解決方法 |
|------|---------|----------|
| `docker compose up -d` 失敗 | 埠號 8080 已被占用 | 修改 `.env` 中的 `FRONTEND_PORT` |
| Backend 啟動後未變健康 | 缺少環境變數 | 檢查 `.env` 是否包含所有必要值 |
| Sync 容器立即退出 | Backend 未就緒 | `depends_on` 確保 sync 會等待 backend 健康 |
| `docker load` 失敗 | images.tar 損毀 | 重新執行 `docker build` 後重新打包 |
| `ENCRYPTION_KEY` 錯誤 | 格式不正確 | 用 `openssl rand -base64 32` 重新產生 |
| `.env` 變更未生效 | Docker Compose 快取了環境變數 | 執行 `docker compose up -d --force-recreate` |

## 附錄 C：快速參考

```bash
# 打包
./scripts/build-docker-package.sh

# 安裝
tar xzf jt-ipam-offline-*.tar.gz && cd jt-ipam-offline && ./install.sh

# 備份
cd /opt/jt-ipam && bash scripts/docker-backup.sh

# 還原（列出）
bash scripts/docker-restore.sh
# 還原（最新）
bash scripts/docker-restore.sh latest

# 升級
docker load -i /path/to/new/images.tar
cp /path/to/new/docker-compose.yml /opt/jt-ipam/
cd /opt/jt-ipam && docker compose up -d --force-recreate
```

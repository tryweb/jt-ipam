#!/usr/bin/env bash
# jt-ipam 憑證派送代理（純 bash，相依只有 curl + coreutils，無 Python / jq / YAML）。
#
# 定期（或單次）向 jt-ipam 詢問「我負責的憑證有沒有新版」，有的話直接 curl 下載各段原始 PEM、
# 原子寫入站台、config-test 通過才 reload，失敗自動回滾，最後把結果回報給 jt-ipam。
#
# 設定檔（預設 /etc/jt-ipam-cert-agent/config，KEY=VALUE，由本腳本 source）：
#
#   SERVER=https://ipam.example.com
#   AGENT_KEY=<enrollment key>
#   VERIFY_TLS=true            # server 自簽時設 false，或用 CA_CERT 指定 CA
#   # CA_CERT=/etc/ssl/certs/ipam-ca.pem
#   AUTO_UPDATE=true           # server 有新版 agent 時自動更新自己
#   TLS_BASE=/etc/ssl/jt-ipam  # 一般 profile 預設寫入目錄
#   # 每個派送一行（DEPLOY_1, DEPLOY_2, ...），「;」分隔的 key=value（值可含空白）：
#   DEPLOY_1="cert=wildcard-example-com; profile=nginx"
#   DEPLOY_2="cert=mail-cert; profile=pmg"
#   # generic 需自訂路徑與 reload：
#   DEPLOY_3="cert=wildcard-example-com; profile=generic; fullchain_path=/etc/myapp/tls.crt; key_path=/etc/myapp/tls.key; reload=systemctl reload myapp"
#
# 用法：jt_ipam_cert_agent.sh [--config PATH] [--dry-run] [--version]
AGENT_VERSION=0.4.146

set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ARGS=("$@")
CONFIG=/etc/jt-ipam-cert-agent/config
STATE_DIR=/var/lib/jt-ipam-cert-agent
STATE_FILE="$STATE_DIR/state"
DRY_RUN=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --version) echo "$AGENT_VERSION"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "需要 curl" >&2; exit 2; }
[ -r "$CONFIG" ] || { echo "讀不到設定檔 $CONFIG" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONFIG"
: "${SERVER:?設定檔缺少 SERVER}"
: "${AGENT_KEY:?設定檔缺少 AGENT_KEY}"
VERIFY_TLS="${VERIFY_TLS:-true}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
TLS_BASE="${TLS_BASE:-/etc/ssl/jt-ipam}"
SERVER="${SERVER%/}"
API="$SERVER/api/v1/cert-agents"

CURL=(curl -fsS --max-time 30 -H "X-Agent-Key: $AGENT_KEY" -H "X-Agent-Version: $AGENT_VERSION")
[ "$VERIFY_TLS" = "false" ] && CURL+=(-k)
[ -n "${CA_CERT:-}" ] && CURL+=(--cacert "$CA_CERT")

# ─────────────────── 設定每個 profile 的檔案清單 + test + reload ───────────────────
# 輸出到全域：PFILES（每行 "kind|path|mode"）、PTEST、PRELOAD、PSPECIAL
profile_spec() {
  local profile="$1" cert="$2" base="$3"
  PFILES=""; PTEST=""; PRELOAD=""; PSPECIAL=""
  case "$profile" in
    nginx)
      PFILES="fullchain|$base/$cert.fullchain.pem|644
key|$base/$cert.key|600"
      PTEST="nginx -t"; PRELOAD="systemctl reload nginx" ;;
    apache)
      PFILES="cert|$base/$cert.crt|644
chain|$base/$cert.chain.pem|644
key|$base/$cert.key|600"
      PTEST="apachectl configtest 2>/dev/null || httpd -t"
      PRELOAD="systemctl reload apache2 2>/dev/null || systemctl reload httpd" ;;
    haproxy)
      PFILES="combined|$base/$cert.pem|600"
      PTEST="haproxy -c -f /etc/haproxy/haproxy.cfg"; PRELOAD="systemctl reload haproxy" ;;
    pve)
      PFILES="fullchain|/etc/pve/local/pveproxy-ssl.pem|640
key|/etc/pve/local/pveproxy-ssl.key|600"
      PRELOAD="systemctl restart pveproxy" ;;
    pmg)
      PFILES="combined|/etc/pmg/pmg-api.pem|600"
      PRELOAD="systemctl restart pmgproxy" ;;
    pbs)
      PFILES="fullchain|/etc/proxmox-backup/proxy.pem|640
key|/etc/proxmox-backup/proxy.key|600"
      PRELOAD="systemctl reload proxmox-backup-proxy" ;;
    postfix)
      PFILES="fullchain|$base/$cert.fullchain.pem|644
key|$base/$cert.key|600"
      PRELOAD="systemctl reload postfix" ;;
    dovecot)
      PFILES="fullchain|$base/$cert.fullchain.pem|644
key|$base/$cert.key|600"
      PRELOAD="systemctl reload dovecot" ;;
    zimbra)
      PSPECIAL="zimbra" ;;
    generic)
      : ;;  # 全靠 config 覆寫
    *)
      return 1 ;;
  esac
  return 0
}

# 下載某段原始 PEM 到檔案；成功回 0
fetch_part() {
  local cert="$1" part="$2" dest="$3"
  "${CURL[@]}" -G --data-urlencode "cert=$cert" --data-urlencode "part=$part" \
    -o "$dest" "$API/bundle/raw" 2>/dev/null
}

# ─────────────────── 套用單一 deployment ───────────────────
# 全域 REPORT_LINES 累積 TSV：cert\tprofile\tstatus\tfingerprint\tnot_after\tdry_run\tmessage
REPORT_LINES=()
add_report() {  # cert profile status fp not_after message
  local msg="${6:-}"
  msg="${msg//$'\t'/ }"; msg="${msg//$'\n'/ }"
  REPORT_LINES+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$DRY_RUN" "$msg")")
}

apply_deployment() {  # cert profile fp not_after  + 透過 DCONF 取得覆寫
  local cert="$1" profile="$2" fp="$3" na="$4"
  local base="$TLS_BASE"
  if ! profile_spec "$profile" "$cert" "$base"; then
    log "[$cert/$profile] 未知 profile"; add_report "$cert" "$profile" failed "$fp" "$na" "未知 profile"; return 1
  fi

  # config 覆寫：reload / test / <kind>_path
  [ -n "${D_reload:-}" ] && PRELOAD="$D_reload"
  [ -n "${D_test:-}" ] && PTEST="$D_test"
  local files="$PFILES" line kind path mode
  # 覆寫各 kind 的路徑（generic 也靠這些）
  local newfiles="" ov
  if [ -n "$files" ]; then
    while IFS='|' read -r kind path mode; do
      [ -z "$kind" ] && continue
      ov="D_${kind}_path"
      [ -n "${!ov:-}" ] && path="${!ov}"
      newfiles+="$kind|$path|$mode"$'\n'
    done <<< "$files"
  fi
  # generic / 覆寫補進未在 profile 預設的 kind
  for kind in cert key chain fullchain combined; do
    ov="D_${kind}_path"
    if [ -n "${!ov:-}" ] && ! printf '%s' "$newfiles" | grep -q "^$kind|"; then
      local m=644; [ "$kind" = key ] || [ "$kind" = combined ] && m=600
      newfiles+="$kind|${!ov}|$m"$'\n'
    fi
  done
  files="$(printf '%s' "$newfiles")"

  if [ "$profile" = generic ] && [ -z "$files" ]; then
    log "[$cert/$profile] generic 未指定任何 *_path"; add_report "$cert" "$profile" failed "$fp" "$na" "generic 未指定路徑"; return 1
  fi

  # dry-run：只印計畫
  if [ "$DRY_RUN" = 1 ]; then
    log "[$cert/$profile] (dry-run) 會寫："
    while IFS='|' read -r kind path mode; do [ -n "$kind" ] && log "    $kind -> $path ($mode)"; done <<< "$files"
    [ -n "$PRELOAD" ] && log "    reload: $PRELOAD"
    add_report "$cert" "$profile" dry-run "$fp" "$na" "計畫套用"
    return 0
  fi

  # 下載 + 安裝（原子 + 備份，失敗回滾）
  local tmpd; tmpd="$(mktemp -d)"; local -a written=() backed=()
  rollback() {
    local p
    for p in "${written[@]}"; do rm -f "$p"; done
    for p in "${backed[@]}"; do mv -f "$p.jtbak" "$p" 2>/dev/null; done
  }
  while IFS='|' read -r kind path mode; do
    [ -z "$kind" ] && continue
    if ! fetch_part "$cert" "$kind" "$tmpd/f"; then
      log "[$cert/$profile] 下載 $kind 失敗"; rollback; rm -rf "$tmpd"
      add_report "$cert" "$profile" failed "$fp" "$na" "下載 $kind 失敗"; return 1
    fi
    mkdir -p "$(dirname "$path")"
    if [ -e "$path" ]; then cp -p "$path" "$path.jtbak"; backed+=("$path"); else written+=("$path"); fi
    install -m "$mode" "$tmpd/f" "$path"
  done <<< "$files"
  rm -rf "$tmpd"

  # config-test
  if [ -n "$PTEST" ] && ! eval "$PTEST" >/dev/null 2>&1; then
    log "[$cert/$profile] config-test 失敗 → 回滾"; rollback
    add_report "$cert" "$profile" failed "$fp" "$na" "config-test 失敗"; return 1
  fi
  # reload
  if [ -n "$PRELOAD" ] && ! eval "$PRELOAD" >/dev/null 2>&1; then
    log "[$cert/$profile] reload 失敗 → 回滾"; rollback
    add_report "$cert" "$profile" failed "$fp" "$na" "reload 失敗"; return 1
  fi
  # 成功 → 清備份
  local p; for p in "${backed[@]}"; do rm -f "$p.jtbak"; done
  log "[$cert/$profile] 已套用（${fp:0:12}…）"
  add_report "$cert" "$profile" ok "$fp" "$na" "已套用"
  return 0
}

# ─────────────────── 自我更新 ───────────────────
self_update() {
  local server_sha="$1"
  [ "$AUTO_UPDATE" = "false" ] && return 0
  [ -z "$server_sha" ] && return 0
  command -v sha256sum >/dev/null 2>&1 || return 0
  local self_sha; self_sha="$(sha256sum "$SELF" | cut -d' ' -f1)"
  [ "$server_sha" = "$self_sha" ] && return 0
  log "[update] server 有新版派送代理，下載更新中…"
  local tmp="$SELF.new"
  if "${CURL[@]}" -o "$tmp" "$API/agent.sh" 2>/dev/null; then
    local new_sha; new_sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
    if [ "$new_sha" = "$server_sha" ]; then
      chmod 0755 "$tmp"; mv -f "$tmp" "$SELF"
      log "[update] 已更新，以新版重新執行"
      exec "$SELF" "${ARGS[@]}"
    fi
    log "[update] 下載內容 sha 不符，本輪略過"; rm -f "$tmp"
  fi
}

# ─────────────────── 主流程 ───────────────────
mkdir -p "$STATE_DIR"; touch "$STATE_FILE"
CHECK="$(mktemp)"
if ! "${CURL[@]}" -o "$CHECK" "$API/check?format=text" 2>/dev/null; then
  log "check 失敗（連不上 $SERVER）"; rm -f "$CHECK"; exit 1
fi
SERVER_SHA="$(awk -F= '/^agent_sha=/{print $2}' "$CHECK")"
self_update "$SERVER_SHA"

state_fp() { awk -F'\t' -v c="$1" -v p="$2" '$1==c && $2==p{print $3}' "$STATE_FILE"; }
set_state() {  # cert profile fp
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v c="$1" -v p="$2" '!($1==c && $2==p)' "$STATE_FILE" > "$tmp"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$tmp"; mv -f "$tmp" "$STATE_FILE"
}

FAILED=0; n=1
while :; do
  var="DEPLOY_$n"; spec="${!var:-}"; [ -z "$spec" ] && break
  n=$((n+1))
  # 解析「;」分隔的 key=value（值可含空白，如 reload=systemctl reload x）。清掉舊的 D_*。
  unset "${!D_@}" 2>/dev/null || true
  cert=""; profile="generic"
  IFS=';' read -ra _pairs <<< "$spec"
  for kv in "${_pairs[@]}"; do
    kv="${kv#"${kv%%[![:space:]]*}"}"; kv="${kv%"${kv##*[![:space:]]}"}"  # trim
    [ -z "$kv" ] && continue
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      cert) cert="$v" ;;
      profile) profile="$v" ;;
      *) printf -v "D_$k" '%s' "$v" ;;
    esac
  done
  [ -z "$cert" ] && { log "DEPLOY_$((n-1)) 缺少 cert，略過"; continue; }
  # 從 check 找此憑證目前指紋
  fp="$(awk -F'\t' -v c="$cert" '$1==c{print $2}' "$CHECK")"
  na="$(awk -F'\t' -v c="$cert" '$1==c{print $3}' "$CHECK")"
  if [ -z "$fp" ]; then
    log "[$cert/$profile] server 上找不到此憑證或不在 scope，略過"
    add_report "$cert" "$profile" skipped "" "" "不在 scope / 無目前版本"; continue
  fi
  if [ "$DRY_RUN" != 1 ] && [ "$(state_fp "$cert" "$profile")" = "$fp" ]; then
    log "[$cert/$profile] 已是最新（${fp:0:12}…），略過"; continue
  fi
  if apply_deployment "$cert" "$profile" "$fp" "$na"; then
    [ "$DRY_RUN" != 1 ] && set_state "$cert" "$profile" "$fp"
  else
    FAILED=1
  fi
done
rm -f "$CHECK"

# 回報（TSV，不影響部署成敗）
if [ "${#REPORT_LINES[@]}" -gt 0 ]; then
  printf '%s\n' "${REPORT_LINES[@]}" | \
    "${CURL[@]}" -X POST -H "Content-Type: text/plain" --data-binary @- "$API/report" >/dev/null 2>&1 \
    || log "report 失敗（不影響部署）"
fi
exit "$FAILED"

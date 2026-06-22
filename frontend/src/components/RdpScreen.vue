<script setup lang="ts">
/**
 * RDP 畫面（原生 canvas）。先換 ticket → 開 WebSocket → 橋接後端 aardwolf。
 * 後端把畫面以 PNG tile 串流過來畫到 canvas；鍵鼠/滾輪事件回送。
 * 帳密只在連線時送出，前端不保存（或選已存帳密以 reference 連線）。
 */
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref } from "vue";
import { useI18n } from "vue-i18n";
import {
  NForm, NFormItem, NInput, NButton, NSpace, NAlert, NIcon, NSpin, NTag,
  NSelect, NSwitch, NPopconfirm, NCard, useMessage,
} from "naive-ui";
import {
  requestRdpTicket, buildRdpWsUrl,
  listRdpCredentials, createRdpCredential, deleteRdpCredential, type RdpCredential,
} from "@/api/rdp";
import { DisplayIcon, CancelIcon, RefreshIcon, DeleteIcon } from "@/icons";

const props = withDefaults(defineProps<{
  addressId: string;
  ip: string;
  hostname?: string | null;
  deviceName?: string | null;
  fullHeight?: boolean;
}>(), { fullHeight: false, hostname: null, deviceName: null });

const { t } = useI18n();
const msg = useMessage();

// 解析度選項（auto = 依目前視窗大小）
const resOptions = computed(() => [
  { label: t("rdp.res_auto"), value: "auto" },
  { label: "1280 × 800", value: "1280x800" },
  { label: "1366 × 768", value: "1366x768" },
  { label: "1600 × 900", value: "1600x900" },
  { label: "1920 × 1080", value: "1920x1080" },
]);
// 依 auto/固定值決定要送給後端的畫面尺寸（後端會再 clamp 到 640–2560）
function resolveSize(): [number, number] {
  if (form.resolution === "auto") {
    // 量測實際 canvas 容器（full-height 模式下 flex 填滿剩餘空間）→ 完全吻合、無捲軸
    const box = canvasBoxEl.value;
    const w = Math.max(640, Math.min(2560, Math.floor(box?.clientWidth || (window.innerWidth - 24))));
    const h = Math.max(480, Math.min(2560, Math.floor(box?.clientHeight || (window.innerHeight - 80))));
    return [w, h];
  }
  const [w, h] = form.resolution.split("x").map((n) => parseInt(n, 10));
  return [w, h];
}

// 已存帳密（by-user，RDP）
const savedCreds = ref<RdpCredential[]>([]);
const selectedCredId = ref<string | null>(null);
const remember = ref(false);
const rememberLabel = ref("");
const credOptions = ref<{ label: string; value: string }[]>([]);

async function loadCreds() {
  try {
    savedCreds.value = await listRdpCredentials(props.addressId);
    credOptions.value = savedCreds.value.map((c) => ({
      label: `${c.label}（${c.domain ? c.domain + "\\" : ""}${c.username}）`,
      value: c.id,
    }));
    if (!selectedCredId.value && savedCreds.value.length) {
      selectedCredId.value = savedCreds.value[0].id;
    }
  } catch { /* 靜默 */ }
}
async function delSelectedCred() {
  if (!selectedCredId.value) return;
  try {
    await deleteRdpCredential(selectedCredId.value);
    selectedCredId.value = null;
    await loadCreds();
    msg.success(t("common.ok"));
  } catch { msg.error(t("errors.server")); }
}
onMounted(loadCreds);

type Phase = "form" | "connecting" | "connected" | "closed" | "error";
const phase = ref<Phase>("form");
const errorMsg = ref("");

const form = reactive({
  username: "",
  password: "",
  domain: "",
  resolution: "auto",
});

const canvasEl = ref<HTMLCanvasElement | null>(null);
const canvasBoxEl = ref<HTMLElement | null>(null);
let ctx: CanvasRenderingContext2D | null = null;
let ws: WebSocket | null = null;
// heartbeat：每 20s 送 ping；45s 內沒收到任何訊息（含 pong）→ 判定斷線
let pingTimer: ReturnType<typeof setInterval> | null = null;
let watchdogTimer: ReturnType<typeof setInterval> | null = null;
let lastRecv = 0;
let lastMove = 0;
const PING_MS = 20_000;
const DEAD_MS = 45_000;
const MOVE_THROTTLE = 30;

function wsSend(obj: Record<string, unknown>) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function stopHeartbeat() {
  if (pingTimer) { clearInterval(pingTimer); pingTimer = null; }
  if (watchdogTimer) { clearInterval(watchdogTimer); watchdogTimer = null; }
}
function startHeartbeat() {
  stopHeartbeat();
  lastRecv = Date.now();
  pingTimer = setInterval(() => wsSend({ type: "ping" }), PING_MS);
  watchdogTimer = setInterval(() => {
    if (phase.value === "connected" && Date.now() - lastRecv > DEAD_MS) {
      teardown();
      phase.value = "closed";
    }
  }, 5_000);
}

function teardown() {
  stopHeartbeat();
  try { ws?.close(); } catch { /* noop */ }
  ws = null;
}

// ── 輸入事件 → 後端 ──
const BMAP: Record<number, number> = { 0: 0, 2: 1, 1: 2 }; // 瀏覽器 button → RDP（左/右/中）
function onMouseMove(e: MouseEvent) {
  const now = Date.now();
  if (now - lastMove < MOVE_THROTTLE) return;
  lastMove = now;
  wsSend({ type: "m", move: true, x: e.offsetX, y: e.offsetY });
}
function onMouseDown(e: MouseEvent) {
  e.preventDefault();
  canvasEl.value?.focus();
  wsSend({ type: "m", b: BMAP[e.button] ?? 0, p: true, x: e.offsetX, y: e.offsetY });
}
function onMouseUp(e: MouseEvent) {
  e.preventDefault();
  wsSend({ type: "m", b: BMAP[e.button] ?? 0, p: false, x: e.offsetX, y: e.offsetY });
}
function onWheel(e: WheelEvent) {
  e.preventDefault();
  wsSend({ type: "m", wheel: true, dir: e.deltaY < 0 ? 1 : -1, x: e.offsetX, y: e.offsetY });
}
function onKey(e: KeyboardEvent, pressed: boolean) {
  e.preventDefault();
  wsSend({ type: "k", key: e.key, ch: e.key && e.key.length === 1 ? e.key : "", p: pressed });
}

async function connect() {
  errorMsg.value = "";
  if (!selectedCredId.value && !form.username.trim()) { errorMsg.value = t("rdp.err_username"); return; }
  phase.value = "connecting";

  let credId: string | null = selectedCredId.value;
  if (!credId && remember.value) {
    try {
      const saved = await createRdpCredential({
        label: rememberLabel.value.trim() || `${form.username.trim()}@${props.ip}`,
        username: form.username.trim(),
        domain: form.domain.trim() || null,
        target_ip_id: props.addressId,
        password: form.password,
      });
      credId = saved.id;
    } catch (e: any) {
      phase.value = "error";
      errorMsg.value = e?.response?.data?.detail || t("rdp.err_save_cred");
      return;
    }
  }

  let ticket;
  try {
    ticket = await requestRdpTicket(props.addressId);
  } catch (e: any) {
    phase.value = "error";
    errorMsg.value = e?.response?.data?.detail || t("rdp.err_ticket");
    return;
  }

  await nextTick();
  if (!canvasEl.value) { phase.value = "error"; errorMsg.value = t("rdp.err_ticket"); return; }
  const [w, h] = resolveSize();   // 在 nextTick 後量測容器（auto 才能對齊實際可用空間）
  canvasEl.value.width = w;
  canvasEl.value.height = h;
  ctx = canvasEl.value.getContext("2d");

  ws = new WebSocket(buildRdpWsUrl(ticket.ws_path, ticket.ticket));
  ws.onopen = () => {
    if (credId) {
      wsSend({ type: "config", credential_id: credId, width: w, height: h });
    } else {
      wsSend({
        type: "config",
        username: form.username.trim(),
        password: form.password,
        domain: form.domain.trim() || undefined,
        width: w, height: h,
      });
    }
    form.password = "";  // 送出即清空
    startHeartbeat();
  };
  ws.onmessage = (ev) => {
    lastRecv = Date.now();
    let payload: any;
    try { payload = JSON.parse(ev.data); } catch { return; }
    switch (payload.type) {
      case "pong": break;
      case "img": {
        const im = new Image();
        im.onload = () => ctx?.drawImage(im, payload.x, payload.y);
        im.src = "data:image/png;base64," + payload.d;
        break;
      }
      case "status":
        if (payload.state === "connected") { phase.value = "connected"; nextTick(() => canvasEl.value?.focus()); }
        else if (payload.state === "disconnected") phase.value = "closed";
        break;
      case "error":
        phase.value = "error";
        errorMsg.value = payload.message || payload.code || t("rdp.err_generic");
        break;
    }
  };
  ws.onclose = () => { if (phase.value !== "error") phase.value = "closed"; };
  ws.onerror = () => {
    if (phase.value !== "error" && phase.value !== "connected") {
      phase.value = "error";
      errorMsg.value = t("rdp.err_ws");
    }
  };
}

function disconnect() {
  wsSend({ type: "close" });
  teardown();
  phase.value = "closed";
}
function backToForm() {
  teardown();
  phase.value = "form";
}

onBeforeUnmount(teardown);
</script>

<template>
  <div class="rdp-wrap" :class="{ 'rdp-full': fullHeight, 'rdp-center': fullHeight && phase === 'form' }">
    <!-- 連線設定表單 -->
    <div v-if="phase === 'form'" class="rdp-form">
      <n-card size="small" :bordered="true">
        <template #header>
          <span style="display:flex;align-items:center;gap:8px">
            <n-icon :component="DisplayIcon" :size="18" />
            <span>{{ t("rdp.connect_to", { ip }) }}</span>
            <n-tag size="small" type="warning" :bordered="false" round>{{ t("rdp.beta") }}</n-tag>
          </span>
        </template>
        <n-alert :show-icon="true" type="warning" :bordered="false" style="margin-bottom:12px">
          {{ t("rdp.beta_hint") }}
        </n-alert>
        <!-- 已存帳密 -->
        <div v-if="credOptions.length" class="rdp-saved-row">
          <span class="rdp-saved-label">{{ t("rdp.saved_cred") }}</span>
          <n-select v-model:value="selectedCredId" :options="credOptions" clearable size="small"
                    :placeholder="t('rdp.saved_cred_ph')" style="flex:1" />
          <n-popconfirm v-if="selectedCredId" @positive-click="delSelectedCred">
            <template #trigger>
              <n-button quaternary type="error" size="small">
                <template #icon><n-icon :component="DeleteIcon" /></template>
              </n-button>
            </template>
            {{ t("rdp.saved_cred_del_confirm") }}
          </n-popconfirm>
        </div>

        <n-form label-placement="left" :label-width="92" size="small">
          <template v-if="!selectedCredId">
            <n-form-item :label="t('rdp.username')">
              <n-input v-model:value="form.username" placeholder="Administrator" autofocus
                       @keyup.enter="connect" />
            </n-form-item>
            <n-form-item :label="t('rdp.password')">
              <n-input v-model:value="form.password" type="password" show-password-on="click"
                       @keyup.enter="connect" />
            </n-form-item>
            <n-form-item :label="t('rdp.domain')">
              <n-input v-model:value="form.domain" :placeholder="t('rdp.domain_ph')"
                       @keyup.enter="connect" />
            </n-form-item>
          </template>

          <n-form-item :label="t('rdp.resolution')">
            <n-select v-model:value="form.resolution" :options="resOptions"
                      :consistent-menu-width="false" style="width:180px" />
          </n-form-item>

          <n-form-item v-if="!selectedCredId" :label="t('rdp.remember')">
            <n-space vertical :size="4" style="width:100%">
              <n-switch v-model:value="remember" />
              <n-input v-if="remember" v-model:value="rememberLabel" size="small"
                       :placeholder="t('rdp.remember_label_ph')" />
            </n-space>
          </n-form-item>

          <n-alert :show-icon="false" type="info" style="margin-bottom:10px">
            {{ selectedCredId ? t("rdp.use_saved_hint") : (remember ? t("rdp.store_hint") : t("rdp.no_store_hint")) }}
          </n-alert>
          <n-space justify="end">
            <n-button type="primary" @click="connect">
              <template #icon><n-icon :component="DisplayIcon" /></template>
              {{ t("rdp.connect") }}
            </n-button>
          </n-space>
        </n-form>
      </n-card>
    </div>

    <!-- 畫面 -->
    <div v-show="phase !== 'form'" class="rdp-screen-area" :class="{ 'rdp-full': fullHeight }">
      <div class="rdp-toolbar">
        <span class="rdp-status" :data-state="phase">
          <n-spin v-if="phase === 'connecting'" :size="12" />
          <span v-else class="rdp-dot" />
          <span>{{ t(`rdp.state_${phase}`) }}</span>
          <span class="rdp-ip">{{ ip }}</span>
          <n-tag v-if="hostname" size="small" :bordered="false" round>{{ hostname }}</n-tag>
          <n-tag v-if="deviceName" size="small" type="info" :bordered="false" round>{{ deviceName }}</n-tag>
          <n-tag size="small" type="warning" :bordered="false" round>{{ t("rdp.beta") }}</n-tag>
        </span>
        <n-space :size="8" align="center">
          <n-button v-if="phase === 'connected'" size="tiny" type="error" ghost @click="disconnect">
            <template #icon><n-icon :component="CancelIcon" /></template>{{ t("rdp.disconnect") }}
          </n-button>
          <n-button v-if="phase === 'closed' || phase === 'error'" size="tiny" @click="backToForm">
            <template #icon><n-icon :component="RefreshIcon" /></template>{{ t("rdp.reconnect") }}
          </n-button>
        </n-space>
      </div>
      <n-alert v-if="phase === 'error'" type="error" :show-icon="true" style="margin:8px 0">
        {{ errorMsg }}
      </n-alert>
      <div ref="canvasBoxEl" class="rdp-canvas-box" :class="{ 'rdp-full': fullHeight }">
        <canvas ref="canvasEl" class="rdp-canvas" tabindex="0"
                @mousemove="onMouseMove" @mousedown="onMouseDown" @mouseup="onMouseUp"
                @wheel.prevent="onWheel" @contextmenu.prevent
                @keydown="onKey($event, true)" @keyup="onKey($event, false)" />
      </div>
    </div>
  </div>
</template>

<style scoped>
.rdp-wrap { width: 100%; }
.rdp-wrap.rdp-full { height: 100%; display: flex; flex-direction: column; }
.rdp-wrap.rdp-center { justify-content: center; align-items: center; }
.rdp-wrap.rdp-center .rdp-form { width: 560px; max-width: 92vw; }
.rdp-form { max-width: 560px; }
.rdp-screen-area { display: flex; flex-direction: column; }
.rdp-screen-area.rdp-full { flex: 1; min-height: 0; }
.rdp-toolbar { display: flex; justify-content: space-between; align-items: center; padding: 4px 2px; gap: 8px; }
.rdp-status { font-size: 13px; display: inline-flex; align-items: center; gap: 7px;
  padding: 3px 11px; border-radius: 999px; font-weight: 500;
  background: rgba(128, 128, 128, .12); color: #888; }
.rdp-dot { width: 8px; height: 8px; border-radius: 50%; background: currentColor; flex: none; }
.rdp-ip { opacity: .7; font-variant-numeric: tabular-nums; }
.rdp-status[data-state="connected"] { color: #18a058; background: rgba(24, 160, 88, .14); }
.rdp-status[data-state="connected"] .rdp-dot { animation: rdp-pulse 1.8s infinite; }
.rdp-status[data-state="connecting"] { color: #d99812; background: rgba(217, 152, 18, .14); }
.rdp-status[data-state="error"] { color: #d03050; background: rgba(208, 48, 80, .14); }
.rdp-status[data-state="closed"] { color: #888; background: rgba(128, 128, 128, .14); }
@keyframes rdp-pulse {
  0%   { box-shadow: 0 0 0 0 rgba(24, 160, 88, .5); }
  70%  { box-shadow: 0 0 0 6px rgba(24, 160, 88, 0); }
  100% { box-shadow: 0 0 0 0 rgba(24, 160, 88, 0); }
}
.rdp-canvas-box { background: #000; padding: 0; border-radius: 8px; border: 1px solid #2b2b30;
  box-shadow: 0 1px 3px rgba(0,0,0,.18); overflow: auto; display: inline-block; max-width: 100%; }
.rdp-canvas-box.rdp-full { flex: 1; min-height: 0; display: block; }
.rdp-canvas { display: block; outline: none; background: #000; }
/* 卡片標題 icon+文字垂直置中 */
:deep(.n-card > .n-card-header) { display: flex; align-items: center; padding-top: 12px; padding-bottom: 12px; }
/* 「已存帳密」列：flex 列，label 與下拉/刪除鈕保證同一行垂直置中 */
.rdp-saved-row { display: flex; align-items: center; margin-bottom: 18px; }
.rdp-saved-label { width: 92px; flex: none; box-sizing: border-box; text-align: right;
  padding-right: 12px; font-size: 14px; }
.rdp-saved-row :deep(.n-button) { margin-left: 6px; }
</style>

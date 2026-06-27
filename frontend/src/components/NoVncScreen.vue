<script setup lang="ts">
/**
 * PVE 主控台（noVNC / xterm）。連線時要求輸入 PVE 帳密（可選擇存進金庫，比照 ssh/rdp/vnc）；
 * kind=vm → @novnc/novnc 圖形 RFB；kind=ct → xterm.js + PVE term 協定。WS 走同站後端代理到 PVE。
 */
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from "vue";
import { useI18n } from "vue-i18n";
import {
  NSpin, NButton, NIcon, NSelect, NInput, NCheckbox, NAlert, NTag, useMessage,
} from "naive-ui";
import { LoginIcon, LogoutIcon } from "@/icons";
import {
  requestNovncTicket, buildNovncWsUrl, listPveCredentials, createPveCredential,
  deletePveCredential, type PveCredential,
} from "@/api/novnc";

const props = withDefaults(defineProps<{
  addressId: string;
  ip: string;
  hostname?: string | null;
  deviceName?: string | null;
  kind?: "vm" | "ct";
  fullHeight?: boolean;
}>(), { fullHeight: false, hostname: null, deviceName: null, kind: "vm" });

const { t } = useI18n();
const msg = useMessage();

type Phase = "idle" | "connecting" | "connected" | "error";
const phase = ref<Phase>("idle");
const errorMsg = ref("");

const form = ref({ username: "", password: "", realm: "pam" });
const realmOpts = [
  { label: "pam (Linux PAM)", value: "pam" }, { label: "pve (Proxmox VE)", value: "pve" },
  { label: "ad (Active Directory)", value: "ad" }, { label: "ldap (LDAP)", value: "ldap" },
];
const remember = ref(false);
const rememberLabel = ref("");
const savedCreds = ref<PveCredential[]>([]);
const selectedCredId = ref<string | null>(null);

const screenBox = ref<HTMLDivElement | null>(null);
let rfb: any = null;            // @novnc/novnc RFB（vm）
let ws: WebSocket | null = null; // xterm WS（ct）
let term: any = null;
let fitAddon: any = null;
let heartbeat: number | null = null;

const credOptions = computed(() => savedCreds.value.map((c) => ({
  label: `${c.label}（${c.username}）`, value: c.id,
})));

async function loadCreds() {
  try { savedCreds.value = await listPveCredentials(props.addressId); }
  catch { savedCreds.value = []; }
}
onMounted(loadCreds);

function cleanup() {
  if (heartbeat) { clearInterval(heartbeat); heartbeat = null; }
  if (rfb) { try { rfb.disconnect(); } catch { /* noop */ } rfb = null; }
  if (ws) { try { ws.close(); } catch { /* noop */ } ws = null; }
  if (term) { try { term.dispose(); } catch { /* noop */ } term = null; fitAddon = null; }
}
onBeforeUnmount(cleanup);

function utf8len(s: string): number {
  return new TextEncoder().encode(s).length;
}

async function connect() {
  errorMsg.value = "";
  phase.value = "connecting";

  // 可選擇記住帳密（存金庫 protocol='pve'）
  let credId: string | null = selectedCredId.value;
  if (!credId && remember.value) {
    try {
      const saved = await createPveCredential({
        label: rememberLabel.value.trim() || `pve@${props.ip}`,
        target_ip_id: props.addressId,
        username: `${form.value.username.trim()}@${form.value.realm}`.replace(/@.*@/, "@"),
        password: form.value.password,
      });
      credId = saved.id;
    } catch (e: any) {
      phase.value = "error";
      errorMsg.value = e?.response?.data?.detail || t("novnc.err_save_cred");
      return;
    }
  }

  let ticket;
  try {
    ticket = await requestNovncTicket(props.addressId, credId
      ? { credential_id: credId }
      : { username: form.value.username, password: form.value.password, realm: form.value.realm });
  } catch (e: any) {
    phase.value = "error";
    errorMsg.value = e?.response?.data?.detail || t("novnc.err_ticket");
    return;
  }
  form.value.password = "";  // 立即清掉

  const wsUrl = buildNovncWsUrl(ticket.ws_path, ticket.ticket);
  await nextTick();
  if (ticket.kind === "vm") await connectRfb(wsUrl, ticket.vnc_password);
  else await connectXterm(wsUrl, ticket.pve_user, ticket.vnc_password);
  if (selectedCredId.value || remember.value) void loadCreds();
}

async function connectRfb(wsUrl: string, password: string) {
  try {
    const RFB = (await import("@novnc/novnc")).default;
    if (screenBox.value) screenBox.value.innerHTML = "";
    rfb = new RFB(screenBox.value, wsUrl, { credentials: { password } });
    rfb.scaleViewport = true;
    rfb.background = "#000";
    rfb.addEventListener("connect", () => { phase.value = "connected"; });
    rfb.addEventListener("disconnect", (e: any) => {
      if (phase.value === "connected" && e?.detail?.clean) phase.value = "idle";
      else if (phase.value !== "idle") { phase.value = "error"; errorMsg.value = errorMsg.value || t("novnc.err_disconnected"); }
      cleanup();
    });
    rfb.addEventListener("securityfailure", (e: any) => {
      phase.value = "error"; errorMsg.value = e?.detail?.reason || t("novnc.err_auth");
    });
  } catch (e: any) {
    phase.value = "error"; errorMsg.value = e?.message || t("novnc.err_connect");
  }
}

async function connectXterm(wsUrl: string, pveUser: string, vncticket: string) {
  try {
    const [{ Terminal }, { FitAddon }] = await Promise.all([
      import("@xterm/xterm"), import("@xterm/addon-fit"),
    ]);
    await import("@xterm/xterm/css/xterm.css");
    term = new Terminal({ cursorBlink: true, fontSize: 13, theme: { background: "#000000" } });
    fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    if (screenBox.value) { screenBox.value.innerHTML = ""; term.open(screenBox.value); fitAddon.fit(); }

    ws = new WebSocket(wsUrl, "binary");
    ws.binaryType = "arraybuffer";
    const enc = new TextEncoder();
    let authed = false;
    ws.onopen = () => {
      // PVE term 協定：先送 "user:ticket\n" 認證
      ws!.send(enc.encode(`${pveUser}:${vncticket}\n`));
    };
    ws.onmessage = (ev) => {
      const buf = ev.data instanceof ArrayBuffer ? new Uint8Array(ev.data)
        : enc.encode(String(ev.data));
      if (!authed) {
        // 認證回應 "OK" → 進入終端機；之後直接寫資料
        authed = true;
        phase.value = "connected";
        const cols = term.cols, rows = term.rows;
        ws!.send(enc.encode(`1:${cols}:${rows}:`));
        term.onData((d: string) => ws?.send(enc.encode(`0:${utf8len(d)}:${d}`)));
        heartbeat = window.setInterval(() => { try { ws?.send(enc.encode("2")); } catch { /* noop */ } }, 30000);
        // 認證回應那一包通常是 "OK"，不寫進畫面
        return;
      }
      term.write(buf);
    };
    ws.onerror = () => { if (phase.value !== "connected") { phase.value = "error"; errorMsg.value = t("novnc.err_connect"); } };
    ws.onclose = () => { if (phase.value === "connected") phase.value = "idle"; cleanup(); };
    window.addEventListener("resize", onResize);
  } catch (e: any) {
    phase.value = "error"; errorMsg.value = e?.message || t("novnc.err_connect");
  }
}

function onResize() {
  if (fitAddon && term && ws && ws.readyState === 1) {
    fitAddon.fit();
    ws.send(new TextEncoder().encode(`1:${term.cols}:${term.rows}:`));
  }
}
onBeforeUnmount(() => window.removeEventListener("resize", onResize));

function disconnect() { phase.value = "idle"; errorMsg.value = ""; cleanup(); }

async function removeCred(id: string) {
  try { await deletePveCredential(id); await loadCreds(); if (selectedCredId.value === id) selectedCredId.value = null; }
  catch { msg.error(t("errors.network")); }
}
</script>

<template>
  <div class="nv-wrap" :class="{ 'nv-full': fullHeight }">
    <!-- 連線表單 -->
    <div v-if="phase === 'idle' || phase === 'error'" class="nv-form">
      <div class="nv-title">
        <n-tag size="small" type="warning" :bordered="false">PVE</n-tag>
        <n-tag size="small" :bordered="false">{{ kind === "vm" ? "noVNC" : "xterm" }}</n-tag>
        <span class="nv-target">{{ hostname || deviceName || ip }} · {{ ip }}</span>
      </div>
      <n-alert v-if="phase === 'error'" type="error" :show-icon="true" style="margin-bottom: 10px">
        {{ errorMsg }}
      </n-alert>
      <n-alert type="info" :show-icon="true" size="small" style="margin-bottom: 12px">
        {{ t("novnc.cred_hint") }}
      </n-alert>

      <div v-if="savedCreds.length" class="nv-row">
        <label>{{ t("novnc.saved_cred") }}</label>
        <div style="display:flex; gap:6px; width:100%">
          <n-select v-model:value="selectedCredId" :options="credOptions" clearable
                    :placeholder="t('novnc.use_typed')" style="flex:1" />
          <n-button v-if="selectedCredId" quaternary type="error" size="small"
                    @click="removeCred(selectedCredId)">{{ t("common.delete") }}</n-button>
        </div>
      </div>

      <template v-if="!selectedCredId">
        <div class="nv-row">
          <label>{{ t("novnc.username") }}</label>
          <n-input v-model:value="form.username" placeholder="root" />
        </div>
        <div class="nv-row">
          <label>{{ t("novnc.realm") }}</label>
          <n-select v-model:value="form.realm" :options="realmOpts" style="width: 220px" />
        </div>
        <div class="nv-row">
          <label>{{ t("novnc.password") }}</label>
          <n-input v-model:value="form.password" type="password" show-password-on="click"
                   @keyup.enter="connect" />
        </div>
        <div class="nv-row">
          <n-checkbox v-model:checked="remember">{{ t("novnc.remember") }}</n-checkbox>
          <n-input v-if="remember" v-model:value="rememberLabel" size="small"
                   :placeholder="t('novnc.remember_label')" style="max-width: 240px" />
        </div>
      </template>

      <n-button type="primary" :disabled="!selectedCredId && (!form.username || !form.password)"
                @click="connect" style="margin-top: 8px">
        <template #icon><n-icon><LoginIcon /></n-icon></template>{{ t("novnc.connect") }}
      </n-button>
    </div>

    <!-- 連線中 / 已連線 -->
    <div v-show="phase === 'connecting' || phase === 'connected'" class="nv-stage">
      <div class="nv-bar">
        <n-tag size="small" type="warning" :bordered="false">PVE</n-tag>
        <n-tag size="small" :bordered="false">{{ kind === "vm" ? "noVNC" : "xterm" }}</n-tag>
        <span class="nv-target">{{ hostname || deviceName || ip }} · {{ ip }}</span>
        <span style="flex:1"></span>
        <n-button size="small" quaternary type="error" @click="disconnect">
          <template #icon><n-icon><LogoutIcon /></n-icon></template>{{ t("novnc.disconnect") }}
        </n-button>
      </div>
      <n-spin v-if="phase === 'connecting'" :show="true" style="margin: 40px auto" />
      <div ref="screenBox" class="nv-screen" :class="{ 'nv-screen-show': phase === 'connected' }"></div>
    </div>
  </div>
</template>

<style scoped>
.nv-wrap { width: 100%; }
.nv-full { height: 100%; display: flex; flex-direction: column; }
.nv-form { max-width: 460px; padding: 4px 2px; }
.nv-title { display: flex; align-items: center; gap: 6px; font-weight: 600; margin-bottom: 12px; }
.nv-target { opacity: .8; font-weight: 500; }
.nv-row { display: flex; flex-direction: column; gap: 4px; margin-bottom: 10px; }
.nv-row > label { font-size: 12px; opacity: .75; }
.nv-stage { flex: 1; display: flex; flex-direction: column; min-height: 0; }
.nv-bar { display: flex; align-items: center; gap: 8px; padding: 4px 2px 8px; }
.nv-screen { flex: 1; min-height: 360px; background: #000; border-radius: 6px; overflow: hidden; }
.nv-full .nv-screen { min-height: 0; }
.nv-screen-show { display: block; }
</style>

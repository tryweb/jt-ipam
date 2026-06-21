<script setup lang="ts">
/**
 * SSH 終端機（xterm.js）。先換 ticket → 開 WebSocket → 橋接後端 asyncssh。
 * 憑證（密碼/私鑰）只在連線時送出，前端不保存。Host key 採 TOFU：首次顯示指紋確認後由後端釘選。
 */
import { nextTick, onBeforeUnmount, reactive, ref } from "vue";
import { useI18n } from "vue-i18n";
import {
  NForm, NFormItem, NInput, NInputNumber, NRadioGroup, NRadio, NButton,
  NSpace, NModal, NAlert, NIcon, NSpin,
} from "naive-ui";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { requestSshTicket, buildSshWsUrl } from "@/api/ssh";
import { TerminalIcon, CancelIcon, RefreshIcon } from "@/icons";

const props = withDefaults(defineProps<{
  addressId: string;
  ip: string;
  defaultPort?: number;
  fullHeight?: boolean;
}>(), { defaultPort: 22, fullHeight: false });

const { t } = useI18n();

type Phase = "form" | "connecting" | "connected" | "closed" | "error";
const phase = ref<Phase>("form");
const errorMsg = ref("");

const form = reactive({
  username: "",
  port: props.defaultPort,
  auth: "password" as "password" | "key",
  password: "",
  privateKey: "",
  passphrase: "",
});

const termEl = ref<HTMLElement | null>(null);
let term: Terminal | null = null;
let fit: FitAddon | null = null;
let ws: WebSocket | null = null;
let ro: ResizeObserver | null = null;

// host key TOFU 確認
const hostKeyAsk = ref(false);
const hostKeyFp = ref("");

function clearCreds() {
  form.password = "";
  form.privateKey = "";
  form.passphrase = "";
}

function wsSend(obj: Record<string, unknown>) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function disposeTerm() {
  ro?.disconnect(); ro = null;
  term?.dispose(); term = null; fit = null;
}

function teardown() {
  try { ws?.close(); } catch { /* noop */ }
  ws = null;
  disposeTerm();
}

function doFit() {
  try {
    fit?.fit();
    if (term) wsSend({ type: "resize", cols: term.cols, rows: term.rows });
  } catch { /* noop */ }
}

async function connect() {
  errorMsg.value = "";
  if (!form.username.trim()) { errorMsg.value = t("ssh.err_username"); return; }
  phase.value = "connecting";
  let ticket;
  try {
    ticket = await requestSshTicket(props.addressId);
  } catch (e: any) {
    phase.value = "error";
    errorMsg.value = e?.response?.data?.detail || t("ssh.err_ticket");
    return;
  }

  await nextTick();
  if (!termEl.value) { phase.value = "error"; errorMsg.value = t("ssh.err_ticket"); return; }
  term = new Terminal({ cursorBlink: true, fontSize: 13, scrollback: 5000,
    theme: { background: "#1e1e1e" } });
  fit = new FitAddon();
  term.loadAddon(fit);
  term.open(termEl.value);
  doFit();
  ro = new ResizeObserver(() => doFit());
  ro.observe(termEl.value);
  term.onData((d) => wsSend({ type: "data", data: d }));

  ws = new WebSocket(buildSshWsUrl(ticket.ws_path, ticket.ticket));
  ws.onopen = () => {
    wsSend({
      type: "config",
      username: form.username.trim(),
      port: form.port,
      auth: form.auth,
      password: form.auth === "password" ? form.password : undefined,
      private_key: form.auth === "key" ? form.privateKey : undefined,
      passphrase: form.auth === "key" ? form.passphrase : undefined,
      cols: term?.cols ?? 80,
      rows: term?.rows ?? 24,
    });
    clearCreds(); // 送出後即清空，前端不留
  };
  ws.onmessage = (ev) => {
    let msg: any;
    try { msg = JSON.parse(ev.data); } catch { return; }
    switch (msg.type) {
      case "data": term?.write(msg.data); break;
      case "status":
        if (msg.state === "connected") phase.value = "connected";
        else if (msg.state === "disconnected") phase.value = "closed";
        break;
      case "hostkey":
        hostKeyFp.value = msg.fingerprint;
        hostKeyAsk.value = true;
        break;
      case "error":
        phase.value = "error";
        errorMsg.value = msg.message || msg.code || t("ssh.err_generic");
        break;
    }
  };
  ws.onclose = () => {
    if (phase.value !== "error") {
      phase.value = "closed";
      term?.write(`\r\n\x1b[33m${t("ssh.disconnected")}\x1b[0m\r\n`);
    }
  };
  ws.onerror = () => {
    if (phase.value !== "error" && phase.value !== "connected") {
      phase.value = "error";
      errorMsg.value = t("ssh.err_ws");
    }
  };
}

function acceptHostKey() {
  hostKeyAsk.value = false;
  wsSend({ type: "hostkey_accept" });
}
function rejectHostKey() {
  hostKeyAsk.value = false;
  wsSend({ type: "hostkey_reject" });
  teardown();
  phase.value = "form";
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
  <div class="ssh-wrap" :class="{ 'ssh-full': fullHeight }">
    <!-- 連線設定表單 -->
    <div v-if="phase === 'form'" class="ssh-form">
      <div class="ssh-title">
        <n-icon :component="TerminalIcon" /> {{ t("ssh.connect_to", { ip }) }}
      </div>
      <n-form label-placement="left" :label-width="92" size="small">
        <n-form-item :label="t('ssh.username')">
          <n-input v-model:value="form.username" placeholder="root" autofocus
                   @keyup.enter="connect" />
        </n-form-item>
        <n-form-item :label="t('ssh.port')">
          <n-input-number v-model:value="form.port" :min="1" :max="65535" style="width:140px" />
        </n-form-item>
        <n-form-item :label="t('ssh.auth_method')">
          <n-radio-group v-model:value="form.auth">
            <n-radio value="password">{{ t("ssh.auth_password") }}</n-radio>
            <n-radio value="key">{{ t("ssh.auth_key") }}</n-radio>
          </n-radio-group>
        </n-form-item>
        <n-form-item v-if="form.auth === 'password'" :label="t('ssh.password')">
          <n-input v-model:value="form.password" type="password" show-password-on="click"
                   @keyup.enter="connect" />
        </n-form-item>
        <template v-else>
          <n-form-item :label="t('ssh.private_key')">
            <n-input v-model:value="form.privateKey" type="textarea"
                     :autosize="{ minRows: 4, maxRows: 8 }"
                     placeholder="-----BEGIN OPENSSH PRIVATE KEY-----" />
          </n-form-item>
          <n-form-item :label="t('ssh.passphrase')">
            <n-input v-model:value="form.passphrase" type="password" show-password-on="click" />
          </n-form-item>
        </template>
        <n-alert :show-icon="false" type="info" style="margin-bottom:10px">
          {{ t("ssh.no_store_hint") }}
        </n-alert>
        <n-space justify="end">
          <n-button type="primary" @click="connect">
            <template #icon><n-icon :component="TerminalIcon" /></template>
            {{ t("ssh.connect") }}
          </n-button>
        </n-space>
      </n-form>
    </div>

    <!-- 終端機 -->
    <div v-show="phase !== 'form'" class="ssh-term-area" :class="{ 'ssh-full': fullHeight }">
      <div class="ssh-toolbar">
        <span class="ssh-status" :data-state="phase">
          <n-spin v-if="phase === 'connecting'" :size="12" />
          <span v-else class="ssh-dot" />
          <span class="ssh-state-label">{{ t(`ssh.state_${phase}`) }}</span>
          <span class="ssh-ip">{{ ip }}</span>
        </span>
        <n-space :size="8">
          <n-button v-if="phase === 'connected'" size="tiny" type="error" ghost @click="disconnect">
            <template #icon><n-icon :component="CancelIcon" /></template>{{ t("ssh.disconnect") }}
          </n-button>
          <n-button v-if="phase === 'closed' || phase === 'error'" size="tiny" @click="backToForm">
            <template #icon><n-icon :component="RefreshIcon" /></template>{{ t("ssh.reconnect") }}
          </n-button>
        </n-space>
      </div>
      <n-alert v-if="phase === 'error'" type="error" :show-icon="true" style="margin:8px 0">
        {{ errorMsg }}
      </n-alert>
      <div ref="termEl" class="ssh-term" :class="{ 'ssh-full': fullHeight }" />
    </div>

    <!-- host key TOFU 確認 -->
    <n-modal v-model:show="hostKeyAsk" preset="dialog" :title="t('ssh.hostkey_title')"
             :positive-text="t('ssh.hostkey_trust')" :negative-text="t('common.cancel')"
             @positive-click="acceptHostKey" @negative-click="rejectHostKey"
             :mask-closable="false">
      <div style="line-height:1.6">
        <div>{{ t("ssh.hostkey_body", { ip }) }}</div>
        <code class="ssh-fp">{{ hostKeyFp }}</code>
        <div style="opacity:.7;font-size:12px">{{ t("ssh.hostkey_hint") }}</div>
      </div>
    </n-modal>
  </div>
</template>

<style scoped>
.ssh-wrap { width: 100%; }
.ssh-wrap.ssh-full { height: 100%; display: flex; flex-direction: column; }
.ssh-form { max-width: 560px; }
.ssh-title { font-weight: 600; display: flex; align-items: center; gap: 6px; margin-bottom: 12px; }
.ssh-term-area { display: flex; flex-direction: column; }
.ssh-term-area.ssh-full { flex: 1; min-height: 0; }
.ssh-toolbar { display: flex; justify-content: space-between; align-items: center; padding: 4px 2px; gap: 8px; }
.ssh-status { font-size: 13px; display: inline-flex; align-items: center; gap: 7px;
  padding: 3px 11px; border-radius: 999px; font-weight: 500;
  background: rgba(128, 128, 128, .12); color: #888; }
.ssh-dot { width: 8px; height: 8px; border-radius: 50%; background: currentColor; flex: none; }
.ssh-ip { opacity: .7; font-variant-numeric: tabular-nums; }
.ssh-status[data-state="connected"] { color: #18a058; background: rgba(24, 160, 88, .14); }
.ssh-status[data-state="connected"] .ssh-dot { animation: ssh-pulse 1.8s infinite; }
.ssh-status[data-state="connecting"] { color: #d99812; background: rgba(217, 152, 18, .14); }
.ssh-status[data-state="error"] { color: #d03050; background: rgba(208, 48, 80, .14); }
.ssh-status[data-state="closed"] { color: #888; background: rgba(128, 128, 128, .14); }
@keyframes ssh-pulse {
  0%   { box-shadow: 0 0 0 0 rgba(24, 160, 88, .5); }
  70%  { box-shadow: 0 0 0 6px rgba(24, 160, 88, 0); }
  100% { box-shadow: 0 0 0 0 rgba(24, 160, 88, 0); }
}
.ssh-term { height: 420px; background: #1e1e1e; padding: 6px; border-radius: 6px; }
.ssh-term.ssh-full { flex: 1; height: auto; min-height: 0; border-radius: 0; }
.ssh-fp { display: block; margin: 8px 0; padding: 6px 8px; background: rgba(128,128,128,.12);
  border-radius: 4px; word-break: break-all; font-size: 13px; }
</style>

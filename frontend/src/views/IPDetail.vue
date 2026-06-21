<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from "vue";
import { useRoute, useRouter } from "vue-router";
import { useI18n } from "vue-i18n";
import { NCard, NDescriptions, NDescriptionsItem, NSpin, NSpace, NTag, NButton, NIcon, useMessage } from "naive-ui";
import { getAddress } from "@/api/addresses";
import IPAddressEditModal from "@/components/IPAddressEditModal.vue";
import SshTerminal from "@/components/SshTerminal.vue";
import { TerminalIcon, CancelIcon } from "@/icons";
import { useScanProbes, probeLabel } from "@/api/scanProbes";
import type { IPAddress } from "@/types";

const route = useRoute();
const router = useRouter();
const { t, locale } = useI18n();
const msg = useMessage();
const { catalog } = useScanProbes();

const addr = ref<IPAddress | null>(null);
const loading = ref(false);
const showSsh = ref(false);
const sshCardRef = ref<any>(null);

async function openSsh() {
  showSsh.value = true;
  // 終端機面板在長頁面底部，開啟後捲動到可視範圍，否則看起來像「沒反應」
  await nextTick();
  sshCardRef.value?.$el?.scrollIntoView({ behavior: "smooth", block: "start" });
}
function openSshPopout() {
  if (!addr.value) return;
  const href = router.resolve({ name: "ssh-console", params: { id: addr.value.id } }).href;
  window.open(href, `ssh-${addr.value.id}`, "width=960,height=640,noopener");
}

// 把探測 key 轉成顯示 label（比不到目錄就直接顯示 key）
function labelForProbe(key: string): string {
  const p = catalog.value.probes.find((x) => x.key === key);
  return p ? probeLabel(p, locale.value) : key;
}

const showScanSection = computed(() => {
  const a = addr.value;
  return !!a && ((a.effective_probes?.length ?? 0) > 0 || (a.excluded_probes?.length ?? 0) > 0);
});

async function load(id: string) {
  loading.value = true;
  showSsh.value = false;
  try { addr.value = await getAddress(id); }
  catch { msg.error(t("errors.network")); addr.value = null; }
  finally { loading.value = false; }
}
function onSaved(a: IPAddress) {
  addr.value = a;
  if (!a.ssh_available) showSsh.value = false;  // 取消啟用/失去權限 → 收掉終端機
}
function onDeleted() { router.push({ name: "addresses" }); }
function back() {
  if (window.history.length > 1) router.back();
  else router.push({ name: "addresses" });
}

onMounted(() => load(String(route.params.id)));
watch(() => route.params.id, (id) => { if (id) load(String(id)); });
</script>

<template>
  <n-spin :show="loading">
    <n-space vertical :size="12">
      <IPAddressEditModal
        v-if="addr"
        inline
        :show="true"
        :address="addr"
        @saved="onSaved"
        @deleted="onDeleted"
        @back="back"
        @ssh-open="openSsh"
        @ssh-popout="openSshPopout"
      />

      <!-- 嵌入式 SSH 終端機 -->
      <n-card v-if="addr && addr.ssh_available && showSsh" ref="sshCardRef" size="small" :bordered="true">
        <template #header>
          <n-space align="center" :size="6">
            <n-icon><TerminalIcon /></n-icon>
            <span>{{ t("ssh.terminal_title") }}</span>
          </n-space>
        </template>
        <template #header-extra>
          <n-button size="tiny" quaternary @click="showSsh = false">
            <template #icon><n-icon><CancelIcon /></n-icon></template>{{ t("ssh.close_panel") }}
          </n-button>
        </template>
        <SshTerminal :key="addr.id" :address-id="addr.id" :ip="addr.ip" />
      </n-card>

      <!-- 掃描項目（唯讀，由探測結果推導）；OS 已併入上方主要欄位表 -->
      <n-card v-if="addr && showScanSection" size="small" :bordered="true">
        <template v-if="showScanSection">
          <div style="font-weight: 600; margin: 0 0 4px">{{ t("scan_probes.title") }}</div>
          <n-descriptions label-placement="left" :column="1" size="small">
            <n-descriptions-item v-if="addr.effective_probes?.length" :label="t('scan_probes.effective')">
              <n-space :size="4" :wrap="true">
                <n-tag v-for="k in addr.effective_probes" :key="k" size="small" :bordered="false">
                  {{ labelForProbe(k) }}
                </n-tag>
              </n-space>
              <div style="font-size: 12px; opacity: .6; margin-top: 4px">{{ t("scan_probes.effective_hint") }}</div>
            </n-descriptions-item>
            <n-descriptions-item v-if="addr.excluded_probes?.length" :label="t('scan_probes.excluded')">
              <n-space :size="4" :wrap="true">
                <n-tag v-for="k in addr.excluded_probes" :key="k" size="small" type="warning" :bordered="false">
                  {{ labelForProbe(k) }}
                </n-tag>
              </n-space>
            </n-descriptions-item>
          </n-descriptions>
        </template>
      </n-card>

      <n-space v-else-if="!loading" justify="center" style="padding: 40px; opacity: .6">
        {{ t("common.no_data") }}
      </n-space>
    </n-space>
  </n-spin>
</template>

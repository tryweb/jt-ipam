<script setup lang="ts">
/** 另開視窗的全頁 SSH 終端機。載入 IP 後渲染全高 SshTerminal。 */
import { onMounted, ref } from "vue";
import { useRoute } from "vue-router";
import { useI18n } from "vue-i18n";
import { NSpin, NResult } from "naive-ui";
import { getAddress } from "@/api/addresses";
import SshTerminal from "@/components/SshTerminal.vue";
import type { IPAddress } from "@/types";

const route = useRoute();
const { t } = useI18n();
const addr = ref<IPAddress | null>(null);
const loading = ref(true);
const failed = ref(false);

onMounted(async () => {
  try {
    addr.value = await getAddress(String(route.params.id));
    if (addr.value?.ip) document.title = `SSH · ${addr.value.ip}`;
  } catch {
    failed.value = true;
  } finally {
    loading.value = false;
  }
});
</script>

<template>
  <div class="ssh-page">
    <n-spin v-if="loading" :show="true" style="margin:80px auto;display:block" />
    <n-result v-else-if="failed || !addr" status="403" :title="t('ssh.err_generic')" />
    <SshTerminal v-else :address-id="addr.id" :ip="addr.ip" full-height />
  </div>
</template>

<style scoped>
.ssh-page { height: 100vh; width: 100vw; display: flex; flex-direction: column;
  padding: 10px; box-sizing: border-box; background: var(--n-color, #fff); }
</style>

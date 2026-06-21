import { apiClient } from "@/api/client";

export interface SshTicket {
  ticket: string;
  ws_path: string;
  host_key_pinned: boolean;
  default_port: number;
  ttl: number;
}

// 換發短期一次性 ticket（之後用它開 WebSocket）。注意帶 /api/v1 前綴。
export async function requestSshTicket(addressId: string): Promise<SshTicket> {
  const { data } = await apiClient.post<SshTicket>(
    `/api/v1/addresses/${addressId}/ssh/ticket`,
  );
  return data;
}

// 由 ws_path + ticket 組出完整 WebSocket URL（同源，沿用目前頁面協定/host）。
export function buildSshWsUrl(wsPath: string, ticket: string): string {
  const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${proto}//${window.location.host}${wsPath}?ticket=${encodeURIComponent(ticket)}`;
}

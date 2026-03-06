export interface DdnsStatusResponse {
  ddns_status: DdnsStatus[];
}

export interface DdnsStatus {
  name: string;
  provider: string;
  status: "success" | "updating" | "error" | "disabled" | "unknown";
  last_update: number;
  last_ip: string;
  message: string;
}

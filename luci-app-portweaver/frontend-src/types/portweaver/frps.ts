export interface FrpsNode {
  enabled: boolean;
  port: number;
  token?: string;
  log_level?: string;
  allow_ports?: string;
  bind_addr?: string;
  max_pool_count?: number;
  max_ports_per_client?: number;
  tcp_mux?: boolean;
  udp_mux?: boolean;
  kcp_mux?: boolean;
  dashboard_addr?: string;
  dashboard_user?: string;
  dashboard_pwd?: string;
}

export interface FrpsStatus {
  status: "running" | "stopped" | "error" | "unavailable";
  last_error: string;
  node_name: string;
}

export interface FrpsProxyStats {
  name: string;
  type: string;
  status: string;
  bytes_in: number;
  bytes_out: number;
  cur_conns: number;
  last_start_time: string;
  last_close_time: string;
}

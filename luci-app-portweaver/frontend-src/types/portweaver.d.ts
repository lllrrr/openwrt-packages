export interface PortWeaverStatus {
  status?: "running" | "stopped" | "degraded" | string;
  total_projects?: number;
  active_ports?: number;
  active_sessions?: number;
  uptime?: number;
  total_bytes_in?: number;
  total_bytes_out?: number;
}

/** Statistics for a single forwarder (port) */
export interface ForwarderStats {
  protocol: string;
  local_port: number;
  bytes_in: number;
  bytes_out: number;
  active_sessions?: number;
}

export interface ProjectStatus {
  id?: number;
  /** UCI section name for index-independent matching */
  section_name?: string;
  remark?: string;
  enabled: boolean;
  status: string;
  startup_status?: string;
  error_code?: number;
  active_ports?: number;
  bytes_in?: number;
  bytes_out?: number;
  active_sessions?: number;
  /** Per-port statistics */
  forwarders?: ForwarderStats[];
}

export interface FrpcStatus {
  enabled: boolean;
  version?: string;
  status?: string;
  last_error?: string;
  client_count?: number;
}

export interface FrpsStatus {
  enabled: boolean;
  version?: string;
  status?: string;
  last_error?: string;
  client_count?: number;
  proxy_count?: number;
  server_count?: number;
}

export interface FrpStatus {
  frp_enabled?: boolean;
  frp_version?: string;
  frpc?: FrpcStatus;
  frps?: FrpsStatus;
}

/** A single event in the activity log */
export interface ActivityEvent {
  /** Unix timestamp in milliseconds */
  timestamp: number;
  /** Event type: project_started, project_stopped, frp_error, etc. */
  type: string;
  /** Event message */
  message: string;
  /** Project ID (-1 if not applicable) */
  project_id: number;
}

export interface PortMapping {
  listenPort: string;
  targetPort: string;
  frpNodes: string[];
  protocol: "tcp" | "udp" | "both";
}

export interface DdnsGlobalStatus {
  ddns_enabled: boolean;
  ddns_version: string | null;
}

// Sub-types for get_full_status
export interface FullStatusProject {
  id: string;
  /** UCI section name for index-independent matching */
  section_name: string;
  enabled: boolean;
  status: string;
  startup_status?: string;
  active_ports: number;
  bytes_in: number;
  bytes_out: number;
  active_sessions?: number;
  last_changed?: number;
  error_code?: number;
  forwarders?: Array<{
    protocol: string;
    local_port: number;
    bytes_in: number;
    bytes_out: number;
    active_sessions?: number;
  }>;
}

export interface FullStatusFrpcNode {
  name: string;
  status: string;
  client_count: number;
  last_error: string;
}

export interface FullStatusFrpsNode {
  name: string;
  status: string;
  client_count: number;
  proxy_count: number;
  server_count: number;
  last_error: string;
}

export interface FullStatusFrp {
  enabled: boolean;
  version?: string;
  clients: FullStatusFrpcNode[];
  servers: FullStatusFrpsNode[];
}

export interface FullStatusDdnsInstance {
  name: string;
  provider: string;
  status: string;
  last_update: number;
  last_ip: string;
  message: string;
}

export interface FullStatusDdns {
  enabled: boolean;
  version?: string;
  instances: FullStatusDdnsInstance[];
}

export interface FullStatusResponse {
  status: string;
  uptime: number;
  total_projects: number;
  active_ports: number;
  total_bytes_in: number;
  total_bytes_out: number;
  active_sessions?: number;
  projects: FullStatusProject[];
  frp: FullStatusFrp;
  ddns: FullStatusDdns;
  events: ActivityEvent[];
}

export interface VersionResponse {
  version: string;
  uci_mode: boolean;
  ubus_mode: boolean;
  frpc_mode: boolean;
  frps_mode: boolean;
  ddns_mode: boolean;
  nftables_mode: boolean;
  wol_mode: boolean;
  forward_backend: string;
  frp_version?: string;
  ddns_version?: string;
  backend_version: string;
}

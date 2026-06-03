import type {
  FullStatusResponse,
  ProjectStatus,
  VersionResponse,
} from "@/types/portweaver";
import type { InfoResponse } from "./../types/portweaver/index";
import type { DdnsStatusResponse } from "@/types/portweaver/ddns";
import type { FrpcProxyStats } from "@/types/portweaver/frpc";
import type { FrpsProxyStats } from "@/types/portweaver/frps";

export function createRpcClient(rpc: typeof L.rpc) {
  const listProjects = rpc.declare<{ projects: ProjectStatus[] }>({
    object: "portweaver",
    method: "list_projects",
  });
  const setEnabled = rpc.declare<void, [id: number, enabled: boolean]>({
    object: "portweaver",
    method: "set_enabled",
    params: ["id", "enabled"],
  });

  const getFrpcInfo = rpc.declare<InfoResponse, [id: string]>({
    object: "portweaver",
    method: "get_frpc_info",
    params: ["id"],
  });

  const clearFrpcLogs = rpc.declare<void, [id: string]>({
    object: "portweaver",
    method: "clear_frpc_logs",
    params: ["id"],
  });

  const getFrpcProxyStats = rpc.declare<FrpcProxyStats, [id: string]>({
    object: "portweaver",
    method: "get_frpc_proxy_stats",
    params: ["id"],
  });

  const getDdnsStatus = rpc.declare<DdnsStatusResponse>({
    object: "portweaver",
    method: "get_ddns_status",
  });

  const getDdnsInfo = rpc.declare<InfoResponse, [name: string]>({
    object: "portweaver",
    method: "get_ddns_info",
    params: ["name"],
  });

  const clearDdnsLogs = rpc.declare<void, [name: string]>({
    object: "portweaver",
    method: "clear_ddns_logs",
    params: ["name"],
  });

  const getFrpsInfo = rpc.declare<InfoResponse, [id: string]>({
    object: "portweaver",
    method: "get_frps_info",
    params: ["id"],
  });

  const clearFrpsLogs = rpc.declare<void, [id: string]>({
    object: "portweaver",
    method: "clear_frps_logs",
    params: ["id"],
  });

  const getFrpsProxyStats = rpc.declare<FrpsProxyStats[], [id: string]>({
    object: "portweaver",
    method: "get_frps_proxy_stats",
    params: ["id"],
  });

  const getFullStatus = rpc.declare<FullStatusResponse>({
    object: "portweaver",
    method: "get_full_status",
  });
  const getVersion = rpc.declare<VersionResponse>({
    object: "portweaver",
    method: "get_version",
  });

  const getNftablesRules = rpc.declare<{ rules: string }>({
    object: "portweaver",
    method: "get_nftables_rules",
  });

  const reloadConfig = rpc.declare<{
    success: boolean;
    changes: number;
    message: string;
  }>({
    object: "portweaver",
    method: "reload_config",
  });

  const restartProject = rpc.declare<
    { id: number; status: string },
    [id: number]
  >({
    object: "portweaver",
    method: "restart_project",
    params: ["id"],
  });

  const wolWake = rpc.declare<
    { success: boolean; sent_count: number },
    [project: string]
  >({
    object: "portweaver",
    method: "wol_wake",
    params: ["project"],
  });

  const wolStatus = rpc.declare<
    {
      enabled: boolean;
      mac_count: number;
      cooldown_ms: number;
      detect_protocols: string[];
    },
    [project: string]
  >({
    object: "portweaver",
    method: "wol_status",
    params: ["project"],
  });

  return {
    listProjects,
    setEnabled,
    getFrpcInfo,
    getFrpcProxyStats,
    clearFrpcLogs,
    getDdnsStatus,
    getDdnsInfo,
    clearDdnsLogs,
    getFrpsInfo,
    clearFrpsLogs,
    getFrpsProxyStats,
    getFullStatus,
    getVersion,
    getNftablesRules,
    reloadConfig,
    restartProject,
    wolWake,
    wolStatus,
  };
}
export type RpcClient = ReturnType<typeof createRpcClient>;
export const rpcClient = createRpcClient(L.rpc);

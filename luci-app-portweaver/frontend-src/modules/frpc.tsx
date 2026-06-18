import { LogViewerDialog } from "@/components/LogViewerDialog";
import { ProxyStatsViewer } from "@/components/ProxyStatsViewer";
import { rpcClient } from "@/utils/rpc-client";
import { getThemeColors } from "@/utils/theme-utils";
const form = L.form;

type FrpState =
  | "connected"
  | "connecting"
  | "error"
  | "stopped"
  | "unavailable";

function getStatusColors(): Record<FrpState, string> {
  const { isDark } = getThemeColors();
  // Dark mode adjustments for better visibility
  const connectedColor = isDark ? "#4CAF50" : "#4CAF50"; // Green works well in both
  const connectingColor = isDark ? "#FFD700" : "#FFC107"; // Brighter gold for dark mode
  const errorColor = isDark ? "#FF5252" : "#F44336"; // Brighter red for dark mode
  const inactiveColor = isDark ? "#BDBDBD" : "#9E9E9E"; // Lighter gray for dark mode

  return {
    connected: connectedColor,
    connecting: connectingColor,
    error: errorColor,
    stopped: inactiveColor,
    unavailable: inactiveColor,
  };
}

const STATUS_LABELS: Record<FrpState, string> = {
  connected: _("Connected"),
  connecting: _("Connecting"),
  error: _("Error"),
  stopped: _("Stopped"),
  unavailable: _("Unavailable"),
};

const nodeStatuses: Record<string, { status: FrpState; last_error: string }> =
  {};
const statusElements: Record<string, HTMLElement> = {};
const actionButtons: Record<string, HTMLButtonElement> = {};

export default function (
  _m: LuCI.form.Map,
  s: LuCI.form.NamedSection,
  tab_id: string,
) {
  const o = s.taboption(
    tab_id,
    form.SectionValue,
    "_frpc_nodes",
    form.GridSection,
    "frpc_node",
  );

  const ss = o.subsection as LuCI.form.GridSection;
  ss.anonymous = true;
  ss.addremove = true;
  ss.sortable = true;
  ss.cloneable = true;

  ss.sectiontitle = (section_id: string) =>
    (L.uci.get("portweaver", section_id, "name") as string) ||
    section_id ||
    _("Unnamed node");

  const oEnable = ss.option(form.Flag, "enabled", _("Enable"));
  oEnable.modalonly = true;
  oEnable.default = "1";
  oEnable.rmempty = false;

  const oName = ss.option(form.Value, "name", _("Node Name"));
  oName.modalonly = true;
  oName.rmempty = false;
  oName.datatype = "string";
  oName.placeholder = "node1";
  oName.validate = (section_id: string, value: unknown) => {
    const val = String(value || "");
    if (!val || val.trim() === "") return _("Node name is required");
    if (!/^[a-zA-Z0-9_-]+$/.test(val.trim()))
      return _(
        "Node name must contain only alphanumeric characters, underscore, or hyphen",
      );

    const sections = L.uci.sections("portweaver", "frpc_node");
    const trimmedValue = val.trim();
    for (const sec of sections) {
      if (sec[".name"] === section_id) continue;

      const existingName = sec.name as string;
      if (existingName && existingName.trim() === trimmedValue) {
        return _("Node name already exists. Please choose a different name.");
      }
    }

    return true;
  };

  const oStatus = ss.option(form.DummyValue, "status", _("Status"));
  oStatus.modalonly = false;
  oStatus.textvalue = (section_id: string) => {
    const info = nodeStatuses[section_id] || { status: "unavailable" };
    const colors = getStatusColors();
    const statusColor = colors[info.status] || colors.unavailable;

    const statusText =
      {
        connected: _("Connected"),
        connecting: _("Connecting"),
        error: _("Error"),
        stopped: _("Stopped"),
        unavailable: _("Unavailable"),
      }[info.status] || info.status;

    const container = (
      <span
        id={`frpc-status-${section_id}`}
        style="display:flex; align-items:center;"
      >
        <span
          style={`display:inline-block; width:12px; height:12px; border-radius:50%; background-color:${statusColor}; margin-right:8px;`}
        ></span>
        <span>{statusText}</span>
      </span>
    ) as HTMLElement;

    statusElements[section_id] = container;
    return container;
  };

  const oEnabled = ss.option(form.Flag, "enabled", _("Enabled"));
  oEnabled.modalonly = false;
  oEnabled.default = "1";
  oEnabled.editable = true;

  const oServer = ss.option(form.Value, "server", _("FRP Server Address"));
  oServer.modalonly = true;
  oServer.rmempty = false;
  oServer.datatype = "host";
  oServer.placeholder = "1.2.3.4";
  oServer.validate = (_section_id: string, value: unknown) => {
    const val = String(value || "");
    if (!val || val.trim() === "") return _("Server address is required");
    return true;
  };

  const oPort = ss.option(form.Value, "port", _("FRP Server Port"));
  oPort.modalonly = true;
  oPort.rmempty = false;
  oPort.datatype = "port";
  oPort.placeholder = "7000";
  oPort.validate = (_section_id: string, value: unknown) => {
    const val = String(value || "");
    if (!val || val.trim() === "") return _("Server port is required");
    const port = parseInt(val, 10);
    if (Number.isNaN(port) || port < 1 || port > 65535)
      return _("Port must be between 1 and 65535");
    return true;
  };

  const oToken = ss.option(form.Value, "token", _("Authentication Token"));
  oToken.modalonly = true;
  oToken.password = true;
  oToken.rmempty = true;
  oToken.placeholder = "optional token for authentication";

  const oLogLevel = ss.option(form.ListValue, "log_level", _("Log Level"));
  oLogLevel.modalonly = true;
  oLogLevel.rmempty = true;
  oLogLevel.default = "info";
  oLogLevel.value("trace", "Trace");
  oLogLevel.value("debug", "Debug");
  oLogLevel.value("info", "Info");
  oLogLevel.value("warn", "Warning");
  oLogLevel.value("error", "Error");

  const oUseEncryption = ss.option(
    form.Flag,
    "use_encryption",
    _("Enable Encryption"),
  );
  oUseEncryption.modalonly = true;
  oUseEncryption.rmempty = false;
  oUseEncryption.default = "1";

  const oUseCompression = ss.option(
    form.Flag,
    "use_compression",
    _("Enable Compression"),
  );
  oUseCompression.modalonly = true;
  oUseCompression.rmempty = false;
  oUseCompression.default = "1";

  const oActions = ss.option(form.DummyValue, "actions", _("Actions"));
  oActions.modalonly = false;
  oActions.textvalue = (section_id: string) => {
    const isRunning =
      (nodeStatuses[section_id]?.status || "stopped") !== "stopped";

    const btn = (
      <button
        type="button"
        class="cbi-button cbi-button-action"
        onclick={() => {
          const nodeName = L.uci.get(
            "portweaver",
            section_id,
            "name",
          ) as string;
          const logViewer = new LogViewerDialog({
            name: nodeName,
            title: _("FRP Logs - %s").format(nodeName),
            fetcher: async () => await rpcClient.getFrpcInfo(nodeName),
            clearer: async () => await rpcClient.clearFrpcLogs(nodeName),
          });
          logViewer.open();
        }}
        disabled={!isRunning}
      >
        {_("View Logs")}
      </button>
    ) as HTMLButtonElement;

    actionButtons[section_id] = btn;
    return btn;
  };

  const oProxyStats = ss.option(
    form.DummyValue,
    "proxy_stats",
    _("Proxy Stats"),
  );
  oProxyStats.modalonly = false;
  oProxyStats.textvalue = (section_id: string) => {
    const nodeName = L.uci.get("portweaver", section_id, "name") as string;
    const container = (
      <div style="display: flex; gap: 8px; flex-wrap: wrap;"></div>
    );

    // Create stats viewer for the client (now shows all proxies)
    const statsViewer = new ProxyStatsViewer({
      clientId: nodeName,
      rpcClient: rpcClient,
    });
    const statsEl = statsViewer.render();
    statsEl.style.cssText = `flex: 1; min-width: 300px; ${statsEl.style.cssText}`;
    container.appendChild(statsEl);

    return container;
  };

  async function pollFrpStatus() {
    try {
      const sections = await L.uci.sections("portweaver", "frpc_node");
      const promises = sections.map((sec: any) => {
        const nodeName = sec.name as string;
        return rpcClient
          .getFrpcInfo(nodeName)
          .then((res) => {
            const oldStatus = nodeStatuses[sec[".name"]]?.status;
            const rawStatus = res.status ?? "unavailable";
            const newStatus: FrpState = [
              "connected",
              "connecting",
              "error",
              "stopped",
              "unavailable",
            ].includes(rawStatus)
              ? (rawStatus as FrpState)
              : ("unavailable" as FrpState);

            nodeStatuses[sec[".name"]] = {
              status: newStatus,
              last_error: res.last_error || "",
            };

            if (oldStatus !== newStatus) {
              const container =
                document.getElementById(`frpc-status-${sec[".name"]}`) ||
                statusElements[sec[".name"]];
              if (container && container.childNodes.length >= 2) {
                const indicator = container.childNodes[0] as HTMLElement;
                const textSpan = container.childNodes[1] as HTMLElement;

                // Get fresh theme colors at update time
                const colors = getStatusColors();
                const statusColor = colors[newStatus] || colors.unavailable;
                indicator.style.backgroundColor = statusColor;
                indicator.style.backgroundColor = statusColor;

                const statusText = STATUS_LABELS[newStatus] || newStatus;
                textSpan.textContent = statusText;
              }

              const actionBtn = actionButtons[sec[".name"]];
              if (actionBtn) {
                const isRunning = newStatus !== "stopped";
                actionBtn.disabled = !isRunning;
              }
            }
          })
          .catch(() => {
            nodeStatuses[sec[".name"]] = {
              status: "error",
              last_error: "Failed to fetch status",
            };

            const container =
              document.getElementById(`frpc-status-${sec[".name"]}`) ||
              statusElements[sec[".name"]];
            if (container && container.childNodes.length >= 2) {
              const indicator = container.childNodes[0] as HTMLElement;
              const textSpan = container.childNodes[1] as HTMLElement;
              indicator.style.backgroundColor = "#F44336";
              textSpan.textContent = _("Error");
            }

            const actionBtn = actionButtons[sec[".name"]];
            if (actionBtn) {
              actionBtn.disabled = true;
            }
          });
      });
      await Promise.all(promises);
    } catch (e) {
      console.error("Polling for FRP status failed:", e);
    }
  }

  pollFrpStatus();
  L.Poll.add(pollFrpStatus, 5);
}

import { LogViewerDialog } from "../components/LogViewerDialog";
import { rpcClient } from "../utils/rpc-client";
import { getThemeColors } from "../utils/theme-utils";
const form = L.form;

type FrpsState =
  | "running"
  | "connected"
  | "connecting"
  | "error"
  | "stopped"
  | "unavailable";

function getStatusColors(): Record<FrpsState, string> {
  const { isDark } = getThemeColors();
  // Dark mode adjustments for better visibility
  const connectedColor = isDark ? "#4CAF50" : "#4CAF50"; // Green works well in both
  const connectingColor = isDark ? "#FFD700" : "#FFC107"; // Brighter gold for dark mode
  const errorColor = isDark ? "#FF5252" : "#F44336"; // Brighter red for dark mode
  const inactiveColor = isDark ? "#BDBDBD" : "#9E9E9E"; // Lighter gray for dark mode

  return {
    running: connectedColor,
    connected: connectedColor,
    connecting: connectingColor,
    error: errorColor,
    stopped: inactiveColor,
    unavailable: inactiveColor,
  };
}

const STATUS_LABELS: Record<FrpsState, string> = {
  running: _("Running"),
  connected: _("Connected"),
  connecting: _("Connecting"),
  error: _("Error"),
  stopped: _("Stopped"),
  unavailable: _("Unavailable"),
};

const nodeStatuses: Record<string, { status: FrpsState; last_error: string }> =
  {};
const statusElements: Record<string, HTMLElement> = {};
const actionButtons: Record<string, HTMLButtonElement> = {};

export default function (
  _m: LuCI.form.CBIMap,
  s: LuCI.form.CBIAbstractSection,
  tab_id: string,
) {
  let o: LuCI.form.CBIAbstractSectionValue;

  o = s.taboption(
    tab_id,
    form.SectionValue,
    "_frps_nodes",
    form.GridSection,
    "frps_node",
  );

  const ss = o.subsection;
  ss.anonymous = true;
  ss.addremove = true;
  ss.sortable = true;
  ss.cloneable = true;

  ss.sectiontitle = (section_id: string) =>
    L.uci.get("portweaver", section_id, "name") ||
    section_id ||
    _("Unnamed FRPS node");

  o = ss.option(form.Flag, "enabled", _("Enable"));
  o.modalonly = true;
  o.default = "1";
  o.rmempty = false;

  o = ss.option(form.Value, "name", _("Node Name"));
  o.modalonly = true;
  o.rmempty = false;
  o.datatype = "string";
  o.placeholder = "frps_node1";
  o.validate = (section_id: string, value: string) => {
    if (!value || String(value).trim() === "")
      return _("Node name is required");
    if (!/^[a-zA-Z0-9_-]+$/.test(String(value).trim()))
      return _(
        "Node name must contain only alphanumeric characters, underscore, or hyphen",
      );

    const sections = L.uci.sections("portweaver", "frps_node");
    const trimmedValue = String(value).trim();
    for (const sec of sections) {
      if (sec[".name"] === section_id) continue;

      const existingName = sec.name as string;
      if (existingName && existingName.trim() === trimmedValue) {
        return _("Node name already exists. Please choose a different name.");
      }
    }

    return true;
  };

  o = ss.option(form.DummyValue, "status", _("Status"));
  o.modalonly = false;
  o.textvalue = (section_id: string) => {
    const info = nodeStatuses[section_id] || { status: "unavailable" };
    const colors = getStatusColors();
    const statusColor = colors[info.status] || colors.unavailable;

    const statusText =
      {
        running: _("Running"),
        connected: _("Connected"),
        connecting: _("Connecting"),
        error: _("Error"),
        stopped: _("Stopped"),
        unavailable: _("Unavailable"),
      }[info.status] || info.status;

    const container = (
      <span style="display:flex; align-items:center;">
        <span
          style={`display:inline-block; width:12px; height:12px; border-radius:50%; background-color:${statusColor}; margin-right:8px;`}
        ></span>
        <span>{statusText}</span>
      </span>
    ) as HTMLElement;

    statusElements[section_id] = container;
    return container;
  };

  o = ss.option(form.Flag, "enabled", _("Enabled"));
  o.modalonly = false;
  o.default = "1";
  o.editable = true;

  o = ss.option(form.Value, "bind_port", _("Bind Port"));
  o.modalonly = true;
  o.rmempty = false;
  o.datatype = "port";
  o.placeholder = "7000";
  o.validate = (_section_id: string, value: string) => {
    if (!value || String(value).trim() === "")
      return _("Bind port is required");
    const port = parseInt(value, 10);
    if (Number.isNaN(port) || port < 1 || port > 65535)
      return _("Port must be between 1 and 65535");
    return true;
  };

  o = ss.option(form.Value, "bind_addr", _("Bind Address"));
  o.modalonly = true;
  o.rmempty = true;
  o.datatype = "host";
  o.placeholder = "0.0.0.0";
  o.default = "0.0.0.0";

  o = ss.option(form.Value, "auth_token", _("Authentication Token"));
  o.modalonly = true;
  o.password = true;
  o.rmempty = true;
  o.placeholder = "optional token for authentication";

  o = ss.option(form.Value, "allow_ports", _("Allow Ports"));
  o.modalonly = true;
  o.rmempty = true;
  o.placeholder = "10000-20000 or 8080,8081,8082";
  o.description = _(
    "Port range or list of ports that clients can use. e.g., '10000-20000' or '8080,8081,8082'",
  );

  o = ss.option(form.Flag, "tcp_mux", _("TCP Mux"));
  o.modalonly = true;
  o.rmempty = true;
  o.default = "1";
  o.description = _("Enable TCP multiplexing for better performance");

  o = ss.option(form.Value, "max_pool_count", _("Max Pool Count"));
  o.modalonly = true;
  o.rmempty = true;
  o.datatype = "uinteger";
  o.placeholder = "5";
  o.description = _("Maximum connection pool size per proxy");

  o = ss.option(form.Value, "max_ports_per_client", _("Max Ports Per Client"));
  o.modalonly = true;
  o.rmempty = true;
  o.datatype = "uinteger";
  o.placeholder = "0";
  o.description = _("Maximum number of ports per client (0 = unlimited)");

  o = ss.option(form.ListValue, "log_level", _("Log Level"));
  o.modalonly = true;
  o.rmempty = true;
  o.default = "info";
  o.value("trace", "Trace");
  o.value("debug", "Debug");
  o.value("info", "Info");
  o.value("warn", "Warning");
  o.value("error", "Error");

  o = ss.option(form.Value, "dashboard_addr", _("Dashboard Address"));
  o.modalonly = true;
  o.rmempty = true;
  o.datatype = "host";
  o.placeholder = "0.0.0.0";
  o.default = "0.0.0.0";

  o = ss.option(form.Value, "dashboard_port", _("Dashboard Port"));
  o.modalonly = true;
  o.rmempty = true;
  o.datatype = "port";
  o.placeholder = "7500";
  o.validate = (_section_id: string, value: string) => {
    if (!value || String(value).trim() === "") return true;
    const port = parseInt(value, 10);
    if (Number.isNaN(port) || port < 1 || port > 65535)
      return _("Port must be between 1 and 65535");
    return true;
  };

  o = ss.option(form.Value, "dashboard_user", _("Dashboard User"));
  o.modalonly = true;
  o.rmempty = true;
  o.placeholder = "admin";
  o.depends("dashboard_port", /\S+/);

  o = ss.option(form.Value, "dashboard_pwd", _("Dashboard Password"));
  o.modalonly = true;
  o.password = true;
  o.rmempty = true;
  o.placeholder = "admin";
  o.depends("dashboard_port", /\S+/);

  o = ss.option(form.DummyValue, "actions", _("Actions"));
  o.modalonly = false;
  o.textvalue = (section_id: string) => {
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
            title: _("FRPS Logs - %s").format(nodeName),
            fetcher: async () => await rpcClient.getFrpsInfo(nodeName),
            clearer: async () => await rpcClient.clearFrpsLogs(nodeName),
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

  async function pollFrpsStatus() {
    try {
      const sections = await L.uci.sections("portweaver", "frps_node");
      const promises = sections.map((sec: any) => {
        const nodeName = sec.name as string;

        return rpcClient
          .getFrpsInfo(nodeName)
          .then((res) => {
            const oldStatus = nodeStatuses[sec[".name"]]?.status;

            const rawStatus = res.status ?? "unavailable";
            const newStatus: FrpsState = [
              "running",
              "connected",
              "connecting",
              "error",
              "stopped",
              "unavailable",
            ].includes(rawStatus)
              ? (rawStatus as FrpsState)
              : ("unavailable" as FrpsState);

            nodeStatuses[sec[".name"]] = {
              status: newStatus,
              last_error: res.last_error || "",
            };

            if (oldStatus !== newStatus) {
              const container = statusElements[sec[".name"]];

              if (container && container.childNodes.length >= 2) {
                const indicator = container.childNodes[0] as HTMLElement;
                const textSpan = container.childNodes[1] as HTMLElement;

                // Get fresh theme colors at update time
                const colors = getStatusColors();
                const statusColor = colors[newStatus] || colors.unavailable;
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

            const container = statusElements[sec[".name"]];
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
      console.error("Polling for FRPS status failed:", e);
    }
  }

  pollFrpsStatus();
  L.Poll.add(pollFrpsStatus, 5);
}

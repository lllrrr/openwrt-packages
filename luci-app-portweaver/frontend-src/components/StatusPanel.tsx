import type {
  PortWeaverStatus,
  FrpStatus,
  ProjectStatus,
  ActivityEvent,
  DdnsGlobalStatus,
} from "@/types/portweaver";
import { formatBytes, formatUptime, translateStatus } from "@/utils/formatters";
import { isFeatureEnabled } from "@/utils/feature";

export class StatusPanel {
  public statusValueEl?: HTMLElement;
  public totalProjectsEl?: HTMLElement;
  public activePortsEl?: HTMLElement;
  public activeSessionsEl?: HTMLElement;
  public uptimeEl?: HTMLElement;
  public trafficInEl?: HTMLElement;
  public trafficOutEl?: HTMLElement;
  public projectHealthEl?: HTMLElement;
  public frpcEnabledEl?: HTMLElement;
  public frpcVersionEl?: HTMLElement;
  public frpcStatusEl?: HTMLElement;
  public frpcInfoEl?: HTMLElement;
  public frpcErrorEl?: HTMLElement;
  public frpsEnabledEl?: HTMLElement;
  public frpsVersionEl?: HTMLElement;
  public frpsStatusEl?: HTMLElement;
  public frpsInfoEl?: HTMLElement;
  public frpsErrorEl?: HTMLElement;
  public ddnsEnabledEl?: HTMLElement;
  public ddnsVersionEl?: HTMLElement;
  public activityLogContainer?: HTMLElement;
  public trafficRateInEl?: HTMLElement;
  public trafficRateOutEl?: HTMLElement;
  public projectListEl?: HTMLElement;
  public frpcProxiesEl?: HTMLElement;
  public frpsProxiesEl?: HTMLElement;
  public ddnsHealthEl?: HTMLElement;

  render(
    status: PortWeaverStatus,
    frpStatus?: FrpStatus,
    projectStatuses?: ProjectStatus[],
    events?: ActivityEvent[],
    ddnsGlobalStatus?: DdnsGlobalStatus,
  ): HTMLElement {
    const statusColor =
      {
        running: "#28a745",
        stopped: "#dc3545",
        degraded: "#ffc107",
      }[status.status || ""] || "#6c757d";

    // Calculate project health stats
    const enabledProjects = projectStatuses?.filter((p) => p.enabled) || [];
    const runningProjects = enabledProjects.filter(
      (p) => p.status === "running",
    );
    const hasEnabledProjects = enabledProjects.length > 0;

    return (
      <div>
        {/* Activity Log Section */}
        {events && events.length > 0 && this.renderActivityLog(events)}

        <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 1em; margin-top: 0.5em;">
          {(() => {
            const statusValueEl = (
              <strong
                style={`color: ${statusColor}; font-size: 1.1em; font-weight: 600;`}
                id="status-value"
              >
                {translateStatus(status.status) || "-"}
              </strong>
            );
            this.statusValueEl = statusValueEl as HTMLElement;
            return this.card(_("Status"), statusValueEl);
          })()}

          {(() => {
            const totalProjectsEl = (
              <strong
                style="font-size: 1.1em; font-weight: 600;"
                id="total-projects-value"
              >
                {status.total_projects || 0}
              </strong>
            );
            this.totalProjectsEl = totalProjectsEl as HTMLElement;
            return this.card(_("Total Projects"), totalProjectsEl);
          })()}

          {(() => {
            const activePortsEl = (
              <strong
                style="font-size: 1.1em; font-weight: 600;"
                id="active-ports-value"
              >
                {status.active_ports || 0}
              </strong>
            );
            this.activePortsEl = activePortsEl as HTMLElement;
            return this.card(_("Active Ports"), activePortsEl);
          })()}

          {(() => {
            const activeSessionsEl = (
              <strong
                style="font-size: 1.1em; font-weight: 600;"
                id="active-sessions-value"
              >
                {status.active_sessions || 0}
              </strong>
            );
            this.activeSessionsEl = activeSessionsEl as HTMLElement;
            return this.card(_("Active Sessions"), activeSessionsEl);
          })()}

          {(() => {
            const uptimeEl = (
              <strong
                style="font-size: 1.1em; font-weight: 600;"
                id="uptime-value"
              >
                {formatUptime(status.uptime || 0)}
              </strong>
            );
            this.uptimeEl = uptimeEl as HTMLElement;
            return this.card(_("Uptime"), uptimeEl);
          })()}

          {(() => {
            const trafficInEl = (
              <strong
                style="font-size: 1.1em; font-weight: 600;"
                id="traffic-in-value"
              >
                {formatBytes(status.total_bytes_in || 0)}
              </strong>
            );
            this.trafficInEl = trafficInEl as HTMLElement;
            return this.card(_("Traffic In"), trafficInEl);
          })()}

          {(() => {
            const trafficOutEl = (
              <strong
                style="font-size: 1.1em; font-weight: 600;"
                id="traffic-out-value"
              >
                {formatBytes(status.total_bytes_out || 0)}
              </strong>
            );
            this.trafficOutEl = trafficOutEl as HTMLElement;
            return this.card(_("Traffic Out"), trafficOutEl);
          })()}

          {/* Global Project Health Indicator */}
          {hasEnabledProjects &&
            this.card(
              _("Project Health"),
              <div id="project-health-value">
                <strong
                  style={`font-size: 1.1em; font-weight: 600; color: ${runningProjects.length === enabledProjects.length ? "#28a745" : runningProjects.length > 0 ? "#ffc107" : "#dc3545"};`}
                >
                  {runningProjects.length} / {enabledProjects.length}
                </strong>
                <div style="font-size: 0.85em; color: #6c757d; margin-top: 0.3em;">
                  {_("projects running")}
                </div>
              </div>,
            )}

          {isFeatureEnabled("frpc_mode") &&
            frpStatus &&
            (() => {
              const frpc = frpStatus.frpc || { enabled: false };
              const isEnabled = frpc.enabled;

              const frpcEnabledEl = (
                <strong
                  style={`font-size: 1.1em; font-weight: 600; color: ${
                    isEnabled ? "#28a745" : "#6c757d"
                  };`}
                  id="frpc-enabled-value"
                >
                  {isEnabled ? _("Enabled") : _("Disabled")}
                </strong>
              );
              this.frpcEnabledEl = frpcEnabledEl as HTMLElement;

              const frpcVersionEl = (
                <div
                  style="font-size: 0.85em; color: #6c757d; margin-top: 0.3em;"
                  id="frpc-version-value"
                >
                  {isEnabled && frpStatus.frp_version
                    ? frpStatus.frp_version
                    : ""}
                </div>
              );
              this.frpcVersionEl = frpcVersionEl as HTMLElement;

              const frpcStatusEl = (
                <div
                  style="font-size: 0.85em; margin-top: 0.2em;"
                  id="frpc-status-value"
                ></div>
              );
              this.frpcStatusEl = frpcStatusEl as HTMLElement;

              const frpcInfoEl = (
                <div
                  style="font-size: 0.85em; color: #6c757d; margin-top: 0.2em;"
                  id="frpc-info-value"
                ></div>
              );
              this.frpcInfoEl = frpcInfoEl as HTMLElement;

              const frpcErrorEl = (
                <div
                  style="cursor: help; font-size: 0.85em; color: #dc3545; margin-top: 0.2em; display: none;"
                  id="frpc-error-value"
                ></div>
              );
              this.frpcErrorEl = frpcErrorEl as HTMLElement;

              return this.card(
                "FRPC",
                <div>
                  {frpcEnabledEl}
                  {frpcVersionEl}
                  {frpcStatusEl}
                  {frpcInfoEl}
                  {frpcErrorEl}
                </div>,
              );
            })()}

          {isFeatureEnabled("frps_mode") &&
            frpStatus &&
            (() => {
              const frps = frpStatus.frps || { enabled: false };
              const isEnabled = frps.enabled;

              const frpsEnabledEl = (
                <strong
                  style={`font-size: 1.1em; font-weight: 600; color: ${
                    isEnabled ? "#28a745" : "#6c757d"
                  };`}
                  id="frps-enabled-value"
                >
                  {isEnabled ? _("Enabled") : _("Disabled")}
                </strong>
              );
              this.frpsEnabledEl = frpsEnabledEl as HTMLElement;

              const frpsVersionEl = (
                <div
                  style="font-size: 0.85em; color: #6c757d; margin-top: 0.3em;"
                  id="frps-version-value"
                >
                  {isEnabled && frpStatus.frp_version
                    ? frpStatus.frp_version
                    : ""}
                </div>
              );
              this.frpsVersionEl = frpsVersionEl as HTMLElement;

              const frpsStatusEl = (
                <div
                  style="font-size: 0.85em; margin-top: 0.2em;"
                  id="frps-status-value"
                ></div>
              );
              this.frpsStatusEl = frpsStatusEl as HTMLElement;

              const frpsInfoEl = (
                <div
                  style="font-size: 0.85em; color: #6c757d; margin-top: 0.2em;"
                  id="frps-info-value"
                ></div>
              );
              this.frpsInfoEl = frpsInfoEl as HTMLElement;

              const frpsErrorEl = (
                <div
                  style="cursor: help; font-size: 0.85em; color: #dc3545; margin-top: 0.2em; display: none;"
                  id="frps-error-value"
                ></div>
              );
              this.frpsErrorEl = frpsErrorEl as HTMLElement;

              return this.card(
                "FRPS",
                <div>
                  {frpsEnabledEl}
                  {frpsVersionEl}
                  {frpsStatusEl}
                  {frpsInfoEl}
                  {frpsErrorEl}
                </div>,
              );
            })()}

          {isFeatureEnabled("ddns_mode") &&
            ddnsGlobalStatus &&
            (() => {
              const ddnsEnabledEl = (
                <strong
                  style={`font-size: 1.1em; font-weight: 600; color: ${
                    ddnsGlobalStatus.ddns_enabled ? "#28a745" : "#6c757d"
                  };`}
                  id="ddns-enabled-value"
                >
                  {ddnsGlobalStatus.ddns_enabled ? _("Enabled") : _("Disabled")}
                </strong>
              );
              this.ddnsEnabledEl = ddnsEnabledEl as HTMLElement;

              const ddnsVersionEl = ddnsGlobalStatus.ddns_version ? (
                <div
                  style="font-size: 0.85em; color: #6c757d; margin-top: 0.3em;"
                  id="ddns-version-value"
                >
                  {ddnsGlobalStatus.ddns_version}
                </div>
              ) : null;
              if (ddnsVersionEl)
                this.ddnsVersionEl = ddnsVersionEl as HTMLElement;

              return this.card(
                _("DDNS-GO"),
                <div>
                  {ddnsEnabledEl}
                  {ddnsVersionEl}
                </div>,
              );
            })()}

          {/* Card A: Traffic Rate */}
          {(() => {
            const trafficRateInEl = (
              <span>{_("calculating")}</span>
            ) as HTMLElement;
            const trafficRateOutEl = (
              <span>{_("calculating")}</span>
            ) as HTMLElement;
            this.trafficRateInEl = trafficRateInEl;
            this.trafficRateOutEl = trafficRateOutEl;
            return this.card(
              _("Traffic Rate"),
              <div>
                <div style="font-size: 0.85em;">↓ {trafficRateInEl}</div>
                <div style="font-size: 0.85em;">↑ {trafficRateOutEl}</div>
              </div>,
            );
          })()}

          {/* Card C: Project List */}
          {(() => {
            const projectListEl = (
              <span style="color: #6c757d;">{_("loading")}</span>
            ) as HTMLElement;
            this.projectListEl = projectListEl;
            return this.card(_("Project List"), projectListEl);
          })()}

          {/* Card F: FRPC Proxies */}
          {isFeatureEnabled("frpc_mode") &&
            (() => {
              const frpcProxiesEl = (
                <span style="color: #6c757d;">{_("loading")}</span>
              ) as HTMLElement;
              this.frpcProxiesEl = frpcProxiesEl;
              return this.card(_("FRPC Proxies"), frpcProxiesEl);
            })()}

          {/* Card H: FRPS Active Proxies */}
          {isFeatureEnabled("frps_mode") &&
            (() => {
              const frpsProxiesEl = (
                <span style="color: #6c757d;">{_("loading")}</span>
              ) as HTMLElement;
              this.frpsProxiesEl = frpsProxiesEl;
              return this.card(_("FRPS Active Proxies"), frpsProxiesEl);
            })()}

          {/* Card J: DDNS Entry Health */}
          {isFeatureEnabled("ddns_mode") &&
            (() => {
              const ddnsHealthEl = (
                <span style="color: #6c757d;">{_("loading")}</span>
              ) as HTMLElement;
              this.ddnsHealthEl = ddnsHealthEl;
              return this.card(_("DDNS Entries"), ddnsHealthEl);
            })()}
        </div>
      </div>
    );
  }

  private truncateError(error: string, maxLen: number): string {
    if (error.length <= maxLen) return error;
    return `${error.substring(0, maxLen - 3)}...`;
  }

  private renderActivityLog(events: ActivityEvent[]): HTMLElement {
    // Show last 5 events, most recent first
    const recentEvents = events.slice(-5).reverse();

    return (
      <div style="margin-bottom: 1em; border: 1px solid #dee2e6; border-radius: 4px; padding: 0.8em;">
        <div style="font-size: 0.9em; font-weight: 600; margin-bottom: 0.5em; color: #495057;">
          {_("Recent Activity")}
        </div>
        {(() => {
          const activityLogContainer = (
            <div
              style="max-height: 150px; overflow-y: auto;"
              id="activity-log-container"
            >
              {recentEvents.map((event) => this.renderEventRow(event))}
            </div>
          );
          this.activityLogContainer = activityLogContainer as HTMLElement;
          return activityLogContainer;
        })()}
      </div>
    );
  }

  private renderEventRow(event: ActivityEvent): HTMLElement {
    const eventColors: Record<string, string> = {
      project_started: "#28a745",
      project_stopped: "#6c757d",
      frp_error: "#dc3545",
      frp_connected: "#28a745",
      frp_disconnected: "#ffc107",
      config_changed: "#17a2b8",
    };

    const eventIcons: Record<string, string> = {
      project_started: "▶",
      project_stopped: "⏹",
      frp_error: "⚠",
      frp_connected: "🔗",
      frp_disconnected: "🔌",
      config_changed: "⚙",
    };

    const color = eventColors[event.type] || "#6c757d";
    const icon = eventIcons[event.type] || "•";
    const time = this.formatTimestamp(event.timestamp);

    return (
      <div style="display: flex; align-items: flex-start; padding: 0.3em 0; border-bottom: 1px solid #eee; font-size: 0.85em;">
        <span style={`color: ${color}; margin-right: 0.5em; flex-shrink: 0;`}>
          {icon}
        </span>
        <span style="color: #6c757d; margin-right: 0.5em; flex-shrink: 0; min-width: 70px;">
          {time}
        </span>
        <span style="flex: 1; word-break: break-word;" title={event.message}>
          {this.truncateError(event.message, 60)}
        </span>
      </div>
    );
  }

  private formatTimestamp(timestamp: number): string {
    const date = new Date(timestamp);
    const hours = date.getHours().toString().padStart(2, "0");
    const minutes = date.getMinutes().toString().padStart(2, "0");
    const seconds = date.getSeconds().toString().padStart(2, "0");
    return `${hours}:${minutes}:${seconds}`;
  }

  private card(label: string, valueEl: any): HTMLElement {
    return (
      <div style="border: 1px solid #dee2e6; padding: 0.8em; border-radius: 4px; background: transparent;">
        <div style="font-size: 0.85em; color: #6c757d; margin-bottom: 0.3em;">
          {label}
        </div>
        {valueEl}
      </div>
    );
  }
}

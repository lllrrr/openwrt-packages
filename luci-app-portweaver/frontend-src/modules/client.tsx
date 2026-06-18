import type {
  ActivityEvent,
  DdnsGlobalStatus,
  ForwarderStats,
  FrpcStatus,
  FrpsStatus,
  FrpStatus,
  FullStatusDdnsInstance,
  FullStatusFrpcNode,
  FullStatusFrpsNode,
  FullStatusResponse,
  PortWeaverStatus,
  ProjectStatus,
} from "@/types/portweaver";
import {
  formatBytes,
  formatUptime,
  getErrorMessage,
  translateStatus,
} from "@/utils/formatters";
import { rpcClient } from "@/utils/rpc-client";
import { getThemeColors } from "@/utils/theme-utils";
import type { StatusPanel } from "@/components/StatusPanel";
export class Client {
  projectStatuses: ProjectStatus[];
  globalStatus: PortWeaverStatus;
  frpStatus: FrpStatus;
  ddnsGlobalStatus: DdnsGlobalStatus;
  events: ActivityEvent[];
  // References to UI elements provided by StatusPanel and config
  statusPanel?: StatusPanel;
  projectContainers: Record<string, HTMLElement> = {};
  private _lastPollTime = 0;
  ddnsInstances: FullStatusDdnsInstance[] = [];
  frpClientNodes: FullStatusFrpcNode[] = [];
  frpServerNodes: FullStatusFrpsNode[] = [];
  constructor(fullStatus: FullStatusResponse) {
    this.projectStatuses = [];
    this.globalStatus = {};
    this.frpStatus = {};
    this.ddnsGlobalStatus = { ddns_enabled: false, ddns_version: null };
    this.events = [];

    this.applyFullStatus(fullStatus);
    L.Poll.add(async () => {
      try {
        const prevBytesIn = this.globalStatus.total_bytes_in || 0;
        const prevBytesOut = this.globalStatus.total_bytes_out || 0;
        const nowMs = Date.now();
        const [latestStatus, listProjects] = await Promise.all([
          rpcClient.getFullStatus(),
          rpcClient.listProjects(),
        ]);
        if (latestStatus) {
          this.applyFullStatus(latestStatus);
        }
        if (listProjects?.projects) {
          this.applyProjectList(listProjects.projects);
        }

        const statusColors: Record<string, string> = {
          running: "green",
          stopped: "red",
          degraded: "orange",
        };
        if (this.statusPanel?.statusValueEl) {
          this.statusPanel.statusValueEl.textContent =
            translateStatus(this.globalStatus.status) || "-";
          (this.statusPanel.statusValueEl.style as any).color =
            statusColors[this.globalStatus.status || ""] || "gray";
        }

        if (this.statusPanel?.totalProjectsEl)
          this.statusPanel.totalProjectsEl.textContent = String(
            this.globalStatus.total_projects || 0,
          );
        if (this.statusPanel?.activePortsEl)
          this.statusPanel.activePortsEl.textContent = String(
            this.globalStatus.active_ports || 0,
          );
        if (this.statusPanel?.activeSessionsEl)
          this.statusPanel.activeSessionsEl.textContent = String(
            this.globalStatus.active_sessions || 0,
          );
        if (this.statusPanel?.uptimeEl)
          this.statusPanel.uptimeEl.textContent = formatUptime(
            this.globalStatus.uptime || 0,
          );
        if (this.statusPanel?.trafficInEl)
          this.statusPanel.trafficInEl.textContent = formatBytes(
            this.globalStatus.total_bytes_in || 0,
          );
        if (this.statusPanel?.trafficOutEl)
          this.statusPanel.trafficOutEl.textContent = formatBytes(
            this.globalStatus.total_bytes_out || 0,
          );

        if (this.statusPanel) {
          this.updateFrpCard(
            this.frpStatus.frpc,
            this.frpStatus.frp_version,
            this.statusPanel.frpcEnabledEl,
            this.statusPanel.frpcVersionEl,
            this.statusPanel.frpcStatusEl,
            this.statusPanel.frpcInfoEl,
            this.statusPanel.frpcErrorEl,
            "frpc",
          );

          this.updateFrpCard(
            this.frpStatus.frps,
            this.frpStatus.frp_version,
            this.statusPanel.frpsEnabledEl,
            this.statusPanel.frpsVersionEl,
            this.statusPanel.frpsStatusEl,
            this.statusPanel.frpsInfoEl,
            this.statusPanel.frpsErrorEl,
            "frps",
          );
        }

        if (this.statusPanel?.ddnsEnabledEl) {
          this.statusPanel.ddnsEnabledEl.textContent = this.ddnsGlobalStatus
            .ddns_enabled
            ? _("Enabled")
            : _("Disabled");
          (this.statusPanel.ddnsEnabledEl.style as any).color = this
            .ddnsGlobalStatus.ddns_enabled
            ? "#28a745"
            : "#6c757d";
        }
        if (
          this.statusPanel?.ddnsVersionEl &&
          this.ddnsGlobalStatus.ddns_version
        ) {
          this.statusPanel.ddnsVersionEl.textContent =
            this.ddnsGlobalStatus.ddns_version;
        }

        this.updateProjectHealthIndicator();
        this.updateActivityLog();

        // Traffic rate
        if (
          this.statusPanel?.trafficRateInEl &&
          this.statusPanel.trafficRateOutEl
        ) {
          if (this._lastPollTime > 0) {
            const elapsed = (nowMs - this._lastPollTime) / 1000;
            if (elapsed > 0) {
              const rateIn =
                Math.max(
                  0,
                  (this.globalStatus.total_bytes_in || 0) - prevBytesIn,
                ) / elapsed;
              const rateOut =
                Math.max(
                  0,
                  (this.globalStatus.total_bytes_out || 0) - prevBytesOut,
                ) / elapsed;
              this.statusPanel.trafficRateInEl.textContent = `${formatBytes(rateIn)}/s`;
              this.statusPanel.trafficRateOutEl.textContent = `${formatBytes(rateOut)}/s`;
            }
          }
        }
        this._lastPollTime = nowMs;

        // Project list
        if (this.statusPanel?.projectListEl) {
          const projectSections = L.uci.sections("portweaver", "project") || [];
          const projectListEl = this.statusPanel.projectListEl;
          projectListEl.innerHTML = "";
          if (projectSections.length === 0) {
            projectListEl.appendChild(
              (
                <span style="color: #6c757d;">{_("No projects")}</span>
              ) as HTMLElement,
            );
          } else {
            for (let i = 0; i < projectSections.length; i++) {
              const sec = projectSections[i];
              const name = (sec.name as string) || sec[".name"] || `#${i + 1}`;
              const ps = this.projectStatuses[i];
              const color =
                ps?.status === "running"
                  ? "#28a745"
                  : ps?.status === "stopped"
                    ? "#dc3545"
                    : "#6c757d";
              projectListEl.appendChild(
                (
                  <div style="display: flex; justify-content: space-between; font-size: 0.85em; padding: 0.15em 0;">
                    <span>{name}</span>
                    <span style={`color: ${color};`}>
                      {translateStatus(ps?.status || "unknown")}
                    </span>
                  </div>
                ) as HTMLElement,
              );
            }
          }
        }

        // FRPC proxies (per client node)
        if (this.statusPanel?.frpcProxiesEl) {
          const frpcProxiesEl = this.statusPanel.frpcProxiesEl;
          frpcProxiesEl.innerHTML = "";
          if (
            !this.frpStatus.frpc?.enabled ||
            this.frpClientNodes.length === 0
          ) {
            frpcProxiesEl.appendChild(
              (
                <span style="color: #6c757d;">{_("disabled")}</span>
              ) as HTMLElement,
            );
          } else {
            for (const node of this.frpClientNodes) {
              const color = node.status === "connected" ? "#28a745" : "#dc3545";
              frpcProxiesEl.appendChild(
                (
                  <div style="display: flex; justify-content: space-between; font-size: 0.85em; padding: 0.15em 0;">
                    <span>{node.name}</span>
                    <span style={`color: ${color};`}>
                      {`${node.client_count} ${_("clients")}`}
                    </span>
                  </div>
                ) as HTMLElement,
              );
            }
          }
        }

        // FRPS active proxies (per server node)
        if (this.statusPanel?.frpsProxiesEl) {
          const frpsProxiesEl = this.statusPanel.frpsProxiesEl;
          frpsProxiesEl.innerHTML = "";
          if (
            !this.frpStatus.frps?.enabled ||
            this.frpServerNodes.length === 0
          ) {
            frpsProxiesEl.appendChild(
              (
                <span style="color: #6c757d;">{_("disabled")}</span>
              ) as HTMLElement,
            );
          } else {
            for (const node of this.frpServerNodes) {
              frpsProxiesEl.appendChild(
                (
                  <div style="display: flex; justify-content: space-between; font-size: 0.85em; padding: 0.15em 0;">
                    <span>{node.name}</span>
                    <span style="color: #6c757d;">
                      {`${node.proxy_count} proxies`}
                    </span>
                  </div>
                ) as HTMLElement,
              );
            }
          }
        }

        // DDNS entries
        if (this.statusPanel?.ddnsHealthEl) {
          const ddnsHealthEl = this.statusPanel.ddnsHealthEl;
          ddnsHealthEl.innerHTML = "";
          if (!this.ddnsGlobalStatus.ddns_enabled) {
            ddnsHealthEl.appendChild(
              (
                <span style="color: #6c757d;">{_("disabled")}</span>
              ) as HTMLElement,
            );
          } else if (this.ddnsInstances.length === 0) {
            ddnsHealthEl.appendChild(
              (
                <span style="color: #6c757d;">{_("No entries")}</span>
              ) as HTMLElement,
            );
          } else {
            for (const inst of this.ddnsInstances) {
              const color =
                inst.status === "success"
                  ? "#28a745"
                  : inst.status === "error"
                    ? "#dc3545"
                    : "#6c757d";
              ddnsHealthEl.appendChild(
                (
                  <div style="display: flex; justify-content: space-between; font-size: 0.85em; padding: 0.15em 0;">
                    <span>{inst.name}</span>
                    <span style={`color: ${color};`}>{inst.status}</span>
                  </div>
                ) as HTMLElement,
              );
            }
          }
        }

        (() => {
          const sections = L.uci.sections("portweaver", "project") || [];
          for (let i = 0; i < sections.length; i++) {
            const section_id = sections[i][".name"];
            if (!section_id) {
              continue;
            }
            const status = this.getProjectStatus(section_id);
            const section =
              document.getElementById(`project-status-${section_id}`) ||
              this.projectContainers[section_id];
            if (!section) continue;
            const newStatusElements = this.renderStatusElements(
              status,
              section_id,
            );
            const newContainer = (
              <div id={`project-status-${section_id}`}>{newStatusElements}</div>
            ) as HTMLElement;
            section.replaceWith(newContainer);
            this.projectContainers[section_id] = newContainer;
          }
        })();
      } catch (err) {
        console.warn("Auto-refresh failed:", err);
      }
    }, 3);
  }

  private applyFullStatus(fullStatus?: FullStatusResponse): void {
    if (!fullStatus) return;

    this.globalStatus = {
      status: fullStatus.status,
      total_projects: fullStatus.total_projects,
      active_ports: fullStatus.active_ports,
      active_sessions: fullStatus.active_sessions,
      uptime: fullStatus.uptime,
      total_bytes_in: fullStatus.total_bytes_in,
      total_bytes_out: fullStatus.total_bytes_out,
    };

    this.projectStatuses = (fullStatus.projects || []).map((project) => ({
      enabled: project.enabled,
      status: project.status,
      startup_status: project.startup_status,
      error_code: project.error_code,
      active_ports: project.active_ports,
      active_sessions: project.active_sessions,
      bytes_in: project.bytes_in,
      bytes_out: project.bytes_out,
      forwarders: project.forwarders,
    }));

    this.frpStatus = this.buildFrpStatus(fullStatus);

    this.ddnsGlobalStatus = {
      ddns_enabled: !!fullStatus.ddns?.enabled,
      ddns_version: fullStatus.ddns?.version ?? null,
    };
    this.ddnsInstances = fullStatus.ddns?.instances || [];
    this.frpClientNodes = fullStatus.frp?.clients || [];
    this.frpServerNodes = fullStatus.frp?.servers || [];

    this.events = fullStatus.events || [];
  }

  private applyProjectList(projects: ProjectStatus[]): void {
    if (!projects || projects.length === 0) return;

    const merged = projects.map((project, index) => {
      const existing = this.projectStatuses[index];
      return {
        enabled: project.enabled ?? existing?.enabled ?? false,
        status: project.status ?? existing?.status ?? "unknown",
        startup_status: project.startup_status ?? existing?.startup_status,
        error_code: project.error_code ?? existing?.error_code,
        active_ports: project.active_ports ?? existing?.active_ports,
        active_sessions: project.active_sessions ?? existing?.active_sessions,
        bytes_in: project.bytes_in ?? existing?.bytes_in,
        bytes_out: project.bytes_out ?? existing?.bytes_out,
        forwarders: project.forwarders ?? existing?.forwarders,
      } as ProjectStatus;
    });

    if (merged.length > 0) {
      this.projectStatuses = merged;
    }
  }

  private buildFrpStatus(fullStatus: FullStatusResponse): FrpStatus {
    const frp = fullStatus.frp;
    const frpEnabled = !!frp?.enabled;
    const frpVersion = frp?.version;
    const frpcNodes = frp?.clients || [];
    const frpsNodes = frp?.servers || [];

    const frpcClientCount = frpcNodes.reduce(
      (total, node) => total + (node.client_count || 0),
      0,
    );
    const frpsClientCount = frpsNodes.reduce(
      (total, node) => total + (node.client_count || 0),
      0,
    );
    const frpsProxyCount = frpsNodes.reduce(
      (total, node) => total + (node.proxy_count || 0),
      0,
    );
    const frpsServerCount = frpsNodes.reduce(
      (total, node) => total + (node.server_count || 0),
      0,
    );

    const frpcStatus: FrpcStatus = {
      enabled: frpEnabled,
      status: this.aggregateFrpStatus(frpcNodes.map((node) => node.status)),
      last_error: this.pickFirstError(frpcNodes.map((node) => node.last_error)),
      client_count: frpcClientCount,
    };

    const frpsStatus: FrpsStatus = {
      enabled: frpEnabled,
      status: this.aggregateFrpStatus(frpsNodes.map((node) => node.status)),
      last_error: this.pickFirstError(frpsNodes.map((node) => node.last_error)),
      client_count: frpsClientCount,
      proxy_count: frpsProxyCount,
      server_count: frpsServerCount,
    };

    return {
      frp_enabled: frpEnabled,
      frp_version: frpVersion,
      frpc: frpcStatus,
      frps: frpsStatus,
    };
  }

  private aggregateFrpStatus(statuses: Array<string | undefined>): string {
    const normalized = statuses.filter(Boolean) as string[];
    if (normalized.some((status) => status === "error")) return "error";
    if (
      normalized.some(
        (status) => status === "connected" || status === "running",
      )
    )
      return "running";
    if (normalized.some((status) => status === "connecting")) return "running";
    return normalized.length > 0 ? "stopped" : "stopped";
  }

  private pickFirstError(
    errors: Array<string | undefined>,
  ): string | undefined {
    return errors.find((error) => !!error) || undefined;
  }

  getProjectIndex(section_id: string): number {
    const sections = L.uci.sections("portweaver", "project");
    for (let i = 0; i < sections.length; i++) {
      if (sections[i][".name"] === section_id) return i;
    }
    return -1;
  }
  getProjectStatus(section_id: string): ProjectStatus | null {
    const idx = this.getProjectIndex(section_id);
    return idx >= 0 && this.projectStatuses && this.projectStatuses[idx]
      ? this.projectStatuses[idx]
      : null;
  }
  renderStatusElements(status: ProjectStatus | null, _section_id: string) {
    if (!status) {
      return [<span style="color: gray;">{_("N/A")}</span>];
    }
    const startupFailed = status.startup_status === "failed";
    const statusColor =
      status.status === "running" && !startupFailed ? "green" : "#dc3545";
    let errorMessage = null as string | null;
    if (
      startupFailed &&
      status.error_code !== undefined &&
      status.error_code !== 0
    ) {
      errorMessage = getErrorMessage(status.error_code);
    }

    const statusBadgeAttrs: any = {
      class: "ifacebadge",
      style: "",
    };
    if (errorMessage) {
      statusBadgeAttrs.title = errorMessage;
      statusBadgeAttrs.style += " cursor: help;";
    }

    const statusElements: any[] = [
      <div>
        <span {...statusBadgeAttrs}>
          <strong
            style={`font-size: 1em; font-weight: 600; color: ${statusColor};`}
          >
            {translateStatus(
              startupFailed ? "failed" : status.status || "unknown",
            )}
          </strong>
        </span>
      </div>,
    ];

    if (errorMessage && status.status !== "stopped") {
      statusElements.push(
        <small style="color: #dc3545; margin-top: 0.3em;">
          {`\u26A0 ${errorMessage}`}
        </small>,
      );
    } else {
      const elements: any[] = [];
      if ((status.active_ports || 0) > 0) {
        elements.push(
          <span>{_("Ports: %d").format(status.active_ports || 0)}</span>,
        );
      }
      if ((status.active_sessions || 0) > 0) {
        if (elements.length > 0) elements.push(<br />);
        elements.push(
          <span>{_("Sessions: %d").format(status.active_sessions || 0)}</span>,
        );
      }
      if (status.bytes_in || 0 || status.bytes_out || 0) {
        if (elements.length > 0) elements.push(<br />);
        elements.push(
          <span>
            {"\u2193 " +
              formatBytes(status.bytes_in || 0) +
              " \u2191 " +
              formatBytes(status.bytes_out || 0)}
          </span>,
        );
      }

      if (status.forwarders && status.forwarders.length > 0) {
        if (elements.length > 0) elements.push(<br />);
        elements.push(this.renderForwarderStats(status.forwarders));
      }

      if (elements.length > 0) {
        statusElements.push(<small>{elements}</small>);
      }
    }

    return statusElements;
  }

  private renderForwarderStats(forwarders: ForwarderStats[]): HTMLElement {
    const themeColors = getThemeColors();
    const borderColor = themeColors.isDark ? "#333" : "#eee";
    const bgColor = themeColors.isDark ? "#222" : "#f8f9fa";
    const textColor = themeColors.isDark ? "#ccc" : "#6c757d";

    const rows = forwarders.map((f) => (
      <div
        style={`display: flex; gap: 0.5em; padding: 0.15em 0; font-size: 0.9em; border-bottom: 1px solid ${borderColor};`}
      >
        <span style={`min-width: 35px; color: ${textColor};`}>
          {f.protocol.toUpperCase()}
        </span>
        <span style="min-width: 45px;">:{f.local_port}</span>
        <span style="color: #28a745;">
          {`\u2193${formatBytes(f.bytes_in)}`}
        </span>
        <span style="color: #dc3545;">
          {`\u2191${formatBytes(f.bytes_out)}`}
        </span>
        <span style="color: #17a2b8;">{`S:${f.active_sessions || 0}`}</span>
      </div>
    ));

    return (
      <div
        style={`margin-top: 0.3em; padding: 0.3em; background: ${bgColor}; border-radius: 3px; max-height: 80px; overflow-y: auto;`}
      >
        {rows}
      </div>
    );
  }

  private updateFrpCard(
    status: FrpcStatus | FrpsStatus | undefined,
    globalVersion: string | undefined,
    enabledEl?: HTMLElement,
    versionEl?: HTMLElement,
    statusEl?: HTMLElement,
    infoEl?: HTMLElement,
    errorEl?: HTMLElement,
    type: "frpc" | "frps" = "frpc",
  ): void {
    const isEnabled = status?.enabled || false;

    if (enabledEl) {
      enabledEl.textContent = isEnabled ? _("Enabled") : _("Disabled");
      (enabledEl.style as any).color = isEnabled ? "#28a745" : "#6c757d";
    }

    if (versionEl) {
      versionEl.textContent = isEnabled && globalVersion ? globalVersion : "";
    }

    if (statusEl) {
      if (isEnabled && status?.status) {
        let statusText = status.status;
        let color = "#6c757d";

        switch (status.status) {
          case "running":
            statusText = _("Running");
            color = "#28a745";
            break;
          case "stopped":
            statusText = _("Stopped");
            color = "#dc3545";
            break;
          case "error":
            statusText = _("Error");
            color = "#dc3545";
            break;
        }

        statusEl.textContent = statusText;
        (statusEl.style as any).color = color;
        statusEl.style.display = "block";
      } else {
        statusEl.style.display = "none";
      }
    }

    if (infoEl) {
      if (isEnabled) {
        const parts: string[] = [];
        if (status?.client_count !== undefined) {
          parts.push(`${status.client_count} ${_("clients")}`);
        }
        if (type === "frps") {
          const frpsStatus = status as FrpsStatus;
          if (frpsStatus.proxy_count !== undefined) {
            parts.push(`${frpsStatus.proxy_count} ${_("proxies")}`);
          }
          if (frpsStatus.server_count !== undefined) {
            parts.push(`${frpsStatus.server_count} ${_("servers")}`);
          }
        }
        infoEl.textContent = parts.join(" | ");
        infoEl.style.display = parts.length > 0 ? "block" : "none";
      } else {
        infoEl.style.display = "none";
      }
    }

    if (errorEl) {
      if (status?.last_error) {
        const truncated =
          status.last_error.length > 50
            ? `${status.last_error.substring(0, 47)}...`
            : status.last_error;
        errorEl.title = status.last_error;
        errorEl.innerHTML = "";
        errorEl.appendChild(
          <strong style="font-size: 0.95em; font-weight: 600; color: #dc3545;">
            {truncated}
          </strong>,
        );
        errorEl.style.display = "block";
      } else {
        errorEl.style.display = "none";
      }
    }
  }

  private updateProjectHealthIndicator(): void {
    const enabledProjects =
      this.projectStatuses?.filter((p) => p.enabled) || [];
    const runningProjects = enabledProjects.filter(
      (p) => p.status === "running",
    );
    const healthElem = this.statusPanel?.projectHealthEl;
    if (healthElem) {
      const healthColor =
        runningProjects.length === enabledProjects.length
          ? "#28a745"
          : runningProjects.length > 0
            ? "#ffc107"
            : "#dc3545";
      healthElem.innerHTML = "";
      healthElem.appendChild(
        <span>
          <strong
            style={`font-size: 1.1em; font-weight: 600; color: ${healthColor};`}
          >
            {runningProjects.length} / {enabledProjects.length}
          </strong>
          <div style="font-size: 0.85em; color: #6c757d; margin-top: 0.3em;">
            {_("projects running")}
          </div>
        </span>,
      );
    }
  }

  private updateActivityLog(): void {
    const logContainer = this.statusPanel?.activityLogContainer;
    if (logContainer && this.events && this.events.length > 0) {
      const recentEvents = this.events.slice(-5).reverse();
      logContainer.innerHTML = "";
      for (const event of recentEvents) {
        logContainer.appendChild(this.renderEventRow(event));
      }
    }
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
      project_started: "\u25B6",
      project_stopped: "\u23F9",
      frp_error: "\u26A0",
      frp_connected: "\uD83D\uDD17",
      frp_disconnected: "\uD83D\uDD0C",
      config_changed: "\u2699",
    };

    const color = eventColors[event.type] || "#6c757d";
    const icon = eventIcons[event.type] || "\u2022";
    const time = this.formatTimestamp(event.timestamp);
    const truncatedMessage =
      event.message.length > 60
        ? `${event.message.substring(0, 57)}...`
        : event.message;

    return (
      <div style="display: flex; align-items: flex-start; padding: 0.3em 0; border-bottom: 1px solid #eee; font-size: 0.85em;">
        <span style={`color: ${color}; margin-right: 0.5em; flex-shrink: 0;`}>
          {icon}
        </span>
        <span style="color: #6c757d; margin-right: 0.5em; flex-shrink: 0; min-width: 70px;">
          {time}
        </span>
        <span style="flex: 1; word-break: break-word;" title={event.message}>
          {truncatedMessage}
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
}

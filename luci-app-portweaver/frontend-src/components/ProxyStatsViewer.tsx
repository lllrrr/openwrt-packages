import type { RpcClient } from "@/utils/rpc-client";
import type { FrpcProxy as FrpProxy } from "@/types/portweaver/frpc";
import { getThemeColors } from "@/utils/theme-utils";
import { translateStatus } from "@/utils/formatters";

interface ProxyStatsViewerProps {
  clientId: string;
  rpcClient: RpcClient;
  refreshInterval?: number;
}

export class ProxyStatsViewer {
  private clientId: string;
  private rpcClient: RpcClient;
  private statsEl: HTMLElement | null = null;
  private errorEl: HTMLElement | null = null;
  private loadingEl: HTMLElement | null = null;
  private refreshInterval: number | null = null;
  private refreshRate: number;
  private isPaused: boolean = false;
  private visibilityHandler: (() => void) | null = null;
  private lastStats: string = "";
  private retryCount: number = 0;
  private maxRetries: number = 3;

  constructor(props: ProxyStatsViewerProps) {
    this.clientId = props.clientId;
    this.rpcClient = props.rpcClient;
    this.refreshRate = props.refreshInterval ?? 5000;
  }

  private getStatsColors() {
    const { isDark } = getThemeColors();
    return {
      borderColor: isDark ? "#404040" : "#ddd",
      bgColor: isDark ? "#1e1e1e" : "#ffffff",
      innerBgColor: isDark ? "#2d2d2d" : "#f8f9fa",
      textColor: isDark ? "#e0e0e0" : "#333333",
      mutedTextColor: isDark ? "#aaa" : "#6c757d",
      successColor: isDark ? "#4CAF50" : "#28a745",
      errorColor: isDark ? "#FF5252" : "#dc3545",
      rowBorderColor: isDark ? "#333" : "#eee",
    };
  }

  render(): HTMLElement {
    const colors = this.getStatsColors();
    const container = (
      <div
        style={`padding: 12px; border: 1px solid ${colors.borderColor}; border-radius: 4px; background-color: ${colors.bgColor};`}
      ></div>
    );

    this.loadingEl = (
      <div style={`font-size: 14px; color: ${colors.textColor};`}>
        {_("Loading stats...")}
      </div>
    );
    container.appendChild(this.loadingEl);

    this.errorEl = (
      <div
        style={`color: ${colors.errorColor}; font-size: 14px; display: none;`}
      ></div>
    );
    container.appendChild(this.errorEl);

    this.statsEl = (
      <div style={`display: none; color: ${colors.textColor};`}></div>
    );
    container.appendChild(this.statsEl);

    this.fetchStats();
    this.refreshInterval = window.setInterval(
      () => this.fetchStats(),
      this.refreshRate,
    );

    this.visibilityHandler = () => this.handleVisibilityChange();
    document.addEventListener("visibilitychange", this.visibilityHandler);

    return container;
  }

  private handleVisibilityChange(): void {
    if (document.hidden) {
      this.isPaused = true;
    } else {
      this.isPaused = false;
      this.fetchStats();
    }
  }

  private async fetchStats(): Promise<void> {
    if (this.isPaused) return;

    try {
      const stats = await this.rpcClient.getFrpcProxyStats(this.clientId);
      const currentStats = JSON.stringify(stats);

      if (currentStats === this.lastStats) {
        return;
      }

      this.lastStats = currentStats;
      this.retryCount = 0;

      if (this.loadingEl) {
        this.loadingEl.style.display = "none";
      }
      if (this.errorEl) {
        this.errorEl.style.display = "none";
      }

      if (this.statsEl) {
        this.statsEl.style.display = "block";
        this.statsEl.textContent = "";

        const proxies = stats.proxies || [];

        if (!Array.isArray(proxies) || proxies.length === 0) {
          const colors = this.getStatsColors();
          this.statsEl.appendChild(
            <div style={`font-size: 14px; color: ${colors.textColor};`}>
              {_("No proxies configured")}
            </div>,
          );
          return;
        }

        const colors = this.getStatsColors();
        const hasError = proxies.some(
          (p: FrpProxy) => (p.err && p.err.length > 0) || p.status === "error",
        );
        const statusColor = hasError ? colors.errorColor : colors.successColor;
        const statusText = hasError ? _("error") : _("running");

        const statusBadge = (
          <div style="margin-bottom: 8px;">
            <span
              class="ifacebadge"
              style={`font-size: 1em; font-weight: 600; color: ${statusColor};`}
            >
              {translateStatus(statusText)}
            </span>
          </div>
        );

        this.statsEl.appendChild(statusBadge);

        const countEl = (
          <small
            style={`display: block; margin-bottom: 4px; color: ${colors.textColor};`}
          >
            <span>{_("Proxies: %d").format(proxies.length)}</span>
            <br />
          </small>
        );
        this.statsEl.appendChild(countEl);

        const container = (
          <div
            style={`margin-top: 0.3em; padding: 0.3em; background: ${colors.innerBgColor}; border-radius: 3px; max-height: 80px; overflow-y: auto;`}
          >
            {proxies.map((proxy: FrpProxy) => (
              <div
                style={`display: flex; gap: 0.5em; padding: 0.15em 0; font-size: 0.9em; border-bottom: 1px solid ${colors.rowBorderColor};`}
              >
                <span
                  style={`min-width: 35px; color: ${colors.mutedTextColor};`}
                >
                  {proxy.type.toUpperCase()}
                </span>
                <span style={`min-width: 45px; color: ${colors.textColor};`}>
                  {`:${proxy.cfg?.remotePort || proxy.remote_addr || "N/A"}`}
                </span>
                <span style={`color: ${colors.successColor};`}>↓0 B</span>
                <span style={`color: ${colors.errorColor};`}>↑0 B</span>
              </div>
            ))}
          </div>
        );

        this.statsEl.appendChild(container);
      }
    } catch (error) {
      this.retryCount++;

      if (this.retryCount < this.maxRetries) {
        const backoffDelay = Math.min(1000 * 2 ** this.retryCount, 30000);
        setTimeout(() => this.fetchStats(), backoffDelay);
        return;
      }

      if (this.loadingEl) {
        this.loadingEl.style.display = "none";
      }
      if (this.errorEl) {
        this.errorEl.style.display = "block";
        this.errorEl.textContent = _("Error: %s").format(
          error instanceof Error ? error.message : _("Unknown error"),
        );
      }
    }
  }

  destroy(): void {
    if (this.refreshInterval !== null) {
      clearInterval(this.refreshInterval);
      this.refreshInterval = null;
    }

    if (this.visibilityHandler) {
      document.removeEventListener("visibilitychange", this.visibilityHandler);
      this.visibilityHandler = null;
    }

    this.isPaused = true;
  }
}

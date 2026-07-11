import { LogViewerCore } from "./LogViewerCore";
import type { LogViewerCoreProps } from "./LogViewerCore";

export interface LogViewerDialogProps extends LogViewerCoreProps {}

export class LogViewerDialog {
  private props: LogViewerDialogProps;
  private core: LogViewerCore | null = null;
  private modal: HTMLElement | null = null;
  private isOpen: boolean = false;
  private statusSpan: HTMLElement | null = null;
  private errorSpan: HTMLElement | null = null;
  private pollInterval: number | null = null;

  constructor(props: LogViewerDialogProps) {
    this.props = props;
  }

  render(): HTMLElement {
    this.core = new LogViewerCore({
      ...this.props,
      showHeader: false,
    });
    this.core.render();

    const statusColor =
      {
        running: "#4CAF50",
        connected: "#4CAF50",
        connecting: "#FFC107",
        error: "#F44336",
        stopped: "#9E9E9E",
        unavailable: "#9E9E9E",
      }.unavailable || "#9E9E9E";

    this.statusSpan = (
      <span
        style={`display: inline-block; padding: 0.25em 0.6em; border-radius: 3px; background: ${statusColor}; color: white; font-weight: 600; font-size: 0.85em;`}
      >
        {_("unavailable")}
      </span>
    );

    this.errorSpan = (
      <div style="color: #F44336; margin-top: 0.3em; display:none"></div>
    );

    const header = (
      <div style="padding: 1em; border-bottom: 1px solid #dee2e6; display: flex; justify-content: space-between; align-items: center;">
        <div>
          <h4 style="margin: 0; font-size: 1.2em; font-weight: 600;">
            {this.props.title}
          </h4>
          <div style="font-size: 0.85em; color: #6c757d; margin-top: 0.3em;">
            {_("Status:")}
            {this.statusSpan}
            {this.errorSpan}
          </div>
        </div>
        <button
          type="button"
          onclick={() => this.close()}
          style="background: none; border: none; font-size: 1.5em; cursor: pointer; color: #6c757d;"
        >
          ×
        </button>
      </div>
    );

    const searchBar = this.core.getSearchBar();
    const logContainer = this.core.getLogContainer();
    const footer = this.core.getFooter();

    const closeFooterButton = (
      <button type="button" class="cbi-button" onclick={() => this.close()}>
        {_("Close")}
      </button>
    );

    const dialogFooter = (
      <div class="button-row">
        <span>{closeFooterButton}</span>
        <span>{footer ? Array.from(footer.children) : null}</span>
      </div>
    );

    const content = (
      <div
        class="modal cbi-modal cbi-section-node"
        role="dialog"
        aria-modal="true"
        style="width: 95vw; max-width: 1200px; max-height: 90vh; display: grid; grid-template-rows: auto auto 1fr auto;"
      >
        <div> {header}</div>
        <div>{searchBar}</div>
        <div style="max-height: min(calc(85vh - 220px), 100vh); border: 1px solid var(--cbi-border-color); border-radius: 4px; overflow: hidden; width: 100%; height: 100%; display: flex; flex-direction: column; overflow: hidden;">
          {logContainer}
        </div>
        <div> {dialogFooter}</div>
      </div>
    );

    this.modal = (
      <div
        style="position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; z-index: 9999;"
        onclick={(e: MouseEvent) => {
          if (e.target === e.currentTarget) this.close();
        }}
      >
        {content}
      </div>
    );

    return this.modal;
  }

  open(): void {
    if (this.isOpen) return;
    this.isOpen = true;
    const node = this.render();
    document.body.appendChild(node);
    if (this.core) {
      this.core.init();
      this.startStatusPolling();
    }
  }

  close(): void {
    if (!this.isOpen) return;
    this.isOpen = false;
    this.stopStatusPolling();
    if (this.core) {
      this.core.destroy();
    }
    this.modal?.parentElement?.removeChild(this.modal);
    this.modal = null;
    this.core = null;
    this.statusSpan = null;
    this.errorSpan = null;
  }

  private startStatusPolling(): void {
    this.updateStatus();
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
    }
    this.pollInterval = window.setInterval(() => {
      this.updateStatus();
    }, 3000);
  }

  private stopStatusPolling(): void {
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
  }

  private updateStatus(): void {
    if (!this.core) return;

    this.props
      .fetcher(this.props.name)
      .then((response) => {
        const status = response.status || "unavailable";
        const lastError = response.last_error || "";

        const statusColor =
          {
            running: "#4CAF50",
            connected: "#4CAF50",
            connecting: "#FFC107",
            error: "#F44336",
            stopped: "#9E9E9E",
            unavailable: "#9E9E9E",
          }[status] || "#9E9E9E";

        if (this.statusSpan) {
          this.statusSpan.textContent = status;
          this.statusSpan.setAttribute(
            "style",
            `display: inline-block; padding: 0.25em 0.6em; border-radius: 3px; background: ${statusColor}; color: white; font-weight: 600; font-size: 0.85em;`,
          );
        }

        if (this.errorSpan) {
          if (lastError) {
            this.errorSpan.style.display = "block";
            this.errorSpan.textContent = lastError;
          } else {
            this.errorSpan.style.display = "none";
          }
        }
      })
      .catch((err: any) => {
        console.error("Failed to fetch status:", err);
        if (this.statusSpan) {
          this.statusSpan.textContent = _("error");
          this.statusSpan.setAttribute(
            "style",
            `display: inline-block; padding: 0.25em 0.6em; border-radius: 3px; background: #F44336; color: white; font-weight: 600; font-size: 0.85em;`,
          );
        }
      });
  }
}

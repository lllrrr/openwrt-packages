/**
 * NftablesRulesViewer - Displays nftables rules for the portweaver table
 *
 * Shows the current nftables rules managed by PortWeaver in a syntax-highlighted view.
 */

export class NftablesRulesViewer {
  private rulesContainer: HTMLElement | null = null;
  private statusSpan: HTMLElement | null = null;
  private refreshBtn: HTMLElement | null = null;
  private rules: string = "";
  private loading: boolean = false;

  render(): HTMLElement {
    this.statusSpan = <span style="color: #666;">Loading...</span>;
    this.rulesContainer = (
      <pre
        style="
          background: #1e1e1e;
          color: #d4d4d4;
          padding: 16px;
          border-radius: 8px;
          overflow-x: auto;
          font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
          font-size: 13px;
          line-height: 1.5;
          max-height: 600px;
          overflow-y: auto;
          margin: 0;
        "
      >
        Loading nftables rules...
      </pre>
    ) as HTMLElement;

    this.refreshBtn = (
      <button
        type="button"
        class="btn cbi-button-action"
        style="margin-bottom: 12px;"
        onclick={() => this.loadRules()}
      >
        Refresh
      </button>
    ) as HTMLElement;

    const container = (
      <div>
        <div style="margin-bottom: 12px; display: flex; align-items: center; gap: 12px;">
          {this.refreshBtn}
          {this.statusSpan}
        </div>
        <div style="margin-bottom: 8px; color: #666; font-size: 12px;">
          Table: <code>inet portweaver</code>
        </div>
        {this.rulesContainer}
      </div>
    ) as HTMLElement;

    // Load rules on render
    this.loadRules();

    return container;
  }

  private async loadRules(): Promise<void> {
    if (this.loading) return;

    this.loading = true;
    if (this.statusSpan) {
      this.statusSpan.textContent = "Loading...";
      this.statusSpan.style.color = "#666";
    }
    if (this.refreshBtn) {
      this.refreshBtn.setAttribute("disabled", "true");
    }

    try {
      const rpc = (window as any).L?.rpc;
      if (!rpc) {
        throw new Error("RPC not available");
      }

      const result = await rpc
        .declare({
          object: "portweaver",
          method: "get_nftables_rules",
        })
        .call();

      if (result?.rules) {
        this.rules = result.rules;
        this.updateDisplay();
        if (this.statusSpan) {
          this.statusSpan.textContent = "Rules loaded";
          this.statusSpan.style.color = "#4caf50";
        }
      } else {
        if (this.statusSpan) {
          this.statusSpan.textContent =
            "No rules found or nftables not available";
          this.statusSpan.style.color = "#ff9800";
        }
        if (this.rulesContainer) {
          this.rulesContainer.textContent =
            "No nftables rules found. Make sure nftables is enabled and the portweaver table exists.";
        }
      }
    } catch (err) {
      console.error("Failed to load nftables rules:", err);
      if (this.statusSpan) {
        this.statusSpan.textContent = `Error: ${(err as Error)?.message || String(err)}`;
        this.statusSpan.style.color = "#f44336";
      }
      if (this.rulesContainer) {
        this.rulesContainer.textContent = `Failed to load nftables rules: ${(err as Error)?.message || String(err)}`;
      }
    } finally {
      this.loading = false;
      if (this.refreshBtn) {
        this.refreshBtn.removeAttribute("disabled");
      }
    }
  }

  private updateDisplay(): void {
    if (!this.rulesContainer) return;

    if (!this.rules || this.rules.trim().length === 0) {
      this.rulesContainer.textContent = "No rules in portweaver table.";
      return;
    }

    // Syntax highlighting
    const highlighted = this.highlightSyntax(this.rules);
    this.rulesContainer.innerHTML = highlighted;
  }

  private highlightSyntax(rules: string): string {
    // Escape HTML
    let html = rules
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");

    // Highlight keywords
    html = html.replace(
      /\b(table|chain|rule|set|map|element|flush|add|delete|list|type|hook|priority|policy|accept|drop|reject|queue|jump|goto|return|comment)\b/g,
      '<span style="color: #569cd6;">$1</span>',
    );

    // Highlight types
    html = html.replace(
      /\b(filter|nat|route|inet|ip|ip6|arp|bridge|ingress|prerouting|input|forward|output|postrouting)\b/g,
      '<span style="color: #4ec9b0;">$1</span>',
    );

    // Highlight protocols
    html = html.replace(
      /\b(tcp|udp|icmp|icmpv6|esp|ah|sctp)\b/g,
      '<span style="color: #c586c0;">$1</span>',
    );

    // Highlight numbers and ports
    html = html.replace(
      /\b(\d+)\b/g,
      '<span style="color: #b5cea8;">$1</span>',
    );

    // Highlight IP addresses
    html = html.replace(
      /\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(\/\d{1,2})?)\b/g,
      '<span style="color: #ce9178;">$1</span>',
    );

    // Highlight strings in quotes
    html = html.replace(
      /"([^"]*)"/g,
      '<span style="color: #ce9178;">"$1"</span>',
    );

    // Highlight comments
    html = html.replace(
      /(#[^\n]*)/g,
      '<span style="color: #6a9955;">$1</span>',
    );

    // Highlight PORTWEAVER comments
    html = html.replace(
      /(PORTWEAVER_\w+)/g,
      '<span style="color: #dcdcaa; font-weight: bold;">$1</span>',
    );

    return html;
  }
}

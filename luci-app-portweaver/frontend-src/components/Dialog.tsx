import { getThemeColors } from "../utils/theme-utils";

export interface DialogOptions {
  title?: string;
  message: string | HTMLElement | (string | HTMLElement)[];
  type: "alert" | "confirm";
  confirmText?: string;
  cancelText?: string;
}

export class Dialog {
  private overlay: HTMLElement | null = null;
  private container: HTMLElement | null = null;
  private titleEl: HTMLElement | null = null;
  private contentEl: HTMLElement | null = null;
  private footerEl: HTMLElement | null = null;
  private confirmBtn: HTMLButtonElement | null = null;
  private cancelBtn: HTMLButtonElement | null = null;

  private resolve: ((value: boolean) => void) | null = null;

  render(): HTMLElement {
    if (this.overlay) return this.overlay;

    this.titleEl = (
      <h2 style="margin: 0; font-size: 1.25rem; font-weight: 600;">
        {_("Dialog")}
      </h2>
    ) as HTMLElement;
    this.contentEl = (
      <div style="overflow-y: auto; max-height: 70vh;"></div>
    ) as HTMLElement;

    this.confirmBtn = (
      <button
        type="button"
        class="cbi-button cbi-button-positive"
        onclick={() => this.close(true)}
      ></button>
    ) as HTMLButtonElement;

    this.cancelBtn = (
      <button
        type="button"
        class="cbi-button cbi-button-neutral"
        onclick={() => this.close(false)}
      ></button>
    ) as HTMLButtonElement;

    this.footerEl = (
      <div style="display: flex; justify-content: flex-end; gap: 0.5rem;">
        {this.cancelBtn}
        {this.confirmBtn}
      </div>
    ) as HTMLElement;

    this.container = (
      <div
        role="dialog"
        aria-modal="true"
        style="display: flex; flex-direction: column; max-width: 90%; min-width: 320px; box-shadow: 0 4px 12px rgba(0,0,0,0.15); border-radius: 4px; animation: fadeIn 0.2s ease-out;"
      >
        {this.titleEl}
        {this.contentEl}
        {this.footerEl}
      </div>
    ) as HTMLElement;

    this.overlay = (
      <div style="position: fixed; top: 0; left: 0; width: 100%; height: 100%; z-index: 9999; display: none; align-items: center; justify-content: center; background-color: rgba(0,0,0,0.5); backdrop-filter: blur(2px);">
        {this.container}
      </div>
    ) as HTMLElement;

    return this.overlay;
  }

  private updateTheme(): void {
    if (!this.container || !this.titleEl || !this.contentEl || !this.footerEl)
      return;

    const theme = getThemeColors();
    const isDark = theme.isDark;

    const bg = isDark ? "#2d2d2d" : "#ffffff";
    const text = isDark ? "#e0e0e0" : "#333333";
    const border = isDark ? "#404040" : "#e0e0e0";
    const footerBg = isDark ? "#252525" : "#f8f9fa";

    this.container.style.backgroundColor = bg;
    this.container.style.color = text;

    this.titleEl.style.borderBottom = `1px solid ${border}`;
    this.titleEl.style.padding = "1rem 1.5rem";

    this.contentEl.style.padding = "1.5rem";

    this.footerEl.style.backgroundColor = footerBg;
    this.footerEl.style.borderTop = `1px solid ${border}`;
    this.footerEl.style.padding = "1rem 1.5rem";
    this.footerEl.style.borderBottomLeftRadius = "4px";
    this.footerEl.style.borderBottomRightRadius = "4px";
  }

  open(options: DialogOptions): Promise<boolean> {
    if (!this.overlay) this.render();

    this.updateTheme();

    if (this.titleEl) {
      if (options.title === undefined) {
        this.titleEl.textContent =
          options.type === "alert" ? _("Alert") : _("Confirm");
        this.titleEl.style.display = "";
      } else if (options.title === null) {
        this.titleEl.style.display = "none";
      } else {
        this.titleEl.textContent = options.title;
        this.titleEl.style.display = "";
      }
    }

    if (this.contentEl) {
      this.contentEl.textContent = "";
      const msg = options.message;
      if (Array.isArray(msg)) {
        msg.forEach((m) => {
          if (typeof m === "string") {
            this.contentEl?.appendChild(document.createTextNode(m));
          } else {
            this.contentEl?.appendChild(m);
          }
        });
      } else if (typeof msg === "string") {
        this.contentEl.textContent = msg;
      } else {
        this.contentEl.appendChild(msg);
      }
    }

    if (this.confirmBtn) {
      this.confirmBtn.textContent = options.confirmText || _("OK");
    }

    if (this.cancelBtn) {
      this.cancelBtn.textContent = options.cancelText || _("Cancel");
      this.cancelBtn.style.display = options.type === "alert" ? "none" : "";
    }

    if (this.overlay) {
      this.overlay.style.display = "flex";
    }

    setTimeout(() => {
      if (this.confirmBtn) this.confirmBtn.focus();
    }, 50);

    document.addEventListener("keydown", this.handleKeydown);

    return new Promise<boolean>((resolve) => {
      this.resolve = resolve;
    });
  }

  close(result: boolean): void {
    if (this.overlay) {
      this.overlay.style.display = "none";
    }
    document.removeEventListener("keydown", this.handleKeydown);
    if (this.resolve) {
      this.resolve(result);
      this.resolve = null;
    }
  }

  private handleKeydown = (e: KeyboardEvent): void => {
    if (e.key === "Escape") {
      this.close(false);
    }
  };
}

import { Client } from "./modules/client";
import type { FullStatusResponse, VersionResponse } from "./types/portweaver";
import frpc from "./modules/frpc";
import frps from "./modules/frps";
import config from "./modules/config";
import header from "./modules/header";
import logs from "./modules/logs";
import ddns from "./modules/ddns";
import nftables from "./modules/nftables";
import about from "./modules/about";
import wol from "./modules/wol";
import { rpcClient } from "./utils/rpc-client";
import { setVersionInfo, isFeatureEnabled } from "./utils/feature";

const form = L.form;
const uci = L.uci;
type UnwrapPromise<T> = T extends Promise<infer R> ? R : T;
export class main extends L.view {
  private mapInstance?: LuCI.form.Map;

  override async load() {
    return Promise.all([
      uci.load("portweaver"),
      uci.load("firewall"),
      rpcClient
        .getFullStatus()
        .then((res: FullStatusResponse) => res || {})
        .catch((err: any) => {
          console.warn("ubus get_full_status failed:", err);
          return {} as FullStatusResponse;
        }),
      L.fs
        .exec("/usr/bin/portweaver", ["version", "--json"])
        .then((res: any) => {
          if (res && res.code === 0 && res.stdout) {
            try {
              const info = JSON.parse(res.stdout) as VersionResponse;
              setVersionInfo(info);
              return info;
            } catch (e) {
              console.warn("Failed to parse portweaver version JSON:", e);
            }
          }
          return null;
        })
        .catch((err: any) => {
          console.warn("exec portweaver version failed:", err);
          return null;
        }),
    ]);
  }

  override render(data: UnwrapPromise<ReturnType<typeof this.load>>) {
    const m = new form.Map(
      "portweaver",
      _("PortWeaver"),
      _("Port forwarding and NAT traversal configuration"),
    );
    this.mapInstance = m;

    const s = m.section(form.NamedSection, "global", "portweaver");
    s.anonymous = true;
    s.addremove = false;

    s.tab("settings", _("Global Settings"));
    s.tab("projects", _("Port Forwarding"));
    if (isFeatureEnabled("wol_mode")) {
      s.tab("wol", _("Wake-on-LAN"));
    }
    if (isFeatureEnabled("ddns_mode")) {
      s.tab("ddns", _("DDNS"));
    }
    if (isFeatureEnabled("frpc_mode")) {
      s.tab("frpc", _("FRP Tunnels"));
    }
    if (isFeatureEnabled("frps_mode")) {
      s.tab("frps", _("FRP Server"));
    }
    if (isFeatureEnabled("nftables_mode")) {
      s.tab("nftables", _("nftables"));
    }
    s.tab("logs", _("System Logs"));
    s.tab("about", _("About"));

    const fullStatus: FullStatusResponse = data[2] as FullStatusResponse;
    const versionInfo = data[3] as VersionResponse | null;
    const client = new Client(fullStatus);

    header(m, s, client, "settings");
    config(m, s, client, "projects");
    if (isFeatureEnabled("wol_mode")) {
      wol(m, s, "wol");
    }
    if (isFeatureEnabled("ddns_mode")) {
      ddns(m, s, "ddns");
    }
    if (isFeatureEnabled("frpc_mode")) {
      frpc(m, s, "frpc");
    }
    if (isFeatureEnabled("frps_mode")) {
      frps(m, s, "frps");
    }
    if (isFeatureEnabled("nftables_mode")) {
      nftables(m, s, "nftables");
    }
    logs(m, s, "logs");
    about(m, s, "about", versionInfo);

    return m.render();
  }

  override async handleSave() {
    if (this.mapInstance) {
      await this.mapInstance.save();
    }
  }

  override async handleReset() {
    if (this.mapInstance) {
      await this.mapInstance.reset();
    }
  }

  override handleSaveApply = null as any;

  async handleSaveReload() {
    try {
      await this.handleSave();
      await L.uci.save();
      await rpcClient.uciCommit("portweaver");
      const result = await rpcClient.reloadConfig();
      L.ui.addNotification(
        null,
        <p>
          {_("Config reloaded: %d project(s) restarted").format(result.changes)}
        </p>,
        "info",
      );
      location.reload();
    } catch (err: any) {
      L.ui.addNotification(
        null,
        <p>{_("Failed to reload config: %s").format(err.toString())}</p>,
        "error",
      );
    }
  }

  async handleSaveRestart() {
    await this.handleSave();
    const uiChanges = (L as any).ui.changes;
    const applyPromise =
      uiChanges && typeof uiChanges.apply === "function"
        ? uiChanges.apply(true)
        : L.uci.apply();

    return applyPromise.then(() => {
      return L.fs
        .exec("/etc/init.d/portweaver", ["restart"])
        .then(() => {
          L.ui.addNotification(
            null,
            <p>{_("Service restarted successfully")}</p>,
            "info",
          );
        })
        .catch((err: any) => {
          L.ui.addNotification(
            null,
            <p>{_("Failed to restart service: %s").format(err.toString())}</p>,
            "error",
          );
        });
    });
  }

  addFooter(): DocumentFragment {
    const fragment = document.createDocumentFragment();

    const pageActions = (
      <div class="cbi-page-actions">
        <button
          type="button"
          class="cbi-button cbi-button-apply"
          onclick={() => this.handleSaveReload()}
        >
          {_("Save & Reload")}
        </button>
        <button
          type="button"
          class="cbi-button cbi-button-apply"
          style="margin-left: 8px;"
          onclick={() => this.handleSaveRestart()}
        >
          {_("Save & Restart")}
        </button>
        <button
          type="button"
          class="cbi-button cbi-button-save"
          style="margin-left: 8px;"
          onclick={() => this.handleSave()}
        >
          {_("Save")}
        </button>
        <button
          type="button"
          class="cbi-button cbi-button-reset"
          style="margin-left: 8px;"
          onclick={() => this.handleReset()}
        >
          {_("Reset")}
        </button>
      </div>
    );

    fragment.appendChild(pageActions);
    return fragment;
  }
}

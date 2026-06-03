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
import { rpcClient } from "./utils/rpc-client";

const form = L.form;
const uci = L.uci;
type UnwrapPromise<T> = T extends Promise<infer R> ? R : T;
export class main extends L.view {
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
      rpcClient
        .getVersion()
        .then((res) => res || null)
        .catch((err: any) => {
          console.warn("ubus get_version failed:", err);
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

    const s = m.section(form.NamedSection, "global", "portweaver");
    s.anonymous = true;
    s.addremove = false;

    s.tab("settings", _("Global Settings"));
    s.tab("projects", _("Port Forwarding"));
    s.tab("ddns", _("DDNS"));
    s.tab("frpc", _("FRP Tunnels"));
    s.tab("frps", _("FRP Server"));
    s.tab("nftables", _("nftables"));
    s.tab("logs", _("System Logs"));
    s.tab("about", _("About"));

    const fullStatus: FullStatusResponse = data[2] as FullStatusResponse;
    const versionInfo = data[3] as VersionResponse | null;
    const client = new Client(fullStatus);

    header(m, s, client, "settings");
    config(m, s, client, "projects");
    ddns(m, s, "ddns");
    frpc(m, s, "frpc");
    frps(m, s, "frps");
    nftables(m, s, "nftables");
    logs(m, s, "logs");
    about(m, s, "about", versionInfo);

    return m.render();
  }
}

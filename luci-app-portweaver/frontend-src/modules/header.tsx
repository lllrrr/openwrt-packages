import { StatusPanel } from "@/components/StatusPanel";
import { rpcClient } from "@/utils/rpc-client";
import { isFeatureEnabled } from "@/utils/feature";
const form = L.form;
import type { Client } from "./client";

export default function (
  _m: LuCI.form.Map,
  s: LuCI.form.NamedSection,
  client: Client,
  tab_id: string,
) {
  {
    const o = s.taboption(tab_id, form.Flag, "enabled", _("Enable PortWeaver"));
    o.default = "1";
    o.rmempty = false;

    if (isFeatureEnabled("nftables_mode")) {
      const o = s.taboption(
        tab_id,
        form.Flag,
        "use_nftables",
        _("Use nftables"),
      );
      o.default = "0";
      o.rmempty = false;
      o.description = _(
        "Use nftables instead of OpenWrt firewall (fw4). Requires nftables package installed.",
      );
      o.default = "1";
      o.rmempty = false;
    }
  }
  {
    const o = s.taboption(
      tab_id,
      form.DummyValue,
      "_runtime_status",
      _("Runtime Status"),
    );
    o.rawhtml = true;
    o.cfgvalue = () => {
      const panel = new StatusPanel();
      client.statusPanel = panel;
      return panel.render(
        client.globalStatus,
        client.frpStatus,
        client.projectStatuses,
        client.events,
        client.ddnsGlobalStatus,
      );
    };
  }

  const o = s.taboption(
    tab_id,
    form.Button,
    "_reload_config",
    _("Reload Config"),
  );
  o.modalonly = false;
  o.editable = true;
  o.inputtitle = _("Reload");
  o.onclick = async () => {
    try {
      await _m.save();
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
    } catch (err) {
      L.ui.addNotification(
        null,
        <p>
          {_("Failed to reload config: %s").format(
            (err as { message: string })?.message || String(err),
          )}
        </p>,
        "error",
      );
    }
  };
  const runtimeToggle = async (section_id: string) => {
    const idx = client.getProjectIndex(section_id);
    if (idx < 0) {
      L.ui.addNotification(
        null,
        <p>{_("Could not determine project index")}</p>,
        "error",
      );
      return Promise.resolve();
    }
    const status = client.getProjectStatus(section_id);
    const newEnabled = !status?.enabled;
    try {
      await rpcClient.setEnabled(idx, !!newEnabled);
      L.ui.addNotification(
        null,
        <p>
          {_("Runtime state updated to: %s").format(
            newEnabled ? _("enabled") : _("disabled"),
          )}
        </p>,
        "info",
      );
      const fullStatus = await rpcClient.getFullStatus();
      if (fullStatus) {
        client.globalStatus = {
          status: fullStatus.status,
          total_projects: fullStatus.total_projects,
          active_ports: fullStatus.active_ports,
          uptime: fullStatus.uptime,
          total_bytes_in: fullStatus.total_bytes_in,
          total_bytes_out: fullStatus.total_bytes_out,
        };
        client.projectStatuses = (fullStatus.projects || []).map(
          (p: import("@/types/portweaver").FullStatusProject) => ({
            enabled: p.enabled,
            status: p.status,
            startup_status: p.startup_status,
            error_code: p.error_code,
            active_ports: p.active_ports,
            bytes_in: p.bytes_in,
            bytes_out: p.bytes_out,
            forwarders: p.forwarders,
          }),
        );
      }
      location.reload();
    } catch (err) {
      L.ui.addNotification(
        null,
        <p>
          {_("Failed to toggle runtime state: %s").format(
            (err as { message: string })?.message || String(err),
          )}
        </p>,
        "error",
      );
    }
  };
  (window as any).portweaverToggle = runtimeToggle;
  const restartProject = async (section_id: string) => {
    const idx = client.getProjectIndex(section_id);
    if (idx < 0) {
      L.ui.addNotification(
        null,
        <p>{_("Could not determine project index")}</p>,
        "error",
      );
      return Promise.resolve();
    }
    try {
      await rpcClient.restartProject(idx);
      L.ui.addNotification(
        null,
        <p>{_("Project restarted successfully")}</p>,
        "info",
      );
      const fullStatus = await rpcClient.getFullStatus();
      if (fullStatus) {
        client.globalStatus = {
          status: fullStatus.status,
          total_projects: fullStatus.total_projects,
          active_ports: fullStatus.active_ports,
          uptime: fullStatus.uptime,
          total_bytes_in: fullStatus.total_bytes_in,
          total_bytes_out: fullStatus.total_bytes_out,
        };
        client.projectStatuses = (fullStatus.projects || []).map(
          (p: import("@/types/portweaver").FullStatusProject) => ({
            enabled: p.enabled,
            status: p.status,
            startup_status: p.startup_status,
            error_code: p.error_code,
            active_ports: p.active_ports,
            bytes_in: p.bytes_in,
            bytes_out: p.bytes_out,
            forwarders: p.forwarders,
          }),
        );
      }
      location.reload();
    } catch (err) {
      L.ui.addNotification(
        null,
        <p>
          {_("Failed to restart project: %s").format(
            (err as { message: string })?.message || String(err),
          )}
        </p>,
        "error",
      );
    }
  };
  (window as any).portweaverRestart = restartProject;
}

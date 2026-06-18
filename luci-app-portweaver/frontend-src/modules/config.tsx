import type { Client } from "./client";
import { isFeatureEnabled } from "../utils/feature";
import FrpNodeSelector from "../components/FrpNodeSelector";
import PortMappingEditor from "../components/PortMappingEditor";
import { rpcClient } from "@/utils/rpc-client";
const form = L.form;
const uci = L.uci;

export default function (
  _m: LuCI.form.Map,
  s: LuCI.form.NamedSection,
  client: Client,
  tab_id: string,
) {
  const o0 = s.taboption(
    tab_id,
    form.SectionValue,
    "_projects",
    form.GridSection,
    "project",
  );

  const ss = o0.subsection as LuCI.form.TableSection;
  ss.anonymous = true;
  ss.addremove = true;
  ss.sortable = true;
  ss.cloneable = true;

  ss.sectiontitle = (section_id: string) =>
    uci.get("portweaver", section_id, "remark")?.toString() ||
    _("Unnamed project");
  {
    const o = ss.option(form.DummyValue, "_runtime_status", _("Status"));
    o.modalonly = false;
    o.textvalue = (section_id: string) => {
      const status = client.getProjectStatus(section_id);
      const container = (
        <div id={`project-status-${section_id}`}>
          {client.renderStatusElements(status, section_id)}
        </div>
      ) as HTMLElement;
      client.projectContainers = client.projectContainers || {};
      client.projectContainers[section_id] = container;
      return container;
    };
  }
  {
    const o = ss.option(form.Button, "_runtime_toggle", _("Toggle"));
    o.modalonly = false;
    o.editable = true;
    o.inputtitle = (section_id: string) => {
      const status = client.getProjectStatus(section_id);
      return status?.enabled ? _("Disable") : _("Enable");
    };
    o.onclick = (_ev: any, section_id: string) =>
      (window as any).portweaverToggle(section_id);
  }
  {
    const o = ss.option(form.Button, "_runtime_restart", _("Restart"));
    o.modalonly = false;
    o.editable = true;
    o.inputtitle = _("Restart");
    o.onclick = (_ev: any, section_id: string) =>
      (window as any).portweaverRestart(section_id);
  }
  {
    const o = ss.option(form.Flag, "enabled", _("Enabled"));
    o.modalonly = false;
    o.default = "1";
    o.editable = true;
  } // Preview column
  {
    const o = ss.option(form.DummyValue, "_preview", _("Overview"));
    o.modalonly = false;
    o.textvalue = (section_id: string) => {
      const protocol =
        uci.get("portweaver", section_id, "protocol")?.toString() || "tcp";
      const family =
        uci.get("portweaver", section_id, "family")?.toString() || "any";
      const listen_port =
        uci.get("portweaver", section_id, "listen_port")?.toString() || "";
      const target_address =
        uci.get("portweaver", section_id, "target_address")?.toString() || "";
      const target_port =
        uci.get("portweaver", section_id, "target_port")?.toString() || "";
      const port_mappings = L.toArray<string>(
        uci.get("portweaver", section_id, "port_mapping"),
      );
      const src_zones = L.toArray<string>(
        uci.get("portweaver", section_id, "src_zone"),
      );
      const dest_zones = L.toArray<string>(
        uci.get("portweaver", section_id, "dest_zone"),
      );

      const proto_text: string =
        (
          {
            both: _("TCP and UDP"),
            tcp: _("TCP"),
            udp: _("UDP"),
          } as any
        )[protocol] || String(protocol).toUpperCase();
      const family_text: string =
        (
          {
            any: _("IPv4 and IPv6"),
            ipv4: _("IPv4"),
            ipv6: _("IPv6"),
          } as any
        )[family] || family;

      const lines: any[] = [];
      lines.push(
        <span>
          {_("Incoming ")}
          <var>{family_text}</var>
          {_(" protocol ")}
          <var>{proto_text}</var>
        </span>,
      );

      if (src_zones.length > 0) {
        const src_badges = src_zones.map((z: string) => (
          <span class="zonebadge" style={fwmodel.getZoneColorStyle(z)}>
            <strong>{z || <em>{_("any zone")}</em>}</strong>
          </span>
        ));
        lines.push(<br />);
        lines.push(
          <span>
            {_("From ")}
            {...src_badges}
          </span>,
        );
      }

      if (port_mappings.length > 0) {
        lines.push(<br />);
        lines.push(
          <span>
            <strong style="color: #09c;">{_("Multi-Port")}</strong>
            {_(" - ")}
            <var>{port_mappings.length}</var>
            {_(" mapping(s)")}
          </span>,
        );
        const first = port_mappings[0];
        lines.push(<br />);
        lines.push(
          <span>
            {_("e.g. ")}
            <var>{first}</var>
          </span>,
        );
      } else if (listen_port) {
        lines.push(<br />);
        lines.push(
          <span>
            {_("Port ")}
            <var>{listen_port}</var>
          </span>,
        );
      }

      lines.push(<br />);
      lines.push(
        <span>
          <var data-tooltip="Forward">{_("Forward")}</var>
          {_(" to ")}
        </span>,
      );

      if (dest_zones.length > 0) {
        const dest_badges = dest_zones.map((z: string) => (
          <span class="zonebadge" style={fwmodel.getZoneColorStyle(z)}>
            <strong>{z || <em>{_("any zone")}</em>}</strong>
          </span>
        ));
        lines.push(...dest_badges);
        lines.push(_(" "));
      }

      if (target_address) {
        lines.push(
          <span>
            {_("IP ")}
            <var>{target_address}</var>
          </span>,
        );
      }
      if (port_mappings.length === 0 && target_port) {
        lines.push(
          <span>
            {_(" port ")}
            <var>{target_port}</var>
          </span>,
        );
      }
      return <small>{lines}</small>;
    };
  }
  {
    // Modal configuration fields
    const o = ss.option(form.Value, "remark", _("Remark"));
    o.modalonly = true;
    o.rmempty = false;
    o.datatype = "string";
    o.validate = (_section_id: string, value: unknown) => {
      if (!value || String(value).trim() === "")
        return _("This field is required");
      return true;
    };
    o.placeholder = "My Project";
  }
  {
    const o = ss.option(form.Flag, "enabled", _("Enabled"));
    o.modalonly = true;
    o.default = "1";
  }
  {
    const o = ss.option(widgets.ZoneSelect, "src_zone", _("Source Zones"));
    o.modalonly = true;
    o.multiple = true;
    o.nocreate = false;
    o.allowlocal = false;
    o.default = "wan";
    o.rmempty = true;
  }
  {
    const o = ss.option(
      widgets.ZoneSelect,
      "dest_zone",
      _("Destination Zones"),
    );
    o.modalonly = true;
    o.multiple = true;
    o.nocreate = false;
    o.allowlocal = false;
    o.default = "lan";
    o.rmempty = true;
  }
  {
    const o = ss.option(form.ListValue, "family", _("Address Family"));
    o.modalonly = true;
    o.value("any", _("IPv4 and IPv6"));
    o.value("ipv4", "IPv4");
    o.value("ipv6", "IPv6");
    o.default = "any";
  }
  {
    const o = ss.option(form.Value, "target_address", _("Target Address"));
    o.modalonly = true;
    o.rmempty = false;
    o.datatype = "host";
    o.placeholder = "192.168.1.100";
    o.validate = (_section_id, value) => {
      if (!value || String(value).trim() === "")
        return _("This field is required");
      return true;
    };
  }

  {
    // Port mode switcher
    const o = ss.option(
      form.Flag,
      "use_port_mappings",
      _("Use Port Mappings Mode"),
    );
    o.modalonly = true;
    o.rmempty = true;
    o.default = "0";
    o.description = _(
      "Enable to configure multiple port mappings or port ranges. Disable for single port mode.",
    );
  }
  {
    // Single port mode
    const o = ss.option(form.ListValue, "protocol", _("Protocol"));
    o.modalonly = true;
    o.value("both", _("TCP and UDP"));
    o.value("tcp", "TCP");
    o.value("udp", "UDP");
    o.default = "tcp";
    o.depends("use_port_mappings", "0");
  }
  {
    if (isFeatureEnabled("frpc_mode")) {
      // FRP node selector component factory
      const o = ss.option(FrpNodeSelector, "frp_nodes", _("FRP Tunnels"));
      o.modalonly = true;
      o.rmempty = true;
      o.depends("use_port_mappings", "0");
    }
  }
  {
    // Port Mapping Editor component factory
    const o = ss.option(PortMappingEditor, "port_mapping", _("Port Mappings"));
    o.modalonly = true;
    o.depends("use_port_mappings", "1");
  }
  {
    const o = ss.option(form.Value, "listen_port", _("Listen Port"));
    o.modalonly = true;
    o.datatype = "port";
    o.placeholder = "8080";
    o.depends("use_port_mappings", "0");
    o.validate = (section_id, value) => {
      const use_mappings = uci.get(
        "portweaver",
        section_id,
        "use_port_mappings",
      );
      if (use_mappings !== "1") {
        if (!value || String(value).trim() === "")
          return _("This field is required in single port mode");
      }
      return true;
    };
  }
  {
    const o = ss.option(form.Value, "target_port", _("Target Port"));
    o.modalonly = true;
    o.datatype = "port";
    o.placeholder = "80";
    o.depends("use_port_mappings", "0");
    o.validate = (section_id, value) => {
      const use_mappings = uci.get(
        "portweaver",
        section_id,
        "use_port_mappings",
      );
      if (use_mappings !== "1") {
        if (!value || String(value).trim() === "")
          return _("This field is required in single port mode");
      }
      return true;
    };
  }
  {
    const o = ss.option(
      form.Flag,
      "open_firewall_port",
      _("Open Firewall Port"),
    );
    o.modalonly = true;
    o.default = "1";
  }
  {
    const o = ss.option(
      form.Flag,
      "enable_app_forward",
      _("Enable App Level Forward"),
    );
    o.modalonly = true;
    o.default = "0";
  }
  {
    const o = ss.option(
      form.ListValue,
      "app_forward_loop_mode",
      _("Loop Mode"),
      _(
        "Controls how event loop runtimes are shared among listeners. " +
          "'per_project' (default): one runtime shared by all listeners in this project, balanced resource usage. " +
          "'per_listener': each listener gets its own dedicated runtime, highest isolation but uses more memory (one thread per listener). " +
          "'global': all projects share a single global runtime, lowest memory usage but no isolation between projects.",
      ),
    );
    o.modalonly = true;
    o.value("per_project", _("Per Project (default) - balanced"));
    o.value("per_listener", _("Per Listener - highest isolation, more memory"));
    o.value("global", _("Global - lowest memory, no isolation"));
    o.default = "per_project";
    o.depends("enable_app_forward", "1");
  }
  {
    const o = ss.option(form.Flag, "reuseaddr", _("Reuse Address"));
    o.modalonly = true;
    o.default = "1";
    o.depends("enable_app_forward", "1");
  }
  {
    const o = ss.option(
      form.Flag,
      "enable_app_stats",
      _("Enable App Statistics"),
      _(
        "Collect traffic statistics (bytes_in/bytes_out) for application-layer forwarding using zero-cost atomic counters.",
      ),
    );
    o.modalonly = true;
    o.default = "0";
    o.depends("enable_app_forward", "1");
  }
  {
    const o = ss.option(
      form.Flag,
      "add_firewall_forward",
      _("Add Firewall Forward"),
    );
    o.modalonly = true;
    o.default = "1";
    o.depends({ enable_app_forward: "0" });
    o.depends({ enable_app_forward: "1" });
  }
  {
    const o = ss.option(
      form.Flag,
      "enable_firewall_stats",
      _("Enable Firewall Statistics"),
      _(
        "Collect traffic statistics using nftables kernel counters (extremely low overhead). Requires nftables backend.",
      ),
    );
    o.modalonly = true;
    o.default = "0";
    o.depends("add_firewall_forward", "1");
  }
  {
    const o = ss.option(
      form.Flag,
      "preserve_source_ip",
      _("Preserve Source IP"),
      _(
        "Add NAT rules, preserving the source IP address. \nNote: Only effective when 'Add Firewall Forward' is enabled.",
      ),
    );
    o.modalonly = true;
    o.default = "0";
    o.depends("add_firewall_forward", "1");
  }

  // ── Wake-on-LAN ──────────────────────────────────────────────

  if (isFeatureEnabled("wol_mode")) {
    {
      const o = ss.option(
        form.Flag,
        "enable_wol",
        /* i18n */ _("Enable Wake-on-LAN"),
        /* i18n */ _(
          "Send a magic packet to wake remote machines when the first packet is detected.",
        ),
      );
      o.modalonly = true;
      o.default = "0";
      o.rmempty = true;
    }
    {
      const o = ss.option(
        form.DynamicList,
        "detect_protocols",
        /* i18n */ _("Detect Protocols"),
        /* i18n */ _(
          "Protocol signatures that trigger WoL. Select from the list or type custom values.",
        ),
      );
      o.modalonly = true;
      o.rmempty = true;
      o.depends("enable_wol", "1");
      o.value("ssh", "SSH");
      o.value("rdp", "RDP");
      o.value("http", "HTTP");
      o.value("tls", "TLS/SSL");
      o.value("vnc", "VNC/RFB");
      o.value("socks5", "SOCKS5");
      o.value("postgresql", "PostgreSQL");
      o.value("telnet", "Telnet");
      o.value("minecraft", "Minecraft (Java Edition)");
      o.value("mqtt", "MQTT");
      o.value("smb", "SMB/CIFS");
    }
    {
      const o = ss.option(
        form.ListValue,
        "wol_target",
        /* i18n */ _("WoL Target"),
        /* i18n */ _(
          "Select the global Wake-on-LAN target configuration for this project.",
        ),
      );
      o.modalonly = true;
      o.rmempty = true;
      o.depends("enable_wol", "1");
      o.value("", _("-- Select Target --"));

      const wol_sections = L.uci.sections("portweaver", "wol_target") || [];
      for (const target of wol_sections) {
        const name = target.name || target[".name"];
        if (name) {
          o.value(String(name), String(name));
        }
      }
    }
    {
      const o = ss.option(form.Button, "_wol_wake", /* i18n */ _("Wake Now"));
      o.modalonly = true;
      o.editable = true;
      o.inputtitle = /* i18n */ _("Wake Now");
      o.depends("enable_wol", "1");
      o.onclick = (_ev: any, section_id: string) => {
        rpcClient
          .wolWake(section_id)
          .then((res: { success: boolean; sent_count: number }) => {
            if (res.success) {
              alert(
                /* i18n */ _(
                  `WoL packets sent to ${res.sent_count} device(s).`,
                ),
              );
            } else {
              alert(/* i18n */ _("WoL failed — check configuration."));
            }
          })
          .catch((err: unknown) => {
            alert(/* i18n */ _(`WoL error: ${String(err)}`));
          });
      };
    }
  }

  // ── Protocol Filter ───────────────────────────────────────────
  {
    const o = ss.option(
      form.Flag,
      "enable_protocol_filter",
      /* i18n */ _("Enable Protocol Filter"),
      /* i18n */ _(
        "Reject connections whose detected application-layer protocol is not in the allowed list.",
      ),
    );
    o.modalonly = true;
    o.default = "0";
    o.rmempty = true;
  }
  {
    const o = ss.option(
      form.DynamicList,
      "allowed_protocols",
      /* i18n */ _("Allowed Protocols"),
      /* i18n */ _(
        "Only connections matching these protocol signatures will be forwarded.",
      ),
    );
    o.modalonly = true;
    o.rmempty = true;
    o.depends("enable_protocol_filter", "1");
    o.value("ssh", "SSH");
    o.value("rdp", "RDP");
    o.value("http", "HTTP");
    o.value("tls", "TLS/SSL");
    o.value("vnc", "VNC/RFB");
    o.value("socks5", "SOCKS5");
    o.value("postgresql", "PostgreSQL");
    o.value("telnet", "Telnet");
    o.value("minecraft", "Minecraft (Java Edition)");
    o.value("mqtt", "MQTT");
    o.value("smb", "SMB/CIFS");
  }
  // ── TLS SNI Filter ────────────────────────────────────────────
  {
    const o = ss.option(
      form.DynamicList,
      "tls_allowed_snis",
      /* i18n */ _("Allowed TLS SNIs"),
      /* i18n */ _(
        "Only TLS connections matching these server names will be forwarded. Supports wildcards (e.g. *.example.com). Only effective when TLS is in the allowed protocols list.",
      ),
    );
    o.modalonly = true;
    o.rmempty = true;
    o.depends("enable_protocol_filter", "1");
    o.placeholder = "*.example.com";
  }
}

import type { VersionResponse } from "@/types/portweaver";

const form = L.form;

export default function (
  _m: LuCI.form.Map,
  s: LuCI.form.NamedSection,
  tab_id: string,
  versionInfo: VersionResponse | null,
) {
  const o = s.taboption(tab_id, form.DummyValue, "_about");
  o.rawhtml = true;
  o.cfgvalue = () => {
    const linkStyle =
      "color:#1a73e8; text-decoration:none; word-break:break-all;";
    const sectionStyle =
      "margin-bottom:16px; padding-bottom:12px; border-bottom:1px solid var(--cbi-border-color);";
    const lastSectionStyle = "margin-bottom:8px;";
    const labelStyle = "font-weight:600; margin-bottom:4px; display:block;";
    const smallStyle = "font-size:0.85em; color:#666;";

    const featureBadgeStyle = (enabled: boolean) => {
      const bg = enabled
        ? "var(--cbi-button-apply-background, #e6f4ea)"
        : "var(--cbi-button-reset-background, #f1f3f4)";
      const color = enabled
        ? "var(--cbi-button-apply-color, #137333)"
        : "var(--cbi-button-reset-color, #5f6368)";
      const border = enabled ? "#c2e7c9" : "#dadce0";
      return `display:inline-flex; align-items:center; gap:6px; padding:4px 8px; border-radius:4px; font-size:0.85em; background-color:${bg}; color:${color}; border:1px solid ${border}; margin:2px;`;
    };

    return (
      <div style="max-width:600px; line-height:1.6;">
        <div style={sectionStyle}>
          <span style={labelStyle}>{_("PortWeaver")}</span>
          <p style="margin:4px 0;">
            {_(
              "A flexible port forwarding and NAT traversal tool for OpenWrt.",
            )}
          </p>
          <div style="display:flex; flex-wrap:wrap; gap:16px; margin-top:8px;">
            <a
              href="https://github.com/LazuliKao/PortWeaver"
              target="_blank"
              rel="noopener noreferrer"
              style={linkStyle}
            >
              {_("Core (Zig)")}
            </a>
            <a
              href="https://github.com/LazuliKao/openwrt-portweaver"
              target="_blank"
              rel="noopener noreferrer"
              style={linkStyle}
            >
              {_("OpenWrt Package")}
            </a>
          </div>
          <p style={`${smallStyle} margin-top:8px;`}>{_("License: GPL-3.0")}</p>
        </div>

        {versionInfo ? (
          <>
            <div style={sectionStyle}>
              <span style={labelStyle}>{_("Version Information")}</span>
              <table style="width:100%; border-collapse:collapse; margin-top:8px; font-size:0.9em; line-height:1.8;">
                <tbody>
                  <tr style="border-bottom:1px solid var(--cbi-border-color, #f0f0f0);">
                    <td style="padding:6px 0; font-weight:500;">
                      {_("PortWeaver Version")}
                    </td>
                    <td style="padding:6px 0; text-align:right; font-family:monospace;">
                      {versionInfo.version}
                    </td>
                  </tr>
                  <tr style="border-bottom:1px solid var(--cbi-border-color, #f0f0f0);">
                    <td style="padding:6px 0; font-weight:500;">
                      {_("Forwarding Engine")}
                    </td>
                    <td style="padding:6px 0; text-align:right; font-family:monospace;">
                      {`${versionInfo.forward_backend} (${versionInfo.backend_version})`}
                    </td>
                  </tr>
                  {versionInfo.frp_version && (
                    <tr style="border-bottom:1px solid var(--cbi-border-color, #f0f0f0);">
                      <td style="padding:6px 0; font-weight:500;">
                        {_("FRP Core Version")}
                      </td>
                      <td style="padding:6px 0; text-align:right; font-family:monospace;">
                        {versionInfo.frp_version}
                      </td>
                    </tr>
                  )}
                  {versionInfo.ddns_version && (
                    <tr style="border-bottom:1px solid var(--cbi-border-color, #f0f0f0);">
                      <td style="padding:6px 0; font-weight:500;">
                        {_("DDNS Core Version")}
                      </td>
                      <td style="padding:6px 0; text-align:right; font-family:monospace;">
                        {versionInfo.ddns_version}
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>

            <div style={sectionStyle}>
              <span style={labelStyle}>{_("Compilation Features")}</span>
              <div style="display:flex; flex-wrap:wrap; gap:4px; margin-top:8px;">
                <div style={featureBadgeStyle(versionInfo.uci_mode)}>
                  <span>{versionInfo.uci_mode ? "✔" : "✘"}</span>
                  <span>{_("UCI Integration")}</span>
                </div>
                <div style={featureBadgeStyle(versionInfo.ubus_mode)}>
                  <span>{versionInfo.ubus_mode ? "✔" : "✘"}</span>
                  <span>{_("UBUS Integration")}</span>
                </div>
                <div style={featureBadgeStyle(versionInfo.frpc_mode)}>
                  <span>{versionInfo.frpc_mode ? "✔" : "✘"}</span>
                  <span>{_("FRP Client")}</span>
                </div>
                <div style={featureBadgeStyle(versionInfo.frps_mode)}>
                  <span>{versionInfo.frps_mode ? "✔" : "✘"}</span>
                  <span>{_("FRP Server")}</span>
                </div>
                <div style={featureBadgeStyle(versionInfo.ddns_mode)}>
                  <span>{versionInfo.ddns_mode ? "✔" : "✘"}</span>
                  <span>{_("Dynamic DNS")}</span>
                </div>
                <div style={featureBadgeStyle(versionInfo.nftables_mode)}>
                  <span>{versionInfo.nftables_mode ? "✔" : "✘"}</span>
                  <span>{_("nftables Support")}</span>
                </div>
                <div style={featureBadgeStyle(versionInfo.wol_mode)}>
                  <span>{versionInfo.wol_mode ? "✔" : "✘"}</span>
                  <span>{_("Wake-on-LAN")}</span>
                </div>
              </div>
            </div>
          </>
        ) : (
          <div style={sectionStyle}>
            <span style={labelStyle}>{_("Version Information")}</span>
            <p
              style={`${smallStyle} color:var(--cbi-warning-color, #c00); margin:8px 0 0 0;`}
            >
              {_(
                "Unable to contact PortWeaver daemon. Version details are unavailable.",
              )}
            </p>
          </div>
        )}

        <div style={sectionStyle}>
          <span style={labelStyle}>{_("Open Source Dependencies")}</span>
          <div style="display:flex; flex-direction:column; gap:8px; margin-top:4px;">
            <div>
              <a
                href="https://github.com/fatedier/frp"
                target="_blank"
                rel="noopener noreferrer"
                style={linkStyle}
              >
                frp
              </a>
              <span style={smallStyle}>
                {" "}
                — {_("Fast Reverse Proxy for NAT traversal")}
              </span>
              <br />
              <span style={smallStyle}>{_("License: Apache-2.0")}</span>
            </div>
            <div>
              <a
                href="https://github.com/jeessy2/ddns-go"
                target="_blank"
                rel="noopener noreferrer"
                style={linkStyle}
              >
                go-ddns
              </a>
              <span style={smallStyle}> — {_("Dynamic DNS client")}</span>
              <br />
              <span style={smallStyle}>{_("License: MIT")}</span>
            </div>
          </div>
        </div>

        <div style={lastSectionStyle}>
          <span style={labelStyle}>{_("Author")}</span>
          <a
            href="https://github.com/LazuliKao"
            target="_blank"
            rel="noopener noreferrer"
            style={linkStyle}
          >
            LazuliKao
          </a>
        </div>
      </div>
    );
  };
}

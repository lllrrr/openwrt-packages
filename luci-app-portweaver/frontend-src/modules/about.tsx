const form = L.form;

export default function (
  _m: LuCI.form.CBIMap,
  s: LuCI.form.CBIAbstractSection,
  tab_id: string,
) {
  let o: LuCI.form.CBIAbstractValue;

  o = s.taboption(tab_id, form.DummyValue, "_about");
  o.rawhtml = true;
  o.cfgvalue = () => {
    const linkStyle =
      "color:#1a73e8; text-decoration:none; word-break:break-all;";
    const sectionStyle =
      "margin-bottom:16px; padding-bottom:12px; border-bottom:1px solid var(--cbi-border-color);";
    const lastSectionStyle = "margin-bottom:8px;";
    const labelStyle = "font-weight:600; margin-bottom:4px; display:block;";
    const smallStyle = "font-size:0.85em; color:#666;";

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
                href="https://github.com/sdlzm/go-ddns"
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

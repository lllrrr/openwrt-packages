import { LogViewerDialog } from "@/components/LogViewerDialog";
import type { DdnsStatus } from "@/types/portweaver/ddns";
import { rpcClient } from "@/utils/rpc-client";

const form = L.form;
const uci = L.uci;

export const DNS_PROVIDERS_CONFIG: Record<
  string,
  {
    idLabel: string;
    secretLabel: string;
    extParamLabel: string;
  }
> = {
  // Providers requiring DnsID (16 total)
  alidns: {
    idLabel: "AccessKey ID",
    secretLabel: "AccessKey Secret",
    extParamLabel: "",
  },
  aliesa: {
    idLabel: "AccessKey ID",
    secretLabel: "AccessKey Secret",
    extParamLabel: "",
  },
  tencentcloud: {
    idLabel: "SecretId",
    secretLabel: "SecretKey",
    extParamLabel: "",
  },
  dnspod: { idLabel: "ID", secretLabel: "Token", extParamLabel: "" },
  huaweicloud: {
    idLabel: "Access Key Id",
    secretLabel: "Secret Access Key",
    extParamLabel: "",
  },
  callback: { idLabel: "URL", secretLabel: "RequestBody", extParamLabel: "" },
  baiducloud: {
    idLabel: "AccessKey ID",
    secretLabel: "AccessKey Secret",
    extParamLabel: "",
  },
  porkbun: { idLabel: "API Key", secretLabel: "Secret Key", extParamLabel: "" },
  godaddy: { idLabel: "Key", secretLabel: "Secret", extParamLabel: "" },
  trafficroute: {
    idLabel: "AccessKey",
    secretLabel: "SecretAccessKey",
    extParamLabel: "",
  },
  spaceship: {
    idLabel: "API Key",
    secretLabel: "API Secret",
    extParamLabel: "",
  },
  dnsla: { idLabel: "APIID", secretLabel: "API密钥", extParamLabel: "" },
  nowcn: { idLabel: "auth-userid", secretLabel: "api-key", extParamLabel: "" },
  eranet: { idLabel: "auth-userid", secretLabel: "api-key", extParamLabel: "" },
  edgeone: { idLabel: "SecretId", secretLabel: "SecretKey", extParamLabel: "" },
  name_com: { idLabel: "username", secretLabel: "token", extParamLabel: "" },

  // Providers NOT requiring DnsID (8 total)
  cloudflare: { idLabel: "", secretLabel: "Token", extParamLabel: "" },
  namecheap: { idLabel: "", secretLabel: "Password", extParamLabel: "" },
  namesilo: { idLabel: "", secretLabel: "Password", extParamLabel: "" },
  vercel: { idLabel: "", secretLabel: "Token", extParamLabel: "Team ID" },
  dynadot: { idLabel: "", secretLabel: "Password", extParamLabel: "" },
  dynv6: { idLabel: "", secretLabel: "Token", extParamLabel: "" },
  gcore: { idLabel: "", secretLabel: "API Key", extParamLabel: "" },
  nsone: { idLabel: "", secretLabel: "API Key", extParamLabel: "" },
};

const DNS_PROVIDERS = [
  { value: "alidns", label: "Alibaba Cloud DNS" },
  { value: "aliesa", label: "Alibaba Cloud ESA" },
  { value: "tencentcloud", label: "Tencent Cloud DNS" },
  { value: "dnspod", label: "DNSPod" },
  { value: "huaweicloud", label: "Huawei Cloud DNS" },
  { value: "callback", label: "Callback (Webhook)" },
  { value: "baiducloud", label: "Baidu Cloud DNS" },
  { value: "porkbun", label: "Porkbun" },
  { value: "godaddy", label: "GoDaddy" },
  { value: "namecheap", label: "Namecheap" },
  { value: "namesilo", label: "NameSilo" },
  { value: "vercel", label: "Vercel" },
  { value: "dynadot", label: "Dynadot" },
  { value: "dynv6", label: "Dynv6" },
  { value: "trafficroute", label: "TrafficRoute (Volcengine)" },
  { value: "spaceship", label: "Spaceship" },
  { value: "dnsla", label: "DNSLA" },
  { value: "nowcn", label: "Nowcn (Era Networks)" },
  { value: "eranet", label: "Eranet" },
  { value: "gcore", label: "Gcore" },
  { value: "edgeone", label: "EdgeOne" },
  { value: "nsone", label: "IBM NS1 Connect" },
  { value: "name_com", label: "name.com" },
  { value: "cloudflare", label: "Cloudflare" },
];

const GET_TYPES = [
  { value: "url", label: _("URL") },
  { value: "net_interface", label: _("Network Interface") },
  { value: "cmd", label: _("Command") },
];

const TTL_OPTIONS = [
  { value: "60", label: _("%d minute").format(1) },
  { value: "300", label: _("%d minutes").format(5) },
  { value: "600", label: _("%d minutes").format(10) },
  { value: "1800", label: _("%d minutes").format(30) },
  { value: "3600", label: _("%d hour").format(1) },
  { value: "7200", label: _("%d hours").format(2) },
  { value: "14400", label: _("%d hours").format(4) },
  { value: "28800", label: _("%d hours").format(8) },
  { value: "86400", label: _("%d day").format(1) },
];

const ddnsStatuses: Record<string, DdnsStatus> = {};
const statusElements: Record<string, HTMLElement> = {};

export default function (
  _m: LuCI.form.Map,
  s: LuCI.form.NamedSection,
  tab_id: string,
) {
  const sectionValue = s.taboption(
    tab_id,
    form.SectionValue,
    "_ddns_configs",
    form.GridSection,
    "ddns",
  );

  const ss = sectionValue.subsection as LuCI.form.GridSection;
  ss.anonymous = true;
  ss.addremove = true;
  ss.sortable = true;

  ss.sectiontitle = (section_id: string) =>
    (uci.get("portweaver", section_id, "name") as string) || _("Unnamed DDNS");

  {
    const o = ss.option(form.DummyValue, "_status", _("Status"));
    o.modalonly = false;
    o.textvalue = (section_id: string) => {
      const name = uci.get("portweaver", section_id, "name") as string;

      const status = ddnsStatuses[name] || {
        status: "unknown",
        name: "",
        provider: "",
        section: section_id,
      };

      const statusColors: Record<string, string> = {
        success: "#4CAF50",
        updating: "#FFC107",
        error: "#F44336",
        disabled: "#9E9E9E",
        unknown: "#9E9E9E",
      };

      const statusLabels: Record<string, string> = {
        success: _("Success"),
        updating: _("Updating"),
        error: _("Error"),
        disabled: _("Disabled"),
        unknown: _("Unknown"),
      };

      const statusColor = statusColors[status.status] || statusColors.unknown;
      const statusText = statusLabels[status.status] || status.status;

      const indicator = (
        <span
          style={`display:inline-block; width:12px; height:12px; border-radius:50%; background-color:${statusColor}; margin-right:8px;`}
        ></span>
      ) as HTMLElement;

      const textSpan = (<span>{statusText}</span>) as HTMLElement;

      const container = (
        <div
          id={`ddns-status-${name}`}
          style="display:flex; flex-direction:column; gap:4px;"
        ></div>
      ) as HTMLElement;

      const statusRow = (
        <div style="display:flex; align-items:center;"></div>
      ) as HTMLElement;
      statusRow.appendChild(indicator);
      statusRow.appendChild(textSpan);
      container.appendChild(statusRow);

      if (status.last_ip) {
        const ipInfo = (
          <small style="color:#666;">
            {_("IP: %s").format(status.last_ip)}
          </small>
        ) as HTMLElement;
        container.appendChild(ipInfo);
      }

      if (status.last_update > 0) {
        const date = new Date(status.last_update * 1000);
        const formattedTime = date.toLocaleString();
        const updateInfo = (
          <small style="color:#666;">
            {_("Updated: %s").format(formattedTime)}
          </small>
        ) as HTMLElement;
        container.appendChild(updateInfo);
      }

      if (status.message && status.status === "error") {
        const errorMsg = (
          <small style="color:#F44336;" title={status.message}>
            {status.message.length > 40
              ? `${status.message.substring(0, 37)}...`
              : status.message}
          </small>
        ) as HTMLElement;
        container.appendChild(errorMsg);
      }

      statusElements[name] = container;
      return container;
    };
  }

  {
    const o = ss.option(form.Flag, "enabled", _("Enabled"));
    o.modalonly = false;
    o.default = "1";
    o.editable = true;
  }

  {
    const o = ss.option(form.DummyValue, "_provider", _("Provider"));
    o.modalonly = false;
    o.textvalue = (section_id: string) => {
      const provider =
        (uci.get("portweaver", section_id, "dns_provider") as string) || "";
      const providerObj = DNS_PROVIDERS.find((p) => p.value === provider);
      return providerObj ? providerObj.label : provider || "-";
    };
  }

  {
    const o = ss.option(form.DummyValue, "_domains", _("Domains"));
    o.modalonly = false;
    o.textvalue = (section_id: string) => {
      const ipv4Domains =
        (uci.get("portweaver", section_id, "ipv4_domains") as string) || "";
      const ipv6Domains =
        (uci.get("portweaver", section_id, "ipv6_domains") as string) || "";
      const domains = [ipv4Domains, ipv6Domains]
        .filter(Boolean)
        .join(", ")
        .split(/[,\s]+/)
        .filter(Boolean);
      return domains.length > 0 ? domains.slice(0, 3).join(", ") : "-";
    };
  }

  {
    const o = ss.option(form.DummyValue, "_actions", _("Actions"));
    o.modalonly = false;
    o.textvalue = (section_id: string) => {
      const viewLogsBtn = (
        <button class="btn cbi-button cbi-button-action" type="button">
          {_("View Logs")}
        </button>
      ) as HTMLButtonElement;

      const nodeName = L.uci.get("portweaver", section_id, "name") as string;
      viewLogsBtn.onclick = () => {
        const viewer = new LogViewerDialog({
          name: nodeName,
          title: _("DDNS Logs - %s").format(nodeName),
          fetcher: (name) => rpcClient.getDdnsInfo(name),
          clearer: (name) => rpcClient.clearDdnsLogs(name),
        });
        viewer.open();
      };

      return viewLogsBtn;
    };
  }

  {
    const o = ss.option(form.Flag, "enabled", _("Enable"));
    o.modalonly = true;
    o.default = "1";
    o.rmempty = false;
  }

  {
    const o = ss.option(form.Value, "name", _("Configuration Name"));
    o.modalonly = true;
    o.rmempty = false;
    o.datatype = "string";
    o.placeholder = "home";
    o.validate = (_section_id: string, value: unknown) => {
      if (!value || String(value).trim() === "")
        return _("Configuration name is required");
      return true;
    };
  }

  {
    const o = ss.option(form.ListValue, "dns_provider", _("DNS Provider"));
    o.modalonly = true;
    o.rmempty = false;
    for (const provider of DNS_PROVIDERS) {
      o.value(provider.value, provider.label);
    }
    o.default = "cloudflare";
  }

  const dnsIdOption = ss.option(form.Value, "dns_id", _("DNS ID / API Key"));
  dnsIdOption.modalonly = true;
  dnsIdOption.rmempty = true;
  dnsIdOption.placeholder = "API Key or Account ID";
  dnsIdOption.description = _(
    "Field name varies by provider: AccessKey ID (Aliyun), ID (DNSPod), API Key (Porkbun), etc.",
  );
  // Providers requiring DnsID (16 total)
  dnsIdOption.depends("dns_provider", "alidns");
  dnsIdOption.depends("dns_provider", "aliesa");
  dnsIdOption.depends("dns_provider", "tencentcloud");
  dnsIdOption.depends("dns_provider", "dnspod");
  dnsIdOption.depends("dns_provider", "huaweicloud");
  dnsIdOption.depends("dns_provider", "callback");
  dnsIdOption.depends("dns_provider", "baiducloud");
  dnsIdOption.depends("dns_provider", "porkbun");
  dnsIdOption.depends("dns_provider", "godaddy");
  dnsIdOption.depends("dns_provider", "trafficroute");
  dnsIdOption.depends("dns_provider", "spaceship");
  dnsIdOption.depends("dns_provider", "dnsla");
  dnsIdOption.depends("dns_provider", "nowcn");
  dnsIdOption.depends("dns_provider", "eranet");
  dnsIdOption.depends("dns_provider", "edgeone");
  dnsIdOption.depends("dns_provider", "name_com");

  const dnsSecretOption = ss.option(
    form.Value,
    "dns_secret",
    _("DNS Secret / Token"),
  );
  dnsSecretOption.modalonly = true;
  dnsSecretOption.password = true;
  dnsSecretOption.rmempty = true;
  dnsSecretOption.placeholder = "API Token or Secret Key";
  dnsSecretOption.description = _(
    "Field name varies by provider: Token (Cloudflare/DNSPod), AccessKey Secret (Aliyun), Password (Namecheap), etc.",
  );

  const dnsExtParamOption = ss.option(
    form.Value,
    "dns_ext_param",
    _("Extended Parameters"),
  );
  dnsExtParamOption.modalonly = true;
  dnsExtParamOption.rmempty = true;
  dnsExtParamOption.placeholder = "Team ID or additional parameters";
  dnsExtParamOption.description = _(
    "Additional provider-specific parameters (e.g., Team ID for Vercel)",
  );
  dnsExtParamOption.depends("dns_provider", "vercel");

  {
    const o = ss.option(form.ListValue, "ttl", _("TTL (Time To Live)"));
    o.modalonly = true;
    o.rmempty = true;
    o.default = "3600";
    for (const ttl of TTL_OPTIONS) {
      o.value(ttl.value, ttl.label);
    }
  }

  {
    const o = ss.option(form.Flag, "ipv4_enable", _("Enable IPv4"));
    o.modalonly = true;
    o.default = "1";
  }

  {
    const o = ss.option(form.ListValue, "ipv4_get_type", _("IPv4 Get Method"));
    o.modalonly = true;
    o.depends("ipv4_enable", "1");
    o.default = "url";
    for (const type of GET_TYPES) {
      o.value(type.value, type.label);
    }
  }

  {
    const o = ss.option(form.Value, "ipv4_url", _("IPv4 URL"));
    o.modalonly = true;
    o.depends({ ipv4_enable: "1", ipv4_get_type: "url" });
    o.placeholder = "https://api.ipify.org";
    o.datatype = "string";
  }

  {
    const o = ss.option(
      form.Value,
      "ipv4_net_interface",
      _("IPv4 Network Interface"),
    );
    o.modalonly = true;
    o.depends({ ipv4_enable: "1", ipv4_get_type: "net_interface" });
    o.placeholder = "eth0";
    o.datatype = "string";
  }

  {
    const o = ss.option(form.Value, "ipv4_cmd", _("IPv4 Command"));
    o.modalonly = true;
    o.depends({ ipv4_enable: "1", ipv4_get_type: "cmd" });
    o.placeholder = "curl -s https://api.ipify.org";
    o.datatype = "string";
  }

  {
    const o = ss.option(form.TextValue, "ipv4_domains", _("IPv4 Domains"));
    o.modalonly = true;
    o.depends("ipv4_enable", "1");
    o.rows = 3;
    o.placeholder = "example.com\nwww.example.com";
    o.description = _("One domain per line or comma-separated");
  }

  {
    const o = ss.option(form.Flag, "ipv6_enable", _("Enable IPv6"));
    o.modalonly = true;
    o.default = "0";
  }

  {
    const o = ss.option(form.ListValue, "ipv6_get_type", _("IPv6 Get Method"));
    o.modalonly = true;
    o.depends("ipv6_enable", "1");
    o.default = "url";
    for (const type of GET_TYPES) {
      o.value(type.value, type.label);
    }
  }

  {
    const o = ss.option(form.Value, "ipv6_url", _("IPv6 URL"));
    o.modalonly = true;
    o.depends({ ipv6_enable: "1", ipv6_get_type: "url" });
    o.placeholder = "https://api6.ipify.org";
    o.datatype = "string";
  }

  {
    const o = ss.option(
      form.Value,
      "ipv6_net_interface",
      _("IPv6 Network Interface"),
    );
    o.modalonly = true;
    o.depends({ ipv6_enable: "1", ipv6_get_type: "net_interface" });
    o.placeholder = "eth0";
    o.datatype = "string";
  }

  {
    const o = ss.option(form.Value, "ipv6_cmd", _("IPv6 Command"));
    o.modalonly = true;
    o.depends({ ipv6_enable: "1", ipv6_get_type: "cmd" });
    o.placeholder = "curl -s https://api6.ipify.org";
    o.datatype = "string";
  }

  {
    const o = ss.option(form.Value, "ipv6_reg", _("IPv6 Regex"));
    o.modalonly = true;
    o.depends("ipv6_enable", "1");
    o.rmempty = true;
    o.placeholder = "([0-9a-fA-F:]+)";
    o.description = _("Regular expression to extract IPv6 address from output");
  }

  {
    const o = ss.option(form.TextValue, "ipv6_domains", _("IPv6 Domains"));
    o.modalonly = true;
    o.depends("ipv6_enable", "1");
    o.rows = 3;
    o.placeholder = "example.com\nwww.example.com";
    o.description = _("One domain per line or comma-separated");
  }

  {
    const o = ss.option(form.Value, "webhook_url", _("Webhook URL"));
    o.modalonly = true;
    o.rmempty = true;
    o.placeholder = "https://example.com/webhook";
    o.description = _("Optional webhook to call after successful update");
  }

  {
    const o = ss.option(form.TextValue, "webhook_body", _("Webhook Body"));
    o.modalonly = true;
    o.rmempty = true;
    o.rows = 3;
    o.placeholder = '{"ip": "{{ip}}", "domain": "{{domain}}"}';
    o.description = _("JSON body for webhook (supports {{ip}} and {{domain}})");
    o.depends({ webhook_url: /^.+$/ });
  }

  {
    const o = ss.option(
      form.TextValue,
      "webhook_headers",
      _("Webhook Headers"),
    );
    o.modalonly = true;
    o.rmempty = true;
    o.rows = 3;
    o.placeholder =
      "Authorization: Bearer token\nContent-Type: application/json";
    o.description = _("One header per line (Header: Value)");
    o.depends({ webhook_url: /^.+$/ });
  }

  async function pollDdnsStatus() {
    try {
      const result = await rpcClient.getDdnsStatus();

      const statuses = result?.ddns_status || [];

      for (const status of statuses) {
        const oldStatus = ddnsStatuses[status.name];
        ddnsStatuses[status.name] = status;

        if (
          !oldStatus ||
          oldStatus.status !== status.status ||
          oldStatus.last_ip !== status.last_ip ||
          oldStatus.last_update !== status.last_update
        ) {
          const container =
            document.getElementById(`ddns-status-${status.name}`) ||
            statusElements[status.name];
          if (container) {
            const statusColors: Record<string, string> = {
              success: "#4CAF50",
              updating: "#FFC107",
              error: "#F44336",
              disabled: "#9E9E9E",
              unknown: "#9E9E9E",
            };

            const statusLabels: Record<string, string> = {
              success: _("Success"),
              updating: _("Updating"),
              error: _("Error"),
              disabled: _("Disabled"),
              unknown: _("Unknown"),
            };

            const statusColor =
              statusColors[status.status] || statusColors.unknown;
            const statusText = statusLabels[status.status] || status.status;

            // Clear container by removing all children
            while (container.firstChild) {
              container.removeChild(container.firstChild);
            }

            const statusRow = (
              <div style="display:flex; align-items:center;"></div>
            ) as HTMLElement;

            const indicator = (
              <span
                style={`display:inline-block; width:12px; height:12px; border-radius:50%; background-color:${statusColor}; margin-right:8px;`}
              ></span>
            ) as HTMLElement;

            const textSpan = (<span>{statusText}</span>) as HTMLElement;

            statusRow.appendChild(indicator);
            statusRow.appendChild(textSpan);
            container.appendChild(statusRow);

            if (status.last_ip) {
              const ipInfo = (
                <small style="color:#666;">
                  {_("IP: %s").format(status.last_ip)}
                </small>
              ) as HTMLElement;
              container.appendChild(ipInfo);
            }

            if (status.last_update > 0) {
              const date = new Date(status.last_update * 1000);
              const formattedTime = date.toLocaleString();
              const updateInfo = (
                <small style="color:#666;">
                  {_("Updated: %s").format(formattedTime)}
                </small>
              ) as HTMLElement;
              container.appendChild(updateInfo);
            }

            if (status.message && status.status === "error") {
              const errorMsg = (
                <small style="color:#F44336;" title={status.message}>
                  {status.message.length > 40
                    ? `${status.message.substring(0, 37)}...`
                    : status.message}
                </small>
              ) as HTMLElement;
              container.appendChild(errorMsg);
            }
          }
        }
      }
    } catch (err) {
      console.warn("Failed to fetch DDNS statuses:", err);
    }
  }

  pollDdnsStatus();
  L.Poll.add(pollDdnsStatus, 5);
}

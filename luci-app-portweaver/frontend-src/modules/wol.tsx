import { rpcClient } from "@/utils/rpc-client";
const form = L.form;

export default function (
  _m: LuCI.form.CBIMap,
  s: LuCI.form.CBIAbstractSection,
  tab_id: string,
) {
  let o: LuCI.form.CBIAbstractSectionValue;

  o = s.taboption(
    tab_id,
    form.SectionValue,
    "_wol_targets",
    form.GridSection,
    "wol_target",
  );

  const ss = o.subsection;
  ss.anonymous = true;
  ss.addremove = true;
  ss.sortable = true;
  ss.cloneable = true;

  ss.sectiontitle = (section_id: string) =>
    L.uci.get("portweaver", section_id, "name") ||
    section_id ||
    _("Unnamed target");

  o = ss.option(form.Flag, "enabled", _("Enable"));
  o.modalonly = true;
  o.default = "1";
  o.rmempty = false;

  o = ss.option(form.Value, "name", _("Target Name"));
  o.modalonly = true;
  o.rmempty = false;
  o.datatype = "string";
  o.placeholder = "my_pc";
  o.validate = (section_id: string, value: string) => {
    if (!value || String(value).trim() === "")
      return _("Target name is required");
    if (!/^[a-zA-Z0-9_-]+$/.test(String(value).trim()))
      return _(
        "Target name must contain only alphanumeric characters, underscore, or hyphen",
      );

    const sections = L.uci.sections("portweaver", "wol_target");
    const trimmedValue = String(value).trim();
    for (const sec of sections) {
      if (sec[".name"] === section_id) continue;

      const existingName = sec.name as string;
      if (existingName && existingName.trim() === trimmedValue) {
        return _("Target name already exists. Please choose a different name.");
      }
    }

    return true;
  };

  o = ss.option(form.Flag, "enabled", _("Enabled"));
  o.modalonly = false;
  o.default = "1";
  o.editable = true;

  o = ss.option(
    form.DynamicList,
    "mac_addresses",
    _("MAC Addresses"),
    _("MAC addresses of machines to wake (e.g. AA:BB:CC:DD:EE:FF)."),
  );
  o.modalonly = true;
  o.rmempty = false;
  o.datatype = "macaddr";

  o = ss.option(
    form.Value,
    "cooldown_ms",
    _("WoL Cooldown (ms)"),
    _(
      "Minimum interval between successive WoL packets in milliseconds (1000–300000).",
    ),
  );
  o.modalonly = true;
  o.rmempty = true;
  o.default = "30000";
  o.datatype = "uinteger";
  o.placeholder = "30000";

  o = ss.option(
    form.Flag,
    "log_enabled",
    _("Enable Logging"),
    _("Record diagnostic logs when triggering WoL for this target."),
  );
  o.modalonly = true;
  o.default = "0";
  o.rmempty = true;

  o = ss.option(form.DummyValue, "actions", _("Actions"));
  o.modalonly = false;
  o.textvalue = (section_id: string) => {
    const targetName = L.uci.get("portweaver", section_id, "name") as string;
    if (!targetName) return "";

    const wakeBtn = (
      <button
        type="button"
        class="cbi-button cbi-button-action"
        onclick={() => {
          rpcClient
            .wolWake(undefined, targetName)
            .then((res: { success: boolean; sent_count: number }) => {
              if (res.success) {
                alert(
                  _("WoL packets sent to %s device(s).").format(res.sent_count),
                );
              } else {
                alert(_("WoL failed — check configuration."));
              }
            })
            .catch((err: unknown) => {
              alert(_("WoL error: %s").format(String(err)));
            });
        }}
      >
        {_("Wake Now")}
      </button>
    ) as HTMLButtonElement;

    return wakeBtn;
  };
}

import { rpcClient } from "@/utils/rpc-client";
const form = L.form;

export default function (
  _m: LuCI.form.Map,
  s: LuCI.form.AbstractSection,
  tab_id: string,
) {
  const o = s.taboption(
    tab_id,
    form.SectionValue,
    "_wol_targets",
    form.GridSection,
    "wol_target",
  );

  const ss = o.subsection as LuCI.form.GridSection;
  ss.anonymous = true;
  ss.addremove = true;
  ss.sortable = true;
  ss.cloneable = true;

  ss.sectiontitle = (section_id: string) =>
    (L.uci.get("portweaver", section_id, "name") as string) ||
    section_id ||
    _("Unnamed target");

  const oFlag = ss.option(form.Flag, "enabled", _("Enable"));
  oFlag.modalonly = true;
  oFlag.default = "1";
  oFlag.rmempty = false;

  const oName = ss.option(form.Value, "name", _("Target Name"));
  oName.modalonly = true;
  oName.rmempty = false;
  oName.datatype = "string";
  oName.placeholder = "my_pc";
  oName.validate = (section_id: string, value: unknown) => {
    const val = String(value || "");
    if (!val || val.trim() === "") return _("Target name is required");
    if (!/^[a-zA-Z0-9_-]+$/.test(val.trim()))
      return _(
        "Target name must contain only alphanumeric characters, underscore, or hyphen",
      );

    const sections = L.uci.sections("portweaver", "wol_target");
    const trimmedValue = val.trim();
    for (const sec of sections) {
      if (sec[".name"] === section_id) continue;

      const existingName = sec.name as string;
      if (existingName && existingName.trim() === trimmedValue) {
        return _("Target name already exists. Please choose a different name.");
      }
    }

    return true;
  };

  const oEnabled = ss.option(form.Flag, "enabled", _("Enabled"));
  oEnabled.modalonly = false;
  oEnabled.default = "1";
  oEnabled.editable = true;

  const oMacList = ss.option(
    form.DynamicList,
    "mac_addresses",
    _("MAC Addresses"),
    _("MAC addresses of machines to wake (e.g. AA:BB:CC:DD:EE:FF)."),
  );
  oMacList.modalonly = true;
  oMacList.rmempty = false;
  oMacList.datatype = "macaddr";

  const oCooldown = ss.option(
    form.Value,
    "cooldown_ms",
    _("WoL Cooldown (ms)"),
    _(
      "Minimum interval between successive WoL packets in milliseconds (1000–300000).",
    ),
  );
  oCooldown.modalonly = true;
  oCooldown.rmempty = true;
  oCooldown.default = "30000";
  oCooldown.datatype = "uinteger";
  oCooldown.placeholder = "30000";

  const oLogFlag = ss.option(
    form.Flag,
    "log_enabled",
    _("Enable Logging"),
    _("Record diagnostic logs when triggering WoL for this target."),
  );
  oLogFlag.modalonly = true;
  oLogFlag.default = "0";
  oLogFlag.rmempty = true;

  const oActions = ss.option(form.DummyValue, "actions", _("Actions"));
  oActions.modalonly = false;
  oActions.textvalue = (section_id: string) => {
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
                  _("WoL packets sent to %s device(s).").format(
                    String(res.sent_count),
                  ),
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

import { NftablesRulesViewer } from "@/components/NftablesRulesViewer";

const form = L.form;

export default function (
  _m: LuCI.form.CBIMap,
  s: LuCI.form.CBIAbstractSection,
  tab_id: string,
) {
  const o = s.taboption(
    tab_id,
    form.DummyValue,
    "_nftables_rules",
    _("nftables Rules"),
  );
  o.render = () => {
    const viewer = new NftablesRulesViewer();
    return viewer.render();
  };
}

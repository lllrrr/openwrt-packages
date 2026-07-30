import { defineConfig } from "@lazulikao/luci-types/i18n";

export default defineConfig({
  packageName: "luci-app-portweaver",
  input: ["../htdocs"],
  merge: true,
  headers:{
    lastTranslator: "TranslateGemma"
  },
  translate: {
    enabled: true,
    batchSize: 15,
    prompt: "translate.md",
  },
  locales: [
    { locale: "zh_Hans", po: "../po/zh_Hans/portweaver.po" },
  ],
});

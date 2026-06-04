import type { VersionResponse } from "@/types/portweaver";

let globalVersionInfo: VersionResponse | null = null;

export function setVersionInfo(info: VersionResponse | null) {
  globalVersionInfo = info;
}

export function isFeatureEnabled(feature: keyof VersionResponse): boolean {
  if (!globalVersionInfo) return true;
  const val = globalVersionInfo[feature];
  return typeof val === "boolean" ? val : true;
}

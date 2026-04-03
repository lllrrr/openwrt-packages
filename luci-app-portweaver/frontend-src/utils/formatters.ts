export function formatBytes(bytes: number = 0): string {
  if (bytes < 1024) return `${parseFloat(bytes.toFixed(2))} B`;
  if (bytes < 1048576) return `${parseFloat((bytes / 1024).toFixed(2))} KiB`;
  if (bytes < 1073741824)
    return `${parseFloat((bytes / 1048576).toFixed(2))} MiB`;
  return `${parseFloat((bytes / 1073741824).toFixed(2))} GiB`;
}

export function formatUptime(seconds: number = 0): string {
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const mins = Math.floor((seconds % 3600) / 60);
  const sec = seconds % 60;
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${mins}m`;
  return `${mins}m${sec}s`;
}

export function getErrorMessage(error_code?: number): string | null {
  if (error_code === undefined || error_code === 0) return null;
  const messages: Record<string, string> = {
    "0": _("OK"),
    "-1": _("Memory allocation failed"),
    "-2": _("Failed to bind to port"),
    "-3": _("Address or port already in use (EADDRINUSE)"),
    "-4": _("Permission denied - unable to bind to port (EACCES)"),
    "-5": _("Invalid address format"),
    "-98": _("Address already in use"),
    "-91": _("Protocol wrong type for socket"),
    "-92": _("Protocol not available"),
    "-93": _("Protocol not supported"),
    "-94": _("Socket type not supported"),
    "-95": _("Operation not supported on transport endpoint"),
    "-96": _("Protocol family not supported"),
    "-97": _("Address family not supported by protocol"),
    "-99": _("Cannot assign requested address"),
    "-100": _("Network is down"),
    "-101": _("Network is unreachable"),
  };
  return messages[String(error_code)] || `Unknown error (code: ${error_code})`;
}

export function translateStatus(str: string | undefined) {
  if (!str) return str;
  if (str === "running") return _("Running");
  if (str === "stopped") return _("Stopped");
  if (str === "degraded") return _("Degraded");
  if (str === "failed") return _("Failed");
  if (str === "error") return _("Error");
  if (str === "unknown") return _("Unknown");
  return str;
}

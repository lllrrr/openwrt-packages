import { LogViewerCore } from "../components/LogViewerCore";
import { confirm } from "../modules/dialog";

const form = L.form;
const fs = L.fs;
const ui = L.ui;

const LOG_FILE = "/tmp/portweaver.log";

let logViewerCore: LogViewerCore | null = null;

export default function (
  _m: LuCI.form.CBIMap,
  s: LuCI.form.CBIAbstractSection,
  tab_id: string,
) {
  let o: LuCI.form.CBIAbstractValue;

  o = s.taboption(tab_id, form.Flag, "log_enabled", _("Enable Logging"));
  o.default = "1";
  o.rmempty = false;
  o.description = _("Enable logging output to /tmp/portweaver.log");

  o = s.taboption(tab_id, form.Value, "max_log_size", _("Max Log Size (KB)"));
  o.datatype = "uinteger";
  o.default = "1024";
  o.rmempty = false;
  o.description = _(
    "Maximum size of log file before rotation (default: 1024 KB = 1MB)",
  );
  o.placeholder = "1024";
  o.depends("log_enabled", "1");

  o = s.taboption(
    tab_id,
    form.Value,
    "max_log_files",
    _("Max Log Backup Files"),
  );
  o.datatype = "uinteger";
  o.default = "3";
  o.rmempty = false;
  o.description = _("Number of rotated log files to keep (default: 3)");
  o.placeholder = "3";
  o.depends("log_enabled", "1");

  o = s.taboption(tab_id, form.DummyValue, "_logs_viewer");
  o.rawhtml = true;

  const fetcher = async (): Promise<{
    status: string;
    last_error: string;
    logs: string[];
  }> => {
    try {
      const content = await fs.read_direct(LOG_FILE, "text");
      const lines = content.trim().split("\n").filter(Boolean);
      return {
        status: "running",
        last_error: "",
        logs: lines,
      };
    } catch (err: any) {
      if (err.toString().includes("NotFoundError")) {
        return {
          status: "stopped",
          last_error: _("Log file does not exist."),
          logs: [],
        };
      } else {
        return {
          status: "error",
          last_error: _("Error reading log: %s").format(err.toString()),
          logs: [],
        };
      }
    }
  };

  const clearer = async (): Promise<void> => {
    try {
      await fs.write(LOG_FILE, "");
      ui.addNotification(null, E("p", _("Logs cleared successfully")), "info");
    } catch (err) {
      ui.addNotification(null, E("p", _("Failed to clear logs")), "error");
      throw err;
    }
  };

  const restartService = async () => {
    if (
      !(await confirm(
        _("Are you sure you want to restart PortWeaver service?"),
      ))
    ) {
      return;
    }

    try {
      await fs.exec("/etc/init.d/portweaver", ["restart"]);
      ui.addNotification(
        null,
        E("p", _("Service restarted successfully")),
        "info",
      );
    } catch (_err) {
      ui.addNotification(null, E("p", _("Failed to restart service")), "error");
    }
  };

  o.render = () => {
    if (logViewerCore) {
      logViewerCore.destroy();
    }

    logViewerCore = new LogViewerCore({
      name: "system",
      title: _("System Logs"),
      fetcher: () => fetcher(),
      clearer: () => clearer(),
      showHeader: false,
    });

    const coreElement = logViewerCore.render();

    logViewerCore.init();

    const restartButton = (
      <button
        type="button"
        class="cbi-button cbi-button-apply"
        onclick={() => restartService()}
      >
        {_("Restart Service")}
      </button>
    );

    const footer = coreElement.querySelector(".button-row");
    if (footer) {
      const clearButton = footer.querySelector("button:last-child");
      if (clearButton) {
        clearButton.parentNode?.insertBefore(restartButton, clearButton);
      } else {
        footer.appendChild(restartButton);
      }
    }
    return (
      <div style="height: max(calc(100vh - 800px), 500px); border: 1px solid var(--cbi-border-color); border-radius: 4px; overflow: hidden;">
        {coreElement}
      </div>
    );
  };
}

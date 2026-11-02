"""Command line entry point: ``cfpick <command>`` / ``python3 -m cfpick``."""

import argparse
import json
import os
import signal
import sys
from pathlib import Path

from . import __version__, config, core, cron, ddns, engine, links, lock, paths, result
from .log import Logger


def _print_json(payload):
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def cmd_status(_args):
    cfg = config.load()
    running = lock.is_running()
    state = lock.read_state()
    cores = core.all_core_info(cfg)
    _print_json({
        "running": running,
        "pid": lock.current_run_pid() if running else 0,
        "mode": state.get("mode", ""),
        "phase": "running" if running else state.get("phase", "idle"),
        "started_at": state.get("started_at", 0),
        "finished_at": state.get("finished_at", 0),
        "best_ip": state.get("best_ip", ""),
        "error": state.get("error", ""),
        "cron": cron.current(),
        "core_type": cores["active"],
        "core": cores["cores"][cores["active"]],
        "cores": cores["cores"],
    })


def cmd_cores(_args):
    _print_json(core.all_core_info(config.load()))


def cmd_config(_args):
    _print_json(config.load())


def cmd_nodes(_args):
    cfg = config.load()
    out = []
    for index, item in enumerate(cfg.get("nodes", [])):
        entry = {
            "index": index + 1,
            "name": item.get("name", ""),
            "enabled": bool(item.get("enabled", True)),
            "ip_list": item.get("ip_list", ""),
        }
        try:
            parsed = links.parse_link(item.get("link", ""))
            entry.update({"valid": True, "type": parsed.type,
                          "server": parsed.server, "port": parsed.port})
        except (links.LinkError, ValueError) as exc:
            entry.update({"valid": False, "error": str(exc)})
        out.append(entry)
    _print_json({"nodes": out})


def cmd_update_core(args):
    paths.ensure_dirs()
    cfg = config.load()
    choices = ["active", "all"] + list(core.CORE_TYPES)
    chosen = args.type if args.type in choices else "active"
    if chosen == "active":
        targets = [core.active_type(cfg)]
    elif chosen == "all":
        targets = list(core.CORE_TYPES)
    else:
        targets = [chosen]

    results = {}
    failed = 0
    for target in targets:
        try:
            results[target] = core.update_core(target, tag=args.tag or None, log=print)
        except core.CoreError as exc:
            print("%s 更新失败: %s" % (target, exc))
            results[target] = {"error": str(exc)}
            failed += 1
    _print_json(results)
    return 1 if failed else 0


def cmd_cron(args):
    if args.action == "list":
        _print_json(cron.list_tasks())
        return 0
    cfg = config.load()
    try:
        if args.action == "remove":
            settings = dict(cfg.get("schedule", {}))
            settings["enabled"] = False
            enabled, line = cron.apply(settings)
        else:
            enabled, line = cron.apply(cfg.get("schedule", {}))
    except cron.CronError as exc:
        print("定时任务操作失败: %s" % exc)
        return 1
    _print_json({"enabled": enabled, "line": line})
    return 0


# The shell pipeline keeps its throw-away SOCKS configs here, so its existing
# flag-based cleanup and config verification keep working unchanged.
CORE_RUN_DIR = Path("/tmp/etc/passwall")


def cmd_core(args):
    """Start/stop one standalone core for the OpenWrt shell pipeline."""
    from . import passwall

    if args.action == "stop":
        if not args.flag:
            print("core stop 需要 --flag", file=sys.stderr)
            return 2
        pid_path = CORE_RUN_DIR / (args.flag + ".pid")
        try:
            pid = int(pid_path.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            pid = 0
        if pid > 0:
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except OSError:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
        for suffix in (".pid", ".json", ".yaml", ".log"):
            try:
                (CORE_RUN_DIR / (args.flag + suffix)).unlink()
            except OSError:
                pass
        return 0

    if not args.node or not args.ip or not args.port or not args.flag:
        print("core start 需要 --node/--ip/--port/--flag", file=sys.stderr)
        return 2
    try:
        parsed = links.parse_link(passwall.node_link(args.node))
        proxy = parsed.proxy_for_ip(args.ip)
        core.validate_proxy(proxy, args.core)
    except (links.LinkError, core.CoreError, ValueError) as exc:
        print("独立内核不可用: %s" % exc, file=sys.stderr)
        return 3
    binary = core.core_binary(None, args.core)
    if not binary:
        print("%s 内核未安装" % args.core, file=sys.stderr)
        return 4
    CORE_RUN_DIR.mkdir(parents=True, exist_ok=True)
    log_path = CORE_RUN_DIR / (args.flag + ".log")
    config_name = args.flag + (".json" if args.core == "xray" else ".yaml")
    try:
        process, config_path = core.start_core(
            str(binary), args.core, proxy, args.ip, args.port,
            str(CORE_RUN_DIR), str(log_path), config_name=config_name)
    except (core.CoreError, OSError) as exc:
        print("内核启动失败: %s" % exc, file=sys.stderr)
        return 5
    (CORE_RUN_DIR / (args.flag + ".pid")).write_text(
        str(process.proc.pid), encoding="utf-8")
    _print_json({
        "pid": process.proc.pid,
        "core": args.core,
        "binary": str(binary),
        "config": str(config_path),
        "port": args.port,
    })
    return 0


def cmd_ddns_uci_apply(args):
    """DDNS for the OpenWrt shell pipeline: config/nodes come from UCI."""
    from . import passwall

    settings = passwall.ddns_config()
    nodes = passwall.node_ip_ddns()
    if not settings["enabled"]:
        _print_json({"enabled": False, "message": "DDNS 未启用"})
        return 0
    if not nodes:
        _print_json({"enabled": True, "message": "没有节点配置 DDNS 域名，跳过"})
        return 0
    rows, when = result.read_result(args.result or None)
    if not rows:
        _print_json({"enabled": True, "ok": False, "error": "没有可用的测速结果"})
        return 1
    cfg = {"ddns": settings}
    node_list = [{
        "name": item["name"],
        "node_id": item["node"],
        "ddns_domain": item["domain"],
        "enabled": True,
    } for item in nodes]
    report = ddns.apply(cfg, node_list, rows, log=print, when=when)
    _print_json(report)
    return 0 if report.get("ok") else 1


def cmd_ddns_verify(args):
    """Validate Cloudflare credentials without writing any DNS record.

    With ``--token`` the settings page can check the value being saved before
    it is committed; otherwise the UCI config is used.
    """
    if args.token:
        settings = {
            "enabled": True,
            "cloudflare": {
                "api_token": args.token,
                "zone_id": args.zone_id,
                "zone_name": args.zone_name,
            },
        }
    else:
        from . import passwall

        settings = passwall.ddns_config()

    report = ddns.verify({"ddns": settings})
    _print_json(report)
    return 0 if report.get("ok") else 1


def cmd_ddns(args):
    if args.action == "uci-apply":
        return cmd_ddns_uci_apply(args)
    if args.action == "verify":
        return cmd_ddns_verify(args)
    cfg = config.load()
    nodes = cfg.get("nodes", [])
    rows, when = result.read_result()
    if not rows:
        print("没有可用的测速结果，请先运行测速")
        return 1
    if args.action == "show":
        _print_json(ddns.preview(cfg, nodes, rows, when))
        return 0
    if lock.is_running():
        print("测速正在运行，请等结束后再写入 DNS")
        return 1
    if not (cfg.get("ddns") or {}).get("enabled"):
        print("DDNS 未启用，请先在配置中打开 ddns.enabled")
        return 1
    logger = Logger(paths.DDNS_LOG)
    report = ddns.apply(cfg, nodes, rows, log=logger.log, when=when)
    lock.write_state(ddns=report)
    _print_json(report)
    return 0 if report.get("ok") else 1


def cmd_serve(args):
    from . import web

    web.serve(listen=args.listen, port=args.port)
    return 0


def cmd_run(args):
    mode = args.mode
    if mode == "replace":
        rows, when = result.read_result()
        if not rows:
            print("没有可导出的结果，请先运行测速")
            return 1
        result.export_json(rows, when)
        _print_json({"exported": str(paths.STATE_DIR), "rows": len(rows)})
        return 0
    return engine.run(mode)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="cfpick",
        description="Cloudflare IP speed test for Debian/Ubuntu (mihomo-powered).",
    )
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command")

    run_parser = sub.add_parser("run", help="run one full test")
    run_parser.add_argument("mode", nargs="?", default="start",
                            choices=["start", "test", "retest", "replace"])
    run_parser.set_defaults(func=cmd_run)

    status_parser = sub.add_parser("status", help="show run status")
    status_parser.set_defaults(func=cmd_status)

    config_parser = sub.add_parser("config", help="print the configuration")
    config_parser.set_defaults(func=cmd_config)

    nodes_parser = sub.add_parser("nodes", help="list configured nodes")
    nodes_parser.set_defaults(func=cmd_nodes)

    update_parser = sub.add_parser("update-core", help="download/upgrade a proxy core")
    update_parser.add_argument(
        "--type", default="active",
        choices=["active", "all", "mihomo", "xray"],
        help="core module to update (default: the active one)")
    update_parser.add_argument("--tag", default="", help="release tag, default latest")
    update_parser.set_defaults(func=cmd_update_core)

    cores_parser = sub.add_parser("cores", help="list proxy core modules")
    cores_parser.set_defaults(func=cmd_cores)

    cron_parser = sub.add_parser("cron", help="apply/remove/list crontab entries")
    cron_parser.add_argument("action", nargs="?", default="apply",
                             choices=["apply", "remove", "list"])
    cron_parser.set_defaults(func=cmd_cron)

    ddns_parser = sub.add_parser("ddns", help="preview or write best IPs to Cloudflare DNS")
    ddns_parser.add_argument("action", nargs="?", default="show",
                             choices=["show", "apply", "verify", "uci-apply"])
    ddns_parser.add_argument("--result", default="",
                             help="uci-apply: result.csv written by the shell pipeline")
    ddns_parser.add_argument("--token", default="",
                             help="verify: token to check instead of the UCI value")
    ddns_parser.add_argument("--zone-id", default="",
                             help="verify: zone id to check")
    ddns_parser.add_argument("--zone-name", default="",
                             help="verify: zone name to check")
    ddns_parser.set_defaults(func=cmd_ddns)

    core_parser = sub.add_parser(
        "core", help="start/stop one standalone core for the shell pipeline")
    core_parser.add_argument("action", choices=["start", "stop"])
    core_parser.add_argument("--node", default="", help="PassWall UCI node id")
    core_parser.add_argument("--ip", default="", help="candidate server address")
    core_parser.add_argument("--port", type=int, default=0, help="local SOCKS port")
    core_parser.add_argument("--core", default="xray", choices=["mihomo", "xray"])
    core_parser.add_argument("--flag", default="", help="unique run flag / file prefix")
    core_parser.set_defaults(func=cmd_core)

    serve_parser = sub.add_parser("serve", help="start the web UI")
    serve_parser.add_argument("--listen", default="")
    serve_parser.add_argument("--port", type=int, default=0)
    serve_parser.set_defaults(func=cmd_serve)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 0
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())

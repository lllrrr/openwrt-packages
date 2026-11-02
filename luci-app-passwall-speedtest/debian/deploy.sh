#!/usr/bin/env bash
# cfpick Debian/Ubuntu one-click deployer.
#
#   sudo bash deploy.sh
#   sudo bash deploy.sh --core all
#   sudo bash deploy.sh --listen 0.0.0.0 --token "$(openssl rand -hex 24)"
#   sudo bash deploy.sh --uninstall
#
# The source checkout lives in /opt/cfpick-src and is managed by this
# script; the installed program lives in /opt/cfpick.  Existing
# /etc/cfpick/config.json is never overwritten.
set -Eeuo pipefail

REPO="${CFPICK_REPO:-https://github.com/urbanescavenger/CFPick.git}"
BRANCH="${CFPICK_BRANCH:-main}"
SRC_DIR="${CFPICK_SRC_DIR:-/opt/cfpick-src}"
CORE="mihomo"
CORE_EXPLICIT=0
LISTEN=""
PORT=""
TOKEN=""
UNINSTALL=0
PURGE=0

log()  { printf '[deploy] %s\n' "$*"; }
warn() { printf '[deploy] 警告: %s\n' "$*" >&2; }
die()  { printf '[deploy] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
cfpick Debian/Ubuntu 一键部署

用法: sudo bash deploy.sh [选项]

选项:
  --core mihomo|xray|all|none   安装/升级的内核（默认当前内核；已安装时跳过）
  --branch NAME                 源码分支（默认 main）
  --repo URL                    仓库地址
  --dir PATH                    源码目录（默认 /opt/cfpick-src）
  --listen ADDR                 Web 监听地址（默认沿用配置，初始 127.0.0.1）
  --port PORT                   Web 端口（默认沿用配置，初始 8787）
  --token TOKEN                 Web 访问令牌
  --no-core                     不安装/升级内核
  --uninstall                   卸载（保留配置、结果、日志）
  --purge                       卸载并删除配置、结果、日志
  -h, --help                    显示本帮助

示例:
  sudo bash deploy.sh
  sudo bash deploy.sh --core all
  sudo bash deploy.sh --listen 0.0.0.0 --token "$(openssl rand -hex 24)"
  sudo bash deploy.sh --uninstall --purge
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --core) CORE="${2:-}"; [ -n "$CORE" ] || die "--core 需要参数"; CORE_EXPLICIT=1; shift 2 ;;
        --branch) BRANCH="${2:-}"; [ -n "$BRANCH" ] || die "--branch 需要参数"; shift 2 ;;
        --repo) REPO="${2:-}"; [ -n "$REPO" ] || die "--repo 需要参数"; shift 2 ;;
        --dir) SRC_DIR="${2:-}"; [ -n "$SRC_DIR" ] || die "--dir 需要参数"; shift 2 ;;
        --listen) LISTEN="${2:-}"; shift 2 ;;
        --port) PORT="${2:-}"; shift 2 ;;
        --token) TOKEN="${2:-}"; shift 2 ;;
        --no-core) CORE="none"; CORE_EXPLICIT=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --purge) UNINSTALL=1; PURGE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（--help 查看用法）" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行：sudo bash $0 ..."

[ -r /etc/os-release ] || die "无法读取 /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) ;;
    *) die "仅支持 Debian/Ubuntu 系（当前: ${PRETTY_NAME:-unknown}）" ;;
esac

if [ -n "$PORT" ]; then
    case "$PORT" in *[!0-9]*) die "--port 必须是数字" ;; esac
    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port 范围 1-65535"
fi

HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    HAS_SYSTEMD=1
fi

is_loopback() {
    case "$1" in
        127.0.0.1|localhost|::1|"[::1]") return 0 ;;
        *) return 1 ;;
    esac
}

core_installed() {
    # Ask cfpick so a custom core.paths entry counts as installed too.
    cfpick cores </dev/null 2>/dev/null | python3 -c '
import json
import sys

target = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("cores", {}).get(target, {}).get("installed") else 1)
' "$1"
}

# ── uninstall: use the installed copy when possible ─────────────────────
if [ "$UNINSTALL" = 1 ]; then
    script=""
    if [ -x /opt/cfpick/uninstall.sh ]; then
        script=/opt/cfpick/uninstall.sh
    elif [ -f "$SRC_DIR/debian/uninstall.sh" ]; then
        script="$SRC_DIR/debian/uninstall.sh"
    else
        die "找不到卸载脚本（/opt/cfpick/uninstall.sh 或 $SRC_DIR/debian/uninstall.sh）"
    fi
    log "卸载: $script"
    if [ "$PURGE" = 1 ]; then
        sh "$script" --purge
    else
        sh "$script"
    fi
    exit 0
fi

# ── dependencies ────────────────────────────────────────────────────────
# When this script is piped to bash (``curl ... | sudo bash``), stdin is the
# script itself.  Any child that reads stdin (notably dpkg's conffile prompt)
# would eat the rest of the script and cause a bogus syntax error.  Force
# non-interactive apt and disconnect its stdin.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export GIT_TERMINAL_PROMPT=0
log "安装系统依赖（git / curl / ca-certificates / cron / python3）"
apt-get update </dev/null
apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    git curl ca-certificates cron python3 </dev/null

python3 - <<'PY' || die "需要 Python 3.8+"
import sys
raise SystemExit(0 if sys.version_info >= (3, 8) else 1)
PY

if [ "$HAS_SYSTEMD" = 1 ]; then
    systemctl enable --now cron </dev/null >/dev/null 2>&1 || \
        warn "cron 服务启动失败，定时测速可能不可用"
fi

# ── source checkout ─────────────────────────────────────────────────────
if [ -d "$SRC_DIR/.git" ]; then
    current_remote="$(git -C "$SRC_DIR" remote get-url origin 2>/dev/null || true)"
    [ "$current_remote" = "$REPO" ] || \
        die "$SRC_DIR 的 origin 是 '$current_remote'，不是 '$REPO'；请用 --dir 指定其他目录"
    log "更新源码: $SRC_DIR（origin/$BRANCH）"
    git -C "$SRC_DIR" fetch --depth 1 origin "$BRANCH" </dev/null
    git -C "$SRC_DIR" checkout -B "$BRANCH" FETCH_HEAD </dev/null >/dev/null
elif [ -e "$SRC_DIR" ]; then
    die "$SRC_DIR 已存在但不是 git 仓库；请移走该目录或使用 --dir"
else
    log "克隆源码到 $SRC_DIR"
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$SRC_DIR" </dev/null
fi
[ -f "$SRC_DIR/debian/install.sh" ] || die "源码不完整：找不到 $SRC_DIR/debian/install.sh"

# ── install / upgrade ───────────────────────────────────────────────────
log "安装/更新 cfpick 到 /opt/cfpick（保留已有配置）"
sh "$SRC_DIR/debian/install.sh" </dev/null

# ── optional web overrides ──────────────────────────────────────────────
if [ -n "$LISTEN" ] || [ -n "$PORT" ] || [ -n "$TOKEN" ]; then
    [ -f /etc/cfpick/config.json ] || die "配置文件不存在：/etc/cfpick/config.json"
    log "更新 Web 配置（listen / port / token）"
    CFPICK_LISTEN="$LISTEN" CFPICK_PORT="$PORT" CFPICK_TOKEN="$TOKEN" python3 - <<'PY'
import json
import os
import tempfile

path = "/etc/cfpick/config.json"
with open(path, "r", encoding="utf-8") as handle:
    cfg = json.load(handle)
web = cfg.setdefault("web", {})
if os.environ.get("CFPICK_LISTEN"):
    web["listen"] = os.environ["CFPICK_LISTEN"]
if os.environ.get("CFPICK_PORT"):
    web["port"] = int(os.environ["CFPICK_PORT"])
if os.environ.get("CFPICK_TOKEN"):
    web["token"] = os.environ["CFPICK_TOKEN"]

fd, tmp = tempfile.mkstemp(prefix=".config.", dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(cfg, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print("web.listen=%s web.port=%s token=%s" % (
    web.get("listen"), web.get("port"), "已设置" if web.get("token") else "未设置"))
PY
fi

if [ "$HAS_SYSTEMD" = 1 ]; then
    systemctl restart cfpick-web.service </dev/null
fi

# ── proxy cores ─────────────────────────────────────────────────────────
CORE_FAILED=0
if [ "$CORE" != "none" ]; then
    if [ "$CORE_EXPLICIT" = 0 ]; then
        # Default to whatever the installed config uses (mihomo on a fresh box).
        CORE="$(python3 - <<'PY' 2>/dev/null || echo mihomo
import json
try:
    with open("/etc/cfpick/config.json", "r", encoding="utf-8") as handle:
        print(json.load(handle).get("core", {}).get("type", "mihomo"))
except Exception:
    print("mihomo")
PY
)"
        [ -n "$CORE" ] || CORE=mihomo
    fi
    case "$CORE" in
        mihomo|xray|all) ;;
        *) die "--core 只能是 mihomo / xray / all / none" ;;
    esac
    case "$CORE" in
        all) targets="mihomo xray" ;;
        *) targets="$CORE" ;;
    esac
    command -v cfpick >/dev/null 2>&1 || die "cfpick 未安装成功，无法安装内核"

    for target in $targets; do
        if [ "$CORE_EXPLICIT" = 0 ] && core_installed "$target"; then
            log "$target 内核已安装，跳过下载（用 --core $target 可强制升级）"
            continue
        fi
        ok=0
        for attempt in 1 2 3; do
            log "安装/升级 $target 内核（第 $attempt/3 次）"
            if cfpick update-core --type "$target" </dev/null; then
                ok=1
                break
            fi
            warn "$target 内核下载失败（第 $attempt 次）"
            [ "$attempt" -lt 3 ] && sleep 3
        done
        if [ "$ok" != 1 ]; then
            warn "$target 内核安装失败；可稍后在 Web「内核」页重试"
            CORE_FAILED=1
        fi
    done
fi

# ── health check / summary ──────────────────────────────────────────────
mapfile -t WEB_CONF < <(python3 - <<'PY'
import json
try:
    with open("/etc/cfpick/config.json", "r", encoding="utf-8") as handle:
        web = json.load(handle).get("web", {})
except Exception:
    web = {}
print(web.get("listen", "127.0.0.1"))
print(web.get("port", 8787))
PY
)
CFG_LISTEN="${WEB_CONF[0]:-127.0.0.1}"
CFG_PORT="${WEB_CONF[1]:-8787}"

CHECK_HOST="$CFG_LISTEN"
case "$CHECK_HOST" in
    ""|0.0.0.0|::|"[::]") CHECK_HOST=127.0.0.1 ;;
esac
case "$CHECK_HOST" in
    *:*) case "$CHECK_HOST" in \[*) ;; *) CHECK_HOST="[$CHECK_HOST]" ;; esac ;;
esac

if [ "$HAS_SYSTEMD" = 1 ]; then
    log "等待 Web 服务就绪: http://$CHECK_HOST:$CFG_PORT/api/ping"
    ready=0
    for _ in $(seq 1 20); do
        if curl -fsS --max-time 2 "http://$CHECK_HOST:$CFG_PORT/api/ping" </dev/null >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 1
    done
    if [ "$ready" = 1 ]; then
        log "Web 健康检查通过"
    else
        warn "Web 健康检查失败；最近日志："
        journalctl -u cfpick-web.service -n 50 --no-pager </dev/null || true
        CORE_FAILED=1
    fi
else
    warn "未检测到 systemd，Web 服务未自动启动；可手动运行："
    warn "  cd /opt/cfpick && CFPICK_APP_DIR=/opt/cfpick PYTHONPATH=/opt/cfpick python3 -m cfpick serve"
fi

CFG_TOKEN="$(python3 - <<'PY' 2>/dev/null || true
import json
try:
    with open("/etc/cfpick/config.json", "r", encoding="utf-8") as handle:
        print(json.load(handle).get("web", {}).get("token", ""))
except Exception:
    print("")
PY
)"

cat <<EOF

[deploy] 完成
  程序目录 : /opt/cfpick
  源码目录 : $SRC_DIR
  配置文件 : /etc/cfpick/config.json
  结果目录 : /var/lib/cfpick
  日志     : journalctl -u cfpick-web -f
  命令     : cfpick status | cfpick cores | cfpick run start
EOF

if is_loopback "$CFG_LISTEN"; then
    cat <<EOF
  远程访问 : ssh -N -L $CFG_PORT:127.0.0.1:$CFG_PORT <用户>@<服务器IP>
             然后本地浏览器打开 http://127.0.0.1:$CFG_PORT/
EOF
else
    cat <<EOF
  Web 地址 : http://<服务器IP>:$CFG_PORT/
EOF
    if [ -z "$CFG_TOKEN" ]; then
        warn "Web 监听 $CFG_LISTEN 但未设置访问令牌；请设置 --token 或使用 SSH 隧道，并通过 HTTPS 反向代理访问。"
    fi
fi

if [ "$CORE_FAILED" = 1 ]; then
    warn "部署完成但存在未完成项（内核下载或 Web 健康检查失败），请查看上面的提示。"
    exit 1
fi
exit 0

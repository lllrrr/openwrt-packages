#!/bin/sh
# Install cfpick on Debian/Ubuntu.  Run as root from any directory:
#   sudo sh debian/install.sh
set -eu

APP_DIR=/opt/cfpick
CONFIG_DIR=/etc/cfpick
STATE_DIR=/var/lib/cfpick
LOG_DIR=/var/log/cfpick
UNIT=/etc/systemd/system/cfpick-web.service

log() { printf '[cfpick] %s\n' "$*"; }
fail() { printf '[cfpick] 错误: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "请使用 root 运行（sudo sh debian/install.sh）"
command -v python3 >/dev/null 2>&1 || fail "未找到 python3，请先安装：apt install python3"
command -v curl >/dev/null 2>&1 || log "警告: 未找到 curl，测速前请安装：apt install curl"
command -v crontab >/dev/null 2>&1 || log "警告: 未找到 crontab，定时测速不可用：apt install cron"

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -f "$SRC_DIR/cfpick/engine.py" ] || fail "安装包不完整：找不到 cfpick/engine.py"

log "安装到 $APP_DIR"
install -d -m 755 "$APP_DIR" "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
chmod 700 "$CONFIG_DIR"
rm -rf "$APP_DIR/cfpick" "$APP_DIR/web" "$APP_DIR/data" "$APP_DIR/bin"
install -d -m 755 "$APP_DIR/bin"
cp -a "$SRC_DIR/cfpick" "$APP_DIR/cfpick"
cp -a "$SRC_DIR/web" "$APP_DIR/web"
cp -a "$SRC_DIR/data" "$APP_DIR/data"
install -m 755 "$SRC_DIR/bin/cfpick" "$APP_DIR/bin/cfpick"
install -m 755 "$SRC_DIR/self-update.sh" "$APP_DIR/self-update.sh"
install -m 755 "$SRC_DIR/uninstall.sh" "$APP_DIR/uninstall.sh"
install -m 644 "$SRC_DIR/README.md" "$APP_DIR/README.md"
ln -sf "$APP_DIR/bin/cfpick" /usr/local/bin/cfpick

# Create the config once; keep an existing one untouched.
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    CFPICK_APP_DIR="$APP_DIR" CFPICK_CONFIG_DIR="$CONFIG_DIR" CFPICK_STATE_DIR="$STATE_DIR" \
    CFPICK_LOG_DIR="$LOG_DIR" PYTHONPATH="$APP_DIR" \
        python3 -c 'from cfpick import config; config.load()'
    chmod 600 "$CONFIG_DIR/config.json"
    log "已生成默认配置 $CONFIG_DIR/config.json"
else
    log "保留现有配置 $CONFIG_DIR/config.json"
fi

install -m 644 "$SRC_DIR/systemd/cfpick-web.service" "$UNIT"

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable cfpick-web.service
    systemctl restart cfpick-web.service
    log "Web 服务已启动/重启: http://127.0.0.1:8787/"
else
    log "未检测到 systemd，跳过服务启动。手动启动："
    log "  cd $APP_DIR && CFPICK_APP_DIR=$APP_DIR PYTHONPATH=$APP_DIR python3 -m cfpick serve"
fi

cat <<'EOF'

下一步：
  1. 安装代理内核（任选其一，或都装）：
       cfpick update-core                 # mihomo（默认）
       cfpick update-core --type xray     # Xray-core
       cfpick update-core --type all
     也可以打开 Web「内核」页，选择当前内核并分别安装/升级。
  2. 打开 Web 页面（默认 http://127.0.0.1:8787/），在「节点」页粘贴
     vless:// / vmess:// / trojan:// / ss:// / hysteria2:// 分享链接。
  3. 按需在「设置」页调整候选 IP、阈值、下载实测、迭代和定时任务。

常用命令：
  cfpick status
  cfpick run start
  cfpick run retest
  cfpick ddns show
  cfpick update-core
  systemctl status cfpick-web
  journalctl -u cfpick-web -f

默认只监听 127.0.0.1。如需远程访问，请先设置访问令牌，再用反向代理
（Nginx/Caddy）加 TLS 暴露，或修改 web.listen（不推荐直接暴露明文端口）。
EOF

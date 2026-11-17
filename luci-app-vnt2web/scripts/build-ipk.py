#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""免 SDK 打包 luci-app-vnt2web（ipk）。

用法：
    python scripts/build-ipk.py [版本号]

产物：dist/luci-app-vnt2web_<版本>-1_all.ipk

因为 luci-app-vnt2web 是纯脚本 + 前端资源的包（PKGARCH=all），
不需要交叉编译，所以可以这样直接组装，产物与 SDK 编译等价。
"""

import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import ipk  # noqa: E402

# 安装清单：源路径(相对包目录) -> 安装到设备的目标路径
#   root/  —— 与 OpenWrt 包约定一致（luci.mk / package.mk 都认这个目录名）
#   htdocs/ —— LuCI 静态资源，安装到 /www
INSTALL_MAP = [
    ("root/etc/init.d/vnt2web", "/etc/init.d/vnt2web", 0o755),
    ("root/etc/config/vnt2web", "/etc/config/vnt2web", 0o644),
    ("root/etc/uci-defaults/95-vnt2web", "/etc/uci-defaults/95-vnt2web", 0o755),
    ("root/usr/share/vnt2web/vnt.sh", "/usr/share/vnt2web/vnt.sh", 0o644),
    ("root/usr/share/vnt2web/vnt-core.sh", "/usr/share/vnt2web/vnt-core.sh", 0o644),
    # rpcd 后端：shell 插件机制（/usr/libexec/rpcd/），需可执行权限
    ("root/usr/libexec/rpcd/vnt2web", "/usr/libexec/rpcd/vnt2web", 0o755),
    ("root/usr/share/rpcd/acl.d/luci-app-vnt2web.json",
     "/usr/share/rpcd/acl.d/luci-app-vnt2web.json", 0o644),
    ("root/usr/share/luci/menu.d/luci-app-vnt2web.json",
     "/usr/share/luci/menu.d/luci-app-vnt2web.json", 0o644),
    ("htdocs/luci-static/resources/view/vnt2web/client.js",
     "/www/luci-static/resources/view/vnt2web/client.js", 0o644),
]

# 安装时保留用户改动的配置（opkg 升级不会覆盖）
CONFFILES = ["/etc/config/vnt2web"]

POSTINST = r"""
[ -n "${IPKG_INSTROOT}" ] && exit 0
# 目录：配置在 /etc 下（升级固件保留），日志与运行缓存放 /tmp（不写 Flash）
mkdir -p /etc/vnt2web/config 2>/dev/null
chmod 700 /etc/vnt2web 2>/dev/null
mkdir -p /tmp/vnt2web/run 2>/dev/null

# rpcd 插件脚本必须可执行，否则不会被注册为 ubus 对象
chmod 755 /usr/libexec/rpcd/vnt2web 2>/dev/null
chmod 755 /etc/init.d/vnt2web /etc/uci-defaults/95-vnt2web 2>/dev/null

# 生成初始访问令牌（>=16 位），让用户装完就能看到
if [ ! -s /etc/vnt2web/token ]; then
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex 24 > /etc/vnt2web/token 2>/dev/null
	elif [ -r /dev/urandom ]; then
		head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > /etc/vnt2web/token
	fi
	chmod 600 /etc/vnt2web/token 2>/dev/null
	# 同步进 UCI，便于界面直接读到
	tk="$(cat /etc/vnt2web/token 2>/dev/null)"
	[ -n "$tk" ] && uci -q set "vnt2web.main.token=$tk" && uci -q commit vnt2web
fi

# 让 LuCI 立刻发现新菜单
rm -f /tmp/luci-indexcache* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null

# rpcd 需要重新加载才能认识新的插件。
# 官方文档明确指出：在部分构建（CC 等）上 `reload` 不足以发现新插件，
# 必须 `restart`。为保证首次安装后界面就能用，这里直接用 restart。
/etc/init.d/rpcd restart >/dev/null 2>&1 || /etc/init.d/rpcd reload >/dev/null 2>&1
exit 0
"""

POSTRM = r"""
[ -n "${IPKG_INSTROOT}" ] && exit 0

# opkg 升级时也会调用 postrm（参数 upgrade）—— 此时绝不能动数据目录，
# 否则升级瞬间丢配置与核心，违背「升级不丢配置」。
case "$1" in
	upgrade) exit 0 ;;
esac

# 卸载时停服务
if [ -x /etc/init.d/vnt2web ]; then
	/etc/init.d/vnt2web stop >/dev/null 2>&1
	/etc/init.d/vnt2web disable >/dev/null 2>&1
fi

# 清运行期数据（/tmp 下的，重启本就会清）
rm -rf /tmp/vnt2web 2>/dev/null

# 把 /etc 下的数据目录搬到 /tmp —— 软删除：既不在 Flash 留残留，
# 又给「误卸载」留一次后悔机会（重启后随内存盘消失）。
# 加时间戳后缀，避免同一会话内重复卸载互相覆盖。
if [ -d /etc/vnt2web ]; then
	_stash="/tmp/vnt2web-removed-$$"
	mv -f /etc/vnt2web "$_stash" 2>/dev/null || rm -rf /etc/vnt2web 2>/dev/null
	if [ -d "$_stash" ]; then
		echo "配置与核心已移至 $_stash（重启后自动清除）。"
		echo "如需立刻彻底清除：rm -rf $_stash"
	fi
fi

rm -f /tmp/luci-indexcache* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null

# 让 rpcd 摘掉已删除的 ubus 对象
/etc/init.d/rpcd restart >/dev/null 2>&1
exit 0
"""


def norm_eol(path):
    """把文本文件的 CRLF 转成 LF。

    Windows 上编辑的 .sh/.uc/.js 会带 CRLF，装到 Linux 上后
    shell 脚本可能因 \\r 报错，前端 JS 也可能出问题，故统一为 LF。
    """
    exts = (".sh", ".uc", ".js", ".json", ".py", ".md", ".txt")
    if not path.lower().endswith(exts):
        return
    with open(path, "rb") as f:
        raw = f.read()
    if b"\r\n" in raw:
        with open(path, "wb") as f:
            f.write(raw.replace(b"\r\n", b"\n"))


def read_version():
    """从 Makefile 读版本号，保证与 SDK 编译一致。"""
    mk = os.path.join(ROOT, "Makefile")
    if os.path.exists(mk):
        with open(mk, encoding="utf-8") as f:
            for line in f:
                if line.startswith("PKG_VERSION:="):
                    return line.split(":=", 1)[1].strip()
    return "1.0.0"


def main():
    ver = sys.argv[1] if len(sys.argv) > 1 else read_version()
    stage = os.path.join(ROOT, "build", "stage")
    dist = os.path.join(ROOT, "dist")

    print("==> 组装 luci-app-vnt2web v%s" % ver)
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    os.makedirs(dist, exist_ok=True)

    installed = []
    mode_map = {}
    for rel, dest, mode in INSTALL_MAP:
        src = os.path.join(ROOT, rel)
        if not os.path.exists(src):
            print("!! 缺少文件: %s" % rel, file=sys.stderr)
            return 1
        norm_eol(src)
        target = os.path.join(stage, dest.lstrip("/"))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(src, target)
        os.chmod(target, mode)
        # 权限走显式表，不依赖文件系统（Windows 上无执行位语义）
        mode_map[dest.lstrip("/")] = mode
        installed.append(dest)

    print("   已收集 %d 个文件" % len(installed))

    out = os.path.join(dist, "luci-app-vnt2web_%s-1_all.ipk" % ver)
    ipk.build_ipk(
        stage_dir=stage,
        control_fields={
            "Package": "luci-app-vnt2web",
            "Version": "%s-1" % ver,
            "Depends": "luci-base, rpcd, kmod-tun, unzip",
            "Section": "luci",
            "Category": "LuCI",
            "Priority": "optional",
            "Architecture": "all",
            "Installed-Size": "0",
            "Maintainer": "VirKing <https://github.com/virkingz>",
            "License": "MIT",
            "Description": "VNT 组网（Web 版）：把 vnt2_web 封装成 OpenWrt 服务与 LuCI 界面，"
                           "可设置监听端口与访问令牌，并按架构在线下载与更新核心。"
                           "组网的添加与启停由 vnt2_web 自带网页完成，支持镜像/代理加速下载。",
        },
        out_path=out,
        scripts={"postinst": POSTINST, "postrm": POSTRM},
        conffiles=CONFFILES,
        mode_map=mode_map,
    )

    shutil.rmtree(stage, ignore_errors=True)

    size = os.path.getsize(out)
    print("\n==> 产物: %s (%d 字节)" % (out, size))
    return 0


if __name__ == "__main__":
    sys.exit(main())

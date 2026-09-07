import os
import sys
import io
import time
import shutil
import tarfile
import hashlib

if sys.stdout.encoding != 'utf-8':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

SOURCE_DIR = r"D:\rules\luci-app-autosign"
TARGET_DIR = r"F:\luci-app-autosign"
ROOT_DIR = os.path.join(SOURCE_DIR, "root")
CONTROL_DIR = os.path.join(SOURCE_DIR, "control")
CURRENT_TIME = int(time.time())
VERSION = "1.2.0"
PKG_RELEASE = "1"

os.makedirs(TARGET_DIR, exist_ok=True)

# 1. 复制最新源码树到 F:\luci-app-autosign
print(">>> [1/5] 同步完整源码树到 F:\\luci-app-autosign...")
for item in ["root", "control", "Makefile", "README.md"]:
    s_path = os.path.join(SOURCE_DIR, item)
    t_path = os.path.join(TARGET_DIR, item)
    if os.path.isdir(s_path):
        if os.path.exists(t_path):
            shutil.rmtree(t_path)
        shutil.copytree(s_path, t_path)
    elif os.path.isfile(s_path):
        shutil.copy2(s_path, t_path)
print("    源码树同步完成！")

# 2. 读取文件辅助函数
def get_file_content_unix(filepath):
    with open(filepath, 'rb') as f:
        data = f.read()
    return data.replace(b'\r\n', b'\n')

file_order = [
    'etc/config/autosign',
    'etc/init.d/autosign',
    'usr/share/autosign/autosign.sh',
    'usr/share/luci/menu.d/luci-app-autosign.json',
    'usr/share/rpcd/acl.d/luci-app-autosign.json',
    'www/luci-static/resources/view/autosign/index.js',
    'www/luci-static/resources/view/autosign/tasks.js'
]


# 3. 生成 iStore 专属 .run 自解压一键离线包
print("\n>>> [2/5] 构建 iStore 专属自解压离线安装包 (.run)...")
run_lines = [
    "#!/bin/sh",
    "# ==========================================================",
    "# iStore Self-Extracting Installer for luci-app-autosign",
    f"# Version: {VERSION}-{PKG_RELEASE} (Multi-task schedule + Smart cURL import edition)",
    "# Pure POSIX Shell - Zero dependencies",
    "# ==========================================================",
    "",
    'ACTION="${1:-install}"',
    "",
    "do_install() {",
    '    echo "=========================================================="',
    f'    echo ">>> 开始离线安装 luci-app-autosign v{VERSION}..."',
    '    echo ">>> 特性：多任务独立定时调度 + 浏览器F12抓包/cURL智能一键填单"',
    '    echo "=========================================================="',
    "",
    '    echo "[1/4] 创建系统目录结构..."',
    "    mkdir -p /etc/config",
    "    mkdir -p /etc/init.d",
    "    mkdir -p /usr/share/autosign",
    "    mkdir -p /usr/share/luci/menu.d",
    "    mkdir -p /usr/share/rpcd/acl.d",
    "    mkdir -p /www/luci-static/resources/view/autosign",
    "",
    '    echo "[2/4] 写入核心文件..."',
]

for rel_path in file_order:
    full_path = os.path.join(ROOT_DIR, rel_path.replace('/', os.sep))
    content = get_file_content_unix(full_path).decode('utf-8')
    target = "/" + rel_path
    if rel_path == 'etc/config/autosign':
        # 如果已经存在用户配置，保留旧配置不覆盖，否则释放默认配置
        run_lines.append(f"    if [ ! -f {target} ]; then")
        run_lines.append(f"        cat << '__AUTOSIGN_EOF__' > {target}")
        run_lines.append(content.rstrip('\n'))
        run_lines.append("__AUTOSIGN_EOF__")
        run_lines.append("    fi")
    else:
        run_lines.append(f"    cat << '__AUTOSIGN_EOF__' > {target}")
        run_lines.append(content.rstrip('\n'))
        run_lines.append("__AUTOSIGN_EOF__")

run_lines.extend([
    "",
    '    echo "[3/4] 赋予执行权限并同步定时计划任务..."',
    "    chmod 755 /etc/init.d/autosign",
    "    chmod 755 /usr/share/autosign/autosign.sh",
    "    /etc/init.d/autosign enable",
    "    /etc/init.d/autosign reload",
    "",
    '    echo "[4/4] 刷新 Web 界面缓存与服务..."',
    "    rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null",
    "    /etc/init.d/rpcd restart 2>/dev/null",
    "",
    '    echo "=========================================================="',
    f'    echo "✅ luci-app-autosign v{VERSION} 安装成功！"',
    '    echo "请刷新路由器 Web 页面，进入【服务】->【定时签到】配置独立任务时间。"',
    '    echo "=========================================================="',
    "    exit 0",
    "}",
    "",
    "do_uninstall() {",
    '    echo ">>> 正在卸载 luci-app-autosign..."',
    "    /etc/init.d/autosign stop 2>/dev/null",
    "    /etc/init.d/autosign disable 2>/dev/null",
    "    sed -i '/autosign.sh/d' /etc/crontabs/root 2>/dev/null",
    "    rm -rf /usr/share/autosign",
    "    rm -f /usr/share/luci/menu.d/luci-app-autosign.json",
    "    rm -f /usr/share/rpcd/acl.d/luci-app-autosign.json",
    "    rm -rf /www/luci-static/resources/view/autosign",
    "    rm -f /etc/init.d/autosign",
    "    rm -f /etc/config/autosign",
    "    rm -f /var/log/autosign.log",
    "    rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null",
    "    /etc/init.d/rpcd restart 2>/dev/null",
    '    echo "✅ 卸载完成。"',
    "    exit 0",
    "}",
    "",
    'case "$ACTION" in',
    '    install|dotrun|run|"")',
    "        do_install",
    "        ;;",
    "    uninstall|remove)",
    "        do_uninstall",
    "        ;;",
    "    *)",
    '        echo "用法: $0 [install|uninstall]"',
    "        exit 1",
    "        ;;",
    "esac",
    "",
    "exit 0",
    ""
])

run_path = os.path.join(TARGET_DIR, f"luci-app-autosign-{VERSION}.run")
with open(run_path, "wb") as f:
    f.write("\n".join(run_lines).encode("utf-8"))
print(f"    [OK] RUN 离线安装包已生成: {run_path} ({os.path.getsize(run_path)} 字节)")

# 4. 构建 APK 安装包 (适配 OpenWrt 25.12)
print("\n>>> [3/5] 构建 OpenWrt 25.12 专属 APK 格式安装包...")
def build_apk_data_tar():
    tar_stream = io.BytesIO()
    total_uncompressed = 0
    with tarfile.open(fileobj=tar_stream, mode="w:gz", format=tarfile.USTAR_FORMAT) as tar:
        dirs_added = set()
        for rel_file in file_order:
            parts = rel_file.split("/")
            for i in range(1, len(parts)):
                dpath = "/".join(parts[:i])
                if dpath not in dirs_added:
                    dirs_added.add(dpath)
                    dinfo = tarfile.TarInfo(name=dpath)
                    dinfo.mtime = CURRENT_TIME
                    dinfo.mode = 0o755
                    dinfo.uid = 0
                    dinfo.gid = 0
                    dinfo.uname = "root"
                    dinfo.gname = "root"
                    dinfo.type = tarfile.DIRTYPE
                    tar.addfile(dinfo)

            full_path = os.path.join(ROOT_DIR, rel_file.replace('/', os.sep))
            data = get_file_content_unix(full_path)
            total_uncompressed += len(data)
            is_exec = rel_file.startswith("etc/init.d/") or rel_file.endswith(".sh")
            mode = 0o755 if is_exec else 0o644

            tarinfo = tarfile.TarInfo(name=rel_file)
            tarinfo.size = len(data)
            tarinfo.mtime = CURRENT_TIME
            tarinfo.mode = mode
            tarinfo.uid = 0
            tarinfo.gid = 0
            tarinfo.uname = "root"
            tarinfo.gname = "root"
            tarinfo.type = tarfile.REGTYPE
            tar.addfile(tarinfo, io.BytesIO(data))

    return tar_stream.getvalue(), total_uncompressed

def build_apk_control(arch, uncompressed_size, datahash):
    pkginfo_content = f"""# Generated by OpenWrt 25 apk builder
pkgname = luci-app-autosign
pkgver = {VERSION}-r{PKG_RELEASE}
pkgdesc = Modern Daily Auto Check-in Plugin for OpenWrt (Independent Schedule Edition)
url = https://github.com/sanwei2493313866-wq/luci-app-autosign
builddate = {CURRENT_TIME}
packager = OpenWrt Developer
size = {uncompressed_size}
arch = {arch}
origin = luci-app-autosign
license = Apache-2.0
datahash = {datahash}
"""
    scripts = {
        ".post-install": """#!/bin/sh
chmod +x /etc/init.d/autosign
chmod +x /usr/share/autosign/autosign.sh
/etc/init.d/autosign enable
/etc/init.d/autosign reload
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
exit 0
""",
        ".pre-deinstall": """#!/bin/sh
/etc/init.d/autosign stop
/etc/init.d/autosign disable
exit 0
""",
        ".post-deinstall": """#!/bin/sh
rm -f /var/log/autosign.log
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
exit 0
"""
    }
    tar_stream = io.BytesIO()
    with tarfile.open(fileobj=tar_stream, mode="w:gz", format=tarfile.USTAR_FORMAT) as tar:
        info_data = pkginfo_content.encode("utf-8")
        tarinfo = tarfile.TarInfo(name=".PKGINFO")
        tarinfo.size = len(info_data)
        tarinfo.mtime = CURRENT_TIME
        tarinfo.mode = 0o644
        tarinfo.uid = 0
        tarinfo.gid = 0
        tarinfo.uname = "root"
        tarinfo.gname = "root"
        tarinfo.type = tarfile.REGTYPE
        tar.addfile(tarinfo, io.BytesIO(info_data))

        for sname, scontent in scripts.items():
            sdata = scontent.replace("\r\n", "\n").encode("utf-8")
            tarinfo = tarfile.TarInfo(name=sname)
            tarinfo.size = len(sdata)
            tarinfo.mtime = CURRENT_TIME
            tarinfo.mode = 0o755
            tarinfo.uid = 0
            tarinfo.gid = 0
            tarinfo.uname = "root"
            tarinfo.gname = "root"
            tarinfo.type = tarfile.REGTYPE
            tar.addfile(tarinfo, io.BytesIO(sdata))

    return tar_stream.getvalue()

apk_data_tar, uncomp_sz = build_apk_data_tar()
apk_hash = hashlib.sha256(apk_data_tar).hexdigest()

apk_path = os.path.join(TARGET_DIR, f"luci-app-autosign-{VERSION}-r{PKG_RELEASE}.apk")
with open(apk_path, "wb") as f:
    f.write(build_apk_control("aarch64", uncomp_sz, apk_hash))
    f.write(apk_data_tar)
print(f"    [OK] APK 安装包已生成: {apk_path} ({os.path.getsize(apk_path)} 字节)")

# 5. 构建 IPK 安装包 (传统 opkg 格式)
print("\n>>> [4/5] 构建标准 OPKG 格式安装包 (.ipk)...")
def build_ipk_control(arch="all"):
    tar_stream = io.BytesIO()
    control_text = f"""Package: luci-app-autosign
Version: {VERSION}-{PKG_RELEASE}
Architecture: {arch}
Section: luci
Category: LuCI
Title: Modern Daily Auto Check-in Plugin (Independent Schedule Edition)
Maintainer: OpenWrt Developer
Description: Modern Daily Auto Check-in Plugin with independent task scheduling support.
"""
    postinst_text = """#!/bin/sh
chmod +x /etc/init.d/autosign
chmod +x /usr/share/autosign/autosign.sh
/etc/init.d/autosign enable
/etc/init.d/autosign reload
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
exit 0
"""
    prerm_text = """#!/bin/sh
/etc/init.d/autosign stop
/etc/init.d/autosign disable
exit 0
"""
    postrm_text = """#!/bin/sh
rm -f /var/log/autosign.log
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
exit 0
"""
    scripts = {
        "control": (control_text, 0o644),
        "postinst": (postinst_text, 0o755),
        "prerm": (prerm_text, 0o755),
        "postrm": (postrm_text, 0o755)
    }
    with tarfile.open(fileobj=tar_stream, mode="w:gz", format=tarfile.USTAR_FORMAT) as tar:
        for sname, (scontent, smode) in scripts.items():
            sdata = scontent.replace("\r\n", "\n").encode("utf-8")
            tarinfo = tarfile.TarInfo(name=f"./{sname}")
            tarinfo.size = len(sdata)
            tarinfo.mtime = CURRENT_TIME
            tarinfo.mode = smode
            tarinfo.uid = 0
            tarinfo.gid = 0
            tarinfo.uname = "root"
            tarinfo.gname = "root"
            tarinfo.type = tarfile.REGTYPE
            tar.addfile(tarinfo, io.BytesIO(sdata))
    return tar_stream.getvalue()

def build_ipk_data():
    tar_stream = io.BytesIO()
    with tarfile.open(fileobj=tar_stream, mode="w:gz", format=tarfile.USTAR_FORMAT) as tar:
        rootinfo = tarfile.TarInfo(name=".")
        rootinfo.mtime = CURRENT_TIME
        rootinfo.mode = 0o755
        rootinfo.uid = 0
        rootinfo.gid = 0
        rootinfo.uname = "root"
        rootinfo.gname = "root"
        rootinfo.type = tarfile.DIRTYPE
        tar.addfile(rootinfo)

        dirs_added = set()
        for rel_file in file_order:
            parts = rel_file.split("/")
            for i in range(1, len(parts)):
                dpath = "./" + "/".join(parts[:i])
                if dpath not in dirs_added:
                    dirs_added.add(dpath)
                    dinfo = tarfile.TarInfo(name=dpath)
                    dinfo.mtime = CURRENT_TIME
                    dinfo.mode = 0o755
                    dinfo.uid = 0
                    dinfo.gid = 0
                    dinfo.uname = "root"
                    dinfo.gname = "root"
                    dinfo.type = tarfile.DIRTYPE
                    tar.addfile(dinfo)

            full_path = os.path.join(ROOT_DIR, rel_file.replace('/', os.sep))
            data = get_file_content_unix(full_path)
            is_exec = rel_file.startswith("etc/init.d/") or rel_file.endswith(".sh")
            mode = 0o755 if is_exec else 0o644

            tarinfo = tarfile.TarInfo(name=f"./{rel_file}")
            tarinfo.size = len(data)
            tarinfo.mtime = CURRENT_TIME
            tarinfo.mode = mode
            tarinfo.uid = 0
            tarinfo.gid = 0
            tarinfo.uname = "root"
            tarinfo.gname = "root"
            tarinfo.type = tarfile.REGTYPE
            tar.addfile(tarinfo, io.BytesIO(data))

    return tar_stream.getvalue()

def pack_ar_ipk(output_path, control_gz, data_gz):
    debian_binary = b"2.0\n"
    members = [
        ("debian-binary", debian_binary, 0o100644),
        ("control.tar.gz", control_gz, 0o100644),
        ("data.tar.gz", data_gz, 0o100644),
    ]
    with open(output_path, "wb") as f:
        f.write(b"!<arch>\n")
        for name, data, mode in members:
            name_field = f"{name:<16}".encode("ascii")
            mtime_field = f"{CURRENT_TIME:<12}".encode("ascii")
            uid_field = b"0     "
            gid_field = b"0     "
            mode_field = f"{oct(mode)[2:]:<8}".encode("ascii")
            size_field = f"{len(data):<10}".encode("ascii")
            magic_field = b"\x60\n"
            header = name_field + mtime_field + uid_field + gid_field + mode_field + size_field + magic_field
            f.write(header)
            f.write(data)
            if len(data) % 2 != 0:
                f.write(b"\n")

ipk_path = os.path.join(TARGET_DIR, f"luci-app-autosign_{VERSION}-{PKG_RELEASE}_all.ipk")
pack_ar_ipk(ipk_path, build_ipk_control("all"), build_ipk_data())
print(f"    [OK] IPK 安装包已生成: {ipk_path} ({os.path.getsize(ipk_path)} 字节)")

# 6. 编写详细使用说明
print("\n>>> [5/5] 生成配套使用说明文档...")
readme_text = f"""==========================================================
 定时自动签到插件 (独立定时调度 + 智能抓包导入版) v{VERSION}
 存放目录: F:\\luci-app-autosign
==========================================================

【新增核心功能】:
★ 【智能抓包 / cURL 一键填单】:
   支持直接粘贴浏览器 (F12) 复制的 cURL (bash / cmd / PowerShell) 或原始 HTTP 报文，
   系统自动提取 URL、请求方式、请求头、Cookie 和请求载荷并自动新建任务，免去繁琐手工填写！
★ 【多任务独立定时调度】:
   支持每个签到任务设定不同的执行时间（几点几分，如 08:30、12:00），
   任务之间互不影响，各自按照预设时间在后台独立触发打卡！
★ 【直观 Web 界面】:
   在任务表格中直接点击下拉框修改执行时间，操作清晰便捷。

【包含文件清单】:
1. luci-app-autosign-{VERSION}.run
   -> iStore 专属自解压一键离线安装包（强烈推荐！零依赖、兼容所有 OpenWrt 版本）。
   
2. luci-app-autosign-{VERSION}-r{PKG_RELEASE}.apk
   -> OpenWrt 25.12 官方 apk 包（可通过终端 apk add 安装）。

3. luci-app-autosign_{VERSION}-{PKG_RELEASE}_all.ipk
   -> 传统 opkg ipk 包。

4. 完整源码目录:
   - root/        : 插件系统文件（UCI、init 脚本、核心引擎、LuCI JS 界面）
   - control/     : 包控制信息
   - Makefile     : OpenWrt SDK 编译规则
   - README.md    : 详细特性与使用说明

【安装方法（推荐通过 iStore 网页端）】:
1. 打开路由器管理后台 -> 进入【iStore 应用商店】。
2. 点击【手动安装】标签页 -> 选择【上传并安装】。
3. 选择本目录下的 `luci-app-autosign-{VERSION}.run`。
4. 安装完成后，刷新管理后台，在左侧【服务】菜单中点击【定时签到】。
5. 在【签到任务管理】中添加或编辑任务，即可为每个任务自由设置每天几点几分执行！

【卸载方法】:
在路由器终端中执行：
   sh luci-app-autosign-{VERSION}.run uninstall
或者直接执行清理命令：
   /etc/init.d/autosign stop 2>/dev/null
   /etc/init.d/autosign disable 2>/dev/null
   sed -i '/autosign.sh/d' /etc/crontabs/root 2>/dev/null
   rm -rf /usr/share/autosign /etc/config/autosign /etc/init.d/autosign
   rm -f /usr/share/luci/menu.d/luci-app-autosign.json /usr/share/rpcd/acl.d/luci-app-autosign.json
   rm -rf /www/luci-static/resources/view/autosign
   rm -f /tmp/luci-indexcache
   /etc/init.d/rpcd restart 2>/dev/null
"""

with open(os.path.join(TARGET_DIR, "使用说明.txt"), "wb") as f:
    f.write(readme_text.replace("\r\n", "\n").encode("utf-8"))

print("    [OK] 使用说明.txt 已生成！")
print("\n" + "="*60)
print("✅ 全部构建完成！已成功部署并打包至 F:\\luci-app-autosign")
print("="*60)

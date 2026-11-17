#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""luci-app-vnt2web 本地测试。

全部不联网、不依赖 OpenWrt 环境，可在开发机直接跑：
    python scripts/test.py

覆盖：
  1. 架构映射      DISTRIB_ARCH -> vnt 目标三元组
  2. 版本号解析    各种脏输入（含镜像把整段 URL 编码的情况）
  3. 版本比较
  4. UCI -> 命令行参数翻译（用桩 uci 驱动真实 shell 库）
  5. ipk 产物结构与权限
  6. 文件与语法静态检查
"""

import gzip
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PASS = 0
FAIL = 0
FAILED = []


def check(name, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
    else:
        FAIL += 1
        FAILED.append("%s\n     期望: %r\n     实际: %r" % (name, want, got))


def check_true(name, cond, detail=""):
    check(name + ((" (" + detail + ")") if detail else ""), bool(cond), True)


def section(t):
    print("\n" + "=" * 66)
    print(t)
    print("=" * 66)


# ---------------------------------------------------------------------------
# 跑 shell：加载库并执行片段
# ---------------------------------------------------------------------------
def sh(script, env=None):
    """在临时环境里 source vnt 库后执行脚本，返回 stdout。"""
    e = dict(os.environ)
    if env:
        e.update(env)
    prelude = (
        'VNT_ETC="%s/vntetc"; VNT_LOG_DIR="%s/vntlog"; VNT_CACHE_DIR="%s/vntcache"; '
        '. "%s/root/usr/share/vnt2web/vnt.sh"; '
        '. "%s/root/usr/share/vnt2web/vnt-core.sh"; '
    ) % (e.get("TMPD", "/tmp"), e.get("TMPD", "/tmp"), e.get("TMPD", "/tmp"), ROOT, ROOT)
    r = subprocess.run(["sh", "-c", prelude + script],
                       capture_output=True, text=True, env=e)
    return r.stdout.strip()


# ---------------------------------------------------------------------------
# 1. 架构映射
# ---------------------------------------------------------------------------
def test_arch():
    section("1. 架构映射")
    cases = [
        ("x86_64", "vnt2-x86_64-unknown-linux-musl"),
        ("aarch64_generic", "vnt2-aarch64-unknown-linux-musl"),
        ("aarch64_cortex-a53", "vnt2-aarch64-unknown-linux-musl"),
        ("aarch64_cortex-a72", "vnt2-aarch64-unknown-linux-musl"),
        ("arm_cortex-a7_neon-vfpv4", "vnt2-armv7-unknown-linux-musleabihf"),
        ("arm_cortex-a15_neon-vfpv4", "vnt2-armv7-unknown-linux-musleabihf"),
        ("arm_cortex-a7", "vnt2-armv7-unknown-linux-musleabi"),
        ("arm_arm1176jzf-s_vfp", "vnt2-arm-unknown-linux-musleabihf"),
        ("mips_24kc", "vnt2-mips-unknown-linux-musl"),
        ("mipsel_24kc", "vnt2-mipsel-unknown-linux-musl"),
        ("mipsel_24kc_24kf", "vnt2-mipsel-unknown-linux-musl"),
    ]
    for arch, want in cases:
        got = sh('vnt_asset_name %s || echo UNSUPPORTED' % arch)
        check("架构 %s" % arch, got, want)

    # 明确不支持的架构
    for arch in ["i386_pentium4", "riscv64_riscv64", "loongarch64"]:
        got = sh('vnt_asset_name %s 2>/dev/null || echo UNSUPPORTED' % arch)
        check("架构 %s 应不支持" % arch, got, "UNSUPPORTED")


# ---------------------------------------------------------------------------
# 2. 版本号解析
# ---------------------------------------------------------------------------
def test_version():
    section("2. 版本号解析")
    cases = [
        ("2.0.11", "2.0.11"),
        ("v2.0.11", "2.0.11"),
        ("2.0", "2.0"),
        ("2.0.11.1", "2.0.11.1"),
        ("tag/v2.0.12", "2.0.12"),
        ("v2.0.11\n", "2.0.11"),
        # 镜像把整段 URL 编码 —— 这是最容易出错的情况
        ("vhttps%3A%2F%2Fgithub.com%2Fvnt-dev%2Fvnt%2Freleases%2Ftag%2Fv2.0.11", "2.0.11"),
        ("https://github.com/vnt-dev/vnt/releases/tag/v2.0.11", "2.0.11"),
        ("vnt2-x86_64-unknown-linux-musl-v2.0.11.zip", "2.0.11"),
        ('{"version":"2.0.11"}', "2.0.11"),
    ]
    for raw, want in cases:
        got = sh("vnt_normalize_version '%s' 2>/dev/null || echo REJECT" % raw)
        check("版本解析 %s" % raw[:44], got, want)

    # 应被拒绝的
    for raw in ["junk", "", "no-version-here", "abc.def"]:
        got = sh("vnt_normalize_version '%s' 2>/dev/null || echo REJECT" % raw)
        check("版本拒绝 %r" % raw, got, "REJECT")


# ---------------------------------------------------------------------------
# 3. 版本比较
# ---------------------------------------------------------------------------
def test_vercmp():
    section("3. 版本比较")
    cases = [
        ("2.0.11 2.0.12", "-1"),
        ("2.0.12 2.0.11", "1"),
        ("2.0.11 2.0.11", "0"),
        ("2.1 2.0.11", "1"),
        ("2.0.11.1 2.0.11", "1"),
        ("1.9.9 2.0.0", "-1"),
    ]
    for pair, want in cases:
        got = sh("vnt_ver_cmp %s" % pair)
        check("比较 %s" % pair, got, want)


# ---------------------------------------------------------------------------
# 4. 令牌与监听地址（vnt2_web 版的核心配置逻辑）
# ---------------------------------------------------------------------------
def test_token_and_addr():
    section("4. 令牌与监听地址")

    stub_dir = tempfile.mkdtemp(prefix="vntstub")
    # 桩 uci：从 UCI_<config>_<section>_<option> 环境变量回读
    with open(os.path.join(stub_dir, "uci"), "w") as f:
        f.write('#!/bin/sh\n'
                'if [ "$1" = "-q" ] && [ "$2" = "get" ]; then\n'
                '  k=$(echo "$3" | sed "s/[.\\-]/_/g")\n'
                '  eval "v=\\${UCI_$k}"\n'
                '  [ -n "$v" ] && echo "$v"\n'
                'fi\n'
                'exit 0\n')
    os.chmod(os.path.join(stub_dir, "uci"), 0o755)

    base_env = {
        "PATH": stub_dir + os.pathsep + os.environ.get("PATH", ""),
        "TMPD": stub_dir,
    }

    def sh_(script, extra=None):
        e = dict(base_env)
        if extra:
            e.update(extra)
        return sh(script, e)

    # ---- 令牌生成 ----
    t = sh_("vnt_gen_token")
    check_true("令牌已生成", bool(t), "")
    check_true("令牌长度 >= 16", len(t) >= 16, "实际 %d 位: %r" % (len(t), t))
    check_true("令牌为十六进制", bool(re.match(r"^[0-9a-fA-F]+$", t)), t)
    check("令牌可读回", sh_("vnt_get_token"), t)

    # 再次生成应不同（随机性）
    t2 = sh_("vnt_gen_token")
    check_true("两次生成的令牌不同", t != t2, "%s vs %s" % (t, t2))

    # ---- 令牌校验 ----
    cases = [
        ("1234567890123456", "有效"),   # 恰好 16 位
        ("123456789012345", "无效"),    # 15 位，过短
        ("", "无效"),
        ("has space in token", "无效"),
        ("abc", "无效"),
    ]
    for tok, want in cases:
        got = sh_("vnt_token_valid '%s' && echo 有效 || echo 无效" % tok)
        check("令牌校验 %r" % tok[:20], got, want)

    # ---- 监听地址组装 ----
    check("默认 addr", sh_("vnt_web_addr", {"UCI_vnt2web_main_port": "19099"}),
          "0.0.0.0:19099")
    # 监听地址已固定为 0.0.0.0：不再提供配置项，UCI 里的 bind 取值应被忽略
    check("bind 配置被忽略（固定 0.0.0.0）",
          sh_("vnt_web_addr", {"UCI_vnt2web_main_bind": "127.0.0.1",
                               "UCI_vnt2web_main_port": "8080"}),
          "0.0.0.0:8080")
    check("vnt_web_bind 固定返回 0.0.0.0",
          sh_("vnt_web_bind", {"UCI_vnt2web_main_bind": "127.0.0.1"}),
          "0.0.0.0")
    # 非法端口应回退 19099
    check("非法端口回退", sh_("vnt_web_port", {"UCI_vnt2web_main_port": "abc"}), "19099")
    check("超范围端口回退", sh_("vnt_web_port", {"UCI_vnt2web_main_port": "99999"}), "19099")
    check("端口 0 回退", sh_("vnt_web_port", {"UCI_vnt2web_main_port": "0"}), "19099")

    # ---- 面板地址 ----
    url = sh_("vnt_panel_url_bare", {"UCI_vnt2web_main_port": "19099"})
    check_true("bare 面板地址无令牌", "?token=" not in url, url)
    check_true("bare 面板地址格式正确", url.startswith("http://") and url.endswith("/"), url)

    # 先生成令牌，再验证带令牌的地址
    sh_("vnt_gen_token")
    url2 = sh_("vnt_panel_url", {"UCI_vnt2web_main_port": "19099"})
    check_true("带令牌面板地址含 ?token=", "?token=" in url2, url2)

    # ---- 日志级别环境变量 ----
    check("log_level 默认", sh_("vnt_log_level_env"), "RUST_LOG=info")
    check("log_level debug", sh_("vnt_log_level_env",
                                 {"UCI_vnt2web_main_log_level": "debug"}),
          "RUST_LOG=debug")
    check("log_level 非法值回退", sh_("vnt_log_level_env",
                                     {"UCI_vnt2web_main_log_level": "bogus"}),
          "RUST_LOG=info")

    # ---- 路径：默认可配置值 ----
    check("默认核心路径", sh_("vnt_bin_path"), "/usr/bin/vnt2web")
    check("默认配置目录", sh_("vnt_config_path"), "/etc/vnt2web/config")
    check("自定义核心路径", sh_("vnt_bin_path",
                                {"UCI_vnt2web_main_bin_path": "/mnt/sda1/vnt2_web"}),
          "/mnt/sda1/vnt2_web")
    check("自定义配置目录", sh_("vnt_config_path",
                                {"UCI_vnt2web_main_config_dir": "/mnt/sda1/conf"}),
          "/mnt/sda1/conf")
    # 核心会在配置目录下创建 vnt_config/
    check("配置子目录跟随配置目录", sh_("vnt_config_dir",
                                       {"UCI_vnt2web_main_config_dir": "/mnt/sda1/conf"}),
          "/mnt/sda1/conf/vnt_config")
    check("配置子目录默认值", sh_("vnt_config_dir"),
          "/etc/vnt2web/config/vnt_config")

    # ---- 路径：日志与状态文件的落点约定 ----
    # 注意：sh() 的 prelude 会把 VNT_ETC / VNT_LOG_DIR 指到临时目录，
    # 因此这里检查的是「是否落在预期的根目录下」与「相对结构」，
    # 而不是硬编码的绝对路径。默认绝对值另用一组断言验证常量。
    ldir = sh_("printf '%s' \"$VNT_LOG_DIR\"")
    check_true("日志目录是 tmpfs（/tmp 或临时目录下）",
               ('/tmp' in ldir) or ('Temp' in ldir) or ('temp' in ldir), ldir)
    check_true("日志目录名以 vnt 开头",
               ldir.rstrip('/').split('/')[-1].startswith('vnt'), ldir)
    check("日志文件名", sh_("basename \"$VNT_CORE_LOG\""), "core.log")
    check("主日志文件名", sh_("basename \"$VNT_MAIN_LOG\""), "main.log")

    # 版本/来源/令牌都在 $VNT_ETC 根下，且不随 bin_path 漂移
    vf = sh_("vnt_ver_file")
    check("版本标记文件名", sh_("basename \"$(vnt_ver_file)\""), ".core_version")
    check("来源标记文件名", sh_("basename \"$(vnt_src_file)\""), ".core_source")
    check("令牌文件名", sh_("basename \"$(vnt_token_file)\""), "token")
    vf2 = sh_("vnt_ver_file", {"UCI_vnt2web_main_bin_path": "/mnt/sda1/vnt2_web"})
    check("版本标记不随 bin 漂移", vf2, vf)
    tk2 = sh_("vnt_token_file", {"UCI_vnt2web_main_bin_path": "/mnt/sda1/x"})
    check("令牌不随 bin 漂移", tk2, sh_("vnt_token_file"))
    # 三者应在同一目录（都在 VNT_ETC 下）
    check("版本/令牌同目录",
          sh_("dirname \"$(vnt_ver_file)\""), sh_("dirname \"$(vnt_token_file)\""))

    # ---- 默认绝对路径（读源码里的默认值，绕开 prelude 的环境变量覆盖）----
    check("默认 bin 常量", sh_("printf '%s' \"$VNT_BIN_DEFAULT\""),
          "/usr/bin/vnt2web")
    check("默认 config 常量", sh_("printf '%s' \"$VNT_CFG_DEFAULT\""),
          "/etc/vnt2web/config")
    # 日志默认值在源码里是 /tmp/vnt2web（被 prelude 覆盖，故查源文件）
    lib_src = open(os.path.join(ROOT, "root/usr/share/vnt2web/vnt.sh"),
                   encoding="utf-8").read()
    check_true("源码中日志默认值为 /tmp/vnt2web",
               'VNT_LOG_DIR="${VNT_LOG_DIR:-/tmp/vnt2web}"' in lib_src, "")
    check_true("源码中缓存默认值在 /tmp 下",
               '/tmp/vnt2web/run' in lib_src, "")

    shutil.rmtree(stub_dir, ignore_errors=True)


# ---------------------------------------------------------------------------
# 5. ipk 产物
# ---------------------------------------------------------------------------
def test_ipk():
    section("5. ipk 产物结构与权限")

    ipk_path = None
    dist = os.path.join(ROOT, "dist")
    for n in os.listdir(dist) if os.path.isdir(dist) else []:
        if n.endswith(".ipk"):
            ipk_path = os.path.join(dist, n)
    if not ipk_path:
        check_true("存在 ipk 产物", False, "请先运行 scripts/build-ipk.py")
        return
    print("  产物: %s" % os.path.basename(ipk_path))

    raw = open(ipk_path, "rb").read()

    # ---- 最关键的一条：外层必须是 gzip 压缩的 tar，不能是 ar ----
    # ar 是 Debian .deb 的容器，opkg 会报 "Malformed package file"。
    check("外层为 gzip（非 ar）", raw[:2], b"\x1f\x8b")
    check_true("外层不是 ar 格式", raw[:8] != b"!<arch>\n",
               "用了 ar 会被 opkg 拒绝")

    # tar 必须能直接读出（opkg 内部就是这么读的）
    try:
        outer = tarfile.open(ipk_path, "r:gz")
        outer_names = [m.name for m in outer.getmembers()]
        check_true("tar 可读且含三个成员", True)
    except Exception as ex:
        check_true("tar 可读", False, str(ex))
        return

    # 成员名与顺序对齐官方 ipkg-build：./debian-binary ./data.tar.gz ./control.tar.gz
    check("外层成员名与顺序", outer_names,
          ["./debian-binary", "./data.tar.gz", "./control.tar.gz"])

    check("debian-binary 内容", outer.extractfile("./debian-binary").read(), b"2.0\n")

    # ---- control.tar.gz ----
    ct = tarfile.open(fileobj=io.BytesIO(outer.extractfile("./control.tar.gz").read()))
    cnames = [m.name for m in ct.getmembers()]
    check_true("control 含 . 根条目", "." in cnames, str(cnames))
    check_true("control 成员带 ./ 前缀",
               all(n == "." or n.startswith("./") for n in cnames), str(cnames))
    ctrl = ct.extractfile("./control").read().decode()
    check_true("control 含包名", "Package: luci-app-vnt2web" in ctrl, "")
    check_true("control 含依赖", "Depends:" in ctrl and "kmod-tun" in ctrl, "")
    check_true("Installed-Size 已回填", "Installed-Size: 0" not in ctrl, "")
    check_true("conffiles 含配置", "/etc/config/vnt2web" in
               ct.extractfile("./conffiles").read().decode(), "")
    check("postinst 权限", ct.getmember("./postinst").mode, 0o755)
    check("postrm 权限", ct.getmember("./postrm").mode, 0o755)

    # ---- postrm 行为：卸载软删除，但升级必须保留 ----
    # 这是易错点：opkg 升级时也调 postrm（传 upgrade），若无条件搬走 /etc/vnt2web，
    # 升级瞬间丢配置与核心。
    postrm_src = ct.extractfile("./postrm").read().decode()
    check_true("postrm 区分 upgrade（升级时保留数据）",
               "upgrade)" in postrm_src, "否则升级会丢配置")
    check_true("postrm 把数据移到 /tmp（软删除）",
               "/tmp/vnt2web-removed-" in postrm_src, "")
    # mv 失败（如跨设备）时才退化为直接删除，这是有意的兜底；
    # 但不能无条件 rm —— 那样就不是软删除了。
    check_true("rm 仅作为 mv 失败的兜底",
               "|| rm -rf /etc/vnt2web" in postrm_src, "")
    # 实测行为：真跑一遍 postrm，验升级保留、卸载搬走
    postrm_py = os.path.join(ROOT, "scripts/build-ipk.py")
    import re as _re
    _src = open(postrm_py, encoding="utf-8").read()
    _m = _re.search(r'POSTRM = r"""(.*?)"""', _src, _re.S)
    if _m:
        import subprocess as _sp
        import tempfile as _tf
        for arg, expect_kept in [("upgrade", True), ("remove", False)]:
            with _tf.TemporaryDirectory() as td:
                # 关键：临时目录在 Windows 下是反斜杠路径，直接塞进 sh 会被
                # 当成转义序列（\U \v \T ...）吃掉反斜杠，导致 [ -d ] 判断失败。
                # 必须转成正斜杠。
                sl = td.replace("\\", "/")
                os.makedirs(os.path.join(td, "etc/vnt2web/config"))
                open(os.path.join(td, "etc/vnt2web/token"), "w").write("tok")
                sc = _m.group(1)
                for a, b in [("/etc/vnt2web", sl + "/etc/vnt2web"),
                             ("/tmp/vnt2web", sl + "/tmp/vnt2web"),
                             ("/etc/init.d/rpcd", "true"),
                             ("/etc/init.d/vnt2web", "true"),
                             ("/tmp/luci-indexcache", sl + "/tmp/luci-indexcache"),
                             ("/tmp/luci-modulecache", sl + "/tmp/luci-modulecache")]:
                    sc = sc.replace(a, b)
                _sp.run(["sh", "-c", sc, "--", arg], capture_output=True, timeout=20)
                kept = os.path.isdir(os.path.join(td, "etc/vnt2web"))
                label = "升级" if arg == "upgrade" else "卸载"
                check_true("postrm %s 时数据%s" % (label, "保留" if expect_kept else "搬走"),
                           kept == expect_kept, "")

    # ---- data.tar.gz ----
    dt = tarfile.open(fileobj=io.BytesIO(outer.extractfile("./data.tar.gz").read()))
    members = dt.getmembers()
    dnames = [m.name for m in members]
    check_true("data 含 . 根条目", "." in dnames, "")
    check_true("data 成员带 ./ 前缀",
               all(n == "." or n.startswith("./") for n in dnames), "")

    mode_map = {
        "etc/init.d/vnt2web": 0o755,
        "etc/uci-defaults/95-vnt2web": 0o755,
        "etc/config/vnt2web": 0o644,
        "usr/share/vnt2web/vnt.sh": 0o644,
        "usr/share/vnt2web/vnt-core.sh": 0o644,
        "usr/libexec/rpcd/vnt2web": 0o755,
        "usr/share/rpcd/acl.d/luci-app-vnt2web.json": 0o644,
        "usr/share/luci/menu.d/luci-app-vnt2web.json": 0o644,
        "www/luci-static/resources/view/vnt2web/client.js": 0o644,
    }
    files = {m.name.lstrip("./"): m for m in members if m.isfile()}
    for path, mode in mode_map.items():
        check_true("包含 %s" % path, path in files, "")
        if path in files:
            check("权限 %s" % path, files[path].mode, mode)

    # 目录条目必须存在，否则安装后目录可能缺失
    dirs = {m.name.lstrip("./") for m in members if m.isdir()}
    for d in ["etc", "etc/config", "etc/init.d", "usr", "usr/share/vnt2web",
              "www/luci-static/resources/view/vnt2web"]:
        check_true("含目录条目 %s" % d, d in dirs, "")

    # 所有条目必须 root、无 CRLF
    for m in members:
        if m.isfile():
            check_true("uid/gid=root: %s" % m.name, m.uid == 0 and m.gid == 0, "")
    for path in ["etc/init.d/vnt2web", "usr/share/vnt2web/vnt.sh",
                 "www/luci-static/resources/view/vnt2web/client.js",
                 "usr/libexec/rpcd/vnt2web"]:
        if path in files:
            c = dt.extractfile("./" + path).read()
            check_true("LF 换行: %s" % path, b"\r\n" not in c, "含 CRLF")


# ---------------------------------------------------------------------------
# 5b. 与官方真包对照（有基准文件时执行）
# ---------------------------------------------------------------------------
def test_against_official():
    section("5b. 与官方真包对照")

    ref = os.path.join(ROOT, "scripts", "ref", "official-6to4_13_all.ipk")
    if not os.path.exists(ref):
        print("  (未找到 scripts/ref/official-6to4_13_all.ipk，跳过。")
        print("   获取方式：curl -o scripts/ref/official-6to4_13_all.ipk \\")
        print("     https://downloads.openwrt.org/releases/23.05.5/packages/x86_64/base/6to4_13_all.ipk)")
        return

    dist = os.path.join(ROOT, "dist")
    mine = None
    for n in os.listdir(dist) if os.path.isdir(dist) else []:
        if n.endswith(".ipk"):
            mine = os.path.join(dist, n)
    if not mine:
        check_true("存在 ipk 产物", False, "")
        return

    def outer_info(p):
        o = tarfile.open(p, "r:gz")
        names = [m.name for m in o.getmembers()]
        deb = o.extractfile("./debian-binary").read()
        ct = tarfile.open(fileobj=io.BytesIO(o.extractfile("./control.tar.gz").read()))
        cn = [m.name for m in ct.getmembers()]
        return names, deb, cn

    on, odeb, ocn = outer_info(ref)
    mn, mdeb, mcn = outer_info(mine)

    check("外层成员名与顺序对齐官方", mn, on)
    check("debian-binary 对齐官方", mdeb, odeb)
    check_true("control 成员形式对齐官方（. 与 ./ 前缀）",
               all(n == "." or n.startswith("./") for n in mcn) and "." in mcn,
               str(mcn))
    # 脚本名按各包需要而定（官方用 prerm，本项目用 postrm），
    # 这里只要求共同必需的 control 成员存在
    check_true("control 成员含 ./control", "./control" in mcn, str(mcn))


# ---------------------------------------------------------------------------
# 5c. rpcd 后端协议（/usr/libexec/rpcd/<name> 的 list/call 机制）
# 这部分对应「RPC call to ... failed with error -32000: Object not found」那个故障，
# 必须保证：插件可执行、list 输出合法 JSON、call 按 stdin 传参并回合法 JSON。
# ---------------------------------------------------------------------------
def test_rpcd_backend():
    section("5c. rpcd 后端协议")

    plugin = os.path.join(ROOT, "root/usr/libexec/rpcd/vnt2web")
    if not os.path.exists(plugin):
        check_true("rpcd 后端存在", False, plugin)
        return
    check_true("rpcd 后端存在", True)

    # 可执行位：rpcd 只扫描可执行文件，没有执行位就不会注册 ubus 对象
    # （Windows 上该位读不回来，故检查源码里的 git 记录意义不大，
    #   这里检查打包时的 mode_map，见 test_ipk）
    src = open(plugin, encoding="utf-8").read()
    check_true("含 shebang", src.startswith("#!"), src[:20])

    # 库路径可覆盖（便于测试）
    check_true("库路径可被环境变量覆盖", "VNT_LIB_DIR" in src, "")
    # 库缺失时必须给出明确错误而不是静默
    check_true("库缺失时有明确报错", "后端组件缺失" in src, "")

    # ---- list ----
    env = dict(os.environ)
    env["VNT_LIB_DIR"] = os.path.join(ROOT, "root/usr/share/vnt2web")
    r = subprocess.run(["sh", plugin, "list"], capture_output=True, text=True, env=env)
    check_true("list 退出码 0", r.returncode == 0, r.stderr.strip())
    try:
        methods = json.loads(r.stdout)
        check_true("list 输出合法 JSON", True)
    except Exception as ex:
        check_true("list 输出合法 JSON", False, str(ex) + " | " + r.stdout[:200])
        return

    expect = ["status", "panel", "get_token", "gen_token", "set_token",
              "check_update", "update", "start", "stop", "restart",
              "logs", "clear_log", "diag", "net_test"]
    for m in expect:
        check_true("list 声明了 %s" % m, m in methods, "")

    # ---- call：必须能从 stdin 读参数 ----
    tmpd = tempfile.mkdtemp(prefix="vntrpcd")
    try:
        stub = os.path.join(tmpd, "bin")
        os.makedirs(stub)
        with open(os.path.join(stub, "uci"), "w") as f:
            f.write('#!/bin/sh\n'
                    'if [ "$1" = "-q" ] && [ "$2" = "get" ]; then\n'
                    '  k=$(echo "$3" | sed "s/[.\\-]/_/g")\n'
                    '  eval "v=\\${UCI_$k}"\n'
                    '  [ -n "$v" ] && echo "$v"\n'
                    'fi\n'
                    'if [ "$1" = "-q" ] && [ "$2" = "set" ]; then exit 0; fi\n'
                    'if [ "$1" = "-q" ] && [ "$2" = "commit" ]; then exit 0; fi\n'
                    'exit 0\n')
        os.chmod(os.path.join(stub, "uci"), 0o755)

        env2 = dict(os.environ)
        env2["PATH"] = stub + os.pathsep + env2.get("PATH", "")
        env2["VNT_LIB_DIR"] = os.path.join(ROOT, "root/usr/share/vnt2web")
        env2["VNT_ETC"] = os.path.join(tmpd, "etc")
        env2["VNT_LOG_DIR"] = os.path.join(tmpd, "log")
        env2["VNT_CACHE_DIR"] = os.path.join(tmpd, "cache")
        env2["UCI_vnt2web_main_enabled"] = "1"
        env2["UCI_vnt2web_main_bind"] = "0.0.0.0"
        env2["UCI_vnt2web_main_port"] = "19099"

        def call(method, args="{}"):
            p = subprocess.run(["sh", plugin, "call", method],
                               input=args, capture_output=True, text=True, env=env2)
            try:
                return json.loads(p.stdout), None
            except Exception as ex:
                return None, "%s | stdout=%r stderr=%r" % (ex, p.stdout[:200], p.stderr[:200])

        # 无参方法
        for m in ["status", "panel", "get_token", "diag", "stop"]:
            d, err = call(m)
            check_true("call %s 返回合法 JSON" % m, d is not None, err or "")

        # status 的关键字段与类型
        d, err = call("status")
        if d:
            check("status.bind", d.get("bind"), "0.0.0.0")
            check("status.port", d.get("port"), "19099")
            check("status.enabled 为布尔", isinstance(d.get("enabled"), bool), True)
            check("status.running 为布尔", isinstance(d.get("running"), bool), True)
            check("status.token_set 为布尔", isinstance(d.get("token_set"), bool), True)
            check("status.token_valid 为布尔", isinstance(d.get("token_valid"), bool), True)
            check("status.port_listening 为布尔",
                  isinstance(d.get("port_listening"), bool), True)
            check_true("status 含 panel_url", "panel_url" in d, str(list(d.keys())))
            check_true("status 含 instance_count", "instance_count" in d, "")
            # 不再有旧的组网参数字段
            for gone in ["network_code", "server", "device_mode"]:
                check_true("status 已不含 %s" % gone, gone not in d, "")
        else:
            check_true("status 可解析", False, err or "")

        # 令牌方法
        d, err = call("gen_token")
        if d:
            tok = d.get("token", "")
            check_true("gen_token 返回 >=16 位令牌", len(tok) >= 16,
                       "长度 %d" % len(tok))
        else:
            check_true("gen_token 可解析", False, err or "")

        d, err = call("get_token")
        if d:
            check("get_token.min_len", d.get("min_len"), 16)
            check_true("get_token 返回令牌", bool(d.get("token")), str(d))
        else:
            check_true("get_token 可解析", False, err or "")

        d, err = call("panel")
        if d:
            check_true("panel.url 含 ?token=", "?token=" in (d.get("url") or ""),
                       str(d.get("url")))
            check_true("panel.display_url 不含令牌",
                       "?token=" not in (d.get("display_url") or ""), "")
        else:
            check_true("panel 可解析", False, err or "")

        # 带参方法
        for m, a in [("logs", '{"name":"core","lines":10}'),
                     ("clear_log", '{"name":"core"}'),
                     ("set_token", '{"token":"1234567890123456"}')]:
            d, err = call(m, a)
            check_true("call %s 带参返回合法 JSON" % m, d is not None, err or "")

        # set_token 校验：过短/含空格必须被拒
        for bad, label in [('{"token":"short"}', "过短"),
                           ('{"token":"has space 1234567"}', "含空格"),
                           ('{"token":""}', "空值")]:
            d, err = call("set_token", bad)
            if d is None:
                check_true("set_token 拒绝%s且返回合法 JSON" % label, False, err or "")
            else:
                check_true("set_token 拒绝%s" % label, d.get("ok") is False, str(d))

        # 版本号注入防护
        for bad in ['{"ver":"../etc/passwd"}', '{"ver":"2.0;rm -rf /"}',
                    '{"ver":"$(id)"}']:
            d, err = call("update", bad)
            if d is None:
                check_true("update 拒绝 %s 且返回合法 JSON" % bad, False, err or "")
            else:
                check_true("update 拒绝 %s" % bad, d.get("ok") is False, str(d))

        # 未知方法也要回合法 JSON，不能崩
        d, err = call("nonexistent_method")
        check_true("未知方法返回合法 JSON", d is not None, err or "")

        # 空 stdin 不能崩
        p = subprocess.run(["sh", plugin, "call", "status"], input="",
                           capture_output=True, text=True, env=env2)
        try:
            json.loads(p.stdout)
            check_true("空 stdin 仍返回合法 JSON", True)
        except Exception as ex:
            check_true("空 stdin 仍返回合法 JSON", False, str(ex))
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


# ---------------------------------------------------------------------------
# 6. 静态检查
# ---------------------------------------------------------------------------
def test_static():
    section("6. 静态检查")

    # shell 语法
    for rel in ["root/usr/share/vnt2web/vnt.sh",
                "root/usr/share/vnt2web/vnt-core.sh",
                "root/etc/init.d/vnt2web",
                "root/etc/uci-defaults/95-vnt2web"]:
        p = os.path.join(ROOT, rel)
        r = subprocess.run(["sh", "-n", p], capture_output=True, text=True)
        check_true("sh -n %s" % rel, r.returncode == 0, r.stderr.strip())

    # JSON 合法性
    import json
    for rel in ["root/usr/share/rpcd/acl.d/luci-app-vnt2web.json",
                "root/usr/share/luci/menu.d/luci-app-vnt2web.json"]:
        try:
            json.load(open(os.path.join(ROOT, rel), encoding="utf-8"))
            check_true("JSON %s" % rel, True)
        except Exception as ex:
            check_true("JSON %s" % rel, False, str(ex))

    # 库函数引用完整性：init 脚本调用的 vnt_* 必须在库里或自身有定义
    defs = set()
    for rel in ["root/usr/share/vnt2web/vnt.sh", "root/usr/share/vnt2web/vnt-core.sh",
                "root/etc/init.d/vnt2web"]:
        src = open(os.path.join(ROOT, rel), encoding="utf-8").read()
        defs |= set(re.findall(r"^(vnt_[a-z_]+|_vnt_[a-z_]+)\(\)", src, re.M))
    init_src = open(os.path.join(ROOT, "root/etc/init.d/vnt2web"), encoding="utf-8").read()
    # 只匹配「函数调用」形式（标识符后紧跟括号），避免把注释里的
    # vnt_config 之类的词误当成函数。同时先剥掉注释行。
    init_code = re.sub(r"^[ \t]*#.*$", "", init_src, flags=re.M)
    used = set(re.findall(r"\b(vnt_[a-z_]+)\s*\(", init_code))
    missing = sorted(u for u in used if u not in defs)
    check_true("init 脚本引用的库函数均已定义", not missing, "缺: " + ", ".join(missing))

    # rpcd shell 后端引用的库函数同样要有定义
    _be = os.path.join(ROOT, "root/usr/libexec/rpcd/vnt2web")
    if os.path.exists(_be):
        be = open(_be, encoding="utf-8").read()
        be_used = set(re.findall(r"\b(vnt_[a-z_]+)\(", be))
        be_missing = sorted(u for u in be_used if u not in defs)
        check_true("rpcd 后端引用的库函数均已定义", not be_missing,
                   "缺: " + ", ".join(be_missing))
    check_true("已移除 ucode 后端",
               not os.path.exists(os.path.join(ROOT, "root/usr/share/rpcd/ucode")), "")

    # ---- 运行状态检测 ----
    # 这组断言对应两个真实故障：
    #   (a) procd 托管后没有任何地方写 PID 文件 → 永远显示「已停止」
    #   (b) 用 `pgrep -f <裸名字>` 检测进程 → 会命中检测脚本自身
    #       （rpcd 执行 /usr/libexec/rpcd/vnt2web，命令行含 "vnt2web"），
    #       导致恒真 → 「没启用却显示已启动」
    init_full = open(os.path.join(ROOT, "root/etc/init.d/vnt2web"),
                     encoding="utf-8").read()
    core_full = open(os.path.join(ROOT, "root/usr/share/vnt2web/vnt-core.sh"),
                     encoding="utf-8").read()
    lib_full = open(os.path.join(ROOT, "root/usr/share/vnt2web/vnt.sh"),
                    encoding="utf-8").read()

    check_true("init 让 procd 写 PID 文件",
               "procd_set_param pidfile" in init_full, "")
    check_true("PID 文件放 /tmp 下（不占 Flash）",
               "/tmp/vnt2web" in lib_full, "")
    check_true("检测含 PID 文件判定", "kill -0" in core_full, "")
    check_true("检测含 procd 状态判定",
               "vnt_procd_running" in core_full and "ubus call service list" in core_full, "")

    # 关键：绝不能出现 `pgrep -f "<裸名字>"` 这种自我匹配陷阱。
    # 允许 `pgrep -f /绝对/路径`（含斜杠），禁止 `pgrep -f 词`（不含斜杠）。
    # 先剥掉注释行，避免把说明文字里的示例误判成真实调用。
    core_code = re.sub(r"^[ \t]*#.*$", "", core_full, flags=re.M)
    dangerous = re.findall(r'pgrep\s+-f\s+"?\$\(basename[^"]*"?', core_code)
    dangerous += re.findall(r'pgrep\s+-f\s+"?[A-Za-z_][A-Za-z0-9_]*"?', core_code)
    check_true("无 pgrep -f 裸名字（会自我匹配）", not dangerous, str(dangerous))
    # 检测应使用 /proc/<pid>/exe 精确比对
    check_true("用 /proc/<pid>/exe 精确匹配进程",
               "/proc/$pid/exe" in core_full or "/proc/${pid}/exe" in core_full, "")
    # 存活判定不含端口（端口可能被无关进程占用）
    running_fn = core_full[core_full.index("vnt_core_running()"):]
    running_fn = running_fn[:running_fn.index("\n}\n")]
    check_true("存活判定不依赖端口监听（避免误报）",
               "vnt_port_listening" not in running_fn, "")

    # ---- 启动前清理残留实例 ----
    # 对应真实故障：残留进程占着面板端口，新进程 bind 失败即退出，
    # 表现为「点了启用但起不来」，而且状态检测发现不了（路径可能已变）。
    check_true("存在残留清理函数", "vnt_kill_stale_core()" in core_full, "")
    check_true("启动前调用残留清理",
               "vnt_kill_stale_core" in init_full, "")
    check_true("先 TERM 再 KILL", "-TERM" in core_full and "-KILL" in core_full, "")
    check_true("清理后确认端口释放",
               "仍被占用" in core_full or "仍被占用" in init_full, "")
    # 启动后观察：核心秒退时把原因写进日志
    check_true("启动后检查存活并记录失败原因",
               "核心启动后立即退出" in init_full, "")

    # ---- 端口探测的 /proc 兜底 ----
    check_true("端口探测有 /proc/net/tcp 兜底",
               "/proc/net/tcp" in lib_full, "")
    check_true("按 LISTEN 状态(0A)判断",
               '"0A"' in lib_full, "")

    # ---- 令牌：UCI 优先（否则界面改的令牌不生效）----
    gtk = lib_full[lib_full.index("vnt_get_token()"):]
    gtk = gtk[:gtk.index("\n}\n")]
    check_true("vnt_get_token 中 UCI 在文件之前",
               gtk.index("vnt_uci_get token") < gtk.index("vnt_token_file"),
               "仍是文件优先，界面改的令牌会被忽略")

    # 前端 JS：优先用 node 做真实语法检查（粗略剥离正则不可靠）
    js_path = os.path.join(ROOT, "htdocs/luci-static/resources/view/vnt2web/client.js")
    js = open(js_path, encoding="utf-8").read()
    node = shutil.which("node")
    if node:
        r = subprocess.run([node, "--check", js_path], capture_output=True, text=True)
        check_true("JS 语法（node --check）", r.returncode == 0,
                   (r.stderr or "").strip()[:200])
    else:
        # 无 node 时退化为括号配平（仅作预警，不作为通过依据）
        s = re.sub(r"//[^\n]*", "", js)
        s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
        s = re.sub(r"'(?:\\.|[^'\\])*'", "''", s)
        s = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
        print("  (无 node，跳过 JS 语法检查)")

    # 不应残留未定义的标识符
    for bad in ["view_self", "vnt_fetch_text_probe"]:
        check_true("JS 无残留 %s" % bad, bad not in js)
        uc_src2 = open(os.path.join(ROOT, "root/usr/libexec/rpcd/vnt2web"),
                       encoding="utf-8").read()
        check_true("后端无残留 %s" % bad, bad not in uc_src2)

    # 前端声明的每个 RPC 方法，后端都必须实现
    # 前端声明的每个 RPC 方法，后端都必须实现
    rpc_methods = set(re.findall(r"method:\s*'([a-z_]+)'", js))
    be_src = open(os.path.join(ROOT, "root/usr/libexec/rpcd/vnt2web"),
                  encoding="utf-8").read()
    for meth in sorted(rpc_methods):
        check_true("后端实现 %s" % meth,
                   (meth + ")") in be_src, "")

    # ---- UCI 配置名一致性（改名时最容易漏的地方）----
    # 这组断言对应一个真实故障：改名后前端仍加载旧的配置名，
    # 导致 form.Map 读不到数据，界面只剩标题与说明、字段全部不渲染。
    check_true("前端加载的配置名是 vnt2web", "uci.load('vnt2web')" in js,
               "出现 uci.load('vnt') 会导致表单无字段")
    check_true("form.Map 的配置名是 vnt2web",
               bool(re.search(r"form\.Map\(\s*'vnt2web'", js)), "")
    # 每个 NamedSection 的 sectiontype 必须是 vnt2web
    named = re.findall(r"form\.NamedSection,\s*'([^']+)',\s*'([^']+)'", js)
    check_true("存在 NamedSection 定义", len(named) > 0, "")
    for secname, sectype in named:
        check("NamedSection %s 的 type" % secname, sectype, "vnt2web")

    # 不应再有裸的 'vnt' 配置名（'vnt' 作为配置名即意味着漏改）
    stray = re.findall(r"(?:uci\.load|form\.Map)\(\s*'vnt'\s*[,)]", js)
    check_true("无残留的 'vnt' 配置名", not stray, str(stray))

    # UCI 配置文件必须定义与前端一致的节名与类型
    cfg = open(os.path.join(ROOT, "root/etc/config/vnt2web"), encoding="utf-8").read()
    m0 = re.search(r"^config\s+(\S+)\s+'(\S+)'", cfg, re.M)
    check_true("配置文件含 config 节", bool(m0), "")
    if m0:
        check("配置文件节类型", m0.group(1), "vnt2web")
        check("配置文件节名", m0.group(2), "main")


# ---------------------------------------------------------------------------
# 7. 前端重排逻辑（DOM 语义模拟）
#
# 对应真实故障：页面重排时用「某个待摘除节点的兄弟」当插入锚点，
# 摘除后该锚点成了游离节点，insertBefore 抛 NotFoundError，页面白屏。
# 这里用纯逻辑复现 DOM 的 parent/children 语义，验证重排算法。
# ---------------------------------------------------------------------------
class _Node:
    def __init__(self, name):
        self.name = name
        self.parent = None

    def __repr__(self):
        return self.name


class _Parent(_Node):
    def __init__(self, name):
        _Node.__init__(self, name)
        self.children = []

    def appendChild(self, n):
        n.parent = self
        self.children.append(n)

    def insertBefore(self, n, ref):
        # 与浏览器一致：ref 必须是本节点的子节点，否则抛错
        if ref is not None and ref.parent is not self:
            raise ValueError("NotFoundError: ref is not a child of this node")
        n.parent = self
        if ref is None:
            self.children.append(n)
        else:
            self.children.insert(self.children.index(ref), n)

    def removeChild(self, n):
        if n.parent is not self:
            raise ValueError("NotFoundError: not a child")
        self.children.remove(n)
        n.parent = None


DOM_SETTINGS = ["服务设置", "存储路径", "其它", "核心更新源"]


def _dom_build():
    """旧版（多区块）的 DOM：服务设置/核心更新源/存储路径/其它"""
    root = _Parent("map")
    for t in ["服务设置", "核心更新源", "存储路径", "其它"]:
        root.appendChild(_Parent(t))
    return root, root.children[:]


def _dom_build_single():
    """当前版（合并后）的 DOM：只有「服务设置」一个区块"""
    root = _Parent("map")
    root.appendChild(_Parent("服务设置"))
    return root, root.children[:]


def _reorder_old(root, sections):
    """旧实现：用 last.nextSibling 当锚点（会抛错）"""
    by = {s.name: s for s in sections}
    nodes = [by[t] for t in DOM_SETTINGS]
    last = nodes[-1]
    i = root.children.index(last)
    ref = root.children[i + 1] if i + 1 < len(root.children) else None
    for s in nodes:
        root.removeChild(s)
    seq = [_Node("概览")] + nodes + [_Node("访问令牌"), _Node("组网面板"), _Node("日志")]
    for n in seq:
        root.insertBefore(n, ref)


def _reorder_new(root, sections):
    """当前实现：标签页布局。
    清空 mapEl（保留 H2 标题与说明），再挂一个 wrap，内含：
      状态条 → 标签栏 → 各标签 pane
    表单 section 被「移动」进 access pane（移动而非重建，表单状态不丢）。"""
    # 记录标题/说明（保留）
    keep = [c for c in root.children
            if c.name in ("H2", "cbi-map-descr")]
    # 取走表单 section（移动到 access pane）
    access = _Parent("pane-access")
    for s in sections:
        root.removeChild(s)
        access.appendChild(s)
    # 清空后放回保留项
    for c in root.children[:]:
        root.removeChild(c)
    for k in keep:
        root.appendChild(k)
    # 挂 wrap
    wrap = _Parent("wrap")
    root.appendChild(wrap)
    # wrap 内：状态条 → 标签栏 → 四个 pane
    wrap.appendChild(_Node("状态条"))
    tabs = _Parent("tabs")
    for t in ["核心更新", "访问设置", "组网面板", "日志"]:
        tabs.appendChild(_Node("tab:" + t))
    wrap.appendChild(tabs)
    for p in ["pane-core", "pane-access", "pane-panel", "pane-logs"]:
        if p == "pane-access":
            wrap.appendChild(access)
        else:
            wrap.appendChild(_Node(p))
    return [c.name for c in root.children], [c.name for c in wrap.children]


def test_frontend_reorder():
    section("7. 前端重排逻辑（DOM 模拟）")

    # 旧实现应当抛错 —— 证明测试确实能捕获该类故障
    root, secs = _dom_build()
    old_err = None
    try:
        _reorder_old(root, secs)
    except ValueError as e:
        old_err = str(e)
    check_true("旧实现（nextSibling 锚点）会抛 NotFoundError",
               old_err is not None and "NotFoundError" in old_err,
               "未复现故障，说明模拟失真")

    # 新实现（标签页布局）应正确组装且不抛错
    root, secs = _dom_build_single()
    new_err = None
    res = None
    try:
        res = _reorder_new(root, secs)
    except ValueError as e:
        new_err = str(e)
    check_true("新实现不抛异常", new_err is None, new_err or "")

    root_order, wrap_order = res if res else ([], [])
    # mapEl 下只应保留标题（与说明）以及 wrap
    check_true("mapEl 只保留标题 + wrap",
               all(x in ("H2", "cbi-map-descr", "wrap") for x in root_order),
               str(root_order))
    check_true("wrap 已挂到 mapEl", "wrap" in root_order, str(root_order))
    # wrap 内顺序：状态条 → 标签栏 → 四个 pane
    check("wrap 内结构正确", wrap_order,
          ["状态条", "tabs", "pane-core", "pane-access", "pane-panel", "pane-logs"])
    check_true("没有遗留游离节点",
               "__placeholder__" not in root_order and
               "__placeholder__" not in wrap_order, "")

    # 源码层面检查
    js = open(os.path.join(ROOT,
              "htdocs/luci-static/resources/view/vnt2web/client.js"),
              encoding="utf-8").read()
    check_true("源码不再用 nextSibling 作插入锚点",
               "refNode = last.nextSibling" not in js, "")
    # 标签页结构
    for tab in ["'核心更新'", "'访问设置'", "'组网面板'", "'日志'"]:
        check_true("标签定义含 %s" % tab, "label: %s" % tab in js, "")
    check_true("用 .vnt-tabs 标签栏", "'class': 'vnt-tabs'" in js, "")
    check_true("有 switchTab 切换逻辑", "function switchTab" in js, "")
    # 标签显隐必须走 CSS 类，且 CSS 里有「默认隐藏」兜底 ——
    # 只用内联 style 会在框架重排/时序错开时全显示或全不显示，
    # 表现为「标签点不动，要刷新才出来」。
    check_true("CSS 定义 .vnt-pane 默认隐藏",
               ".vnt-pane { display:none; }" in js.replace("\n", " ")
               or ".vnt-pane {display:none;}" in js.replace("\n", " ")
               or "vnt-pane { display:none" in js, "")
    check_true("CSS 定义 .vnt-pane.active 显示",
               "vnt-pane.active { display:block" in js or
               "vnt-pane.active {display:block" in js, "")
    check_true("切标签用 classList.toggle",
               "classList.toggle('active', k === id)" in js, "")
    check_true("不再用内联 style 控制显隐",
               "panes[k].style.display" not in js, "")
    check_true("表单 section 被移动而非重建",
               "paneAccess.appendChild(sec)" in js, "")
    check_true("保留 H2 标题", "n.tagName === 'H2'" in js, "")
    # 卡片与配色（对齐 fnos 观感）
    check_true("卡片样式 vnt-card", ".vnt-card" in js, "")
    check_true("主色与 fnos 一致 #185fa5", "#185fa5" in js, "")
    check_true("圆角与 fnos 一致 12px", "--vnt-radius:12px" in js, "")

    # 合并为一个 section：不应再有独立的设置类区块声明
    for gone in ["'核心更新源'", "'存储路径'", "'其它'"]:
        check_true("不再有独立区块 %s" % gone,
                   "m.section(form.NamedSection, 'main', 'vnt2web', %s" % gone
                   not in js, "")
    check_true("服务设置区块仍存在",
               "m.section(form.NamedSection, 'main', 'vnt2web', '服务设置'" in js, "")
    # 令牌：只保留表单里的一个输入框，不再单独提供工具区
    check_true("令牌工具已移除（不再单独显示当前值）",
               "function buildTokenTools" not in js and
               "vnt-token-tools" not in js, "")
    check_true("令牌为普通表单项", "s1.option(form.Value, 'token'" in js, "")
    check_true("令牌带长度校验", "至少需要 16 位" in js, "")
    # 监听地址配置项应已移除
    check_true("不再有「监听地址」配置项",
               "form.ListValue, 'bind'" not in js, "")
    # DummyValue 不应挂自定义 render（它对 DummyValue 无效）
    check_true("DummyValue 不再挂自定义 render",
               "o.render = function () { return E('div', { 'id': 'vnt-net-msg' }); }"
               not in js, "")

    # ---- 菜单：放到 VPN 分类，标题 VNT2WEB ----
    menu_path = os.path.join(ROOT, "root/usr/share/luci/menu.d/luci-app-vnt2web.json")
    menu = json.load(open(menu_path, encoding="utf-8"))
    check_true("菜单挂在 admin/vpn 下", "admin/vpn/vnt2web" in menu,
               str(list(menu.keys())))
    check_true("菜单不再挂在 admin/services 下",
               not any(k.startswith("admin/services") for k in menu), "")
    if "admin/vpn/vnt2web" in menu:
        check("菜单标题为 VNT2WEB", menu["admin/vpn/vnt2web"].get("title"), "VNT2WEB")

    # ---- 连通性探测：地址须与真实下载链路一致 ----
    # 曾经的 bug：net_test 探测 api.github.com，而检查更新/下载走 github.com。
    # 结果「检查更新」成功、连通性却报失败（api.github.com 在部分网络下不通），
    # 结论误导。两者必须探测同一条链路。
    rpcd_src = open(os.path.join(ROOT, "root/usr/libexec/rpcd/vnt2web"),
                    encoding="utf-8").read()
    # 只看 m_net_test 函数体（剥掉注释行）
    ntp = rpcd_src[rpcd_src.index("m_net_test()"):]
    ntp = ntp[:ntp.index("\n}\n")]
    ntp_code = re.sub(r"^\s*#.*$", "", ntp, flags=re.M)
    check_true("连通性探测不用 api.github.com",
               "api.github.com" not in ntp_code, "该域名在部分网络下不通")
    check_true("连通性探测走 release 附件（与下载同链路）",
               "latest/download/latest.json" in ntp_code, "")
    # 库里的版本查询也用同一地址
    check_true("版本查询用同一地址",
               "releases/latest/download/latest.json" in
               open(os.path.join(ROOT, "root/usr/share/vnt2web/vnt.sh"),
                    encoding="utf-8").read(), "")
    # 失败时应给出可操作建议
    check_true("失败提示含镜像前缀建议", "镜像前缀" in ntp, "")
    check_true("不支持代理的客户端有专门提示",
               "不支持 SOCKS 代理" in ntp, "")

    # ---- 「最新版本」这一行必须被更新 ----
    # 曾经的 bug：handleCheck 只改按钮文字与 ST.latest，从没写 #vnt-latest，
    # 于是该行永远停在「未检查」。
    hc = js[js.index("handleCheck: function"):]
    hc = hc[:hc.index("\n\t},")]
    check_true("handleCheck 会写 #vnt-latest", "vnt-latest" in hc, "")
    check_true("查询失败时该行显示失败",
               "查询失败" in hc, "")

    # ---- 「测试连通性」按钮不用 form.Button（会跑到最左并独占一行）----
    # ---- 「测试连通性」按钮：位置在「核心更新」标签的按钮行里 ----
    check_true("测试按钮不用 form.Button",
               "form.Button" not in re.sub(r"^\s*//.*$", "", js, flags=re.M), "")
    # 它应与「检查更新 / 更新核心」同在一个按钮行（buildOverview 的 btns）
    ov = js[js.index("function buildOverview"):]
    ov = ov[:ov.index("\nfunction ")]
    check_true("测试按钮在核心更新的按钮行", "'handleNetTest'" in ov, "")
    check_true("按钮行含检查更新", "'handleCheck'" in ov, "")
    check_true("按钮行含更新核心", "'handleUpdate'" in ov, "")
    # 结果提示容器也在该卡片内（handleNetTest 按 id 查找）
    check_true("结果容器 vnt-net-msg 在核心更新卡片",
               "vnt-net-msg" in ov, "")
    # 不再残留在「访问设置」的表单里
    check_true("访问设置里已无测试按钮占位",
               "vnt-nettest-box" not in js and "buildNetTest" not in js, "")


# ---------------------------------------------------------------------------
def main():
    tmpd = tempfile.mkdtemp(prefix="vnttest")
    os.environ["TMPD"] = tmpd
    try:
        test_arch()
        test_version()
        test_vercmp()
        test_token_and_addr()
        test_ipk()
        test_rpcd_backend()
        test_against_official()
        test_static()
        test_frontend_reorder()
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)

    section("结果")
    print("通过: %d" % PASS)
    print("失败: %d" % FAIL)
    if FAILED:
        print("\n失败明细:")
        for f in FAILED:
            print("  - " + f)
    print()
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

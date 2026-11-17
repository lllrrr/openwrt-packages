#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""免 SDK 的 ipk 组装器。

ipk 结构（OpenWrt 的 opkg 包）：**外层是 gzip 压缩的 tar**，里面三个成员：

    外层 gzip(tar)
    ├── ./debian-binary    内容固定为 "2.0\\n"
    ├── ./control.tar.gz   包元数据：control 文件 + 可选 postinst/postrm
    └── ./data.tar.gz      实际安装的文件树

务必注意：外层容器是 **tar+gzip**，不是 ar。
ar 是 Debian .deb 的容器格式，opkg 不认，用 ar 打包会得到
`pkg_init_from_file: Malformed package file`。
自检方式：`tar tzf xxx.ipk` 应能列出上述三个成员。

内层两个压缩包的细节（参考官方 ipkg-build）：
  1) tar 用 --numeric-owner，uid/gid 统一为 0，避免把当前用户名写进去
     导致跨环境重建产物不一致。
  2) 成员名前带 `./` 前缀，与官方产物一致，个别老版本 opkg 依赖这个形式。

不依赖 opkg-utils / tar / ar 等外部命令，纯 Python 实现，Windows 上也能出包。
"""

import gzip
import io
import os
import struct
import sys
import tarfile
import time

DEBIAN_BINARY = b"2.0\n"
DEFAULT_MTIME = 1700000000  # 固定时间戳，保证可复现构建


# ---------------------------------------------------------------------------
# tar.gz
# ---------------------------------------------------------------------------
def _add_tree(tf, root, arc_prefix="", mode_map=None):
    """把 root 目录下的内容按相对路径加入 tarfile。

    mode_map: {归档相对路径: 权限} —— 显式指定每个文件的权限。
              必须显式指定，不能依赖源文件的权限位：Windows 上
              os.chmod 设置的可执行位读不回来（os.stat 恒为 0o666/0o777 的
              Windows 语义），会导致 init 脚本装上去没有可执行权限，
              OpenWrt 直接拒绝启动服务。
    """
    mode_map = mode_map or {}
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if arc_prefix:
                rel = arc_prefix.rstrip("/") + "/" + rel
            entries.append((rel, full))
        if not filenames and not dirnames:
            rel = os.path.relpath(dirpath, root).replace(os.sep, "/")
            if rel != ".":
                entries.append((rel + "/", None))

    # 目录条目（含所有中间目录），保证安装后目录结构完整
    dirs = set()
    for rel, _ in entries:
        parts = rel.rstrip("/").split("/")
        for i in range(1, len(parts)):
            dirs.add("/".join(parts[:i]))

    _add_root_entry(tf)
    for d in sorted(dirs):
        ti = tarfile.TarInfo(name="./" + d)
        ti.type = tarfile.DIRTYPE
        ti.mode = 0o755
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = DEFAULT_MTIME
        tf.addfile(ti)

    for rel, full in sorted(entries):
        if full is None:
            ti = tarfile.TarInfo(name="./" + rel.rstrip("/"))
            ti.type = tarfile.DIRTYPE
            ti.mode = 0o755
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = DEFAULT_MTIME
            tf.addfile(ti)
            continue
        with open(full, "rb") as f:
            data = f.read()
        ti = tarfile.TarInfo(name="./" + rel)
        ti.size = len(data)
        ti.mtime = DEFAULT_MTIME
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        # 优先用显式权限表，未列出时按 644
        ti.mode = mode_map.get(rel, 0o644)
        tf.addfile(ti, io.BytesIO(data))


def make_tar_gz(root, arc_prefix="", mode_map=None):
    """把 root 打包成 data.tar.gz 的字节串。"""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        _add_tree(tf, root, arc_prefix, mode_map)
    raw.seek(0)
    out = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0, compresslevel=9) as gz:
        gz.write(raw.getvalue())
    return out.getvalue()


def make_tar_gz_from_bytes(files):
    """files: {归档路径: (内容bytes, 模式)}，用于生成 control.tar.gz。

    成员名统一加 `./` 前缀 —— 与官方 ipkg-build 产物一致
    （官方内层同样形如 ./control、./postinst）。
    """
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        _add_root_entry(tf)
        for name in sorted(files):
            content, mode = files[name]
            ti = tarfile.TarInfo(name="./" + name.lstrip("./"))
            ti.size = len(content)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = DEFAULT_MTIME
            tf.addfile(ti, io.BytesIO(content))
    raw.seek(0)
    out = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0, compresslevel=9) as gz:
        gz.write(raw.getvalue())
    return out.getvalue()


def _add_root_entry(tf):
    """加一条 "." 根目录条目，与官方产物一致。"""
    ti = tarfile.TarInfo(name=".")
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = DEFAULT_MTIME
    tf.addfile(ti)


# ---------------------------------------------------------------------------
# 外层容器：gzip 压缩的 tar（不是 ar！）
# ---------------------------------------------------------------------------
def make_ipk_container(members):
    """members: [(名字, 内容bytes), ...] -> ipk 字节串。

    关键：OpenWrt 的 ipk 外层是 **gzip 压缩的 tar**，不是 ar。
    ar 是 Debian .deb 的容器格式，opkg 完全不认——
    用 ar 打包会得到 `Malformed package file` 并拒绝安装。

    官方 ipkg-build 的写法是：
        ( cd $tmp_dir && $TAR --format=gnu -cf - ./debian-binary \
            ./data.tar.gz ./control.tar.gz | gzip -n - > "$pkg_file" )
    即条目名前带 `./` 前缀，三层成员，整体 gzip。

    验证方式：`tar tzf xxx.ipk` 应能列出
        ./debian-binary  ./data.tar.gz  ./control.tar.gz
    """
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for name, data in members:
            # 官方用 ./ 前缀，这里保持一致
            ti = tarfile.TarInfo(name="./" + name)
            ti.size = len(data)
            ti.mode = 0o644
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = DEFAULT_MTIME
            tf.addfile(ti, io.BytesIO(data))
    raw.seek(0)
    out = io.BytesIO()
    # mtime=0 让 gzip 头可复现
    with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0, compresslevel=9) as gz:
        gz.write(raw.getvalue())
    return out.getvalue()


# ---------------------------------------------------------------------------
# 组装 ipk
# ---------------------------------------------------------------------------
def build_ipk(stage_dir, control_fields, out_path, scripts=None, conffiles=None,
              mode_map=None):
    """stage_dir 是 data 树根；control_fields 是 control 文件的键值。

    scripts: {'postinst': '...', 'prerm': '...'} 等（内容是 shell 文本）
    conffiles: 配置文件路径列表，写入 control/conffiles
    mode_map: {相对路径: 权限}，显式指定安装后的权限。
              键是相对 stage_dir 的路径（如 "etc/init.d/vnt"）。
              必须提供，否则可执行文件会丢掉执行位。
    """
    mode_map = mode_map or {}
    control_dir = os.path.join(stage_dir, ".control")
    os.makedirs(control_dir, exist_ok=True)

    # control 文件
    lines = []
    order = [
        "Package", "Version", "Depends", "Recommends", "Suggests",
        "Section", "Category", "Priority", "Architecture", "Installed-Size",
        "Maintainer", "Source", "License", "Description"
    ]
    for k in order:
        if k in control_fields and control_fields[k] != "":
            lines.append("%s: %s" % (k, control_fields[k]))
    # 其余键按字母序补充
    for k in sorted(control_fields):
        if k not in order and control_fields[k] != "":
            lines.append("%s: %s" % (k, control_fields[k]))
    control_txt = ("\n".join(lines) + "\n").encode("utf-8")

    files = {"control": (control_txt, 0o644)}
    if conffiles:
        cf = ("\n".join(sorted(conffiles)) + "\n").encode("utf-8")
        files["conffiles"] = (cf, 0o644)
    if scripts:
        for name, body in scripts.items():
            if not body:
                continue
            if not body.startswith("#!"):
                body = "#!/bin/sh\n" + body
            files[name] = (body.encode("utf-8"), 0o755)

    control_tar = make_tar_gz_from_bytes(files)

    # data 树：排除 .control
    tmp_data = os.path.join(stage_dir, ".data_tmp")
    if os.path.exists(tmp_data):
        import shutil
        shutil.rmtree(tmp_data)
    os.makedirs(tmp_data)
    import shutil
    for name in sorted(os.listdir(stage_dir)):
        if name.startswith(".control") or name.startswith(".data_tmp"):
            continue
        src = os.path.join(stage_dir, name)
        dst = os.path.join(tmp_data, name)
        if os.path.isdir(src):
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)
    data_tar = make_tar_gz(tmp_data, mode_map=mode_map)

    # Installed-Size 用 data.tar.gz 的大小（opkg 惯例）
    size_kb = (len(data_tar) + 1023) // 1024
    control_txt = control_txt.replace(
        b"Installed-Size: 0",
        b"Installed-Size: %d" % size_kb
    )
    files["control"] = (control_txt, 0o644)
    control_tar = make_tar_gz_from_bytes(files)

    # 成员顺序与官方 ipkg-build 一致：debian-binary -> data -> control
    # （官方写法：tar -cf - ./debian-binary ./data.tar.gz ./control.tar.gz）
    ipk = make_ipk_container([
        ("debian-binary", DEBIAN_BINARY),
        ("data.tar.gz", data_tar),
        ("control.tar.gz", control_tar),
    ])

    with open(out_path, "wb") as f:
        f.write(ipk)

    shutil.rmtree(tmp_data, ignore_errors=True)
    shutil.rmtree(control_dir, ignore_errors=True)
    return out_path


if __name__ == "__main__":
    print("这是库模块，请用 scripts/build-ipk.sh 调用。", file=sys.stderr)
    sys.exit(1)

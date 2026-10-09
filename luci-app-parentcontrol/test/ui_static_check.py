#!/usr/bin/env python3
"""UI 静态结构检查（W37 / W38 / W39 / W42-静态）。

主机上没有 lua，无法行为级执行 LuCI 页面 —— 这里用 python 扫 Lua/HTML 源码，
把设计稿（pc-acceptance-design.md A35/A36/A37/A40）承诺的 UI 行为钉成结构断言。

诚实声明：这是**静态检查、非行为级**。它保证「实现该行为的构造存在且没有退化成
已知坏形态」，不能替代运行时行为验证；行为级验收由真机黑盒 B10/B11/B16 承担。

用法：python3 test/ui_static_check.py <repo-root>
"""
import glob
import os
import re
import sys

REPO = sys.argv[1] if len(sys.argv) > 1 else "."
problems = []


def check(desc, cond, detail=""):
    if cond:
        print("  ok   %s" % desc)
    else:
        print("  FAIL %s" % desc)
        if detail:
            print("       %s" % detail)
        problems.append(desc)


def src(rel):
    path = os.path.join(REPO, rel)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def strip_lua(text):
    """去掉 Lua 行注释（复审 S2：注释里出现目标串不应让检查通过）。"""
    return re.sub(r"--[^\n]*", "", text)


def strip_shell(text):
    """去掉 shell 整行注释（同上；不动行内 #，避免误伤字符串）。"""
    return re.sub(r"^[ \t]*#[^\n]*", "", text, flags=re.M)


def slice_between(text, start, end):
    i = text.find(start)
    if i < 0:
        return ""
    j = text.find(end, i + len(start))
    return text[i:j] if j > i else text[i:]


def w37():
    print("== W37 (A35)：列表摘要格式化 —— 静态结构检查（非行为级）==")
    s = src("luasrc/model/cbi/parentcontrol/ui.lua")
    check("ui.lua（列表页渲染助手）存在", s is not None)
    if s is None:
        return
    t = strip_lua(s)
    # 今日额度：只钉语义哨兵（"-" / 「不限」/ 「分钟」/ format 串），不钉变量名与整句写法
    check("今日额度：条目不存在 → \"-\"（哨兵）", 'return "-"' in t)
    check("今日额度：勾不限 → 「不限」", 'translate("不限")' in t)
    check("今日额度：格式「已用 / 额度 分钟」",
          'string.format("%d / %d %s"' in t and 'translate("分钟")' in t)
    check("今日额度：额度 0 → 「已用 / 0 分钟」（全禁照实显示）", '"%d / 0 %s"' in t)
    # 档案摘要：两档案相同只写一次 / 全天不写 / 秒不写
    check("档案摘要：两档案相同只写一次（同值比较判定）", "sd == hd" in t)
    check("档案摘要：相同时的紧凑标记「两档案相同」", "两档案相同" in t)
    check("档案摘要：全天时段（00:00:00-23:59:59）不显示",
          re.search(r'\w+ == "00:00:00" and \w+ == "23:59:59"', t) is not None)
    check("档案摘要：秒不写（取 HH:MM）", t.count(":sub(1, 5)") >= 2)
    check("档案摘要：平日/节假日两套各自标注", "平日" in t and "节假日" in t)
    # 设备列：MAC（设备名）—— 只钉全角括号哨兵，不钉变量名/拼接写法
    check("设备列：MAC（设备名）全角括号拼接", '" （"' in t and '"）"' in t)
    check("设备列：没填设备 → 「全部客户端」", "全部客户端" in t)


def w38():
    print("== W38 (A36)：编辑页「起必须早于止」校验 —— 静态结构检查（非行为级）==")
    s = src("luasrc/model/cbi/parentcontrol/parts.lua")
    check("parts.lua（档案字段 + 校验）存在", s is not None)
    if s is None:
        return
    body = strip_lua(slice_between(s, "function M.validate_window", "function M.add_profile"))
    check("validate_window 函数存在且有函数体", len(body) > 50)
    check("校验同时挂到 起(qstart) 与 止(qend) 两个字段上",
          s.count("s.validate = M.validate_window")
          + s.count("e.validate = M.validate_window") >= 2)
    # 与「另一个字段」比，而不是自己和自己比
    check("起 ↔ 止 互相映射（gsub 到对方字段名）",
          'gsub("_qstart$"' in body and 'gsub("_qend$"' in body)
    # 历史缺陷：来回 gsub 会转回自己 → a>=b 恒真 → 每个合法的「起」都被判错。
    # 结构上禁止链式 gsub（gsub(...):gsub(...) 形状）。
    check("禁止「自己和自己比」的链式 gsub 写法", "):gsub(" not in body)
    check("起=止 / 起>止 都判错（is_start and a >= b）", "is_start and a >= b" in body)
    check("反方向同样判错（not is_start and b >= a）", "not is_start and b >= a" in body)
    # 编辑页前端的即时软提示也要用 >=（只提示不拦提交，后端另有兜底）
    h = src("luasrc/view/parentcontrol/edit.htm") or ""
    check("edit.htm 前端软提示用 a >= b 判定", "if (a >= b)" in h)
    # B16（真机 500）防线：submitted() 必须从 self.section 的 .section 属性取 uci 名字，
    # 不得把 AbstractSection 对象直接喂给 string.format（Lua 5.1 %s 不做 tostring → 500）。
    sub = strip_lua(slice_between(s, "local function submitted", "function M.validate_window"))
    check("submitted 函数存在且有函数体", len(sub) > 20)
    check("submitted 从 self.section.section 取 uci 名字（不直接 format 对象）",
          "self.section.section" in sub
          and 'format(self.map.config, self.section,' not in sub)


def w39():
    print("== W39 (A37)：使用限额页 —— 静态结构检查（非行为级）==")
    raw_q = src("luasrc/model/cbi/parentcontrol/quota.lua")
    check("quota.lua（使用限额页）存在", raw_q is not None)
    if raw_q is None:
        return
    q = strip_lua(raw_q)
    check("页面标题「使用限额」", 'Map("parentcontrol", translate("使用限额")' in q)
    check("含共享额度池 TypedSection（quota）",
          'TypedSection, "quota"' in q and "共享额度池" in q)
    check("含寒暑假区间 TypedSection（vacation）",
          'TypedSection, "vacation"' in q and "寒暑假区间" in q)
    for f in ('"name"', '"sd_quota"', '"hd_quota"'):
        check("池字段 %s 存在" % f, f in q)
    for f in ('"start"', '"end"'):
        check("寒暑假字段 %s 存在" % f, f in q)
    # 字段名与 shell 侧读取一致（逐字对上）
    c = strip_shell(src("root/usr/lib/parentcontrol/common.sh") or "")
    check("shell 侧按 <sfx>_quota 读池额度（与 UI 的 sd_quota/hd_quota 一致）",
          "@quota[$_i].${_sfx}_quota" in c)
    check("shell 侧按 @vacation[].start/.end 读区间（与 UI 一致）",
          "@vacation[$_i].start" in c and "@vacation[$_i].end" in c)
    k = src("luasrc/controller/parentcontrol.lua") or ""
    check("菜单入口：admin/control/parentcontrol/quota", 'cbi("parentcontrol/quota")' in k)


def w42():
    print("== W42-静态 (A40)：UI 无 时间限制/协议过滤 入口 —— 静态检查（非行为级）==")
    ctrl = strip_lua(src("luasrc/controller/parentcontrol.lua") or "")
    check("controller 存在", ctrl != "")
    # 正向对照：仍在的三个入口必须找得到（证明扫的是真文件、检查真的在跑）
    for p in ('cbi("parentcontrol/weburl")', 'cbi("parentcontrol/quota")',
              'cbi("parentcontrol/stats")'):
        check("正向对照：入口 %s 仍在" % p.split('"')[1], p in ctrl)
    check("无 time 页面入口", '"parentcontrol/time"' not in ctrl)
    check("无 protocol 页面入口", '"parentcontrol/protocol"' not in ctrl)
    check("无「时间限制」菜单文案", "时间限制" not in ctrl)
    check("无「协议过滤」菜单文案", "协议过滤" not in ctrl)
    models = glob.glob(os.path.join(REPO, "luasrc/model/cbi/parentcontrol/*.lua"))
    bad = [p for p in models if os.path.basename(p) in ("time.lua", "protocol.lua")]
    check("无 time.lua / protocol.lua 模型文件", not bad, str(bad))
    hits = []
    luadir = os.path.join(REPO, "luasrc")
    for root, _dirs, files in os.walk(luadir):
        for fn in files:
            p = os.path.join(root, fn)
            with open(p, encoding="utf-8", errors="replace") as fh:
                t = fh.read()
            if fn.endswith(".lua"):
                t = strip_lua(t)
            if "parentcontrol/time" in t or "parentcontrol/protocol" in t:
                hits.append(os.path.relpath(p, REPO))
    check("luasrc 无任何对已移除页面的引用", not hits, str(hits))


def main():
    print("（静态结构检查：主机无 lua，非行为级；行为级由真机 B10/B11/B16 覆盖）")
    w37()
    w38()
    w39()
    w42()
    if problems:
        print("\nUI 静态检查：%d 处不符" % len(problems))
        return 1
    print("\nUI 静态检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())

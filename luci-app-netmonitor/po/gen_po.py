#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 luci-app-netmonitor 的 po 模板与中文翻译文件。

用法：python3 po/gen_po.py
输出：po/templates/luci-app-netmonitor.pot
      po/zh_Hans/luci-app-netmonitor.po

说明：
  * 本脚本从 htdocs 下的 JS 源码与 menu.d JSON 中提取 _('...') 字面量，
    与下面的译文字典合并后输出，避免手工维护时漏翻。
  * 未收录的字符串会以空 msgstr 输出并打印告警，方便补齐。
"""

import io
import os
import re
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(BASE, 'htdocs', 'luci-static', 'resources')
MENU = os.path.join(BASE, 'root', 'usr', 'share', 'luci', 'menu.d', 'luci-app-netmonitor.json')
UCODE = os.path.join(BASE, 'root', 'usr', 'share', 'rpcd', 'ucode', 'luci.netmonitor')
COMMON_JS = os.path.join(RES, 'netmonitor', 'common.js')

DOMAIN = 'luci-app-netmonitor'

# 中文映射表。msgid 必须是「插件独有」的英文原文，原因见下。
#
# 核心语言包覆盖规则（实机实测，2026-09 于 ImmortalWrt + aurora 主题）：
#   LuCI 把核心 base.zh-cn.lmo 与插件语言包一起加载，同名 msgid 上**核心覆盖插件**，
#   插件自己写的那条被静默丢弃、没有任何提示。实测该规则的方式：核心 lmo 只存哈希，
#   用 sfh_hash(本插件 msgid) 去查核心索引，命中即冲突。
#   踩过的具体例子：目标管理页表头 _('Label') 本插件译「标签」，
#   设备上显示「卷标」——那正是核心 "Label" 的译文（核心用它指分区卷标）。
#
# 因此新增文案时遵守两条：
#   1) 含义有歧义的通用词（Label / Status / Total 之类）不要直接用，
#      换成插件语境明确的说法（表头用 'Custom label' 而不是 'Label'）；
#   2) 已被核心占用、但核心译文在本插件语境下同样可用的（如 Interval / Enabled），
#      本表取值直接对齐核心，保证「无论哪条生效，界面都是同一个词」。
# 冲突面用工作区的 _audit_i18n_collide.py 复查（需要设备上的 base.zh-cn.lmo）。
ZH = {
    # 菜单
    'Network Monitor': '网络质量监控',
    'Overview': '概览',
    'Realtime': '实时监控',
    'Latency Charts': '延迟曲线',
    'CN / Global': '国内 / 国外',
    'History': '历史数据',
    'Targets': '目标管理',
    'Settings': '设置',

    # 通用 / 状态
    'Never checked': '从未检测',
    'Just now': '刚刚',
    'China': '国内',
    'Overseas': '国外',
    'Other': '其他',
    'Timeout': '超时',
    'DNS resolve failed': 'DNS 解析失败',
    'Network unreachable': '网络不可达',
    'Invalid target': '目标无效',
    'Check failed': '检测失败',
    'Avg': '平均',
    'Average': '平均',
    'P50': 'P50',
    'P95': 'P95',
    'Loss': '丢包',
    'Availability': '在线率',
    'Current': '当前',
    'Max': '最大',
    'Min': '最小',
    'Range': '范围',
    'Online': '在线',
    'Abnormal': '异常',
    'Failed': '失败',
    'Disabled': '已禁用',
    'Total': '总数',
    'Samples': '样本数',
    'Statistics': '统计',
    'Updated': '更新时间',
    'Interval': '间隔',
    'UI refresh': '界面刷新',
    'Actions': '操作',

    # 等级
    'Excellent': '优秀',
    'Good': '良好',
    'Fair': '一般',
    'Poor': '较差',
    'Severe': '严重',
    'Offline': '离线',
    'Unknown': '未知',

    # 相对时间
    '%d seconds ago': '%d 秒前',
    '%d minutes ago': '%d 分钟前',
    '%d hours ago': '%d 小时前',
    '%d days ago': '%d 天前',

    # 时间范围
    '1 min': '最近 1 分钟',
    '5 min': '最近 5 分钟',
    '15 min': '最近 15 分钟',
    '30 min': '最近 30 分钟',
    '1 hour': '最近 1 小时',
    '6 hours': '最近 6 小时',
    '12 hours': '最近 12 小时',
    '24 hours': '最近 24 小时',
    '3 days': '最近 3 天',
    '7 days': '最近 7 天',
    '30 days': '最近 30 天',

    # 总览
    'No monitoring data': '暂无监控数据',
    'Add and enable monitoring targets to start collecting data.': '请添加并启用监控目标以开始采集数据。',
    'Network is healthy': '网络正常',
    'All monitored targets respond normally.': '所有监控目标响应正常。',
    'Network problems detected': '网络存在异常',
    'Some targets are unreachable or unstable.': '部分目标不可达或不稳定。',
    'Serious network failure': '网络严重故障',
    'One or more targets failed consecutively beyond the threshold.': '一个或多个目标连续失败次数已超过阈值。',
    'Current latency': '当前延迟',
    'Packet loss': '丢包率',
    'Background service is not running. Monitoring is stopped.': '后台服务未运行，监控已停止。',
    'Background service did not update data recently. Check the service status.': '后台服务近期未更新数据，请检查服务状态。',
    'No enabled targets. Go to Targets to add one.': '没有已启用的目标，请到「目标管理」添加。',
    'Average latency': '平均延迟',
    'Across enabled targets': '所有已启用目标的平均值',
    'Latest probe round': '最近一次检测结果',
    'Weighted by samples': '按样本加权',
    'China network': '国内网络',
    'Overseas network': '国外网络',
    'Online targets': '在线目标',
    'Target count': '目标数',
    'No targets configured': '尚未配置监控目标',
    'Service running': '服务运行中',
    'Service stopped': '服务已停止',
    'Last update': '最后更新',
    'Operation completed': '操作已完成',
    'Start': '启动',
    'Stop': '停止',
    'Restart': '重启',

    # 动态 SVG 图标卡片
    'Success rate': '成功率',
    'Probe settings': '探测设置',
    'Check interval': '检测间隔',
    'Probe timeout': '探测超时',
    'Data source': '数据来源',
    'In-memory ring buffer': '内存环形缓存',
    'Retention': '保留期',
    'Dual stack': '双协议栈',
    'Address family': '地址族',
    'Live sampling': '实时采样',
    'Selected targets': '已选目标',
    'Master switch': '总开关',
    'Reserved': '预留',
    'UI refresh interval': '界面刷新间隔',
    'Independent from the probe interval': '与探测间隔相互独立',
    'The table scrolls horizontally on small screens.': '小屏幕下表格可横向滚动。',

    # 实时监控
    'All regions': '所有区域',
    'All status': '所有状态',
    'Region': '区域',
    'Status': '状态',
    'Search name or address': '搜索名称或地址',
    'Search': '搜索',
    'Pause': '暂停',
    'Resume': '继续',
    'Name': '名称',
    'Address': '地址',
    'Fails': '连续失败',
    'Last check': '最后检测',
    'No matching targets': '没有匹配的目标',

    # 曲线
    'Time range': '时间范围',
    'All targets': '所有目标',
    'Quick filter': '快速筛选',
    'No target selected': '未选择目标',
    'Data source: persistent history on flash': '数据来源：Flash 持久化历史',
    'Data source: in-memory ring buffer': '数据来源：内存环形缓存',
    'Latency trend': '延迟趋势',
    'No data in this range': '该时间范围内没有数据',
    'Target': '目标',
    'Query': '查询',
    'History persistence is disabled. Ranges longer than the in-memory buffer may have no data.':
        '历史持久化未启用，超出内存缓存范围的时间段可能没有数据。',

    # 区域
    'Region latency comparison': '区域延迟对比',
    'No targets': '暂无目标',

    # 设置
    'Checking...': '正在检查…',
    'Clear all collected samples and persistent history': '清空所有已采集样本与持久化历史',
    'Clear history': '清空历史',
    'Clear all collected history data?': '确定清空所有历史数据？',
    'History cleared': '历史数据已清空',
    'Global settings': '全局设置',
    'Detection': '检测设置',
    'Enable monitoring': '启用监控',
    'Master switch. When disabled the background daemon stops probing.': '总开关。关闭后后台服务停止探测。',
    'Check interval (seconds)': '检测间隔（秒）',
    'Recommended values: 1, 5, 10, 15, 30, 60, 120, 300. Allowed range 1-3600.':
        '推荐值：1、5、10、15、30、60、120、300。允许范围 1-3600。',
    'Probe timeout (seconds)': 'Ping 超时（秒）',
    'Per-packet wait time before a probe is considered lost.': '单个探测包的等待时间，超时即判定为丢包。',
    'Packets per probe': '每次检测发包数',
    'Higher values give better loss statistics but cost more time.': '数值越大丢包统计越准，但耗时更长。',
    'Concurrent probes': '并发检测数量',
    'Maximum number of targets probed in parallel.': '同时进行探测的目标数量上限。',
    'Auto': '自动',
    'IPv4 only': '仅 IPv4',
    'IPv6 only': '仅 IPv6',
    'Outbound interface (optional)': '出口接口（可选）',
    'Example: wan, wwan. Leave empty to use the system default route.':
        '例如 wan、wwan。留空则使用系统默认路由。',
    'auto': '自动',
    'Source address (optional)': '源地址（可选）',
    'Bind probes to a specific source IP address.': '将探测绑定到指定的源 IP 地址。',
    'Data retention': '数据保留',
    'Persistent history': '历史持久化',
    'Write aggregated samples to flash periodically. Disabled by default to protect flash lifetime.':
        '定期将聚合数据写入 Flash。默认关闭以保护 Flash 寿命。',
    'History retention': '历史保留时间',
    'Flush interval (seconds)': '落盘间隔（秒）',
    'How often aggregated data is written to flash. Larger values mean fewer writes.':
        '聚合数据写入 Flash 的频率，数值越大写入次数越少。',
    'In-memory samples per target': '每目标内存采样点数',
    'Ring buffer size in /tmp. 4320 samples at 10s interval covers about 12 hours.':
        '/tmp 中环形缓存的大小。10 秒间隔下 4320 点约覆盖 12 小时。',
    'Thresholds': '阈值',
    'Excellent below (ms)': '优秀（低于，毫秒）',
    'Good below (ms)': '良好（低于，毫秒）',
    'Fair below (ms)': '一般（低于，毫秒）',
    'Poor below (ms)': '较差（低于，毫秒）',
    'Loss warning (%)': '丢包告警阈值（%）',
    'Loss critical (%)': '丢包严重阈值（%）',
    'Consecutive failures to warn': '连续失败告警阈值',
    'Consecutive failures to critical': '连续失败严重阈值',
    'Interface & logging': '界面与日志',
    'UI refresh interval (seconds)': '界面刷新间隔（秒）',
    'How often the page fetches new state. Independent from the probe interval.':
        '页面获取最新状态的频率，与检测间隔相互独立。',
    'Log level': '日志级别',
    'Normal probes are never logged. Only state changes and failures produce log entries.':
        '正常探测不写日志，只在状态变化和失败时记录。',
    'Debug': '调试',
    'Info': '信息',
    'Warning': '警告',
    'Error': '错误',
    'Notification (reserved)': '通知（预留）',
    'Enable notification': '启用通知',
    'Interface is reserved for future webhook / Telegram / WeCom / DingTalk / mail support.':
        '接口预留，后续可扩展 Webhook、Telegram、企业微信、钉钉、邮件等方式。',
    'Notification endpoint': '通知地址',
    'Reserved. Leave empty until a notification backend is available.':
        '预留项，在通知后端可用之前请留空。',

    # 目标管理
    'Add target': '新增目标',
    'Enable selected': '批量启用',
    'Disable selected': '批量禁用',
    'Refresh': '刷新',
    'Global interval': '全局间隔',
    'Family': '地址族',
    'Interface': '接口',
    'Enabled': '已启用',
    'Interval and timeout set to 0 inherit the global settings.': '间隔与超时填 0 表示继承全局设置。',
    'IPv4': 'IPv4',
    'IPv6': 'IPv6',
    'IPv4 + IPv6': 'IPv4 + IPv6',
    'Global': '跟随全局',
    'Edit': '编辑',
    'Copy': '复制',
    'Delete': '删除',
    'Delete this target?': '确定删除该目标？',
    'Edit target': '编辑目标',
    'Custom label': '自定义标签',
    'Check interval (s, 0 = global)': '检测间隔（秒，0 = 跟随全局）',
    'Timeout (s, 0 = global)': '超时（秒，0 = 跟随全局）',
    'Interface (optional)': '接口（可选）',
    'Remark': '备注',
    'Cancel': '取消',
    'Save': '保存',
    'Name and address are required': '名称与地址为必填项',
    'Saved': '已保存',
    'No changes to save': '没有需要保存的改动',

    # ---------------------------------------------------------- TCP 探测
    # 目标级与全局级的探测方式选择（2026-09-15 新增）
    'Default probe method': '默认探测方式',
    'Probe method': '探测方式',
    'ICMP (ping)': 'ICMP（ping）',
    'TCP connect': 'TCP 连接',
    'How the background daemon probes every target.': '后台守护进程对每个目标使用的探测方式。',
    'ICMP echo (ping) by default. TCP connect measures the TCP handshake time to a port and still works on networks that drop ICMP. A target can override this.':
        '默认使用 ICMP echo（ping）。TCP 连接方式测量到指定端口的 TCP 握手耗时，在被丢弃 ICMP 的网络里依然可用。单个目标可单独覆盖此项。',
    'Default TCP port': '默认 TCP 端口',
    'Used by TCP targets that do not specify a port of their own. Allowed range 1-65535.':
        '供未单独指定端口的目标使用，允许范围 1-65535。',
    'TCP port (0 = global default)': 'TCP 端口（0 = 跟随全局默认）',
    'Not used by ICMP': 'ICMP 不使用端口',
    'global default port': '跟随全局默认端口',
    'TCP targets need a port or a global default port': 'TCP 目标需要填写端口，或先设置一个全局默认端口',
    'Handshake timing to port': '到端口的握手耗时',
    'Echo request / reply': '回显请求 / 应答',
    'ICMP only. Higher values give better loss statistics but cost more time. TCP always performs a single connect.':
        '仅对 ICMP 有效。数值越大丢包统计越准，但耗时更长；TCP 方式固定只建立一次连接。',
    'Which protocol family the probes use. A target can override this.': '探测使用的协议族，单个目标可单独覆盖。',

    # ---------------------------------------------------------- 设置页改写
    'Where samples are kept and how long they survive.': '采样数据的存放位置与保留时长。',
    'How long aggregated samples are kept on flash when persistence is enabled.':
        '开启持久化后，聚合数据在 Flash 上的保留时长。',
    'Values used to turn raw measurements into a quality grade.': '把原始测量值换算为质量等级所用的阈值。',
    'Latency below this value is graded Excellent.': '延迟低于该值判为「优秀」。',
    'Latency below this value is graded Good.': '延迟低于该值判为「良好」。',
    'Latency below this value is graded Fair.': '延迟低于该值判为「一般」。',
    'Latency at or above this value is graded Severe.': '延迟达到或超过该值判为「严重」。',
    'Packet loss at or above this percentage is considered a warning.': '丢包率达到或超过该百分比时视为告警。',
    'Packet loss at or above this percentage is considered critical.': '丢包率达到或超过该百分比时视为严重。',
    'After this many consecutive failures the target is graded Severe.':
        '连续失败达到该次数后，目标判为「严重」。',
    'After this many consecutive failures the target is graded Offline.':
        '连续失败达到该次数后，目标判为「离线」。',
    'Front-end refresh rate and log verbosity.': '前端刷新频率与日志详细程度。',
    'The notification backend is not implemented yet.': '通知后端尚未实现。',
    'Reserved for future webhook / Telegram / WeCom / DingTalk / mail support. Has no effect yet.':
        '接口预留，后续可扩展 Webhook、Telegram、企业微信、钉钉、邮件等方式；目前不生效。',
    'Ring buffer size in tmpfs. 4320 samples at a 10s interval covers about 12 hours.':
        'tmpfs 中环形缓存的大小。10 秒间隔下 4320 点约覆盖 12 小时。',
    'Save & Apply': '保存并应用',
    'Discard changes': '放弃修改',
    'Unsaved changes': '有未保存的修改',
    'All changes applied': '所有修改已应用',
    'Changes discarded': '已放弃修改',
    'Please enter a whole number': '请填写整数',
    'Allowed range': '允许范围',
    '(current)': '（当前值）',

    # ------------------------------------------------- 后端 err() 的前端兜底翻译
    # rpcd 的 ucode 插件没有 LuCI i18n 运行时，只能返回英文原文，
    # 由 common.js 的 localizeError() 在浏览器侧查表翻译（见该函数注释）。
    # 新增后端 err() 字面量时，务必同步在此登记，否则会以英文原样透出。
    'Invalid arguments': '参数无效',
    'Invalid ID': '标识无效',
    'Invalid target selection': '目标选择无效',
    'Invalid name': '名称无效',
    'Invalid host': '主机无效',
    'Invalid region': '区域无效',
    'Invalid label': '标签无效',
    'Invalid protocol': '协议无效',
    'Invalid address family': '地址族无效',
    'Invalid interface': '接口无效',
    'Invalid source address': '源地址无效',
    'Invalid remark': '备注无效',
    'Invalid direction': '方向无效',
    'Target not found': '目标不存在',
    'Target already exists': '目标已存在',
    'Cannot create configuration section': '无法创建配置节',
    'Already at the boundary': '已在边界位置',
    'Invalid value for %s': '%s 的值无效',

    # ------------------------------------------------------- 无障碍 / 图标标签
    'Icon': '图标',

    # --------------------------------------------------- 加权丢包率（总览页）
    'Weighted loss': '加权丢包率',
    'Lost packets': '丢包数',
    'Unweighted': '未加权',
}

# 手工补充（来自数组常量 / 动态拼接，正则无法直接提取）
EXTRA = [
    'Excellent', 'Good', 'Fair', 'Poor', 'Severe', 'Offline', 'Unknown',
    '%d seconds ago', '%d minutes ago', '%d hours ago', '%d days ago',
    '1 min', '5 min', '15 min', '30 min', '1 hour', '6 hours', '12 hours',
    '24 hours', '3 days', '7 days', '30 days',
    '1 hour', '6 hours', '12 hours', '24 hours', '3 days', '7 days', '30 days',
]

PAT = re.compile(r"_\('((?:[^'\\]|\\.)*)'\)")

# 映射表取值模式：'key': 'value'（精确表） / msg: 'value'（带参表）
PAIR = re.compile(r"'([^']+)':\s*'((?:[^'\\]|\\.)*)'")
MSGVAL = re.compile(r"\bmsg:\s*'((?:[^'\\]|\\.)*)'")
PREFIXVAL = re.compile(r"\bprefix:\s*'((?:[^'\\]|\\.)*)'")


def _map_block(src, var, term):
    """截出 common.js 里某个映射表的源码块；找不到返回 None。"""
    i = src.find('var %s' % var)
    if i < 0:
        sys.stderr.write('warn: 未找到 %s 映射表\n' % var)
        return None
    j = src.find(term, i)
    if j < 0:
        sys.stderr.write('warn: %s 映射表未正常闭合\n' % var)
        return None
    return src[i:j]


def backend_map():
    """解析 common.js 的后端错误映射表 → (待翻译文案, 精确键, 前缀键)。

    这些文案是以变量形式传给 _() 的（_(BACKEND_MSG[s])），PAT 抓不到字面量，
    必须直接解析映射表，否则不会进 po，运行时 _() 查表落空、回落英文。
    映射表因此是唯一事实来源：后端新增 err() 后登记进表即可，这里自动跟上。"""
    if not os.path.isfile(COMMON_JS):
        sys.stderr.write('warn: 找不到 %s，后端错误文案未纳入翻译\n' % COMMON_JS)
        return [], set(), set()

    with io.open(COMMON_JS, encoding='utf-8') as fh:
        src = fh.read()

    strings, keys, prefixes = [], set(), set()

    blk = _map_block(src, 'BACKEND_MSG', '\n};')
    if blk is not None:
        for k, v in PAIR.findall(blk):
            keys.add(k)
            strings.append(v)

    blk = _map_block(src, 'BACKEND_MSG_ARG', '\n];')
    if blk is not None:
        strings.extend(MSGVAL.findall(blk))
        prefixes.update(PREFIXVAL.findall(blk))

    if not strings:
        sys.stderr.write('warn: %s 未解析出任何后端错误文案\n' % COMMON_JS)
    return strings, keys, prefixes


def backend_keys():
    """审计用键集合 = 精确键 ∪ 前缀键（覆盖 err('前缀' + k) 这类拼接报错）。"""
    _s, keys, prefixes = backend_map()
    return keys | prefixes


def audit_duplicate_keys():
    """自检 ZH 字典字面量里是否有同名键。

    Python 字典字面量出现同名键时「后者覆盖前者」，且不给任何提示。
    实测踩过一次：总览段另写了一条 'Targets': '目标数'，把菜单页签的
    '目标管理' 静默顶掉，页签显示成「目标数」。重复键在字典构造时就已
    合并，单看 ZH 本身查不出来，必须回读本文件源码逐键比对行号。"""
    import ast
    with io.open(os.path.abspath(__file__), encoding='utf-8') as fh:
        tree = ast.parse(fh.read())

    node = None
    for n in ast.walk(tree):
        if isinstance(n, ast.Assign):
            for t in n.targets:
                if (isinstance(t, ast.Name) and t.id == 'ZH'
                        and isinstance(n.value, ast.Dict)):
                    node = n.value
    if node is None:
        sys.stdout.write('  WARN: 未解析出 ZH 字典字面量，重复键检查被跳过\n')
        return []

    where = {}
    for k in node.keys:
        if isinstance(k, ast.Constant) and isinstance(k.value, str):
            where.setdefault(k.value, []).append(k.lineno)

    dups = sorted((k, v) for k, v in where.items() if len(v) > 1)
    for k, lns in dups:
        sys.stdout.write('  DUPLICATE ZH key: %r 在 L%s（仅最后一条生效）\n'
                         % (k, ', L'.join(str(x) for x in lns)))
    return dups


def audit_core_collisions(strings):
    """校验「与核心语言包同名」的 msgid 本插件取值是否也与核心一致。

    核心 base 语言包与插件语言包同名时，核心覆盖插件、插件的译文被静默丢弃，
    因此这类 msgid 的取值必须与核心一致（见 po/core_msgids.txt 与 ZH 表头说明）。
    清单外的通用词（核心也有、但本插件此前没用过的）检测不到，
    新增文案后需用工作区的 _audit_i18n_collide.py 复查并重新生成本清单。"""
    path = os.path.join(BASE, 'po', 'core_msgids.txt')
    if not os.path.isfile(path):
        sys.stdout.write('  WARN: 缺少 po/core_msgids.txt，同名冲突检查被跳过\n')
        return []

    core = {}
    with io.open(path, encoding='utf-8') as fh:
        for ln in fh:
            ln = ln.rstrip('\n')
            if not ln or ln.startswith('#'):
                continue
            parts = ln.split('\t')
            if len(parts) != 2:
                continue
            core[parts[0]] = parts[1]

    bad = []
    for s in strings:
        if s in core and ZH.get(s, '') != core[s]:
            bad.append((s, ZH.get(s, ''), core[s]))
    for msgid, mine, cval in bad:
        sys.stdout.write('  CORE COLLISION MISMATCH: %r 本插件=%r 核心=%r\n'
                         % (msgid, mine, cval))
    return bad


def collect():
    strings = []
    seen = set()

    def add(s):
        if s and s not in seen:
            seen.add(s)
            strings.append(s)

    for dirpath, dirnames, filenames in os.walk(RES):
        # 目录枚举顺序由文件系统决定（NTFS 与 ext4 就不一样），只排序 filenames 不够：
        # 子目录的先后会直接改变产出 po/pot 里条目的顺序，CI 的
        # `git diff --exit-code -- po/` 于是在换机器后必然报「与源码不一致」。
        dirnames.sort()
        for fn in sorted(filenames):
            if not fn.endswith('.js'):
                continue
            with io.open(os.path.join(dirpath, fn), encoding='utf-8') as fh:
                src = fh.read()
            for m in PAT.finditer(src):
                add(m.group(1).replace("\\'", "'"))

    # 菜单 JSON 中的 title
    if os.path.isfile(MENU):
        import json
        with io.open(MENU, encoding='utf-8') as fh:
            data = json.load(fh)
        for _key, node in data.items():
            add(node.get('title'))

    for s in EXTRA:
        add(s)

    # 以变量形式传给 _() 的后端错误文案（见 backend_map 注释）
    for s in backend_map()[0]:
        add(s)

    return strings


def escape(v):
    return v.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


def write_po(path, strings, translated):
    header = (
        '# luci-app-netmonitor translation file\n'
        '# Copyright (C) 2026 netmonitor contributors\n'
        '# This file is distributed under the same license as the luci-app-netmonitor package.\n'
        '#\n'
        'msgid ""\n'
        'msgstr ""\n'
        '"Project-Id-Version: luci-app-netmonitor 1.2.0\\n"\n'
        '"Language: %s\\n"\n'
        '"MIME-Version: 1.0\\n"\n'
        '"Content-Type: text/plain; charset=UTF-8\\n"\n'
        '"Content-Transfer-Encoding: 8bit\\n"\n'
        '"X-Generator: po/gen_po.py\\n"\n'
        % (translated and 'zh_Hans' or 'en')
    )

    out = [header]
    for s in strings:
        msgstr = ZH.get(s, '') if translated else ''
        out.append('')
        out.append('msgid "%s"' % escape(s))
        out.append('msgstr "%s"' % escape(msgstr))

    with io.open(path, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write('\n'.join(out) + '\n')


def main():
    strings = collect()
    missing = [s for s in strings if s not in ZH]

    pot = os.path.join(BASE, 'po', 'templates', DOMAIN + '.pot')
    po = os.path.join(BASE, 'po', 'zh_Hans', DOMAIN + '.po')

    write_po(pot, strings, False)
    write_po(po, strings, True)

    sys.stdout.write('strings: %d, untranslated: %d\n' % (len(strings), len(missing)))
    for s in missing:
        sys.stdout.write('  MISSING: %s\n' % s)

    # 漂移审计：ucode 后端新增 err('...') 却忘了登记进 common.js 的映射表时，
    # 该英文串会绕过翻译直接透出，这里提前告警。
    known = backend_keys()
    if os.path.isfile(UCODE):
        with io.open(UCODE, encoding='utf-8') as fh:
            usrc = fh.read()
        unregistered = sorted(set(re.findall(r"err\('([^']*)'", usrc)) - known)
        for s in unregistered:
            sys.stdout.write('  UNREGISTERED backend error: %s\n' % s)
        if unregistered:
            sys.stdout.write('  => 需在 common.js 的 BACKEND_MSG 中登记并补中文\n')

    # ZH 字典自检：重复键会让被覆盖的那条翻译静默失效，且不会出现在 MISSING 里
    if audit_duplicate_keys():
        sys.stdout.write('  => ZH 字典存在重复键，请删掉被覆盖的那条\n')

    # 与核心语言包同名却不同译：界面上看到的不是本插件写的那个词
    if audit_core_collisions(strings):
        sys.stdout.write('  => 这些 msgid 请改用插件独有说法，或把译文对齐核心\n')

    return 0


if __name__ == '__main__':
    sys.exit(main())

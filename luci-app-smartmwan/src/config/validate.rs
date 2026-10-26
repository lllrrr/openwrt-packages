//! 配置校验：把「能跑」和「跑对了」分开。
//!
//! 两层结果：
//! * `errors` —— 致命，禁止 apply（例如线路名非法、主线路不存在）。
//! * `warnings` —— 可 apply，但必须在 UI 上显式展示（例如只有一个线路还开了负载均衡）。
//!
//! 安全要点：所有会进入 nftables / `ip` 命令行的标识符（接口名、段名、集合名）都在这里
//! 做白名单字符校验。后续模块信任校验结果，**不再**依赖引号或转义来防注入 ——
//! 防注入的正确做法是让非法输入根本进不了模型。

use std::net::IpAddr;

use serde::{Deserialize, Serialize};

use super::schema::{Algorithm, GameSelection, Mode, ProtoFilter, WanRole};
use super::Config;
use crate::marks;

/// 校验结果的严重级别。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Error,
    Warning,
    /// 只供用户参考的事实性说明，不影响提交（例如线路备注）。
    Info,
}

/// 一条具体问题，`path` 用 UCI 风格点路径，前端可直接定位到表单控件。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Issue {
    pub severity: Severity,
    pub path: String,
    pub message: String,
    /// 给用户的具体修法，而不只是「不合法」。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
}

/// 校验报告。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Report {
    pub issues: Vec<Issue>,
    /// 校验所依据的模式版本，便于前端判断「daemon 与 view 不同步」。
    pub schema_version: u32,
}

impl Report {
    pub fn errors(&self) -> Vec<&Issue> {
        self.issues
            .iter()
            .filter(|i| i.severity == Severity::Error)
            .collect()
    }

    pub fn warnings(&self) -> Vec<&Issue> {
        self.issues
            .iter()
            .filter(|i| i.severity == Severity::Warning)
            .collect()
    }

    pub fn is_valid(&self) -> bool {
        self.errors().is_empty()
    }

    /// 合并另一份报告（用于 apply 前把「本次校验」与「运行能力探测」结论并起来）。
    pub fn merge(&mut self, other: Report) {
        self.issues.extend(other.issues);
    }
}

/// UCI / shell 安全标识符：字母、数字、下划线、点、连字符；首字符非 `-`；长度 ≤ 32。
/// 接口名额外受 IFNAMSIZ=15 限制，由 [`valid_ifname`] 处理。
pub fn valid_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if s.len() > 32 || !(first.is_ascii_alphanumeric() || first == '_') {
        return false;
    }
    s.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '-')
}

/// Linux 网络接口名（IFNAMSIZ = 16 含结尾 NUL）。
pub fn valid_ifname(s: &str) -> bool {
    s.len() <= 15 && valid_identifier(s)
}

/// CIDR 或裸 IP（v4/v6 均可）。
pub fn valid_cidr_or_ip(s: &str) -> bool {
    if let Some((addr, len)) = s.split_once('/') {
        let ok = addr.parse::<IpAddr>().is_ok();
        let max = if addr.contains(':') { 128 } else { 32 };
        ok && len.parse::<u8>().map(|l| l <= max).unwrap_or(false)
    } else {
        s.parse::<IpAddr>().is_ok()
    }
}

/// MAC 地址，接受 `aa:bb:cc:dd:ee:ff` 与 `aa-bb-cc-dd-ee-ff` 与 Cisco 点分格式。
pub fn valid_mac(s: &str) -> bool {
    let s = s.trim();
    let groups: Vec<&str> = if s.contains('.') {
        s.split('.').collect()
    } else {
        s.split([':', '-']).collect()
    };
    if s.contains('.') {
        return groups.len() == 3 && groups.iter().all(|g| g.len() == 4 && hex_ok(g));
    }
    groups.len() == 6 && groups.iter().all(|g| g.len() == 2 && hex_ok(g))
}

fn hex_ok(g: &str) -> bool {
    g.chars().all(|c| c.is_ascii_hexdigit())
}

/// 域名：仅做保守校验（真正的解析在 dns_sets 里做，失败要报错而不是静默）。
pub fn valid_domain(s: &str) -> bool {
    let s = s.trim().trim_end_matches('.');
    if s.is_empty() || s.len() > 253 || !s.contains('.') {
        return false;
    }
    s.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && label
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
            && !label.starts_with('-')
    })
}

/// 绝对路径且不含换行/控制字符（防止把路径拼进任何外部调用时越界）。
pub fn valid_abs_path(s: &str) -> bool {
    s.starts_with('/')
        && !s.contains('\n')
        && !s.contains('\0')
        && s.len() <= 128
        && !s.contains("..")
}

/// 全量校验入口。
pub fn validate(cfg: &Config) -> Report {
    let mut r = Report {
        issues: Vec::new(),
        schema_version: cfg.global.config_version,
    };
    let g = &cfg.global;

    let err = |r: &mut Report, path: &str, msg: String, hint: Option<String>| {
        r.issues.push(Issue {
            severity: Severity::Error,
            path: path.to_string(),
            message: msg,
            hint,
        })
    };
    let warn = |r: &mut Report, path: &str, msg: String, hint: Option<String>| {
        r.issues.push(Issue {
            severity: Severity::Warning,
            path: path.to_string(),
            message: msg,
            hint,
        })
    };

    // ---------- 全局字段 ----------
    if g.config_version > crate::CONFIG_SCHEMA_VERSION {
        err(
            &mut r,
            "smartmwan.global.config_version",
            format!(
                "配置版本 {} 高于本守护进程支持的 {}",
                g.config_version,
                crate::CONFIG_SCHEMA_VERSION
            ),
            Some("请升级 smartmwand，不要降级配置文件".into()),
        );
    }

    if g.buckets < 2 || g.buckets > marks::BUCKETS {
        err(
            &mut r,
            "smartmwan.global.buckets",
            format!("桶数 {} 超出允许范围 2..{}", g.buckets, marks::BUCKETS),
            Some("桶数决定分流粒度；建议 16/32/64".into()),
        );
    }

    // 域名集合的元素寿命：下限 30 秒、上限 24 小时。
    // 下限不是为了好看：寿命小于解析周期时，元素每轮都过期 ⇒ 每轮都重解析 +
    // 每轮都写内核集合，把一个「低频」特性变成高频负载，这正是任务书禁止的方向。
    if g.dns_ttl_floor_s < 30 || g.dns_ttl_floor_s > 86_400 {
        err(
            &mut r,
            "smartmwan.global.dns_ttl_floor_s",
            format!(
                "域名集合元素寿命 {} 秒超出允许范围 30..86400",
                g.dns_ttl_floor_s
            ),
            Some("建议 300 秒；改小会增加解析与内核集合写入频率".into()),
        );
    }

    if !valid_abs_path(&g.rpc_socket) {
        err(
            &mut r,
            "smartmwan.global.rpc_socket",
            format!(
                "RPC socket 路径非法：{}",
                crate::clamp_str(&g.rpc_socket, 64)
            ),
            Some("必须是绝对路径且不含 ..，例如 /var/run/smartmwan/rpc.sock".into()),
        );
    }
    if !valid_abs_path(&g.state_dir) {
        err(
            &mut r,
            "smartmwan.global.state_dir",
            format!("状态目录非法：{}", crate::clamp_str(&g.state_dir, 64)),
            Some("例如 /tmp/run/smartmwan".into()),
        );
    }
    if !g.log_file.is_empty() && !valid_abs_path(&g.log_file) {
        err(
            &mut r,
            "smartmwan.global.log_file",
            format!("日志路径非法：{}", crate::clamp_str(&g.log_file, 64)),
            Some("例如 /tmp/log/smartmwan.log；留空表示只写 stderr".into()),
        );
    }
    if crate::logging::Level::parse(&g.log_level).is_none() {
        err(
            &mut r,
            "smartmwan.global.log_level",
            format!("日志等级无法识别：{}", g.log_level),
            Some("error|warning|info|debug|trace".into()),
        );
    }
    if g.log_max_bytes < 16 * 1024 {
        warn(
            &mut r,
            "smartmwan.global.log_max_bytes",
            "轮转阈值过小".into(),
            Some("至少 16384 字节，否则一次故障切换的日志会被截没".into()),
        );
    }

    // ---------- 健康检测参数之间的耦合 ----------
    let h = &g.health;
    if h.timeout_ms == 0 || h.interval_ms == 0 {
        err(
            &mut r,
            "smartmwan.global.health",
            "探测周期与超时不得为 0".into(),
            None,
        );
    } else if h.timeout_ms > h.interval_ms {
        err(
            &mut r,
            "smartmwan.global.health.timeout_ms",
            format!(
                "单次超时 {}ms 大于周期 {}ms，探测会自叠加",
                h.timeout_ms, h.interval_ms
            ),
            Some("保持 timeout_ms < interval_ms；需要更长超时就同时放大周期".into()),
        );
    }
    if h.failure_threshold == 0 || h.recovery_threshold == 0 {
        err(
            &mut r,
            "smartmwan.global.health.failure_threshold",
            "失败/恢复阈值必须 ≥1".into(),
            None,
        );
    }
    if h.recovery_threshold < h.failure_threshold {
        warn(
            &mut r,
            "smartmwan.global.health.recovery_threshold",
            format!(
                "恢复阈值 {} 小于故障阈值 {}，线路会更容易抖动后立刻回池",
                h.recovery_threshold, h.failure_threshold
            ),
            Some("典型值：故障 3 次 / 恢复 5 次".into()),
        );
    }
    if h.max_concurrent_probes == 0 {
        err(
            &mut r,
            "smartmwan.global.health.max_concurrent_probes",
            "并发探测上限不得为 0".into(),
            Some("0 会让所有探测排队直至超时；建议 8~32".into()),
        );
    }
    if h.warmup_ms > 5 * 60_000 {
        warn(
            &mut r,
            "smartmwan.global.health.warmup_ms",
            format!("预热时间 {}ms 超过 5 分钟", h.warmup_ms),
            Some("过长会让线路恢复后长时间不分流".into()),
        );
    }

    if g.smoothing_permille == 0 || g.smoothing_permille > 999 {
        err(
            &mut r,
            "smartmwan.global.smoothing_permille",
            format!("平滑系数 {} 必须在 1..999", g.smoothing_permille),
            Some("700 表示新样本权重 30%".into()),
        );
    }
    if g.rebalance_interval_ms < 200 {
        err(
            &mut r,
            "smartmwan.global.rebalance_interval_ms",
            format!("重排间隔 {}ms 过小", g.rebalance_interval_ms),
            Some("≥200ms，否则会退化成高频规则重建".into()),
        );
    }
    if g.sample_window_ms < g.rebalance_interval_ms {
        err(
            &mut r,
            "smartmwan.global.sample_window_ms",
            format!(
                "统计窗口 {}ms 小于重排间隔 {}ms，样本无意义",
                g.sample_window_ms, g.rebalance_interval_ms
            ),
            None,
        );
    }
    if g.min_switch_interval_ms < 1000 {
        warn(
            &mut r,
            "smartmwan.global.min_switch_interval_ms",
            format!("最小切换间隔 {}ms 过小", g.min_switch_interval_ms),
            Some("主备防抖建议 ≥5000ms".into()),
        );
    }
    if g.hash_seed == 0 {
        warn(
            &mut r,
            "smartmwan.global.hash_seed",
            "哈希种子为 0，多设备部署时分流模式可能雷同".into(),
            Some("设置一个非零种子以使各设备分桶互不相同".into()),
        );
    }

    // ---------- 保护性网段（防失联）----------
    for (i, net) in g.protected_src.iter().enumerate() {
        if !valid_cidr_or_ip(net) {
            err(
                &mut r,
                &format!("smartmwan.global.protected_src[{i}]"),
                format!("非法网段：{net}"),
                Some("例：192.168.100.0/24 或 2001:db8::1".into()),
            );
        }
    }
    for (i, net) in g.bypass_dst.iter().enumerate() {
        if !valid_cidr_or_ip(net) {
            err(
                &mut r,
                &format!("smartmwan.global.bypass_dst[{i}]"),
                format!("非法网段：{net}"),
                None,
            );
        }
    }
    if g.protected_src.is_empty() {
        warn(
            &mut r,
            "smartmwan.global.protected_src",
            "保护源段为空：管理侧流量可能被分流，存在失联风险".into(),
            Some("至少把路由器管理网段加入 protected_src".into()),
        );
    }
    if g.bypass_dst.iter().any(|s| s == "0.0.0.0/0") {
        err(
            &mut r,
            "smartmwan.global.bypass_dst",
            "bypass_dst 含 0.0.0.0/0 会让所有流量绕过策略路由".into(),
            Some("该选项用于内网/组播段，不是总开关".into()),
        );
    }

    // ---------- 线路 ----------
    let mut names: Vec<String> = Vec::new();
    for (i, w) in cfg.wans.iter().enumerate() {
        let base = format!("smartmwan.wan[{i}]");
        if !valid_identifier(&w.name) {
            err(&mut r, &base, format!("线路段名非法：{:?}", crate::clamp_str(&w.name, 32)), Some("仅允许字母、数字、下划线、点、连字符，且不能以 - 开头；该名称会用于 nftables 集合名".into()));
        }
        if names.contains(&w.name) {
            err(
                &mut r,
                &base,
                format!("线路段名重复：{}", w.name),
                Some("重复段名会让 uci 只保留最后一段".into()),
            );
        }
        names.push(w.name.clone());

        if !w.device.is_empty() && !valid_ifname(&w.device) {
            err(
                &mut r,
                &format!("{base}.device"),
                format!("接口名非法或超过 15 字符：{}", w.device),
                Some("Linux IFNAMSIZ 限制 15 字符".into()),
            );
        }
        if w.weight == 0 {
            err(
                &mut r,
                &format!("{base}.weight"),
                "权重不得为 0".into(),
                Some("权重为 0 会让该线路在加权算法中永远拿不到桶".into()),
            );
        }
        if w.weight > 1000 {
            warn(
                &mut r,
                &format!("{base}.weight"),
                format!("权重 {} 过大，归一化后其它线路可能完全得不到流量", w.weight),
                None,
            );
        }
        if w.down_kbps > 100_000_000 || w.up_kbps > 100_000_000 {
            err(
                &mut r,
                &format!("{base}.down_kbps"),
                "带宽上限超出合理范围（≤100000000 kbit/s）".into(),
                None,
            );
        }
        if !w.gateway.is_empty() && w.gateway.parse::<IpAddr>().is_err() {
            err(
                &mut r,
                &format!("{base}.gateway"),
                format!("网关覆盖值非法：{}", w.gateway),
                Some("必须是 IPv4/IPv6 字面量".into()),
            );
        }
        if !w.src_ip.is_empty() && w.src_ip.parse::<IpAddr>().is_err() {
            err(
                &mut r,
                &format!("{base}.src_ip"),
                format!("源地址覆盖非法：{}", w.src_ip),
                None,
            );
        }
        if w.probe_targets.len() > 8 {
            warn(
                &mut r,
                &format!("{base}.probe_targets"),
                format!("探测目标 {} 个偏多", w.probe_targets.len()),
                Some("3~5 个足以避免单目标屏蔽 ICMP 造成误判".into()),
            );
        }
        for (j, t) in w.probe_targets.iter().enumerate() {
            let p = format!("{base}.probe_targets[{j}]");
            if t.trim().is_empty() {
                err(&mut r, &p, "探测目标为空字符串".into(), None);
            } else if t.parse::<IpAddr>().is_ok() {
                if t.contains(':') && !cfg.global.enable_ipv6 {
                    warn(&mut r, &p, format!("IPv6 已关闭但探测目标为 {t}"), None);
                }
            } else if !valid_domain(t) {
                err(
                    &mut r,
                    &p,
                    format!("探测目标既不是 IP 也不是合法域名：{t}"),
                    Some("填写 IP 时建议用字面量，域名会在运行时解析".into()),
                );
            }
            if let Some((_, plen)) = t.split_once('/') {
                err(
                    &mut r,
                    &p,
                    format!("探测目标不能是网段：{t}"),
                    Some("只接受主机 IP 或域名".into()),
                );
                let _ = plen;
            }
        }
        if w.enabled && !w.maintenance && w.probe_targets.is_empty() {
            warn(
                &mut r,
                &format!("{base}.probe_targets"),
                format!(
                    "线路 {} 未配置探测目标，只能依赖链路与网关可达性判断",
                    w.name
                ),
                Some("至少配置 2 个不同运营商的 IP，避免误判".into()),
            );
        }
        if w.probe_proto == crate::config::schema::ProbeProto::Icmp && w.probe_port != 0 {
            warn(
                &mut r,
                &format!("{base}.probe_port"),
                "ICMP 探测不使用端口，probe_port 将被忽略".into(),
                None,
            );
        }
    }

    // ---------- 模式相关 ----------
    // role=primary 的唯一性与地址族模式无关：负载均衡模式下出现两条
    // “主线路”同样是配置错误（会被 UI 的“首选”语义误用），必须提前拦住。
    if cfg
        .wans
        .iter()
        .filter(|w| w.role == WanRole::Primary)
        .count()
        > 1
    {
        err(
            &mut r,
            "smartmwan.wan",
            "出现多条 role=primary 的线路".into(),
            Some("显式主线路只能有一条；其余用 role=backup".into()),
        );
    }

    let active: Vec<&str> = cfg.active_wans().iter().map(|w| w.name.as_str()).collect();
    if g.enabled && active.is_empty() {
        err(
            &mut r,
            "smartmwan.global.enabled",
            "已启用但没有任何可参与分流的线路".into(),
            Some("至少启用一条 WAN，或关闭插件".into()),
        );
    }

    match g.mode {
        Mode::Failover => {
            if g.primary.is_empty() {
                if g.enabled {
                    err(
                        &mut r,
                        "smartmwan.global.primary",
                        "主备模式必须指定主线路".into(),
                        None,
                    );
                }
            } else if !names.contains(&g.primary) {
                err(
                    &mut r,
                    "smartmwan.global.primary",
                    format!("主线路 {} 不存在", g.primary),
                    Some("主线路必须是某个 config wan 段名".into()),
                );
            }
            if g.algorithm != Algorithm::SrcIpDstIp && g.enabled {
                warn(
                    &mut r,
                    "smartmwan.global.algorithm",
                    format!("主备模式下算法 {} 不参与普通流量决策", g.algorithm.as_str()),
                    Some("普通流量只走主线路，该算法仅在回切/降级为并行时无效".into()),
                );
            }
            if g.failback == crate::config::schema::Failback::Auto && g.failback_delay_ms < 10_000 {
                warn(
                    &mut r,
                    "smartmwan.global.failback_delay_ms",
                    format!("自动回切延迟 {}ms 偏短", g.failback_delay_ms),
                    Some("建议 ≥30000ms，避免主线路抖动引起来回切换".into()),
                );
            }
        }
        Mode::Balance => {
            if active.len() < 2 && g.enabled {
                warn(
                    &mut r,
                    "smartmwan.global.mode",
                    "负载均衡模式只有 1 条可用线路，实际等同单线路".into(),
                    None,
                );
            }
        }
    }

    for (i, n) in g.backup_order.iter().enumerate() {
        let p = format!("smartmwan.global.backup_order[{i}]");
        if !names.contains(n) {
            err(&mut r, &p, format!("备用线路 {n} 不存在"), None);
        }
        if n == &g.primary {
            err(
                &mut r,
                &p,
                format!("主线路 {n} 不应出现在备用顺序里"),
                Some("主备冲突：请从 backup_order 中移除".into()),
            );
        }
        if g.backup_order[..i].contains(n) {
            err(&mut r, &p, format!("备用顺序重复项：{n}"), None);
        }
    }

    if g.algorithm == Algorithm::WeightedEcmp {
        warn(
            &mut r,
            "smartmwan.global.algorithm",
            "加权 ECMP 需要内核多路径与 ip-full；能力探测失败时 apply 会被拒绝".into(),
            Some("运行 `smartmwand --capabilities` 确认".into()),
        );
    }
    if g.algorithm.is_dynamic() && active.len() < 2 && g.enabled {
        warn(
            &mut r,
            "smartmwan.global.algorithm",
            "动态算法在单线路下没有可调度对象".into(),
            None,
        );
    }

    // ---------- 评分权重 ----------
    let s = &cfg.score;
    if s.total() == 0 {
        err(
            &mut r,
            "smartmwan.score",
            "评分权重全为 0，游戏择优会退化成「永不切换」".into(),
            None,
        );
    }
    for (k, v) in [
        ("rtt_norm_ms", s.rtt_norm_ms),
        ("jitter_norm_ms", s.jitter_norm_ms),
    ] {
        if v == 0 {
            err(
                &mut r,
                &format!("smartmwan.score.{k}"),
                format!("{k} 不得为 0（会导致归一化除零）"),
                None,
            );
        }
    }
    if s.loss_norm_pmm == 0 {
        err(
            &mut r,
            "smartmwan.score.loss_norm_pmm",
            "loss_norm_pmm 不得为 0".into(),
            None,
        );
    }
    if s.min_advantage_permille > 900 {
        warn(
            &mut r,
            "smartmwan.score.min_advantage_permille",
            format!(
                "切换门槛 {}‰ 过高，几乎不会再择优切换",
                s.min_advantage_permille
            ),
            Some("150‰ 表示候选需好 15% 才切换".into()),
        );
    }

    // ---------- 游戏规则 ----------
    let mut game_names: Vec<String> = Vec::new();
    for (i, rule) in cfg.games.iter().enumerate() {
        let base = format!("smartmwan.game[{i}]");
        if !valid_identifier(&rule.name) {
            err(
                &mut r,
                &base,
                format!("规则名非法：{:?}", crate::clamp_str(&rule.name, 32)),
                Some("规则名会成为 nft 集合/注释标识的一部分，仅允许安全字符".into()),
            );
        }
        if game_names.contains(&rule.name) {
            err(&mut r, &base, format!("规则名重复：{}", rule.name), None);
        }
        game_names.push(rule.name.clone());

        if rule.enabled
            && rule.targets.is_empty()
            && rule.domains.is_empty()
            && rule.client_ips.is_empty()
            && rule.client_macs.is_empty()
        {
            err(
                &mut r,
                &format!("{base}.targets"),
                format!("规则 {} 没有任何匹配条件，启用后将匹配全部流量", rule.name),
                Some("必须至少指定目标网段、域名或客户端条件之一".into()),
            );
        }

        for (j, t) in rule.targets.iter().enumerate() {
            let p = format!("{base}.targets[{j}]");
            if !valid_cidr_or_ip(t) {
                err(
                    &mut r,
                    &p,
                    format!("非法目标：{t}"),
                    Some("接受 IP 或 CIDR（v4/v6）".into()),
                );
            } else if t == "0.0.0.0/0" || t == "::/0" {
                err(
                    &mut r,
                    &p,
                    "游戏规则目标不能是默认路由".into(),
                    Some("那会把所有流量标记为游戏流量".into()),
                );
            } else if t.contains(':') && !g.enable_ipv6 {
                warn(&mut r, &p, format!("IPv6 已关闭，目标 {t} 不会生效"), None);
            }
        }
        for (j, p) in rule.ports.iter().enumerate() {
            let path = format!("{base}.ports[{j}]");
            if super::schema::parse_port_range(p).is_none() {
                err(
                    &mut r,
                    &path,
                    format!("非法端口或范围：{p}"),
                    Some("格式：443 或 8000-8010".into()),
                );
            }
            if rule.proto == crate::config::schema::ProtoFilter::Both && p.parse::<u16>().is_ok() {
                // 端口号本身可能与非 TCP/UDP 协议冲突，提示但不算错误
                warn(
                    &mut r,
                    &path,
                    format!("端口 {p} 将同时匹配 TCP 与 UDP"),
                    Some("如只需一种协议请设置 proto".into()),
                );
            }
        }
        for (j, c) in rule.client_ips.iter().enumerate() {
            if !valid_cidr_or_ip(c) {
                err(
                    &mut r,
                    &format!("{base}.client_ips[{j}]"),
                    format!("非法客户端地址：{c}"),
                    None,
                );
            }
        }
        for (j, m) in rule.client_macs.iter().enumerate() {
            if !valid_mac(m) {
                err(
                    &mut r,
                    &format!("{base}.client_macs[{j}]"),
                    format!("非法 MAC：{m}"),
                    Some("格式 aa:bb:cc:dd:ee:ff".into()),
                );
            }
        }
        for (j, d) in rule.domains.iter().enumerate() {
            let p = format!("{base}.domains[{j}]");
            if !valid_domain(d) {
                err(
                    &mut r,
                    &p,
                    format!("非法域名：{d}"),
                    Some("不支持通配符；请逐条填写具体域名".into()),
                );
            } else if d.len() > 64 {
                warn(&mut r, &p, "域名偏长，解析结果可能不稳定".into(), None);
            }
        }
        if rule.selection == GameSelection::Pin {
            if rule.pin_wan.is_empty() {
                err(
                    &mut r,
                    &format!("{base}.pin_wan"),
                    format!("规则 {} 选择 pin 但未指定线路", rule.name),
                    None,
                );
            } else if !names.contains(&rule.pin_wan) {
                err(
                    &mut r,
                    &format!("{base}.pin_wan"),
                    format!("pin 目标线路 {} 不存在", rule.pin_wan),
                    None,
                );
            } else if g.mode == Mode::Failover
                && g.game_policy == crate::config::schema::GamePolicy::Follow
            {
                warn(
                    &mut r,
                    &format!("{base}.selection"),
                    format!(
                        "严格主备策略下规则 {} 的 pin 会被普通主备顺序覆盖",
                        rule.name
                    ),
                    Some("把 game_policy 设为 exception 才允许跨线路".into()),
                );
            }
        }
        if rule.selection == GameSelection::Best
            && g.mode == Mode::Failover
            && g.game_policy == crate::config::schema::GamePolicy::Follow
        {
            warn(
                &mut r,
                &format!("{base}.selection"),
                format!(
                    "规则 {} 设为择优，但当前 game_policy=follow，游戏流量仍只走主线路",
                    rule.name
                ),
                Some("UI 必须如实展示该行为，避免用户误判".into()),
            );
        }
        if !rule.preset.is_empty() && !valid_identifier(&rule.preset) {
            err(
                &mut r,
                &format!("{base}.preset"),
                format!("预置标识非法：{}", rule.preset),
                None,
            );
        }
    }

    // 规则冲突/优先级歧义：同优先级且目标重叠 → 匹配结果取决于顺序，必须报出来。
    let sorted: Vec<(usize, &crate::config::schema::GameRule)> = cfg
        .games
        .iter()
        .enumerate()
        .filter(|(_, r)| r.enabled)
        .collect();
    for (ai, (_, a)) in sorted.iter().enumerate() {
        for (_, b) in sorted.iter().skip(ai + 1) {
            if a.priority != b.priority {
                continue;
            }
            if overlaps(a, b) {
                warn(
                    &mut r,
                    &format!("smartmwan.game[{}].priority", a.name),
                    format!(
                        "规则 {} 与 {} 优先级相同且匹配范围重叠，命中顺序不确定",
                        a.name, b.name
                    ),
                    Some("给其中一条更小的 priority 以显式定序".into()),
                );
            }
        }
    }

    r
}

/// 两条规则是否可能匹配到同一批流量（保守判定：任一集合有交集即算重叠）。
fn overlaps(a: &crate::config::schema::GameRule, b: &crate::config::schema::GameRule) -> bool {
    let str_overlap = |x: &[String], y: &[String]| x.iter().any(|i| y.iter().any(|j| i == j));
    // 空目标视为「任意」，与任何规则都重叠
    let targets = if a.targets.is_empty() || b.targets.is_empty() {
        true
    } else {
        str_overlap(&a.targets, &b.targets)
            || a.targets
                .iter()
                .any(|x| b.targets.iter().any(|y| cidr_overlap(x, y)))
    };
    let clients = if a.client_ips.is_empty() || b.client_ips.is_empty() {
        // 任一侧不限客户端 ⇒ 该维度必然可能重叠，交由其它维度判定。
        // （两侧都为空也落在这里，因此不需要单独的分支。）
        true
    } else {
        str_overlap(&a.client_ips, &b.client_ips)
            || a.client_ips
                .iter()
                .any(|x| b.client_ips.iter().any(|y| cidr_overlap(x, y)))
    };
    let ports = if a.ports.is_empty() || b.ports.is_empty() {
        true
    } else {
        a.ports
            .iter()
            .any(|x| b.ports.iter().any(|y| port_overlap(x, y)))
    };
    // 只有「一个只认 TCP、另一个只认 UDP」时才可确定不重叠；其余组合都可能在协议维度上重叠。
    let proto = !matches!(
        (a.proto, b.proto),
        (ProtoFilter::Tcp, ProtoFilter::Udp) | (ProtoFilter::Udp, ProtoFilter::Tcp)
    );
    targets && clients && ports && proto
}

/// 网段是否重叠（支持裸 IP 视为 /32 或 /128）。
fn cidr_overlap(x: &str, y: &str) -> bool {
    fn to_net(s: &str) -> Option<(u128, u32, bool)> {
        let (addr, len) = match s.split_once('/') {
            Some((a, l)) => (a.parse::<IpAddr>().ok()?, l.parse::<u32>().ok()?),
            None => {
                let a: IpAddr = s.parse().ok()?;
                let max = if a.is_ipv6() { 128 } else { 32 };
                (a, max)
            }
        };
        let v6 = addr.is_ipv6();
        let bits = match addr {
            IpAddr::V4(v4) => u128::from(u32::from(v4)),
            IpAddr::V6(v6a) => u128::from_be_bytes(v6a.octets()),
        };
        Some((bits, len, v6))
    }
    let Some((a, al, a6)) = to_net(x) else {
        return false;
    };
    let Some((b, bl, b6)) = to_net(y) else {
        return false;
    };
    if a6 != b6 {
        return false;
    }
    let width: u32 = if a6 { 128 } else { 32 };
    let mask = |len: u32| -> u128 {
        if len == 0 {
            0
        } else {
            (!0u128) << (width.saturating_sub(len))
        }
    };
    let shorter = al.min(bl);
    (a & mask(shorter)) == (b & mask(shorter))
}

fn port_overlap(x: &str, y: &str) -> bool {
    let (Some(a), Some(b)) = (
        super::schema::parse_port_range(x),
        super::schema::parse_port_range(y),
    ) else {
        return false;
    };
    a.start <= b.end && b.start <= a.end
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::schema::*;

    fn base() -> Config {
        let mut c = Config::default();
        c.global.enabled = true;
        c.global.primary = "wan".into();
        c.wans = vec![
            WanConfig {
                name: "wan".into(),
                priority: 10,
                probe_targets: vec!["1.1.1.1".into(), "8.8.8.8".into()],
                ..Default::default()
            },
            WanConfig {
                name: "wan2".into(),
                priority: 20,
                probe_targets: vec!["9.9.9.9".into()],
                ..Default::default()
            },
        ];
        c.global.backup_order = vec!["wan2".into()];
        c
    }

    #[test]
    fn default_disabled_config_is_valid() {
        let c = Config::default();
        let r = validate(&c);
        // 未启用且无线路：不应有致命错误（安装后即是这个状态）
        assert!(r.is_valid(), "错误: {:?}", r.errors());
    }

    #[test]
    fn healthy_config_passes_with_no_errors() {
        let r = validate(&base());
        assert!(r.is_valid(), "不应有错误: {:?}", r.errors());
    }

    #[test]
    fn enabled_without_any_wan_is_fatal() {
        let mut c = base();
        c.global.enabled = true;
        c.wans.clear();
        c.global.primary = String::new();
        c.global.backup_order.clear();
        let r = validate(&c);
        assert!(!r.is_valid());
        assert!(r.errors().iter().any(|i| i.path.contains("enabled")));
    }

    #[test]
    fn rejects_injection_attempt_in_names() {
        let mut c = base();
        for bad in [
            "wan;rm -rf /",
            "wan' or '1'='1",
            "-wan",
            "wan\nrm",
            "wan$(id)",
            "",
        ] {
            c.wans[0].name = bad.into();
            let r = validate(&c);
            assert!(!r.is_valid(), "非法段名未被拒绝: {bad:?}");
        }
        // 正常名称通过
        c.wans[0].name = "wan_2.0-1".into();
        assert!(validate(&c).is_valid());
    }

    #[test]
    fn rejects_ifname_longer_than_ifnamsiz() {
        let mut c = base();
        c.wans[0].device = "a".repeat(16);
        assert!(!validate(&c).is_valid());
        c.wans[0].device = "a".repeat(15);
        assert!(validate(&c).is_valid());
    }

    #[test]
    fn timeout_must_be_smaller_than_interval() {
        let mut c = base();
        c.global.health.interval_ms = 1000;
        c.global.health.timeout_ms = 1200;
        let r = validate(&c);
        assert!(!r.is_valid());
        assert!(r.errors().iter().any(|i| i.path.ends_with("timeout_ms")));
    }

    #[test]
    fn zero_division_fields_rejected() {
        let mut c = base();
        c.score.rtt_norm_ms = 0;
        assert!(!validate(&c).is_valid());
        let mut c2 = base();
        c2.score.rtt = 0;
        c2.score.jitter = 0;
        c2.score.loss = 0;
        c2.score.instability = 0;
        assert!(!validate(&c2).is_valid(), "权重全 0 应报错");
    }

    #[test]
    fn duplicate_and_missing_wan_refs_are_errors() {
        let mut c = base();
        c.wans.push(WanConfig {
            name: "wan".into(),
            ..Default::default()
        });
        assert!(validate(&c)
            .errors()
            .iter()
            .any(|i| i.message.contains("重复")));

        let mut c2 = base();
        c2.global.backup_order = vec!["ghost".into()];
        assert!(!validate(&c2).is_valid(), "不存在的备用线路必须报错");

        let mut c3 = base();
        c3.global.backup_order.push("wan".into());
        assert!(
            !validate(&c3).is_valid(),
            "主线路不能同时出现在 backup_order"
        );
    }

    #[test]
    fn primary_role_must_be_unique() {
        let mut c = base();
        c.wans[1].role = WanRole::Primary;
        c.wans[0].role = WanRole::Primary;
        assert!(validate(&c)
            .errors()
            .iter()
            .any(|i| i.message.contains("primary")));
    }

    #[test]
    fn game_rule_requires_some_matcher() {
        let mut c = base();
        c.games.push(GameRule {
            name: "empty".into(),
            ..Default::default()
        });
        let r = validate(&c);
        assert!(!r.is_valid(), "无匹配条件的启用规则必须报错");
        assert!(r.errors().iter().any(|i| i.path.contains("targets")));
    }

    #[test]
    fn game_rule_rejects_default_route_target() {
        let mut c = base();
        c.games.push(GameRule {
            name: "bad".into(),
            targets: vec!["0.0.0.0/0".into()],
            ..Default::default()
        });
        assert!(!validate(&c).is_valid());
    }

    #[test]
    fn game_rule_pin_validation() {
        let mut c = base();
        c.games.push(GameRule {
            name: "pin".into(),
            targets: vec!["203.0.113.7".into()],
            selection: GameSelection::Pin,
            pin_wan: String::new(),
            ..Default::default()
        });
        assert!(!validate(&c).is_valid(), "pin 必须指定线路");
        c.games[0].pin_wan = "ghost".into();
        assert!(!validate(&c).is_valid(), "pin 目标必须存在");
        c.games[0].pin_wan = "wan2".into();
        assert!(validate(&c).is_valid());
    }

    #[test]
    fn strict_failover_warns_about_game_exception() {
        // 任务书要求 UI 能明确展示「备用线路不会承担游戏流量」
        let mut c = base();
        c.global.mode = Mode::Failover;
        c.global.game_policy = GamePolicy::Follow;
        c.games.push(GameRule {
            name: "best".into(),
            targets: vec!["198.51.100.0/24".into()],
            selection: GameSelection::Best,
            ..Default::default()
        });
        let r = validate(&c);
        assert!(r.is_valid());
        assert!(
            r.warnings()
                .iter()
                .any(|i| i.message.contains("仍只走主线路")),
            "{:?}",
            r.warnings()
        );
    }

    #[test]
    fn same_priority_overlapping_rules_warn() {
        let mut c = base();
        c.games.push(GameRule {
            name: "a".into(),
            targets: vec!["203.0.113.0/24".into()],
            priority: 10,
            ..Default::default()
        });
        c.games.push(GameRule {
            name: "b".into(),
            targets: vec!["203.0.113.5".into()],
            priority: 10,
            ..Default::default()
        });
        let r = validate(&c);
        assert!(
            r.warnings()
                .iter()
                .any(|i| i.message.contains("优先级相同")),
            "{:?}",
            r.warnings()
        );
    }

    #[test]
    fn cidr_overlap_detects_families() {
        assert!(cidr_overlap("10.0.0.0/8", "10.1.2.3"));
        assert!(!cidr_overlap("10.0.0.0/8", "11.0.0.1"));
        assert!(!cidr_overlap("10.0.0.0/8", "fe80::1"), "跨族不得判为重叠");
        assert!(cidr_overlap("fe80::/10", "fe80::abcd"));
        assert!(!cidr_overlap("bad", "10.0.0.0/8"));
    }

    #[test]
    fn mac_and_domain_and_path_checks() {
        assert!(valid_mac("aa:bb:cc:dd:ee:ff"));
        assert!(valid_mac("AA-BB-CC-DD-EE-FF"));
        assert!(valid_mac("aabb.ccdd.eeff"));
        assert!(!valid_mac("aa:bb:cc:dd:ee"));
        assert!(!valid_mac("gg:bb:cc:dd:ee:ff"));
        assert!(valid_domain("gamer-srv.example.com"));
        assert!(!valid_domain("nodots"));
        assert!(!valid_domain("-bad.example.com"));
        assert!(!valid_domain(""));
        assert!(valid_abs_path("/var/run/smartmwan/rpc.sock"));
        assert!(!valid_abs_path("relative/path"));
        assert!(!valid_abs_path("/etc/../etc/passwd"));
        assert!(!valid_abs_path("/tmp/log\nrm"));
    }

    #[test]
    fn protected_src_is_validated() {
        let mut c = base();
        c.global.protected_src = vec!["not-a-cidr".into()];
        let r = validate(&c);
        assert!(!r.is_valid());
        assert!(r
            .errors()
            .iter()
            .any(|i| i.path.contains("protected_src[0]")));
    }

    #[test]
    fn bypass_default_route_guard() {
        let mut c = base();
        c.global.bypass_dst = vec!["0.0.0.0/0".into()];
        assert!(!validate(&c).is_valid(), "绕过全部流量必须拒绝");
    }

    #[test]
    fn buckets_out_of_range() {
        let mut c = base();
        c.global.buckets = 1;
        assert!(!validate(&c).is_valid());
        c.global.buckets = marks::BUCKETS + 1;
        assert!(!validate(&c).is_valid());
    }

    #[test]
    fn port_overlap_and_format() {
        assert!(port_overlap("8000-8100", "8050"));
        assert!(!port_overlap("80", "443"));
        assert!(!port_overlap("abc", "443"));
    }
}

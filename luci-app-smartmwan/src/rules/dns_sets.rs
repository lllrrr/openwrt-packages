//! 域名规则 → 动态 nft 集合。
//!
//! # 为什么这是一个「近似」特性，以及近似在哪里
//!
//! 用域名决定路由，本质上是拿 **DNS 的答案** 去猜 **应用实际会连的地址**。
//! 这中间的差距必须写清楚，否则用户会以为「填了域名就等于长期拦住这个游戏」：
//!
//! 1. **TTL 拿不到**。`getaddrinfo` 只返回地址，不返回 TTL（本模块用的就是这条路）。
//!    因此元素寿命取配置值 `dns_ttl_floor_s`，而不是权威 TTL：
//!    TTL 比它短时，我们的元素会比真实记录多留一会儿（可能连到已回收的 IP）；
//!    TTL 比它长时，会提前过期并触发一次重新解析（多一次 DNS 查询）。
//! 2. **CDN / anycast**。同一个域名在不同时间、不同递归解析器上返回不同地址，
//!    而且地址池可能几百个。集合上限到顶时会丢弃并计数，界面必须显示丢弃数，
//!    不能显示「已生效」。
//! 3. **DoH / DoT / 加密 DNS**。应用绕过路由器做解析时，我们看到的只是 DNS 服务器
//!    的地址，猜不到游戏服务器。此时域名规则事实上无效，只能靠网段预置项。
//! 4. **IPv6**。当前动态集合是 `ipv4_addr`（`firewall.rs` 里声明），
//!    AAAA 记录被**计数并明确报告**，不是悄悄丢掉。
//! 5. **SNI / 应用层**。我们不看 TLS SNI，不做 DPI，只按目的 IP 匹配。
//! 6. **解析失败**。域名解析失败 **不是线路故障**：它按 `ProbeReply`/`Timeout`
//!    的分类一样归为 `LocalError`/`Unsupported` 类事件，只影响该域名的集合更新。
//!    失败期间**保留旧元素直到自然过期**，因为清空集合会让本来正常的分流突然失效。
//!
//! # 本模块的边界
//!
//! [`Registry`] 是纯逻辑：进（解析结果）/出（集合增量）都可单测，不碰网络、不碰内核。
//! 真实的 [`resolve`] 只是 `getaddrinfo` 的一层带超时封装，由守护进程在独立任务里调用
//! （不能在决策循环里同步解析，否则 DNS 一慢就把整轮调度拖住）。

use std::collections::BTreeMap;
use std::net::{IpAddr, ToSocketAddrs};
use std::time::Duration;

use crate::{Error, Result};

/// 元素寿命下限（秒）。没有真实 TTL 时的默认值。
pub const DEFAULT_TTL_FLOOR_S: u64 = 300;
/// 元素寿命上限（秒）：再长就等于是「永久条目」，与动态集合的意图相反。
pub const MAX_TTL_CAP_S: u64 = 86_400;
/// 单条规则可配的域名数量上限（集合数量与解析次数都要有上界）。
pub const MAX_DOMAINS_PER_RULE: usize = 32;
/// 单个域名最多采纳的地址数（CDN 一次返回几百条时截断，并计入 `truncated`）。
pub const MAX_ADDRESSES_PER_DOMAIN: usize = 32;
/// 集合元素总量默认上限，与 `firewall::DYNAMIC_SET_SIZE` 同阶。
pub const DEFAULT_MAX_ELEMENTS: usize = 1024;

/// 一条集合元素。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub domain: String,
    /// 规范化后的地址文本（IPv4 点分十进制）。
    pub elem: String,
    /// 本次插入/刷新的时刻（单调毫秒）。
    pub refreshed_ms: u64,
    /// 过期时刻（单调毫秒）。
    pub expires_ms: u64,
}

/// 一次「按域名对账」产生的集合增量。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Diff {
    /// 需要 `add element` 的地址文本。
    pub added: Vec<String>,
    /// 需要 `delete element` 的地址文本（含自然过期与该域名已被删除的旧地址）。
    pub removed: Vec<String>,
    /// 已存在且本轮刷新的地址数。
    pub kept: usize,
    /// 被跳过的 AAAA 记录数（IPv6 未进集合，必须显示）。
    pub v6_skipped: usize,
    /// 因为集合已满而被丢弃的地址数。
    pub rejected_full: usize,
    /// 因为超过单域名地址上限而被截断的地址数。
    pub truncated: usize,
}

impl Diff {
    pub fn is_noop(&self) -> bool {
        self.added.is_empty() && self.removed.is_empty()
    }
}

/// 解析失败的种类。**没有任何一种会被当成线路故障。**
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolveError {
    /// NXDOMAIN / 无记录。
    NotFound,
    /// 解析超时（递归服务器不响应、被墙、DNS 抢重拨期间）。
    Timeout,
    /// 本机原因：无 resolv.conf、socket 错误、线程池不可用。
    LocalError(String),
}

impl std::fmt::Display for ResolveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ResolveError::NotFound => f.write_str("域名无解析结果（NXDOMAIN 或无 A 记录）"),
            ResolveError::Timeout => f.write_str("域名解析超时"),
            ResolveError::LocalError(s) => f.write_str(s),
        }
    }
}

/// 注册表统计，供 UI 如实显示。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Stats {
    pub elements: usize,
    pub domains: usize,
    /// 累计因集合满被丢弃的次数（不是「本次」，长跑要看趋势）。
    pub rejected_total: u64,
    /// 累计解析失败次数，按种类。
    pub failed_notfound: u64,
    pub failed_timeout: u64,
    pub failed_local: u64,
    /// 最近一次成功解析每个域名的时刻是否已落后于 TTL（陈旧标记）。
    pub stale_domains: usize,
}

/// 域名→地址集合的账本。
#[derive(Debug, Clone)]
pub struct Registry {
    ttl: Duration,
    max_elements: usize,
    entries: BTreeMap<String, Entry>,
    /// 每个域名最近一次成功对账的时刻，用于「多久没更新了」。
    last_seen: BTreeMap<String, u64>,
    /// 连续解析失败次数（成功即清零）；用于把「一直解析不了」如实报出来。
    fails: BTreeMap<String, u32>,
    stats: Stats,
}

impl Registry {
    pub fn new(ttl: Duration, max_elements: usize) -> Self {
        // 下限夹取：0 秒寿命的元素加进去就过期，等价于什么都没加，
        // 但会把解析负载变成「每轮都重解」，这是配置写错时最坏的放大。
        let ttl = ttl
            .max(Duration::from_secs(30))
            .min(Duration::from_secs(MAX_TTL_CAP_S));
        Registry {
            ttl,
            max_elements: max_elements.max(1),
            entries: BTreeMap::new(),
            last_seen: BTreeMap::new(),
            fails: BTreeMap::new(),
            stats: Stats::default(),
        }
    }

    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    pub fn entries(&self) -> impl Iterator<Item = &Entry> {
        self.entries.values()
    }

    pub fn elements(&self) -> Vec<String> {
        self.entries.keys().cloned().collect()
    }

    pub fn stats(&self) -> Stats {
        let mut s = self.stats.clone();
        s.elements = self.entries.len();
        s.domains = self.last_seen.len();
        s
    }

    /// 某个域名的连续失败次数（0 表示最近一次是成功的）。
    pub fn fail_count(&self, domain: &str) -> u32 {
        self.fails.get(domain).copied().unwrap_or(0)
    }

    /// 距上次成功对账过去了多久；从未成功过返回 `None`（UI 显示「尚未解析成功」）。
    pub fn age_ms(&self, domain: &str, now_ms: u64) -> Option<u64> {
        self.last_seen
            .get(domain)
            .map(|t| now_ms.saturating_sub(*t))
    }

    /// 把某个域名的解析结果对账进集合。
    ///
    /// 语义是**该域名范围内**的替换：本轮答案里没有的地址会被删掉
    /// （其它域名的地址不受影响）。这与「只增不删」的做法相比，
    /// CDN 换址后不会留下越积越多的僵尸元素。
    ///
    /// `ttl_hint` 留给将来接入真实 TTL 的解析器；现在恒为 `None` ⇒ 用注册表的寿命。
    pub fn observe(
        &mut self,
        domain: &str,
        addrs: &[IpAddr],
        ttl_hint: Option<Duration>,
        now_ms: u64,
    ) -> Diff {
        let mut d = Diff::default();
        let life = ttl_hint.unwrap_or(self.ttl).max(Duration::from_secs(30));
        let life_ms = u64::try_from(life.as_millis()).unwrap_or(u64::MAX / 2);
        let expires = now_ms.saturating_add(life_ms);

        // 先把本域名的地址收集出来（含 IPv6 计数）。
        let mut wanted: Vec<String> = Vec::new();
        for a in addrs {
            match a {
                IpAddr::V4(v4) => wanted.push(v4.to_string()),
                IpAddr::V6(_) => d.v6_skipped += 1,
            }
        }
        if wanted.len() > MAX_ADDRESSES_PER_DOMAIN {
            d.truncated = wanted.len() - MAX_ADDRESSES_PER_DOMAIN;
            wanted.truncate(MAX_ADDRESSES_PER_DOMAIN);
        }
        wanted.sort();
        wanted.dedup();

        // 删除：属于本域名、但不在本轮答案里的元素。
        let doomed: Vec<String> = self
            .entries
            .iter()
            .filter(|(_, e)| e.domain == domain)
            .map(|(k, _)| k.clone())
            .filter(|k| !wanted.contains(k))
            .collect();
        for k in &doomed {
            self.entries.remove(k);
        }
        d.removed.extend(doomed);

        // 新增/刷新。
        for w in wanted {
            match self.entries.get_mut(&w) {
                Some(e) => {
                    // 已被别的域名占用：不抢，直接记为保留。
                    // 两个域名解析到同一个 IP 是常态（同台机器多个服务名），
                    // 抢过来只会让「删掉一个域名」时误删另一个域名还要的元素。
                    e.refreshed_ms = now_ms;
                    e.expires_ms = e.expires_ms.max(expires);
                    d.kept += 1;
                }
                None => {
                    if self.entries.len() >= self.max_elements {
                        d.rejected_full += 1;
                        self.stats.rejected_total += 1;
                        continue;
                    }
                    self.entries.insert(
                        w.clone(),
                        Entry {
                            domain: domain.to_string(),
                            elem: w.clone(),
                            refreshed_ms: now_ms,
                            expires_ms: expires,
                        },
                    );
                    d.added.push(w);
                }
            }
        }
        d.added.sort();
        d.removed.sort();
        self.last_seen.insert(domain.to_string(), now_ms);
        self.fails.insert(domain.to_string(), 0);
        d
    }

    /// 记录一次解析失败：**不动集合**。
    pub fn note_failure(&mut self, domain: &str, err: &ResolveError) {
        let n = self.fails.entry(domain.to_string()).or_insert(0);
        *n = n.saturating_add(1);
        match err {
            ResolveError::NotFound => self.stats.failed_notfound += 1,
            ResolveError::Timeout => self.stats.failed_timeout += 1,
            ResolveError::LocalError(_) => self.stats.failed_local += 1,
        }
    }

    /// 该域名已被删除（规则停用/改掉）：清掉它名下的全部元素。
    pub fn forget_domain(&mut self, domain: &str) -> Vec<String> {
        self.last_seen.remove(domain);
        self.fails.remove(domain);
        let doomed: Vec<String> = self
            .entries
            .iter()
            .filter(|(_, e)| e.domain == domain)
            .map(|(k, _)| k.clone())
            .collect();
        for k in &doomed {
            self.entries.remove(k);
        }
        doomed
    }

    /// 过期清扫：返回需要 `delete element` 的地址。
    ///
    /// 注意内核动态集合本身带 `timeout`，会自己老化；这里的清扫是为了
    /// **账本与内核一致**（否则 `elements()` 会把已老化地址当成还在）。
    /// 两边都做是冗余但安全的：少做一边会让账本和真实集合长期不一致。
    pub fn expire(&mut self, now_ms: u64) -> Vec<String> {
        let doomed: Vec<String> = self
            .entries
            .iter()
            .filter(|(_, e)| e.expires_ms <= now_ms)
            .map(|(k, _)| k.clone())
            .collect();
        for k in &doomed {
            self.entries.remove(k);
        }
        doomed
    }

    /// 标记「距离上次成功已超过 2 个寿命」的域名（真的解析不上时 UI 要能说清）。
    pub fn refresh_stale(&mut self, now_ms: u64) {
        let window = u64::try_from(self.ttl.as_millis())
            .unwrap_or(u64::MAX / 2)
            .saturating_mul(2);
        let stale = self
            .last_seen
            .iter()
            .filter(|(_, t)| now_ms.saturating_sub(**t) > window)
            .count();
        self.stats.stale_domains = stale;
    }

    /// 校验规则里的域名列表（数量上限在这里判，避免解析任务被无限放大）。
    pub fn check_domain_budget(domains: &[String]) -> Result<()> {
        if domains.len() > MAX_DOMAINS_PER_RULE {
            return Err(Error::Config(format!(
                "单条规则的域名数量 {} 超过上限 {MAX_DOMAINS_PER_RULE}",
                domains.len()
            )));
        }
        Ok(())
    }
}

/// 真实解析：`getaddrinfo` 的带超时封装。
///
/// 用 `spawn_blocking` 是因为 std 的解析是阻塞调用，放进 async 上下文会占住工作线程；
/// 超时只放弃等待（阻塞线程仍会跑完），这是 std 解析的固有代价，
/// 因此调用方必须保证这条路径在独立任务里、且有并发额度。
pub async fn resolve(
    domain: &str,
    timeout: Duration,
) -> std::result::Result<Vec<IpAddr>, ResolveError> {
    let host = domain.to_string();
    let job = tokio::task::spawn_blocking(move || (host.as_str(), 0u16).to_socket_addrs());
    let joined = match tokio::time::timeout(timeout, job).await {
        Ok(Ok(r)) => r,
        Ok(Err(_)) => {
            return Err(ResolveError::LocalError(
                "解析任务被丢弃（阻塞线程池不可用）".into(),
            ))
        }
        Err(_) => return Err(ResolveError::Timeout),
    };
    match joined {
        // `to_socket_addrs` 可能成功返回空迭代器（只有 AAAA 而无 A 时也算有结果，
        // 由 observe 计入 v6_skipped）。真正的空结果按 NotFound 报，
        // 因为「解析成功但一条都没有」和「解析失败」在 UI 上是两件事。
        Ok(iter) => {
            let v: Vec<IpAddr> = iter.map(|sa| sa.ip()).collect();
            if v.is_empty() {
                Err(ResolveError::NotFound)
            } else {
                Ok(v)
            }
        }
        Err(e) => Err(ResolveError::LocalError(format!("解析 {domain} 失败：{e}"))),
    }
}

/// 供决策侧使用的最小聚合：把多个域名的解析结果合并成一个 `Diff` 序列。
///
/// 单独放一个函数是为了让「解析顺序不影响结果」这件事有测试：
/// 域名按字典序处理，同一份答案无论以什么顺序到达，集合内容都一致。
pub fn observe_all(
    reg: &mut Registry,
    answers: &BTreeMap<String, Vec<IpAddr>>,
    now_ms: u64,
) -> Vec<(String, Diff)> {
    let mut out = Vec::new();
    for (domain, addrs) in answers {
        // 域名在这里已经清洗过，但仍按 `matchers` 的规则再校验一次字符集：
        // 解析结果进的是内核集合名与 comment，任何奇怪字符都必须在这一层被挡住。
        let Ok(d) = crate::rules::matchers::normalize_domain(domain) else {
            continue;
        };
        out.push((d.clone(), reg.observe(&d, addrs, None, now_ms)));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    fn v4(s: &str) -> IpAddr {
        IpAddr::V4(s.parse::<Ipv4Addr>().unwrap())
    }
    fn v6(s: &str) -> IpAddr {
        IpAddr::V6(s.parse::<Ipv6Addr>().unwrap())
    }

    fn reg() -> Registry {
        Registry::new(Duration::from_secs(300), 4)
    }

    #[test]
    fn ttl_is_clamped_not_trusted() {
        // 0 秒寿命会被抬到 30 秒：否则元素加进去即过期，等于把解析频率放大到每轮。
        assert_eq!(
            Registry::new(Duration::ZERO, 8).ttl(),
            Duration::from_secs(30)
        );
        assert_eq!(
            Registry::new(Duration::from_secs(999_999), 8).ttl(),
            Duration::from_secs(MAX_TTL_CAP_S)
        );
        assert_eq!(
            Registry::new(Duration::from_secs(300), 8).ttl(),
            Duration::from_secs(300)
        );
    }

    #[test]
    fn observe_adds_and_refreshes() {
        let mut r = reg();
        let d = r.observe("a.example", &[v4("1.2.3.4"), v4("1.2.3.5")], None, 1000);
        assert_eq!(d.added, vec!["1.2.3.4".to_string(), "1.2.3.5".to_string()]);
        assert!(d.removed.is_empty());
        // 同样的答案第二次：无增量（幂等 —— 高频轮询下不产生内核写入）。
        let d2 = r.observe("a.example", &[v4("1.2.3.4"), v4("1.2.3.5")], None, 2000);
        assert!(d2.is_noop(), "{d2:?}");
        assert_eq!(d2.kept, 2);
        assert_eq!(r.elements().len(), 2);
    }

    #[test]
    fn answer_change_removes_only_that_domains_stale_addrs() {
        let mut r = reg();
        r.observe("a.example", &[v4("1.2.3.4")], None, 1000);
        r.observe("b.example", &[v4("9.9.9.9")], None, 1000);
        let d = r.observe("a.example", &[v4("1.2.3.9")], None, 2000);
        assert_eq!(d.removed, vec!["1.2.3.4".to_string()]);
        assert_eq!(d.added, vec!["1.2.3.9".to_string()]);
        assert!(
            r.elements().contains(&"9.9.9.9".to_string()),
            "别的域名的地址不能被牵连"
        );
    }

    #[test]
    fn shared_ip_is_not_reassigned_between_domains() {
        let mut r = reg();
        r.observe("a.example", &[v4("1.1.1.1")], None, 1000);
        let d = r.observe("b.example", &[v4("1.1.1.1")], None, 2000);
        assert_eq!(d.kept, 1, "同一 IP 被两个域名解析到时不重复计入");
        assert_eq!(r.elements().len(), 1);
        // 删掉 a 会把该地址带走（所有权仍是先到的 a），这是当前实现的已知边界：
        // 宁可多删一个元素（下轮 b 会重新加上），也不做「一个元素多个主人」的引用计数，
        // 因为引用计数错一次的后果是内核里留下永久僵尸元素。
        let gone = r.forget_domain("a.example");
        assert_eq!(gone, vec!["1.1.1.1".to_string()]);
        assert!(r.elements().is_empty());
    }

    #[test]
    fn ipv6_is_counted_not_dropped_silently() {
        let mut r = reg();
        let d = r.observe("a.example", &[v4("1.2.3.4"), v6("2001:db8::1")], None, 1000);
        assert_eq!(d.v6_skipped, 1, "AAAA 必须被计数并可被 UI 报告");
        assert_eq!(r.elements(), vec!["1.2.3.4".to_string()]);
    }

    #[test]
    fn capacity_rejects_and_counts() {
        let mut r = Registry::new(Duration::from_secs(300), 2);
        let d = r.observe(
            "a.example",
            &[v4("1.1.1.1"), v4("1.1.1.2"), v4("1.1.1.3")],
            None,
            1000,
        );
        assert_eq!(d.added.len(), 2);
        assert_eq!(d.rejected_full, 1);
        assert_eq!(r.stats().rejected_total, 1);
        // 被丢弃不是错误：集合到顶时拒多是保护，但必须能被人看见。
        assert_eq!(r.elements().len(), 2);
    }

    #[test]
    fn per_domain_cap_truncates_and_counts() {
        let many: Vec<IpAddr> = (1..=(MAX_ADDRESSES_PER_DOMAIN + 5))
            .map(|i| v4(&format!("10.0.{i}.1")))
            .collect();
        let mut r = Registry::new(Duration::from_secs(300), 1000);
        let d = r.observe("cdn.example", &many, None, 1000);
        assert_eq!(d.truncated, 5, "超过单域名上限的部分必须被计数");
        assert_eq!(d.added.len(), MAX_ADDRESSES_PER_DOMAIN);
    }

    #[test]
    fn expiry_removes_and_reports() {
        let mut r = Registry::new(Duration::from_secs(300), 8);
        r.observe("a.example", &[v4("1.2.3.4")], None, 0);
        assert!(r.expire(299_000).is_empty(), "未到寿命不能过期");
        let gone = r.expire(301_000);
        assert_eq!(gone, vec!["1.2.3.4".to_string()]);
        assert!(r.elements().is_empty());
    }

    #[test]
    fn ttl_hint_extends_within_cap() {
        let mut r = Registry::new(Duration::from_secs(300), 8);
        r.observe(
            "a.example",
            &[v4("1.2.3.4")],
            Some(Duration::from_secs(3600)),
            0,
        );
        assert!(
            r.expire(301_000).is_empty(),
            "hint 比默认寿命长时应活得更久"
        );
        let gone = r.expire(3_601_000);
        assert_eq!(gone, vec!["1.2.3.4".to_string()]);
    }

    #[test]
    fn failure_keeps_entries_and_is_counted_as_local_not_line_fault() {
        let mut r = reg();
        r.observe("a.example", &[v4("1.2.3.4")], None, 1000);
        r.note_failure("a.example", &ResolveError::Timeout);
        r.note_failure("a.example", &ResolveError::NotFound);
        // 关键：解析失败期间元素保留（清空会让本来正常的分流突然失效）。
        assert_eq!(r.elements(), vec!["1.2.3.4".to_string()]);
        assert_eq!(r.fail_count("a.example"), 2);
        let s = r.stats();
        assert_eq!(s.failed_timeout, 1);
        assert_eq!(s.failed_notfound, 1);
        // 成功后计数清零。
        r.observe("a.example", &[v4("1.2.3.4")], None, 2000);
        assert_eq!(r.fail_count("a.example"), 0);
    }

    #[test]
    fn never_resolved_reports_none_age() {
        let mut r = reg();
        r.note_failure("x.example", &ResolveError::NotFound);
        assert_eq!(
            r.age_ms("x.example", 5000),
            None,
            "从未解析成功不能谎报「多久没更新」"
        );
        r.observe("x.example", &[v4("2.2.2.2")], None, 5000);
        assert_eq!(r.age_ms("x.example", 8000), Some(3000));
    }

    #[test]
    fn stale_flag_needs_two_lives_of_silence() {
        let mut r = Registry::new(Duration::from_secs(300), 8);
        r.observe("a.example", &[v4("1.2.3.4")], None, 0);
        r.refresh_stale(400_000);
        assert_eq!(r.stats().stale_domains, 0, "1.3 个寿命还不算陈旧");
        r.refresh_stale(700_000);
        assert_eq!(r.stats().stale_domains, 1);
    }

    #[test]
    fn observe_all_is_order_independent() {
        let mut a = BTreeMap::new();
        a.insert("a.example".to_string(), vec![v4("1.1.1.1")]);
        a.insert("b.example".to_string(), vec![v4("2.2.2.2")]);
        let mut r = reg();
        let out = observe_all(&mut r, &a, 1000);
        assert_eq!(
            out.iter().map(|(d, _)| d.as_str()).collect::<Vec<_>>(),
            vec!["a.example", "b.example"]
        );
        assert_eq!(
            r.elements(),
            vec!["1.1.1.1".to_string(), "2.2.2.2".to_string()]
        );
        // 非法域名被丢弃而不是污染集合名。
        let mut bad = BTreeMap::new();
        bad.insert("*.example.com".to_string(), vec![v4("3.3.3.3")]);
        let mut r2 = reg();
        assert!(observe_all(&mut r2, &bad, 1000).is_empty());
        assert!(r2.elements().is_empty());
    }

    #[test]
    fn domain_budget_enforced() {
        let ok: Vec<String> = (0..MAX_DOMAINS_PER_RULE)
            .map(|i| format!("a{i}.example"))
            .collect();
        assert!(Registry::check_domain_budget(&ok).is_ok());
        let mut too = ok;
        too.push("extra.example".into());
        assert!(Registry::check_domain_budget(&too).is_err());
    }

    #[tokio::test]
    async fn resolve_timeout_is_not_a_line_failure() {
        // 一个不会响应的名字 + 极短超时：必须归为 Timeout，而不是「线路坏了」。
        // 这里不依赖外网：端口 0 的名字解析在一个不存在的 .invalid 域上应当快速失败或超时。
        let e = resolve(
            "definitely-not-a-real-host.invalid",
            Duration::from_millis(50),
        )
        .await;
        match e {
            Err(ResolveError::Timeout)
            | Err(ResolveError::NotFound)
            | Err(ResolveError::LocalError(_)) => {}
            Ok(v) => panic!("沙箱里不应该解析成功：{v:?}"),
        }
    }
}

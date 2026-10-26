//! conntrack 观测：按标记统计并发连接数，读取跟踪表容量。
//!
//! 为什么不用 `conntrack` crate / `ctnetlink`：
//! * 只需要「每个槽位多少条连接」和一个总数，`/proc` 一次顺序扫描就够；
//! * ctnetlink 需要 `RTNLGRP_*` 组订阅与更复杂的属性解析，收益不匹配复杂度；
//! * 采集频率由上层节流（默认与 `sample_window_ms` 同量级），不做事件驱动。
//!
//! 注意：`/proc/net/nf_conntrack` 只有在 `CONFIG_NF_CONNTRACK_MARK=y` 且
//! 挂载了 mark 时才有意义；内核打印的 mark 可能是 `0x` 十六进制也可能是十进制，
//! 两种都按同一函数解析，避免「读到 0 就以为没有标记」这种误判。

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use crate::marks;
use crate::{logging, Error, Result};

/// 单次扫描最多读取的行数。conntrack 表在极端 DDOS 下可能非常大，
/// 守护进程不能被一次观测拖死；超过上限就只统计已读部分并明确标记「不完整」。
pub const MAX_LINES: usize = 250_000;

/// 一次扫描的结果。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Counts {
    /// 扫描到的（本插件相关 + 外来）连接条目总数，不含被截断的部分。
    pub total: u64,
    /// 槽位 → 并发连接数（只统计本插件标记）。
    pub per_slot: BTreeMap<u8, u64>,
    /// 带标记但不属于本插件的连接数（共存可观测性）。
    pub foreign: u64,
    /// 无标记（未经过策略路由）的连接数。
    pub unmarked: u64,
    /// 是否因达到 `MAX_LINES` 提前结束。为真时上层必须说明数据不完整，
    /// 不能把「偏少的计数」当成真实负载去做均衡决策。
    pub truncated: bool,
    /// 采集时刻（毫秒），供上层做差值/速率。
    pub at_ms: u64,
}

impl Counts {
    pub fn of_slot(&self, slot: u8) -> u64 {
        self.per_slot.get(&slot).copied().unwrap_or(0)
    }

    /// 本插件标记的连接总数。
    pub fn owned(&self) -> u64 {
        self.per_slot.values().sum()
    }

    /// 与上一帧的比较：用于「最少新建连接」与饱和判断。
    ///
    /// 并发连接数不是「新建速率」，这里返回的是同一槽位的增减量，
    /// 上层（scheduler）负责把它平滑成速率，不能直接当速率展示给用户。
    pub fn growth_since(&self, prev: &Counts) -> BTreeMap<u8, i64> {
        let mut out = BTreeMap::new();
        for (slot, cur) in &self.per_slot {
            let before = prev.of_slot(*slot) as i64;
            out.insert(*slot, *cur as i64 - before);
        }
        for (slot, before) in &prev.per_slot {
            out.entry(*slot).or_insert(-(*before as i64));
        }
        out
    }

    /// 人类可读摘要，进 RPC `get_status` 的连接字段。
    pub fn summary(&self) -> String {
        format!(
            "已标记 {} 条（外 {} 条），未标记 {} 条，跟踪总数 {} 条{}",
            self.owned(),
            self.foreign,
            self.unmarked,
            self.total,
            if self.truncated {
                "（达扫描上限，数据不完整）"
            } else {
                ""
            }
        )
    }
}

/// 解析一行 `/proc/net/nf_conntrack`。
///
/// 返回 `None` 表示该行没有可用标记字段（例如内核未开 `NF_CONNTRACK_MARK`），
/// 调用方据此把「无法统计」与「统计到 0」区分开 —— 这两件事对运维完全不同。
pub fn parse_mark_field(line: &str) -> Option<u32> {
    let rest = line.split("mark=").nth(1)?;
    let tok: String = rest
        .chars()
        .take_while(|c| !c.is_whitespace())
        .filter(|c| c.is_ascii_hexdigit() || *c == '.' || *c == 'x' || *c == 'X')
        .collect();
    let tok = tok.trim_end_matches('.');
    if tok.is_empty() {
        return None;
    }
    if let Some(hex) = tok.strip_prefix("0x").or_else(|| tok.strip_prefix("0X")) {
        let hex = hex.trim_end_matches('.');
        u32::from_str_radix(hex, 16).ok()
    } else {
        // 十进制打印时同样按十进制解析；注意 `0` 前缀八进制在 procfs 里不存在。
        tok.parse::<u32>().ok()
    }
}

/// 从一行里取 `src=` / `dst=`（用于「哪条线路承载了哪些对端」的排查视图）。
pub fn parse_src_dst(line: &str) -> (Option<String>, Option<String>) {
    let mut src = None;
    let mut dst = None;
    // 只取第一个地址族段（IPv4 在前），避免同名的 `src` 出现在 IPv6 段时被覆盖。
    for pair in line.split_whitespace() {
        match pair.strip_prefix("src=") {
            Some(v) if src.is_none() => src = Some(v.to_string()),
            _ => {}
        }
        match pair.strip_prefix("dst=") {
            Some(v) if dst.is_none() => dst = Some(v.to_string()),
            _ => {}
        }
    }
    (src, dst)
}

/// 扫描 conntrack 表。
///
/// `path` 注入便于单测（真机是 `/proc/net/nf_conntrack`）。
/// 文件不存在 → `Error::Io(NotFound)`，调用方必须把它变成明确告警：
/// 「本插件的连接统计不可用」，而不是静默显示 0。
pub fn scan(proc_path: &Path, at_ms: u64) -> Result<Counts> {
    scan_with_cap(proc_path, at_ms, MAX_LINES)
}

/// 带自定义上限的扫描（测试与小内存设备用）。
pub fn scan_with_cap(proc_path: &Path, at_ms: u64, max_lines: usize) -> Result<Counts> {
    let f = std::fs::File::open(proc_path).map_err(|e| {
        logging::error_ctx(
            "conntrack",
            "open",
            Error::Io(std::io::Error::new(
                e.kind(),
                format!("打开 {} 失败: {e}", proc_path.display()),
            )),
            &[],
        )
    })?;
    let mut c = Counts {
        at_ms,
        ..Default::default()
    };
    let reader = BufReader::with_capacity(32 * 1024, f);
    let mut lines = reader.lines();
    while let Some(line) = lines.next() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                // 读一半失败：已统计部分仍然有效，但必须记日志并标不完整，
                // 让上层知道这份数据不能用于均衡决策。
                logging::warn_ctx("conntrack", "read", &format!("扫描中断: {e}"), &[]);
                c.truncated = true;
                break;
            }
        };
        if let Some(m) = parse_mark_field(&line) {
            c.total += 1;
            if marks::is_own(m) {
                *c.per_slot.entry(marks::slot_of(m)).or_insert(0) += 1;
            } else if m == 0 {
                c.unmarked += 1;
            } else {
                c.foreign += 1;
            }
        }
        // 达到上限后额外读一行：能读到就说明确实被截断了，而不是刚好读完。
        if c.total >= max_lines as u64 {
            c.truncated = lines.next().is_some();
            break;
        }
    }
    Ok(c)
}

/// 读取跟踪表当前占用与容量。`None` 表示内核没开对应 procfs（不报错，由上层说明）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    pub count: u64,
    pub max: u64,
}

impl Limits {
    /// 使用率（千分比），供 UI 显示「跟踪表接近上限」。
    pub fn used_permille(&self) -> u32 {
        if self.max == 0 {
            return 0;
        }
        ((self.count.saturating_mul(1000)) / self.max) as u32
    }

    pub fn tight(&self) -> bool {
        self.used_permille() >= 850
    }
}

pub fn read_limits(sysctl_dir: &Path) -> Option<Limits> {
    let count = read_u64(&sysctl_dir.join("nf_conntrack_count"))?;
    let max = read_u64(&sysctl_dir.join("nf_conntrack_max"))?;
    Some(Limits { count, max })
}

fn read_u64(path: &Path) -> Option<u64> {
    let s = std::fs::read_to_string(path).ok()?;
    s.trim().parse::<u64>().ok()
}

/// 异步入口：`/proc` 读取放到阻塞线程池，避免拖慢 tokio 的事件循环。
pub async fn snapshot(path: PathBuf, at_ms: u64) -> Result<Counts> {
    let joined = tokio::task::spawn_blocking(move || scan(&path, at_ms))
        .await
        .map_err(|e| Error::Config(format!("conntrack 采集任务被中止: {e}")))??;
    Ok(joined)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn own_mark(slot: u8, bucket: u16) -> String {
        format!(
            "0x{:08x}",
            marks::mark(slot, marks::CLASS_NORMAL, 1, bucket)
        )
    }

    #[test]
    fn mark_field_parses_hex_and_decimal() {
        assert_eq!(
            parse_mark_field("ipv4 2 tcp 6 src=a mark=0x05000001 seen=1"),
            Some(0x05000001)
        );
        assert_eq!(parse_mark_field("mark=83886081"), Some(83886081));
        // procfs 常在 mark 后紧跟 ` [` 之类的分隔，必须不受影响
        assert_eq!(parse_mark_field("mark=0x05000102 [LANG]"), Some(0x05000102));
        assert_eq!(
            parse_mark_field("ipv4 2 udp 17 src=1.1.1.1"),
            None,
            "没有 mark 字段必须返回 None"
        );
        // 没有 0x 前缀一律按十进制解释；非十进制的垃圾文本必须解析失败，
        // 绝不能「猜」成十六进制，否则会把别人的标记误算成自己的。
        assert_eq!(parse_mark_field("mark=abc"), None);
        assert_eq!(parse_mark_field("mark="), None);
    }

    #[test]
    fn src_dst_take_first_family_only() {
        let line = "ipv4 2 tcp 6 src=192.168.1.20 dst=8.8.8.8 sport=1 dport=53 src=8.8.8.8 dst=10.0.0.2 [ASSURED]";
        let (s, d) = parse_src_dst(line);
        assert_eq!(s.as_deref(), Some("192.168.1.20"));
        assert_eq!(d.as_deref(), Some("8.8.8.8"));
    }

    #[test]
    fn scan_buckets_by_slot_and_separates_foreign_marks() {
        let dir = tempfile::TempDir::new().unwrap();
        let p = dir.path().join("nf_conntrack");
        let lines = [
            format!(
                "ipv4 2 tcp 6 src=192.168.1.10 dst=1.1.1.1 mark={} ",
                own_mark(1, 3)
            ),
            format!(
                "ipv4 2 udp 17 src=192.168.1.11 dst=2.2.2.2 mark={}",
                own_mark(1, 9)
            ),
            format!(
                "ipv4 2 tcp 6 src=192.168.1.12 dst=3.3.3.3 mark={}",
                own_mark(2, 0)
            ),
            "ipv4 2 tcp 6 src=172.16.0.5 dst=4.4.4.4 mark=0x000000aa".to_string(),
            "ipv4 2 tcp 6 src=172.16.0.6 dst=5.5.5.5 mark=0x00000000".to_string(),
            "ipv4 2 tcp 6 src=172.16.0.7 dst=6.6.6.6".to_string(),
        ];
        std::fs::write(&p, lines.join("\n") + "\n").unwrap();
        let c = scan(&p, 1234).unwrap();
        assert_eq!(c.of_slot(1), 2);
        assert_eq!(c.of_slot(2), 1);
        assert_eq!(c.owned(), 3);
        assert_eq!(c.foreign, 1, "别人的标记不能被算成自己的");
        assert_eq!(c.unmarked, 1);
        assert_eq!(c.total, 5, "无 mark 字段的行不计入总数（无法判断）");
        assert!(!c.truncated);
        assert_eq!(c.at_ms, 1234);
        assert!(c.summary().contains("已标记 3 条"), "{}", c.summary());
    }

    #[test]
    fn scan_handles_missing_file_as_error_not_zero() {
        let dir = tempfile::TempDir::new().unwrap();
        let e = scan(&dir.path().join("nope"), 0).unwrap_err();
        assert!(matches!(e, Error::Io(_)), "{e:?}");
    }

    #[test]
    fn growth_since_covers_disappeared_slots() {
        let mut prev = Counts::default();
        prev.per_slot.insert(1, 10);
        prev.per_slot.insert(2, 4);
        let mut now = Counts::default();
        now.per_slot.insert(2, 6);
        let g = now.growth_since(&prev);
        assert_eq!(g[&1], -10);
        assert_eq!(g[&2], 2);
    }

    #[test]
    fn limits_report_usage_and_tightness() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::write(dir.path().join("nf_conntrack_count"), "4000\n").unwrap();
        std::fs::write(dir.path().join("nf_conntrack_max"), "5000\n").unwrap();
        let l = read_limits(dir.path()).unwrap();
        assert_eq!(l.used_permille(), 800);
        assert!(!l.tight());
        std::fs::write(dir.path().join("nf_conntrack_count"), "4600\n").unwrap();
        assert!(
            read_limits(dir.path()).unwrap().tight(),
            "接近容量上限必须提前告警"
        );
        // 文件缺失 → None（上层负责说明），而不是 panic 或返回 0
        assert!(read_limits(&dir.path().join("nowhere")).is_none());
    }

    #[test]
    fn scan_marks_truncation_instead_of_underreporting() {
        let dir = tempfile::TempDir::new().unwrap();
        let p = dir.path().join("nf_conntrack");
        let body: Vec<String> = (0..10)
            .map(|i| format!("ipv4 2 tcp 6 mark={} x{i}", own_mark(1, i as u16)))
            .collect();
        std::fs::write(&p, body.join("\n") + "\n").unwrap();
        // 上限 4：必须报「不完整」，否则上层会把偏小的负载当成事实。
        let c = scan_with_cap(&p, 0, 4).unwrap();
        assert!(c.truncated);
        assert!(c.total <= 5, "{:?}", c.total);
        // 刚好等于上限且后面没有更多行：不算截断。
        let exact = scan_with_cap(&p, 0, 10).unwrap();
        assert!(!exact.truncated && exact.total == 10, "{exact:?}");
    }

    #[tokio::test]
    async fn snapshot_runs_off_the_event_loop() {
        let dir = tempfile::TempDir::new().unwrap();
        let p = dir.path().join("nf_conntrack");
        std::fs::write(&p, format!("ipv4 2 tcp 6 mark={}\n", own_mark(3, 1))).unwrap();
        let c = snapshot(p, 7).await.unwrap();
        assert_eq!(c.of_slot(3), 1);
        assert_eq!(c.at_ms, 7);
    }
}

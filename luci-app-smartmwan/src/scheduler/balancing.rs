//! 负载均衡的桶分配：把「算法 + 权重 + 实时负载」翻译成 `bucket -> slot` 映射。
//!
//! # 数据面现实（必须诚实）
//!
//! nftables 侧只有一个静态映射表：`jhash(...) mod buckets map { 0: 0x101, 1: 0x102, ... }`。
//! 因此所谓「算法」在本插件里全部落到同一件事上 —— **决定每个桶指向哪条线路**：
//!
//! * 静态哈希类（SrcIP / SrcIP+SrcPort / SrcIP+DstIP / SrcIP+DstIP+DstPort /
//!   FullFiveTuple / WeightedHash）：桶图只由权重决定，不随负载变化，
//!   下发后不重排；同一流（按所选字段）始终落同一出口。
//! * 动态类（LeastNewConnections / LeastTraffic）：桶图由实时占用比例反推，
//!   受最小重排间隔与单轮搬动上限约束。**已建立连接不会迁移**（出口由 ct mark
//!   决定），只有新建连接跟随新桶图。
//! * WeightedEcmp：需要内核多路径 nexthop weight 支持，本版本**未实现**，
//!   调用即返回 [`crate::Error::Unsupported`]，UI 也必须据此拒绝保存。
//!
//! # 粒度
//!
//! 一个桶 = 100/`buckets`% 的新建连接。默认 64 桶时粒度约 1.56%，
//! 这是本设计能达到的最细控制，不能对外宣称「按带宽精确分配」。

use std::fmt;

use crate::config::schema::Algorithm;
use crate::{Error, Result};

use super::hysteresis::{advantage_permille, shift_limit};

/// 一条线路在调度时刻的负载快照。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Load {
    /// 当前该线路上的 conntrack 连接数（按标记统计）。
    pub conns: u64,
    /// 本窗口内新建连接数（差值）。
    pub new_conns: u64,
    /// 窗口内平均下行/上行速率（kbit/s，来自接口计数器差值）。
    pub rx_kbps: u64,
    pub tx_kbps: u64,
    /// 配置的上限（0 = 未知/不限）。
    pub down_kbps: u32,
    pub up_kbps: u32,
    /// 单线路连接数上限（0 = 不限），来自 `global.max_connections_per_wan`。
    pub conn_limit: u32,
    /// 采样是否可信（窗口不足或计数器回绕时为 false，动态算法会退回静态权重）。
    pub measured: bool,
}

impl Load {
    /// 带宽占用千分比；上限未知时用流量绝对值做相对比较（返回 None 语义由
    /// [`Load::relative_permille`] 承担）。
    pub fn used_permille(&self) -> Option<u32> {
        if self.down_kbps == 0 && self.up_kbps == 0 {
            return None;
        }
        let d = if self.down_kbps > 0 {
            self.rx_kbps.saturating_mul(1000) / u64::from(self.down_kbps)
        } else {
            0
        };
        let u = if self.up_kbps > 0 {
            self.tx_kbps.saturating_mul(1000) / u64::from(self.up_kbps)
        } else {
            0
        };
        Some(crate::scheduler::hysteresis::clamp_permille(d.max(u) as i64))
    }

    /// 连接数占用千分比。
    pub fn conn_permille(&self) -> Option<u32> {
        if self.conn_limit == 0 {
            return None;
        }
        Some(crate::scheduler::hysteresis::clamp_permille(
            (self.conns.saturating_mul(1000) / u64::from(self.conn_limit)) as i64,
        ))
    }

    /// 剩余容量千分比（越空的线路越高）。没有任何上限信息时返回 `None`，
    /// 调用方必须据此降级，而不是假设「都一样空」。
    pub fn spare_permille(&self, mode: SpareMode) -> Option<u32> {
        let used = match mode {
            SpareMode::Traffic => self.used_permille(),
            SpareMode::Connections => self.conn_permille().or_else(|| self.used_permille()),
        };
        used.map(|u| 1000u32.saturating_sub(u).max(1))
    }

    /// 是否已经撞到连接数上限（用于「最少新建连接」的硬保护）。
    pub fn conn_capped(&self) -> bool {
        self.conn_limit > 0 && self.conns >= u64::from(self.conn_limit)
    }
}

/// 剩余容量的口径。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpareMode {
    /// 按带宽占用。
    Traffic,
    /// 按连接数占用。
    Connections,
}

/// 参与调度的线路。
#[derive(Debug, Clone)]
pub struct Candidate {
    pub name: String,
    /// 数据面槽位（1..=MAX_WANS）。
    pub slot: u8,
    pub weight: u32,
    pub priority: u16,
    /// 当前是否可承载普通流量（健康层 + 静态阻断共同决定）。
    pub usable: bool,
    /// 质量偏差（DEGRADED）：仍可承载，但动态分配时应降权。
    pub degraded: bool,
    pub load: Load,
}

impl Candidate {
    /// 有效权重：不可用为 0；降级线路按半权处理（整数千分比，避免浮点噪声）。
    pub fn effective_weight_permille(&self) -> u64 {
        if !self.usable {
            return 0;
        }
        let w = u64::from(self.weight.max(1)) * 1000;
        if self.degraded {
            w / 2
        } else {
            w
        }
    }
}

/// 一次分配所需的全部输入。
#[derive(Debug, Clone)]
pub struct Request<'a> {
    pub algorithm: Algorithm,
    pub buckets: usize,
    pub candidates: &'a [Candidate],
    /// 上一轮桶图（`None` 表示首次）。
    pub previous: Option<&'a [u8]>,
    /// 单轮最大搬动千分比（`global.smoothing_permille` 的补数语义：
    /// 值越大越平滑，这里换算成允许搬动的比例）。
    pub smoothing_permille: u32,
    /// 触发重排所需的最小负载差（千分比），防止在两条线路几乎打平时来回搬。
    pub min_advantage_permille: u32,
    /// 距上次重排是否已经满足最小间隔（不满足时本轮只允许「必要搬迁」）。
    pub interval_ok: bool,
}

/// 分配结果。
#[derive(Debug, Clone)]
pub struct Assignment {
    /// 长度 = buckets，元素为槽位；全 0 表示本轮不分流。
    pub buckets: Vec<u8>,
    /// 相对 `previous` 实际变化的桶数。
    pub moved: usize,
    /// 人类可读的决策依据，必须能回答 UI 的「为什么现在是这样分的」。
    pub reason: String,
    /// 降级/限制说明（例如「负载采样不可信，本轮按权重」）。
    pub notes: Vec<String>,
}

impl Assignment {
    /// 每条线路分到的桶数（供 RPC/UI 展示实际比例）。
    pub fn share(&self) -> Vec<(u8, usize)> {
        let mut out: Vec<(u8, usize)> = Vec::new();
        for b in &self.buckets {
            if *b == 0 {
                continue;
            }
            match out.iter_mut().find(|(s, _)| *s == *b) {
                Some((_, n)) => *n += 1,
                None => out.push((*b, 1)),
            }
        }
        out.sort_by_key(|(s, _)| *s);
        out
    }

    pub fn is_empty(&self) -> bool {
        self.buckets.iter().all(|b| *b == 0)
    }
}

impl fmt::Display for Assignment {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}（变化 {} 个桶）", self.reason, self.moved)
    }
}

/// 主入口。
pub fn assign(req: &Request) -> Result<Assignment> {
    if req.buckets == 0 {
        return Err(Error::Config("桶数必须大于 0".into()));
    }
    if req.algorithm == Algorithm::WeightedEcmp {
        return Err(Error::Unsupported(
            "加权 ECMP 依赖内核多路径 nexthop 权重与 ip-full，本版本未实现；请改用加权哈希（WeightedHash）".into(),
        ));
    }
    let usable: Vec<&Candidate> = req.candidates.iter().filter(|c| c.usable).collect();
    if usable.is_empty() {
        // 没有任何可用线路：返回全 0（不标记），流量按系统默认路由走。
        // 这是「诚实的失败」——比把流量硬塞给已知断掉的线路更好解释。
        return Ok(Assignment {
            buckets: vec![0; req.buckets],
            moved: 0,
            reason: "没有可用线路，本轮不分流（流量走系统默认路由）".into(),
            notes: vec!["请检查线路健康状态与探测目标配置".into()],
        });
    }

    match req.algorithm {
        Algorithm::LeastNewConnections => dynamic(req, SpareMode::Connections),
        Algorithm::LeastTraffic => dynamic(req, SpareMode::Traffic),
        _ => static_weighted(req),
    }
}

/// 静态哈希：按权重把桶铺开。
///
/// 铺开方式用「累加计数（Bresenham 式）」而不是「连续区段」，
/// 这样权重变化后重算的桶图与旧图差异最小，迁移的连接数也最少。
fn static_weighted(req: &Request) -> Result<Assignment> {
    let mut notes = Vec::new();
    let usable: Vec<&Candidate> = req.candidates.iter().filter(|c| c.usable).collect();
    let counts = distribute(&usable, req.buckets);
    let mut buckets = vec![0u8; req.buckets];
    fill_slots(&mut buckets, &usable, &counts);

    let moved = count_moves(req.previous, &buckets);
    if !req.algorithm.is_static_hash() {
        notes.push(format!(
            "算法 {} 不属于静态哈希，本轮仍按权重分配（不应期望其具备动态迁移语义）",
            req.algorithm.as_str()
        ));
    }
    if moved > 0 && !req.interval_ok {
        notes.push("权重在最小重排间隔内发生变化，桶图已按新权重下发".into());
    }
    let reason = format!(
        "按权重分配 {} 个桶：{}",
        req.buckets,
        describe(&usable, &counts)
    );
    Ok(Assignment {
        buckets,
        moved,
        reason,
        notes,
    })
}

/// 动态算法：按剩余容量分配，再套一层限流与「值得搬吗」判断。
fn dynamic(req: &Request, mode: SpareMode) -> Result<Assignment> {
    let mut notes = Vec::new();
    let usable: Vec<&Candidate> = req.candidates.iter().filter(|c| c.usable).collect();

    // 采样不可信时绝不假装动态：明确降级为权重分配。
    let measured = usable.iter().any(|c| c.load.measured);
    let spares: Vec<Option<u32>> = usable.iter().map(|c| c.load.spare_permille(mode)).collect();
    let use_dynamic = measured && spares.iter().all(|s| s.is_some());
    if !use_dynamic {
        notes.push(
            "负载采样不可信（缺少带宽/连接上限，或窗口尚未形成），本轮按权重分配".to_string(),
        );
        let mut a = static_weighted(req)?;
        a.notes.extend(notes);
        a.reason = format!("{}（动态降级）", a.reason);
        return Ok(a);
    }

    let weights: Vec<u64> = usable
        .iter()
        .map(|c| c.load.spare_permille(mode).unwrap_or(1).max(1) as u64)
        .collect();
    let total: u64 = weights.iter().sum();
    let mut counts: Vec<usize> = Vec::with_capacity(usable.len());
    for w in &weights {
        counts.push(((req.buckets as u64 * w + total / 2) / total) as usize);
    }
    fix_rounding(&mut counts, req.buckets);

    // 目标桶图（铺开）与当前桶图对比，只搬「必要」和「允许」的两类。
    let mut wanted = vec![0u8; req.buckets];
    fill_slots(&mut wanted, &usable, &counts);

    let base: Vec<u8> = match req.previous {
        Some(p) if p.len() == req.buckets => p.to_vec(),
        _ => {
            notes.push("没有上一轮桶图，本轮按目标直接下发".into());
            wanted.clone()
        }
    };

    // 1) 必要搬迁：上一轮指向已不可用槽位的桶，必须立刻搬走（不受限流约束）。
    let mut out = base.clone();
    let usable_slots: Vec<u8> = usable.iter().map(|c| c.slot).collect();
    let mut forced = 0usize;
    for (i, v) in out.iter_mut().enumerate() {
        if *v != 0 && !usable_slots.contains(v) {
            *v = wanted[i];
            forced += 1;
        }
    }

    // 2) 常规搬迁：受单轮上限与「值得搬吗」约束。
    let limit = if req.interval_ok {
        shift_limit(
            req.buckets,
            (1000 - req.smoothing_permille as i64).max(10) as u32,
        )
    } else {
        0
    };
    let mut budget = limit;
    if budget > 0 {
        let over = overloaded_indices(&out, &wanted, &usable, req.buckets);
        for idx in over {
            if wanted[idx] == out[idx] {
                continue;
            }
            if budget == 0 {
                break;
            }
            // 「值得搬吗」：目标线路的剩余容量必须明显优于当前线路。
            let cur = usable.iter().find(|c| c.slot == out[idx]);
            let dst = usable.iter().find(|c| c.slot == wanted[idx]);
            let better = match (cur, dst) {
                (Some(c), Some(d)) => {
                    let cs = c.load.spare_permille(mode).unwrap_or(0);
                    let ds = d.load.spare_permille(mode).unwrap_or(0);
                    advantage_permille(ds as f64, cs as f64) >= req.min_advantage_permille as i64
                        || c.load.conn_capped()
                }
                (None, Some(_)) => true,
                _ => false,
            };
            if !better {
                continue;
            }
            out[idx] = wanted[idx];
            budget -= 1;
        }
    }
    if !req.interval_ok && forced == 0 {
        notes.push("未到最小重排间隔，本轮不搬动桶".into());
    }

    let counts_now = tally(&out, &usable);
    let moved = count_moves(req.previous, &out);
    let reason = format!(
        "{} 算法按剩余容量分配：{}{}",
        req.algorithm.as_str(),
        describe(&usable, &counts_now),
        if forced > 0 {
            format!("（其中 {forced} 个桶因线路不可用被强制搬离）")
        } else {
            String::new()
        }
    );
    Ok(Assignment {
        buckets: out,
        moved,
        reason,
        notes,
    })
}

/// 最大余额法：按权重把 `buckets` 个桶分给候选线路，保证总和恰好等于桶数。
fn distribute(cands: &[&Candidate], buckets: usize) -> Vec<usize> {
    let weights: Vec<u64> = cands
        .iter()
        .map(|c| c.effective_weight_permille())
        .collect();
    let total: u64 = weights.iter().sum();
    if total == 0 {
        // 全部权重为 0（异常配置）：平均分，保证不留空桶。
        let each = buckets / cands.len().max(1);
        let mut v = vec![each; cands.len()];
        for i in 0..buckets.saturating_sub(v.iter().sum::<usize>()) {
            let idx = i % v.len().max(1);
            v[idx] += 1;
        }
        return v;
    }
    let mut base: Vec<usize> = Vec::with_capacity(cands.len());
    let mut fracs: Vec<(usize, u64)> = Vec::with_capacity(cands.len());
    let mut used = 0usize;
    for (i, w) in weights.iter().enumerate() {
        let num = buckets as u64 * w;
        let q = (num / total) as usize;
        let r = num % total;
        base.push(q);
        used += q;
        fracs.push((i, r));
    }
    let rest = buckets.saturating_sub(used);
    // 余数按小数部分从大到小分配；同余数按优先级、名称稳定排序，保证确定性。
    fracs.sort_by(|a, b| {
        b.1.cmp(&a.1)
            .then_with(|| cands[a.0].priority.cmp(&cands[b.0].priority))
            .then_with(|| cands[a.0].name.cmp(&cands[b.0].name))
    });
    for k in 0..rest {
        if let Some((i, _)) = fracs.get(k) {
            base[*i] += 1;
        }
    }
    base
}

/// 把「每条线路几个桶」铺成桶图：用累加游标交错，而不是连续区段。
fn fill_interleaved(buckets: &mut [u8], counts: &[usize]) {
    let total: usize = counts.iter().sum();
    if total == 0 || buckets.is_empty() {
        return;
    }
    // 游标法：每次取「相对位置最靠前」的线路，使各线路的桶交错分布而不是连成一段。
    let mut acc = 0usize;
    let mut starts: Vec<usize> = Vec::with_capacity(counts.len());
    for c in counts {
        starts.push(acc);
        acc += c;
    }
    let mut next = starts.clone();
    let step: Vec<f64> = counts
        .iter()
        .map(|c| {
            if *c == 0 {
                0.0
            } else {
                total as f64 / *c as f64
            }
        })
        .collect();
    let mut cursor: Vec<f64> = (0..counts.len())
        .map(|i| starts[i] as f64 + (if counts[i] == 0 { f64::INFINITY } else { 0.0 }))
        .collect();
    for b in buckets.iter_mut() {
        let mut pick: Option<usize> = None;
        for i in 0..counts.len() {
            if next[i] >= starts[i] + counts[i] {
                continue;
            }
            if step[i] <= 0.0 {
                continue;
            }
            match pick {
                None => pick = Some(i),
                Some(p) => {
                    if cursor[i] < cursor[p] || (cursor[i] == cursor[p] && i < p) {
                        pick = Some(i);
                    }
                }
            }
        }
        match pick {
            Some(i) => {
                // 槽位号 = 下标 + 1 的约定由调用方保证（这里用 counts 顺序对应的 slot 传入）。
                *b = i as u8 + 1;
                next[i] += 1;
                cursor[i] += step[i];
            }
            None => break,
        }
    }
}

/// `fill_interleaved` 的槽位版本：桶值必须是真实 slot，而不是下标。
fn fill_slots(buckets: &mut [u8], cands: &[&Candidate], counts: &[usize]) {
    let slots: Vec<u8> = cands.iter().map(|c| c.slot).collect();
    fill_interleaved(buckets, counts);
    for b in buckets.iter_mut() {
        if *b == 0 {
            continue;
        }
        let idx = (*b as usize) - 1;
        *b = slots.get(idx).copied().unwrap_or(0);
    }
}

fn tally(buckets: &[u8], cands: &[&Candidate]) -> Vec<usize> {
    let mut out = vec![0usize; cands.len()];
    for b in buckets {
        if let Some(i) = cands.iter().position(|c| c.slot == *b) {
            out[i] += 1;
        }
    }
    out
}

fn describe(cands: &[&Candidate], counts: &[usize]) -> String {
    let parts: Vec<String> = cands
        .iter()
        .enumerate()
        .map(|(i, c)| format!("{}={}桶", c.name, counts.get(i).copied().unwrap_or(0)))
        .collect();
    parts.join(", ")
}

fn count_moves(previous: Option<&[u8]>, now: &[u8]) -> usize {
    match previous {
        Some(p) if p.len() == now.len() => p.iter().zip(now.iter()).filter(|(a, b)| a != b).count(),
        _ => now.iter().filter(|b| **b != 0).count(),
    }
}

/// 哪些桶最该动：先动「当前线路桶数超出目标」的那些，且从尾部开始。
fn overloaded_indices(
    cur: &[u8],
    wanted: &[u8],
    cands: &[&Candidate],
    buckets: usize,
) -> Vec<usize> {
    let cur_counts = tally(cur, cands);
    let want_counts = tally(wanted, cands);
    let mut surplus: Vec<(usize, i64)> = Vec::new();
    for (i, c) in cands.iter().enumerate() {
        let diff = cur_counts[i] as i64 - want_counts[i] as i64;
        if diff > 0 {
            // 从该线路占据的桶里挑最靠后的 diff 个（保持稳定：低位桶先留着）。
            let idxs: Vec<usize> = (0..buckets).filter(|k| cur[*k] == c.slot).collect();
            for k in idxs.into_iter().rev().take(diff as usize) {
                surplus.push((k, -(k as i64)));
            }
        }
    }
    surplus.sort_by_key(|(k, _)| *k);
    surplus.into_iter().map(|(k, _)| k).collect()
}

/// 四舍五入后修正总数。
fn fix_rounding(counts: &mut [usize], total: usize) {
    let sum: usize = counts.iter().sum();
    if sum == total {
        return;
    }
    if sum < total {
        let gap = total - sum;
        // 缺的桶给当前桶数最少的线路（并列取下标小者），保持均衡语义。
        for _ in 0..gap {
            let mut best = 0usize;
            for (i, c) in counts.iter().enumerate() {
                if counts[best] == 0 || *c < counts[best] {
                    best = i;
                }
            }
            counts[best] += 1;
        }
    } else {
        let mut over = sum - total;
        while over > 0 {
            let mut max = 0usize;
            for (i, c) in counts.iter().enumerate() {
                if *c > counts[max] {
                    max = i;
                }
            }
            if counts[max] == 0 {
                break;
            }
            counts[max] -= 1;
            over -= 1;
        }
    }
}

#[cfg(test)]
mod tests {
    //! 桶分配是数据平面的直接输入，这里逐条守住「比例准确、总量守恒、
    //! 搬迁受预算约束、必要搬迁不受预算约束」四条不变式。

    use super::*;
    use crate::scheduler::hysteresis::shift_limit;

    fn cand(name: &str, slot: u8, weight: u32, usable: bool) -> Candidate {
        Candidate {
            name: name.into(),
            slot,
            weight,
            priority: slot as u16 * 10,
            usable,
            degraded: false,
            load: Load::default(),
        }
    }

    /// 带可信采样与带宽上限的候选（动态算法只有在两者齐备时才会真的动态）。
    fn measured(name: &str, slot: u8, rx_kbps: u64, limit_kbps: u32) -> Candidate {
        Candidate {
            load: Load {
                rx_kbps,
                tx_kbps: 0,
                down_kbps: limit_kbps,
                up_kbps: 0,
                conns: 0,
                new_conns: 0,
                conn_limit: 0,
                measured: true,
            },
            ..cand(name, slot, 1, true)
        }
    }

    fn req<'a>(
        algorithm: Algorithm,
        cands: &'a [Candidate],
        previous: Option<&'a [u8]>,
    ) -> Request<'a> {
        Request {
            algorithm,
            buckets: 64,
            candidates: cands,
            previous,
            smoothing_permille: 700,
            min_advantage_permille: 150,
            interval_ok: true,
        }
    }

    fn counts(a: &Assignment) -> Vec<(u8, usize)> {
        a.share()
    }

    #[test]
    fn weighted_allocation_is_proportional_and_conserves_buckets() {
        let cands = vec![cand("wan1", 1, 3, true), cand("wan2", 2, 1, true)];
        let a = assign(&req(Algorithm::WeightedHash, &cands, None)).unwrap();
        assert_eq!(a.buckets.len(), 64);
        assert_eq!(counts(&a), vec![(1, 48), (2, 16)], "3:1 必须精确落到 48:16");
        assert_eq!(
            a.share().iter().map(|(_, n)| n).sum::<usize>(),
            64,
            "桶数守恒"
        );
        assert!(a.buckets.iter().all(|b| *b != 0), "静态分配不能留下空桶");
    }

    #[test]
    fn degraded_lines_are_halved_and_disabled_lines_get_nothing() {
        let mut d = cand("wan1", 1, 1, true);
        d.degraded = true;
        let cands = vec![d, cand("wan2", 2, 1, true)];
        let a = assign(&req(Algorithm::SrcIp, &cands, None)).unwrap();
        // 半权 500 vs 1000 → 21 : 43（最大余额法把余数给小数部分大者）
        // share() 按槽位升序返回：与 nft 桶映射表的书写顺序一致，便于逐条核对。
        assert_eq!(counts(&a), vec![(1, 21), (2, 43)], "{:?}", counts(&a));

        let cands2 = vec![cand("wan1", 1, 5, false), cand("wan2", 2, 1, true)];
        let a2 = assign(&req(Algorithm::SrcIp, &cands2, None)).unwrap();
        assert_eq!(counts(&a2), vec![(2, 64)], "不可用线路一个桶都不能给");
    }

    #[test]
    fn fractional_weights_still_sum_exactly() {
        let cands = vec![
            cand("a", 1, 1, true),
            cand("b", 2, 1, true),
            cand("c", 3, 1, true),
        ];
        let a = assign(&req(Algorithm::SrcIpDstIp, &cands, None)).unwrap();
        let sum: usize = counts(&a).iter().map(|(_, n)| n).sum();
        assert_eq!(sum, 64, "三条线路均分 64 桶时必须凑满而不是留空");
        let max = counts(&a).iter().map(|(_, n)| *n).max().unwrap();
        let min = counts(&a).iter().map(|(_, n)| *n).min().unwrap();
        assert!(max - min <= 1, "均分结果最多相差 1 个桶: {:?}", counts(&a));
    }

    #[test]
    fn all_zero_when_nothing_is_usable() {
        let cands = vec![cand("wan1", 1, 1, false), cand("wan2", 2, 1, false)];
        let a = assign(&req(Algorithm::SrcIp, &cands, None)).unwrap();
        assert!(a.is_empty());
        assert!(a.buckets.iter().all(|b| *b == 0));
        assert!(a.reason.contains("没有可用线路"), "{}", a.reason);
        assert!(!a.notes.is_empty(), "必须附带排查提示");
    }

    #[test]
    fn weighted_ecmp_is_refused_rather_than_silently_approximated() {
        let cands = vec![cand("wan1", 1, 1, true), cand("wan2", 2, 1, true)];
        let e = assign(&req(Algorithm::WeightedEcmp, &cands, None)).unwrap_err();
        assert!(matches!(e, Error::Unsupported(_)), "{e}");
        assert!(e.to_string().contains("加权哈希"), "{e}");
    }

    #[test]
    fn zero_buckets_is_a_configuration_error() {
        let cands = vec![cand("wan1", 1, 1, true)];
        let mut r = req(Algorithm::SrcIp, &cands, None);
        r.buckets = 0;
        assert!(matches!(assign(&r), Err(Error::Config(_))));
    }

    #[test]
    fn same_weights_same_state_produce_zero_churn() {
        let cands = vec![cand("wan1", 1, 2, true), cand("wan2", 2, 1, true)];
        let first = assign(&req(Algorithm::WeightedHash, &cands, None)).unwrap();
        let second = assign(&req(Algorithm::WeightedHash, &cands, Some(&first.buckets))).unwrap();
        assert_eq!(
            second.moved, 0,
            "同样的输入必须得到同样的桶图，否则每次重排都会打断新建连接分布"
        );
        assert_eq!(second.buckets, first.buckets);
    }

    #[test]
    fn interleaved_fill_minimises_churn_when_weight_changes() {
        // 1:1 → 2:1：交错铺开会打散变化，连续区段铺开会整段搬迁。
        let before = vec![cand("wan1", 1, 1, true), cand("wan2", 2, 1, true)];
        let a = assign(&req(Algorithm::WeightedHash, &before, None)).unwrap();
        let after = vec![cand("wan1", 1, 2, true), cand("wan2", 2, 1, true)];
        let b = assign(&req(Algorithm::WeightedHash, &after, Some(&a.buckets))).unwrap();
        assert_eq!(
            counts(&b),
            vec![(1, 43), (2, 21)],
            "2:1 应为 43:21（最大余额法）"
        );
        // 理论下限 = wan2 必须让出的桶数（32 − 21 = 11）；交错铺开不应显著超过它。
        assert!(b.moved >= 11, "权重变了不可能零变更: {}", b.moved);
        assert!(
            b.moved <= 22,
            "交错铺开应把变更压到接近理论下限 11，实测 {}",
            b.moved
        );
    }

    #[test]
    fn dynamic_algorithm_degrades_when_samples_are_untrustworthy() {
        let cands = vec![cand("wan1", 1, 1, true), cand("wan2", 2, 3, true)];
        let a = assign(&req(Algorithm::LeastTraffic, &cands, None)).unwrap();
        assert!(
            a.notes.iter().any(|n| n.contains("采样不可信")),
            "{:?}",
            a.notes
        );
        assert!(a.reason.contains("动态降级"), "{}", a.reason);
        // 退回权重后仍是 1:3 的精确分配
        assert_eq!(counts(&a), vec![(1, 16), (2, 48)]);
    }

    #[test]
    fn dynamic_moves_only_within_shift_budget() {
        let cands = vec![
            measured("wan1", 1, 900_000, 1_000_000),
            measured("wan2", 2, 100_000, 1_000_000),
        ];
        let previous = vec![1u8; 64];
        let a = assign(&req(Algorithm::LeastTraffic, &cands, Some(&previous))).unwrap();
        let budget = shift_limit(64, 300);
        assert_eq!(a.moved, budget, "首轮应按预算上限搬动，不能一次性全量重建");
        assert_eq!(counts(&a).iter().find(|(s, _)| *s == 2).unwrap().1, budget);
        // 目标态是 6:58，本轮只应搬到预算为止
        assert!(
            counts(&a).iter().find(|(s, _)| *s == 1).unwrap().1 > 6,
            "剩余差距留给后续轮次"
        );
    }

    #[test]
    fn dynamic_needs_a_visible_advantage_before_moving() {
        // wan1 更空（spare 600 vs 500）：把桶从 wan1 搬去 wan2 没有收益
        let cands = vec![
            measured("wan1", 1, 400_000, 1_000_000),
            measured("wan2", 2, 500_000, 1_000_000),
        ];
        let previous = vec![1u8; 64];
        let a = assign(&req(Algorithm::LeastTraffic, &cands, Some(&previous))).unwrap();
        assert_eq!(a.moved, 0, "优势不足不得搬动: {:?}", counts(&a));
        assert!(a.buckets.iter().all(|b| *b == 1));
    }

    #[test]
    fn necessary_eviction_ignores_interval_and_budget() {
        // 上一轮全部指向 slot 3，而 3 已经不可用：64 个桶必须立刻离开
        let cands = vec![
            measured("wan1", 1, 100_000, 1_000_000),
            measured("wan2", 2, 100_000, 1_000_000),
        ];
        let previous = vec![3u8; 64];
        let mut r = req(Algorithm::LeastTraffic, &cands, Some(&previous));
        r.interval_ok = false;
        let a = assign(&r).unwrap();
        assert!(
            a.buckets.iter().all(|b| *b != 3),
            "线路没了还留着标记就是黑洞"
        );
        assert_eq!(a.moved, 64);
        assert!(a.reason.contains("强制搬离"), "{}", a.reason);
    }

    #[test]
    fn ordinary_moves_are_held_back_before_the_rebalance_interval() {
        let cands = vec![
            measured("wan1", 1, 900_000, 1_000_000),
            measured("wan2", 2, 100_000, 1_000_000),
        ];
        let previous = vec![1u8; 64];
        let mut r = req(Algorithm::LeastTraffic, &cands, Some(&previous));
        r.interval_ok = false;
        let a = assign(&r).unwrap();
        assert_eq!(
            a.moved, 0,
            "未到重排间隔且没有必要搬迁时，数据面必须保持不动"
        );
        assert!(
            a.notes.iter().any(|n| n.contains("未到最小重排间隔")),
            "{:?}",
            a.notes
        );
    }

    #[test]
    fn connection_capped_line_is_evicted_even_without_advantage() {
        // 两条线路剩余容量接近，但 wan1 已经撞到连接数上限：仍要搬
        let mut a1 = cand("wan1", 1, 1, true);
        a1.load = Load {
            conns: 1000,
            conn_limit: 1000,
            down_kbps: 1_000_000,
            rx_kbps: 500_000,
            measured: true,
            ..Default::default()
        };
        let mut a2 = cand("wan2", 2, 1, true);
        a2.load = Load {
            conns: 100,
            conn_limit: 1000,
            down_kbps: 1_000_000,
            rx_kbps: 520_000,
            measured: true,
            ..Default::default()
        };
        let cands = vec![a1, a2];
        let previous = vec![1u8; 64];
        let out = assign(&req(
            Algorithm::LeastNewConnections,
            &cands,
            Some(&previous),
        ))
        .unwrap();
        assert!(out.moved > 0, "连接数封顶必须触发搬迁: {:?}", out.moved);
        assert!(out.buckets.contains(&2));
    }

    #[test]
    fn spare_permille_refuses_to_guess_without_limits() {
        let l = Load {
            rx_kbps: 1000,
            measured: true,
            ..Default::default()
        };
        assert_eq!(l.used_permille(), None, "没配带宽上限时不能编造占用率");
        assert_eq!(l.spare_permille(SpareMode::Traffic), None);
        assert_eq!(l.conn_permille(), None);
        assert!(!l.conn_capped());
        let l2 = Load {
            rx_kbps: 2_000_000,
            down_kbps: 1_000,
            ..Default::default()
        };
        assert_eq!(l2.used_permille(), Some(1000), "超上限必须钳位而不是溢出");
        assert_eq!(
            l2.spare_permille(SpareMode::Traffic),
            Some(1),
            "留 1‰ 保证还能拿到桶"
        );
    }

    #[test]
    fn display_and_reasons_are_human_readable() {
        let cands = vec![cand("wan1", 1, 1, true)];
        let a = assign(&req(Algorithm::SrcIpSrcPort, &cands, None)).unwrap();
        let text = a.to_string();
        assert!(text.contains("wan1=64桶"), "{text}");
        assert!(text.contains("变化"), "{text}");
    }

    #[test]
    fn non_hash_algorithm_still_gets_a_weight_note() {
        // 动态算法降级路径之外的组合：静态函数被直接调用时要提示语义不符
        let cands = vec![cand("wan1", 1, 1, true), cand("wan2", 2, 1, true)];
        let a = assign(&req(Algorithm::LeastTraffic, &cands, None)).unwrap();
        assert!(
            a.notes
                .iter()
                .any(|n| n.contains("采样不可信") || n.contains("不属于静态哈希")),
            "{:?}",
            a.notes
        );
    }
}

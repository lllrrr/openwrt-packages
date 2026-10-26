//! 探测指标：滑动窗口 RTT / 抖动 / 丢包 / 不稳定度。
//!
//! # 为什么要窗口而不是只用最后一个值
//!
//! 单次 RTT 在蜂窝线路上抖得厉害（同一秒 30ms 与 400ms 都正常）。
//! 若直接拿最后一次探测值做游戏选路，会在两条线路之间反复横跳；
//! 拿它做健康判定则会频繁误报断线。因此这里同时给出：
//!
//! * `rtt_ms`：窗口内成功样本的均值（对 5G 更稳）；
//! * `p95_ms`：尾延迟（游戏玩家真正感知的是偶发尖峰）；
//! * `jitter_ms`：相邻样本 RTT 差绝对值的滑动平均（RFC 3550 的思路，简化为均值）；
//! * `loss_pmm`：千分比丢包（含超时）；
//! * `instability_pmm`：`stddev / rtt` 的千分比，作为评分里的「不稳定惩罚」输入。
//!
//! # 诚实约束
//!
//! 样本数不足 `MIN_SAMPLES` 时 `confident()` 为 false：前端必须显示「采样中」，
//! 不能把前 2 个样本的均值当成线路真实质量展示（任务书「不得把 mock 数据当实时状态」）。

use std::collections::VecDeque;

/// 窗口容量：约覆盖 1~2 分钟探测（默认 1s 间隔），再长就失去「反映当前状态」的意义。
pub const WINDOW: usize = 90;
/// 得出可信指标所需的最少成功样本数。
pub const MIN_SAMPLES: usize = 5;

/// 一次探测结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Sample {
    pub at_ms: u64,
    /// 往返时延；失败时为 0 且 `ok == false`。
    pub rtt_ms: u32,
    pub ok: bool,
    /// 探测协议标识（icmp/tcp/dns），仅用于排障展示。
    pub proto: &'static str,
}

impl Sample {
    pub fn success(at_ms: u64, rtt_ms: u32, proto: &'static str) -> Sample {
        Sample {
            at_ms,
            rtt_ms,
            ok: true,
            proto,
        }
    }
    pub fn failure(at_ms: u64, proto: &'static str) -> Sample {
        Sample {
            at_ms,
            rtt_ms: 0,
            ok: false,
            proto,
        }
    }
}

/// 指标快照（可序列化给 RPC）。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Metrics {
    pub samples: usize,
    pub ok_samples: usize,
    /// 0~1000 千分比。
    pub loss_pmm: u32,
    pub rtt_ms: u32,
    pub min_ms: u32,
    pub max_ms: u32,
    pub p95_ms: u32,
    pub jitter_ms: u32,
    pub instability_pmm: u32,
    pub last_ok_ms: u64,
    pub last_fail_ms: u64,
    /// 指标新鲜度：最后一个样本距今超过 `stale_ms` 时不再可信。
    pub age_ms: u64,
}

impl Metrics {
    /// 是否足以作为决策与展示依据。
    pub fn confident(&self) -> bool {
        self.ok_samples >= MIN_SAMPLES
    }

    /// 供前端直接引用的中文说明，避免 UI 自己编「质量良好」这类判断。
    pub fn describe(&self) -> String {
        if !self.confident() {
            return format!("采样中（成功 {}/{}）", self.ok_samples, MIN_SAMPLES);
        }
        format!(
            "RTT {}ms（抖动 {}ms，P95 {}ms，丢包 {}‰）",
            self.rtt_ms, self.jitter_ms, self.p95_ms, self.loss_pmm
        )
    }
}

/// 滑动窗口。
#[derive(Debug, Clone)]
pub struct SlidingWindow {
    samples: VecDeque<Sample>,
    capacity: usize,
}

impl Default for SlidingWindow {
    fn default() -> Self {
        SlidingWindow::new(WINDOW)
    }
}

impl SlidingWindow {
    pub fn new(capacity: usize) -> SlidingWindow {
        SlidingWindow {
            samples: VecDeque::with_capacity(capacity.max(1)),
            capacity: capacity.max(1),
        }
    }

    pub fn push(&mut self, s: Sample) {
        if self.samples.len() == self.capacity {
            self.samples.pop_front();
        }
        self.samples.push_back(s);
    }

    pub fn len(&self) -> usize {
        self.samples.len()
    }

    /// 空窗口必须可判空（`is_empty` 与 `len` 成对，避免 clippy 噪音，也让调用方语义清楚）。
    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    pub fn clear(&mut self) {
        self.samples.clear();
    }

    pub fn last(&self) -> Option<Sample> {
        self.samples.back().copied()
    }

    /// 窗口覆盖的时间跨度（毫秒）。用于判断指标是不是「同一批老样本」。
    pub fn span_ms(&self) -> u64 {
        match (self.samples.front(), self.samples.back()) {
            (Some(f), Some(b)) => b.at_ms.saturating_sub(f.at_ms),
            _ => 0,
        }
    }

    /// 计算指标。`now_ms` 用于算新鲜度。
    pub fn metrics(&self, now_ms: u64) -> Metrics {
        let mut m = Metrics::default();
        let total = self.samples.len();
        if total == 0 {
            return m;
        }
        m.samples = total;
        let oks: Vec<u32> = self
            .samples
            .iter()
            .filter(|s| s.ok)
            .map(|s| s.rtt_ms)
            .collect();
        m.ok_samples = oks.len();
        m.loss_pmm = permille(total as u64 - oks.len() as u64, total as u64);
        for s in &self.samples {
            if s.ok {
                m.last_ok_ms = m.last_ok_ms.max(s.at_ms);
            } else {
                m.last_fail_ms = m.last_fail_ms.max(s.at_ms);
            }
        }
        m.age_ms = now_ms.saturating_sub(self.samples.back().map(|s| s.at_ms).unwrap_or(0));
        if oks.is_empty() {
            return m;
        }
        let mut sorted = oks.clone();
        sorted.sort_unstable();
        m.min_ms = sorted[0];
        m.max_ms = sorted[sorted.len() - 1];
        let sum: u64 = oks.iter().map(|v| *v as u64).sum();
        m.rtt_ms = clamp_ms(sum / oks.len() as u64);
        // P95：取向上第 95 百分位的样本（样本少时就是最大值，符合直觉）。
        let idx = ((oks.len() as f64) * 0.95).ceil() as usize - 1;
        m.p95_ms = sorted[idx.min(sorted.len() - 1)];
        // 抖动：相邻成功样本 RTT 差绝对值的平均（保持时间顺序，不按排序后的值算）。
        let mut diffs: Vec<u64> = Vec::new();
        let seq: Vec<u32> = self
            .samples
            .iter()
            .filter(|s| s.ok)
            .map(|s| s.rtt_ms)
            .collect();
        for w in seq.windows(2) {
            diffs.push(w[0].abs_diff(w[1]) as u64);
        }
        if !diffs.is_empty() {
            m.jitter_ms = clamp_ms(diffs.iter().sum::<u64>() / diffs.len() as u64);
        }
        // 不稳定度：标准差 / 均值。
        let mean = sum as f64 / oks.len() as f64;
        if oks.len() > 1 && mean > 0.0 {
            let var = oks
                .iter()
                .map(|v| {
                    let d = *v as f64 - mean;
                    d * d
                })
                .sum::<f64>()
                / (oks.len() - 1) as f64;
            let sd = var.sqrt();
            m.instability_pmm = clamp_permille((sd / mean * 1000.0) as u64);
        }
        m
    }

    /// 是否越过降级阈值。任一指标越线即为 degraded；样本不足时**不判降级**
    /// （否则刚启动就把线路标成 degraded，等于用噪声做决策）。
    pub fn is_degraded(
        &self,
        now_ms: u64,
        rtt_limit: u32,
        loss_limit: u32,
        jitter_limit: u32,
    ) -> bool {
        let m = self.metrics(now_ms);
        if !m.confident() {
            return false;
        }
        m.rtt_ms > rtt_limit || m.loss_pmm > loss_limit || m.jitter_ms > jitter_limit
    }
}

fn permille(part: u64, whole: u64) -> u32 {
    if whole == 0 {
        return 0;
    }
    clamp_permille(part.saturating_mul(1000) / whole)
}

fn clamp_permille(v: u64) -> u32 {
    if v > 1000 {
        1000
    } else {
        v as u32
    }
}

/// RTT/抖动的合理上限钳位：探测超时或内核异常值不该把均值拉到荒谬程度。
fn clamp_ms(v: u64) -> u32 {
    if v > u32::MAX as u64 {
        u32::MAX
    } else {
        v as u32
    }
}

/// 指数滑动平均（用于把「窗口指标」再平滑一次，抑制桶重排的抖动）。
#[derive(Debug, Clone, Copy)]
pub struct Ewma {
    value: f64,
    initialized: bool,
    /// 平滑系数千分比（`global.smoothing_permille`）：越大越重视新值。
    alpha_permille: u32,
}

impl Ewma {
    pub fn new(alpha_permille: u32) -> Ewma {
        Ewma {
            value: 0.0,
            initialized: false,
            alpha_permille: alpha_permille.clamp(1, 1000),
        }
    }

    pub fn push(&mut self, x: f64) -> f64 {
        let a = self.alpha_permille as f64 / 1000.0;
        if !self.initialized {
            self.value = x;
            self.initialized = true;
            return x;
        }
        self.value = self.value * (1.0 - a) + x * a;
        self.value
    }

    pub fn value(&self) -> f64 {
        self.value
    }

    pub fn initialized(&self) -> bool {
        self.initialized
    }

    pub fn reset(&mut self) {
        self.value = 0.0;
        self.initialized = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(at: u64, rtt: u32) -> Sample {
        Sample::success(at, rtt, "icmp")
    }

    #[test]
    fn empty_window_is_not_pretending_to_be_measured() {
        let w = SlidingWindow::default();
        let m = w.metrics(1000);
        assert_eq!(m.samples, 0);
        assert!(!m.confident());
        assert!(m.describe().starts_with("采样中"), "{}", m.describe());
    }

    #[test]
    fn loss_is_permille_of_all_samples() {
        let mut w = SlidingWindow::default();
        for i in 0..10 {
            if i % 2 == 0 {
                w.push(ok(i, 40));
            } else {
                w.push(Sample::failure(i, "icmp"));
            }
        }
        let m = w.metrics(100);
        assert_eq!(m.samples, 10);
        assert_eq!(m.ok_samples, 5);
        assert_eq!(m.loss_pmm, 500, "一半失败应是 500‰");
        assert_eq!(m.rtt_ms, 40);
        assert_eq!(m.last_fail_ms, 9);
        assert_eq!(m.last_ok_ms, 8);
    }

    #[test]
    fn jitter_and_instability_need_spread() {
        let mut w = SlidingWindow::default();
        for (i, rtt) in [50u32, 52, 48, 50, 51].iter().enumerate() {
            w.push(ok(i as u64, *rtt));
        }
        let m = w.metrics(100);
        assert!(m.jitter_ms <= 4, "小抖动不该算大: {m:?}");
        assert!(m.instability_pmm < 100, "{m:?}");
        // 剧烈抖动的线路：不稳定度必须显著更高
        let mut w2 = SlidingWindow::default();
        for (i, rtt) in [20u32, 400, 25, 380, 22].iter().enumerate() {
            w2.push(ok(i as u64, *rtt));
        }
        let m2 = w2.metrics(100);
        assert!(
            m2.instability_pmm > m.instability_pmm * 3,
            "{m:?} vs {m2:?}"
        );
        assert!(m2.jitter_ms > 100, "{m2:?}");
        assert_eq!(m2.min_ms, 20);
        assert_eq!(m2.max_ms, 400);
        assert!(m2.p95_ms >= 380);
        assert_eq!(m2.rtt_ms, (20 + 400 + 25 + 380 + 22) / 5);
    }

    #[test]
    fn window_evicts_oldest_and_keeps_span_bounded() {
        let mut w = SlidingWindow::new(4);
        for i in 0..10u64 {
            w.push(ok(i, 30));
        }
        assert_eq!(w.len(), 4);
        assert_eq!(w.span_ms(), 3);
        assert_eq!(w.last().unwrap().at_ms, 9);
        // 只保留最近的样本：老的一次超时必须被挤出去
        let m = w.metrics(10);
        assert_eq!(m.loss_pmm, 0);
    }

    #[test]
    fn degraded_needs_confident_samples() {
        let mut w = SlidingWindow::default();
        // 3 个样本、RTT 极高：不足以判降级（噪声期不做决策）
        for i in 0..3 {
            w.push(ok(i, 900));
        }
        assert!(
            !w.is_degraded(10, 150, 50, 40),
            "样本不足时不能用降级污染状态"
        );
        w.push(ok(3, 900));
        w.push(ok(4, 900));
        assert!(w.is_degraded(10, 150, 50, 40), "RTT 超限必须判降级");
        // 抖动超限
        let mut j = SlidingWindow::default();
        for (i, rtt) in [30u32, 90, 30, 90, 30].iter().enumerate() {
            j.push(ok(i as u64, *rtt));
        }
        assert!(j.is_degraded(10, 500, 50, 20), "抖动超限必须判降级");
        // 丢包超限
        let mut l = SlidingWindow::default();
        for i in 0..10u64 {
            if i < 8 {
                l.push(ok(i, 30));
            } else {
                l.push(Sample::failure(i, "icmp"));
            }
        }
        assert!(l.is_degraded(10, 500, 50, 999), "200‰ 丢包必须判降级");
    }

    #[test]
    fn age_reflects_last_sample() {
        let mut w = SlidingWindow::default();
        w.push(ok(1000, 30));
        assert_eq!(w.metrics(3500).age_ms, 2500, "指标新鲜度必须暴露给上层");
    }

    #[test]
    fn ewma_starts_with_first_value_and_smooths() {
        let mut e = Ewma::new(500);
        assert!(!e.initialized());
        assert_eq!(e.push(100.0), 100.0);
        assert_eq!(e.push(0.0), 50.0);
        assert!(e.value() < 100.0);
        // alpha=1000 时完全跟随新值
        let mut f = Ewma::new(1000);
        f.push(10.0);
        assert_eq!(f.push(90.0), 90.0);
        // alpha 越界必须被钳位，而不是算出负权重
        let mut g = Ewma::new(0);
        g.push(5.0);
        assert!(g.push(10.0) >= 5.0);
        g.reset();
        assert!(!g.initialized());
    }

    #[test]
    fn permille_helpers_clamp() {
        assert_eq!(permille(1, 3), 333);
        assert_eq!(permille(5, 0), 0, "除零必须给 0 而不是 panic");
        assert_eq!(clamp_permille(2000), 1000);
        assert_eq!(clamp_ms(u64::from(u32::MAX) + 1), u32::MAX);
    }
}

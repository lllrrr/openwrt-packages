//! 去抖与滞回：让「决策」不等于「每次采样都改口」。
//!
//! 为什么这一层必须独立存在：
//!
//! * 桶重排会改变**新建连接**的出口分布。如果每 1 秒的采样都能把桶搬一遍，
//!   用户看到的就是「负载均衡」在来回抖动，实际效果是每条线路的平均连接数
//!   反而更差（连接建立时落在哪条线，取决于那一刻的桶图）。
//! * 主备回切更严重：每次回切都意味着一次全量 conntrack 语义变化，
//!   在线的长连接虽然保持原出口，但新建连接会整体迁移。
//!
//! 因此所有「是否变更」的判断都集中在这里，其它模块只描述「想要什么」。

/// 整数钳位：所有百分比/千分比计算都过一遍，避免溢出后变负数。
pub fn clamp_i64(v: i64, lo: i64, hi: i64) -> i64 {
    if v < lo {
        lo
    } else if v > hi {
        hi
    } else {
        v
    }
}

/// 千分比钳位（0~1000）。
pub fn clamp_permille(v: i64) -> u32 {
    clamp_i64(v, 0, 1000) as u32
}

/// 评分钳位：公式上限就是 100 分，钳位保证任何权重配置都不会算出越界分数。
pub fn clamp_score(v: f64) -> f64 {
    if v.is_nan() || v.is_infinite() {
        return 0.0;
    }
    v.clamp(0.0, 100.0)
}

/// 一轮允许搬动的桶数上限。
///
/// `max_shift_permille` 是相对总桶数的千分比；无论如何至少允许搬 1 个桶，
/// 否则小桶数（例如 8 桶）配置下限流会把算法彻底锁死。
pub fn shift_limit(buckets: usize, max_shift_permille: u32) -> usize {
    if buckets == 0 {
        return 0;
    }
    let raw = (buckets as u64 * u64::from(max_shift_permille) / 1000) as usize;
    raw.max(1).min(buckets)
}

/// 连续命中 + 最小稳定时间的去抖器。
///
/// 用于两处：
/// 1. 回切（主线路需连续成功 N 次且保持 M 毫秒）；
/// 2. 游戏择优（候选线路需明显更优且稳定一段时间才切换）。
#[derive(Debug, Clone, Copy, Default)]
pub struct Debounce {
    /// 需要的连续命中次数。
    needed: u32,
    /// 需要的最短持续时间（毫秒）。
    min_stable_ms: u64,
    /// 当前连续命中次数。
    count: u32,
    /// 本轮连续命中的起始时间。
    since_ms: u64,
    /// 上一次达到条件的时间（用于「已满足后不反复触发」）。
    last_fired_ms: u64,
    /// 是否曾经触发过（触发后需要一次未命中重新武装）。
    armed: bool,
}

impl Debounce {
    pub fn new(needed: u32, min_stable_ms: u64) -> Debounce {
        Debounce {
            needed: needed.max(1),
            min_stable_ms,
            count: 0,
            since_ms: 0,
            last_fired_ms: 0,
            armed: true,
        }
    }

    /// 记录一次观察，返回本轮是否**首次**满足条件。
    ///
    /// 「首次」很关键：满足条件后如果每轮都返回 true，上层就会反复执行同一个
    /// 切换动作（反复 replace 规则、反复写审计日志）。
    pub fn offer(&mut self, hit: bool, now_ms: u64) -> bool {
        if !hit {
            self.count = 0;
            self.since_ms = 0;
            self.armed = true;
            return false;
        }
        if self.count == 0 {
            self.since_ms = now_ms;
        }
        self.count = self.count.saturating_add(1);
        let enough_count = self.count >= self.needed;
        let enough_time = now_ms.saturating_sub(self.since_ms) >= self.min_stable_ms;
        if enough_count && enough_time && self.armed {
            self.armed = false;
            self.last_fired_ms = now_ms;
            return true;
        }
        false
    }

    pub fn count(&self) -> u32 {
        self.count
    }

    pub fn last_fired_ms(&self) -> u64 {
        self.last_fired_ms
    }

    /// 强制复位（人工干预、配置变更后重新计时）。
    pub fn reset(&mut self) {
        self.count = 0;
        self.since_ms = 0;
        self.armed = true;
    }
}

/// 相对优势千分比：`a` 比 `b` 好多少（正值表示 a 更优）。
///
/// 用「相对」而不是「绝对差」，是因为评分本身在 0~100 上，
/// 线路质量差异大时 2 分不重要，两条线路都很差时 2 分可能就是唯一区别；
/// 但反过来，绝对差门槛也保留：`min_advantage_permille` 之外再加一个
/// 最小绝对分差，避免「两条线路几乎打平时反复横跳」。
pub fn advantage_permille(candidate: f64, current: f64) -> i64 {
    if current <= 0.01 {
        // 当前线路评分为 0 附近：任何更好的候选都是巨大优势。
        return if candidate > 0.01 { 1000 } else { 0 };
    }
    ((candidate - current) / current * 1000.0).round() as i64
}

/// 距上次变更是否已过最小间隔。
///
/// `last_change_ms == 0` 表示「从未变更过」：此时不存在间隔约束，
/// 否则进程启动后的第一次决策会被一个不存在的历史切换永久卡住。
pub fn interval_elapsed(last_change_ms: u64, now_ms: u64, min_interval_ms: u64) -> bool {
    if last_change_ms == 0 {
        return true;
    }
    now_ms.saturating_sub(last_change_ms) >= min_interval_ms
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamps_never_wrap() {
        assert_eq!(clamp_permille(-10), 0);
        assert_eq!(clamp_permille(5000), 1000);
        assert_eq!(clamp_permille(333), 333);
        assert_eq!(clamp_score(f64::NAN), 0.0);
        assert_eq!(clamp_score(-5.0), 0.0);
        assert_eq!(clamp_score(9999.0), 100.0);
    }

    #[test]
    fn shift_limit_allows_progress_on_small_sets() {
        assert_eq!(shift_limit(64, 100), 6);
        assert_eq!(
            shift_limit(8, 10),
            1,
            "小桶数必须至少能搬 1 个，否则算法被锁死"
        );
        assert_eq!(shift_limit(0, 500), 0);
        assert_eq!(shift_limit(64, 1000), 64);
    }

    #[test]
    fn debounce_needs_count_and_time() {
        let mut d = Debounce::new(3, 1000);
        assert!(!d.offer(true, 0));
        assert!(!d.offer(true, 100), "连续次数与稳定时间都还没够");
        assert!(!d.offer(true, 500));
        assert!(d.offer(true, 1100), "次数与时间都满足时首次触发");
        assert!(
            !d.offer(true, 2000),
            "已触发后必须保持沉默，直到出现一次未命中"
        );
        assert!(!d.offer(false, 2100), "未命中本身不触发任何东西");
        // 「重新武装」= 次数与计时从头再来，不是「立刻又能触发一次」
        assert!(!d.offer(true, 3300), "未命中后必须重新累计次数");
        assert!(!d.offer(true, 3400));
        assert!(
            !d.offer(true, 3500),
            "次数已满但稳定时间未达（本轮起点 3300ms）"
        );
        assert!(d.offer(true, 4400), "重新满足次数与时间后再次触发");
    }

    #[test]
    fn debounce_single_shot_with_zero_time() {
        let mut d = Debounce::new(1, 0);
        assert!(d.offer(true, 5));
        assert_eq!(d.last_fired_ms(), 5);
        assert!(!d.offer(true, 6));
        d.reset();
        assert!(d.offer(true, 7));
    }

    #[test]
    fn advantage_is_relative_with_sane_edges() {
        assert!(
            advantage_permille(60.0, 50.0) > 150,
            "20% 优势必须超过默认滞回"
        );
        assert_eq!(advantage_permille(50.0, 50.0), 0);
        assert!(advantage_permille(40.0, 50.0) < 0, "更差就是负优势");
        assert_eq!(
            advantage_permille(10.0, 0.0),
            1000,
            "当前为 0 分时任何有效候选都是巨大优势"
        );
        assert_eq!(
            advantage_permille(0.0, 0.0),
            0,
            "双方都无数据时不该假装有人更优"
        );
    }

    #[test]
    fn interval_gate_is_monotonic() {
        assert!(interval_elapsed(0, 10, 10_000), "从未变更过不受间隔约束");
        assert!(interval_elapsed(1000, 1000, 0));
        assert!(!interval_elapsed(1000, 1999, 1000));
        assert!(interval_elapsed(1000, 2000, 1000));
        // 时间戳接近上限时只能得出「才过 5ms」，绝不能因下溢变成「已过很久」
        assert!(
            !interval_elapsed(u64::MAX - 5, u64::MAX, 1000),
            "回绕不得变成负数或巨大间隔"
        );
        assert!(interval_elapsed(u64::MAX - 5000, u64::MAX, 1000));
    }
}

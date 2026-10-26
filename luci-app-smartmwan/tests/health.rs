//! 集成测试：健康层的**时间线**行为。
//!
//! 单测断言的是单次 `record()` 的迁移；这里串起整条时间线：
//! 未测量 → 健康 → 连续失败转故障 → 恢复预热 → 回到健康，以及
//! 「本机自己的问题不算线路故障」这条诚实性要求。

use std::sync::Arc;

use smartmwan::config::schema::{Config, HealthConfig, WanConfig};
use smartmwan::health::probe::{self, Outcome, ProbeResult, Prober, Request};
use smartmwan::health::{run_round, Registry, State};
use smartmwan::logging;
use smartmwan::system::interface::Resolved;
use tokio::sync::watch;

fn cfg_with(wans: &[&str], health: &HealthConfig) -> Config {
    let mut c = Config::default();
    c.global.health = health.clone();
    for n in wans {
        c.wans.push(WanConfig {
            name: (*n).into(),
            enabled: true,
            health: health.clone(),
            ..Default::default()
        });
    }
    c
}

fn resolved(name: &str) -> Resolved {
    Resolved {
        wan: name.to_string(),
        device: format!("dev-{name}"),
        ifindex: 3,
        link_up: true,
        gw4: "10.0.0.1".parse().ok(),
        gw6: None,
        src4: "10.0.0.2".parse().ok(),
        src6: None,
        link_default: false,
        notes: vec![],
    }
}

/// 固定结果的探测器：一轮里每条线路都拿到同一个结论。
struct Fixed {
    outcome: Outcome,
}

impl Prober for Fixed {
    fn probe(&self, req: Request) -> probe::BoxFuture<'_, smartmwan::Result<ProbeResult>> {
        let outcome = self.outcome.clone();
        Box::pin(async move {
            Ok(ProbeResult {
                req,
                at_ms: logging::now_ms(),
                outcome,
                resolved: None,
            })
        })
    }
}

/// 短阈值配置：把预热压到 0，让状态迁移只由**次数**决定，测试不必真等几秒。
fn fast_health() -> HealthConfig {
    HealthConfig {
        interval_ms: 100,
        timeout_ms: 50,
        warmup_ms: 0,
        ..Default::default()
    }
}

async fn rounds(cfg: &Config, r: &Registry, outcome: Outcome, times: usize) {
    let (_tx, cancel) = watch::channel(false);
    for _ in 0..times {
        let resolved: Vec<Resolved> = cfg.wans.iter().map(|w| resolved(&w.name)).collect();
        run_round(
            Arc::new(Fixed {
                outcome: outcome.clone(),
            }),
            cfg,
            &resolved,
            r,
            cancel.clone(),
        )
        .await;
    }
}

#[tokio::test]
async fn a_line_walks_the_whole_state_machine_and_comes_back() {
    let cfg = cfg_with(&["wan"], &fast_health());
    let r = Registry::new();

    // ① 起始：从未测量。UI 必须显示「未测量」，不能显示「健康」。
    let snap = r.snapshot(logging::now_ms());
    assert!(!snap.measured, "没跑过探测不得声称已测量");
    assert!(snap.get("wan").is_none() || snap.get("wan").unwrap().state == State::Unknown);

    // ② 连续成功 → Healthy。
    rounds(&cfg, &r, Outcome::Reply { rtt_ms: 10 }, 10).await;
    let snap = r.snapshot(logging::now_ms());
    assert_eq!(snap.get("wan").unwrap().state, State::Healthy);
    assert!(snap.measured, "跑过探测后必须标记为已测量");

    // ③ 连续超时 → Failed。
    rounds(&cfg, &r, Outcome::Timeout, 15).await;
    let snap = r.snapshot(logging::now_ms());
    let s = snap.get("wan").unwrap().state;
    assert_eq!(s, State::Failed, "连续超时必须判故障，实际 {s:?}");

    // ④ 恢复：先脱离 Failed（窗口里还留着失败样本，所以第一步通常是
    // Recovering/Degraded 而不是直接 Healthy —— 滑窗记忆是有意的，
    // 刚抖完的线路不该立刻被当成完全健康）。
    rounds(&cfg, &r, Outcome::Reply { rtt_ms: 8 }, 6).await;
    let snap = r.snapshot(logging::now_ms());
    let s = snap.get("wan").unwrap().state;
    assert_ne!(s, State::Failed, "有成功探测后就不得停留在故障态：{s:?}");

    // 继续成功，直到滑窗（容量 90）把失败样本整个挤出去 → 回到 Healthy。
    // 失败样本留在窗口里时不该宣称健康：刚抖完的线路要拿数据证明自己稳了。
    rounds(&cfg, &r, Outcome::Reply { rtt_ms: 8 }, 100).await;
    let snap = r.snapshot(logging::now_ms());
    assert_eq!(
        snap.get("wan").unwrap().state,
        State::Healthy,
        "窗口刷新后必须回到健康"
    );
}

/// **本机的问题不是线路的问题**：`LocalError` 不得计入线路失败。
///
/// 这条一旦写反，设备没解锁 ping socket 时所有线路都会被判故障，
/// 用户看到「网络坏了」，而真相是「插件没权限发 ICMP」。
#[tokio::test]
async fn local_problems_never_count_as_line_failures() {
    let cfg = cfg_with(&["wan"], &fast_health());
    let r = Registry::new();
    rounds(&cfg, &r, Outcome::Reply { rtt_ms: 10 }, 10).await;
    assert_eq!(
        r.snapshot(logging::now_ms()).get("wan").unwrap().state,
        State::Healthy
    );

    rounds(
        &cfg,
        &r,
        Outcome::LocalError("不允许创建 ICMP socket".into()),
        15,
    )
    .await;
    let snap = r.snapshot(logging::now_ms());
    let h = snap.get("wan").unwrap();
    assert_ne!(
        h.state,
        State::Failed,
        "本机错误不得把线路判成故障：{:?}",
        h.blocked_reason
    );
}

/// 删除线路后追踪器必须一起消失：否则界面会一直显示一条已不存在的线路，
/// 它的旧结论还可能被调度层拿去决策。
#[tokio::test]
async fn removing_a_line_removes_its_tracker() {
    let mut cfg = cfg_with(&["wan", "wan2"], &fast_health());
    let r = Registry::new();
    rounds(&cfg, &r, Outcome::Reply { rtt_ms: 10 }, 3).await;
    {
        let snap = r.snapshot(logging::now_ms());
        assert_eq!(snap.wan.len(), 2);
    }

    cfg.wans.retain(|w| w.name != "wan2");
    r.ensure(&cfg, logging::now_ms());
    let snap = r.snapshot(logging::now_ms());
    assert_eq!(snap.wan.len(), 1);
    assert!(snap.get("wan2").is_none());
}

/// 指标滑窗要跟着**最近**的样本走，而不是整段历史的平均。
#[tokio::test]
async fn metrics_follow_the_recent_window() {
    let cfg = cfg_with(&["wan"], &fast_health());
    let r = Registry::new();
    rounds(&cfg, &r, Outcome::Reply { rtt_ms: 200 }, 20).await;
    let slow = r
        .snapshot(logging::now_ms())
        .get("wan")
        .unwrap()
        .metrics
        .clone()
        .unwrap();
    rounds(&cfg, &r, Outcome::Reply { rtt_ms: 10 }, 20).await;
    let fast = r
        .snapshot(logging::now_ms())
        .get("wan")
        .unwrap()
        .metrics
        .clone()
        .unwrap();
    assert!(
        fast.rtt_ms < slow.rtt_ms,
        "窗口必须跟着最近样本走：慢 {}ms / 快 {}ms",
        slow.rtt_ms,
        fast.rtt_ms
    );
}

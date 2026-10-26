//! 集成测试：调度层在**两条线路**上的实际行为。
//!
//! 单测验证的是桶分配算法的内部不变式；这里验证的是「用户改一个配置，
//! 桶图会按预期变」以及「没变化就不碰数据面」。

use std::collections::BTreeMap;

use smartmwan::config::schema::{Algorithm, Config, Mode, WanConfig};
use smartmwan::health::{Metrics, Snapshot, State, WanHealth};
use smartmwan::scheduler::balancing::Load;
use smartmwan::scheduler::Scheduler;

fn line(name: &str, weight: u32) -> WanConfig {
    WanConfig {
        name: name.to_string(),
        enabled: true,
        weight,
        ..Default::default()
    }
}

/// 全部线路健康、指标可信的快照。
fn healthy_snapshot(names: &[&str], now: u64) -> Snapshot {
    let mut wan = BTreeMap::new();
    for n in names {
        wan.insert(
            (*n).to_string(),
            WanHealth {
                name: (*n).to_string(),
                state: State::Healthy,
                metrics: Some(Metrics {
                    samples: 40,
                    ok_samples: 40,
                    rtt_ms: 20,
                    jitter_ms: 2,
                    loss_pmm: 0,
                    ..Default::default()
                }),
                last_outcome: Some("reply".into()),
                last_transition: None,
                warmup_remaining_ms: 0,
                blocked_reason: None,
                state_since_ms: now,
                consec_ok: 10,
                consec_fail: 0,
                probes_total: 40,
                probes_ignored: 0,
            },
        );
    }
    Snapshot {
        wan,
        at_ms: now,
        measured: true,
    }
}

fn loads(names: &[&str]) -> BTreeMap<String, Load> {
    names
        .iter()
        .map(|n| {
            (
                (*n).to_string(),
                Load {
                    conns: 0,
                    new_conns: 0,
                    rx_kbps: 0,
                    tx_kbps: 0,
                    down_kbps: 0,
                    up_kbps: 0,
                    conn_limit: 0,
                    measured: true,
                },
            )
        })
        .collect()
}

/// 桶数落在各线路上的分布（按槽位计数）。
fn share(outcome: &smartmwan::scheduler::Outcome, slots: usize) -> Vec<usize> {
    let mut v = vec![0usize; slots + 1];
    for b in &outcome.buckets {
        v[usize::from(*b)] += 1;
    }
    v
}

/// 权重必须真的体现在桶数上：3:1 的两条线路，桶数也应当接近 3:1，
/// 而不是各占一半（那是「权重没接上」最典型的假象）。
#[test]
fn weights_show_up_in_the_bucket_map() {
    let mut cfg = Config::default();
    cfg.global.enabled = true;
    cfg.global.mode = Mode::Balance;
    cfg.global.algorithm = Algorithm::WeightedHash;
    cfg.global.buckets = 64;
    cfg.wans.push(line("wan", 3));
    cfg.wans.push(line("wan2", 1));

    let snap = healthy_snapshot(&["wan", "wan2"], 1000);
    let loads = loads(&["wan", "wan2"]);
    let mut s = Scheduler::new();
    let out = s.decide(&cfg, &snap, &loads, 1000).unwrap();

    let heavy = share(&out, 2)[1];
    let light = share(&out, 2)[2];
    assert!(
        heavy > light,
        "权重大的线路应拿到更多桶：{heavy} vs {light}"
    );
    // 3:1 的配置下，大权重一侧应拿约 3/4（允许算法离散，给 ±10% 余量）。
    let ratio = heavy as f64 / (heavy + light) as f64;
    assert!(
        (0.65..=0.85).contains(&ratio),
        "3:1 的权重应落在约 75%，实际 {ratio:.2}"
    );
    assert_eq!(heavy + light, 64, "所有桶都必须分配出去");
}

/// 同样的配置跑两次（或重启后），桶图必须一致 —— 否则已建立连接会换出口。
#[test]
fn the_same_configuration_produces_the_same_buckets() {
    let mk = || {
        let mut cfg = Config::default();
        cfg.global.enabled = true;
        cfg.global.mode = Mode::Balance;
        cfg.global.algorithm = Algorithm::SrcIpDstIp;
        cfg.global.buckets = 32;
        cfg.wans.push(line("wan", 1));
        cfg.wans.push(line("wan2", 1));
        cfg
    };
    let snap = healthy_snapshot(&["wan", "wan2"], 1000);
    let loads = loads(&["wan", "wan2"]);
    let a = Scheduler::new().decide(&mk(), &snap, &loads, 1000).unwrap();
    let b = Scheduler::new().decide(&mk(), &snap, &loads, 9000).unwrap();
    assert_eq!(a.buckets, b.buckets, "桶图必须可复现，与时间无关");
}

/// 决策没变 ⇒ `changed=false`：这是「不做事」的证据。
///
/// 高频全量重建是本项目的红线之一；`changed` 是数据面前唯一的闸门，
/// 它一旦恒为 true，每个探测周期都会重写一遍 nft。
#[test]
fn an_unchanged_decision_reports_changed_false() {
    let mut cfg = Config::default();
    cfg.global.enabled = true;
    cfg.global.mode = Mode::Balance;
    cfg.global.buckets = 16;
    cfg.wans.push(line("wan", 1));
    cfg.wans.push(line("wan2", 1));
    let snap = healthy_snapshot(&["wan", "wan2"], 1000);
    let loads = loads(&["wan", "wan2"]);

    let mut s = Scheduler::new();
    let first = s.decide(&cfg, &snap, &loads, 1000).unwrap();
    assert!(first.changed, "首次决策必然是变更");
    let second = s.decide(&cfg, &snap, &loads, 2000).unwrap();
    assert!(!second.changed, "条件没变就不该产生数据面写入");
}

/// 全线路不可用 ⇒ 桶全 0 且 `all_dead=true`，绝不能显示「正常」。
#[test]
fn all_lines_down_means_no_traffic_and_all_dead() {
    let mut cfg = Config::default();
    cfg.global.enabled = true;
    cfg.global.mode = Mode::Balance;
    cfg.global.buckets = 16;
    cfg.wans.push(line("wan", 1));
    cfg.wans.push(line("wan2", 1));

    let mut snap = healthy_snapshot(&["wan", "wan2"], 1000);
    for h in snap.wan.values_mut() {
        h.state = State::Failed;
        h.metrics = None;
        h.consec_fail = 9;
        h.consec_ok = 0;
    }
    let loads = loads(&["wan", "wan2"]);
    let out = Scheduler::new().decide(&cfg, &snap, &loads, 1000).unwrap();
    assert!(out.all_dead, "全灭必须显式报告");
    assert!(
        !out.carries_traffic(),
        "没有可用出口时不得分流：{:?}",
        out.buckets
    );
    assert!(
        !out.reason.is_empty() && !out.notes.is_empty(),
        "必须给出为什么不分流"
    );
}

/// 停用配置：决策必须与数据面一致（内核已清场，UI 就不能再声称承载流量）。
#[test]
fn a_disabled_config_decides_no_traffic() {
    let mut cfg = Config::default();
    cfg.global.enabled = false;
    cfg.global.buckets = 16;
    cfg.wans.push(line("wan", 1));
    let snap = healthy_snapshot(&["wan"], 1000);
    let loads = loads(&["wan"]);
    let out = Scheduler::new().decide(&cfg, &snap, &loads, 1000).unwrap();
    assert!(!out.carries_traffic(), "停用时不得承载流量");
}

/// 七种算法都要能产出完整桶图：任一算法在某条路径上抛错，
/// 界面上看到的就是「没有线路」，而真相是算法不被支持。
#[test]
fn every_algorithm_produces_a_full_bucket_map() {
    let algorithms = [
        Algorithm::SrcIp,
        Algorithm::SrcIpSrcPort,
        Algorithm::SrcIpDstIp,
        Algorithm::SrcIpDstIpDstPort,
        Algorithm::FullFiveTuple,
        Algorithm::LeastNewConnections,
        Algorithm::LeastTraffic,
        Algorithm::WeightedHash,
        Algorithm::WeightedEcmp,
    ];
    let snap = healthy_snapshot(&["wan", "wan2"], 1000);
    let loads = loads(&["wan", "wan2"]);
    for alg in algorithms {
        let mut cfg = Config::default();
        cfg.global.enabled = true;
        cfg.global.mode = Mode::Balance;
        cfg.global.algorithm = alg;
        cfg.global.buckets = 24;
        cfg.wans.push(line("wan", 1));
        cfg.wans.push(line("wan2", 1));
        let out = Scheduler::new().decide(&cfg, &snap, &loads, 1000).unwrap();
        assert_eq!(out.buckets.len(), 24, "{:?} 桶数不对", alg);
        assert!(
            out.carries_traffic(),
            "{:?}：两条健康线路下必须有桶被分配（实际算法 {:?}，notes {:?}）",
            alg,
            out.algorithm,
            out.notes
        );
    }
}

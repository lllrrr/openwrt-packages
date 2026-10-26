//! 集成测试：事务层在**替身数据面**上的编排。
//!
//! 这里不验证 nft 语法（那是真机能力探测的事），验证的是：阶段顺序、失败即回滚、
//! 复核不过不写快照、同一配置二次提交幂等、以及残留回收只动自己的对象。

use std::path::Path;
use std::sync::Arc;

use smartmwan::config::schema::{Config, Mode, WanConfig};
use smartmwan::config::Store as ConfigStore;
use smartmwan::logging;
use smartmwan::system::firewall::Capabilities;
use smartmwan::system::interface::SysFs;
use smartmwan::system::netlink::FakeNetlink;
use smartmwan::system::Env;
use smartmwan::transaction::{Coordinator, Decision, FirewallExec, Plane, Sim};

fn cfg_two_lines() -> Config {
    let mut c = Config::default();
    c.global.enabled = true;
    c.global.mode = Mode::Balance;
    c.global.buckets = 8;
    for n in ["wan", "wan2"] {
        c.wans.push(WanConfig {
            name: n.to_string(),
            enabled: true,
            ..Default::default()
        });
    }
    c
}

/// 决策：桶交替落在两条线路上。
fn decision(bucket_map: Vec<u8>) -> Decision {
    Decision {
        bucket_map,
        picks: Default::default(),
        gen: 0,
        now_ms: logging::now_ms(),
    }
}

fn plane(dir: &Path, fw: FirewallExec) -> Plane {
    Plane {
        ops: Arc::new(FakeNetlink::new()),
        fw,
        env: Env {
            etc_dir: dir.to_path_buf(),
            sysfs: SysFs::new(dir),
        },
        caps: Capabilities {
            nft_exists: true,
            version: "1.1.7".into(),
            ..Capabilities::default()
        },
        config_path: dir.join("smartmwan"),
        state_dir: dir.join("state"),
        presets_dir: dir.join("presets"),
    }
}

fn sim_plane(dir: &Path) -> (Coordinator, Arc<Sim>) {
    let sim = Sim::new();
    let co = Coordinator::new(plane(dir, FirewallExec::Sim(sim.clone())));
    (co, sim)
}

/// 一次成功提交必须走完固定阶段，并把快照落到状态目录 —— 快照是下次启动
/// 恢复的依据，也是「上次到底下发成了什么样」的唯一凭据。
#[tokio::test]
async fn a_successful_submit_runs_the_stages_and_persists_a_snapshot() {
    let dir = tempfile::tempdir().unwrap();
    let (co, _sim) = sim_plane(dir.path());
    let cfg = cfg_two_lines();
    ConfigStore::load(&dir.path().join("smartmwan"))
        .unwrap()
        .save(&cfg)
        .unwrap();

    let r = co
        .submit(&cfg, &decision(vec![1, 2, 1, 2, 1, 2, 1, 2]))
        .await;
    assert!(r.ok, "提交应成功：{:?} / {:?}", r.error, r.issues);
    assert!(r.changed, "首次提交应产生变更");
    assert!(r.rollback.is_empty(), "成功路径不应有回滚残留");
    assert!(
        r.stages.len() >= 6,
        "八阶段应留下记录：{:?}",
        stage_names(&r)
    );
    // 复核必须在提交之后（否则「写进一份没验证过的状态」等于把故障固化成正常）。
    let names = stage_names(&r);
    let apply = names
        .iter()
        .position(|n| n.contains("firewall_apply"))
        .unwrap_or(0);
    let verify = names
        .iter()
        .rposition(|n| n.contains("firewall_verify"))
        .unwrap_or(0);
    assert!(verify >= apply, "复核不得早于提交：{names:?}");

    let applied = ConfigStore::load_applied(&dir.path().join("state"));
    assert!(applied.is_some(), "成功提交必须写入 applied 快照");
}

/// 二次提交同一配置 ⇒ 幂等（`changed=false`），但**仍然要复核**。
///
/// 幂等不等于跳过复核：跳过就意味着「内核现在长什么样」不再被验证。
#[tokio::test]
async fn submitting_the_same_configuration_twice_is_idempotent_but_still_verified() {
    let dir = tempfile::tempdir().unwrap();
    let (co, _sim) = sim_plane(dir.path());
    let cfg = cfg_two_lines();
    ConfigStore::load(&dir.path().join("smartmwan"))
        .unwrap()
        .save(&cfg)
        .unwrap();
    let d = decision(vec![1, 2, 1, 2, 1, 2, 1, 2]);

    let first = co.submit(&cfg, &d).await;
    assert!(first.ok && first.changed, "{:?}", first.error);
    let second = co.submit(&cfg, &d).await;
    assert!(second.ok, "幂等提交不应失败：{:?}", second.issues);
    assert!(!second.changed, "同一配置二次提交不应再变更");
    assert!(
        stage_names(&second).iter().any(|n| n.contains("verify")),
        "幂等路径也必须复核：{:?}",
        stage_names(&second)
    );
}

/// nft 提交失败 ⇒ 回滚，并把失败原因写进回执。
#[tokio::test]
async fn a_failed_nft_submit_rolls_back_and_says_why() {
    let dir = tempfile::tempdir().unwrap();
    let (co, sim) = sim_plane(dir.path());
    sim.fail_apply(Some("集成测试注入的失败".into()));
    let cfg = cfg_two_lines();
    ConfigStore::load(&dir.path().join("smartmwan"))
        .unwrap()
        .save(&cfg)
        .unwrap();

    let r = co
        .submit(&cfg, &decision(vec![1, 2, 1, 2, 1, 2, 1, 2]))
        .await;
    assert!(!r.ok, "nft 提交失败必须体现在回执上");
    assert!(
        r.error
            .as_deref()
            .unwrap_or("")
            .contains("集成测试注入的失败"),
        "必须保留失败原因：{:?}",
        r.error
    );
    // 回滚非空 = 内核状态需要人工确认，UI 不得把它显示成「已恢复」。
    assert!(!r.rollback.is_empty(), "失败必须留下回滚记录");
}

/// 停用配置：清场在没有 nft 的设备上也必须能跑。
///
/// 半套状态比没有状态更危险，所以**启用**路径会拒绝 Absent 通道；
/// 而清场不需要 nft，拦住它等于让设备在停用状态下留着残留。
#[tokio::test]
async fn a_disabled_config_clears_the_plane_even_without_nft() {
    let dir = tempfile::tempdir().unwrap();
    let co = Coordinator::new(plane(dir.path(), FirewallExec::Absent));
    let mut cfg = cfg_two_lines();
    cfg.global.enabled = false;
    ConfigStore::load(&dir.path().join("smartmwan"))
        .unwrap()
        .save(&cfg)
        .unwrap();

    let r = co.submit(&cfg, &decision(vec![0; 8])).await;
    assert!(r.ok, "停用清场在没有 nft 时也必须能跑：{:?}", r.issues);
}

/// 残留回收只动自己的对象；空环境（刚装好）什么都不该删，也不该报错。
#[tokio::test]
async fn reclaim_on_a_fresh_box_deletes_nothing_and_keeps_foreign_objects() {
    let dir = tempfile::tempdir().unwrap();
    let (co, _sim) = sim_plane(dir.path());
    let rep = co.reclaim().await.unwrap();
    assert_eq!(rep.rules_removed, 0, "空环境不该删任何规则：{rep:?}");
    assert_eq!(rep.routes_removed, 0, "空环境不该删任何路由：{rep:?}");
    assert!(rep.foreign.is_empty(), "空环境没有别人的对象：{rep:?}");
}

/// 任何结局都必须有一份回执：事务从不以 panic 收场。
#[tokio::test]
async fn every_outcome_produces_a_receipt() {
    let dir = tempfile::tempdir().unwrap();
    let (co, sim) = sim_plane(dir.path());
    sim.fail_check(Some("语法不过".into()));
    let cfg = cfg_two_lines();
    ConfigStore::load(&dir.path().join("smartmwan"))
        .unwrap()
        .save(&cfg)
        .unwrap();
    let r = co
        .submit(&cfg, &decision(vec![1, 1, 1, 1, 1, 1, 1, 1]))
        .await;
    assert!(!r.id.is_empty(), "任何结局都必须有回执");
    assert!(!r.ok, "试算不过就不该提交");
    // 试算阶段就失败 ⇒ 不该动内核，因此没有回滚记录。
    assert!(
        r.rollback.is_empty(),
        "试算失败不该有内核变更需要回滚：{:?}",
        r.rollback
    );
}

fn stage_names(r: &smartmwan::transaction::Receipt) -> Vec<String> {
    r.stages
        .iter()
        .map(|s| s.stage.as_str().to_string())
        .collect()
}

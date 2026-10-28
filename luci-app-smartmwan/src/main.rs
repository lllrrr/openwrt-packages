//! 守护进程入口（M7）：装配全部层，跑监督循环，对外提供 RPC。
//!
//! # 命令行
//!
//! ```text
//! smartmwand                          # 守护进程（默认）
//! smartmwand --config PATH            # 指定 UCI 配置文件（默认 /etc/config/smartmwan）
//! smartmwand --check                  # 只读体检：校验 + 观察，不写任何东西
//! smartmwand --once                   # 跑一轮「探测 + 决策 + 提交」后退出
//! smartmwand --dump-nft               # 打印将为当前配置生成的 nft 程序（只读）
//! smartmwand --dump-defaults          # 打印默认配置的 UCI 文本
//! smartmwand --capabilities           # 打印设备 nft 能力探测结果
//! smartmwand --print-config           # 打印规范化后的 UCI 文本
//! smartmwand --restore-last-good      # 把 last-good 快照写回配置文件（不下发）
//! ```
//!
//! # 监督循环
//!
//! 单个主循环任务按 200ms tick：探测到期就跑探测轮（含内核观测与流量/连接采样），
//! 然后做决策；**只有桶图真的变了、或配置指纹相对上次应用变了**，才写数据面
//! （桶图单独变化走 `replace rule` 热替换，其余走完整事务）。命令通道
//! （`smartmwan.apply` 等 RPC 写方法）也由这个循环串行执行 ——
//! `Scheduler` 与事务因此都只有一个所有者。
//!
//! 关停（SIGTERM/SIGINT）：停环 → 回收本插件全部内核对象 → 退出。
//! 撤销自己的对象是硬要求：标记规则留在内核里而守护进程不在，
//! 意味着「包被打上 table 105 标记但没人维护 table 105」。

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use smartmwan::config::schema::{Config, GameSelection};
use smartmwan::config::{self, Store as ConfigStore};
use smartmwan::health;
use smartmwan::health::probe::SystemProber;
use smartmwan::logging::{self, Level};
use smartmwan::rpc::{Acl, AppState, Command, ConnView, Paths, ReloadReport, Server, TrafficView};
use smartmwan::rules::{self, dns_sets, matchers};
use smartmwan::scheduler::{self, Scheduler};
use smartmwan::system::conntrack;
use smartmwan::system::firewall::{self, Capabilities, Nft};
use smartmwan::system::netlink::{HandleOps, NetlinkHandle};
use smartmwan::system::{self, Env};
use smartmwan::transaction::{
    Coordinator, Decision, FirewallExec, Plane, Receipt, Stage, StageRecord,
};
use smartmwan::{Error, Result};
use tokio::sync::{mpsc, watch};

/// 主循环 tick。探测有自己的周期（`health.interval_ms`），决策是纯计算，
/// 因此 tick 取一个远小于探测周期的小值，保证故障切换及时。
const TICK: Duration = Duration::from_millis(200);

/// 域名集合刷新周期。与 `dns_ttl_floor_s` 解耦：刷新是「尽量保持账本新鲜」，
/// 元素寿命由内核集合的 timeout 负责。
const DNS_REFRESH: Duration = Duration::from_secs(30);

/// 单个域名解析超时。
const DNS_RESOLVE_TIMEOUT: Duration = Duration::from_secs(5);

/// 关停时等各环自行收尾的上限。超时就不再等 —— 回收动作不依赖它们。
const DRAIN_TIMEOUT: Duration = Duration::from_secs(5);

/// 关停看门狗：SIGTERM 之后主循环仍未停止这么久，就强制走关停序列并退出。
/// procd 的默认超时比这更短，等它 SIGKILL 不如自己有序地退。
const SHUTDOWN_WATCHDOG: Duration = Duration::from_secs(30);

/// 关停时回收操作的硬上限（见 `ShutdownCtl::run_sequence` 的说明）。
const RECLAIM_LIMIT: Duration = Duration::from_secs(20);

/// 提交失败后的重试退避。没有它，一次失败会让主循环每个 tick（200ms）
/// 都重放一遍完整事务（含若干次 nft 进程），把失败放大成事务风暴。
const SUBMIT_RETRY_BACKOFF_MS: u64 = 5000;

/// 游戏规则命中数的采样间隔。`nft -a list chain` 会把整条链拉回来，
/// 比探测贵得多；而命中数只是给用户看趋势的，不需要探测那种秒级精度。
const HITS_SAMPLE_INTERVAL_MS: u64 = 30_000;

/// conntrack 与 sysctl 的生产路径（设备上固定，不可配置）。
const CONNTRACK_PROC: &str = "/proc/net/nf_conntrack";
const NETFILTER_SYSCTL: &str = "/proc/sys/net/netfilter";

// ==================== 命令行 ====================

#[derive(Debug, Default)]
struct Cli {
    config: Option<PathBuf>,
    socket: Option<PathBuf>,
    check: bool,
    once: bool,
    dump_nft: bool,
    dump_defaults: bool,
    dump_include: bool,
    capabilities: bool,
    print_config: bool,
    restore_last_good: bool,
    reclaim: bool,
    log_level: Option<String>,
    log_file: Option<String>,
}

fn parse_args() -> Result<Cli> {
    let mut cli = Cli::default();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--config" => {
                cli.config = Some(path_arg(&mut args, "--config")?);
            }
            "--socket" => {
                cli.socket = Some(path_arg(&mut args, "--socket")?);
            }
            "--check" => cli.check = true,
            "--once" => cli.once = true,
            "--dump-nft" => cli.dump_nft = true,
            "--dump-defaults" => cli.dump_defaults = true,
            "--dump-include" => cli.dump_include = true,
            "--capabilities" => cli.capabilities = true,
            "--print-config" => cli.print_config = true,
            "--restore-last-good" => cli.restore_last_good = true,
            "--reclaim" => cli.reclaim = true,
            "--log-level" => cli.log_level = Some(value_arg(&mut args, "--log-level")?),
            "--log-file" => cli.log_file = Some(value_arg(&mut args, "--log-file")?),
            "-h" | "--help" => {
                print!("{HELP}");
                std::process::exit(0);
            }
            other => {
                return Err(Error::Validate(format!(
                    "未知参数 {other}（--help 看用法）"
                )));
            }
        }
    }
    Ok(cli)
}

fn path_arg(args: &mut std::iter::Skip<std::env::Args>, flag: &str) -> Result<PathBuf> {
    Ok(PathBuf::from(value_arg(args, flag)?))
}

/// 取一个选项值。缺值（或下一个参数本身就是另一个选项）必须报错，
/// 不能静默当成 `None` —— 那会让 `--log-level --once` 这类笔误悄悄失效。
fn value_arg(args: &mut std::iter::Skip<std::env::Args>, flag: &str) -> Result<String> {
    match args.next() {
        Some(v) if !v.starts_with("--") => Ok(v),
        _ => Err(Error::Validate(format!("{flag} 需要一个参数值"))),
    }
}

const HELP: &str = "\
smartmwand — 多 WAN 智能选路守护进程

用法：
  smartmwand [选项]

选项：
  --config PATH          指定 UCI 配置文件（默认 /etc/config/smartmwan）
  --socket PATH          指定 RPC socket 路径（默认取 global.rpc_socket）
  --check                只读体检：校验配置 + 观察内核，不写任何东西
  --once                 跑一轮「探测 + 决策 + 提交」后退出
  --dump-nft             打印将为当前配置生成的 nft 程序（只读，桶图为空）
  --dump-defaults        打印默认配置的 UCI 文本
  --dump-include         打印 fw4 自动片段占位（ruleset-post/smartmwan.nft，与代码同源，打包用）
  --capabilities         打印设备 nft 能力探测结果
  --print-config         打印规范化后的 UCI 文本
  --restore-last-good    把 last-good 快照写回配置文件（只写盘，不下发）
  --reclaim              一次性回收本插件自己的全部内核对象（卸载/排障用）
  --log-level LEVEL      trace/debug/info/warn/error（覆盖配置）
  --log-file PATH        日志文件（覆盖配置）
  -h, --help             本帮助
";

fn main() {
    let cli = match parse_args() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("smartmwand: {e}");
            std::process::exit(2);
        }
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("smartmwand: 无法创建 tokio 运行时: {e}");
            std::process::exit(1);
        }
    };
    let code = match runtime.block_on(async_main(cli)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("smartmwand: {e}");
            1
        }
    };
    std::process::exit(code);
}

fn default_config_path() -> PathBuf {
    PathBuf::from("/etc/config/smartmwan")
}

async fn async_main(cli: Cli) -> Result<i32> {
    if cli.dump_defaults {
        print!("{}", ConfigStore::defaults_uci_text());
        return Ok(0);
    }
    // fw4 自动片段（ruleset-post）安装期占位必须与代码同源：打包时由本入口生成，
    // 不允许仓库里出现手写的第二份（docs/HANDOVER.md §3）。
    if cli.dump_include {
        print!("{}", firewall::include_file_text());
        return Ok(0);
    }
    let cfg_path = cli.config.clone().unwrap_or_else(default_config_path);
    // `--reclaim` 必须排在配置加载之前：它是卸载/排障的兜底清场命令，
    // 而「配置坏掉」恰恰是最需要清场的场景之一。配置文件读不到时按默认参数回收
    // —— 所有权判定只用常量（优先级带 1000-1023、表号 101-124、OUR_RTPROT、
    // `inet smw` 表名），与用户配置无关，配置仅用于定位 nft 临时目录。
    if cli.reclaim {
        let cfg = load_config_or_default(&cfg_path);
        // 只删本插件自己的对象，幂等；守护进程不在时也能跑
        // （不 bind socket、不进主循环）。
        return Ok(cmd_reclaim(&cfg_path, &cfg).await);
    }
    let store = ConfigStore::load(&cfg_path)?;
    let cfg = store.config.clone();
    init_logging(&cli, &cfg);

    if cli.print_config {
        print!("{}", store.render(&cfg));
        return Ok(0);
    }
    if cli.check {
        return Ok(cmd_check(&cfg).await);
    }
    if cli.capabilities {
        return Ok(cmd_capabilities().await);
    }
    if cli.dump_nft {
        return Ok(cmd_dump_nft(&cfg_path, &cfg).await);
    }
    if cli.restore_last_good {
        return Ok(cmd_restore_last_good(&cfg_path, &cfg));
    }
    let once = cli.once;
    let daemon = Daemon::assemble(cli, cfg_path, cfg).await?;
    if once {
        return daemon.run_once().await;
    }
    daemon.run().await
}

/// 回收命令专用的容错加载：配置读不到就按默认参数继续。
///
/// 兜底清场不能被坏配置挡住 —— 卸载时配置恰好损坏/被删，正是最需要
/// 清场的场景。所有权判定只用常量（优先级带 1000-1023、表号 101-124、
/// `OUR_RTPROT`、`inet smw` 表名），与用户配置无关；配置仅用来定位
/// nft 临时目录，取默认值不影响回收的正确性。
fn load_config_or_default(path: &Path) -> Config {
    match ConfigStore::load(path) {
        Ok(s) => s.config,
        Err(e) => {
            println!("[告警] 配置不可用（{e}），按默认参数回收");
            Config::default()
        }
    }
}

/// 日志初始化：CLI 覆盖优先，其次配置里的 `log_level` / `log_file`。
fn init_logging(cli: &Cli, cfg: &Config) {
    config::apply_logging(cfg);
    if let Some(l) = cli.log_level.as_deref().and_then(Level::parse) {
        logging::set_level(l);
    }
    if let Some(f) = &cli.log_file {
        logging::init(
            logging::level(),
            Some(Path::new(f)),
            cfg.global.log_max_bytes,
            cfg.global.log_keep_backups,
        );
    }
}

// ==================== 只读 CLI 子命令 ====================

/// `--check`：校验 + 观察，全程只读。
async fn cmd_check(cfg: &Config) -> i32 {
    println!(
        "== 配置校验（schema v{}） ==",
        smartmwan::CONFIG_SCHEMA_VERSION
    );
    let report = config::validate::validate(cfg);
    for i in &report.issues {
        println!("[{}] {}：{}", severity_tag(i.severity), i.path, i.message);
        if let Some(h) = &i.hint {
            println!("       建议：{h}");
        }
    }
    println!(
        "校验结论：{}",
        if report.is_valid() {
            "通过"
        } else {
            "未通过"
        }
    );

    println!("\n== 内核观察（只读） ==");
    match system::open_netlink() {
        Ok(handle) => {
            let cfg2 = cfg.clone();
            let ob = tokio::task::spawn_blocking(move || {
                system::observe(&cfg2, &Env::default(), &HandleOps(handle))
            })
            .await;
            match ob {
                Ok(Ok(ob)) => {
                    for w in &ob.warnings {
                        println!("[告警] {w}");
                    }
                    for i in &ob.issues {
                        println!("[{}] {}：{}", severity_tag(i.severity), i.path, i.message);
                    }
                    println!(
                        "观察结论：解析线路 {} 条，期望规则 增{} 删{}，路由 增{} 删{}",
                        ob.resolved.len(),
                        ob.diff.add_rules.len(),
                        ob.diff.del_rules.len(),
                        ob.diff.add_routes.len(),
                        ob.diff.del_routes.len()
                    );
                }
                Ok(Err(e)) => println!("[失败] 观察内核出错：{e}"),
                Err(e) => println!("[失败] 观察任务被丢弃：{e}"),
            }
        }
        Err(e) => println!("[失败] 打不开 netlink：{e}（需要 root？）"),
    }
    i32::from(!report.is_valid())
}

fn severity_tag(s: config::validate::Severity) -> &'static str {
    match s {
        config::validate::Severity::Error => "致命",
        config::validate::Severity::Warning => "告警",
        config::validate::Severity::Info => "提示",
    }
}

/// `--capabilities`：在设备上实测 nft 语法支持。
async fn cmd_capabilities() -> i32 {
    let tmp = std::env::temp_dir().join("smartmwan-caps");
    let _ = std::fs::create_dir_all(&tmp);
    match Nft::new(&tmp) {
        Ok(nft) => {
            let caps = firewall::probe_caps(&nft).await;
            print_caps(&caps);
            0
        }
        Err(e) => {
            println!("[失败] {e}");
            println!("结论：设备上没有可用的 nft，本插件无法工作（不会假装能用）");
            1
        }
    }
}

fn print_caps(c: &Capabilities) {
    let rows: [(&str, bool); 9] = [
        ("jhash ... map 桶映射", c.jhash_map),
        ("ct mark 区间匹配", c.ct_mark_range),
        ("th sport/dport 传输头", c.th_payload),
        ("dynamic,timeout 集合", c.dyn_timeout_sets),
        ("type route hook output", c.route_hook_output),
        ("ether_addr 集合", c.ether_sets),
        ("规则 comment", c.comments),
        ("jhash 额外种子参数", c.jhash_seed),
        ("nft 可执行文件存在", c.nft_exists),
    ];
    for (name, ok) in rows {
        println!("{} {name}", if ok { "[可用]" } else { "[不可用]" });
    }
    if !c.version.is_empty() {
        println!("nft 版本：{}", c.version);
    }
    let degraded: Vec<&str> = rows.iter().filter(|(_, ok)| !ok).map(|(n, _)| *n).collect();
    if degraded.is_empty() {
        println!("结论：全部语法可用");
    } else {
        println!(
            "结论：以下语法不可用，相关功能会降级为告警而不是硬编码：{}",
            degraded.join("、")
        );
    }
}

/// `--dump-nft`：只读地生成程序文本。
///
/// 诚实性说明：没有探测数据时可用的决策只有「所有桶未分配」，因此打印的是
/// **首轮探测完成前**的程序（游戏择优规则会进入 pending）。真实程序以守护进程
/// 运行期的决策为准。
async fn cmd_dump_nft(cfg_path: &Path, cfg: &Config) -> i32 {
    let state_dir = PathBuf::from(&cfg.global.state_dir);
    let handle = match system::open_netlink() {
        Ok(h) => h,
        Err(e) => {
            println!("[失败] 打不开 netlink：{e}");
            return 1;
        }
    };
    let (plane, _nft) = build_plane(cfg_path, &state_dir, handle).await;
    let coord = Coordinator::new(plane);
    let d = Decision {
        bucket_map: vec![0u8; usize::from(cfg.global.buckets.max(1))],
        now_ms: logging::now_ms(),
        ..Default::default()
    };
    match coord.plan(cfg, &d, None, "dump-nft".into()).await {
        Ok(plan) => {
            println!("{}", plan.text());
            eprintln!("（以上为只读生成：桶图未分配、决策代际 0；设备上的真实程序由守护进程生成）");
            0
        }
        Err(e) => {
            println!("[失败] {e}");
            1
        }
    }
}

/// `--restore-last-good`：只写盘，不下发。
fn cmd_restore_last_good(cfg_path: &Path, cfg: &Config) -> i32 {
    let state_dir = PathBuf::from(&cfg.global.state_dir);
    match config::Store::restore_last_good(&state_dir) {
        Ok(Some(good)) => {
            let report = config::validate::validate(&good);
            if !report.is_valid() {
                println!(
                    "[失败] last-good 快照本身校验不过（{} 个致命问题），拒绝写回",
                    report.errors().len()
                );
                return 1;
            }
            let mut store = match ConfigStore::load(cfg_path) {
                Ok(s) => s,
                Err(e) => {
                    println!("[失败] 读取 {cfg_path:?} 失败：{e}");
                    return 1;
                }
            };
            let changes = config::diff(cfg, &good);
            match store.save(&good) {
                Ok(_) => {
                    println!(
                        "已写回 last-good 快照（{} 项变更）。未下发 —— 重启守护进程或调用 apply 后生效。",
                        changes.len()
                    );
                    0
                }
                Err(e) => {
                    println!("[失败] 写回失败：{e}");
                    1
                }
            }
        }
        Ok(None) => {
            println!("没有 last-good 快照（从未成功应用过）。");
            1
        }
        Err(e) => {
            println!("[失败] {e}");
            1
        }
    }
}

/// `--reclaim`：一次性回收本插件自己的全部内核对象（卸载/排障用）。
///
/// 与守护进程的关停回收同一实现（`Coordinator::reclaim()`）：按优先级带、
/// 表号区间、`OUR_RTPROT`、`NS` 表名判定所有权，**只删自己的**，别人的对象
/// 保留并逐条报告。幂等 —— 没有残留时也返回成功。
async fn cmd_reclaim(cfg_path: &Path, cfg: &Config) -> i32 {
    let state_dir = PathBuf::from(&cfg.global.state_dir);
    let handle = match system::open_netlink() {
        Ok(h) => h,
        Err(e) => {
            println!("[失败] 打不开 netlink（需要 root）：{e}");
            return 1;
        }
    };
    let (plane, _nft) = build_plane(cfg_path, &state_dir, handle).await;
    let coord = Coordinator::new(plane);
    match coord.reclaim().await {
        Ok(rep) => {
            println!(
                "回收完成：ip rule {} 条、路由 {} 条、nft 表 {}",
                rep.rules_removed,
                rep.routes_removed,
                if rep.nft_dropped {
                    "已删"
                } else {
                    "未处理"
                }
            );
            for f in &rep.foreign {
                println!("保留非本插件对象：{f}");
            }
            for n in &rep.notes {
                println!("说明：{n}");
            }
            0
        }
        Err(e) => {
            println!("[失败] {e}");
            1
        }
    }
}

// ==================== 装配 ====================

/// 组装事务执行面：netlink + nft 通道 + 能力探测。
///
/// nft 找不到不是致命错误：通道退化为 `FirewallExec::Absent`，事务层会拒绝
/// enabled 提交、允许停用提交（清场不需要 nft）。但探测失败必须留下告警。
/// `handle` 由调用方打开（netlink 打不开对调用方都是致命的，各命令自己报）。
async fn build_plane(
    cfg_path: &Path,
    state_dir: &Path,
    handle: NetlinkHandle,
) -> (Plane, Option<Arc<Nft>>) {
    let ops: Arc<dyn smartmwan::system::netlink::RouteOps> = Arc::new(HandleOps(handle));

    let nft_tmp = state_dir.join("nft-tmp");
    let _ = std::fs::create_dir_all(&nft_tmp);
    let nft = match Nft::new(&nft_tmp) {
        Ok(n) => Some(Arc::new(n)),
        Err(e) => {
            logging::error_ctx(
                "main",
                "nft",
                e,
                &[(
                    "impact",
                    "防火墙阶段不可用：启用状态会被拒绝，停用/清场仍可执行".into(),
                )],
            );
            None
        }
    };
    let caps = match &nft {
        Some(n) => firewall::probe_caps(n).await,
        None => Capabilities::default(),
    };
    let fw = match &nft {
        Some(n) => FirewallExec::Real(n.clone()),
        None => FirewallExec::Absent,
    };
    (
        Plane {
            ops,
            fw,
            env: Env::default(),
            caps: caps.clone(),
            config_path: cfg_path.to_path_buf(),
            state_dir: state_dir.to_path_buf(),
            presets_dir: PathBuf::from(rules::presets::PRESET_DIR),
        },
        nft,
    )
}

// ==================== 守护进程 ====================

/// 主循环向自己派发的内部消息（避免在 `select!` 里借 `self`）。
enum LoopMsg {
    Tick,
    Cmd(Command),
    Quit,
}

/// 关停序列的持有者。放在信号任务里而不是主循环之后，是因为**主循环可能卡死**：
/// 关停代码跟在主循环后面，就等于「循环不返回就没法退出」。
/// 正常路径与看门狗路径都走这里，靠 `done` 保证只做一次。
struct ShutdownCtl {
    done: std::sync::atomic::AtomicBool,
    tx: watch::Sender<bool>,
    cancel: watch::Sender<bool>,
    coordinator: Arc<Coordinator>,
    socket: PathBuf,
}

impl ShutdownCtl {
    /// 执行关停序列（幂等）。`forced` = 看门狗路径（主循环已无响应）。
    async fn run_sequence(&self, forced: bool) {
        if self.done.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return; // 另一条路径已经做过了
        }
        if forced {
            // 主循环大概已经不听指令了，flags 仍要发（RPC/DNS 环可能还活着）。
            let _ = self.tx.send(true);
            let _ = self.cancel.send(true);
        }
        logging::info_ctx(
            "main",
            "stop",
            if forced {
                "看门狗强制关停：主循环未在限定时间内停止"
            } else {
                "优雅关停：撤销自有内核对象"
            },
            &[],
        );
        // 撤销自己的全部内核对象：标记规则不该在守护进程不在时继续生效。
        // 再包一层超时：netlink 自身有 2s 超时，但 reclaim 有几十次操作，
        // 且它要抢事务锁 —— 楔死的事务持着锁时不能把退出也搭进去。
        match tokio::time::timeout(RECLAIM_LIMIT, self.coordinator.reclaim()).await {
            Ok(Ok(rep)) => logging::info_ctx(
                "main",
                "reclaim",
                &format!(
                    "关停回收：规则 {} 条、路由 {} 条、nft 表 {}",
                    rep.rules_removed,
                    rep.routes_removed,
                    if rep.nft_dropped {
                        "已删"
                    } else {
                        "未处理"
                    }
                ),
                &[],
            ),
            Ok(Err(e)) => {
                logging::error_ctx("main", "reclaim", e, &[]);
            }
            Err(_) => {
                logging::error_ctx(
                    "main",
                    "reclaim",
                    Error::Timeout {
                        operation: "关停回收".into(),
                        elapsed_ms: RECLAIM_LIMIT.as_millis() as u64,
                    },
                    &[("note", "对象可能残留，下次启动时的残留回收会清理".into())],
                );
            }
        }
        let _ = std::fs::remove_file(&self.socket);
        logging::info_ctx("main", "stop", "smartmwand 关停序列完成", &[]);
    }
}

/// 装配好的守护进程。持有全部共享件；`run()` 是主循环。
struct Daemon {
    st: Arc<AppState>,
    cfg_path: PathBuf,
    env: Env,
    handle: Arc<NetlinkHandle>,
    prober: Arc<SystemProber>,
    nft: Option<Arc<Nft>>,
    ctl_rx: mpsc::UnboundedReceiver<Command>,
    shutdown_tx: watch::Sender<bool>,
    cancel_tx: watch::Sender<bool>,
    shutdown_ctl: Arc<ShutdownCtl>,
    /// 上次成功应用时的配置指纹（`None` = 从未应用）。
    last_applied_fp: Option<String>,
    /// 上次成功应用时的游戏择优结果。择优变化改的是游戏规则的标记（槽位位），
    /// 只替换桶规则会把游戏流量留在旧出口，因此它必须参与「要不要提交 / 能否热替换」的判断。
    last_picks: BTreeMap<String, u8>,
    /// 上次提交是否成功收敛（热替换的前置条件，也是失败重试的依据）。
    last_ok: bool,
    /// 决策代际（4bit）。只在**完整事务**提交时递增：热替换要求程序文本除桶图外
    /// 逐字节不变，而 gen 会写进每条游戏规则的标记里。桶图变化时递增 gen 会让
    /// 游戏规则也跟着变，可热替换只动桶规则 —— 内核与快照就此分叉。
    gen: u8,
    last_probe_ms: u64,
    /// 上次采样游戏规则命中数的时刻（unix 毫秒）；0 = 还没采样过。
    last_hits_ms: u64,
    /// 退避截止时刻（unix 毫秒）：0 = 不在退避期。只影响周期路径，
    /// RPC 显式触发的 apply 随时允许重试（那是用户的选择）。
    next_retry_ms: u64,
    known_rules: BTreeSet<String>,
}

impl Daemon {
    async fn assemble(cli: Cli, cfg_path: PathBuf, cfg: Config) -> Result<Daemon> {
        let state_dir = PathBuf::from(&cfg.global.state_dir);
        let socket = cli
            .socket
            .clone()
            .unwrap_or_else(|| PathBuf::from(&cfg.global.rpc_socket));
        std::fs::create_dir_all(&state_dir).map_err(|e| {
            Error::Config(format!("创建状态目录 {} 失败: {e}", state_dir.display()))
        })?;

        let handle = Arc::new(
            system::open_netlink()
                .map_err(|e| Error::Netlink(format!("打不开 netlink（需要 root）：{e}")))?,
        );
        let (plane, nft) = build_plane(&cfg_path, &state_dir, (*handle).clone()).await;
        let caps = plane.caps.clone();
        let coordinator = Arc::new(Coordinator::new(plane));
        let registry = Arc::new(smartmwan::health::Registry::new());
        let (ctl_tx, ctl_rx) = mpsc::unbounded_channel();
        let (shutdown_tx, _shutdown_rx) = watch::channel(false);
        let (cancel_tx, _cancel_rx) = watch::channel(false);
        let shutdown_ctl = Arc::new(ShutdownCtl {
            done: std::sync::atomic::AtomicBool::new(false),
            tx: shutdown_tx.clone(),
            cancel: cancel_tx.clone(),
            coordinator: coordinator.clone(),
            socket: socket.clone(),
        });

        let st = Arc::new(AppState {
            coordinator,
            registry,
            scheduler: Arc::new(std::sync::Mutex::new(Scheduler::new())),
            cfg: Arc::new(std::sync::RwLock::new(Arc::new(cfg.clone()))),
            snap: Arc::new(std::sync::RwLock::new(
                smartmwan::health::Snapshot::default(),
            )),
            ob: Arc::new(std::sync::RwLock::new(None)),
            loads: Arc::new(std::sync::RwLock::new(BTreeMap::new())),
            traffic: Arc::new(std::sync::RwLock::new(TrafficView {
                cur: smartmwan::system::interface::TrafficSample::default(),
                prev: None,
            })),
            conns: Arc::new(std::sync::RwLock::new(ConnView {
                cur: conntrack::Counts::default(),
                prev: None,
                limits: None,
            })),
            receipt: Arc::new(std::sync::RwLock::new(None)),
            outcome: Arc::new(std::sync::RwLock::new(None)),
            decision: Arc::new(std::sync::RwLock::new(Decision::default())),
            last_round: Arc::new(std::sync::Mutex::new(None)),
            caps: Arc::new(std::sync::RwLock::new(caps)),
            dns: Arc::new(std::sync::Mutex::new(dns_sets::Registry::new(
                Duration::from_secs(cfg.global.dns_ttl_floor_s.max(30)),
                1024,
            ))),
            hits: Arc::new(std::sync::RwLock::new(rules::GameHits::default())),
            ctl: ctl_tx,
            paths: Paths {
                config: cfg_path.clone(),
                state_dir: state_dir.clone(),
                socket: socket.clone(),
            },
            started: std::time::Instant::now(),
            acl: Acl::system_default(Path::new("/etc/passwd")),
            nft: nft.clone(),
        });

        let prober = Arc::new(SystemProber::new(cfg.global.health.max_concurrent_probes));
        let known_rules = cfg.games.iter().map(|g| g.name.clone()).collect();

        logging::info_ctx(
            "main",
            "start",
            &format!(
                "smartmwand 启动（配置 {}，socket {}，nft {}）",
                cfg_path.display(),
                socket.display(),
                if nft.is_some() { "可用" } else { "不可用" }
            ),
            &[
                ("enabled", cfg.global.enabled.to_string()),
                ("mode", cfg.global.mode.as_str().to_string()),
                ("acl", format!("{:?}", st.acl.allowed_uids())),
            ],
        );

        Ok(Daemon {
            st,
            cfg_path,
            env: Env::default(),
            handle,
            prober,
            nft,
            ctl_rx,
            shutdown_tx,
            cancel_tx,
            shutdown_ctl,
            last_applied_fp: None,
            last_picks: BTreeMap::new(),
            last_ok: false,
            gen: 0,
            last_probe_ms: 0,
            last_hits_ms: 0,
            next_retry_ms: 0,
            known_rules,
        })
    }

    /// 完整守护进程：起环 → 等信号 → 优雅关停。
    async fn run(mut self) -> Result<i32> {
        // 单实例：bind 失败（已有活实例）直接退出，绝不两个实例同时写内核。
        let server = Server::bind(&self.st.paths.socket, self.st.clone(), self.shutdown_rx())?;

        // 启动时回收上次异常退出留下的自有对象（别人的一律保留并报告）。
        match self.st.coordinator.reclaim().await {
            Ok(rep) => {
                for f in &rep.foreign {
                    logging::info_ctx("main", "reclaim", &format!("保留非本插件对象：{f}"), &[]);
                }
                for n in &rep.notes {
                    logging::info_ctx("main", "reclaim", n, &[]);
                }
            }
            Err(e) => {
                logging::error_ctx("main", "reclaim", e, &[]);
            }
        }

        let rpc_handle = tokio::spawn(async move { server.run().await });
        let dns_handle = {
            let st = self.st.clone();
            let nft = self.nft.clone();
            let shutdown = self.shutdown_rx();
            tokio::spawn(async move { dns_loop(st, nft, shutdown).await })
        };
        let ctl = self.shutdown_ctl.clone();
        let signal_handle = {
            let ctl_tx = self.st.ctl.clone();
            let ctl = ctl.clone();
            tokio::spawn(async move { signal_loop(ctl_tx, ctl).await })
        };

        // ---- 主循环 ----
        // select! 的各分支只借用自己那部分字段；handler 里再调 &mut self 的方法，
        // 因此先用一个局部 shutdown 订阅，避免整个 self 被借走。
        let mut shutdown = self.shutdown_rx();
        let mut ticker = tokio::time::interval(TICK);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            let msg = tokio::select! {
                _ = ticker.tick() => LoopMsg::Tick,
                cmd = self.ctl_rx.recv() => match cmd {
                    Some(c) => LoopMsg::Cmd(c),
                    None => LoopMsg::Quit,   // 所有 RPC 发送端都没了
                },
                changed = shutdown.changed() => {
                    if changed.is_ok() && *shutdown.borrow() {
                        LoopMsg::Quit
                    } else {
                        LoopMsg::Tick
                    }
                }
            };
            match msg {
                LoopMsg::Tick => self.tick().await,
                LoopMsg::Cmd(c) => self.handle_command(c).await,
                LoopMsg::Quit => break,
            }
        }

        // ---- 优雅关停（正常路径）----
        // 注意：关停序列本身在 ShutdownCtl 里，由信号任务看护。主循环若因故卡死
        // （例如某个 await 永不返回），看门狗会在 SHUTDOWN_WATCHDOG 后强制走同一序列
        // 并退出 —— SIGTERM 必须永远能终结进程，procd 可等不起。
        logging::info_ctx("main", "stop", "主循环已停止，开始收尾", &[]);
        let _ = tokio::time::timeout(DRAIN_TIMEOUT, async {
            let _ = rpc_handle.await;
            let _ = dns_handle.await;
        })
        .await;
        signal_handle.abort();
        ctl.run_sequence(false).await;
        Ok(0)
    }

    /// `--once`：一轮「探测 + 决策 + 提交」，打印回执后退出。不绑定 socket。
    async fn run_once(mut self) -> Result<i32> {
        let cfg = self.st.cfg_snapshot();
        let now = logging::now_ms();
        self.probe_round(&cfg, now).await;
        match self.cycle(&cfg, now, true).await {
            Some(r) => {
                println!("{}", r.describe());
                Ok(i32::from(!r.ok))
            }
            None => {
                println!("本轮没有产生任何提交（决策未变化且配置未变化）");
                Ok(0)
            }
        }
    }

    fn shutdown_rx(&self) -> watch::Receiver<bool> {
        self.shutdown_tx.subscribe()
    }

    // ---------- 主循环 ----------

    async fn tick(&mut self) {
        let now = logging::now_ms();
        let cfg = self.st.cfg_snapshot();
        let interval = u64::from(cfg.global.health.interval_ms.max(100));
        if self.last_probe_ms == 0 || now.saturating_sub(self.last_probe_ms) >= interval {
            self.probe_round(&cfg, now).await;
            self.last_probe_ms = now;
        }
        self.cycle(&cfg, now, false).await;
        if now.saturating_sub(self.last_hits_ms) >= HITS_SAMPLE_INTERVAL_MS {
            self.sample_game_hits(now).await;
            self.last_hits_ms = now;
        }
    }

    /// 采样一次游戏规则命中数。
    ///
    /// 频率刻意低于探测：`nft -a list chain` 要把整条链拉回来，高频跑是白花钱，
    /// 而命中数是给用户看趋势的，不需要秒级精度。通道不是真 nft 时**什么都不写** ——
    /// 让 AppState 停在「从未采样」的默认值，比写一个编造的 0 诚实。
    async fn sample_game_hits(&self, now_ms: u64) {
        let rules = self
            .st
            .coordinator
            .plane()
            .fw
            .rule_counters(firewall::CHAIN_PREROUTING)
            .await;
        let Some(rules) = rules else { return };
        *self.st.hits.write().unwrap_or_else(|p| p.into_inner()) =
            rules::GameHits::from_listing(&rules, now_ms);
    }

    /// 处理 RPC 发来的命令。全部串行在本循环里执行。
    async fn handle_command(&mut self, cmd: Command) {
        match cmd {
            Command::ProbeNow(tx) => {
                let cfg = self.st.cfg_snapshot();
                let now = logging::now_ms();
                self.probe_round(&cfg, now).await;
                self.last_probe_ms = now;
                let info = self
                    .st
                    .last_round
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .clone()
                    .unwrap_or_default();
                let _ = tx.send(info);
            }
            Command::Cycle(tx) => {
                let cfg = self.st.cfg_snapshot();
                let now = logging::now_ms();
                // RPC 触发：探测到期就先补一轮（用户可能刚改了配置），再强制提交一次，
                // 让回执如实反映「我检查过了，有没有变更」。
                let interval = u64::from(cfg.global.health.interval_ms.max(100));
                if self.last_probe_ms == 0 || now.saturating_sub(self.last_probe_ms) >= interval {
                    self.probe_round(&cfg, now).await;
                    self.last_probe_ms = now;
                }
                let receipt = self.cycle(&cfg, now, true).await;
                let _ = tx.send(receipt.unwrap_or_else(|| self.idle_receipt()));
            }
            Command::Reload(tx) => {
                let rep = self.reload().await;
                let _ = tx.send(rep);
            }
        }
    }

    /// 重新读盘。失败时保留内存配置并如实报告（守护进程不能因为一次手滑退出）。
    async fn reload(&mut self) -> ReloadReport {
        let mut rep = ReloadReport::default();
        match ConfigStore::load(&self.cfg_path) {
            Ok(store) => {
                let new = store.config;
                let new_rules: BTreeSet<String> =
                    new.games.iter().map(|g| g.name.clone()).collect();
                {
                    let mut g = self.st.scheduler.lock().unwrap_or_else(|p| p.into_inner());
                    for gone in self.known_rules.difference(&new_rules) {
                        g.forget_rule(gone);
                    }
                    g.on_config_change();
                }
                self.known_rules = new_rules;
                rep.parse_warnings = store.parse_warnings;
                self.st.registry.sync_config(&new);
                *self.st.cfg.write().unwrap_or_else(|p| p.into_inner()) = Arc::new(new);
                rep.reloaded = true;
                rep.note = "已重新读取 UCI，去抖与重排计时已复位".into();
                logging::info_ctx("main", "reload", &rep.note, &[]);
            }
            Err(e) => {
                rep.note = format!("重载失败，继续使用内存中的配置：{e}");
                logging::error_ctx("main", "reload", e, &[]);
            }
        }
        rep
    }

    // ---------- 探测轮 ----------

    /// 一轮探测：观察内核 → 探测 → 采样流量/连接 → 更新全部只读缓存。
    async fn probe_round(&mut self, cfg: &Config, now: u64) {
        let env = self.env.clone();
        let handle = self.handle.clone();
        let cfg2 = cfg.clone();
        let ob = match tokio::task::spawn_blocking(move || {
            system::observe(&cfg2, &env, &HandleOps((*handle).clone()))
        })
        .await
        {
            Ok(Ok(ob)) => ob,
            Ok(Err(e)) => {
                logging::warn_ctx("system", "observe", &format!("本轮内核观察失败：{e}"), &[]);
                return;
            }
            Err(e) => {
                logging::warn_ctx("system", "observe", &format!("观察任务被丢弃：{e}"), &[]);
                return;
            }
        };
        let mut resolved: Vec<smartmwan::system::interface::Resolved> =
            ob.resolved.values().cloned().collect();
        resolved.sort_by(|a, b| a.wan.cmp(&b.wan));
        *self.st.ob.write().unwrap_or_else(|p| p.into_inner()) = Some(Arc::new(ob));

        let prober = self.prober.clone();
        let registry = self.st.registry.clone();
        let cancel = self.cancel_tx.subscribe();
        let info = health::run_round(prober, cfg, &resolved, &registry, cancel).await;
        if info.transitions > 0 {
            logging::info_ctx(
                "health",
                "round",
                &format!(
                    "探测轮完成：{} 计划 / {} 完成 / {} 状态迁移",
                    info.planned, info.completed, info.transitions
                ),
                &[],
            );
        }
        *self.st.last_round.lock().unwrap_or_else(|p| p.into_inner()) = Some(info);

        // 流量与连接采样（动态算法的输入 + UI 数据）。
        let sample = system::sample(cfg, &self.env, now);
        {
            let mut g = self.st.traffic.write().unwrap_or_else(|p| p.into_inner());
            g.prev = Some(g.cur.clone());
            g.cur = sample;
        }
        if let Ok(c) = conntrack::snapshot(PathBuf::from(CONNTRACK_PROC), now).await {
            let limits = conntrack::read_limits(Path::new(NETFILTER_SYSCTL));
            let mut g = self.st.conns.write().unwrap_or_else(|p| p.into_inner());
            g.prev = Some(g.cur.clone());
            g.cur = c;
            g.limits = limits;
        }

        *self.st.snap.write().unwrap_or_else(|p| p.into_inner()) = registry.snapshot(now);
    }

    // ---------- 决策与下发 ----------

    /// 一轮决策。代际在桶图变化时递增（它进程序文本，无谓递增等于无谓重写）。
    ///
    /// 失败必须返回 `Err` 而不是一份空决策：空桶图提交下去等于把内核里的
    /// 分流规则全部清掉（线路明明可用却瞬间失联）。
    async fn decide(&mut self, cfg: &Config, now: u64) -> Result<Decision> {
        let snap = self
            .st
            .snap
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .clone();
        let loads = self.compute_loads(cfg);
        *self.st.loads.write().unwrap_or_else(|p| p.into_inner()) = loads.clone();

        let slots = match scheduler::slot_map(cfg) {
            Ok(s) => s,
            Err(e) => return Err(logging::error_ctx("scheduler", "slots", e, &[])),
        };
        let mut g = self.st.scheduler.lock().unwrap_or_else(|p| p.into_inner());
        // 游戏择优与决策在同一把锁里完成：保证「显示的排名」与「下发的落点」同源。
        let active = g.active().map(str::to_string);
        let ranking = g.ranking(cfg, &slots, &snap, active.as_deref());
        let mut picks: BTreeMap<String, u8> = BTreeMap::new();
        for rule in cfg.games.iter().filter(|r| r.enabled) {
            if rule.selection != GameSelection::Best {
                continue;
            }
            let pick = g.pick_for_rule(cfg, &rule.name, ranking.clone(), now);
            if let Some(chosen) = pick.chosen {
                if let Some(slot) = slots.get(&chosen).copied() {
                    picks.insert(rule.name.clone(), slot);
                }
            }
        }
        match g.decide(cfg, &snap, &loads, now) {
            Ok(outcome) => {
                // 代际不在这里递增：递增时机见 `apply_decision`（只有完整事务才换代）。
                let decision = Decision {
                    bucket_map: outcome.buckets.clone(),
                    picks,
                    gen: self.gen,
                    now_ms: now,
                };
                *self.st.outcome.write().unwrap_or_else(|p| p.into_inner()) = Some(outcome);
                *self.st.decision.write().unwrap_or_else(|p| p.into_inner()) = decision.clone();
                Ok(decision)
            }
            Err(e) => Err(logging::error_ctx("scheduler", "decide", e, &[])),
        }
    }

    /// 组装动态算法的负载输入（连接数 + 速率 + 配置上限）。
    fn compute_loads(&self, cfg: &Config) -> BTreeMap<String, scheduler::balancing::Load> {
        let conns = self
            .st
            .conns
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .clone();
        let traffic = self
            .st
            .traffic
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .clone();
        let delta = traffic
            .cur
            .delta(traffic.prev.as_ref().unwrap_or(&traffic.cur));
        let window_ms = traffic
            .prev
            .as_ref()
            .map(|p| traffic.cur.at_ms.saturating_sub(p.at_ms))
            .unwrap_or(0);
        let slots = scheduler::slot_map(cfg).unwrap_or_default();
        let mut out = BTreeMap::new();
        for w in cfg.wans.iter().filter(|w| w.enabled) {
            let dev = if w.device.is_empty() {
                w.name.clone()
            } else {
                w.device.clone()
            };
            let (rx_b, tx_b) = delta.get(&dev).copied().unwrap_or((0, 0));
            let rate = |bytes: u64| -> u64 {
                bytes
                    .saturating_mul(8000)
                    .checked_div(window_ms)
                    .map(|v| v / 1024)
                    .unwrap_or(0)
            };
            let slot = slots.get(&w.name).copied().unwrap_or(0);
            let conns_now = if slot == 0 {
                0
            } else {
                conns.cur.of_slot(slot)
            };
            let conns_prev = if slot == 0 {
                0
            } else {
                conns.prev.as_ref().map(|c| c.of_slot(slot)).unwrap_or(0)
            };
            out.insert(
                w.name.clone(),
                scheduler::balancing::Load {
                    conns: conns_now,
                    new_conns: conns_now.saturating_sub(conns_prev),
                    rx_kbps: rate(rx_b),
                    tx_kbps: rate(tx_b),
                    down_kbps: w.down_kbps,
                    up_kbps: w.up_kbps,
                    conn_limit: cfg.global.max_connections_per_wan,
                    measured: window_ms > 0,
                },
            );
        }
        out
    }

    /// 一轮「决策 + 按需下发」。`force` = RPC 显式触发（即使无变更也提交一次，
    /// 让回执如实反映复核结论）。`None` = 无需任何写入。
    async fn cycle(&mut self, cfg: &Config, now: u64, force: bool) -> Option<Receipt> {
        let decision = match self.decide(cfg, now).await {
            Ok(d) => d,
            // 决策失败绝不下发：宁可保持内核现状（旧规则仍然有效），
            // 也不能提交一份空桶图把分流清空。
            Err(e) => return Some(self.failed_receipt(&e)),
        };
        let fp = config::fingerprint(cfg);
        let cfg_changed = self.last_applied_fp.as_deref() != Some(fp.as_str());
        let picks_changed = decision.picks != self.last_picks;
        let outcome_changed = self
            .st
            .outcome
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .as_ref()
            .map(|o| o.changed)
            .unwrap_or(false);
        if !needs_submit(
            force,
            outcome_changed,
            cfg_changed,
            picks_changed,
            self.last_ok,
        ) {
            return None;
        }
        if !force && self.next_retry_ms > now {
            // 上一次提交失败了，还在退避期：只更新缓存，不重放事务。
            return None;
        }
        self.apply_decision(cfg, &decision, force, now).await
    }

    /// 选择热替换还是完整事务，并更新记账。
    async fn apply_decision(
        &mut self,
        cfg: &Config,
        decision: &Decision,
        force: bool,
        now: u64,
    ) -> Option<Receipt> {
        let fp = config::fingerprint(cfg);
        let picks_changed = decision.picks != self.last_picks;
        let same_config = self.last_applied_fp.as_deref() == Some(fp.as_str());
        if !force
            && hot_replace_allowed(self.nft.is_some(), self.last_ok, same_config, picks_changed)
        {
            match self.hot_replace(cfg, decision).await {
                Ok(rec) => {
                    *self.st.receipt.write().unwrap_or_else(|p| p.into_inner()) = Some(rec.clone());
                    self.last_ok = true;
                    self.last_applied_fp = Some(fp);
                    self.last_picks = decision.picks.clone();
                    return Some(rec);
                }
                Err(e) => {
                    // 热替换失败不改变内核现状（replace 是单条原子操作），
                    // 回退完整事务重试；日志必须留下为什么回退。
                    logging::warn_ctx(
                        "transaction",
                        "hot-replace",
                        &format!("热替换失败，回退完整事务：{e}"),
                        &[],
                    );
                }
            }
        }
        // 完整事务（整表重写）：代际只在这里递增，见 `gen` 字段的说明。
        let mut applied = decision.clone();
        self.gen = self.gen.wrapping_add(1) & 0x0F;
        applied.gen = self.gen;
        let receipt = self.st.coordinator.submit(cfg, &applied).await;
        self.last_ok = receipt.ok;
        if receipt.ok {
            self.last_applied_fp = Some(fp);
            self.last_picks = applied.picks.clone();
            // 让 UI 看到的决策与真正下发的代际一致。
            *self.st.decision.write().unwrap_or_else(|p| p.into_inner()) = applied;
            self.next_retry_ms = 0;
        } else {
            // 失败进退避：下一个 tick 不再重放，等 SUBMIT_RETRY_BACKOFF_MS。
            self.next_retry_ms = now + SUBMIT_RETRY_BACKOFF_MS;
        }
        *self.st.receipt.write().unwrap_or_else(|p| p.into_inner()) = Some(receipt.clone());
        Some(receipt)
    }

    /// 桶轮排热替换：只 `replace rule` 那几条桶映射规则，不重建整表。
    ///
    /// 前置条件由调用方保证（见 [`hot_replace_allowed`]）：nft 通道为 Real、
    /// 上次提交成功、配置指纹与上次应用一致（⇒ 程序除桶图外逐字节相同）、
    /// **且游戏择优未变**（择优写进游戏规则标记，不在这批要 replace 的桶规则里）。
    /// 任一不满足都走完整事务。
    async fn hot_replace(&self, cfg: &Config, decision: &Decision) -> Result<Receipt> {
        let nft = self
            .nft
            .as_ref()
            .ok_or_else(|| Error::Firewall("没有 nft 通道，不能热替换".into()))?;
        let tx = self.st.coordinator.next_transaction_id();
        let prev = config::Store::load_applied(&self.st.paths.state_dir);
        let plan = self
            .st
            .coordinator
            .plan(cfg, decision, prev.as_ref(), tx.clone())
            .await?;
        if let Some(blocked) = plan.blocked() {
            return Err(Error::Validate(format!(
                "已拒绝热替换，未改动内核：{blocked}"
            )));
        }
        let buckets = plan
            .program
            .as_ref()
            .map(|p| p.buckets.clone())
            .unwrap_or_default();
        if buckets.is_empty() {
            return Err(Error::Firewall("计划里没有桶规则可替换".into()));
        }
        let t0 = std::time::Instant::now();
        let mut notes: Vec<String> = Vec::new();
        for b in &buckets {
            let actual = nft.list_chain(b.chain).await?;
            let handle = actual
                .iter()
                .find(|r| r.comment.as_deref() == Some(b.comment.as_str()))
                .map(|r| r.handle)
                .ok_or_else(|| {
                    Error::Firewall(format!(
                        "链 {} 里找不到标签 {}，无法定位规则",
                        b.chain, b.comment
                    ))
                })?;
            nft.replace_rule(b.chain, handle, &b.body).await?;
            notes.push(format!("{}：handle {handle} 已替换", b.comment));
        }
        // 复核：替换后标签必须还在（replace 返回成功但规则消失 = 内核没接受）。
        for b in &buckets {
            let actual = nft.list_chain(b.chain).await?;
            if !actual
                .iter()
                .any(|r| r.comment.as_deref() == Some(b.comment.as_str()))
            {
                return Err(Error::Firewall(format!(
                    "热替换后标签 {} 不在链里",
                    b.comment
                )));
            }
        }
        // 记账：applied.nft 必须同步成新程序，否则下次完整提交的幂等判据失效。
        self.st.coordinator.record_program(&plan.text(), cfg, &tx)?;
        logging::info_ctx(
            "transaction",
            "hot-replace",
            &format!("桶轮排热替换完成（{}）", notes.join("；")),
            &[("transaction", tx.clone())],
        );
        Ok(Receipt {
            id: tx,
            ok: true,
            changed: true,
            stages: vec![StageRecord {
                stage: Stage::FirewallApply,
                ok: true,
                took_ms: t0.elapsed().as_millis() as u64,
                note: format!("热替换 {} 条桶映射规则（未重建整表）", buckets.len()),
            }],
            issues: Vec::new(),
            pending: plan.pending.clone(),
            domains: plan.domains.clone(),
            rollback: Vec::new(),
            summary: format!(
                "桶轮排热替换：{} 条桶规则更新，策略路由未动（槽位未变）",
                buckets.len()
            ),
            error: None,
            firewall: self.st.coordinator.plane().fw.describe(),
        })
    }

    /// 决策失败的回执：明说「未触碰内核」，并把原因原样带给 RPC/前端。
    fn failed_receipt(&self, err: &Error) -> Receipt {
        let rec = Receipt {
            id: self.st.coordinator.next_transaction_id(),
            ok: false,
            changed: false,
            summary: format!("本轮决策失败，未向内核写入任何内容：{err}"),
            error: Some(err.to_string()),
            firewall: self.st.coordinator.plane().fw.describe(),
            ..Default::default()
        };
        *self.st.receipt.write().unwrap_or_else(|p| p.into_inner()) = Some(rec.clone());
        rec
    }

    /// 无变更时的回执（RPC apply 需要一份能显示的回执）。
    fn idle_receipt(&self) -> Receipt {
        Receipt {
            id: self.st.coordinator.next_transaction_id(),
            ok: true,
            changed: false,
            summary: "决策未变化且配置未变化：未产生任何数据面写入".into(),
            firewall: self.st.coordinator.plane().fw.describe(),
            ..Default::default()
        }
    }
}

// ==================== 下发门控 ====================

/// 本轮是否必须提交。
///
/// `last_ok == false` 表示上一次提交失败：此时即使「本轮没有任何新变化」也必须重试。
/// 否则一次桶图提交失败后，下一轮 `outcome_changed` / `cfg_changed` 都是相对上一轮
/// **决策**算出来的假，`cycle` 会在退避检查之前提前返回，失败永远不收敛。
fn needs_submit(
    force: bool,
    outcome_changed: bool,
    cfg_changed: bool,
    picks_changed: bool,
    last_ok: bool,
) -> bool {
    force || !last_ok || outcome_changed || cfg_changed || picks_changed
}

/// 能否只做桶规则热替换。
///
/// 前提：nft 通道可用、上次提交成功、配置指纹与上次应用一致（⇒ 程序除桶图外逐字节
/// 相同）、**且游戏择优未变**。择优变化改的是游戏规则的标记（槽位位），而热替换只
/// `replace` 桶规则 —— 放过去会让游戏流量继续落在旧出口，内核与快照就此分叉。
fn hot_replace_allowed(
    has_nft: bool,
    last_ok: bool,
    same_config: bool,
    picks_changed: bool,
) -> bool {
    has_nft && last_ok && same_config && !picks_changed
}

// ==================== 旁路环 ====================

/// 信号处理：SIGHUP = 重载；SIGTERM/SIGINT = 关停（带看门狗）。
///
/// 看门狗存在的理由是一次真实的事故：主循环楔死在 netlink recv 里时，
/// 「先停主循环再回收」的关停代码永远走不到，SIGTERM 形同虚设。
async fn signal_loop(ctl: mpsc::UnboundedSender<Command>, shutdown: Arc<ShutdownCtl>) {
    use tokio::signal::unix::{signal, SignalKind};
    let mut term = match signal(SignalKind::terminate()) {
        Ok(s) => s,
        Err(e) => {
            logging::error_ctx("main", "signal", Error::Io(e), &[]);
            return;
        }
    };
    let mut int = match signal(SignalKind::interrupt()) {
        Ok(s) => s,
        Err(e) => {
            logging::error_ctx("main", "signal", Error::Io(e), &[]);
            return;
        }
    };
    let mut hup = match signal(SignalKind::hangup()) {
        Ok(s) => s,
        Err(e) => {
            logging::error_ctx("main", "signal", Error::Io(e), &[]);
            return;
        }
    };
    loop {
        tokio::select! {
            _ = term.recv() => {
                logging::info_ctx("main", "signal", "收到 SIGTERM，开始关停", &[]);
                request_shutdown(&ctl, &shutdown);
                return;
            }
            _ = int.recv() => {
                logging::info_ctx("main", "signal", "收到 SIGINT，开始关停", &[]);
                request_shutdown(&ctl, &shutdown);
                return;
            }
            _ = hup.recv() => {
                logging::info_ctx("main", "signal", "收到 SIGHUP，重载配置", &[]);
                let (tx, _rx) = tokio::sync::oneshot::channel();
                let _ = ctl.send(Command::Reload(tx));
            }
        }
    }
}

/// 请求关停并看好门狗：主循环不响应就强制走关停序列后退出。
fn request_shutdown(ctl: &mpsc::UnboundedSender<Command>, shutdown: &Arc<ShutdownCtl>) {
    let _ = shutdown.tx.send(true);
    let _ = shutdown.cancel.send(true);
    let ctl = ctl.clone();
    let shutdown = shutdown.clone();
    tokio::spawn(async move {
        tokio::time::sleep(SHUTDOWN_WATCHDOG).await;
        // 到点主循环还没停：不等了，自己收尾并退出。
        // 保留 ctl 发送端：否则等待中的 RPC 写方法会误报「主循环未运行」。
        let _keep_alive = ctl;
        shutdown.run_sequence(true).await;
        std::process::exit(1);
    });
}

/// 域名集合刷新环：解析 → 对账 → 增量写内核集合。
///
/// 三条边界（写进代码而不是靠文档里有人记得）：
/// * 解析失败**绝不**回灌健康层（DNS 故障不是出口故障）；
/// * 内核集合自身带 timeout 会老化，这里只做「账本与内核一致」的增删；
/// * 集合不存在（规则还没下发）时写失败只记告警。
async fn dns_loop(st: Arc<AppState>, nft: Option<Arc<Nft>>, mut shutdown: watch::Receiver<bool>) {
    let mut ticker = tokio::time::interval(DNS_REFRESH);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_ok() && *shutdown.borrow() {
                    return;
                }
            }
            _ = ticker.tick() => {}
        }
        let cfg = st.cfg_snapshot();
        let ttl = cfg.global.dns_ttl_floor_s.max(30);
        // 域名 → 规则集合名。一个域名可能被多条规则引用，每个集合都要写。
        let mut wanted: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for g in cfg
            .games
            .iter()
            .filter(|g| g.enabled && !g.domains.is_empty())
        {
            let set = format!("smw_g_{}_dns", matchers::slug_of(&g.name));
            for d in &g.domains {
                wanted.entry(d.clone()).or_default().push(set.clone());
            }
        }
        if wanted.is_empty() {
            continue;
        }
        let now = logging::now_ms();
        {
            let mut reg = st.dns.lock().unwrap_or_else(|p| p.into_inner());
            reg.refresh_stale(now);
        }
        // 解析（BTreeMap 保证顺序确定：同一份答案无论以什么顺序到达，集合内容一致）。
        let mut answers: BTreeMap<String, Vec<std::net::IpAddr>> = BTreeMap::new();
        for domain in wanted.keys() {
            match dns_sets::resolve(domain, DNS_RESOLVE_TIMEOUT).await {
                Ok(addrs) => {
                    answers.insert(domain.clone(), addrs);
                }
                Err(e) => {
                    let mut reg = st.dns.lock().unwrap_or_else(|p| p.into_inner());
                    reg.note_failure(domain, &e);
                    logging::warn_ctx(
                        "dns",
                        "resolve",
                        &format!("域名 {domain} 解析失败：{e}（不计为线路故障）"),
                        &[],
                    );
                }
            }
        }
        let diffs = {
            let mut reg = st.dns.lock().unwrap_or_else(|p| p.into_inner());
            dns_sets::observe_all(&mut reg, &answers, now)
        };
        let Some(nft) = nft.as_ref() else {
            continue;
        };
        for (domain, diff) in &diffs {
            let Some(sets) = wanted.get(domain) else {
                continue;
            };
            for set in sets {
                if !diff.added.is_empty() {
                    if let Err(e) = nft.add_elements(set, &diff.added, ttl).await {
                        logging::warn_ctx(
                            "dns",
                            "add",
                            &format!("集合 {set} 添加 {} 个元素失败：{e}", diff.added.len()),
                            &[],
                        );
                    }
                }
                if !diff.removed.is_empty() {
                    if let Err(e) = nft.del_elements(set, &diff.removed).await {
                        logging::warn_ctx(
                            "dns",
                            "del",
                            &format!("集合 {set} 删除 {} 个元素失败：{e}", diff.removed.len()),
                            &[],
                        );
                    }
                }
            }
        }
        // 账本过期清扫（内核集合自己会老化，这里只为账本一致）。
        let expired = {
            let mut reg = st.dns.lock().unwrap_or_else(|p| p.into_inner());
            reg.expire(now)
        };
        if !expired.is_empty() {
            logging::debug_ctx(
                "dns",
                "expire",
                &format!(
                    "账本过期元素 {} 个（内核集合按其 timeout 自行老化）",
                    expired.len()
                ),
                &[],
            );
        }
    }
}

// ==================== 单元测试 ====================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reclaim_load_falls_back_to_defaults_when_config_is_broken() {
        // 卸载/排障的兜底清场不能被坏配置挡住：目录路径会让读文件报
        // 「Is a directory」（非 NotFound），必须回落到默认配置而不是失败。
        let cfg = load_config_or_default(Path::new("/tmp"));
        assert_eq!(cfg, Config::default());
        // 回落值必须仍是合法配置：桶数等常量不随用户配置改变，回收只依赖它们。
        assert_eq!(cfg.global.buckets, Config::default().global.buckets);
    }

    #[test]
    fn reclaim_load_accepts_missing_config() {
        // 首次安装前的清理：文件不存在时 load() 本身就给默认配置。
        let cfg = load_config_or_default(Path::new("/nonexistent/smartmwan/config"));
        assert_eq!(cfg, Config::default());
    }

    #[test]
    fn failed_submit_is_retried_even_without_new_changes() {
        // 关键回归：桶图提交失败后，下一轮「相对上一轮决策」看起来毫无变化。
        // 若门控只看变化标志，退避重试永远不可达 —— 一次失败就永久停在不收敛状态。
        assert!(needs_submit(false, false, false, false, false));
        // 成功收敛且无变化时不该重放事务。
        assert!(!needs_submit(false, false, false, false, true));
        // 三个变化源各自都能单独触发提交。
        assert!(needs_submit(false, true, false, false, true));
        assert!(needs_submit(false, false, true, false, true));
        assert!(needs_submit(false, false, false, true, true));
        // 显式 apply 无条件提交。
        assert!(needs_submit(true, false, false, false, true));
    }

    #[test]
    fn hot_replace_is_refused_when_picks_change() {
        // 择优变化改的是游戏规则标记（槽位位），而热替换只 replace 桶规则：
        // 放过去会让游戏流量继续走旧出口。必须回退完整事务。
        assert!(!hot_replace_allowed(true, true, true, true));
        // 其余条件任一不满足都拒绝。
        assert!(!hot_replace_allowed(false, true, true, false));
        assert!(!hot_replace_allowed(true, false, true, false));
        assert!(!hot_replace_allowed(true, true, false, false));
        // 四项都满足才允许。
        assert!(hot_replace_allowed(true, true, true, false));
    }
}

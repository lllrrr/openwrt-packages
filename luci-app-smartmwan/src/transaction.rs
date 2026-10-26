//! 事务层（M6）：把「配置 → 规则 → nft 程序 → 策略路由」编排成一次可回滚的提交。
//!
//! # 为什么需要这一层
//!
//! 前面几层各自都是对的，但谁也不认识谁：
//!
//! * `system::route` 有差量、逆操作（[`route::Undo`]）与应用后校验，只管 `ip rule` / 路由表；
//! * `system::firewall` 有程序生成、`nft -c` 试算、原子提交与标签复核，只管 nft；
//! * `rules::compile` 把用户写的游戏条件编译成 `GameSpec`，只管条件语义。
//!
//! 「谁先谁后」「中间失败了怎么办」「失败了内核里留下的是哪半套」这三件事，
//! 在装配之前没有任何一层回答得了。事务层就是那个回答者。
//!
//! # 阶段顺序（固定，不允许跳过或调换）
//!
//! ```text
//! validate → plan → nft dry-run → route apply → route verify
//!          → nft apply → nft verify → persist last-good
//! ```
//!
//! 先路由后 nft 是**故意的**：策略路由（表与规则）先就位，标记规则后就位，
//! 中间任何时刻的流量都落在「未标记 ⇒ main 表默认路由」这条安全路径上。
//! 反过来先提交 nft，就会出现「包被标记成 table 105，而 table 105 还是空的」
//! —— 那是黑洞，不是降级。
//!
//! # 回滚
//!
//! 每个有副作用的步骤成功执行后，把它的逆操作压进栈；任一步失败就**逆序**弹出执行。
//! nft 侧的逆操作是「重新提交上一版程序」（没有上一版就是删表），因为 nft 的批量提交
//! 是原子的：`nft -f` 失败时表内容未变，成功时要么全新要么全无，所以「重放上一版」
//! 总能回到事务开始前。
//!
//! 回滚过程中的每一个错误都必须留在 [`Receipt::rollback`] 里并写日志 ——
//! 「回滚失败」是运维最需要知道的事，绝不能被 `let _ =` 吃掉。
//!
//! # 幂等
//!
//! 同一份配置 + 同一份决策，第二次提交必须得出「差量为空且 nft 程序文本逐字节相同」，
//! 此时跳过所有下发步骤、**只做复核**。判据是算出来的（`Diff::is_empty()` + 程序文本比对），
//! 不是「我觉得没变」。
//!
//! # 本层刻意不做的事
//!
//! * 不做桶轮转（那是热路径，走 `firewall::Nft::replace_rule`，一次重排只替换几条规则，
//!   绝不全量重建 —— 任务书第「不得高频全量重建 nftables」条）；
//! * 不做 DNS 解析（域名解析是旁路，失败不得影响线路健康，见 `docs/ARCHITECTURE.md` §3；
//!   本层只把 [`rules::Compiled::domains`] 原样交给回执，由守护进程的独立任务消费）；
//! * 不写 `/etc/config/smartmwan`（「保存」与「应用」分离：写盘是 `config::Store::save`，
//!   本层只负责把已保存的配置变成内核状态并记录 [`config::Applied`] 快照）。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use tokio::sync::Mutex as AsyncMutex;

use crate::config::{self, schema::Config, validate::Issue};
use crate::rules::{self, matchers, presets};
use crate::scheduler;
use crate::system::firewall::{self, Capabilities, GameSpec, Nft, Program, RuleInfo, Tag};
use crate::system::netlink::{Family, RouteOps};
use crate::system::route::{self, Applier, Desired, Undo};
use crate::system::{Env, Observation};
use crate::{Error, Result};

/// 已提交 nft 程序的落盘文件名（幂等比较依据 + nft 侧回滚基线）。
pub const APPLIED_NFT: &str = "applied.nft";

/// `state_dir/applied.nft` 的完整路径。
pub fn applied_nft_path(state_dir: &Path) -> PathBuf {
    state_dir.join(APPLIED_NFT)
}

// ==================== 阶段 ====================

/// 事务阶段。名字同时进日志、回执与 RPC 响应，前端不必再翻译一遍。
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum Stage {
    Validate,
    Plan,
    FirewallCheck,
    RouteApply,
    RouteVerify,
    FirewallApply,
    FirewallVerify,
    Persist,
}

impl Stage {
    /// 机器可读名（日志字段、RPC JSON）。
    pub fn as_str(self) -> &'static str {
        match self {
            Stage::Validate => "validate",
            Stage::Plan => "plan",
            Stage::FirewallCheck => "firewall_check",
            Stage::RouteApply => "route_apply",
            Stage::RouteVerify => "route_verify",
            Stage::FirewallApply => "firewall_apply",
            Stage::FirewallVerify => "firewall_verify",
            Stage::Persist => "persist",
        }
    }

    /// 中文阶段名，UI 进度条直接用。
    pub fn label(self) -> &'static str {
        match self {
            Stage::Validate => "配置校验",
            Stage::Plan => "生成计划",
            Stage::FirewallCheck => "nft 试算",
            Stage::RouteApply => "下发策略路由",
            Stage::RouteVerify => "复核策略路由",
            Stage::FirewallApply => "提交 nft",
            Stage::FirewallVerify => "复核 nft",
            Stage::Persist => "记录快照",
        }
    }
}

/// 一个阶段的执行记录。
#[derive(Debug, Clone, serde::Serialize)]
pub struct StageRecord {
    pub stage: Stage,
    pub ok: bool,
    pub took_ms: u64,
    /// 人话说明（做了什么 / 为什么没做 / 失败原因）。
    pub note: String,
}

impl StageRecord {
    fn new(stage: Stage, from: Instant, ok: bool, note: String) -> StageRecord {
        StageRecord {
            stage,
            ok,
            took_ms: from.elapsed().as_millis() as u64,
            note,
        }
    }
}

// ==================== 决策快照 ====================

/// 调度器给出的决策快照。
///
/// 事务层**不自己分桶、不自己择优**：那两处逻辑在 `scheduler` 里已经各有一份实现，
/// 在这里再算一次就等于「界面显示一套、内核下发另一套」。
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct Decision {
    /// 桶号 → 槽位，长度必须等于 `global.buckets`；`0` 表示该桶不分流。
    pub bucket_map: Vec<u8>,
    /// 游戏规则名 → 选定槽位。`rules::compile` 用它判断 `selection = best` 能否下发。
    pub picks: BTreeMap<String, u8>,
    /// 标记里的代际（bit12..15，仅观测用）。
    pub gen: u8,
    /// 本轮决策时间（写进摘要，便于把内核状态和日志对上）。
    pub now_ms: u64,
}

// ==================== nft 侧执行通道 ====================

/// nft 侧执行通道。
///
/// 为什么是枚举而不是 trait：`Nft` 的方法是 `async`，做成对象安全得手写
/// `Pin<Box<dyn Future>>`；而这里只有三种确定实现（真 nft / 测试替身 / 环境无 nft），
/// 枚举分派更直白，也不会让人误以为可以随意插第三种实现。
#[derive(Clone)]
pub enum FirewallExec {
    /// 真实 `nft` 执行器。
    Real(Arc<Nft>),
    /// 替身：只用于在**没有 nft 与 netfilter 的构建环境**里验证编排与回滚。
    Sim(Arc<Sim>),
    /// 设备上找不到 `nft`。这不是「跳过防火墙阶段就行」——标记不生效 ⇒ 插件不工作，
    /// 因此事务会在下发前把它判为阻塞错误（除非配置本身是停用的）。
    Absent,
}

impl FirewallExec {
    /// 是否有可执行的 nft 通道。
    pub fn available(&self) -> bool {
        !matches!(self, FirewallExec::Absent)
    }

    /// 一句话说明用的是哪种通道，必须出现在回执里（替身与缺失都不许冒充真执行器）。
    pub fn describe(&self) -> String {
        match self {
            FirewallExec::Real(n) => format!("nft:{}", n.program()),
            FirewallExec::Sim(_) => "sim(测试替身，不验证 nft 语法)".to_string(),
            FirewallExec::Absent => "absent(无 nft 可执行文件)".to_string(),
        }
    }

    /// `nft -c -f`：只解析与语义检查，不产生任何副作用。
    pub async fn check(&self, text: &str) -> Result<()> {
        match self {
            FirewallExec::Real(n) => n.check(text).await,
            FirewallExec::Sim(s) => s.exchange("check", text, true).await,
            FirewallExec::Absent => Err(Error::Firewall(
                "本环境没有 nft 可执行文件，无法试算防火墙程序".into(),
            )),
        }
    }

    /// `nft -f`：原子提交。
    pub async fn apply(&self, text: &str) -> Result<()> {
        match self {
            FirewallExec::Real(n) => n.apply(text).await,
            FirewallExec::Sim(s) => s.exchange("apply", text, false).await,
            FirewallExec::Absent => Err(Error::Firewall(
                "本环境没有 nft 可执行文件，无法提交防火墙程序".into(),
            )),
        }
    }

    /// 列出某条链的实际规则（复核用）。
    pub async fn list(&self, chain: &str) -> Result<Vec<RuleInfo>> {
        match self {
            FirewallExec::Real(n) => n.list_chain(chain).await,
            FirewallExec::Sim(s) => Ok(s.list(chain)),
            FirewallExec::Absent => Err(Error::Firewall("无 nft，无法复核".into())),
        }
    }
}

/// 替身的内部状态。
#[derive(Debug, Default)]
struct SimState {
    /// 非 `None` ⇒ `check` 以此文案失败（模拟 `nft -c` 拒绝）。
    check_error: Option<String>,
    /// 非 `None` ⇒ `apply` 以此文案失败（模拟 `nft -f` 拒绝）。
    apply_error: Option<String>,
    /// `true` ⇒ `apply` 返回成功但链里看不到规则（模拟「提交成功、规则没落地」）。
    hide_after_apply: bool,
    /// 已提交的程序文本（最后一次 `apply` 的内容），回滚基线测试用。
    applied: Vec<String>,
    /// 调用顺序，例如 `["check", "apply", "apply"]`。
    calls: Vec<String>,
    /// 「内核里实际存在的标签」。`None` = 与最后一次提交的程序一致。
    present: Option<Vec<String>>,
}

/// `nft` 替身。
///
/// **它不证明 nft 语法可用** —— 本沙箱既没有 `nft` 二进制也没有 netfilter，
/// 语法可用性只能由 `firewall::probe_scripts()` 在真机上用 `nft -c` 测出来。
/// 它存在的唯一意义是：让「阶段顺序 / 失败中断 / 逆序回滚 / 复核不通过就不写快照」
/// 这些编排逻辑能被单测覆盖，而不是只能靠真机验证。
#[derive(Debug, Default)]
pub struct Sim {
    state: Mutex<SimState>,
}

impl Sim {
    pub fn new() -> Arc<Sim> {
        Arc::new(Sim::default())
    }

    /// 让 `check` 失败（`None` 恢复成功）。
    pub fn fail_check(&self, msg: Option<String>) {
        self.lock().check_error = msg;
    }

    /// 让 `apply` 失败（`None` 恢复成功）。
    pub fn fail_apply(&self, msg: Option<String>) {
        self.lock().apply_error = msg;
    }

    /// 模拟「`nft -f` 返回 0，但规则并不在链里」——真机上对应并发修改或内核内部拒绝。
    /// 事务的复核阶段必须因此失败并回滚，这是本替身最有价值的一条路径。
    pub fn hide_applied_rules(&self, on: bool) {
        self.lock().hide_after_apply = on;
    }

    /// 指定「内核里现在有哪些标签」。`None` 表示跟随最后一次提交的程序。
    pub fn set_present(&self, tags: Option<Vec<String>>) {
        self.lock().present = tags;
    }

    /// 已提交的程序文本（按顺序）。
    pub fn programs(&self) -> Vec<String> {
        self.lock().applied.clone()
    }

    /// 调用顺序。
    pub fn calls(&self) -> Vec<String> {
        self.lock().calls.clone()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, SimState> {
        // 中毒只可能因为测试代码 panic；那时让 panic 继续向外传比假装无事发生更好。
        match self.state.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        }
    }

    /// 替身的 check/apply：记录调用，按剧本成败。
    async fn exchange(&self, kind: &str, text: &str, is_check: bool) -> Result<()> {
        if text.trim().is_empty() {
            return Err(Error::Firewall("替身拒绝执行空程序".into()));
        }
        let err = {
            let mut s = self.lock();
            s.calls.push(kind.to_string());
            if is_check {
                s.check_error.clone()
            } else {
                if s.apply_error.is_none() {
                    s.applied.push(text.to_string());
                    // 新提交的程序成为新的「内核现状」，除非测试显式要求不一致。
                    s.present = if s.hide_after_apply {
                        Some(Vec::new())
                    } else {
                        None
                    };
                }
                s.apply_error.clone()
            }
        };
        match err {
            Some(m) => Err(Error::Firewall(format!("模拟 {kind} 失败：{m}"))),
            None => Ok(()),
        }
    }

    /// 模拟 `nft -a list chain <chain>`：只返回该链块里的标签。
    fn list(&self, chain: &str) -> Vec<RuleInfo> {
        let s = self.lock();
        let tags: Vec<String> = match &s.present {
            Some(t) => t.clone(),
            None => s
                .applied
                .last()
                .map(|text| comments_of_chain(text, chain))
                .unwrap_or_default(),
        };
        tags.into_iter()
            .enumerate()
            .map(|(i, comment)| RuleInfo {
                handle: (i + 1) as u64,
                comment: Some(comment),
                body: String::new(),
                packets: 0,
                bytes: 0,
            })
            .collect()
    }
}

/// 从程序文本的某个 `chain <名字> { ... }` 块里取出 `smw:` 标签。
///
/// 只认 `comment "smw:..."`，不做完整 nft 解析：这个函数只存在于测试替身路径，
/// 真机复核走 `firewall::parse_chain_listing`。按大括号深度配对，因此集合声明里的
/// `{ 1.2.3.4 }` 之类不会干扰边界。
fn comments_of_chain(text: &str, chain: &str) -> Vec<String> {
    let needle = format!("chain {chain}");
    let mut out = Vec::new();
    let mut search_from = 0usize;
    while let Some(rel) = text[search_from..].find(&needle) {
        let start = search_from + rel;
        // 找到本块的起始 `{`，再按深度找匹配的 `}`。
        let Some(open) = text[start..].find('{') else {
            break;
        };
        let open_at = start + open;
        let mut depth = 0usize;
        let mut end = text.len();
        for (i, ch) in text[open_at..].char_indices() {
            match ch {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        end = open_at + i;
                        break;
                    }
                }
                _ => {}
            }
        }
        out.extend(collect_comments(&text[open_at..end], true));
        search_from = end + 1;
        if search_from >= text.len() {
            break;
        }
    }
    dedup(out)
}

/// 收集一段文本里的 `comment "..."`。`only_smw` 为真时只保留本插件前缀。
fn collect_comments(segment: &str, only_smw: bool) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = segment;
    while let Some(i) = rest.find("comment \"") {
        let tail = &rest[i + "comment \"".len()..];
        match tail.find('"') {
            Some(j) => {
                let c = &tail[..j];
                if !only_smw || c.starts_with("smw:") {
                    out.push(c.to_string());
                }
                rest = &tail[j + 1..];
            }
            None => break,
        }
    }
    out
}

/// 保序去重。
fn dedup(items: Vec<String>) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    for item in items {
        if !seen.iter().any(|s| s == &item) {
            seen.push(item);
        }
    }
    seen
}

/// 「表不存在」的错误判定：删表/试算删表时，nft 会以非零码退出。
///
/// 这是对文案匹配的**一处有意妥协**：判据弱，因此只在「配置为停用 ⇒ 删表」这条路径上
/// 用于豁免，且豁免后必须在回执里写清依据；其它任何阶段的同类错误一律上抛。
fn is_no_such_table(msg: &str) -> bool {
    let m = msg.to_ascii_lowercase();
    m.contains("no such file or directory") || m.contains("cannot find table")
}

// ==================== 计划 ====================

/// 只读计划。`apply.preview`（RPC）与真正提交共用同一份计算结果，
/// 保证「给用户看的」和「下发到内核的」不是两次计算。
#[derive(Debug)]
pub struct Plan {
    /// 事务 id。
    pub tx: String,
    /// 配置为「停用」⇒ 期望状态是空，所有本插件对象都要被回收。
    pub disabled: bool,
    /// 策略路由侧的观察（含差量与冲突审计）。
    pub ob: Observation,
    /// 规则层编译产物，直接喂给 `firewall::Input::games`。
    pub games: Vec<GameSpec>,
    /// nft 程序（`None` 只可能出现在内部错误路径，正常计划一定有）。
    pub program: Option<Program>,
    /// 因「还没有择优结论」而暂未下发的规则名。
    pub pending: Vec<String>,
    /// 本轮待解析域名（交给守护进程的 DNS 任务，不属于事务）。
    pub domains: Vec<String>,
    /// 合并后的问题清单（观察 + 规则层 + 生成器 + 能力）。
    pub issues: Vec<Issue>,
    /// 相对上一次成功应用的字段级变更摘要（应用前必须展示）。
    pub changes: Vec<config::Change>,
    /// 人类可读摘要。
    pub summary: String,
    /// 已执行的只读阶段记录。
    pub stages: Vec<StageRecord>,
}

impl Plan {
    /// 是否禁止提交。返回阻塞原因。
    ///
    /// 三条判据都是 Error 级：内核现状被别的组件占用、配置/条件有致命问题、
    /// 或者这台设备根本没法执行 nft 却要求下发标记。
    pub fn blocked(&self) -> Option<String> {
        if let Some(msg) = self.ob.diff.blocking() {
            return Some(msg);
        }
        let errs: Vec<String> = self
            .issues
            .iter()
            .filter(|i| i.severity == crate::config::Severity::Error)
            .map(|i| format!("{}：{}", i.path, i.message))
            .collect();
        if errs.is_empty() {
            None
        } else {
            Some(crate::clamp_str(&errs.join("；"), 512))
        }
    }

    /// 期望存在的 nft 标签。
    pub fn tags(&self) -> Vec<Tag> {
        self.program
            .as_ref()
            .map(|p| p.tags.clone())
            .unwrap_or_default()
    }

    /// 程序文本。
    pub fn text(&self) -> String {
        self.program
            .as_ref()
            .map(|p| p.text.clone())
            .unwrap_or_default()
    }
}

// ==================== 回执 ====================

/// 一次事务的完整回执。
///
/// 事务的任何结局（成功、被拒绝、已回滚）都必须是一份回执，因此 [`Coordinator::submit`]
/// 不返回 `Result`：调用方不能因为走了错误分支而丢掉「内核现在是什么状态」这个信息。
///
/// 派生 `Serialize` 是为了让 RPC 把回执**原样**转给前端（`smartmwan.apply` 的响应体
/// 就是这份结构序列化的结果），而不是在传输途中压缩成布尔值。
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct Receipt {
    /// 事务 id，格式 `T<毫秒>-<pid>-<序号>`，同时写进快照与日志。
    pub id: String,
    /// 事务是否成功收敛。
    pub ok: bool,
    /// 是否真的改动了内核（`false` = 幂等命中，只复核未下发）。
    pub changed: bool,
    pub stages: Vec<StageRecord>,
    pub issues: Vec<Issue>,
    pub pending: Vec<String>,
    pub domains: Vec<String>,
    /// 回滚过程的记录；**非空就意味着内核状态需要人工确认**。
    pub rollback: Vec<String>,
    pub summary: String,
    pub error: Option<String>,
    /// nft 通道种类，避免把替身/缺失混成「已生效」。
    pub firewall: String,
}

impl Receipt {
    fn new(id: String, firewall: String) -> Receipt {
        Receipt {
            id,
            firewall,
            ..Default::default()
        }
    }

    fn record(&mut self, stage: Stage, from: Instant, ok: bool, note: String) {
        self.stages.push(StageRecord::new(stage, from, ok, note));
    }

    /// 单行结论，日志与 `config.apply` 的 RPC 响应都用它。
    pub fn describe(&self) -> String {
        let state = if self.ok {
            if self.changed {
                "已提交"
            } else {
                "无变更（幂等复核通过）"
            }
        } else if !self.rollback.is_empty() {
            "失败并已回滚"
        } else {
            "未提交"
        };
        let stages = self
            .stages
            .iter()
            .map(|s| format!("{}={}", s.stage.as_str(), if s.ok { "ok" } else { "fail" }))
            .collect::<Vec<_>>()
            .join(" ");
        let err = self
            .error
            .as_ref()
            .map(|e| format!("；原因：{}", crate::clamp_str(e, 200)))
            .unwrap_or_default();
        format!(
            "[{}] {state}{err}（{stages}；nft 通道 {}）",
            self.id, self.firewall
        )
    }
}

// ==================== 回收报告 ====================

/// 启动时的残留回收结果。
#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct ReclaimReport {
    /// 删除的本插件 `ip rule` 条数。
    pub rules_removed: usize,
    /// 删除的本插件路由条数。
    pub routes_removed: usize,
    /// nft 表是否被删除（或本来就不存在）。
    pub nft_dropped: bool,
    /// 不属于本插件、因此**保留不动**的对象（只报告，绝不误删）。
    pub foreign: Vec<String>,
    /// 过程说明（含 dump 失败等「看不到」的情况）。
    pub notes: Vec<String>,
}

// ==================== 回滚栈 ====================

/// 一个可撤销的副作用。压栈顺序即执行顺序，回滚逆序弹出。
#[derive(Debug)]
enum UndoAction {
    /// 已装入内核的 netlink 变更（逆操作表由 `Applier` 给出）。
    Routes(Vec<Undo>),
    /// nft 侧：恢复到上一版程序；`None` 表示上一版不存在 ⇒ 恢复手段是删表。
    Firewall(Option<String>),
}

// ==================== 执行环境与协调器 ====================

/// 事务的执行环境：数据面句柄 + 各类路径 + 设备能力。
pub struct Plane {
    /// netlink 通道（策略路由读写）。
    pub ops: Arc<dyn RouteOps>,
    /// nft 通道。
    pub fw: FirewallExec,
    /// 配置文件与 sysfs 观察环境。
    pub env: Env,
    /// 真机探测得到的能力（默认值是保守的「未验证为可用」）。
    pub caps: Capabilities,
    /// `/etc/config/smartmwan`。
    pub config_path: PathBuf,
    /// 状态目录（`applied.json` / `applied.nft`）。
    pub state_dir: PathBuf,
    /// 预置项目录（权威值：`rules::presets::PRESET_DIR`）。
    pub presets_dir: PathBuf,
}

/// 事务协调器：持有单事务锁。
pub struct Coordinator {
    plane: Plane,
    /// 单事务锁：同一时刻只允许一个提交者（含并发 RPC 场景）。
    ///
    /// 用异步锁而不是 `std::sync::Mutex`，因为一次提交里有多处 `await`；
    /// 持跨 `await` 的同步锁会死锁或需要 `!Send`，都不如老实排队。
    lock: AsyncMutex<()>,
    seq: AtomicU64,
}

impl Coordinator {
    pub fn new(plane: Plane) -> Coordinator {
        Coordinator {
            plane,
            lock: AsyncMutex::new(()),
            seq: AtomicU64::new(1),
        }
    }

    pub fn plane(&self) -> &Plane {
        &self.plane
    }

    /// 读取磁盘上「已保存但可能尚未应用」的配置。
    ///
    /// 「保存」与「应用」是两件事（任务书第八节）：`config.set` 只写盘，
    /// `config.apply` 才走本层。这个入口让守护进程不必自己拼路径与解析错误。
    /// 返回值第二项是 UCI 解析告警，必须原样显示，不能吞。
    pub fn saved_config(&self) -> Result<(Config, Vec<String>)> {
        let store = config::Store::load(&self.plane.config_path)?;
        Ok((store.config, store.parse_warnings))
    }

    /// 是否已有事务在跑。RPC 侧据此回「稍后重试」，而不是让请求无限排队。
    pub fn is_busy(&self) -> bool {
        self.lock.try_lock().is_err()
    }

    fn next_id(&self) -> String {
        let n = self.seq.fetch_add(1, Ordering::Relaxed);
        format!("T{}-{}-{}", crate::logging::now_ms(), std::process::id(), n)
    }

    /// 事务 id（热替换路径与日志关联用；序号与 `submit` 共用同一计数器，
    /// 因此两次调用不会拿到同一个 id）。
    pub fn next_transaction_id(&self) -> String {
        self.next_id()
    }

    // ---------- 只读：生成计划 ----------

    /// 生成计划（只读，不改内核）。RPC 的 `apply.preview` 走这里。
    pub async fn plan(
        &self,
        cfg: &Config,
        d: &Decision,
        prev: Option<&config::Applied>,
        tx: String,
    ) -> Result<Plan> {
        let mut stages = Vec::new();
        let p = self.build_plan(cfg, d, prev, &mut stages, tx).await?;
        Ok(p)
    }

    /// 计划的核心实现。`stages` 由调用方提供，提交路径把只读阶段也记进同一份回执。
    async fn build_plan(
        &self,
        cfg: &Config,
        d: &Decision,
        prev: Option<&config::Applied>,
        stages: &mut Vec<StageRecord>,
        tx: String,
    ) -> Result<Plan> {
        // ---- 1. 配置校验（纯函数） ----
        let t = Instant::now();
        let report = config::validate::validate(cfg);
        let mut issues = report.issues.clone();
        if !report.is_valid() {
            let first = report
                .errors()
                .first()
                .map(|i| format!("{}：{}", i.path, i.message))
                .unwrap_or_else(|| "未知致命问题".into());
            stages.push(StageRecord::new(
                Stage::Validate,
                t,
                false,
                format!("{} 个致命问题，首个：{}", report.errors().len(), first),
            ));
            return Err(Error::Validate(format!(
                "配置校验未通过（{} 个致命问题）：{first}",
                report.errors().len()
            )));
        }
        stages.push(StageRecord::new(
            Stage::Validate,
            t,
            true,
            format!(
                "通过（schema v{}，{} 条告警）",
                report.schema_version,
                report.warnings().len()
            ),
        ));

        // ---- 2. 观察 + 预置项（阻塞 IO 一律进 spawn_blocking） ----
        if d.gen > 0x0F {
            // 代际只有 4 bit，超了会被静默取模 ⇒ 观测对不上号，明确拒绝。
            return Err(Error::Validate(format!(
                "决策代际 {} 超出 4 bit 上限 15",
                d.gen
            )));
        }
        let slots = scheduler::slot_map(cfg)?;
        let t = Instant::now();
        let cfg2 = cfg.clone();
        let env = self.plane.env.clone();
        let ops = self.plane.ops.clone();
        let pdir = self.plane.presets_dir.clone();
        let observed = tokio::task::spawn_blocking(
            move || -> Result<(Observation, Vec<crate::rules::presets::Preset>)> {
                let ob = crate::system::observe(&cfg2, &env, &*ops)?;
                let ps = presets::load_dir(&pdir)?;
                Ok((ob, ps))
            },
        )
        .await
        .map_err(|e| Error::Netlink(format!("观察任务被丢弃: {e}")))?;
        let (mut ob, presets) = match observed {
            Ok(v) => v,
            Err(e) => {
                stages.push(StageRecord::new(Stage::Plan, t, false, e.to_string()));
                return Err(e);
            }
        };
        // 观察阶段的读失败留在 warnings 里，必须转成可显示的 issue，不能只进日志。
        for w in ob.warnings.clone() {
            issues.push(Issue {
                severity: crate::config::Severity::Warning,
                path: "system.observe".into(),
                message: w,
                hint: None,
            });
        }

        // ---- 3. 规则层 ----
        let compiled = rules::compile(&rules::Input {
            cfg,
            slots: &slots,
            gen: d.gen,
            caps: &self.plane.caps,
            presets: &presets,
            picks: &d.picks,
        })?;
        let CompiledParts {
            specs,
            issues: rule_issues,
            domains,
            pending,
        } = split_compiled(compiled);
        issues.extend(rule_issues);

        // ---- 4. 停用 ⇒ 期望空状态 ----
        let disabled = !cfg.global.enabled;
        if disabled {
            // 回收完全走 `reconcile` 的所有权判定，不在这里自己拼删除命令：
            // 「我们拥有的才删」这条规则只允许有一份实现。
            ob.desired = Desired::default();
            ob.diff = route::reconcile(&ob.rules, &ob.routes, &ob.desired);
        }

        // ---- 5. nft 程序 ----
        let program = if disabled {
            Some(Program {
                text: firewall::teardown_program(),
                summary: "停用：删除 inet smw 表，不装任何规则".into(),
                ..Default::default()
            })
        } else {
            let lines: Vec<firewall::Line> = {
                let mut v: Vec<firewall::Line> = slots
                    .iter()
                    .map(|(n, s)| firewall::Line {
                        name: n.clone(),
                        slot: *s,
                    })
                    .collect();
                v.sort_by_key(|l| l.slot);
                v
            };
            let fams = Observation::families(cfg.global.enable_ipv6);
            let lan = ob.topo.lan_devices(&cfg.global.lan_zones);
            let prot = matchers::split_normalize(&cfg.global.protected_src, "受保护来源")?;
            let byp = matchers::split_normalize(&cfg.global.bypass_dst, "旁路目的")?;
            let inp = firewall::Input {
                algorithm: cfg.global.algorithm,
                buckets: cfg.global.buckets,
                bucket_map: &d.bucket_map,
                gen: d.gen,
                hash_seed: cfg.global.hash_seed,
                conn_sticky: cfg.global.conn_sticky,
                families: &fams,
                lan_ifaces: &lan,
                lines: &lines,
                games: &specs,
                protected_v4: &prot.v4,
                protected_v6: &prot.v6,
                bypass_v4: &byp.v4,
                bypass_v6: &byp.v6,
                caps: &self.plane.caps,
            };
            Some(firewall::build(&inp)?)
        };
        if let Some(p) = &program {
            issues.extend(p.issues.clone());
        }

        // ---- 6. 能力/通道检查（不许把「没法执行」报成「已生效」） ----
        if !disabled && !self.plane.fw.available() {
            issues.push(Issue {
                severity: crate::config::Severity::Error,
                path: "system.nft".into(),
                message: "设备上找不到 nft 可执行文件，标记规则无法下发".into(),
                hint: Some(
                    "确认 firewall4/nftables 已安装；插件不会在没有 nft 的情况下假装工作".into(),
                ),
            });
        }
        if !disabled && !self.plane.caps.nft_exists {
            issues.push(Issue {
                severity: crate::config::Severity::Warning,
                path: "system.nft".into(),
                message: "设备 nft 能力尚未探测或未确认存在，本次按保守默认生成程序".into(),
                hint: Some("先跑一次能力探测（probe_scripts），否则高风险语法不会被使用".into()),
            });
        }

        stages.push(StageRecord::new(
            Stage::Plan,
            t,
            true,
            format!(
                "{} 条标记规则待装，nft 程序 {} 字节，{} 条游戏 spec，{} 条待判定",
                ob.diff.add_rules.len() + ob.diff.del_rules.len(),
                program.as_ref().map(|p| p.text.len()).unwrap_or(0),
                specs.len(),
                pending.len()
            ),
        ));

        let changes = match prev {
            Some(a) => config::diff(&a.config, cfg),
            None => Vec::new(),
        };
        let mut summary = String::new();
        summary.push_str(if disabled {
            "本次为停用：回收本插件全部内核对象\n"
        } else {
            ""
        });
        if !changes.is_empty() {
            summary.push_str(&format!("字段变更 {} 项：\n", changes.len()));
            for c in changes.iter().take(20) {
                summary.push_str(&format!(
                    "· {}：{} → {}{}\n",
                    c.path,
                    c.old,
                    c.new,
                    if c.risky {
                        "（高风险，需二次确认）"
                    } else {
                        ""
                    }
                ));
            }
        }
        summary.push_str(&format!(
            "本次决策：代际 {}，桶 {} 个，时间 {}\n",
            d.gen,
            d.bucket_map.len(),
            d.now_ms
        ));
        summary.push_str(&format!("策略路由：{}\n", ob.diff.summary()));
        if let Some(p) = &program {
            summary.push_str(&format!("nft：{}\n", p.summary));
        }
        if !pending.is_empty() {
            summary.push_str(&format!(
                "等待质量判定（本轮不下发）：{}\n",
                pending.join(", ")
            ));
        }

        Ok(Plan {
            tx,
            disabled,
            ob,
            games: specs,
            program,
            pending,
            domains,
            issues,
            changes,
            summary,
            stages: std::mem::take(stages),
        })
    }

    // ---------- 提交 ----------

    /// 提交一次配置变更。**永不返回 `Result`**，任何结局都是一份 [`Receipt`]。
    pub async fn submit(&self, cfg: &Config, d: &Decision) -> Receipt {
        // 单事务锁：并发的第二个提交者在这里排队，等前一个把内核与快照都收好。
        let _g = self.lock.lock().await;
        let id = self.next_id();
        let mut rec = Receipt::new(id.clone(), self.plane.fw.describe());
        crate::logging::info_ctx(
            "transaction",
            "begin",
            &format!("事务 {id} 开始"),
            &[
                ("transaction", id.clone()),
                ("mode", cfg.global.mode.as_str().to_string()),
                ("algorithm", cfg.global.algorithm.as_str().to_string()),
                ("enabled", cfg.global.enabled.to_string()),
            ],
        );
        if let Err(e) = self.run(cfg, d, &mut rec).await {
            rec.ok = false;
            rec.error = Some(e.to_string());
        }
        crate::logging::log(
            if rec.ok {
                crate::logging::Level::Info
            } else {
                crate::logging::Level::Error
            },
            "transaction",
            if rec.rollback.is_empty() {
                "end"
            } else {
                "end-rolled-back"
            },
            &rec.describe(),
            &[("transaction", id)],
        );
        rec
    }

    async fn run(&self, cfg: &Config, d: &Decision, rec: &mut Receipt) -> Result<()> {
        let prev = config::Store::load_applied(&self.plane.state_dir);
        let prev_nft = read_applied_nft(&self.plane.state_dir);
        let mut stages = std::mem::take(&mut rec.stages);
        let built = self
            .build_plan(cfg, d, prev.as_ref(), &mut stages, rec.id.clone())
            .await;
        rec.stages = stages;
        let plan = match built {
            Ok(p) => {
                // 只读阶段的记录被搬进了 Plan（预览接口也要显示它们），这里取回来。
                rec.stages = p.stages.clone();
                p
            }
            Err(e) => {
                rec.issues = plan_issues_of(&e);
                return Err(e);
            }
        };
        rec.issues = plan.issues.clone();
        rec.pending = plan.pending.clone();
        rec.domains = plan.domains.clone();
        rec.summary = plan.summary.clone();

        // ---- 闸门：有任何阻塞问题就完全不碰内核 ----
        if let Some(msg) = plan.blocked() {
            return Err(Error::Validate(format!("已拒绝提交，未改动内核：{msg}")));
        }
        let text = plan.text();
        let tags = plan.tags();
        // 幂等判据：策略路由差量为空 **且** nft 程序与已提交文本逐字节相同。
        let idempotent = plan.ob.diff.is_empty() && prev_nft.as_deref() == Some(text.as_str());
        rec.changed = !idempotent;

        let mut stack: Vec<UndoAction> = Vec::new();

        // ---- 3. nft 试算（无副作用，必须在任何下发之前） ----
        let t = Instant::now();
        if plan.disabled {
            // 删表不需要试算：表本来就可能不存在，`nft -c` 对它也会报错。
            rec.record(
                Stage::FirewallCheck,
                t,
                true,
                "停用路径：无需试算删除语句".into(),
            );
        } else {
            match self.plane.fw.check(&text).await {
                Ok(()) => rec.record(
                    Stage::FirewallCheck,
                    t,
                    true,
                    format!("试算通过（{} 字节程序）", text.len()),
                ),
                Err(e) => {
                    let msg = e.to_string();
                    rec.record(Stage::FirewallCheck, t, false, msg.clone());
                    // 此时内核一个字都没改，直接返回即可。
                    return Err(Error::Firewall(format!(
                        "nft 试算未通过，已放弃提交（内核未改动）：{msg}"
                    )));
                }
            }
        }

        // ---- 4/5. 策略路由下发 + 复核 ----
        let t = Instant::now();
        let ops = self.plane.ops.clone();
        let diff = plan.ob.diff.clone();
        let desired = plan.ob.desired.clone();
        let route_outcome =
            tokio::task::spawn_blocking(move || -> Result<(Vec<Undo>, Vec<Issue>, String)> {
                let ap = Applier::new(&*ops);
                let summary = diff.summary();
                // 差量为空也要复核：内核可能已被别的组件改动（重启后首次提交正是这种情况）。
                let undo = if diff.is_empty() {
                    Vec::new()
                } else {
                    ap.apply(&diff)?
                };
                let verify = ap.verify(&desired)?;
                Ok((undo, verify, summary))
            })
            .await
            .map_err(|e| Error::Rollback(format!("路由任务被丢弃: {e}")))?;
        let (undo, verify_issues, route_summary) = match route_outcome {
            Ok(v) => v,
            Err(e) => {
                // `Applier::apply` 失败时已自行逆序回滚，这里不再压栈，也不谎报「已回滚」。
                rec.record(Stage::RouteApply, t, false, e.to_string());
                return Err(e);
            }
        };
        rec.record(Stage::RouteApply, t, true, route_summary.clone());
        // 下发与复核在同一次阻塞任务里完成，两条阶段记录因此共用同一计时起点。
        rec.record(
            Stage::RouteVerify,
            t,
            verify_issues
                .iter()
                .all(|i| i.severity != crate::config::Severity::Error),
            if verify_issues.is_empty() {
                "复核通过：期望差量为空".to_string()
            } else {
                verify_issues
                    .iter()
                    .map(|i| i.message.clone())
                    .collect::<Vec<_>>()
                    .join("；")
            },
        );
        if !undo.is_empty() {
            stack.push(UndoAction::Routes(undo));
        }
        if verify_issues
            .iter()
            .any(|i| i.severity == crate::config::Severity::Error)
        {
            self.unwind(&mut stack, rec).await;
            let first = verify_issues
                .iter()
                .find(|i| i.severity == crate::config::Severity::Error)
                .map(|i| i.message.clone())
                .unwrap_or_default();
            return Err(Error::Rollback(format!("策略路由复核未通过：{first}")));
        }

        // ---- 6/7. nft 提交与复核 ----
        // 没有 nft 通道时能走到这里的只有「停用 ⇒ 回收」这一条路（启用状态在计划阶段
        // 就被判为阻塞）。无通道意味着内核里本来就不可能有 `inet smw`，跳过并写明依据，
        // 而不是让 `FirewallExec::apply` 的错误把已经做好的路由回收拖回滚。
        if !self.plane.fw.available() {
            let tn = Instant::now();
            rec.record(
                Stage::FirewallApply,
                tn,
                true,
                "无 nft 通道：内核里不存在 inet smw，跳过提交".into(),
            );
            rec.record(
                Stage::FirewallVerify,
                tn,
                true,
                "无 nft 通道：跳过复核（回执 firewall 字段已标明 absent）".into(),
            );
        } else {
            // ---- 6. nft 提交 ----
            let t = Instant::now();
            if idempotent {
                rec.record(
                    Stage::FirewallApply,
                    t,
                    true,
                    "与已提交程序逐字节相同：跳过提交".into(),
                );
            } else {
                // 回滚基线在提交**之前**入栈：`nft -f` 是原子的，失败即未变，重放上一版无害。
                stack.push(UndoAction::Firewall(prev_nft.clone()));
                match self.plane.fw.apply(&text).await {
                    Ok(()) => rec.record(
                        Stage::FirewallApply,
                        t,
                        true,
                        format!(
                            "提交 {} 字节程序（期望 {} 条规则标签）",
                            text.len(),
                            tags.len()
                        ),
                    ),
                    Err(e) => {
                        let msg = e.to_string();
                        let tolerated = plan.disabled && is_no_such_table(&msg);
                        rec.record(
                            Stage::FirewallApply,
                            t,
                            tolerated,
                            if tolerated {
                                "表本就不存在，无需删除".to_string()
                            } else {
                                msg.clone()
                            },
                        );
                        if !tolerated {
                            self.unwind(&mut stack, rec).await;
                            return Err(Error::Firewall(format!("nft 提交失败：{msg}")));
                        }
                    }
                }
            }

            // ---- 7. nft 复核（幂等命中时同样要做：内核可能已被别的组件改过） ----
            let t = Instant::now();
            match self.verify_firewall(&tags).await {
                Ok(note) => rec.record(Stage::FirewallVerify, t, true, note),
                Err(e) => {
                    let msg = e.to_string();
                    rec.record(Stage::FirewallVerify, t, false, msg.clone());
                    self.unwind(&mut stack, rec).await;
                    return Err(Error::Firewall(format!(
                        "nft 复核未通过（已按逆序回滚）：{msg}"
                    )));
                }
            }
        }

        // ---- 8. 落盘快照 ----
        let t = Instant::now();
        if let Err(e) = self.persist(&text, cfg, &rec.id) {
            // 这里**不回滚**：内核已经是目标状态且已复核通过，因为一个记账失败
            // 把用户正在用的连接拆掉是更坏的选择。但绝不谎报成功。
            rec.record(Stage::Persist, t, false, e.to_string());
            rec.rollback.push(
                "快照未写入：内核已按新配置生效，但下次启动无法用 applied 快照判定幂等（请把下面这条错误原样转给运维）"
                    .to_string(),
            );
            return Err(Error::Config(format!("数据面已生效但快照写入失败：{e}")));
        }
        rec.record(
            Stage::Persist,
            t,
            true,
            format!("已记录快照（事务 {}）", rec.id),
        );
        rec.ok = true;
        Ok(())
    }

    /// 按标签复核 nft 实际规则。停用时期望标签为空 ⇒ 任何 `smw:` 残留都是失败。
    async fn verify_firewall(&self, expected: &[Tag]) -> Result<String> {
        let mut chains: Vec<&'static str> = Vec::new();
        for tg in expected {
            if !chains.contains(&tg.chain) {
                chains.push(tg.chain);
            }
        }
        if chains.is_empty() {
            chains.push(firewall::CHAIN_PREROUTING);
        }
        let mut total = 0usize;
        for c in chains {
            let want: Vec<Tag> = expected.iter().filter(|t| t.chain == c).cloned().collect();
            let actual = self.plane.fw.list(c).await?;
            let rep = firewall::verify(&want, &actual);
            total += rep.rules.len();
            if !rep.ok() {
                return Err(Error::Firewall(format!("链 {c}：{}", rep.describe())));
            }
        }
        Ok(format!(
            "复核通过：链内 {total} 条规则，{want} 个期望标签全部命中",
            want = expected.len()
        ))
    }

    /// 写状态文件：`applied.nft`（幂等依据 + 回滚基线）与 `applied.json`（含事务 id）。
    fn persist(&self, text: &str, cfg: &Config, tx: &str) -> Result<()> {
        std::fs::create_dir_all(&self.plane.state_dir).map_err(|e| {
            Error::Config(format!(
                "创建状态目录 {} 失败: {e}",
                self.plane.state_dir.display()
            ))
        })?;
        config::uci::write_atomic(&applied_nft_path(&self.plane.state_dir), text)?;
        config::Store::store_applied(&self.plane.state_dir, cfg, tx)?;
        Ok(())
    }

    /// 桶轮换热替换后的记账入口（M7 守护进程专用）。
    ///
    /// 热替换只改 `smw:bucket:*` 几条规则的映射值，不走完整事务；但 `applied.nft`
    /// 描述的是「内核里现在是什么」，必须同步更新，否则下次完整提交的幂等判据
    /// （逐字节比对）会把一次无变更提交误判成需要全量重写。
    /// 与 [`Coordinator::persist`] 的区别只有调用场景，写入内容完全相同。
    pub fn record_program(&self, text: &str, cfg: &Config, tx: &str) -> Result<()> {
        self.persist(text, cfg, tx)
    }

    /// 逆序回滚。每个失败都记进回执并写日志，绝不静默。
    async fn unwind(&self, stack: &mut Vec<UndoAction>, rec: &mut Receipt) {
        while let Some(a) = stack.pop() {
            match a {
                UndoAction::Routes(mut undo) => {
                    let ops = self.plane.ops.clone();
                    let n = undo.len();
                    let res = tokio::task::spawn_blocking(move || {
                        let mut leftovers = Vec::new();
                        let ap = Applier::new(&*ops);
                        ap.rollback(&mut undo, &mut leftovers);
                        leftovers
                    })
                    .await;
                    match res {
                        Ok(leftovers) if leftovers.is_empty() => {
                            rec.rollback.push(format!("路由：已逆序撤销 {n} 步"));
                        }
                        Ok(leftovers) => {
                            for l in leftovers {
                                crate::logging::error_ctx(
                                    "transaction",
                                    "rollback",
                                    Error::Rollback(l.clone()),
                                    &[("transaction", rec.id.clone())],
                                );
                                rec.rollback.push(format!("路由回滚遗留：{l}"));
                            }
                        }
                        Err(e) => rec.rollback.push(format!("路由回滚任务被丢弃: {e}")),
                    }
                }
                UndoAction::Firewall(prev) => {
                    let (text, how) = match &prev {
                        Some(p) => (p.clone(), "重放上一版程序"),
                        None => (firewall::teardown_program(), "删除 inet smw 表"),
                    };
                    let t = Instant::now();
                    match self.plane.fw.apply(&text).await {
                        Ok(()) => {
                            rec.record(Stage::FirewallApply, t, true, format!("回滚：{how}"));
                            rec.rollback.push(format!("nft：已{how}"));
                        }
                        Err(e) => {
                            let msg = e.to_string();
                            crate::logging::error_ctx(
                                "transaction",
                                "rollback",
                                Error::Firewall(format!("nft 回滚（{how}）失败：{msg}")),
                                &[("transaction", rec.id.clone())],
                            );
                            // 表不存在时「删表回滚」失败是可以接受的：目标状态本就是无表。
                            if prev.is_none() && is_no_such_table(&msg) {
                                rec.rollback.push("nft：无表可回滚（保持无表）".to_string());
                            } else {
                                rec.rollback.push(format!(
                                    "nft 回滚失败（{how}）：{msg}，内核现状需人工确认"
                                ));
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------- 启动回收 ----------

    /// 启动时回收残留：删掉**属于本插件**的 `ip rule`、路由表条目与 `inet smw` 表。
    ///
    /// 所有权判定只有一份：`RuleEntry::is_ours()`（优先级区间 + 掩码 + 槽位 + 表号四条件）、
    /// `RouteEntry::in_our_table()` 加 `protocol == OUR_RTPROT`、以及表名 `inet smw`。
    /// 别人的对象一律保留，只报告 —— 误删别人的规则比留下我们的垃圾严重得多。
    pub async fn reclaim(&self) -> Result<ReclaimReport> {
        let _g = self.lock.lock().await;
        let mut rep = ReclaimReport::default();
        let ops = self.plane.ops.clone();
        let our_tables: Vec<u32> = (1..=crate::marks::MAX_WANS)
            .map(crate::marks::table_of)
            .collect();
        let found = tokio::task::spawn_blocking(move || -> Result<ReclaimNet> {
            let mut rules = Vec::new();
            let mut routes = Vec::new();
            let mut notes: Vec<String> = Vec::new();
            for f in [Family::V4, Family::V6] {
                match ops.dump_rules(f) {
                    Ok(v) => rules.extend(v),
                    // 看不到就无法回收，必须报告；但另一族的残留仍要处理。
                    Err(e) => notes.push(format!("{} 规则 dump 失败: {e}", f.as_str())),
                }
                for t in &our_tables {
                    match ops.dump_routes(f, *t) {
                        Ok(v) => routes.extend(v),
                        Err(e) => notes.push(format!("{} 表 {t} dump 失败: {e}", f.as_str())),
                    }
                }
            }
            let diff = route::reconcile(&rules, &routes, &Desired::default());
            let foreign: Vec<String> = diff
                .conflicts
                .iter()
                .map(|i| format!("{}：{}", i.path, i.message))
                .collect();
            let (nr, nt) = (diff.del_rules.len(), diff.del_routes.len());
            if !diff.is_empty() {
                Applier::new(&*ops).apply(&diff)?;
            }
            Ok(ReclaimNet {
                rules: nr,
                routes: nt,
                foreign,
                notes,
            })
        })
        .await
        .map_err(|e| Error::Rollback(format!("回收任务被丢弃: {e}")))??;
        rep.rules_removed = found.rules;
        rep.routes_removed = found.routes;
        rep.foreign = found.foreign;
        rep.notes = found.notes;

        // nft 侧：只删自己的表。没有 nft 通道时明确报告，不假装清理过。
        match &self.plane.fw {
            FirewallExec::Absent => rep
                .notes
                .push("无 nft 通道：未清理 inet smw 表".to_string()),
            exec => {
                let text = firewall::teardown_program();
                match exec.apply(&text).await {
                    Ok(()) => {
                        rep.nft_dropped = true;
                        rep.notes.push("已删除 inet smw 表".to_string());
                    }
                    Err(e) if is_no_such_table(&e.to_string()) => {
                        rep.nft_dropped = true;
                        rep.notes
                            .push("inet smw 表本就不存在（视为已清理）".to_string());
                    }
                    Err(e) => rep.notes.push(format!("删除 inet smw 表失败：{e}")),
                }
            }
        }
        crate::logging::info_ctx(
            "transaction",
            "reclaim",
            &format!(
                "回收残留：规则 {} 条、路由 {} 条、nft 表 {}",
                rep.rules_removed,
                rep.routes_removed,
                if rep.nft_dropped {
                    "已删"
                } else {
                    "未处理"
                }
            ),
            &[],
        );
        Ok(rep)
    }
}

/// `rules::Compiled` 的具名字段搬运（避免解构时漏字段 —— 编译期会检查）。
struct CompiledParts {
    specs: Vec<GameSpec>,
    issues: Vec<Issue>,
    domains: Vec<String>,
    pending: Vec<String>,
}

fn split_compiled(c: rules::Compiled) -> CompiledParts {
    CompiledParts {
        specs: c.specs,
        issues: c.issues,
        domains: c.domains,
        pending: c.pending,
    }
}

/// 内部错误也要能变成可显示问题。计划阶段的失败一律是 Error 级：
/// 它意味着「我们连该下发什么都没算清楚」，绝不能降级成告警后继续提交。
fn plan_issues_of(e: &Error) -> Vec<Issue> {
    vec![Issue {
        severity: crate::config::Severity::Error,
        path: "transaction.plan".into(),
        message: e.to_string(),
        hint: Some("修正配置或能力探测结果后重试；本次未改动内核".into()),
    }]
}

fn read_applied_nft(state_dir: &Path) -> Option<String> {
    let p = applied_nft_path(state_dir);
    match std::fs::read_to_string(&p) {
        Ok(t) => Some(t),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            crate::logging::debug_ctx(
                "transaction",
                "state",
                &format!("无 {APPLIED_NFT}，本次必须实际下发"),
                &[("path", p.display().to_string())],
            );
            None
        }
        Err(e) => {
            crate::logging::warn_ctx(
                "transaction",
                "state",
                &format!("读取 {} 失败: {e}", p.display()),
                &[],
            );
            None
        }
    }
}

/// 回收过程里阻塞任务的产物（`Send`，可从 `spawn_blocking` 取出）。
struct ReclaimNet {
    rules: usize,
    routes: usize,
    foreign: Vec<String>,
    notes: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::schema::{GameRule, GameSelection, WanConfig};
    use crate::marks;
    use crate::system::interface::SysFs;
    use crate::system::netlink::{
        FakeNetlink, RouteEntry, RuleEntry, FR_ACT_TO_TBL, RTN_LOCAL, RTN_UNICAST, RTPROT_BOOT,
        RTPROT_KERNEL, RTPROT_STATIC, RT_SCOPE_HOST, RT_SCOPE_LINK, RT_TABLE_LOCAL, RT_TABLE_MAIN,
    };
    use std::net::IpAddr;
    use std::time::Duration;

    // ==================== 夹具 ====================

    /// 事务层的可复现环境：临时 `/etc`、临时 sysfs、内存 netlink 替身、nft 替身。
    struct Fixture {
        /// 只在测试结束时负责删除临时目录；不读它，但不能改名也不能删。
        dir: tempfile::TempDir,
        fake: Arc<FakeNetlink>,
        sim: Arc<Sim>,
    }

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    /// 测试夹具路由条目（位置参数与内核转储字段一一对应，见 `system` 层同名夹具）。
    #[allow(clippy::too_many_arguments)]
    fn route(
        table: u32,
        dst: Option<IpAddr>,
        len: u8,
        gw: Option<IpAddr>,
        oif: u32,
        kind: u8,
        scope: u8,
        protocol: u8,
    ) -> RouteEntry {
        RouteEntry {
            family: Family::V4,
            table,
            dst_len: len,
            dst,
            gateway: gw,
            oif: Some(oif),
            prefsrc: None,
            priority: 0,
            protocol,
            scope,
            kind,
        }
    }

    /// 内核现状：main 表两条默认路由（wan 有网关、5G 是点对点）+ LAN 直连，
    /// local 表本机地址。与 `system` 层同名夹具一致，只是不重复带 family 参数。
    fn kernel_state() -> Vec<RouteEntry> {
        vec![
            route(
                RT_TABLE_MAIN as u32,
                None,
                0,
                Some(ip("10.0.0.1")),
                4,
                RTN_UNICAST,
                RT_SCOPE_LINK,
                RTPROT_KERNEL,
            ),
            route(
                RT_TABLE_MAIN as u32,
                None,
                0,
                None,
                7,
                RTN_UNICAST,
                RT_SCOPE_LINK,
                RTPROT_KERNEL,
            ),
            route(
                RT_TABLE_MAIN as u32,
                Some(ip("192.168.1.0")),
                24,
                None,
                6,
                RTN_UNICAST,
                RT_SCOPE_LINK,
                RTPROT_KERNEL,
            ),
            route(
                RT_TABLE_LOCAL as u32,
                Some(ip("192.168.1.1")),
                32,
                None,
                6,
                RTN_LOCAL,
                RT_SCOPE_HOST,
                RTPROT_KERNEL,
            ),
        ]
    }

    impl Fixture {
        fn new(extra_rules: Vec<RuleEntry>, extra_routes: Vec<RouteEntry>) -> Fixture {
            let dir = tempfile::TempDir::new().unwrap();
            let etc = dir.path().join("etc");
            std::fs::create_dir_all(etc.join("config")).unwrap();
            std::fs::write(
                etc.join("config/network"),
                "config interface 'lan'\n    option device 'br-lan'\n    option proto 'static'\n    option ipaddr '192.168.1.1'\n\n\
                 config interface 'wan'\n    option device 'eth1'\n    option proto 'dhcp'\n\n\
                 config interface 'wan_5g'\n    option device 'wwan0'\n    option proto 'dhcp'\n",
            )
            .unwrap();
            std::fs::write(
                etc.join("config/firewall"),
                "config zone\n    option name 'lan'\n    list network 'lan'\n\n\
                 config zone\n    option name 'wan'\n    list network 'wan'\n    list network 'wan_5g'\n    option masq '1'\n",
            )
            .unwrap();
            let net = dir.path().join("net");
            for (n, idx) in [("br-lan", "6"), ("eth1", "4"), ("wwan0", "7")] {
                let d = net.join(n);
                std::fs::create_dir_all(d.join("statistics")).unwrap();
                std::fs::write(d.join("ifindex"), format!("{idx}\n")).unwrap();
                std::fs::write(d.join("carrier"), "1\n").unwrap();
                std::fs::write(d.join("operstate"), "up\n").unwrap();
                std::fs::write(d.join("statistics/rx_bytes"), "10\n").unwrap();
                std::fs::write(d.join("statistics/tx_bytes"), "20\n").unwrap();
            }
            let mut routes = kernel_state();
            routes.extend(extra_routes);
            let mut rules: Vec<RuleEntry> = Vec::new();
            rules.extend(extra_rules);
            Fixture {
                fake: Arc::new(FakeNetlink::with_state(rules, routes, vec![])),
                sim: Sim::new(),
                dir,
            }
        }

        fn plane_at(&self, fw: FirewallExec, state_dir: PathBuf) -> Plane {
            Plane {
                ops: self.fake.clone(),
                fw,
                env: Env {
                    etc_dir: self.dir.path().join("etc"),
                    sysfs: SysFs::new(self.dir.path().join("net")),
                },
                caps: Capabilities::default(),
                config_path: self.dir.path().join("etc/config/smartmwan"),
                presets_dir: self.dir.path().join("presets"),
                state_dir,
            }
        }

        fn coordinator(&self) -> Coordinator {
            Coordinator::new(self.plane(FirewallExec::Sim(self.sim.clone())))
        }

        fn plane(&self, fw: FirewallExec) -> Plane {
            self.plane_at(fw, self.dir.path().join("state"))
        }

        fn state_dir(&self) -> PathBuf {
            self.dir.path().join("state")
        }

        /// 内核里属于本插件的 `ip rule` 条数。
        fn our_rules(&self) -> usize {
            self.fake.rule_list().iter().filter(|r| r.is_ours()).count()
        }

        /// 内核里落在本插件表号区间内的路由条数。
        fn our_routes(&self) -> usize {
            self.fake
                .route_list()
                .iter()
                .filter(|r| r.in_our_table())
                .count()
        }

        /// 替身最后一次提交的程序。
        fn last_program(&self) -> String {
            self.sim.programs().last().cloned().unwrap_or_default()
        }
    }

    fn wan(name: &str) -> WanConfig {
        WanConfig {
            name: name.into(),
            enabled: true,
            ..Default::default()
        }
    }

    fn cfg(enabled: bool) -> Config {
        let mut c = Config::default();
        c.global.enabled = enabled;
        c.global.enable_ipv6 = false;
        c.global.lan_zones = vec!["lan".into()];
        c.wans = vec![wan("wan"), wan("wan_5g")];
        c
    }

    /// 决策快照：桶在两条线路间平分，够用且确定。
    fn decision(cfg: &Config) -> Decision {
        let n = cfg.global.buckets as usize;
        Decision {
            bucket_map: (0..n).map(|i| if i % 2 == 0 { 1 } else { 2 }).collect(),
            picks: BTreeMap::new(),
            gen: 3,
            now_ms: 1_700_000_000_000,
        }
    }

    fn stage_order(rec: &Receipt) -> Vec<&'static str> {
        rec.stages.iter().map(|s| s.stage.as_str()).collect()
    }

    // ==================== 替身自身 ====================

    #[test]
    fn comments_of_chain_scopes_by_chain_block() {
        let text = r#"
            table inet smw {
                chain prerouting {
                    type filter hook prerouting priority -150; policy accept;
                    meta mark set jhash ip saddr . ip daddr mod 64 map { 0 : 0x05000001 } comment "smw:bucket:v4"
                    ip daddr @smw_g_fps_dst4 meta mark set 0x05000001 comment "smw:game:fps"
                }
                chain output {
                    type route hook output priority -150; policy accept;
                    ct mark 0x05000000 meta mark set ct mark comment "smw:inherit"
                }
            }
        "#;
        assert_eq!(
            comments_of_chain(text, "prerouting"),
            vec!["smw:bucket:v4".to_string(), "smw:game:fps".to_string()]
        );
        assert_eq!(
            comments_of_chain(text, "output"),
            vec!["smw:inherit".to_string()]
        );
        assert!(comments_of_chain(text, "nope").is_empty());
    }

    #[test]
    fn is_no_such_table_only_matches_the_known_phrases() {
        assert!(is_no_such_table(
            "Error: no such file or directory: cannot delete table"
        ));
        assert!(is_no_such_table("cannot find table smw"));
        assert!(!is_no_such_table(
            "Error: syntax error: unexpected end of file"
        ));
    }

    #[test]
    fn stage_names_are_stable_for_logs_and_rpc() {
        assert_eq!(Stage::FirewallCheck.as_str(), "firewall_check");
        assert_eq!(Stage::RouteVerify.label(), "复核策略路由");
    }

    #[test]
    fn receipt_describe_reports_rollback_separately_from_not_committed() {
        let mut r = Receipt::new("T1".into(), "sim".into());
        assert!(r.describe().contains("未提交"));
        r.rollback.push("路由：已逆序撤销 2 步".into());
        assert!(r.describe().contains("失败并已回滚"));
        r.ok = true;
        r.changed = false;
        assert!(r.describe().contains("幂等"));
    }

    // ==================== 成功路径与顺序 ====================

    #[tokio::test]
    async fn submit_follows_the_fixed_stage_order_and_persists() {
        let f = Fixture::new(vec![], vec![]);
        let co = f.coordinator();
        let cfg = cfg(true);
        let rec = co.submit(&cfg, &decision(&cfg)).await;
        assert!(rec.ok, "{}", rec.describe());
        assert!(rec.changed);
        assert_eq!(
            stage_order(&rec),
            vec![
                "validate",
                "plan",
                "firewall_check",
                "route_apply",
                "route_verify",
                "firewall_apply",
                "firewall_verify",
                "persist"
            ]
        );
        // 两条线路两条标记规则，且真的进了（替身）内核
        assert_eq!(f.our_rules(), 2);
        assert!(f.our_routes() > 0);
        // nft 侧：先试算再提交，各一次
        assert_eq!(
            f.sim.calls(),
            vec!["check".to_string(), "apply".to_string()]
        );
        assert!(
            f.last_program().contains("smw:bucket:v4"),
            "{}",
            f.last_program()
        );
        // 快照必须带上事务 id，且 applied.nft 与实际提交内容逐字节一致
        let applied = config::Store::load_applied(&f.state_dir()).expect("applied.json");
        assert_eq!(applied.transaction, rec.id);
        assert_eq!(
            std::fs::read_to_string(applied_nft_path(&f.state_dir())).unwrap(),
            f.last_program()
        );
        assert!(rec.summary.contains("策略路由："));
        assert!(rec.summary.contains("代际 3"));
    }

    #[tokio::test]
    async fn second_submit_of_same_config_is_a_no_op_but_still_verified() {
        let f = Fixture::new(vec![], vec![]);
        let co = f.coordinator();
        let cfg = cfg(true);
        let first = co.submit(&cfg, &decision(&cfg)).await;
        assert!(first.ok && first.changed);
        let second = co.submit(&cfg, &decision(&cfg)).await;
        assert!(second.ok, "{}", second.describe());
        assert!(
            !second.changed,
            "第二次必须判定为无变更：{}",
            second.summary
        );
        // 幂等命中 ⇒ 不重复提交 nft，也不重复装规则
        assert_eq!(
            f.sim.calls(),
            vec![
                "check".to_string(),
                "apply".to_string(),
                "check".to_string()
            ]
        );
        assert_eq!(f.our_rules(), 2, "规则不能被重复安装");
        assert!(stage_order(&second).contains(&"firewall_verify"));
    }

    // ==================== 失败路径：不得留下半套状态 ====================

    #[tokio::test]
    async fn check_failure_leaves_kernel_and_state_files_untouched() {
        let f = Fixture::new(vec![], vec![]);
        f.sim.fail_check(Some("syntax error at 3:32".into()));
        let co = f.coordinator();
        let cfg = cfg(true);
        let rec = co.submit(&cfg, &decision(&cfg)).await;
        assert!(!rec.ok);
        assert!(
            rec.error.as_deref().unwrap_or_default().contains("试算"),
            "{}",
            rec.describe()
        );
        assert_eq!(f.our_rules(), 0, "试算失败不能动内核");
        assert_eq!(f.sim.calls(), vec!["check".to_string()]);
        assert!(config::Store::load_applied(&f.state_dir()).is_none());
        assert!(!applied_nft_path(&f.state_dir()).exists());
        // 没回滚发生过，就不许写「已回滚」
        assert!(rec.rollback.is_empty(), "{:?}", rec.rollback);
    }

    #[tokio::test]
    async fn route_apply_failure_never_reaches_nft_apply() {
        let f = Fixture::new(vec![], vec![]);
        // 第一条 add_route 失败：Applier 会自行逆序回滚已成功部分
        f.fake
            .fail_routes(vec![Some("表满：No buffer space available".into())]);
        let co = f.coordinator();
        let cfg = cfg(true);
        let rec = co.submit(&cfg, &decision(&cfg)).await;
        assert!(!rec.ok, "{}", rec.describe());
        assert!(
            rec.error
                .as_deref()
                .unwrap_or_default()
                .contains("安装路由失败"),
            "{:?}",
            rec.error
        );
        // nft 只做了试算，绝不提交
        assert_eq!(f.sim.calls(), vec!["check".to_string()]);
        assert_eq!(f.our_rules(), 0);
        assert!(config::Store::load_applied(&f.state_dir()).is_none());
    }

    #[tokio::test]
    async fn nft_apply_failure_rolls_back_routes_and_reports_rollback_failure() {
        let f = Fixture::new(vec![], vec![]);
        f.sim
            .fail_apply(Some("Netlink: Operation not permitted".into()));
        let co = f.coordinator();
        let cfg = cfg(true);
        let rec = co.submit(&cfg, &decision(&cfg)).await;
        assert!(!rec.ok);
        assert!(
            rec.error
                .as_deref()
                .unwrap_or_default()
                .contains("nft 提交失败"),
            "{:?}",
            rec.error
        );
    }

    #[tokio::test]
    async fn nft_verify_failure_rolls_back_nft_then_routes_in_reverse_order() {
        let f = Fixture::new(vec![], vec![]);
        // apply 返回成功但链里看不到规则：复核必须失败并逆序回滚
        f.sim.hide_applied_rules(true);
        let co = f.coordinator();
        let cfg = cfg(true);
        let rec = co.submit(&cfg, &decision(&cfg)).await;
        assert!(!rec.ok, "{}", rec.describe());
        assert!(
            rec.error
                .as_deref()
                .unwrap_or_default()
                .contains("复核未通过"),
            "{:?}",
            rec.error
        );
        // 回滚顺序：先 nft（此时无上一版 ⇒ 删表），再路由
        assert!(
            rec.rollback
                .iter()
                .any(|s| s.contains("nft：已删除 inet smw 表")),
            "{:?}",
            rec.rollback
        );
        assert!(
            rec.rollback.iter().any(|s| s.contains("路由：已逆序撤销")),
            "{:?}",
            rec.rollback
        );
        let nft_at = rec
            .rollback
            .iter()
            .position(|s| s.contains("nft："))
            .unwrap();
        let route_at = rec
            .rollback
            .iter()
            .position(|s| s.contains("路由：已逆序撤销"))
            .unwrap();
        assert!(nft_at < route_at, "回滚必须逆序：{:?}", rec.rollback);
        assert_eq!(f.our_rules(), 0, "回滚后不能留规则");
        // 复核失败 ⇒ 绝不写快照（否则下次启动会以为这套状态是好的）
        assert!(config::Store::load_applied(&f.state_dir()).is_none());
    }

    #[tokio::test]
    async fn foreign_priority_conflict_blocks_before_any_side_effect() {
        // 别人占用了本插件给槽位 1 保留的优先级
        let foreign = RuleEntry {
            family: Family::V4,
            priority: route::prio_for_slot(1),
            table: 200,
            action: FR_ACT_TO_TBL,
            fwmark: None,
            fwmask: None,
            iifname: Some("br-lan".into()),
            src: None,
            dst: None,
            protocol: Some(RTPROT_BOOT),
            flags: 0,
        };
        let f = Fixture::new(vec![foreign], vec![]);
        let co = f.coordinator();
        let cfg = cfg(true);
        let rec = co.submit(&cfg, &decision(&cfg)).await;
        assert!(!rec.ok, "{}", rec.describe());
        assert!(rec.error.unwrap().contains("已拒绝提交"));
        // 计划阶段就被拦下：nft 一次都没调，内核一条都没改
        assert!(f.sim.calls().is_empty());
        assert_eq!(f.fake.rule_list().len(), 1, "只剩那条别人的规则");
    }

    #[tokio::test]
    async fn missing_nft_blocks_enabled_submit_but_allows_disable() {
        let f = Fixture::new(vec![], vec![]);
        let co = Coordinator::new(f.plane(FirewallExec::Absent));
        let on = cfg(true);
        let rec = co.submit(&on, &decision(&on)).await;
        assert!(!rec.ok, "{}", rec.describe());
        assert!(
            rec.error.as_deref().unwrap_or_default().contains("nft"),
            "{:?}",
            rec.error
        );
        assert_eq!(
            f.our_rules(),
            0,
            "没有 nft 就不能假装工作，也不能只装半套路由"
        );

        // 停用路径没有 nft 也能走完：内核里本来就没有 inet smw，跳过并写明依据
        let off = cfg(false);
        let rec2 = co.submit(&off, &decision(&off)).await;
        assert!(rec2.ok, "{}", rec2.describe());
        assert!(rec2.firewall.contains("absent"), "{}", rec2.firewall);
        assert!(rec2
            .stages
            .iter()
            .any(|s| s.stage == Stage::FirewallApply && s.note.contains("跳过提交")));
    }

    #[tokio::test]
    async fn snapshot_write_failure_is_not_reported_as_success() {
        // 状态目录位置放一个普通文件 ⇒ create_dir_all 必然失败
        let blocker = {
            let p = std::path::PathBuf::from("/tmp/smartmwan-tx-blocker");
            std::fs::create_dir_all(p.parent().unwrap()).ok();
            std::fs::write(&p, b"x").unwrap();
            p
        };
        let f = Fixture::new(vec![], vec![]);
        let co = Coordinator::new(f.plane_at(FirewallExec::Sim(f.sim.clone()), blocker.clone()));
        let cfg = cfg(true);
        let rec = co.submit(&cfg, &decision(&cfg)).await;
        assert!(!rec.ok, "记账失败绝不能被说成成功");
        assert!(
            rec.error.as_deref().unwrap_or_default().contains("快照"),
            "{:?}",
            rec.error
        );
        // 数据面已经生效且已复核 ⇒ 有意不回滚，回执必须把这件事讲清楚
        assert_eq!(f.our_rules(), 2);
        assert_eq!(
            f.sim.calls(),
            vec!["check".to_string(), "apply".to_string()]
        );
        assert!(rec.rollback.iter().any(|s| s.contains("快照未写入")));
        std::fs::remove_file(&blocker).ok();
    }

    // ==================== 装配证据：config → rules → firewall ====================

    #[tokio::test]
    async fn game_rule_from_config_reaches_the_nft_program() {
        let mut c = cfg(true);
        c.games = vec![GameRule {
            name: "fps".into(),
            targets: vec!["198.18.0.0/16".into()],
            selection: GameSelection::Pin,
            pin_wan: "wan".into(),
            ..Default::default()
        }];
        let f = Fixture::new(vec![], vec![]);
        let co = f.coordinator();
        let rec = co.submit(&c, &decision(&c)).await;
        assert!(rec.ok, "{}", rec.describe());
        let prog = f.last_program();
        // 规则层产物真的变成了 nft 文本里的对象与匹配项（不只是「集合被声明过」）
        assert!(prog.contains("smw_g_fps_dst4"), "{prog}");
        assert!(prog.contains("ip daddr @smw_g_fps_dst4"), "{prog}");
        assert!(prog.contains("smw:game:fps"), "{prog}");
        assert!(rec.pending.is_empty());
    }

    #[tokio::test]
    async fn best_without_a_verdict_is_pending_not_fabricated() {
        let mut c = cfg(true);
        c.games = vec![GameRule {
            name: "fps".into(),
            targets: vec!["198.18.0.0/16".into()],
            selection: GameSelection::Best,
            ..Default::default()
        }];
        // decision() 的 picks 为空 ⇒ 本轮还没有择优结论
        let f = Fixture::new(vec![], vec![]);
        let co = f.coordinator();
        let rec = co.submit(&c, &decision(&c)).await;
        assert!(rec.ok, "{}", rec.describe());
        assert_eq!(rec.pending, vec!["fps".to_string()]);
        let prog = f.last_program();
        assert!(
            !prog.contains("smw:game:fps"),
            "没有结论就不能编造规则：{prog}"
        );
        assert!(!prog.contains("smw_g_fps_dst4"), "{prog}");
    }

    // ==================== 回收与幂等启动 ====================

    #[tokio::test]
    async fn disabling_config_removes_every_object_we_own() {
        let f = Fixture::new(vec![], vec![]);
        let co = f.coordinator();
        let on = cfg(true);
        assert!(co.submit(&on, &decision(&on)).await.ok);
        assert!(f.our_rules() > 0 && f.our_routes() > 0);

        let off = cfg(false);
        let rec = co.submit(&off, &decision(&off)).await;
        assert!(rec.ok, "{}", rec.describe());
        assert_eq!(f.our_rules(), 0, "停用后不能留下我们的规则");
        assert_eq!(f.our_routes(), 0, "停用后不能留下我们表里的路由");
        assert_eq!(f.last_program(), firewall::teardown_program());
        assert_eq!(
            std::fs::read_to_string(applied_nft_path(&f.state_dir())).unwrap(),
            firewall::teardown_program()
        );
    }

    #[tokio::test]
    async fn reclaim_deletes_ours_and_keeps_everything_foreign() {
        // 别人的规则：优先级不在保留区间、也没有我们的掩码
        let foreign_rule = RuleEntry {
            family: Family::V4,
            priority: 900,
            table: 100,
            action: FR_ACT_TO_TBL,
            fwmark: None,
            fwmask: None,
            iifname: Some("tun0".into()),
            src: None,
            dst: None,
            protocol: Some(RTPROT_STATIC),
            flags: 0,
        };
        // 别人塞进我们表号区间的路由（协议不是 OUR_RTPROT）。
        // 用独立前缀而不是默认路由：默认路由会被本插件自己的表内默认路由
        // 按 (表号, 前缀) 覆盖掉（`ip route replace` 语义），那样就测不出「保留别人的」了。
        let foreign_route = route(
            marks::table_of(1),
            Some(ip("172.16.0.0")),
            24,
            None,
            9,
            RTN_UNICAST,
            RT_SCOPE_LINK,
            RTPROT_KERNEL,
        );
        let f = Fixture::new(vec![foreign_rule], vec![foreign_route]);
        let co = f.coordinator();
        let on = cfg(true);
        assert!(co.submit(&on, &decision(&on)).await.ok, "先造出残留");
        assert_eq!(f.our_rules(), 2);

        let rep = co.reclaim().await.expect("回收应成功");
        assert_eq!(rep.rules_removed, 2, "{rep:?}");
        assert!(rep.routes_removed > 0, "{rep:?}");
        assert!(rep.nft_dropped);
        assert!(
            rep.foreign.iter().any(|s| s.contains("表 101")),
            "{:?}",
            rep.foreign
        );
        // 只删自己的：别人的规则与别人的路由都还在
        assert_eq!(f.fake.rule_list().len(), 1);
        assert_eq!(f.fake.rule_list()[0].priority, 900);
        assert!(f
            .fake
            .route_list()
            .iter()
            .any(|r| r.table == marks::table_of(1) && r.protocol == RTPROT_KERNEL));
    }

    #[tokio::test]
    async fn reclaim_tolerates_a_fresh_box_with_nothing_to_clean() {
        let f = Fixture::new(vec![], vec![]);
        let co = f.coordinator();
        let rep = co.reclaim().await.unwrap();
        assert_eq!(rep.rules_removed, 0);
        assert_eq!(rep.routes_removed, 0);
        assert!(rep.foreign.is_empty(), "{:?}", rep.foreign);
        assert!(rep.nft_dropped, "替身里没有表 ⇒ 删表成功");
    }

    // ==================== 单事务锁 ====================

    #[tokio::test]
    async fn second_committer_waits_for_the_first_to_finish() {
        let f = Fixture::new(vec![], vec![]);
        let co = Arc::new(f.coordinator());
        let cfg = cfg(true);
        // 手动持锁模拟「另一个人正在提交」
        let guard = co.lock.lock().await;
        assert!(co.is_busy(), "持锁期间必须报告忙");
        let co2 = co.clone();
        let cfg2 = cfg.clone();
        let mut h = tokio::spawn(async move { co2.submit(&cfg2, &decision(&cfg2)).await });
        // 锁没放，这个提交就必须卡在入口，而不是插进内核操作中间
        assert!(
            tokio::time::timeout(Duration::from_millis(80), &mut h)
                .await
                .is_err(),
            "第二个提交者越过了单事务锁"
        );
        drop(guard);
        let rec = h.await.unwrap();
        assert!(rec.ok, "{}", rec.describe());
        assert_eq!(f.our_rules(), 2, "串行化后仍只能有一套对象");
    }

    #[tokio::test]
    async fn transaction_ids_are_unique_and_recorded_in_the_snapshot() {
        let f = Fixture::new(vec![], vec![]);
        let co = f.coordinator();
        let cfg = cfg(true);
        let a = co.submit(&cfg, &decision(&cfg)).await;
        assert!(a.ok);
        // 改一个字段再来一次：必须是新事务 id，且快照里记的是最新那个
        let mut cfg2 = cfg.clone();
        cfg2.global.hash_seed = 0x1234_5678;
        let b = co.submit(&cfg2, &decision(&cfg2)).await;
        assert!(b.ok, "{}", b.describe());
        assert_ne!(a.id, b.id);
        assert!(b.id.starts_with('T'), "{}", b.id);
        let applied = config::Store::load_applied(&f.state_dir()).unwrap();
        assert_eq!(applied.transaction, b.id);
        assert!(b.summary.contains("字段变更"), "{:?}", b.summary);
    }

    // ==================== 保存 / 应用分离的入口 ====================

    #[tokio::test]
    async fn saved_config_reads_the_file_on_disk() {
        let f = Fixture::new(vec![], vec![]);
        let co = f.coordinator();
        let path = co.plane().config_path.clone();
        // 先走「保存」这条路：写盘但不应用
        let mut store = config::Store::load(&path).unwrap();
        let mut want = store.config.clone();
        want.global.enabled = true;
        want.wans = vec![wan("wan")];
        store.save(&want).unwrap();
        let (got, warnings) = co.saved_config().unwrap();
        assert!(got.global.enabled);
        assert_eq!(got.wans.len(), 1);
        assert!(warnings.is_empty(), "{warnings:?}");
    }
}

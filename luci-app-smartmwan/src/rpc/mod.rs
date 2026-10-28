//! RPC 层（M7）：Unix socket + JSON，LuCI 视图（经 rpcd ucode 桥）的唯一入口。
//!
//! # 协议
//!
//! 传输是 Unix 域套接字（路径取 `global.rpc_socket`），帧格式为 **4 字节大端长度前缀 +
//! JSON 体**，一请求一响应，响应体即统一信封：
//!
//! ```json
//! { "ok": true,  "data": { … }, "error": null, "timestamp": 1730000000, "protocol": 1 }
//! { "ok": false, "data": null,
//!   "error": { "code": "validate", "message": "…", "details": [ … ] },
//!   "timestamp": 1730000000, "protocol": 1 }
//! ```
//!
//! `code` 取 [`crate::Error::code()`] 的 12 个稳定值之一，前端据此区分「可重试」与
//! 「需用户修正」。`protocol` 不符时前端应拒绝渲染，而不是猜字段含义。
//!
//! # 鉴权与审计
//!
//! 每条连接接受后立刻取 `SO_PEERCRED`，uid 不在白名单（root / wwwdata）一律
//! `permission` 错误，**不进入方法分发**。所有写方法（以及有网络副作用的 `probeNow`）
//! 记录调用者 uid/pid、参数摘要（脱敏）、事务 id、结果与耗时。
//!
//! # 状态归属（最重要的一条）
//!
//! 本层**不保存任何业务状态**：健康快照、观测结果、最近回执都由守护进程的主循环
//! 写进 [`AppState`] 的各个槽位，RPC 只读。需要改变状态的写方法通过 [`Command`]
//! 通道送给主循环执行，而不是在这里另起一套逻辑 —— 尤其是 [`crate::scheduler::Scheduler`]，
//! 它只能有一个所有者（见 `docs/HANDOVER.md` §2.4）。
//!
//! 读方法**没有任何副作用**：不得为了「刷新」而触发探测或下发。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{mpsc, oneshot, watch};

use crate::config::{self, schema::Config, validate, Store as ConfigStore};
use crate::health::{self, Registry, RoundInfo, Snapshot, State, Transition};
use crate::logging;
use crate::marks;
use crate::rules;
use crate::scheduler::{self, Outcome, Scheduler};
use crate::system::conntrack::{Counts, Limits};
use crate::system::firewall::{Capabilities, Nft};
use crate::system::interface::TrafficSample;
use crate::system::Observation;
use crate::transaction::{Coordinator, Decision, Receipt};
use crate::{Error, Result, RPC_PROTOCOL};

// ==================== 帧与信封 ====================

/// 单帧最大字节数。请求是小 JSON，512 KiB 足够；超限直接拒绝，
/// 因为「先读完再拒绝」会让一个畸形客户端占住连接。
pub const MAX_FRAME_BYTES: usize = 512 * 1024;

/// 长度前缀宽度（大端 u32）。
const LEN_PREFIX: usize = 4;

/// 连接空闲超时：rpcd 桥是短连接模式，长留着只会让对端忘记关。
const IDLE_TIMEOUT: Duration = Duration::from_secs(120);

/// 等待主循环执行命令的超时。一次 apply 含探测轮与完整事务，给足余量。
const COMMAND_TIMEOUT: Duration = Duration::from_secs(90);

/// 统一响应信封。字段与 `docs/ARCHITECTURE.md` §6 逐字对应，前端按它握手。
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct Envelope {
    pub ok: bool,
    pub protocol: u32,
    pub timestamp: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

/// 结构化错误。`code` 必须是 [`crate::Error::code()`] 的稳定值之一。
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct RpcError {
    pub code: String,
    pub message: String,
    pub details: Vec<String>,
}

impl Envelope {
    /// 成功响应。
    pub fn ok_data(data: Value) -> Envelope {
        Envelope {
            ok: true,
            protocol: RPC_PROTOCOL,
            timestamp: logging::now_ms(),
            data: Some(data),
            error: None,
        }
    }

    /// 失败响应。`code` 由调用方从 [`crate::Error::code()`] 取，保证前后端一致。
    pub fn err(code: &str, message: String, details: Vec<String>) -> Envelope {
        Envelope {
            ok: false,
            protocol: RPC_PROTOCOL,
            timestamp: logging::now_ms(),
            data: None,
            error: Some(RpcError {
                code: code.to_string(),
                message: crate::clamp_str(&message, 512),
                details: details
                    .into_iter()
                    .map(|d| crate::clamp_str(&d, 256))
                    .collect(),
            }),
        }
    }

    /// 把内部错误映射成信封，**保留错误码**（前端要靠它决定是否可重试）。
    pub fn from_error(e: &Error) -> Envelope {
        Envelope::err(e.code(), e.to_string(), Vec::new())
    }
}

/// 请求体。没有 id 字段：一请求一响应，且协议版本在信封里握手。
#[derive(Debug, serde::Deserialize)]
struct RawRequest {
    method: String,
    #[serde(default)]
    params: Value,
}

/// 序列化并加长度前缀。
pub fn encode_frame(v: &Value) -> Result<Vec<u8>> {
    let body = serde_json::to_vec(v)?;
    let n = u32::try_from(body.len()).map_err(|_| {
        Error::Json(serde_json::Error::io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "帧超过 4GiB",
        )))
    })?;
    let mut out = Vec::with_capacity(LEN_PREFIX + body.len());
    out.extend_from_slice(&n.to_be_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

/// 读一帧。`Ok(None)` = 对端正常关闭（读到干净的 EOF）。
pub async fn read_frame<R: AsyncReadExt + Unpin>(r: &mut R) -> Result<Option<Vec<u8>>> {
    let mut len = [0u8; LEN_PREFIX];
    match r.read_exact(&mut len).await {
        // 本 tokio 版本的 read_exact 成功时返回读到的字节数（= 缓冲区长度）。
        Ok(_) => {}
        // 连接建立后一个字节都没收到就关闭：正常关闭，不是错误。
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(Error::Io(e)),
    }
    let n = u32::from_be_bytes(len) as usize;
    if n == 0 {
        return Err(Error::Json(serde_json::Error::io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "零长度帧",
        ))));
    }
    if n > MAX_FRAME_BYTES {
        return Err(Error::Json(serde_json::Error::io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("帧过大：{n} > {MAX_FRAME_BYTES}"),
        ))));
    }
    let mut buf = vec![0u8; n];
    r.read_exact(&mut buf).await?;
    Ok(Some(buf))
}

async fn write_frame<W: AsyncWriteExt + Unpin>(w: &mut W, bytes: &[u8]) -> Result<()> {
    w.write_all(bytes).await?;
    w.flush().await?;
    Ok(())
}

// ==================== 方法表 ====================

/// 方法种类。写方法才进审计；读方法不许有任何副作用。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Read,
    Write,
}

/// 方法清单。与 `docs/ARCHITECTURE.md` §6 的表一一对应，**增删方法必须同步文档**。
///
/// 不少于 19 条（任务书 6.1）。`probeNow` 名义上是读，但会真的发出探测包，
/// 因此按写方法审计。
///
/// 末尾六个是「便捷形态」：`switchMode` / `setPrimary` / `setBackupOrder` /
/// `setAlgorithm` / `failback` 只是「改一个字段 + 保存 + 触发一轮事务」的薄封装
/// （数据模型与事务原本就支持，这里补的是调用形态），`diagnostics` 是若干只读
/// 方法的聚合视图。它们都不持有状态，也不绕过 [`Command`] 通道。
pub const METHODS: &[(&str, Kind)] = &[
    ("smartmwan.hello", Kind::Read),
    ("smartmwan.getStatus", Kind::Read),
    ("smartmwan.getLines", Kind::Read),
    ("smartmwan.getLine", Kind::Read),
    ("smartmwan.getBalance", Kind::Read),
    ("smartmwan.getFailover", Kind::Read),
    ("smartmwan.getGames", Kind::Read),
    ("smartmwan.getGameQuality", Kind::Read),
    ("smartmwan.getConnections", Kind::Read),
    ("smartmwan.getTraffic", Kind::Read),
    ("smartmwan.getLogs", Kind::Read),
    ("smartmwan.getConfig", Kind::Read),
    ("smartmwan.getCapabilities", Kind::Read),
    ("smartmwan.validate", Kind::Read),
    ("smartmwan.diff", Kind::Read),
    ("smartmwan.save", Kind::Write),
    ("smartmwan.apply", Kind::Write),
    ("smartmwan.rollback", Kind::Write),
    ("smartmwan.forceWan", Kind::Write),
    ("smartmwan.releaseForced", Kind::Write),
    ("smartmwan.setMaintenance", Kind::Write),
    ("smartmwan.probeNow", Kind::Write),
    ("smartmwan.reload", Kind::Write),
    ("smartmwan.switchMode", Kind::Write),
    ("smartmwan.setPrimary", Kind::Write),
    ("smartmwan.setBackupOrder", Kind::Write),
    ("smartmwan.setAlgorithm", Kind::Write),
    ("smartmwan.failback", Kind::Write),
    ("smartmwan.diagnostics", Kind::Read),
];

/// 方法总数（文档与测试引用）。
pub const METHOD_COUNT: usize = METHODS.len();

/// 任务书 6.1 的「不少于 19 个方法」是编译期可判的事实，放在匿名常量里：
/// 方法被删到 19 条以下时**编译**就失败，而不是等测试运行。
const _: () = assert!(METHOD_COUNT >= 19);

fn method_kind(name: &str) -> Option<Kind> {
    METHODS.iter().find(|(n, _)| *n == name).map(|(_, k)| *k)
}

// ==================== 鉴权 ====================

/// 调用者身份（来自 `SO_PEERCRED`，不可由对端伪造）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Caller {
    pub uid: u32,
    pub gid: u32,
    pub pid: u32,
}

/// uid 白名单。默认 root（0）；rpcd 以 root 运行，uhttpd 降权到 wwwdata，
/// 因此 wwwdata 也放行（按方法的读写区分由 rpcd 的 acl.d 负责，见 M8）。
#[derive(Debug, Clone)]
pub struct Acl {
    allowed: Vec<u32>,
}

impl Acl {
    /// root + 解析出的 wwwdata（若 `/etc/passwd` 里有）。
    pub fn system_default(passwd: &Path) -> Acl {
        let mut allowed = vec![0u32];
        if let Some(u) = wwwdata_uid(passwd) {
            if !allowed.contains(&u) {
                allowed.push(u);
            }
        }
        Acl { allowed }
    }

    /// 仅测试用：只允许 root。
    pub fn root_only() -> Acl {
        Acl { allowed: vec![0] }
    }

    pub fn allows(&self, uid: u32) -> bool {
        self.allowed.contains(&uid)
    }

    pub fn allowed_uids(&self) -> &[u32] {
        &self.allowed
    }
}

/// 从 `/etc/passwd` 找 `wwwdata` 的 uid。找不到返回 `None`（只允许 root），
/// 不猜一个常见值 —— 猜错的后果是放行一个不属于本系统的 uid。
///
/// passwd 行格式 `name:passwd:uid:gid:...`，uid 是**第三**个字段。
pub fn wwwdata_uid(passwd: &Path) -> Option<u32> {
    let text = std::fs::read_to_string(passwd).ok()?;
    text.lines()
        .map(|l| l.split(':'))
        .find(|f| f.clone().next() == Some("wwwdata"))
        .and_then(|mut f| {
            f.next()?; // name
            f.next()?; // passwd
            f.next() // uid
        })
        .and_then(|uid| uid.parse().ok())
}

/// 取对端凭证。失败（非 socket、已关闭）返回 `None`，调用方必须拒绝服务。
pub fn peer_cred(fd: std::os::unix::io::RawFd) -> Option<Caller> {
    // SAFETY: `ucred` 是 POD，`getsockopt` 只写入不超过所给长度的数据；
    // 失败时返回 -1，此时不解引用任何内容。
    let mut uc: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let ret = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut uc as *mut libc::ucred as *mut libc::c_void,
            &mut len,
        )
    };
    if ret != 0 {
        return None;
    }
    Some(Caller {
        uid: uc.uid,
        gid: uc.gid,
        pid: uc.pid as u32,
    })
}

// ==================== 共享状态 ====================

/// 关键路径集合（由 main 在装配时填好）。
#[derive(Debug, Clone)]
pub struct Paths {
    /// `/etc/config/smartmwan`。
    pub config: PathBuf,
    /// 状态目录（`applied.json` / `applied.nft`）。
    pub state_dir: PathBuf,
    /// RPC socket 路径。
    pub socket: PathBuf,
}

/// 流量视图：当前采样 + 上一帧（速率靠差值，绝不编造）。
#[derive(Debug, Clone)]
pub struct TrafficView {
    pub cur: TrafficSample,
    pub prev: Option<TrafficSample>,
}

/// 连接统计视图：当前扫描 + 上一帧 + sysctl 上限。
#[derive(Debug, Clone)]
pub struct ConnView {
    pub cur: Counts,
    pub prev: Option<Counts>,
    pub limits: Option<Limits>,
}

/// 主循环重载结果（`smartmwan.reload` 的响应体）。
#[derive(Debug, Clone, Default, Serialize)]
pub struct ReloadReport {
    pub reloaded: bool,
    pub parse_warnings: Vec<String>,
    pub note: String,
}

/// RPC 交给主循环执行的命令。**所有状态变更都走这里**，
/// 因为 Scheduler / 探测 / 事务的所有者是主循环，不是 RPC 连接。
pub enum Command {
    /// 立即跑一轮探测（`probeNow`）。
    ProbeNow(oneshot::Sender<RoundInfo>),
    /// 立即跑一轮「决策 + 提交」（apply / forceWan / releaseForced / setMaintenance）。
    Cycle(oneshot::Sender<Receipt>),
    /// 重新读盘并复位去抖状态（reload / SIGHUP）。
    Reload(oneshot::Sender<ReloadReport>),
}

/// 全进程共享状态。每个字段都有唯一写者（主循环或 save/reload 路径），
/// RPC 只读；锁的临界区内**不得有 await**。
pub struct AppState {
    pub coordinator: Arc<Coordinator>,
    pub registry: Arc<Registry>,
    pub scheduler: Arc<Mutex<Scheduler>>,
    /// 当前生效配置。`save`/`reload` 成功后替换；apply 不接收 UI 传来的配置副本，
    /// 以这里（= 磁盘内容）为准。
    pub cfg: Arc<RwLock<Arc<Config>>>,
    pub snap: Arc<RwLock<Snapshot>>,
    /// 最近一次内核观测（`getLines` 的设备/网关/地址来自这里）。
    /// `Observation` 不含 `Clone`，因此按 `Arc` 共享快照。
    pub ob: Arc<RwLock<Option<Arc<Observation>>>>,
    pub loads: Arc<RwLock<BTreeMap<String, scheduler::balancing::Load>>>,
    pub traffic: Arc<RwLock<TrafficView>>,
    pub conns: Arc<RwLock<ConnView>>,
    pub receipt: Arc<RwLock<Option<Receipt>>>,
    pub outcome: Arc<RwLock<Option<Outcome>>>,
    pub decision: Arc<RwLock<Decision>>,
    /// 最近一轮探测统计（`probeNow` 的响应体）。
    pub last_round: Arc<Mutex<Option<RoundInfo>>>,
    pub caps: Arc<RwLock<Capabilities>>,
    pub dns: Arc<Mutex<rules::dns_sets::Registry>>,
    /// 最近一次游戏规则命中计数采样。**主循环低频写入，RPC 只读**；
    /// 通道不是真 nft 时永远停在默认值（读不到就是读不到，不补 0）。
    pub hits: Arc<RwLock<rules::GameHits>>,
    pub ctl: mpsc::UnboundedSender<Command>,
    pub paths: Paths,
    pub started: Instant,
    pub acl: Acl,
    /// 真机 nft 通道（`--capabilities` 与 getCapabilities 用；沙箱里为 None）。
    pub nft: Option<Arc<Nft>>,
}

impl AppState {
    /// 配置快照（`Arc` 克隆，避免整树拷贝）。
    pub fn cfg_snapshot(&self) -> Arc<Config> {
        read_lock(&self.cfg).clone()
    }

    pub fn state_dir(&self) -> &Path {
        &self.paths.state_dir
    }
}

/// 锁中毒时取回内容：poisoning 只可能来自 panic 的临界区，
/// 那时继续用现有数据比让每个 RPC 都报错更有意义（数据本身仍一致）。
fn read_lock<T>(l: &RwLock<T>) -> std::sync::RwLockReadGuard<'_, T> {
    match l.read() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

fn write_lock<T>(l: &RwLock<T>) -> std::sync::RwLockWriteGuard<'_, T> {
    match l.write() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

// ==================== 服务器 ====================

/// RPC 服务器。`run()` 是接受循环，直到 shutdown 为 true。
pub struct Server {
    listener: UnixListener,
    state: Arc<AppState>,
    shutdown: watch::Receiver<bool>,
}

impl Server {
    /// 绑定 socket。父目录不存在会创建；遗留的旧 socket 文件先删
    /// （上次异常退出时它还在，bind 会报 EADDRINUSE）。
    pub fn bind(
        path: &Path,
        state: Arc<AppState>,
        shutdown: watch::Receiver<bool>,
    ) -> Result<Server> {
        if let Some(dir) = path.parent() {
            if !dir.as_os_str().is_empty() {
                std::fs::create_dir_all(dir).map_err(|e| {
                    Error::Io(std::io::Error::new(
                        e.kind(),
                        format!("创建 socket 目录 {} 失败: {e}", dir.display()),
                    ))
                })?;
            }
        }
        // 探测是不是一个活着的实例：连得上就说明有守护进程在跑，直接报错，
        // 而不是删掉别人的 socket 再绑定（那会让两个实例同时写内核）。
        if path.exists() {
            let alive = std::os::unix::net::UnixStream::connect(path).is_ok();
            if alive {
                return Err(Error::Config(format!(
                    "RPC socket {} 已有实例在监听，拒绝重复启动",
                    path.display()
                )));
            }
            let _ = std::fs::remove_file(path);
        }
        let listener = UnixListener::bind(path)?;
        // 0660：root 与同组可写。不放宽到 0666 —— 本 socket 能改内核路由。
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o660));
        logging::info_ctx(
            "rpc",
            "listen",
            &format!("RPC 监听 {}", path.display()),
            &[("acl", format!("{:?}", state.acl.allowed_uids()))],
        );
        Ok(Server {
            listener,
            state,
            shutdown,
        })
    }

    /// 接受循环。每个连接一个任务；连接内串行处理请求。
    pub async fn run(self) -> Result<()> {
        let Server {
            listener,
            state,
            mut shutdown,
        } = self;
        loop {
            tokio::select! {
                biased;
                changed = shutdown.changed() => {
                    if changed.is_ok() && *shutdown.borrow() {
                        break;
                    }
                }
                acc = listener.accept() => {
                    let (stream, _addr) = acc?;
                    let st = state.clone();
                    tokio::spawn(async move {
                        serve_conn(stream, st).await;
                    });
                }
            }
        }
        logging::info_ctx("rpc", "stop", "RPC 接受循环已停止", &[]);
        Ok(())
    }
}

/// 服务一条连接：鉴权 → 循环读帧 → 分发 → 写帧。
async fn serve_conn(stream: UnixStream, state: Arc<AppState>) {
    let fd = {
        use std::os::unix::io::AsRawFd;
        stream.as_raw_fd()
    };
    let Some(caller) = peer_cred(fd) else {
        logging::warn_ctx("rpc", "peer", "无法获取对端凭证，拒绝服务", &[]);
        return;
    };
    let (mut rd, mut wr) = stream.into_split();
    loop {
        let frame = match tokio::time::timeout(IDLE_TIMEOUT, read_frame(&mut rd)).await {
            Ok(Ok(Some(f))) => f,
            Ok(Ok(None)) => break, // 对端关闭
            Ok(Err(e)) => {
                logging::debug_ctx(
                    "rpc",
                    "frame",
                    &format!("读帧失败（{e}），断开"),
                    &[("caller", caller.uid.to_string())],
                );
                break;
            }
            Err(_) => break, // 空闲超时
        };
        let resp = handle_frame(&state, caller, &frame).await;
        let bytes = match encode_frame(&resp) {
            Ok(b) => b,
            Err(e) => {
                logging::error_ctx("rpc", "encode", e, &[]);
                break;
            }
        };
        if write_frame(&mut wr, &bytes).await.is_err() {
            break;
        }
    }
}

/// 解析一帧并分发。任何解析失败都回一封带错误码的信封，不断连
/// （一次手滑不该让整条连接死掉）。
async fn handle_frame(state: &AppState, caller: Caller, frame: &[u8]) -> Value {
    let req: RawRequest = match serde_json::from_slice(frame) {
        Ok(r) => r,
        Err(e) => {
            let env = Envelope::err("json", format!("请求不是合法 JSON: {e}"), Vec::new());
            return serde_json::to_value(&env).unwrap_or_else(|_| json!({"ok": false}));
        }
    };
    let env = dispatch(state, caller, &req.method, req.params).await;
    serde_json::to_value(&env).unwrap_or_else(|_| json!({"ok": false}))
}

// ==================== 分发 ====================

/// 分发一个方法。公开是为了让测试不经过 socket 也能验证路由与 ACL。
pub async fn dispatch(st: &AppState, caller: Caller, method: &str, params: Value) -> Envelope {
    let t0 = Instant::now();
    let Some(kind) = method_kind(method) else {
        return Envelope::err(
            "json",
            format!("未知方法 {method}"),
            vec![format!("协议版本 {RPC_PROTOCOL}")],
        );
    };
    if !st.acl.allows(caller.uid) {
        logging::warn_ctx(
            "rpc",
            "deny",
            &format!("uid {} 调用 {method} 被 ACL 拒绝", caller.uid),
            &[("caller", format!("uid={} pid={}", caller.uid, caller.pid))],
        );
        return Envelope::err(
            "permission",
            format!("调用者 uid {} 不在白名单（仅 root/wwwdata）", caller.uid),
            Vec::new(),
        );
    }

    let res = match method {
        "smartmwan.hello" => h_hello(st).await,
        "smartmwan.getStatus" => h_get_status(st).await,
        "smartmwan.getLines" => h_get_lines(st).await,
        "smartmwan.getLine" => h_get_line(st, &params).await,
        "smartmwan.getBalance" => h_get_balance(st).await,
        "smartmwan.getFailover" => h_get_failover(st).await,
        "smartmwan.getGames" => h_get_games(st).await,
        "smartmwan.getGameQuality" => h_get_game_quality(st).await,
        "smartmwan.getConnections" => h_get_connections(st).await,
        "smartmwan.getTraffic" => h_get_traffic(st).await,
        "smartmwan.getLogs" => h_get_logs(&params).await,
        "smartmwan.getConfig" => h_get_config(st).await,
        "smartmwan.getCapabilities" => h_get_capabilities(st).await,
        "smartmwan.validate" => h_validate(&params).await,
        "smartmwan.diff" => h_diff(st).await,
        "smartmwan.save" => h_save(st, &params, caller).await,
        "smartmwan.apply" => h_apply(st).await,
        "smartmwan.rollback" => h_rollback(st).await,
        "smartmwan.forceWan" => h_force_wan(st, &params).await,
        "smartmwan.releaseForced" => h_release_forced(st).await,
        "smartmwan.setMaintenance" => h_set_maintenance(st, &params, caller).await,
        "smartmwan.probeNow" => h_probe_now(st).await,
        "smartmwan.reload" => h_reload(st).await,
        "smartmwan.switchMode" => h_switch_mode(st, &params, caller).await,
        "smartmwan.setPrimary" => h_set_primary(st, &params, caller).await,
        "smartmwan.setBackupOrder" => h_set_backup_order(st, &params, caller).await,
        "smartmwan.setAlgorithm" => h_set_algorithm(st, &params, caller).await,
        "smartmwan.failback" => h_failback(st).await,
        "smartmwan.diagnostics" => h_diagnostics(st).await,
        _ => Err(Error::Unsupported(format!("方法 {method} 尚未实现"))),
    };

    // 写方法与有网络副作用的 probeNow 必须留审计；读方法不留。
    if kind == Kind::Write {
        audit(caller, method, &params, &res, t0.elapsed());
    }

    match res {
        Ok(v) => Envelope::ok_data(v),
        Err(e) => Envelope::from_error(&e),
    }
}

/// 审计一条写调用。参数摘要脱敏；事务 id 从回执里取，便于把 UI 操作与内核变更对上。
fn audit(caller: Caller, method: &str, params: &Value, res: &Result<Value>, took: Duration) {
    let summary = redact_params(params);
    let (result, tx) = match res {
        Ok(v) => ("ok", tx_of(v)),
        Err(_) => ("err", None),
    };
    let mut ctx: Vec<(&str, String)> = vec![
        ("caller", format!("uid={} pid={}", caller.uid, caller.pid)),
        ("params", summary),
        ("result", result.to_string()),
        ("took_ms", took.as_millis().to_string()),
    ];
    if let Some(t) = tx {
        ctx.push(("transaction", t));
    }
    logging::info_ctx("rpc", method, &format!("{method} → {result}"), &ctx);
}

/// 从回执 JSON 里取事务 id（apply/forceWan 等的响应体就是回执本身）。
fn tx_of(v: &Value) -> Option<String> {
    v.get("id")
        .and_then(|id| id.as_str())
        .filter(|s| s.starts_with('T'))
        .map(str::to_string)
}

/// 参数摘要：递归屏蔽疑似密钥字段，再截断。日志里绝不出现明文密码。
fn redact_params(p: &Value) -> String {
    crate::clamp_str(&mask_secrets(p).to_string(), 256)
}

fn mask_secrets(v: &Value) -> Value {
    match v {
        Value::Object(m) => {
            let mut out = serde_json::Map::new();
            for (k, val) in m {
                if looks_secret_key(k) {
                    out.insert(k.clone(), Value::String("***".into()));
                } else {
                    out.insert(k.clone(), mask_secrets(val));
                }
            }
            Value::Object(out)
        }
        Value::Array(a) => Value::Array(a.iter().map(mask_secrets).collect()),
        other => other.clone(),
    }
}

fn looks_secret_key(k: &str) -> bool {
    let k = k.to_ascii_lowercase();
    [
        "password",
        "passwd",
        "secret",
        "token",
        "key",
        "credential",
        "private",
    ]
    .iter()
    .any(|s| k.contains(s))
}

// ==================== 参数提取助手 ====================

/// 取字符串参数。缺失/空/非字符串都是调用方错误（`validate` 码）。
fn param_str<'a>(params: &'a Value, key: &str) -> Result<&'a str> {
    params
        .get(key)
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| Error::Validate(format!("缺少参数 {key}（应为非空字符串）")))
}

fn param_bool(params: &Value, key: &str, default: bool) -> bool {
    params.get(key).and_then(|v| v.as_bool()).unwrap_or(default)
}

/// 取配置对象参数（`validate` / `save` 的 `config` 字段）。
fn param_config(params: &Value) -> Result<Config> {
    let raw = params
        .get("config")
        .ok_or_else(|| Error::Validate("缺少参数 config（配置对象）".into()))?;
    serde_json::from_value::<Config>(raw.clone())
        .map_err(|e| Error::Validate(format!("config 不是合法配置对象: {e}")))
}

// ==================== 只读方法 ====================

async fn h_hello(st: &AppState) -> Result<Value> {
    Ok(json!({
        "protocol": RPC_PROTOCOL,
        "version": env!("CARGO_PKG_VERSION"),
        "pid": std::process::id(),
        "uptime_ms": st.started.elapsed().as_millis() as u64,
        "socket": st.paths.socket.display().to_string(),
    }))
}

async fn h_get_status(st: &AppState) -> Result<Value> {
    let cfg = st.cfg_snapshot();
    let snap = read_lock(&st.snap).clone();
    let outcome = read_lock(&st.outcome).clone();
    let conns = read_lock(&st.conns).clone();
    let receipt = read_lock(&st.receipt).clone();

    let (mode, algorithm, active, standby, waiting, all_dead, reason, notes, share, moved, at_ms) =
        match &outcome {
            Some(o) => (
                o.mode.as_str(),
                o.algorithm.as_str(),
                o.active.clone(),
                o.standby.clone(),
                o.waiting.clone(),
                o.all_dead,
                o.reason.clone(),
                o.notes.clone(),
                o.share_permille(),
                o.moved,
                o.at_ms,
            ),
            None => (
                cfg.global.mode.as_str(),
                cfg.global.algorithm.as_str(),
                None,
                Vec::new(),
                None,
                false,
                "守护进程尚未完成第一轮决策".to_string(),
                vec!["尚未完成首轮决策：页面所有线路数据都必须是「未测量」而不是 0".to_string()],
                Vec::new(),
                0,
                0,
            ),
        };

    let forced = {
        let g = st.scheduler.lock().unwrap_or_else(|p| p.into_inner());
        g.forced().map(str::to_string)
    };

    Ok(json!({
        "enabled": cfg.global.enabled,
        "measured": snap.measured,
        "mode": mode,
        "algorithm": algorithm,
        "algorithm_limitations": cfg.global.algorithm.limitations(),
        "active": active,
        "standby": standby,
        "waiting": waiting.map(|(w, why)| json!({"wan": w, "reason": why})),
        "all_dead": all_dead,
        "carries_traffic": outcome.as_ref().map(|o| o.carries_traffic()).unwrap_or(false),
        "forced": forced,
        "reason": reason,
        "notes": notes,
        "buckets": {
            "total": outcome.as_ref().map(|o| o.buckets.len()).unwrap_or(0),
            "moved": moved,
            "at_ms": at_ms,
            "share_permille": share.iter().map(|(n, p)| json!({"wan": n, "permille": p})).collect::<Vec<_>>(),
        },
        "connections": {
            "owned": conns.cur.owned(),
            "foreign": conns.cur.foreign,
            "unmarked": conns.cur.unmarked,
            "total": conns.cur.total,
            "truncated": conns.cur.truncated,
            "at_ms": conns.cur.at_ms,
        },
        "busy": st.coordinator.is_busy(),
        "firewall": st.coordinator.plane().fw.describe(),
        "last_receipt": receipt,
    }))
}

async fn h_get_lines(st: &AppState) -> Result<Value> {
    let cfg = st.cfg_snapshot();
    let snap = read_lock(&st.snap).clone();
    let ob = read_lock(&st.ob).clone();
    let conns = read_lock(&st.conns).clone();
    let slots = scheduler::slot_map(&cfg)?;
    let now = logging::now_ms();
    let mut out = Vec::with_capacity(cfg.wans.len());
    for w in &cfg.wans {
        let slot = slots.get(&w.name).copied();
        let h = snap.get(&w.name);
        let r = ob.as_ref().and_then(|o| o.resolved.get(&w.name));
        out.push(json!({
            "name": w.name,
            "enabled": w.enabled,
            "role": w.role.as_str(),
            "priority": w.priority,
            "weight": w.weight,
            "maintenance": w.maintenance,
            "device": r.map(|x| x.device.clone()).unwrap_or_else(|| w.device.clone()),
            "link_up": r.map(|x| x.link_up).unwrap_or(false),
            "address": r.and_then(|x| x.src4.map(|a| a.to_string())),
            "gateway": r.and_then(|x| x.gw4.map(|a| a.to_string())),
            "slot": slot,
            "table": slot.map(marks::table_of),
            "state": h.map(|x| x.state.as_str()).unwrap_or("unknown"),
            "state_label": h.map(|x| state_label(x.state)).unwrap_or("未测量"),
            "blocked_reason": h.and_then(|x| x.blocked_reason.clone()),
            "last_outcome": h.and_then(|x| x.last_outcome.clone()),
            "metrics": h.and_then(|x| x.metrics.as_ref()).map(metrics_json),
            "warmup_remaining_ms": h.map(|x| x.warmup_remaining_ms).unwrap_or(0),
            "state_since_ms": h.map(|x| x.state_since_ms).unwrap_or(0),
            "consec_ok": h.map(|x| x.consec_ok).unwrap_or(0),
            "consec_fail": h.map(|x| x.consec_fail).unwrap_or(0),
            "probes_total": h.map(|x| x.probes_total).unwrap_or(0),
            "probes_ignored": h.map(|x| x.probes_ignored).unwrap_or(0),
            "conns": slot.map(|s| conns.cur.of_slot(s)).unwrap_or(0),
            "resolve_notes": r.map(|x| x.notes.clone()).unwrap_or_default(),
        }));
    }
    Ok(json!({ "lines": out, "measured": snap.measured, "at_ms": now }))
}

async fn h_get_line(st: &AppState, params: &Value) -> Result<Value> {
    let name = param_str(params, "wan")?;
    let cfg = st.cfg_snapshot();
    let w = cfg
        .wan(name)
        .ok_or_else(|| Error::Validate(format!("线路 {name} 不存在")))?;
    let snap = read_lock(&st.snap).clone();
    let h = snap.get(name);
    let transitions: Vec<Transition> = st.registry.transitions(name);
    let diagnostics = health::probe_diagnostics(&cfg, &snap)
        .into_iter()
        .filter(|d| d.contains(name))
        .collect::<Vec<_>>();
    let slots = scheduler::slot_map(&cfg)?;
    Ok(json!({
        "line": {
            "name": w.name,
            "enabled": w.enabled,
            "role": w.role.as_str(),
            "priority": w.priority,
            "weight": w.weight,
            "maintenance": w.maintenance,
            "device": w.device,
            "slot": slots.get(name).copied(),
            "table": slots.get(name).copied().map(marks::table_of),
            "state": h.map(|x| x.state.as_str()).unwrap_or("unknown"),
            "state_label": h.map(|x| state_label(x.state)).unwrap_or("未测量"),
            "blocked_reason": h.and_then(|x| x.blocked_reason.clone()),
            "last_outcome": h.and_then(|x| x.last_outcome.clone()),
            "metrics": h.and_then(|x| x.metrics.as_ref()).map(metrics_json),
            "warmup_remaining_ms": h.map(|x| x.warmup_remaining_ms).unwrap_or(0),
            "consec_ok": h.map(|x| x.consec_ok).unwrap_or(0),
            "consec_fail": h.map(|x| x.consec_fail).unwrap_or(0),
            "probes_total": h.map(|x| x.probes_total).unwrap_or(0),
            "probes_ignored": h.map(|x| x.probes_ignored).unwrap_or(0),
        },
        "config": w,
        "transitions": transitions.iter().map(|t| json!({
            "at_ms": t.at_ms,
            "from": t.from.as_str(),
            "to": t.to.as_str(),
            "reason": t.reason,
        })).collect::<Vec<_>>(),
        "diagnostics": diagnostics,
    }))
}

async fn h_get_balance(st: &AppState) -> Result<Value> {
    let cfg = st.cfg_snapshot();
    let outcome = read_lock(&st.outcome).clone();
    let (buckets, moved, at_ms, algorithm, share) = match &outcome {
        Some(o) => (
            o.buckets.clone(),
            o.moved,
            o.at_ms,
            o.algorithm,
            o.share_permille(),
        ),
        None => (Vec::new(), 0, 0, cfg.global.algorithm, Vec::new()),
    };
    let total = usize::from(cfg.global.buckets.max(1));
    Ok(json!({
        "algorithm": algorithm.as_str(),
        "configured_algorithm": cfg.global.algorithm.as_str(),
        "limitations": algorithm.limitations(),
        "buckets_total": total,
        "buckets": buckets,
        "share_permille": share.iter().map(|(n, p)| json!({"wan": n, "permille": p})).collect::<Vec<_>>(),
        "moved": moved,
        "at_ms": at_ms,
        "rebalance_interval_ms": cfg.global.rebalance_interval_ms,
        "smoothing_permille": cfg.global.smoothing_permille,
        "hash_seed": cfg.global.hash_seed,
    }))
}

async fn h_get_failover(st: &AppState) -> Result<Value> {
    let cfg = st.cfg_snapshot();
    let outcome = read_lock(&st.outcome).clone();
    let now = logging::now_ms();
    let order = cfg.failover_order();
    let (active, standby, waiting) = match &outcome {
        Some(o) => (o.active.clone(), o.standby.clone(), o.waiting.clone()),
        None => (None, Vec::new(), None),
    };
    let sched = st.scheduler.lock().unwrap_or_else(|p| p.into_inner());
    Ok(json!({
        "order": order,
        "active": active,
        "forced": sched.forced().map(str::to_string),
        "standby": standby,
        "waiting": waiting.map(|(w, why)| json!({"wan": w, "reason": why})),
        "last_switch_ms": sched.last_switch_ms(),
        "primary": cfg.global.primary,
        "failback": cfg.global.failback.as_str(),
        "failback_delay_ms": cfg.global.failback_delay_ms,
        "failback_success_threshold": cfg.global.failback_success_threshold,
        "min_switch_interval_ms": cfg.global.min_switch_interval_ms,
        "now_ms": now,
    }))
}

async fn h_get_games(st: &AppState) -> Result<Value> {
    let cfg = st.cfg_snapshot();
    // 冲突与重复 id 由 validate 统一产出（overlaps 在 validate 内），
    // 这里按 path 过滤出游戏相关项，避免 RPC 自己再算一遍判重。
    let report = validate::validate(&cfg);
    let conflicts: Vec<&validate::Issue> = report
        .issues
        .iter()
        .filter(|i| i.path.contains("game"))
        .collect();
    let rules: Vec<Value> = cfg
        .games
        .iter()
        .map(|g| {
            json!({
                "name": g.name,
                "enabled": g.enabled,
                "priority": g.priority,
                "selection": g.selection.as_str(),
                "pin_wan": g.pin_wan,
                "targets": g.targets,
                "domains": g.domains,
                "ports": g.ports,
                "proto": g.proto.as_str(),
                "client_ips": g.client_ips,
                "client_macs": g.client_macs,
            })
        })
        .collect();
    let dns_stats = st.dns.lock().unwrap_or_else(|p| p.into_inner()).stats();
    // 命中数：读到什么报什么。查不到就是 null —— 0 会被读成「规则没命中过」，
    // 而真相可能是「通道不是真 nft，根本没读到」。
    let hits = read_lock(&st.hits).clone();
    // slug 必须与 `rules::compile()` 的消歧结果一致：自己再 slug_of 一遍会在
    // 中文名（slug 为空）或同 slug 冲突时把命中数挂到别的规则上，甚至永远显示 null。
    let slugs: std::collections::BTreeMap<String, String> =
        rules::game_slugs(&cfg.games).into_iter().collect();
    let rules: Vec<Value> = rules
        .into_iter()
        .map(|mut r| {
            let name = r["name"].as_str().unwrap_or_default();
            let slug = slugs.get(name).cloned().unwrap_or_default();
            if let Some(obj) = r.as_object_mut() {
                obj.insert(
                    "hits".to_string(),
                    hits.of(&slug)
                        .map(|(p, b)| json!({ "packets": p, "bytes": b }))
                        .unwrap_or(Value::Null),
                );
            }
            r
        })
        .collect();
    Ok(json!({
        "rules": rules,
        "hits_at_ms": hits.at_ms,
        "hits_note": if hits.at_ms == 0 {
            "尚未采样到命中数（nft 通道不是真实执行器，或还没到采样周期）"
        } else if hits.note.is_empty() {
            "命中数来自内核 counter，按规则 slug 求和（同一规则可能对应多条 nft 规则）"
        } else {
            &hits.note
        },
        "conflicts": conflicts,
        "presets_dir": rules::presets::PRESET_DIR,
        "domains_tracked": dns_stats.domains,
        "dns_elements": dns_stats.elements,
        "dns_stale_domains": dns_stats.stale_domains,
        "dns_failures": {
            "notfound": dns_stats.failed_notfound,
            "timeout": dns_stats.failed_timeout,
            "local": dns_stats.failed_local,
        },
        "note": "域名规则的解析结果在动态集合里老化；按类别的连接计数见 getConnections",
    }))
}

async fn h_get_game_quality(st: &AppState) -> Result<Value> {
    let cfg = st.cfg_snapshot();
    let snap = read_lock(&st.snap).clone();
    let slots = scheduler::slot_map(&cfg)?;
    let active = read_lock(&st.outcome)
        .as_ref()
        .and_then(|o| o.active.clone());
    let sched = st.scheduler.lock().unwrap_or_else(|p| p.into_inner());
    let ranking = sched.ranking(&cfg, &slots, &snap, active.as_deref());
    let decision = read_lock(&st.decision).clone();
    let candidates: Vec<Value> = ranking
        .iter()
        .map(|s| {
            json!({
                "wan": s.name,
                "slot": s.slot,
                "score": s.score,
                "rtt_ms": s.rtt_ms,
                "jitter_ms": s.jitter_ms,
                "loss_pmm": s.loss_pmm,
                "instability_pmm": s.instability_pmm,
                "state": s.state.as_str(),
                "confident": s.confident,
                "deductions": s.deductions.iter().map(|(r, v)| json!({"reason": r, "amount": v})).collect::<Vec<_>>(),
            })
        })
        .collect();
    let rules: Vec<Value> = cfg
        .games
        .iter()
        .filter(|g| g.enabled)
        .map(|g| {
            let pick = decision.picks.get(&g.name).copied();
            let picked_wan = pick.and_then(|slot| {
                slots
                    .iter()
                    .find(|(_, s)| **s == slot)
                    .map(|(n, _)| n.clone())
            });
            json!({
                "rule": g.name,
                "selection": g.selection.as_str(),
                "pin_wan": g.pin_wan,
                "pick_slot": pick,
                "pick_wan": picked_wan,
            })
        })
        .collect();
    Ok(json!({
        "ranking": candidates,
        "rules": rules,
        "score_weights": cfg.score,
        "note": "评分是线路级结论，所有规则共用同一份排名；最终落点以 picks 为准",
    }))
}

async fn h_get_connections(st: &AppState) -> Result<Value> {
    let conns = read_lock(&st.conns).clone();
    let growth = conns
        .cur
        .growth_since(conns.prev.as_ref().unwrap_or(&conns.cur));
    let per_slot: Vec<Value> = conns
        .cur
        .per_slot
        .iter()
        .map(|(slot, n)| {
            json!({
                "slot": slot,
                "table": marks::table_of(*slot),
                "conns": n,
                "growth": growth.get(slot).copied().unwrap_or(0),
            })
        })
        .collect();
    Ok(json!({
        "per_slot": per_slot,
        "owned": conns.cur.owned(),
        "foreign": conns.cur.foreign,
        "unmarked": conns.cur.unmarked,
        "total": conns.cur.total,
        "truncated": conns.cur.truncated,
        "at_ms": conns.cur.at_ms,
        "limits": conns.limits.as_ref().map(|l| json!({
            "count": l.count,
            "max": l.max,
            "used_permille": l.used_permille(),
            "tight": l.tight(),
        })),
        "note": if conns.cur.truncated {
            "扫描达到行数上限提前结束：计数偏小，不能当真实负载做均衡决策"
        } else {
            "并发连接数，不是新建速率；速率见 getTraffic"
        },
    }))
}

async fn h_get_traffic(st: &AppState) -> Result<Value> {
    let tv = read_lock(&st.traffic).clone();
    let delta = tv.cur.delta(tv.prev.as_ref().unwrap_or(&tv.cur));
    let window_ms = tv
        .prev
        .as_ref()
        .map(|p| tv.cur.at_ms.saturating_sub(p.at_ms))
        .unwrap_or(0);
    let kbps = |bytes: u64| -> u64 {
        bytes
            .saturating_mul(8000)
            .checked_div(window_ms)
            .map(|v| v / 1024)
            .unwrap_or(0)
    };
    let devices: Vec<Value> = tv
        .cur
        .per_device
        .iter()
        .map(|(name, (rx, tx))| {
            let (drx, dtx) = delta.get(name).copied().unwrap_or((0, 0));
            json!({
                "device": name,
                "rx_bytes": rx,
                "tx_bytes": tx,
                "rx_kbps": kbps(drx),
                "tx_kbps": kbps(dtx),
            })
        })
        .collect();
    Ok(json!({
        "devices": devices,
        "window_ms": window_ms,
        "at_ms": tv.cur.at_ms,
        "note": "计数器来自 /sys/class/net；设备重建（重拨）后差值归零而不是负数",
    }))
}

async fn h_get_logs(params: &Value) -> Result<Value> {
    let level = params
        .get("level")
        .and_then(|v| v.as_str())
        .and_then(logging::Level::parse);
    let limit = params
        .get("limit")
        .and_then(|v| v.as_u64())
        .map(|n| n.clamp(1, 500) as usize)
        .unwrap_or(100);
    let events = logging::recent(level, limit);
    Ok(json!({
        "events": events,
        "dropped": logging::dropped(),
        "note": "只读内存环形缓冲；文件日志路径见 global.log_file",
    }))
}

async fn h_get_config(st: &AppState) -> Result<Value> {
    let cfg = st.cfg_snapshot();
    let applied = config::Store::load_applied(st.state_dir());
    let pending = applied
        .as_ref()
        .map(|a| config::diff(&a.config, &cfg))
        .unwrap_or_default();
    let parse_warnings = ConfigStore::load(&st.paths.config)
        .map(|s| s.parse_warnings)
        .unwrap_or_default();
    Ok(json!({
        "config": &*cfg,
        "schema_version": crate::CONFIG_SCHEMA_VERSION,
        "fingerprint": config::fingerprint(&cfg),
        "parse_warnings": parse_warnings,
        "applied": applied.map(|a| json!({
            "fingerprint": a.fingerprint,
            "applied_at_ms": a.applied_at_ms,
            "transaction": a.transaction,
        })),
        "pending_changes": pending,
    }))
}

async fn h_get_capabilities(st: &AppState) -> Result<Value> {
    let caps = read_lock(&st.caps).clone();
    Ok(json!({
        "nft_exists": caps.nft_exists,
        "version": caps.version,
        "jhash_map": caps.jhash_map,
        "ct_mark_range": caps.ct_mark_range,
        "th_payload": caps.th_payload,
        "dyn_timeout_sets": caps.dyn_timeout_sets,
        "route_hook_output": caps.route_hook_output,
        "ether_sets": caps.ether_sets,
        "comments": caps.comments,
        "jhash_seed": caps.jhash_seed,
        "firewall_channel": st.coordinator.plane().fw.describe(),
        "degraded": degraded_syntax(&caps),
        "note": "探测在守护进程启动时执行；为 false 的项在生成程序时会被回避并降级为告警",
    }))
}

/// 把「未验证可用」的能力翻译成用户能看懂的解释（UI 直接显示）。
fn degraded_syntax(c: &Capabilities) -> Vec<String> {
    let mut out = Vec::new();
    if !c.dyn_timeout_sets {
        out.push("动态集合（dynamic,timeout）不可用：带域名条件的游戏规则不会下发".into());
    }
    if !c.ether_sets {
        out.push("ether_addr 集合不可用：只有 MAC 客户端条件的规则不会下发".into());
    }
    if !c.th_payload {
        out.push("传输头匹配（th sport/dport）不可用：按端口的游戏条件不会下发".into());
    }
    if !c.route_hook_output {
        out.push("route hook output 不可用：路由器本机发起流量的回程标记不生效".into());
    }
    if !c.jhash_map {
        out.push("jhash map 不可用：桶映射改用静态逐条规则（规则数随桶数增长）".into());
    }
    if !c.comments {
        out.push("规则 comment 不可用：无法按标签复核与定位，清理退化为整表删除".into());
    }
    if !c.ct_mark_range {
        out.push("ct mark 区间匹配不可用：继承已建立连接的出口标记不生效".into());
    }
    out
}

/// 试算一份配置（不写盘、不碰内核）。
async fn h_validate(params: &Value) -> Result<Value> {
    let cfg = param_config(params)?;
    let report = validate::validate(&cfg);
    Ok(json!({
        "valid": report.is_valid(),
        "schema_version": report.schema_version,
        "issues": report.issues,
        "note": "试算不写盘、不碰内核；保存请用 save，下发请用 apply",
    }))
}

/// 「已保存但尚未下发」的变更摘要（应用前确认页用）。
async fn h_diff(st: &AppState) -> Result<Value> {
    let cfg = st.cfg_snapshot();
    let applied = config::Store::load_applied(st.state_dir());
    let changes = applied
        .as_ref()
        .map(|a| config::diff(&a.config, &cfg))
        .unwrap_or_default();
    Ok(json!({
        "changes": changes,
        "applied_transaction": applied.map(|a| a.transaction),
        "note": if changes.is_empty() {
            "当前保存的配置与上次成功应用一致"
        } else {
            "以下变更尚未下发到内核"
        },
    }))
}

// ==================== 写方法 ====================

/// 把新配置放进共享槽，并复位调度器里带旧配置语义的状态。
///
/// 所有改配置的写方法都必须走这里，而不是各自「写槽 + 同步追踪器」：
/// 只换配置而不复位去抖，会让旧配置的失败计数/重排计时延续到新配置上，
/// 出现「刚改了主线路却还在沿用上一次的切换计时」这类错判；
/// 被删掉的游戏规则也要清理选路状态，否则长期运行会留下垃圾条目。
fn adopt_config(st: &AppState, old: &Config, new: Config) {
    {
        let mut g = st.scheduler.lock().unwrap_or_else(|p| p.into_inner());
        for rule in &old.games {
            if !new.games.iter().any(|n| n.name == rule.name) {
                g.forget_rule(&rule.name);
            }
        }
        g.on_config_change();
    }
    *write_lock(&st.cfg) = Arc::new(new);
    st.registry.sync_config(&st.cfg_snapshot());
}

/// 保存配置（写盘，**不下发**）。返回校验报告与相对上一版的差异。
async fn h_save(st: &AppState, params: &Value, caller: Caller) -> Result<Value> {
    let cfg = param_config(params)?;
    let mut store = ConfigStore::load(&st.paths.config)?;
    let report = store.save(&cfg)?;
    let old = st.cfg_snapshot();
    let changes = config::diff(&old, &cfg);
    // 共享配置、健康追踪器阈值、调度器去抖状态三处同步更新；主循环下一轮自然看到新配置。
    adopt_config(st, &old, cfg);
    logging::info_ctx(
        "config",
        "save",
        &format!("配置已保存（{} 项变更，uid {}）", changes.len(), caller.uid),
        &[("caller", caller.uid.to_string())],
    );
    Ok(json!({
        "saved": true,
        "report": report,
        "changes": changes,
        "note": "已写盘但未下发；确认变更摘要后调用 apply",
    }))
}

/// 应用：跑一轮完整事务。**不接收 UI 传来的配置** —— 以磁盘上已保存的为准
/// （`docs/REQUIREMENTS.md` 6.4：不信任界面副本）。
async fn h_apply(st: &AppState) -> Result<Value> {
    let (tx, rx) = oneshot::channel();
    st.ctl
        .send(Command::Cycle(tx))
        .map_err(|_| Error::Io(std::io::Error::other("守护主循环未运行，无法应用")))?;
    let receipt = tokio::time::timeout(COMMAND_TIMEOUT, rx)
        .await
        .map_err(|_| Error::Timeout {
            operation: "apply".into(),
            elapsed_ms: COMMAND_TIMEOUT.as_millis() as u64,
        })?
        .map_err(|_| Error::Io(std::io::Error::other("主循环丢弃了 apply 请求")))?;
    Ok(serde_json::to_value(&receipt)?)
}

/// 回滚到 last-good 快照并重新下发。
async fn h_rollback(st: &AppState) -> Result<Value> {
    let Some(cfg) = config::Store::restore_last_good(st.state_dir())? else {
        return Err(Error::Config(
            "没有可回滚的 last-good 快照（从未成功应用过）".into(),
        ));
    };
    let report = validate::validate(&cfg);
    if !report.is_valid() {
        return Err(Error::Validate(format!(
            "last-good 快照本身校验不过（{} 个致命问题），拒绝回滚",
            report.errors().len()
        )));
    }
    // 回滚要让磁盘与内核一致：否则下次 reload 会把回滚成果覆盖掉。
    let mut store = ConfigStore::load(&st.paths.config)?;
    store.save(&cfg)?;
    let old = st.cfg_snapshot();
    adopt_config(st, &old, cfg);
    let (tx, rx) = oneshot::channel();
    st.ctl
        .send(Command::Cycle(tx))
        .map_err(|_| Error::Io(std::io::Error::other("守护主循环未运行，无法回滚")))?;
    let receipt = tokio::time::timeout(COMMAND_TIMEOUT, rx)
        .await
        .map_err(|_| Error::Timeout {
            operation: "rollback".into(),
            elapsed_ms: COMMAND_TIMEOUT.as_millis() as u64,
        })?
        .map_err(|_| Error::Io(std::io::Error::other("主循环丢弃了 rollback 请求")))?;
    Ok(serde_json::to_value(&receipt)?)
}

/// 强制指定出口。目标不可达时不报错：调度器会等它可用后生效
/// （用户明确表达过的意志不能被静默吞掉）。
async fn h_force_wan(st: &AppState, params: &Value) -> Result<Value> {
    let wan = param_str(params, "wan")?;
    let confirm = param_bool(params, "confirm", false);
    let cfg = st.cfg_snapshot();
    let Some(w) = cfg.wan(wan) else {
        return Err(Error::Validate(format!("线路 {wan} 不存在")));
    };
    if !w.enabled {
        return Err(Error::Validate(format!("线路 {wan} 已停用，不能强制")));
    }
    if cfg.global.mode != crate::config::schema::Mode::Failover {
        return Err(Error::Validate(
            "强制切换只在主备（failover）模式下有意义；均衡模式请改用算法与权重".into(),
        ));
    }
    if cfg.global.require_confirm && !confirm {
        return Err(Error::Validate(
            "该操作会把全部普通流量切到指定线路，需要 confirm=true 二次确认".into(),
        ));
    }
    {
        let mut g = st.scheduler.lock().unwrap_or_else(|p| p.into_inner());
        g.force(wan);
    }
    cycle_via_loop(st, "forceWan").await
}

/// 取消强制，回到自动决策。
async fn h_release_forced(st: &AppState) -> Result<Value> {
    {
        let mut g = st.scheduler.lock().unwrap_or_else(|p| p.into_inner());
        g.release_forced();
    }
    cycle_via_loop(st, "releaseForced").await
}

/// 线路维护模式开关。维护中的线路不参与探测与分流，配置落盘（重启后仍生效）。
async fn h_set_maintenance(st: &AppState, params: &Value, caller: Caller) -> Result<Value> {
    let wan = param_str(params, "wan")?;
    let on = param_bool(params, "on", true);
    // Arc<Config> 不能就地改：取出一份可改副本，保存成功后再替换共享槽。
    let old = st.cfg_snapshot();
    let mut cfg: Config = (*old).clone();
    {
        let w = cfg
            .wan_mut(wan)
            .ok_or_else(|| Error::Validate(format!("线路 {wan} 不存在")))?;
        w.maintenance = on;
    }
    let mut store = ConfigStore::load(&st.paths.config)?;
    store.save(&cfg)?;
    adopt_config(st, &old, cfg);
    logging::info_ctx(
        "rpc",
        "setMaintenance",
        &format!("线路 {wan} 维护模式 {}", if on { "开" } else { "关" }),
        &[("caller", caller.uid.to_string())],
    );
    cycle_via_loop(st, "setMaintenance").await
}

/// 立即跑一轮探测。不改配置、不触发下发；返回本轮统计。
async fn h_probe_now(st: &AppState) -> Result<Value> {
    let (tx, rx) = oneshot::channel();
    st.ctl
        .send(Command::ProbeNow(tx))
        .map_err(|_| Error::Io(std::io::Error::other("守护主循环未运行，无法探测")))?;
    let info = tokio::time::timeout(COMMAND_TIMEOUT, rx)
        .await
        .map_err(|_| Error::Timeout {
            operation: "probeNow".into(),
            elapsed_ms: COMMAND_TIMEOUT.as_millis() as u64,
        })?
        .map_err(|_| Error::Io(std::io::Error::other("主循环丢弃了 probeNow 请求")))?;
    Ok(json!({
        "started_at_ms": info.started_at_ms,
        "finished_at_ms": info.finished_at_ms,
        "planned": info.planned,
        "completed": info.completed,
        "ignored": info.ignored,
        "transitions": info.transitions,
        "cancelled": info.cancelled,
        "note": if info.cancelled {
            "本轮被提前结束（关停或超出批次期限），结论不完整"
        } else {
            "本轮探测已完成"
        },
    }))
}

/// 重新读取 UCI 并复位去抖状态（等价于 SIGHUP 的 RPC 形态）。
async fn h_reload(st: &AppState) -> Result<Value> {
    let (tx, rx) = oneshot::channel();
    st.ctl
        .send(Command::Reload(tx))
        .map_err(|_| Error::Io(std::io::Error::other("守护主循环未运行，无法重载")))?;
    let rep = tokio::time::timeout(COMMAND_TIMEOUT, rx)
        .await
        .map_err(|_| Error::Timeout {
            operation: "reload".into(),
            elapsed_ms: COMMAND_TIMEOUT.as_millis() as u64,
        })?
        .map_err(|_| Error::Io(std::io::Error::other("主循环丢弃了 reload 请求")))?;
    Ok(json!({
        "reloaded": rep.reloaded,
        "parse_warnings": rep.parse_warnings,
        "note": rep.note,
    }))
}

// ==================== 便捷写方法（改一个字段 + 保存 + 一轮事务） ====================
//
// 这一组（switchMode / setPrimary / setBackupOrder / setAlgorithm）只是「调用形态」：
// 数据模型与事务原本就支持这些设置，缺的是「不必先 getConfig 再整份 save」的入口。
// 它们一律复用下面的骨架，绝不各自另写一套写盘与下发顺序。

/// 取字符串数组参数（`setBackupOrder` 的 `order`）。
///
/// 逐项校验而非整体反序列化：哪一项坏了要说出下标，
/// 「参数不合法」这种笼统报错对界面用户没有意义。
fn param_str_list(params: &Value, key: &str) -> Result<Vec<String>> {
    let arr = params
        .get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| Error::Validate(format!("缺少参数 {key}（应为字符串数组）")))?;
    let mut out = Vec::with_capacity(arr.len());
    for (i, v) in arr.iter().enumerate() {
        let s = v
            .as_str()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| Error::Validate(format!("参数 {key}[{i}] 应为非空字符串")))?;
        out.push(s.to_string());
    }
    Ok(out)
}

/// 「改 global 字段 → 保存 → 触发一轮事务」的通用骨架。
///
/// 顺序不是随手排的（见 `docs/HANDOVER.md` §2.9）：配置先落盘（内含校验，
/// 不过关就不写），再替换共享槽并同步健康追踪器，最后请**主循环**跑一轮事务 ——
/// 状态的唯一所有者是主循环，RPC 只负责把新配置放好。
///
/// 闭包返回 `Ok(None)` 表示「新值与当前相同」：此时**不写盘也不触发事务**，
/// 如实返回（不变式 2.5：没有 diff 就不得有数据面写入）。
async fn mutate_global<F>(st: &AppState, caller: Caller, op: &str, f: F) -> Result<Value>
where
    F: FnOnce(&mut config::schema::GlobalConfig) -> Result<Option<String>>,
{
    let old = st.cfg_snapshot();
    let mut cfg: Config = (*old).clone();
    let Some(change) = f(&mut cfg.global)? else {
        return Ok(json!({
            "saved": false,
            "changed": false,
            "note": "新值与当前配置相同：未写盘，也未触发事务",
        }));
    };
    let mut store = ConfigStore::load(&st.paths.config)?;
    let report = store.save(&cfg)?;
    adopt_config(st, &old, cfg);
    logging::info_ctx(
        "rpc",
        op,
        &format!("{op}：{change}（uid {}）", caller.uid),
        &[("caller", caller.uid.to_string())],
    );
    let receipt = cycle_via_loop(st, op).await?;
    Ok(json!({
        "saved": true,
        "changed": true,
        "change": change,
        "report": report,
        "receipt": receipt,
        "note": "已写盘并触发一轮事务；receipt 是回执原样透传，不是布尔值",
    }))
}

/// 切换工作模式（`balance` / `failover`）。
async fn h_switch_mode(st: &AppState, params: &Value, caller: Caller) -> Result<Value> {
    let raw = param_str(params, "mode")?;
    let Some(mode) = config::schema::Mode::parse(raw) else {
        return Err(Error::Validate(format!(
            "未知模式 {raw}（应为 balance 或 failover）"
        )));
    };
    mutate_global(st, caller, "switchMode", move |g| {
        if g.mode == mode {
            return Ok(None);
        }
        let old = g.mode.as_str();
        let text = format!("mode: {old} → {}", mode.as_str());
        g.mode = mode;
        Ok(Some(text))
    })
    .await
}

/// 设置主线路（主备模式的「主」）。
async fn h_set_primary(st: &AppState, params: &Value, caller: Caller) -> Result<Value> {
    let wan = param_str(params, "wan")?;
    {
        let cfg = st.cfg_snapshot();
        let w = cfg
            .wan(wan)
            .ok_or_else(|| Error::Validate(format!("线路 {wan} 不存在")))?;
        if !w.enabled {
            return Err(Error::Validate(format!(
                "线路 {wan} 已停用，不能设为主线路"
            )));
        }
        // 与 validate.rs 的同一条规则保持一致：主线路不得同时排在备用列表里。
        // 这里刻意**不顺手**把它从 backup_order 摘掉 —— 那是替用户改第二处配置，
        // 界面上看不见，用户也不会知道自己的备用顺序被动过。
        if cfg.global.backup_order.iter().any(|n| n == wan) {
            return Err(Error::Validate(format!(
                "线路 {wan} 已出现在 backup_order 中：请先用 setBackupOrder 移除"
            )));
        }
    }
    mutate_global(st, caller, "setPrimary", move |g| {
        if g.primary == wan {
            return Ok(None);
        }
        let old = if g.primary.is_empty() {
            "（未设置）".to_string()
        } else {
            g.primary.clone()
        };
        let text = format!("primary: {old} → {wan}");
        g.primary = wan.to_string();
        Ok(Some(text))
    })
    .await
}

/// 设置备用线路顺序（越靠前越优先接管）。
async fn h_set_backup_order(st: &AppState, params: &Value, caller: Caller) -> Result<Value> {
    let order = param_str_list(params, "order")?;
    if order.is_empty() {
        return Err(Error::Validate(
            "order 不能为空：主备模式至少要有一条备用线路（没有备用线路请改用 switchMode 切到均衡模式）"
                .into(),
        ));
    }
    {
        let cfg = st.cfg_snapshot();
        for (i, n) in order.iter().enumerate() {
            if cfg.wan(n).is_none() {
                return Err(Error::Validate(format!("order[{i}] 的线路 {n} 不存在")));
            }
            if *n == cfg.global.primary {
                return Err(Error::Validate(format!(
                    "order[{i}] 的 {n} 是主线路：主线路不得同时作为备用"
                )));
            }
            if order[..i].contains(n) {
                return Err(Error::Validate(format!("order[{i}] 的 {n} 重复出现")));
            }
        }
    }
    mutate_global(st, caller, "setBackupOrder", move |g| {
        if g.backup_order == order {
            return Ok(None);
        }
        let old = if g.backup_order.is_empty() {
            "（空）".to_string()
        } else {
            g.backup_order.join(" → ")
        };
        let text = format!("backup_order: {old} → {}", order.join(" → "));
        g.backup_order = order.clone();
        Ok(Some(text))
    })
    .await
}

/// 设置均衡算法。
async fn h_set_algorithm(st: &AppState, params: &Value, caller: Caller) -> Result<Value> {
    let raw = param_str(params, "algorithm")?;
    let Some(alg) = config::schema::Algorithm::parse(raw) else {
        return Err(Error::Validate(format!(
            "未知算法 {raw}（可取值的中文说明见前端算法下拉框，机器值见 getConfig）"
        )));
    };
    // 诚实提示：加权 ECMP 依赖内核能力，能力不足时事务会走降级路径。
    // 真正生效的算法以 getBalance.algorithm 为准，这里不能宣称「已设为 ECMP」。
    let hint = if alg == config::schema::Algorithm::WeightedEcmp {
        "weighted_ecmp 需内核 MULTIPATH 与 ip-full 支持；能力不足时会在下发时降级，实际生效算法以 getBalance.algorithm 为准"
    } else {
        ""
    };
    let mut v = mutate_global(st, caller, "setAlgorithm", move |g| {
        if g.algorithm == alg {
            return Ok(None);
        }
        let old = g.algorithm.as_str();
        let text = format!("algorithm: {old} → {}", alg.as_str());
        g.algorithm = alg;
        Ok(Some(text))
    })
    .await?;
    if !hint.is_empty() {
        v["hint"] = json!(hint);
    }
    Ok(v)
}

/// 手动回切：立刻把活动线路切回主线路（跳过回切延迟与去抖等待）。
///
/// 与 `forceWan` 的区别要说清楚，否则两个方法会互相打架：`forceWan` 表达的是
/// **持久意志**（目标暂不可用也保留指令，恢复后立即生效），而回切是**即时动作** ——
/// 主线路此刻不够格就如实回答「没切」，不留一条将来悄悄生效的指令。
async fn h_failback(st: &AppState) -> Result<Value> {
    let cfg = st.cfg_snapshot();
    if cfg.global.mode != config::schema::Mode::Failover {
        return Err(Error::Validate(
            "手动回切只在主备（failover）模式下有意义；均衡模式下流量按算法分配，不存在「回切」"
                .into(),
        ));
    }
    let primary = cfg.global.primary.clone();
    if primary.is_empty() {
        return Err(Error::Validate(
            "未配置主线路（global.primary 为空），无法回切".into(),
        ));
    }
    if cfg.wan(&primary).is_none() {
        return Err(Error::Validate(format!("主线路 {primary} 不存在")));
    }

    // 判定「此刻够不够格当活动线路」用的是调度器的同一套判据，不在 RPC 里另写一份：
    // 两套判据迟早会给出不同答案，那时界面与内核会各说各话。
    let snap = read_lock(&st.snap).clone();
    let (usable, reason, active_now) = {
        let sched = st.scheduler.lock().unwrap_or_else(|p| p.into_inner());
        let lines = sched.line_states(&cfg, &snap, logging::now_ms())?;
        let line = lines.iter().find(|l| l.name == primary);
        (
            line.map(|l| l.usable_as_active()).unwrap_or(false),
            line.and_then(|l| l.unusable_reason()),
            sched.active().map(str::to_string),
        )
    };
    if !usable {
        return Ok(json!({
            "switched": false,
            "active": active_now,
            "primary": primary,
            "reason": reason.unwrap_or_else(|| "主线路当前不可用作活动线路".to_string()),
            "note": "回切是即时动作：主线路不够格就不切换，也不会留下一条将来悄悄生效的指令",
        }));
    }
    // 够格：把主线路设为强制目标。强制只是「优先」，不影响后续故障切换
    // （主线路再次不可用时仍会按自动顺序往下选），所以这里不会把网络锁死。
    {
        let mut sched = st.scheduler.lock().unwrap_or_else(|p| p.into_inner());
        sched.force(&primary);
    }
    let receipt = cycle_via_loop(st, "failback").await?;
    let active_after = {
        let sched = st.scheduler.lock().unwrap_or_else(|p| p.into_inner());
        sched.active().map(str::to_string)
    };
    Ok(json!({
        "switched": active_after.as_deref() == Some(primary.as_str()),
        "active": active_after,
        "primary": primary,
        "receipt": receipt,
        "note": "已请求回切；若 switched=false 请读 receipt 的 issues 与 notes（例如最小切换间隔未满足）",
    }))
}

/// 聚合只读诊断：把排障时人们会挨个点的几个只读方法合成一屏。
///
/// 刻意**不**触发探测、不下发、不重载配置 —— 读方法零副作用
/// （`docs/HANDOVER.md` §2.9）。要立即探测请调 `probeNow`，那是有副作用的方法。
async fn h_diagnostics(st: &AppState) -> Result<Value> {
    let cfg = st.cfg_snapshot();
    let snap = read_lock(&st.snap).clone();
    let caps = read_lock(&st.caps).clone();
    let conns = read_lock(&st.conns).clone();
    let receipt = read_lock(&st.receipt).clone();
    let outcome = read_lock(&st.outcome).clone();
    let report = validate::validate(&cfg);
    let dns = st.dns.lock().unwrap_or_else(|p| p.into_inner()).stats();

    let issues = |v: Vec<&validate::Issue>| -> Vec<Value> {
        v.iter()
            .map(|i| json!({ "path": i.path, "message": i.message }))
            .collect()
    };
    let lines: Vec<Value> = cfg
        .wans
        .iter()
        .map(|w| {
            let h = snap.get(&w.name);
            json!({
                "name": w.name,
                "enabled": w.enabled,
                "maintenance": w.maintenance,
                "state": h.map(|x| x.state.as_str()).unwrap_or("unknown"),
                "blocked_reason": h.and_then(|x| x.blocked_reason.clone()),
                "metrics": h.and_then(|x| x.metrics.as_ref()).map(metrics_json),
            })
        })
        .collect();

    Ok(json!({
        "protocol": RPC_PROTOCOL,
        "schema_version": crate::CONFIG_SCHEMA_VERSION,
        "uptime_ms": st.started.elapsed().as_millis() as u64,
        "enabled": cfg.global.enabled,
        "mode": cfg.global.mode.as_str(),
        "config_valid": report.is_valid(),
        "errors": issues(report.errors()),
        "warnings": issues(report.warnings()),
        "capabilities_degraded": degraded_syntax(&caps),
        "firewall_channel": st.coordinator.plane().fw.describe(),
        "lines": lines,
        "conntrack": conns.limits.as_ref().map(|l| json!({
            "count": l.count,
            "max": l.max,
            "used_permille": l.used_permille(),
            "tight": l.tight(),
        })),
        "dns": {
            "domains": dns.domains,
            "elements": dns.elements,
            "stale_domains": dns.stale_domains,
            "failed_notfound": dns.failed_notfound,
            "failed_timeout": dns.failed_timeout,
            "failed_local": dns.failed_local,
            "rejected_total": dns.rejected_total,
        },
        "last_receipt": receipt,
        "decision": outcome.as_ref().map(|o| json!({
            "reason": o.reason,
            "notes": o.notes,
            "changed": o.changed,
            "at_ms": o.at_ms,
        })),
        "recent_warnings": logging::recent(Some(logging::Level::Warn), 20),
        "log_dropped": logging::dropped(),
        "note": "只读聚合视图：不触发探测、不下发、不重载；逐项细节仍以对应的 get* 方法为准",
    }))
}

/// 让主循环跑一轮「决策 + 提交」并把回执原样带回。
async fn cycle_via_loop(st: &AppState, op: &str) -> Result<Value> {
    let (tx, rx) = oneshot::channel();
    st.ctl
        .send(Command::Cycle(tx))
        .map_err(|_| Error::Io(std::io::Error::other("守护主循环未运行")))?;
    let receipt = tokio::time::timeout(COMMAND_TIMEOUT, rx)
        .await
        .map_err(|_| Error::Timeout {
            operation: op.into(),
            elapsed_ms: COMMAND_TIMEOUT.as_millis() as u64,
        })?
        .map_err(|_| Error::Io(std::io::Error::other("主循环丢弃了请求")))?;
    Ok(serde_json::to_value(&receipt)?)
}

// ==================== 展示助手 ====================

/// 状态中文标签。机器可读值仍是 `State::as_str()`，标签只给 UI。
fn state_label(s: State) -> &'static str {
    match s {
        State::Unknown => "未测量",
        State::Healthy => "健康",
        State::Degraded => "降级",
        State::Failed => "故障",
        State::Recovering => "恢复预热中",
    }
}

fn metrics_json(m: &health::Metrics) -> Value {
    json!({
        "samples": m.samples,
        "ok_samples": m.ok_samples,
        "loss_pmm": m.loss_pmm,
        "rtt_ms": m.rtt_ms,
        "min_ms": m.min_ms,
        "max_ms": m.max_ms,
        "p95_ms": m.p95_ms,
        "jitter_ms": m.jitter_ms,
        "instability_pmm": m.instability_pmm,
        "age_ms": m.age_ms,
        "confident": m.confident(),
    })
}

/// 供 main 与测试共用的「用替身拼出最小 AppState」。
#[doc(hidden)]
pub mod testable {
    use super::*;
    use crate::system::firewall::Nft;
    use crate::system::netlink::FakeNetlink;
    use crate::transaction::FirewallExec;

    /// 返回 state 与 Command 接收端。**留着接收端**，写方法就能收到命令；
    /// drop 掉它即模拟「主循环没在跑」。
    pub fn test_state(dir: &Path) -> (Arc<AppState>, mpsc::UnboundedReceiver<Command>) {
        let ops: Arc<dyn crate::system::netlink::RouteOps> = Arc::new(FakeNetlink::new());
        let plane = crate::transaction::Plane {
            ops,
            fw: FirewallExec::Sim(crate::transaction::Sim::new()),
            env: crate::system::Env {
                etc_dir: dir.to_path_buf(),
                sysfs: crate::system::interface::SysFs::new(dir),
            },
            caps: Capabilities::default(),
            config_path: dir.join("smartmwan"),
            state_dir: dir.join("state"),
            presets_dir: dir.join("presets"),
        };
        let (ctl_tx, ctl_rx) = mpsc::unbounded_channel();
        let st = AppState {
            coordinator: Arc::new(Coordinator::new(plane)),
            registry: Arc::new(Registry::new()),
            scheduler: Arc::new(Mutex::new(Scheduler::new())),
            cfg: Arc::new(RwLock::new(Arc::new(Config::default()))),
            snap: Arc::new(RwLock::new(Snapshot::default())),
            ob: Arc::new(RwLock::new(None)),
            loads: Arc::new(RwLock::new(BTreeMap::new())),
            traffic: Arc::new(RwLock::new(TrafficView {
                cur: TrafficSample::default(),
                prev: None,
            })),
            conns: Arc::new(RwLock::new(ConnView {
                cur: Counts::default(),
                prev: None,
                limits: None,
            })),
            receipt: Arc::new(RwLock::new(None)),
            outcome: Arc::new(RwLock::new(None)),
            decision: Arc::new(RwLock::new(Decision::default())),
            last_round: Arc::new(Mutex::new(None)),
            caps: Arc::new(RwLock::new(Capabilities::default())),
            dns: Arc::new(Mutex::new(rules::dns_sets::Registry::new(
                Duration::from_secs(300),
                1024,
            ))),
            hits: Arc::new(RwLock::new(rules::GameHits::default())),
            ctl: ctl_tx,
            paths: Paths {
                config: dir.join("smartmwan"),
                state_dir: dir.join("state"),
                socket: dir.join("rpc.sock"),
            },
            started: Instant::now(),
            acl: Acl::root_only(),
            nft: None,
        };
        (Arc::new(st), ctl_rx)
    }

    /// 测试用 Nft 替身句柄（不执行任何命令）。
    pub fn fake_nft(dir: &Path) -> Arc<Nft> {
        Arc::new(Nft::with_program("", dir))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream as StdUnixStream;
    use tokio::io::DuplexStream;

    fn root() -> Caller {
        Caller {
            uid: 0,
            gid: 0,
            pid: 1,
        }
    }

    fn stranger() -> Caller {
        Caller {
            uid: 1000,
            gid: 1000,
            pid: 2,
        }
    }

    async fn call(st: &AppState, method: &str, params: Value) -> Envelope {
        dispatch(st, root(), method, params).await
    }

    #[test]
    fn method_table_matches_architecture_doc() {
        // 任务书 6.1：不少于 19 个方法（该判据是编译期常量，见下方匿名常量断言）。
        assert_eq!(METHOD_COUNT, METHODS.len());
        // 唯一性：重名会让分发不确定。
        let mut names: Vec<&str> = METHODS.iter().map(|(n, _)| *n).collect();
        names.sort_unstable();
        let total = names.len();
        names.dedup();
        assert_eq!(names.len(), total, "方法表里有重名");
        // 全部带命名空间前缀，前端按前缀过滤。
        for (n, _) in METHODS {
            assert!(n.starts_with("smartmwan."), "方法 {n} 缺少命名空间");
        }
        // 文档表里的 29 条必须一个不少（顺序无关）。
        for expected in [
            "smartmwan.hello",
            "smartmwan.getStatus",
            "smartmwan.getLines",
            "smartmwan.getLine",
            "smartmwan.getBalance",
            "smartmwan.getFailover",
            "smartmwan.getGames",
            "smartmwan.getGameQuality",
            "smartmwan.getConnections",
            "smartmwan.getTraffic",
            "smartmwan.getLogs",
            "smartmwan.getConfig",
            "smartmwan.getCapabilities",
            "smartmwan.validate",
            "smartmwan.diff",
            "smartmwan.save",
            "smartmwan.apply",
            "smartmwan.rollback",
            "smartmwan.forceWan",
            "smartmwan.releaseForced",
            "smartmwan.setMaintenance",
            "smartmwan.probeNow",
            "smartmwan.reload",
            "smartmwan.switchMode",
            "smartmwan.setPrimary",
            "smartmwan.setBackupOrder",
            "smartmwan.setAlgorithm",
            "smartmwan.failback",
            "smartmwan.diagnostics",
        ] {
            assert!(method_kind(expected).is_some(), "缺少方法 {expected}");
        }
        // 写方法必须被标成 Write（否则不进审计）。
        for w in [
            "smartmwan.save",
            "smartmwan.apply",
            "smartmwan.rollback",
            "smartmwan.forceWan",
            "smartmwan.releaseForced",
            "smartmwan.setMaintenance",
            "smartmwan.reload",
            "smartmwan.probeNow",
            "smartmwan.switchMode",
            "smartmwan.setPrimary",
            "smartmwan.setBackupOrder",
            "smartmwan.setAlgorithm",
            "smartmwan.failback",
        ] {
            assert_eq!(method_kind(w), Some(Kind::Write), "{w} 必须是写方法");
        }
        for r in [
            "smartmwan.hello",
            "smartmwan.getStatus",
            "smartmwan.diff",
            "smartmwan.diagnostics",
        ] {
            assert_eq!(method_kind(r), Some(Kind::Read), "{r} 必须是读方法");
        }
    }

    #[test]
    fn envelope_shape_matches_protocol() {
        let ok = Envelope::ok_data(json!({"a": 1}));
        let v = serde_json::to_value(&ok).unwrap();
        assert_eq!(v["ok"], json!(true));
        assert_eq!(v["protocol"], json!(RPC_PROTOCOL));
        assert_eq!(v["data"], json!({"a": 1}));
        assert!(v.get("error").is_none(), "成功响应不得带 error 字段");
        assert!(v["timestamp"].as_u64().unwrap() > 0);

        let bad = Envelope::err("validate", "坏了".into(), vec!["细节".into()]);
        let v = serde_json::to_value(&bad).unwrap();
        assert_eq!(v["ok"], json!(false));
        assert!(v.get("data").is_none(), "失败响应不得带 data 字段");
        assert_eq!(v["error"]["code"], json!("validate"));
        assert_eq!(v["error"]["message"], json!("坏了"));
        assert_eq!(v["error"]["details"], json!(["细节"]));
    }

    #[test]
    fn error_codes_are_the_stable_twelve() {
        // 前端按 code 分流；这里锁死「内部错误 → 稳定码」的映射。
        let cases: Vec<(Error, &str)> = vec![
            (Error::Config("x".into()), "config"),
            (Error::Validate("x".into()), "validate"),
            (Error::Netlink("x".into()), "netlink"),
            (Error::Firewall("x".into()), "firewall"),
            (
                Error::Exec {
                    cmd: "nft".into(),
                    reason: "x".into(),
                },
                "exec",
            ),
            (Error::Rollback("x".into()), "rollback"),
            (Error::Permission("x".into()), "permission"),
            (Error::Unsupported("x".into()), "unsupported"),
            (
                Error::Timeout {
                    operation: "x".into(),
                    elapsed_ms: 1,
                },
                "timeout",
            ),
            (
                Error::NoRoute {
                    wan: "x".into(),
                    reason: "y".into(),
                },
                "no_route",
            ),
            (
                Error::Io(std::io::Error::new(std::io::ErrorKind::NotFound, "x")),
                "io",
            ),
        ];
        for (e, code) in cases {
            let env = Envelope::from_error(&e);
            let got = env.error.expect("错误信封必须带 error").code;
            assert_eq!(got, code, "{e} 映射错了");
        }
    }

    #[tokio::test]
    async fn frame_roundtrip_over_duplex() {
        let (mut a, mut b): (DuplexStream, DuplexStream) = tokio::io::duplex(4096);
        let payload = json!({"ok": true, "big": "中".repeat(1000)});
        let bytes = encode_frame(&payload).unwrap();
        assert_eq!(&bytes[..4], &(bytes.len() as u32 - 4).to_be_bytes());
        write_frame(&mut a, &bytes).await.unwrap();
        let got = read_frame(&mut b).await.unwrap().unwrap();
        assert_eq!(serde_json::from_slice::<Value>(&got).unwrap(), payload);
    }

    #[tokio::test]
    async fn zero_and_oversized_frames_are_rejected() {
        let (mut a, mut b): (DuplexStream, DuplexStream) = tokio::io::duplex(64);
        a.write_all(&0u32.to_be_bytes()).await.unwrap();
        assert!(read_frame(&mut b).await.is_err(), "零长度帧必须拒绝");

        let (mut c, mut d): (DuplexStream, DuplexStream) = tokio::io::duplex(64);
        c.write_all(&(MAX_FRAME_BYTES as u32 + 1).to_be_bytes())
            .await
            .unwrap();
        let err = read_frame(&mut d).await.expect_err("超大帧必须拒绝");
        assert!(
            err.to_string().contains("帧过大"),
            "错误信息要说明原因: {err}"
        );
    }

    #[tokio::test]
    async fn eof_before_any_byte_is_clean_close() {
        let (a, mut b): (DuplexStream, DuplexStream) = tokio::io::duplex(64);
        drop(a);
        assert!(read_frame(&mut b).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn unknown_method_gets_json_error() {
        let dir = tempfile::tempdir().unwrap();
        let (st, _rx) = testable::test_state(dir.path());
        let env = call(&st, "smartmwan.nope", json!({})).await;
        assert!(!env.ok);
        assert_eq!(env.error.unwrap().code, "json");
    }

    #[tokio::test]
    async fn stranger_uid_is_denied_before_dispatch() {
        let dir = tempfile::tempdir().unwrap();
        let (st, _rx) = testable::test_state(dir.path());
        let env = dispatch(&st, stranger(), "smartmwan.hello", json!({})).await;
        assert!(!env.ok);
        let e = env.error.unwrap();
        assert_eq!(e.code, "permission");
        assert!(e.message.contains("1000"), "错误信息要带上是哪个 uid");
    }

    #[tokio::test]
    async fn read_methods_answer_without_daemon_loop() {
        let dir = tempfile::tempdir().unwrap();
        let (st, _rx) = testable::test_state(dir.path());
        for m in [
            "smartmwan.hello",
            "smartmwan.getStatus",
            "smartmwan.getLines",
            "smartmwan.getBalance",
            "smartmwan.getFailover",
            "smartmwan.getGames",
            "smartmwan.getGameQuality",
            "smartmwan.getConnections",
            "smartmwan.getTraffic",
            "smartmwan.getLogs",
            "smartmwan.getConfig",
            "smartmwan.getCapabilities",
            "smartmwan.diff",
        ] {
            let env = call(&st, m, json!({})).await;
            assert!(env.ok, "{m} 应成功，实际: {:?}", env.error);
        }
        // 首轮未测量时，状态必须自报「未测量」而不是绿油油的健康。
        let env = call(&st, "smartmwan.getStatus", json!({})).await;
        assert_eq!(env.data.unwrap()["measured"], json!(false));
    }

    #[tokio::test]
    async fn write_method_without_loop_reports_clearly() {
        let dir = tempfile::tempdir().unwrap();
        // 接收端立即 drop：模拟主循环没在跑。
        let (st, rx) = testable::test_state(dir.path());
        drop(rx);
        let env = call(&st, "smartmwan.apply", json!({})).await;
        assert!(!env.ok, "主循环不在时 apply 必须报错，不能假装成功");
        assert!(!env.error.unwrap().message.is_empty());
    }

    #[tokio::test]
    async fn force_wan_validates_target_and_mode() {
        let dir = tempfile::tempdir().unwrap();
        let (st, _rx) = testable::test_state(dir.path());
        // 默认配置是均衡模式 + 没有线路。
        let env = call(&st, "smartmwan.forceWan", json!({"wan": "wan1"})).await;
        assert!(!env.ok);
        let e = env.error.unwrap();
        assert_eq!(e.code, "validate");
        assert!(
            e.message.contains("不存在") || e.message.contains("主备"),
            "{e:?}"
        );
    }

    #[tokio::test]
    async fn missing_params_are_validate_errors() {
        let dir = tempfile::tempdir().unwrap();
        let (st, _rx) = testable::test_state(dir.path());
        let env = call(&st, "smartmwan.getLine", json!({})).await;
        assert!(!env.ok);
        assert_eq!(env.error.unwrap().code, "validate");
        // save 没有 config 参数同理。
        let env = call(&st, "smartmwan.save", json!({})).await;
        assert!(!env.ok);
        assert_eq!(env.error.unwrap().code, "validate");
    }

    #[tokio::test]
    async fn validate_does_not_write_anything() {
        let dir = tempfile::tempdir().unwrap();
        let (st, _rx) = testable::test_state(dir.path());
        let cfg = Config::default();
        let before = std::fs::read_dir(dir.path()).unwrap().count();
        let env = call(
            &st,
            "smartmwan.validate",
            json!({"config": serde_json::to_value(&cfg).unwrap()}),
        )
        .await;
        assert!(env.ok);
        let after = std::fs::read_dir(dir.path()).unwrap().count();
        assert_eq!(before, after, "validate 不得落任何文件");
        assert_eq!(env.data.unwrap()["valid"], json!(true));
    }

    #[test]
    fn redact_masks_secret_keys_recursively() {
        let p = json!({
            "wan": "wan1",
            "nested": {"password": "hunter2", "keep": 1},
            "list": [{"token": "abc"}, {"note": "ok"}],
            "api_key": "k",
        });
        let s = redact_params(&p);
        assert!(!s.contains("hunter2"), "密码不能进日志: {s}");
        assert!(!s.contains("\"abc\""), "token 不能进日志: {s}");
        assert!(!s.contains("\"k\""), "key 不能进日志: {s}");
        assert!(s.contains("wan1"));
        assert!(s.contains("ok"));
    }

    #[test]
    fn wwwdata_uid_is_read_from_passwd_not_guessed() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("passwd");
        std::fs::write(
            &p,
            "root:x:0:0:root:/root:/bin/ash\nwwwdata:x:33:33:www:/var:/bin/false\n",
        )
        .unwrap();
        assert_eq!(wwwdata_uid(&p), Some(33));
        assert!(Acl::system_default(&p).allows(33));
        assert!(Acl::system_default(&p).allows(0));
        assert!(!Acl::system_default(&p).allows(1000));
        // 文件不存在时只允许 root，不猜值。
        let missing = dir.path().join("nope");
        assert_eq!(wwwdata_uid(&missing), None);
        assert!(!Acl::system_default(&missing).allows(33));
    }

    #[test]
    fn peer_cred_works_on_real_socketpair() {
        let (a, b) = StdUnixStream::pair().unwrap();
        use std::os::unix::io::AsRawFd;
        let c = peer_cred(a.as_raw_fd()).expect("socketpair 必须能拿到凭证");
        assert_eq!(c.uid, unsafe { libc::getuid() });
        assert_eq!(c.gid, unsafe { libc::getgid() });
        assert!(c.pid > 0);
        drop(b);
        // 明显非法的 fd 必须返回 None（调用方据此拒绝服务）。
        assert!(peer_cred(-1).is_none());
    }

    #[tokio::test]
    async fn get_lines_marks_unmeasured_honestly() {
        let dir = tempfile::tempdir().unwrap();
        let (st, _rx) = testable::test_state(dir.path());
        // 放一条线路进配置，但不给任何健康数据。
        let mut cfg = Config::default();
        cfg.wans.push(crate::config::schema::WanConfig {
            name: "wan1".into(),
            enabled: true,
            ..Default::default()
        });
        *write_lock(&st.cfg) = Arc::new(cfg);
        let env = call(&st, "smartmwan.getLines", json!({})).await;
        assert!(env.ok);
        let data = env.data.unwrap();
        assert_eq!(data["lines"][0]["name"], json!("wan1"));
        // 没有探测过：状态必须是 unknown/未测量，不能是 healthy。
        assert_eq!(data["lines"][0]["state"], json!("unknown"));
        assert_eq!(data["lines"][0]["state_label"], json!("未测量"));
        assert_eq!(data["measured"], json!(false));
    }

    /// 两条已启用线路的最小配置（便捷写方法都要求线路真实存在）。
    fn two_wan_cfg() -> Config {
        let mut cfg = Config::default();
        for n in ["wan1", "wan2"] {
            cfg.wans.push(crate::config::schema::WanConfig {
                name: n.into(),
                enabled: true,
                ..Default::default()
            });
        }
        cfg
    }

    /// 主循环替身：把收到的 Cycle 累计次数发出去，并回一条空回执。
    fn spawn_cycle_echo(
        mut rx: mpsc::UnboundedReceiver<Command>,
    ) -> mpsc::UnboundedReceiver<usize> {
        let (tx, out) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            let mut n = 0usize;
            while let Some(cmd) = rx.recv().await {
                if let Command::Cycle(back) = cmd {
                    n += 1;
                    let _ = tx.send(n);
                    let _ = back.send(Receipt::default());
                }
            }
        });
        out
    }

    #[tokio::test]
    async fn switch_mode_persists_and_only_writes_when_it_really_changes() {
        let dir = tempfile::tempdir().unwrap();
        let (st, rx) = testable::test_state(dir.path());
        *write_lock(&st.cfg) = Arc::new(two_wan_cfg());
        let mut cycles = spawn_cycle_echo(rx);

        let env = call(&st, "smartmwan.switchMode", json!({ "mode": "failover" })).await;
        assert!(env.ok, "switchMode 应成功：{:?}", env.error);
        let d = env.data.unwrap();
        assert_eq!(d["saved"], json!(true));
        assert_eq!(d["change"], json!("mode: balance → failover"));
        // 落盘才算数：只改内存槽会在重启后丢设置。
        let on_disk = ConfigStore::load(&st.paths.config).unwrap().config;
        assert_eq!(on_disk.global.mode.as_str(), "failover");
        assert_eq!(cycles.recv().await, Some(1), "变更应触发一轮事务");

        // 同值再调：不写盘也不下发（不变式 2.5：没有 diff 就没有数据面写入）。
        let env = call(&st, "smartmwan.switchMode", json!({ "mode": "failover" })).await;
        let d = env.data.unwrap();
        assert_eq!(d["saved"], json!(false));
        assert_eq!(d["changed"], json!(false));
        assert!(cycles.try_recv().is_err(), "同值调用不得产生事务");
    }

    #[tokio::test]
    async fn set_primary_refuses_lines_that_cannot_be_primary() {
        let dir = tempfile::tempdir().unwrap();
        let (st, _rx) = testable::test_state(dir.path());
        let mut cfg = two_wan_cfg();
        cfg.global.backup_order = vec!["wan2".into()];
        *write_lock(&st.cfg) = Arc::new(cfg);

        for (wan, why) in [("nope", "不存在的线路"), ("wan2", "已在备用列表里的线路")]
        {
            let env = call(&st, "smartmwan.setPrimary", json!({ "wan": wan })).await;
            assert!(!env.ok, "{why} 必须被拒");
            assert_eq!(env.error.as_ref().unwrap().code, "validate");
        }

        let mut cfg = (*st.cfg_snapshot()).clone();
        cfg.wans[0].enabled = false;
        *write_lock(&st.cfg) = Arc::new(cfg);
        let env = call(&st, "smartmwan.setPrimary", json!({ "wan": "wan1" })).await;
        assert!(!env.ok, "已停用的线路不能当主线路");
        assert!(env.error.unwrap().message.contains("已停用"));
    }

    #[tokio::test]
    async fn set_backup_order_refuses_bad_orders() {
        let dir = tempfile::tempdir().unwrap();
        let (st, rx) = testable::test_state(dir.path());
        // 合法的那一笔会真的触发事务，所以主循环替身必须回话（否则等到 90 秒超时）。
        let _cycles = spawn_cycle_echo(rx);
        let mut cfg = two_wan_cfg();
        cfg.global.primary = "wan1".into();
        *write_lock(&st.cfg) = Arc::new(cfg);

        for (order, why) in [
            (json!([]), "空数组"),
            (json!(["ghost"]), "不存在的线路"),
            (json!(["wan1"]), "主线路本身"),
            (json!(["wan2", "wan2"]), "重复项"),
        ] {
            let env = call(&st, "smartmwan.setBackupOrder", json!({ "order": order })).await;
            assert!(!env.ok, "{why} 必须被拒：{order}");
            assert_eq!(env.error.as_ref().unwrap().code, "validate");
        }

        // 合法顺序要真的落盘（主循环替身只需回一次回执）。
        let env = call(
            &st,
            "smartmwan.setBackupOrder",
            json!({ "order": ["wan2"] }),
        )
        .await;
        assert!(env.ok, "合法顺序应被接受：{:?}", env.error);
        assert_eq!(env.data.unwrap()["saved"], json!(true));
        let on_disk = ConfigStore::load(&st.paths.config).unwrap().config;
        assert_eq!(on_disk.global.backup_order, vec!["wan2".to_string()]);
    }

    #[tokio::test]
    async fn set_algorithm_warns_about_possible_degradation() {
        let dir = tempfile::tempdir().unwrap();
        let (st, rx) = testable::test_state(dir.path());
        *write_lock(&st.cfg) = Arc::new(two_wan_cfg());
        let _cycles = spawn_cycle_echo(rx);

        let env = call(
            &st,
            "smartmwan.setAlgorithm",
            json!({ "algorithm": "weighted_ecmp" }),
        )
        .await;
        assert!(env.ok, "{:?}", env.error);
        let d = env.data.unwrap();
        assert!(
            d["hint"].as_str().unwrap_or_default().contains("降级"),
            "可能降级的算法必须给提示：{d}"
        );

        // 普通算法不该带这句提示（提示泛滥等于没有提示）。
        let env = call(
            &st,
            "smartmwan.setAlgorithm",
            json!({ "algorithm": "src_ip" }),
        )
        .await;
        assert!(env.ok);
        assert!(env.data.unwrap().get("hint").is_none());

        let env = call(
            &st,
            "smartmwan.setAlgorithm",
            json!({ "algorithm": "nope" }),
        )
        .await;
        assert!(!env.ok, "未知算法必须报错");
    }

    #[tokio::test]
    async fn failback_is_immediate_and_leaves_nothing_pending() {
        let dir = tempfile::tempdir().unwrap();
        let (st, mut rx) = testable::test_state(dir.path());
        let mut cfg = two_wan_cfg();
        cfg.global.mode = crate::config::schema::Mode::Failover;
        cfg.global.primary = "wan1".into();
        *write_lock(&st.cfg) = Arc::new(cfg);

        // 没有任何探测数据 ⇒ 主线路此刻不够格：如实不切，
        // 而且**不往主循环塞任何东西**（回切是即时动作，不留将来生效的指令）。
        let env = call(&st, "smartmwan.failback", json!({})).await;
        assert!(env.ok, "不可用时是「没切」而不是失败：{:?}", env.error);
        let d = env.data.unwrap();
        assert_eq!(d["switched"], json!(false));
        assert!(
            !d["reason"].as_str().unwrap_or_default().is_empty(),
            "必须说明为什么没切：{d}"
        );
        assert!(rx.try_recv().is_err(), "没切就不该触发事务");

        // 均衡模式没有「回切」这回事。
        let mut cfg = (*st.cfg_snapshot()).clone();
        cfg.global.mode = crate::config::schema::Mode::Balance;
        *write_lock(&st.cfg) = Arc::new(cfg);
        let env = call(&st, "smartmwan.failback", json!({})).await;
        assert!(!env.ok);
        assert!(env.error.unwrap().message.contains("主备"));
    }

    #[tokio::test]
    async fn diagnostics_is_read_only_and_never_pokes_the_loop() {
        let dir = tempfile::tempdir().unwrap();
        let (st, mut rx) = testable::test_state(dir.path());
        *write_lock(&st.cfg) = Arc::new(two_wan_cfg());
        let env = call(&st, "smartmwan.diagnostics", json!({})).await;
        assert!(env.ok, "{:?}", env.error);
        let d = env.data.unwrap();
        assert_eq!(d["protocol"], json!(RPC_PROTOCOL));
        assert_eq!(d["mode"], json!("balance"));
        assert_eq!(d["lines"].as_array().unwrap().len(), 2);
        assert!(d["config_valid"].is_boolean());
        assert!(d.get("errors").is_some() && d.get("warnings").is_some());
        assert!(
            rx.try_recv().is_err(),
            "只读聚合视图不得触发探测、下发或重载"
        );
    }

    #[tokio::test]
    async fn get_games_reports_hits_as_null_until_they_are_really_read() {
        let dir = tempfile::tempdir().unwrap();
        let (st, _rx) = testable::test_state(dir.path());
        *write_lock(&st.cfg) = Arc::new(two_wan_cfg());

        // 从未采样：必须是 null + 说明，绝不能是 0（0 会被读成「规则没命中过」）。
        let env = call(&st, "smartmwan.getGames", json!({})).await;
        assert!(env.ok, "{:?}", env.error);
        let d = env.data.unwrap();
        assert_eq!(d["hits_at_ms"], json!(0));
        assert!(d["hits_note"].as_str().unwrap().contains("尚未采样"));

        // 采样到之后：按 slug 报数字。
        let mut per = std::collections::BTreeMap::new();
        per.insert("svc".to_string(), (3u64, 300u64));
        *write_lock(&st.hits) = rules::GameHits {
            per_rule: per,
            at_ms: 1234,
            note: String::new(),
        };
        let mut cfg = two_wan_cfg();
        cfg.games.push(crate::config::schema::GameRule {
            name: "svc".into(),
            enabled: true,
            ..Default::default()
        });
        *write_lock(&st.cfg) = Arc::new(cfg);
        let env = call(&st, "smartmwan.getGames", json!({})).await;
        let d = env.data.unwrap();
        assert_eq!(d["hits_at_ms"], json!(1234));
        assert_eq!(d["rules"][0]["hits"]["packets"], json!(3));
        assert_eq!(d["rules"][0]["hits"]["bytes"], json!(300));
    }

    #[tokio::test]
    async fn get_games_attributes_hits_by_compiled_slug_not_by_raw_name() {
        // 中文名 slug 为空、ASCII 名清洗后撞车都很常见；命中数必须按 compile 的消歧
        // 结果归属，否则界面会把 A 的流量记到 B 头上（或永远显示 null）。
        let dir = tempfile::tempdir().unwrap();
        let (st, _rx) = testable::test_state(dir.path());
        let mut cfg = two_wan_cfg();
        cfg.games = ["PUBG EU", "pubg-eu", "游戏"]
            .iter()
            .map(|n| crate::config::schema::GameRule {
                name: (*n).into(),
                enabled: true,
                ..Default::default()
            })
            .collect();
        *write_lock(&st.cfg) = Arc::new(cfg);

        let mut per = std::collections::BTreeMap::new();
        per.insert("pubg_eu".to_string(), (1u64, 10u64));
        per.insert("pubg_eu-2".to_string(), (2u64, 20u64));
        per.insert("rule".to_string(), (5u64, 50u64));
        *write_lock(&st.hits) = rules::GameHits {
            per_rule: per,
            at_ms: 1,
            note: String::new(),
        };

        let env = call(&st, "smartmwan.getGames", json!({})).await;
        assert!(env.ok, "{:?}", env.error);
        let d = env.data.unwrap();
        let rules = d["rules"].as_array().unwrap();
        let packets = |n: &str| {
            rules
                .iter()
                .find(|r| r["name"] == json!(n))
                .unwrap_or_else(|| panic!("缺少规则 {n}"))["hits"]["packets"]
                .clone()
        };
        assert_eq!(packets("PUBG EU"), json!(1));
        assert_eq!(packets("pubg-eu"), json!(2), "撞车后的那条必须拿 -2 的计数");
        assert_eq!(packets("游戏"), json!(5), "纯中文名兜底为 rule");
    }

    #[tokio::test]
    async fn receipt_is_passed_through_verbatim() {
        // apply 的响应体必须是 Receipt 原样（含 rollback 字段），不得压缩。
        let dir = tempfile::tempdir().unwrap();
        let (st, mut rx) = testable::test_state(dir.path());
        tokio::spawn(async move {
            if let Some(Command::Cycle(tx)) = rx.recv().await {
                let r = Receipt {
                    id: "T1-2-3".into(),
                    ok: false,
                    rollback: vec!["nft：内核现状需人工确认".into()],
                    ..Default::default()
                };
                let _ = tx.send(r);
            }
        });
        let env = call(&st, "smartmwan.apply", json!({})).await;
        assert!(env.ok, "回执非 Result：失败也要 ok=true 把回执送出去");
        let data = env.data.unwrap();
        assert_eq!(data["id"], json!("T1-2-3"));
        assert_eq!(data["ok"], json!(false));
        assert_eq!(data["rollback"][0], json!("nft：内核现状需人工确认"));
    }
}

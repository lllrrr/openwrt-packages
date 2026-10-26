//! 探测执行：ICMP / TCP 连接 / DNS 查询三种可达性与延迟测量。
//!
//! # 为什么区分「探测失败」的四种原因
//!
//! 把下面几件事混为一谈会造成严重后果 —— 误判断线 → 无谓切换 → 用户所有连接重连：
//!
//! | 结果 | 含义 | 上层是否算线路失败 |
//! |---|---|---|
//! | `Reply` | 对端响应 | 否（成功） |
//! | `Timeout` | 发出请求但无响应 | **是** |
//! | `Unreachable` | 内核立刻回报路由/网络不可达 | **是** |
//! | `Unsupported` | 设备不允许创建该类型 socket（权限/内核缺配置） | **否**，必须报为配置问题 |
//! | `LocalError` | 本机错误：域名解析失败、源地址不可用、socket 出错 | **否**，必须报为运行问题 |
//!
//! # 探测必须绑到正确的出口
//!
//! 多 WAN 环境下，不绑定接口/源地址的探测会走 main 表的默认路由，于是
//! 「wan2 的探测」实际从 wan1 出去，健康状态全线错误。这里用
//! `SO_BINDTODEVICE`（需要 root，本守护进程本来就是 root）并在可用时绑定源地址。
//!
//! # 探测流量本身不能压垮链路
//!
//! 并发上限由 `health.max_concurrent_probes` 控制（全局信号量），
//! 每个探测都有硬超时；整个批次再受一个批次 deadline 约束，
//! 关停时通过 `watch` 通道取消，不留悬挂 socket。

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::{watch, Semaphore};

use crate::config::schema::ProbeProto;
use crate::system::interface::Resolved;
use crate::system::netlink::Family;
use crate::{logging, Error, Result};

use super::metrics::Sample;

/// 把 `dyn Future` 装箱，避免引入 `async-trait` 依赖（依赖越少，交叉构建越稳）。
pub type BoxFuture<'a, T> = std::pin::Pin<Box<dyn std::future::Future<Output = T> + Send + 'a>>;

/// 探测目标：已经解析好的地址，或需要在探测前解析的域名。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Addr(IpAddr),
    Domain(String),
}

impl Target {
    pub fn text(&self) -> String {
        match self {
            Target::Addr(a) => a.to_string(),
            Target::Domain(d) => d.clone(),
        }
    }
}

/// 一次探测请求。
#[derive(Debug, Clone)]
pub struct Request {
    pub wan: String,
    /// 出口设备名（`SO_BINDTODEVICE`）。
    pub device: String,
    pub ifindex: u32,
    /// 源地址覆盖；`None` 时由内核按出口设备选择。
    pub src: Option<IpAddr>,
    pub target: Target,
    pub proto: ProbeProto,
    pub port: u16,
    pub timeout: Duration,
}

/// 探测结果类别。见模块头部的表。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Reply { rtt_ms: u32 },
    Timeout,
    Unreachable(String),
    Unsupported(String),
    LocalError(String),
}

impl Outcome {
    /// 是否应当作为「线路的一次失败探测」计入状态机。
    pub fn counts_as_line_failure(&self) -> bool {
        matches!(self, Outcome::Timeout | Outcome::Unreachable(_))
    }
    pub fn is_reply(&self) -> bool {
        matches!(self, Outcome::Reply { .. })
    }
    /// 面向运维的一句话说明；`Unsupported`/`LocalError` 必须能在此处被看到。
    pub fn describe(&self) -> String {
        match self {
            Outcome::Reply { rtt_ms } => format!("响应 {rtt_ms}ms"),
            Outcome::Timeout => "超时无响应".into(),
            Outcome::Unreachable(r) => format!("内核回报不可达: {r}"),
            Outcome::Unsupported(r) => format!("探测方式不受支持: {r}"),
            Outcome::LocalError(r) => format!("本机探测错误: {r}"),
        }
    }
}

/// 一次探测的完整结果。
#[derive(Debug, Clone)]
pub struct ProbeResult {
    pub req: Request,
    pub at_ms: u64,
    pub outcome: Outcome,
    /// 实际使用的目标地址（域名解析后）。
    pub resolved: Option<IpAddr>,
}

impl ProbeResult {
    /// 转成指标样本。`None` 表示这次结果不该进入健康判定。
    pub fn sample(&self) -> Option<Sample> {
        let proto = proto_tag(self.req.proto);
        match &self.outcome {
            Outcome::Reply { rtt_ms } => Some(Sample::success(self.at_ms, *rtt_ms, proto)),
            Outcome::Timeout | Outcome::Unreachable(_) => Some(Sample::failure(self.at_ms, proto)),
            _ => None,
        }
    }
}

pub fn proto_tag(p: ProbeProto) -> &'static str {
    match p {
        ProbeProto::Icmp => "icmp",
        ProbeProto::Tcp => "tcp",
        ProbeProto::Udp => "udp",
        ProbeProto::Dns => "dns",
    }
}

/// 探测器接口。单测里用假的实现注入确定的延迟/失败序列。
pub trait Prober: Send + Sync + 'static {
    fn probe(&self, req: Request) -> BoxFuture<'_, Result<ProbeResult>>;

    /// 剩余并发额度（`None` = 该实现不做并发限制）。
    ///
    /// 调度层用它把「探测请求数 > 并发上限」这件事说出来：探测本身会占用线路
    /// 带宽与 CPU，静默排队等于让探测负载变成不可见的隐形成本。
    fn free_permits(&self) -> Option<usize> {
        None
    }
}

/// 真实探测器：受全局并发信号量约束。
pub struct SystemProber {
    sem: Arc<Semaphore>,
    /// ICMP socket 是否可用；一旦确认不可用就不再反复尝试（避免每次探测都吃 EPERM）。
    icmp_ok: std::sync::atomic::AtomicU8,
}

/// `icmp_ok` 三态：0 未知 / 1 可用 / 2 不可用。
const ICMP_UNKNOWN: u8 = 0;
const ICMP_OK: u8 = 1;
const ICMP_DISABLED: u8 = 2;

impl SystemProber {
    pub fn new(max_concurrent: u16) -> SystemProber {
        SystemProber {
            sem: Arc::new(Semaphore::new((max_concurrent as usize).max(1))),
            icmp_ok: std::sync::atomic::AtomicU8::new(ICMP_UNKNOWN),
        }
    }
}

impl Prober for SystemProber {
    fn free_permits(&self) -> Option<usize> {
        Some(self.sem.available_permits())
    }

    fn probe(&self, req: Request) -> BoxFuture<'_, Result<ProbeResult>> {
        // `async move` 捕获的是 `&self`（一个引用值），因此返回的 future 生命周期
        // 与 `&self` 绑定，不需要额外把原子量再装箱一次。
        Box::pin(async move {
            let _permit =
                self.sem.acquire().await.map_err(|_| {
                    Error::Config("探测并发信号量已关闭（守护进程正在退出）".into())
                })?;
            // 域名先解析；解析失败是 LocalError，绝不能算成线路断线。
            let (addr, at_ms) = match resolve(&req).await {
                Err(e) => return Ok(local_error(&req, e)),
                Ok(v) => v,
            };
            let outcome = match req.proto {
                ProbeProto::Icmp => {
                    if self.icmp_ok.load(std::sync::atomic::Ordering::Relaxed) == ICMP_DISABLED {
                        Outcome::Unsupported("此前已确认设备不允许创建 ICMP socket".into())
                    } else {
                        let o = icmp_probe(&req, addr).await;
                        if matches!(o, Outcome::Unsupported(_)) {
                            self.icmp_ok
                                .store(ICMP_DISABLED, std::sync::atomic::Ordering::Relaxed);
                            logging::warn_ctx(
                                "health",
                                "icmp-capability",
                                "ICMP 探测不可用，健康判定需改用 tcp/dns 探测",
                                &[("wan", req.wan.clone()), ("reason", o.describe())],
                            );
                        } else {
                            self.icmp_ok
                                .store(ICMP_OK, std::sync::atomic::Ordering::Relaxed);
                        }
                        o
                    }
                }
                ProbeProto::Tcp => tcp_probe(&req, addr).await,
                ProbeProto::Udp => udp_probe(&req, addr).await,
                ProbeProto::Dns => dns_probe(&req, addr).await,
            };
            Ok(ProbeResult {
                req,
                at_ms,
                outcome,
                resolved: Some(addr),
            })
        })
    }
}

fn local_error(req: &Request, reason: String) -> ProbeResult {
    ProbeResult {
        req: req.clone(),
        at_ms: crate::logging::now_ms(),
        outcome: Outcome::LocalError(reason),
        resolved: None,
    }
}

/// 解析目标。域名解析放到阻塞线程，避免 DNS 卡住事件循环。
async fn resolve(req: &Request) -> std::result::Result<(IpAddr, u64), String> {
    match &req.target {
        Target::Addr(a) => Ok((*a, crate::logging::now_ms())),
        Target::Domain(d) => {
            let d = d.clone();
            let want_v6 = matches!(req.src, Some(IpAddr::V6(_)));
            let joined = tokio::task::spawn_blocking(move || {
                use std::net::ToSocketAddrs;
                let mut addrs: Vec<IpAddr> = Vec::new();
                match (d.as_str(), 0u16).to_socket_addrs() {
                    Ok(iter) => {
                        for sa in iter {
                            addrs.push(sa.ip());
                        }
                    }
                    Err(e) => return Err(format!("解析 {d} 失败: {e}")),
                }
                if addrs.is_empty() {
                    return Err(format!("{d} 没有可用地址记录"));
                }
                // 优先与源地址同族，其次 IPv4（多数探测目标仍为 IPv4）。
                let pick = addrs
                    .iter()
                    .find(|a| matches!(a, IpAddr::V6(_)) == want_v6)
                    .copied()
                    .unwrap_or(addrs[0]);
                Ok(pick)
            })
            .await
            .map_err(|e| format!("解析任务被中止: {e}"))??;
            Ok((joined, crate::logging::now_ms()))
        }
    }
}

/// 设置 `SO_BINDTODEVICE`。失败不阻断（部分虚拟接口不支持），但要记日志。
fn try_bind_device<S: std::os::fd::AsFd>(sock: &S, device: &str) -> Option<String> {
    use std::os::fd::AsRawFd;
    if device.is_empty() || device.len() > 15 {
        return None;
    }
    let name = std::ffi::CString::new(device).ok()?;
    let fd = sock.as_fd().as_raw_fd();
    // SO_BINDTODEVICE = 25（Linux 通用值）
    let rc = unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            25,
            name.as_ptr() as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t
                + name.to_bytes_with_nul().len() as libc::socklen_t
                - 1,
        )
    };
    if rc != 0 {
        let e = std::io::Error::last_os_error();
        return Some(format!("SO_BINDTODEVICE({device}) 失败: {e}"));
    }
    None
}

/// TCP 连接探测：成功即 `rtt = connect 耗时`。
async fn tcp_probe(req: &Request, addr: IpAddr) -> Outcome {
    let port = if req.port == 0 {
        req.proto.default_port()
    } else {
        req.port
    };
    let dst = SocketAddr::new(addr, port);
    let started = Instant::now();
    let sock = match addr {
        IpAddr::V4(_) => match tokio::net::TcpSocket::new_v4() {
            Ok(s) => s,
            Err(e) => return Outcome::LocalError(format!("创建 IPv4 socket 失败: {e}")),
        },
        IpAddr::V6(_) => match tokio::net::TcpSocket::new_v6() {
            Ok(s) => s,
            Err(e) => return Outcome::LocalError(format!("创建 IPv6 socket 失败: {e}")),
        },
    };
    if let Some(msg) = try_bind_device(&sock, &req.device) {
        logging::debug_ctx("health", "bind-device", &msg, &[("wan", req.wan.clone())]);
    }
    if let Some(src) = req.src {
        let bind_addr = SocketAddr::new(src, 0);
        if let Err(e) = sock.bind(bind_addr) {
            return Outcome::LocalError(format!("绑定源地址 {src} 失败: {e}"));
        }
    }
    let connect = sock.connect(dst);
    match tokio::time::timeout(req.timeout, connect).await {
        Err(_) => Outcome::Timeout,
        Ok(Err(e)) => classify_io_error(&e),
        Ok(Ok(_stream)) => Outcome::Reply {
            rtt_ms: elapsed_ms(started),
        },
    }
}

/// DNS 探测：发一个最小的 A/AAAA 查询，收到任何合法响应即算可达。
///
/// 选择 DNS 的原因：很多线路屏蔽 ICMP 但不屏蔽 53；用它做「可达性 + 延迟」
/// 比 TCP 连 443 更不容易被远端防火墙干扰。
async fn dns_probe(req: &Request, addr: IpAddr) -> Outcome {
    let port = if req.port == 0 {
        req.proto.default_port()
    } else {
        req.port
    };
    let dst = SocketAddr::new(addr, port);
    let std_sock = match bind_local(addr, req.src) {
        Ok(s) => s,
        Err(e) => return e,
    };
    if let Some(msg) = try_bind_device(&std_sock, &req.device) {
        logging::debug_ctx("health", "bind-device", &msg, &[("wan", req.wan.clone())]);
    }
    if let Err(e) = std_sock.set_nonblocking(true) {
        return Outcome::LocalError(format!("设置非阻塞失败: {e}"));
    }
    let sock = match tokio::net::UdpSocket::from_std(std_sock) {
        Ok(s) => s,
        Err(e) => return Outcome::LocalError(format!("交给 tokio 失败: {e}")),
    };
    if let Err(e) = sock.connect(dst).await {
        return classify_io_error(&e);
    }
    // 查询名固定为 root（"\0"），类型 A/AAAA：只为测量往返，不关心应答内容。
    let query = build_dns_query("");
    let started = Instant::now();
    if let Err(e) = sock.send(&query).await {
        return classify_io_error(&e);
    }
    let mut buf = [0u8; 512];
    match tokio::time::timeout(req.timeout, sock.recv(&mut buf)).await {
        Err(_) => Outcome::Timeout,
        Ok(Err(e)) => classify_io_error(&e),
        Ok(Ok(n)) => {
            if n >= 12 && buf[0] == query[0] && buf[1] == query[1] {
                Outcome::Reply {
                    rtt_ms: elapsed_ms(started),
                }
            } else {
                // 事务 ID 不匹配：收到的是别人的响应或垃圾包，不能算成功。
                Outcome::LocalError(format!("DNS 响应事务 ID 不匹配（{n} 字节）"))
            }
        }
    }
}

/// 裸 UDP 探测：发一个数据报并等待任何应答。
///
/// **能力边界（必须写进文档与 UI）**：绝大多数端口不会回答无状态的 UDP 包，
/// 因此 `udp` 只适用于「确定会应答」的服务（自建 53 端口 DNS、3478 STUN 等）。
/// 目标不应答时结果就是 `Timeout`，会被计入线路失败——这不是缺陷，
/// 而是用户选择该探测方式时必须知道的语义；推荐用 `dns` 代替。
async fn udp_probe(req: &Request, addr: IpAddr) -> Outcome {
    let port = if req.port == 0 {
        req.proto.default_port()
    } else {
        req.port
    };
    let dst = SocketAddr::new(addr, port);
    let std_sock = match bind_local(addr, req.src) {
        Ok(s) => s,
        Err(o) => return o,
    };
    if let Some(msg) = try_bind_device(&std_sock, &req.device) {
        logging::debug_ctx("health", "bind-device", &msg, &[("wan", req.wan.clone())]);
    }
    if let Err(e) = std_sock.set_nonblocking(true) {
        return Outcome::LocalError(format!("设置非阻塞失败: {e}"));
    }
    let sock = match tokio::net::UdpSocket::from_std(std_sock) {
        Ok(s) => s,
        Err(e) => return Outcome::LocalError(format!("交给 tokio 失败: {e}")),
    };
    if let Err(e) = sock.connect(dst).await {
        return classify_io_error(&e);
    }
    let started = Instant::now();
    if let Err(e) = sock.send(b"smartmwan-udp-probe").await {
        return classify_io_error(&e);
    }
    let mut buf = [0u8; 256];
    match tokio::time::timeout(req.timeout, sock.recv(&mut buf)).await {
        Err(_) => Outcome::Timeout,
        Ok(Err(e)) => classify_io_error(&e),
        Ok(Ok(0)) => Outcome::LocalError("收到空 UDP 数据报".into()),
        Ok(Ok(_n)) => Outcome::Reply {
            rtt_ms: elapsed_ms(started),
        },
    }
}

/// ICMP echo 探测。使用 `SOCK_DGRAM` 的 ping socket：
/// 不需要 `CAP_NET_RAW`，在 `net.ipv4.ping_group_range` 允许时即可工作。
async fn icmp_probe(req: &Request, addr: IpAddr) -> Outcome {
    let (domain, proto) = match addr {
        IpAddr::V4(_) => (libc::AF_INET, libc::IPPROTO_ICMP),
        IpAddr::V6(_) => (libc::AF_INET6, libc::IPPROTO_ICMPV6),
    };
    let fd = unsafe { libc::socket(domain, libc::SOCK_DGRAM, proto) };
    if fd < 0 {
        let e = std::io::Error::last_os_error();
        // EPERM/EACCES/EAFNOSUPPORT 属于「探测方式不支持」，不是线路问题。
        return match e.raw_os_error() {
            Some(libc::EPERM)
            | Some(libc::EACCES)
            | Some(libc::EAFNOSUPPORT)
            | Some(libc::EPROTONOSUPPORT) => {
                Outcome::Unsupported(format!("创建 ICMP socket 失败: {e}"))
            }
            _ => Outcome::LocalError(format!("创建 ICMP socket 失败: {e}")),
        };
    }
    // ping socket 的「本地端口」就是 ICMP ID：必须在包装成 UdpSocket 之前、
    // 还在裸 fd 时完成绑定（`std::net::UdpSocket::bind` 是关联函数，
    // 已经存在的 fd 只能通过 libc::bind 绑定）。
    let bind = local_for(addr, req.src);
    if let Err(e) = unsafe { raw_bind(fd, bind) } {
        unsafe { libc::close(fd) };
        return Outcome::LocalError(format!("绑定 {} 失败: {e}", bind.ip()));
    }
    let std_sock = match unsafe { make_std_udp_socket(fd) } {
        Ok(s) => s,
        Err(e) => return Outcome::LocalError(format!("包装 socket 失败: {e}")),
    };
    if let Some(msg) = try_bind_device(&std_sock, &req.device) {
        logging::debug_ctx("health", "bind-device", &msg, &[("wan", req.wan.clone())]);
    }
    let local = match std_sock.local_addr() {
        Ok(a) => a,
        Err(e) => return Outcome::LocalError(format!("读取本地地址失败: {e}")),
    };
    if let Err(e) = std_sock.connect(SocketAddr::new(addr, 0)) {
        return classify_io_error(&e);
    }
    if let Err(e) = std_sock.set_nonblocking(true) {
        return Outcome::LocalError(format!("设置非阻塞失败: {e}"));
    }
    let sock = match tokio::net::UdpSocket::from_std(std_sock) {
        Ok(s) => s,
        Err(e) => return Outcome::LocalError(format!("交给 tokio 失败: {e}")),
    };
    let ident = local.port();
    let pkt = build_echo_request(ident as u16, 1, addr.is_ipv6());
    let started = Instant::now();
    if let Err(e) = sock.send(&pkt).await {
        return classify_io_error(&e);
    }
    let mut buf = [0u8; 1024];
    loop {
        let wait = req.timeout.saturating_sub(started.elapsed());
        if wait.is_zero() {
            return Outcome::Timeout;
        }
        match tokio::time::timeout(wait, sock.recv(&mut buf)).await {
            Err(_) => return Outcome::Timeout,
            Ok(Err(e)) => return classify_io_error(&e),
            Ok(Ok(n)) => {
                if echo_reply_matches(&buf[..n], ident as u16) {
                    return Outcome::Reply {
                        rtt_ms: elapsed_ms(started),
                    };
                }
                // 不是本请求的响应：继续等，直到批次超时为止。
            }
        }
    }
}

/// 把裸 fd 包成 `std::net::UdpSocket`。要求 fd 是 `SOCK_DGRAM` 且尚未关联。
///
/// # Safety
/// `fd` 必须是刚由 [`libc::socket`] 创建、未被任何拥有者包装的描述符。
unsafe fn make_std_udp_socket(fd: i32) -> std::io::Result<std::net::UdpSocket> {
    use std::os::fd::FromRawFd;
    Ok(std::net::UdpSocket::from_raw_fd(fd))
}

/// 挑选本地绑定地址：优先线路自己的源地址，否则同族通配。
///
/// 地址族不一致时退回通配 —— 绑错族的内核会直接 EINVAL，
/// 与其报一个看不懂的错误，不如按内核默认方式让设备绑定来定出口。
fn local_for(dst: IpAddr, src: Option<IpAddr>) -> SocketAddr {
    let fam = Family::of(dst);
    match src {
        Some(s) if Family::of(s) == fam => SocketAddr::new(s, 0),
        _ => SocketAddr::new(
            if fam == Family::V4 {
                IpAddr::V4(Ipv4Addr::UNSPECIFIED)
            } else {
                IpAddr::V6(Ipv6Addr::UNSPECIFIED)
            },
            0,
        ),
    }
}

/// 在尚未关联的 socket 上执行 `bind(2)`。
///
/// # Safety
/// `fd` 必须是有效、未绑定、地址族与 `addr` 一致的套接字描述符。
unsafe fn raw_bind(fd: i32, addr: SocketAddr) -> std::io::Result<()> {
    let rc = match addr {
        SocketAddr::V4(a) => {
            let mut sa: libc::sockaddr_in = unsafe { std::mem::zeroed() };
            sa.sin_family = libc::AF_INET as libc::sa_family_t;
            sa.sin_port = a.port().to_be();
            sa.sin_addr = libc::in_addr {
                s_addr: u32::from_ne_bytes(a.ip().octets()),
            };
            libc::bind(
                fd,
                &sa as *const libc::sockaddr_in as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            )
        }
        SocketAddr::V6(a) => {
            let mut sa: libc::sockaddr_in6 = unsafe { std::mem::zeroed() };
            sa.sin6_family = libc::AF_INET6 as libc::sa_family_t;
            sa.sin6_port = a.port().to_be();
            sa.sin6_addr = libc::in6_addr {
                s6_addr: a.ip().octets(),
            };
            libc::bind(
                fd,
                &sa as *const libc::sockaddr_in6 as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t,
            )
        }
    };
    if rc == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

/// 创建并绑定一个普通 UDP socket（DNS/UDP 探测用）。
///
/// 失败时直接返回归类好的 [`Outcome`]：绑定失败可能是权限或地址问题，
/// 绝不能伪装成「线路超时」。
fn bind_local(
    dst: IpAddr,
    src: Option<IpAddr>,
) -> std::result::Result<std::net::UdpSocket, Outcome> {
    let want = local_for(dst, src);
    std::net::UdpSocket::bind(want)
        .map_err(|e| Outcome::LocalError(format!("绑定本地地址 {} 失败: {e}", want)))
}

fn elapsed_ms(start: Instant) -> u32 {
    start.elapsed().as_millis().min(u128::from(u32::MAX)) as u32
}

/// 把 I/O 错误分成「线路不可达」与「本机错误」两类。
fn classify_io_error(e: &std::io::Error) -> Outcome {
    match e.raw_os_error() {
        // 路由/网络不可达、连接被拒：是线路状态的一部分。
        Some(libc::ENETUNREACH)
        | Some(libc::ENETDOWN)
        | Some(libc::EHOSTUNREACH)
        | Some(libc::ECONNREFUSED) => Outcome::Unreachable(e.to_string()),
        Some(libc::ETIMEDOUT) => Outcome::Timeout,
        // 权限/地址族/参数错误：本机问题，绝不能计入断线。
        Some(libc::EPERM)
        | Some(libc::EACCES)
        | Some(libc::EAFNOSUPPORT)
        | Some(libc::EINVAL)
        | Some(libc::ENOPROTOOPT) => Outcome::Unsupported(e.to_string()),
        _ => Outcome::LocalError(e.to_string()),
    }
}

/// 构造最小 DNS 查询（root，A 记录）。事务 ID 用固定值即可用于匹配。
pub fn build_dns_query(name: &str) -> Vec<u8> {
    let mut q = vec![
        0x4d, 0x73, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];
    for label in name.split('.').filter(|l| !l.is_empty()) {
        let bytes = label.as_bytes();
        let len = bytes.len().min(63);
        q.push(len as u8);
        q.extend_from_slice(&bytes[..len]);
    }
    q.push(0);
    q.extend_from_slice(&[0x00, 0x01]); // QTYPE = A
    q.extend_from_slice(&[0x00, 0x01]); // QCLASS = IN
    q
}

/// 构造 ICMP echo 请求。校验和自行计算：ping socket 在内核里也会重写，
/// 但对某些内核版本/IPv6 路径显式计算更安全，写错也只是白算一次。
pub fn build_echo_request(ident: u16, seq: u16, v6: bool) -> Vec<u8> {
    let ty: u8 = if v6 { 128 } else { 8 };
    let mut p = vec![
        ty,
        0,
        0,
        0,
        (ident >> 8) as u8,
        (ident & 0xff) as u8,
        (seq >> 8) as u8,
        (seq & 0xff) as u8,
    ];
    // 负载带上时间戳友好的填充，方便 tcpdump 观察（不含敏感信息）。
    p.extend_from_slice(b"smartmwan-probe-0001");
    let cks = checksum(&p);
    p[2] = (cks >> 8) as u8;
    p[3] = (cks & 0xff) as u8;
    p
}

/// 标准的 Internet checksum（RFC 1071）。
pub fn checksum(data: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    let mut i = 0;
    while i + 1 < data.len() {
        sum += u16::from_be_bytes([data[i], data[i + 1]]) as u32;
        i += 2;
    }
    if i < data.len() {
        sum += u16::from_be_bytes([data[i], 0]) as u32;
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

/// 判断收到的报文是否是本请求的 echo reply。
///
/// datagram ICMP socket 交付的是完整 ICMP 报文（不含 IP 头）。
pub fn echo_reply_matches(buf: &[u8], ident: u16) -> bool {
    if buf.len() < 8 {
        return false;
    }
    let is_reply = buf[0] == 0 || buf[0] == 129;
    let got = u16::from_be_bytes([buf[4], buf[5]]);
    // 内核可能把 ID 重写成本地端口对应的值；两者都接受，避免误判成超时。
    is_reply && (got == ident || got == 0)
}

/// 从 `Resolved` 造请求（源地址按族挑选）。
pub fn request_for(
    res: &Resolved,
    target: Target,
    hc: &crate::config::schema::HealthConfig,
) -> Request {
    let family_v6 = match &target {
        Target::Addr(a) => Family::of(*a) == Family::V6,
        // 域名在探测时才解析，先按 IPv4 预期挑选源地址；解析出 IPv6 后
        // `probe` 会用该 v6 地址直接发送，源地址缺省交给内核按出口设备选择。
        Target::Domain(_) => false,
    };
    let src = if family_v6 { res.src6 } else { res.src4 };
    Request {
        wan: res.wan.clone(),
        device: res.device.clone(),
        ifindex: res.ifindex,
        src,
        target,
        proto: ProbeProto::Icmp,
        port: 0,
        timeout: Duration::from_millis(hc.timeout_ms as u64),
    }
}

/// 一批探测的并发执行：全局上限 + 批次 deadline + 取消。
///
/// 返回顺序不保证与请求一致；调用方按 `res.req.wan` 归并。
/// 任何单个探测的内部错误都会变成该条结果里的 `Outcome`，不会中断整批。
///
/// 探测器以 `Arc` 传入：`JoinSet` 要求任务 `'static`，借用式引用无法跨 `spawn`
/// 存活；用 `Arc<dyn Prober>` 即可在运行时替换实现而不牺牲可测试性。
pub async fn probe_batch<P: Prober + ?Sized>(
    prober: Arc<P>,
    reqs: Vec<Request>,
    batch_deadline: Duration,
    cancel: watch::Receiver<bool>,
) -> Vec<ProbeResult> {
    // 批次超出并发上限时先说明：探测会排队，而不是「同时打出去」。
    if let Some(free) = prober.free_permits() {
        if reqs.len() > free {
            logging::debug_ctx(
                "health",
                "probe-batch",
                &format!("本批 {} 条探测多于并发额度 {free}，超出的部分排队执行（探测负载受 max_concurrent_probes 约束）", reqs.len()),
                &[],
            );
        }
    }
    let mut set = tokio::task::JoinSet::new();
    for r in reqs {
        let p = Arc::clone(&prober);
        set.spawn(async move {
            let fut = p.probe(r);
            // 超时的探测返回 `None`：不能装作「线路失败」，只能按未完成处理。
            tokio::time::timeout(batch_deadline, fut).await.ok()
        });
    }
    let mut out = Vec::new();
    loop {
        if set.is_empty() {
            break;
        }
        let stop = {
            let c = cancel.borrow();
            *c
        };
        if stop {
            // 关停：放弃剩余探测（abort_all 是同步的；JoinSet::shutdown 会等待任务
            // 结束，而我们要的恰恰是「立刻不等了」），已完成的结果已经收进 out。
            set.abort_all();
            break;
        }
        match tokio::time::timeout(Duration::from_millis(200), set.join_next()).await {
            Err(_) => continue, // 只是轮询取消信号
            Ok(None) => continue,
            Ok(Some(res)) => match res {
                Ok(Some(Ok(r))) => out.push(r),
                Ok(Some(Err(e))) => {
                    logging::warn_ctx("health", "probe-task", &format!("探测任务失败: {e}"), &[]);
                }
                Ok(None) => {
                    logging::warn_ctx(
                        "health",
                        "probe-batch",
                        "单个探测超出批次期限，本条按未完成处理",
                        &[],
                    );
                }
                Err(e) => {
                    logging::warn_ctx("health", "probe-join", &format!("探测任务被中止: {e}"), &[])
                }
            },
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::schema::HealthConfig;

    fn req(proto: ProbeProto, addr: &str) -> Request {
        Request {
            wan: "wan".into(),
            device: "eth1".into(),
            ifindex: 4,
            src: None,
            target: Target::Addr(addr.parse().unwrap()),
            proto,
            port: 0,
            timeout: Duration::from_millis(200),
        }
    }

    #[test]
    fn checksum_matches_known_vectors() {
        // RFC 1071 示例：00 01 f2 03 f4 f5 f6 f7
        assert_eq!(
            checksum(&[0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]),
            0x220d
        );
        // 全零
        assert_eq!(checksum(&[]), 0xffff);
        // 奇数长度也必须可用
        let c = checksum(&[0x08, 0x00, 0x00, 0x00, 0x00, 0x01]);
        assert!(c != 0xffff);
    }

    #[test]
    fn echo_request_is_well_formed() {
        let p = build_echo_request(0x1234, 0x0007, false);
        assert_eq!(p[0], 8);
        assert_eq!(p[1], 0);
        assert_eq!(u16::from_be_bytes([p[4], p[5]]), 0x1234);
        assert_eq!(u16::from_be_bytes([p[6], p[7]]), 7);
        // 校验和：把头部的 checksum 字段置零后再算，结果必须为 0（标准验证法）
        let mut copy = p.clone();
        copy[2] = 0;
        copy[3] = 0;
        let expect = checksum(&copy);
        assert_eq!(u16::from_be_bytes([p[2], p[3]]), expect);
        assert_eq!(checksum(&p), 0, "带正确校验和的报文再校验应为 0");
        assert_eq!(build_echo_request(1, 1, true)[0], 128);
    }

    #[test]
    fn reply_matcher_accepts_only_echo_reply() {
        let mut reply = vec![0u8, 0, 0, 0, 0x12, 0x34, 0, 1];
        assert!(echo_reply_matches(&reply, 0x1234));
        reply[0] = 8; // echo request 不是我们要的
        assert!(!echo_reply_matches(&reply, 0x1234));
        assert!(
            !echo_reply_matches(&reply[0..4], 0x1234),
            "长度不足必须拒绝"
        );
        reply[0] = 0;
        assert!(!echo_reply_matches(&reply, 0x9999), "不同 ID 不能算命中");
        // 内核把 ID 写成 0 的情况（部分版本行为）也要接受，否则会把好线路判成超时
        reply[4] = 0;
        reply[5] = 0;
        assert!(echo_reply_matches(&reply, 0x1234));
    }

    #[test]
    fn dns_query_shape() {
        let q = build_dns_query("example.com");
        assert_eq!(&q[0..2], &[0x4d, 0x73]);
        assert_eq!(q[2..4], [0x01, 0x00], "必须是递归查询");
        assert_eq!(&q[12], &7, "label 长度");
        assert!(q.ends_with(&[0x00, 0x01, 0x00, 0x01]));
        let root = build_dns_query("");
        assert_eq!(root[12], 0, "根域名查询以 0 结尾");
    }

    #[test]
    fn outcome_taxonomy_is_explicit() {
        assert!(Outcome::Timeout.counts_as_line_failure());
        assert!(Outcome::Unreachable("x".into()).counts_as_line_failure());
        assert!(
            !Outcome::Unsupported("no perms".into()).counts_as_line_failure(),
            "权限问题绝不能算成断线"
        );
        assert!(
            !Outcome::LocalError("dns fail".into()).counts_as_line_failure(),
            "解析失败不是线路故障"
        );
        assert!(!Outcome::Reply { rtt_ms: 1 }.counts_as_line_failure());
        assert!(Outcome::Unsupported("x".into())
            .describe()
            .contains("不受支持"));
    }

    #[test]
    fn sample_only_for_meaningful_outcomes() {
        let mut r = ProbeResult {
            req: req(ProbeProto::Icmp, "10.0.0.1"),
            at_ms: 5,
            outcome: Outcome::Reply { rtt_ms: 42 },
            resolved: None,
        };
        assert_eq!(r.sample(), Some(Sample::success(5, 42, "icmp")));
        r.outcome = Outcome::Timeout;
        assert_eq!(r.sample(), Some(Sample::failure(5, "icmp")));
        r.outcome = Outcome::Unsupported("x".into());
        assert!(r.sample().is_none(), "不支持的探测不能污染指标");
        r.outcome = Outcome::LocalError("x".into());
        assert!(r.sample().is_none());
    }

    #[test]
    fn io_errors_are_classified_not_swallowed() {
        let e = std::io::Error::from_raw_os_error(libc::ENETUNREACH);
        assert!(matches!(classify_io_error(&e), Outcome::Unreachable(_)));
        let e = std::io::Error::from_raw_os_error(libc::EACCES);
        assert!(matches!(classify_io_error(&e), Outcome::Unsupported(_)));
        let e = std::io::Error::from_raw_os_error(libc::ETIMEDOUT);
        assert!(matches!(classify_io_error(&e), Outcome::Timeout));
        let e = std::io::Error::from_raw_os_error(libc::EPIPE);
        assert!(matches!(classify_io_error(&e), Outcome::LocalError(_)));
    }

    #[test]
    fn request_uses_family_matching_source() {
        let mut res = Resolved {
            wan: "wan".into(),
            device: "eth1".into(),
            ifindex: 4,
            link_up: true,
            gw4: "10.0.0.1".parse().ok(),
            gw6: Some("fe80::1".parse().unwrap()),
            src4: "10.0.0.2".parse().ok(),
            src6: Some("2001:db8::2".parse().unwrap()),
            link_default: false,
            notes: vec![],
        };
        let hc = HealthConfig::default();
        let r = request_for(&res, Target::Addr("1.1.1.1".parse().unwrap()), &hc);
        assert_eq!(r.src.map(|a| a.to_string()), Some("10.0.0.2".to_string()));
        assert_eq!(r.device, "eth1");
        assert_eq!(r.timeout, Duration::from_millis(hc.timeout_ms as u64));
        let r6 = request_for(&res, Target::Addr("2606:4700::1".parse().unwrap()), &hc);
        assert_eq!(
            r6.src.map(|a| a.to_string()),
            Some("2001:db8::2".to_string())
        );
        res.src4 = None;
        let r2 = request_for(&res, Target::Domain("example.com".into()), &hc);
        assert_eq!(r2.src, None, "没有可用源地址时交给内核，不编造");
    }

    /// 假探测器：按脚本返回固定结果，用于验证并发/取消/期限行为。
    struct FakeProber {
        delay: Duration,
        outcome: Outcome,
        sem: Arc<Semaphore>,
    }

    impl FakeProber {
        fn new(max: usize, delay_ms: u64, outcome: Outcome) -> FakeProber {
            FakeProber {
                delay: Duration::from_millis(delay_ms),
                outcome,
                sem: Arc::new(Semaphore::new(max)),
            }
        }
    }

    impl Prober for FakeProber {
        fn probe(&self, req: Request) -> BoxFuture<'_, Result<ProbeResult>> {
            let sem = self.sem.clone();
            let delay = self.delay;
            let outcome = self.outcome.clone();
            Box::pin(async move {
                let _p = sem.acquire().await.unwrap();
                tokio::time::sleep(delay).await;
                Ok(ProbeResult {
                    req,
                    at_ms: 1,
                    outcome,
                    resolved: None,
                })
            })
        }
    }

    #[tokio::test]
    async fn batch_honours_concurrency_and_collects_all() {
        // 并发 2、每条 20ms、6 条：串行需要 120ms，并发应明显更快。
        let p = Arc::new(FakeProber::new(2, 20, Outcome::Reply { rtt_ms: 5 }));
        let reqs: Vec<Request> = (0..6)
            .map(|i| req(ProbeProto::Tcp, &format!("10.0.0.{}", i + 1)))
            .collect();
        let (_tx, rx) = watch::channel(false);
        let started = Instant::now();
        let out = probe_batch(p, reqs, Duration::from_millis(2000), rx).await;
        assert_eq!(out.len(), 6, "所有已完成结果必须被收集");
        assert!(
            started.elapsed() < Duration::from_millis(110),
            "并发上限没起作用: {:?}",
            started.elapsed()
        );
    }

    #[tokio::test]
    async fn batch_deadline_drops_but_does_not_hang() {
        let p = Arc::new(FakeProber::new(4, 500, Outcome::Timeout));
        let reqs = vec![req(ProbeProto::Icmp, "1.1.1.1")];
        let (_tx, rx) = watch::channel(false);
        let started = Instant::now();
        let out = probe_batch(p, reqs, Duration::from_millis(60), rx).await;
        assert!(out.is_empty(), "超出批次期限的结果不该装作成功");
        assert!(
            started.elapsed() < Duration::from_millis(400),
            "必须被期限截断: {:?}",
            started.elapsed()
        );
    }

    #[tokio::test]
    async fn cancellation_stops_the_batch() {
        let p = Arc::new(FakeProber::new(1, 300, Outcome::Reply { rtt_ms: 1 }));
        let reqs: Vec<Request> = (0..8)
            .map(|i| req(ProbeProto::Tcp, &format!("10.0.0.{}", i + 1)))
            .collect();
        let (tx, rx) = watch::channel(false);
        let handle =
            tokio::spawn(
                async move { probe_batch(p, reqs, Duration::from_millis(5000), rx).await },
            );
        tokio::time::sleep(Duration::from_millis(60)).await;
        tx.send(true).unwrap();
        let out = handle.await.unwrap();
        assert!(out.len() < 8, "取消后不应把所有探测都跑完: {}", out.len());
    }

    #[tokio::test]
    async fn real_prober_reports_unsupported_instead_of_line_failure_without_privilege() {
        // 沙箱里没有 ICMP 权限，也没有可路由的 10.0.0.x：
        // 关键断言是「结果必须是明确分类」，而不是 panic 或假装成功。
        let p = SystemProber::new(4);
        assert_eq!(
            Prober::free_permits(&p),
            Some(4),
            "并发额度必须如实反映 max_concurrent_probes"
        );
        let r = Request {
            wan: "wan".into(),
            device: String::new(),
            ifindex: 0,
            src: None,
            target: Target::Addr("198.51.100.1".parse().unwrap()),
            proto: ProbeProto::Icmp,
            port: 0,
            timeout: Duration::from_millis(150),
        };
        let out = p.probe(r.clone()).await.unwrap();
        assert!(!out.outcome.is_reply(), "沙箱里不该探测成功");
        assert!(
            matches!(
                out.outcome,
                Outcome::Timeout
                    | Outcome::Unreachable(_)
                    | Outcome::Unsupported(_)
                    | Outcome::LocalError(_)
            ),
            "{:?}",
            out.outcome
        );
        // 域名解析失败路径：必须是 LocalError 或真正的网络错误，不能是 Reply。
        let r2 = Request {
            target: Target::Domain("this-domain-does-not-exist-smw.invalid".into()),
            ..r
        };
        let out2 = p.probe(r2).await.unwrap();
        assert!(!out2.outcome.is_reply(), "不存在的域名不能被判成可达");
        assert!(
            matches!(
                out2.outcome,
                Outcome::LocalError(_) | Outcome::Unreachable(_) | Outcome::Timeout
            ),
            "{:?}",
            out2.outcome
        );
        // 解析类错误绝不进入「线路失败」统计，否则会触发无谓切换。
        if let Outcome::LocalError(_) = out2.outcome {
            assert!(!out2.outcome.counts_as_line_failure());
        }
    }
}

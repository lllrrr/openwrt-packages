//! 配置数据模型。
//!
//! 约定：
//! * 每个字段都用 `#[serde(default = "...")]` 给出**显式默认值**，默认值集中在此文件，
//!   UI 与 `--dump-defaults` 共用同一来源，避免「页面显示 A、守护进程用 B」。
//! * 枚举字符串一律小写，与 UCI 值风格一致；未知值不静默回退，由校验层报错。
//! * 本模块只描述数据；合法性在 `validate.rs`，与 UCI 文本的映射在 `mod.rs`。

use std::collections::BTreeSet;
use std::net::{IpAddr, Ipv4Addr};

use serde::{Deserialize, Serialize};

use crate::marks;

/// 全局工作模式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// 负载均衡：多条 WAN 同时承载普通流量。
    Balance,
    /// 主备：普通流量只走主线路，备用线路待命。
    Failover,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Balance => "balance",
            Mode::Failover => "failover",
        }
    }
    pub fn parse(s: &str) -> Option<Mode> {
        match s.trim().to_ascii_lowercase().as_str() {
            "balance" | "loadbalance" | "load_balance" => Some(Mode::Balance),
            "failover" | "primary_backup" | "standby" => Some(Mode::Failover),
            _ => None,
        }
    }
}

/// 负载均衡算法。**每个变体的哈希输入字段都是确定的**，UI 必须按此如实描述。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Algorithm {
    /// jhash(saddr) —— 同一内网客户端稳定绑定同一出口。
    SrcIp,
    /// jhash(saddr, sport) —— 端口参与哈希，同客户端不同连接可能分流。
    SrcIpSrcPort,
    /// jhash(saddr, daddr)。
    SrcIpDstIp,
    /// jhash(saddr, daddr, dport)。注意：不含协议，同 IP 同端口的 TCP/UDP 会同出口。
    SrcIpDstIpDstPort,
    /// 完整五元组 jhash(saddr, sport, daddr, dport, proto)。
    /// 单独列出，避免把它与 `SrcIpDstIpDstPort` 混为「都一样」。
    FullFiveTuple,
    /// 新建连接数最少优先（由守护进程按统计窗口重排桶）。
    LeastNewConnections,
    /// 实时流量最少优先（平滑后的负载）。
    LeastTraffic,
    /// 加权哈希：桶按权重比例分配给各线路。
    WeightedHash,
    /// 内核加权 ECMP（需 ip-full + 内核 MULTIPATH 支持，运行时会探测能力）。
    WeightedEcmp,
}

impl Algorithm {
    pub fn as_str(self) -> &'static str {
        match self {
            Algorithm::SrcIp => "src_ip",
            Algorithm::SrcIpSrcPort => "src_ip_src_port",
            Algorithm::SrcIpDstIp => "src_ip_dst_ip",
            Algorithm::SrcIpDstIpDstPort => "src_ip_dst_ip_dst_port",
            Algorithm::FullFiveTuple => "full_five_tuple",
            Algorithm::LeastNewConnections => "least_new_connections",
            Algorithm::LeastTraffic => "least_traffic",
            Algorithm::WeightedHash => "weighted_hash",
            Algorithm::WeightedEcmp => "weighted_ecmp",
        }
    }

    pub fn parse(s: &str) -> Option<Algorithm> {
        let k = s.trim().to_ascii_lowercase().replace('-', "_");
        Some(match k.as_str() {
            "src_ip" | "srcip" => Algorithm::SrcIp,
            "src_ip_src_port" | "srcip_srcport" => Algorithm::SrcIpSrcPort,
            "src_ip_dst_ip" | "srcip_dstip" => Algorithm::SrcIpDstIp,
            "src_ip_dst_ip_dst_port" | "srcip_dstip_dstport" => Algorithm::SrcIpDstIpDstPort,
            "full_five_tuple" | "fivetuple" => Algorithm::FullFiveTuple,
            "least_new_connections" | "least_newconn" => Algorithm::LeastNewConnections,
            "least_traffic" => Algorithm::LeastTraffic,
            "weighted_hash" => Algorithm::WeightedHash,
            "weighted_ecmp" => Algorithm::WeightedEcmp,
            _ => return None,
        })
    }

    /// 是否是「静态哈希」类算法：桶→线路映射一旦下发就不再随负载变化。
    pub fn is_static_hash(self) -> bool {
        matches!(
            self,
            Algorithm::SrcIp
                | Algorithm::SrcIpSrcPort
                | Algorithm::SrcIpDstIp
                | Algorithm::SrcIpDstIpDstPort
                | Algorithm::FullFiveTuple
                | Algorithm::WeightedHash
        )
    }

    /// 是否需要守护进程周期性重排桶（动态调度）。
    pub fn is_dynamic(self) -> bool {
        matches!(
            self,
            Algorithm::LeastNewConnections | Algorithm::LeastTraffic
        )
    }

    /// 该算法实际使用的 nftables 哈希输入（用于 UI 如实展示与规则生成）。
    pub fn nft_hash_expr(self) -> &'static str {
        match self {
            Algorithm::SrcIp => "ip saddr",
            Algorithm::SrcIpSrcPort => "ip saddr . .sport",
            Algorithm::SrcIpDstIp => "ip saddr . ip daddr",
            Algorithm::SrcIpDstIpDstPort => "ip saddr . ip daddr . ip dport",
            Algorithm::FullFiveTuple => "ip saddr . ip daddr . .sport . ip dport . meta l4proto",
            // 动态算法用递增计数器打散，再由桶映射决定出口
            Algorithm::LeastNewConnections | Algorithm::LeastTraffic => "numgen random",
            Algorithm::WeightedHash => "ip saddr . ip daddr",
            Algorithm::WeightedEcmp => "not-applicable",
        }
    }

    /// UI 必须展示的能力限制说明，避免过度承诺（任务书 5.x 明确要求）。
    pub fn limitations(self) -> &'static str {
        match self {
            Algorithm::SrcIp => "同一内网 IP 始终走同一出口；单客户端大流量不会被均分。",
            Algorithm::SrcIpSrcPort => "源端口参与哈希，可提升均度，但同一连接的端口是稳定的，长连接不会自动迁移；NAT 后源端口会变化，跨 NAT 不可复现。",
            Algorithm::SrcIpDstIp => "同客户端访问同一目标服务器始终同出口；目标数量少时均度差。",
            Algorithm::SrcIpDstIpDstPort => "不含协议字段，同 IP 同端口的 TCP 与 UDP 会走同一出口。",
            Algorithm::FullFiveTuple => "含协议的完整五元组，均度最好，但同客户端会话可能分散到多条线路，对会话保持敏感的应用不友好。",
            Algorithm::LeastNewConnections => "统计基于 conntrack 标记快照与 nft 计数器差值，存在采样误差；连接速率很高时窗口内估算会偏晚。",
            Algorithm::LeastTraffic => "依据接口字节计数器按窗口平滑，不感知单条连接；单连接峰值不会立即触发迁移，且已建立连接保持原出口。",
            Algorithm::WeightedHash => "权重控制的是桶分配比例，不等于实际带宽占比；单连接仍受限于一条线路，不会叠加带宽。",
            Algorithm::WeightedEcmp => "依赖内核多路径与 ip-full；单个连接由内核选一条下一跳，不会聚合带宽；探测不到能力时该算法会被拒绝启用。",
        }
    }
}

/// 主备模式下的游戏流量策略（任务书 6.3 的三种情形）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GamePolicy {
    /// 严格遵守主备顺序，游戏也走主线路。
    Follow,
    /// 允许游戏流量跨线路择优，但普通流量仍严格主备。
    Exception,
}

impl GamePolicy {
    pub fn as_str(self) -> &'static str {
        match self {
            GamePolicy::Follow => "follow",
            GamePolicy::Exception => "exception",
        }
    }
    pub fn parse(s: &str) -> Option<GamePolicy> {
        match s.trim().to_ascii_lowercase().as_str() {
            "follow" | "strict" => Some(GamePolicy::Follow),
            "exception" | "best" => Some(GamePolicy::Exception),
            _ => None,
        }
    }
}

/// 回切方式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Failback {
    Auto,
    Manual,
}

impl Failback {
    pub fn as_str(self) -> &'static str {
        match self {
            Failback::Auto => "auto",
            Failback::Manual => "manual",
        }
    }
    pub fn parse(s: &str) -> Option<Failback> {
        match s.trim().to_ascii_lowercase().as_str() {
            "auto" | "1" => Some(Failback::Auto),
            "manual" | "0" => Some(Failback::Manual),
            _ => None,
        }
    }
}

/// 探测协议。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProbeProto {
    Icmp,
    Tcp,
    Udp,
    Dns,
}

impl ProbeProto {
    pub fn as_str(self) -> &'static str {
        match self {
            ProbeProto::Icmp => "icmp",
            ProbeProto::Tcp => "tcp",
            ProbeProto::Udp => "udp",
            ProbeProto::Dns => "dns",
        }
    }
    pub fn parse(s: &str) -> Option<ProbeProto> {
        match s.trim().to_ascii_lowercase().as_str() {
            "icmp" | "ping" => Some(ProbeProto::Icmp),
            "tcp" => Some(ProbeProto::Tcp),
            "udp" => Some(ProbeProto::Udp),
            "dns" => Some(ProbeProto::Dns),
            _ => None,
        }
    }
    pub fn default_port(self) -> u16 {
        match self {
            ProbeProto::Tcp => 443,
            ProbeProto::Udp | ProbeProto::Dns => 53,
            ProbeProto::Icmp => 0,
        }
    }
}

/// 线路在主备/负载均衡中的角色。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WanRole {
    /// 由优先级与状态自动决定。
    Auto,
    /// 主线路（全配置最多一个显式 primary）。
    Primary,
    /// 备用线路。
    Backup,
    /// 只作观察，永不参与分流（如流量计费的备用卡）。
    Monitor,
}

impl WanRole {
    pub fn as_str(self) -> &'static str {
        match self {
            WanRole::Auto => "auto",
            WanRole::Primary => "primary",
            WanRole::Backup => "backup",
            WanRole::Monitor => "monitor",
        }
    }
    pub fn parse(s: &str) -> Option<WanRole> {
        match s.trim().to_ascii_lowercase().as_str() {
            "auto" | "" => Some(WanRole::Auto),
            "primary" | "main" => Some(WanRole::Primary),
            "backup" | "standby" => Some(WanRole::Backup),
            "monitor" | "observe" => Some(WanRole::Monitor),
            _ => None,
        }
    }
}

/// 单条线路的健康检测配置（可按线路覆盖全局值）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct HealthConfig {
    /// 探测周期（毫秒）。
    pub interval_ms: u32,
    /// 单次探测超时（毫秒）。
    pub timeout_ms: u32,
    /// 连续失败多少次判定 FAILED。
    pub failure_threshold: u32,
    /// 连续成功多少次进入 RECOVERING。
    pub recovery_threshold: u32,
    /// RECOVERING 预热时间（毫秒），期间不参与分流。
    pub warmup_ms: u64,
    /// RTT 超过该值判定 DEGRADED。
    pub degraded_rtt_ms: u32,
    /// 丢包率（千分比）超过该值判定 DEGRADED。
    pub degraded_loss_pmm: u32,
    /// 抖动（毫秒）超过该值判定 DEGRADED。
    pub degraded_jitter_ms: u32,
    /// 并发探测上限（全局，防止探测本身压垮设备）。
    pub max_concurrent_probes: u16,
}

impl Default for HealthConfig {
    fn default() -> Self {
        // 任务书建议的初始值，仅作默认，可按线路覆盖；
        // 文档必须说明：这些值不适合所有 5G 模组与运营商环境。
        Self {
            interval_ms: 1000,
            timeout_ms: 800,
            failure_threshold: 3,
            recovery_threshold: 5,
            warmup_ms: 5000,
            degraded_rtt_ms: 150,
            degraded_loss_pmm: 20,
            degraded_jitter_ms: 40,
            max_concurrent_probes: 16,
        }
    }
}

/// 全局配置（`config smartmwan 'global'`）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct GlobalConfig {
    /// 配置模式版本，用于迁移判定。
    pub config_version: u32,
    pub enabled: bool,
    pub mode: Mode,
    pub algorithm: Algorithm,
    /// 主备模式下的游戏策略。
    pub game_policy: GamePolicy,
    pub failback: Failback,
    /// 主线路名（UCI `wan` 段名）。
    pub primary: String,
    /// 备用线路顺序（按优先级由低到高排列的名称列表）。
    pub backup_order: Vec<String>,
    /// 回切延迟：主线路健康后至少等待该时间才回切（毫秒）。
    pub failback_delay_ms: u64,
    /// 回切需连续成功次数。
    pub failback_success_threshold: u32,
    /// 任意两次出口变更之间的最小间隔（毫秒）—— 防抖的兜底闸门。
    pub min_switch_interval_ms: u64,
    /// 是否保持已建立连接的出口（数据平面 sticky）。
    pub conn_sticky: bool,
    /// 哈希种子，便于多设备一致或人为打散。
    pub hash_seed: u32,
    /// 桶数（必须是 2..=marks::BUCKETS，且建议为偶数）。
    pub buckets: u16,
    /// 全局默认健康检测参数，线路段可覆盖。
    pub health: HealthConfig,
    /// 动态算法的统计窗口（毫秒）。
    pub sample_window_ms: u64,
    /// 动态算法的最小重排间隔（毫秒），避免高频全量重建。
    pub rebalance_interval_ms: u64,
    /// 线路负载平滑系数（千分比，越大越平滑）。
    pub smoothing_permille: u32,
    /// 单条线路允许的最大并发连接数（0=不限制），用于最小切换保护。
    pub max_connections_per_wan: u32,
    /// 绝不参与分流的内网源地址/网段（管理口、VPN 回段等），防失联。
    pub protected_src: Vec<String>,
    /// 不参与分流的目的网段（内网互访、组播）。
    pub bypass_dst: Vec<String>,
    /// 只从这些 LAN zone/接口来的流量参与分流（空=除保护段外全部）。
    pub lan_zones: Vec<String>,
    /// 是否同时接管 IPv6（关闭时 IPv6 一律走 main 表）。
    pub enable_ipv6: bool,
    pub log_level: String,
    pub log_file: String,
    pub log_max_bytes: u64,
    pub log_keep_backups: usize,
    pub rpc_socket: String,
    pub state_dir: String,
    /// 启用前对「可能失联」的变更强制二次确认。
    pub require_confirm: bool,
    /// 域名规则解析出来的集合元素寿命（秒）。
    ///
    /// 为什么可配而不是「用 DNS 真实 TTL」：本实现用 `getaddrinfo`，它**不返回 TTL**，
    /// 所以这里配的是一个人为寿命 —— 它同时决定「过期后多久重新解析」和
    /// 「记录已被回收后地址还会在集合里停留多久」。见 `rules::dns_sets` 模块头的限制说明。
    pub dns_ttl_floor_s: u64,
}

impl Default for GlobalConfig {
    fn default() -> Self {
        Self {
            config_version: crate::CONFIG_SCHEMA_VERSION,
            enabled: false, // 默认关闭：首次安装绝不能改变现有路由
            mode: Mode::Balance,
            algorithm: Algorithm::SrcIpDstIp,
            game_policy: GamePolicy::Follow,
            failback: Failback::Auto,
            primary: String::new(),
            backup_order: Vec::new(),
            failback_delay_ms: 60_000,
            failback_success_threshold: 5,
            min_switch_interval_ms: 15_000,
            conn_sticky: true,
            hash_seed: 0x534d_5731,
            buckets: marks::BUCKETS,
            health: HealthConfig::default(),
            sample_window_ms: 10_000,
            rebalance_interval_ms: 2_000,
            smoothing_permille: 700,
            max_connections_per_wan: 0,
            protected_src: vec![
                // 保留地址段永不分流：链路本地 + 站点本地常见管理段，避免误伤。
                "169.254.0.0/16".into(),
                "fe80::/10".into(),
            ],
            bypass_dst: vec![
                "0.0.0.0/8".into(),
                "100.64.0.0/10".into(),
                "127.0.0.0/8".into(),
                "192.0.0.0/24".into(),
                "192.0.2.0/24".into(),
                "198.51.100.0/24".into(),
                "203.0.113.0/24".into(),
                "224.0.0.0/4".into(),
                "240.0.0.0/4".into(),
                "::1/128".into(),
                "fc00::/7".into(),
            ],
            lan_zones: vec!["lan".into()],
            enable_ipv6: true,
            log_level: "info".into(),
            log_file: "/tmp/log/smartmwan.log".into(),
            log_max_bytes: 512 * 1024,
            log_keep_backups: 3,
            rpc_socket: "/var/run/smartmwan/rpc.sock".into(),
            state_dir: "/tmp/run/smartmwan".into(),
            require_confirm: true,
            // 5 分钟：比常见游戏服务器记录的 60~300 秒长，比 CDN 池轮换周期短。
            // 这是「拿不到真实 TTL」下的折中默认值，不是最优值 —— 见 dns_ttl_floor_s 注释。
            dns_ttl_floor_s: 300,
        }
    }
}

/// 单条 WAN 线路（`config wan '<name>'`，name 通常等于 netifd 接口名）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct WanConfig {
    /// UCI 段名，也是内部主键。
    pub name: String,
    pub enabled: bool,
    pub role: WanRole,
    /// 覆盖自动发现的网络设备名（模组重拨后设备可能变化，留空表示跟随 netifd）。
    pub device: String,
    /// 权重：用于加权哈希/加权 ECMP，最小 1。
    pub weight: u32,
    /// 优先级：数值越小越优先（主备排序用）。
    pub priority: u16,
    /// 下行带宽上限（kbit/s，0=不限），用于最小流量算法。
    pub down_kbps: u32,
    /// 上行带宽上限（kbit/s，0=不限）。
    pub up_kbps: u32,
    /// 探测目标，多个（任务书要求避免单目标被屏蔽导致误判）。
    pub probe_targets: Vec<String>,
    pub probe_proto: ProbeProto,
    pub probe_port: u16,
    /// 是否对该线路做 IPv6 探测。
    pub probe_ipv6: bool,
    /// 网关覆盖（模组环境下自动发现可能不准）。
    pub gateway: String,
    /// 源地址覆盖（用于 `ip rule from` 与 SNAT 一致性）。
    pub src_ip: String,
    /// 维护模式：临时禁用但保留配置。
    pub maintenance: bool,
    /// 健康检测参数覆盖（None 字段表示继承全局）。
    pub health: HealthConfig,
    /// 自定义规则里可作为 pin 目标的别名。
    pub label: String,
}

impl Default for WanConfig {
    fn default() -> Self {
        Self {
            name: String::new(),
            enabled: true,
            role: WanRole::Auto,
            device: String::new(),
            weight: 1,
            priority: 100,
            down_kbps: 0,
            up_kbps: 0,
            probe_targets: vec![],
            probe_proto: ProbeProto::Icmp,
            probe_port: 0,
            probe_ipv6: true,
            gateway: String::new(),
            src_ip: String::new(),
            maintenance: false,
            health: HealthConfig::default(),
            label: String::new(),
        }
    }
}

/// 游戏规则（`config game '<name>'`）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct GameRule {
    pub name: String,
    pub enabled: bool,
    /// 数值越小越先匹配；相同数值按名称字典序，保证确定性。
    pub priority: u16,
    /// 预置项来源标识（空表示自定义规则）。
    pub preset: String,
    /// 目的网段/IP（IPv4 与 IPv6 混放，校验层按族分拣）。
    pub targets: Vec<String>,
    /// 目的端口或范围：`443`、`8000-8010`。空表示任意端口。
    pub ports: Vec<String>,
    /// 协议限制。
    pub proto: ProtoFilter,
    /// 内网客户端 IP/CIDR 匹配（任一命中即适用）。
    pub client_ips: Vec<String>,
    /// 内网客户端 MAC 匹配。
    pub client_macs: Vec<String>,
    /// 域名规则（依赖 DNS 解析，限制见 dns_sets.rs 文档）。
    pub domains: Vec<String>,
    /// 选路方式：择优 / 固定线路 / 跟随普通策略。
    pub selection: GameSelection,
    /// selection = pin 时指定的线路名。
    pub pin_wan: String,
    /// 备注（UI 展示，不参与匹配）。
    pub comment: String,
}

impl Default for GameRule {
    fn default() -> Self {
        Self {
            name: String::new(),
            enabled: true,
            priority: 50,
            preset: String::new(),
            targets: Vec::new(),
            ports: Vec::new(),
            proto: ProtoFilter::Both,
            client_ips: Vec::new(),
            client_macs: Vec::new(),
            domains: Vec::new(),
            selection: GameSelection::Best,
            pin_wan: String::new(),
            comment: String::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProtoFilter {
    Tcp,
    Udp,
    Both,
}

impl ProtoFilter {
    pub fn as_str(self) -> &'static str {
        match self {
            ProtoFilter::Tcp => "tcp",
            ProtoFilter::Udp => "udp",
            ProtoFilter::Both => "both",
        }
    }
    pub fn parse(s: &str) -> Option<ProtoFilter> {
        match s.trim().to_ascii_lowercase().as_str() {
            "tcp" => Some(ProtoFilter::Tcp),
            "udp" => Some(ProtoFilter::Udp),
            "both" | "any" | "tcpudp" | "" => Some(ProtoFilter::Both),
            _ => None,
        }
    }
    /// nftables 协议匹配片段。
    pub fn nft_meta(self) -> Option<&'static str> {
        match self {
            ProtoFilter::Tcp => Some("meta l4proto tcp"),
            ProtoFilter::Udp => Some("meta l4proto udp"),
            ProtoFilter::Both => None,
        }
    }
}

/// 游戏流量的出口选择方式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GameSelection {
    /// 在健康线路中按综合评分择优（受 `game_policy` 约束）。
    Best,
    /// 固定走某条线路。
    Pin,
    /// 不做特殊处理，跟随普通流量策略。
    Follow,
}

impl GameSelection {
    pub fn as_str(self) -> &'static str {
        match self {
            GameSelection::Best => "best",
            GameSelection::Pin => "pin",
            GameSelection::Follow => "follow",
        }
    }
    pub fn parse(s: &str) -> Option<GameSelection> {
        match s.trim().to_ascii_lowercase().as_str() {
            "best" => Some(GameSelection::Best),
            "pin" | "fixed" => Some(GameSelection::Pin),
            "follow" => Some(GameSelection::Follow),
            _ => None,
        }
    }
}

/// 质量评分权重（任务书 6.3 的公式参数）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ScoreWeights {
    pub rtt: u32,
    pub jitter: u32,
    pub loss: u32,
    /// 最近发生过切换/抖动的线路扣分。
    pub instability: u32,
    /// 归一化基准：RTT 达到该值时视为最差（1.0）。
    pub rtt_norm_ms: u32,
    pub jitter_norm_ms: u32,
    /// 丢包归一化基准（千分比）。
    pub loss_norm_pmm: u32,
    /// 滞回：候选线路评分需超过当前线路该百分比才切换。
    pub min_advantage_permille: u32,
    /// 命中游戏流量后的最小稳定时间（毫秒）。
    pub min_stable_ms: u64,
}

impl Default for ScoreWeights {
    fn default() -> Self {
        Self {
            rtt: 50,
            jitter: 20,
            loss: 60,
            instability: 10,
            rtt_norm_ms: 200,
            jitter_norm_ms: 60,
            loss_norm_pmm: 50,
            min_advantage_permille: 150,
            min_stable_ms: 20_000,
        }
    }
}

impl ScoreWeights {
    /// 归一化权重和，供 UI 提示「权重比例已偏离 1.0」。
    pub fn total(&self) -> u32 {
        self.rtt + self.jitter + self.loss + self.instability
    }
}

/// 完整配置树。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
#[derive(Default)]
pub struct Config {
    pub global: GlobalConfig,
    pub wans: Vec<WanConfig>,
    pub games: Vec<GameRule>,
    pub score: ScoreWeights,
}

impl Config {
    pub fn wan(&self, name: &str) -> Option<&WanConfig> {
        self.wans.iter().find(|w| w.name == name)
    }

    pub fn wan_mut(&mut self, name: &str) -> Option<&mut WanConfig> {
        self.wans.iter_mut().find(|w| w.name == name)
    }

    /// 参与分流的线路（启用 + 非维护 + 非 monitor）。
    pub fn active_wans(&self) -> Vec<&WanConfig> {
        self.wans
            .iter()
            .filter(|w| w.enabled && !w.maintenance && w.role != WanRole::Monitor)
            .collect()
    }

    /// 主备顺序：显式 primary → backup_order → 其余按 priority。
    pub fn failover_order(&self) -> Vec<String> {
        let mut seen = BTreeSet::new();
        let mut out = Vec::new();
        if !self.global.primary.is_empty() && self.wan(&self.global.primary).is_some() {
            seen.insert(self.global.primary.clone());
            out.push(self.global.primary.clone());
        }
        for n in &self.global.backup_order {
            if self.wan(n).is_some() && seen.insert(n.clone()) {
                out.push(n.clone());
            }
        }
        let mut rest: Vec<&WanConfig> = self
            .wans
            .iter()
            .filter(|w| !seen.contains(&w.name))
            .collect();
        rest.sort_by_key(|w| (w.priority, w.name.clone()));
        out.extend(rest.into_iter().map(|w| w.name.clone()));
        out
    }
}

/// 网络地址解析辅助：这些校验函数同时被 `validate.rs` 与规则匹配层复用，
/// 集中一处可以避免「校验通过但匹配不通过」的双重标准。
pub fn parse_addr_list(values: &[String]) -> Vec<IpAddr> {
    values
        .iter()
        .filter_map(|v| v.trim().parse().ok())
        .collect()
}

pub fn is_ipv4_cidr(s: &str) -> bool {
    // CIDR 形式：a.b.c.d/len 或裸 IPv4
    let (addr, len) = match s.split_once('/') {
        Some((a, l)) => (a, l),
        None => (s, "32"),
    };
    // 任何 v4 地址都允许（含 0.0.0.0/0 默认路由），只校验语法与前缀长度。
    if addr.parse::<Ipv4Addr>().is_err() {
        return false;
    }
    len.parse::<u8>().map(|l| l <= 32).unwrap_or(false)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PortRange {
    pub start: u16,
    pub end: u16,
}

/// 解析 `443` 或 `8000-8010`；范围必须 start<=end，否则拒绝。
pub fn parse_port_range(s: &str) -> Option<PortRange> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    if let Some((a, b)) = s.split_once('-') {
        let start: u16 = a.trim().parse().ok()?;
        let end: u16 = b.trim().parse().ok()?;
        if start <= end {
            Some(PortRange { start, end })
        } else {
            None
        }
    } else {
        let p: u16 = s.parse().ok()?;
        Some(PortRange { start: p, end: p })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_safe_disabled() {
        let c = Config::default();
        assert!(!c.global.enabled, "默认必须关闭，安装即改路由是不可接受的");
        assert_eq!(c.global.config_version, crate::CONFIG_SCHEMA_VERSION);
        assert!(c.global.bypass_dst.iter().any(|s| s == "127.0.0.0/8"));
        assert_eq!(c.global.health.interval_ms, 1000);
        assert_eq!(c.global.health.timeout_ms, 800);
        assert_eq!(c.global.health.failure_threshold, 3);
        assert_eq!(c.global.health.recovery_threshold, 5);
    }

    #[test]
    fn every_algorithm_declares_limitations() {
        // UI 不得出现无说明的算法选项。
        for a in [
            Algorithm::SrcIp,
            Algorithm::SrcIpSrcPort,
            Algorithm::SrcIpDstIp,
            Algorithm::SrcIpDstIpDstPort,
            Algorithm::FullFiveTuple,
            Algorithm::LeastNewConnections,
            Algorithm::LeastTraffic,
            Algorithm::WeightedHash,
            Algorithm::WeightedEcmp,
        ] {
            assert!(!a.limitations().is_empty(), "{a:?} 缺少限制说明");
            assert!(!a.as_str().is_empty());
            assert_eq!(Algorithm::parse(a.as_str()), Some(a), "{a:?} 字符串不自洽");
        }
        assert!(Algorithm::LeastTraffic.is_dynamic());
        assert!(!Algorithm::LeastTraffic.is_static_hash());
        assert!(Algorithm::WeightedHash.is_static_hash());
    }

    #[test]
    fn failover_order_respects_explicit_roles_first() {
        let mut c = Config {
            wans: vec![wan("wan1", 30), wan("wan2", 10), wan("wan3", 20)],
            ..Default::default()
        };
        c.global.primary = "wan1".into();
        c.global.backup_order = vec!["wan3".into()];
        assert_eq!(c.failover_order(), vec!["wan1", "wan3", "wan2"]);
        // 主线路不存在时不能凭空捏造一个段名；但用户显式写的备份顺序仍是意图，保留。
        c.global.primary = "ghost".into();
        let o = c.failover_order();
        assert!(!o.contains(&"ghost".to_string()), "不能捏造不存在的线路");
        assert_eq!(
            o,
            vec!["wan3", "wan2", "wan1"],
            "失去主线路后按显式备份顺序，其余按 priority"
        );
        // 完全没有显式指定时，纯按 priority 升序（同优先级按段名，保证确定性）
        let d = Config {
            wans: vec![wan("wan1", 30), wan("wan2", 10), wan("wan3", 20)],
            ..Default::default()
        };
        assert_eq!(d.failover_order(), vec!["wan2", "wan3", "wan1"]);
    }

    #[test]
    fn active_wans_exclude_monitor_and_maintenance() {
        let mut c = Config::default();
        let a = wan("a", 1);
        let mut m = wan("m", 2);
        m.role = WanRole::Monitor;
        let mut mut_ = wan("t", 3);
        mut_.maintenance = true;
        let mut off = wan("o", 4);
        off.enabled = false;
        c.wans = vec![a.clone(), m, mut_, off];
        let names: Vec<&str> = c.active_wans().iter().map(|w| w.name.as_str()).collect();
        assert_eq!(names, ["a"]);
    }

    #[test]
    fn port_range_parsing() {
        assert_eq!(
            parse_port_range("443"),
            Some(PortRange {
                start: 443,
                end: 443
            })
        );
        assert_eq!(
            parse_port_range(" 8000-8010 "),
            Some(PortRange {
                start: 8000,
                end: 8010
            })
        );
        assert_eq!(parse_port_range("8010-8000"), None, "逆序范围必须拒绝");
        assert_eq!(parse_port_range("0"), Some(PortRange { start: 0, end: 0 }));
        assert_eq!(parse_port_range("70000"), None, "超范围端口必须拒绝");
        assert_eq!(parse_port_range(""), None);
    }

    #[test]
    fn cidr_validation() {
        assert!(is_ipv4_cidr("192.168.1.0/24"));
        assert!(is_ipv4_cidr("10.0.0.1"), "裸 IP 视为 /32");
        assert!(!is_ipv4_cidr("192.168.1.0/33"));
        assert!(!is_ipv4_cidr("fe80::/10"));
        assert!(!is_ipv4_cidr("abc"));
    }

    #[test]
    fn serde_roundtrip_covers_missing_fields() {
        // 老配置缺字段必须能读，且落到默认值（配置兼容要求）。
        let json = r#"{"global":{"mode":"failover","primary":"wan"}}"#;
        let c: Config = serde_json::from_str(json).unwrap();
        assert_eq!(c.global.mode, Mode::Failover);
        assert_eq!(c.global.primary, "wan");
        assert_eq!(c.global.algorithm, Algorithm::SrcIpDstIp, "缺字段应取默认");
        assert!(!c.global.enabled);
    }

    fn wan(name: &str, priority: u16) -> WanConfig {
        WanConfig {
            name: name.into(),
            priority,
            ..Default::default()
        }
    }
}

//! 规则匹配项的规范化（pure 逻辑，全部可单测）。
//!
//! 这一层的唯一职责是把 UCI 里用户写的字符串变成 **nft 集合元素能直接用的、
//! 形式唯一** 的文本，并给出 `GameSpec` 需要的族分拣结果。
//!
//! 为什么要把「规范化」单独做一层，而不是在生成 nft 文本时顺手处理：
//!
//! * **去重依赖形式一致**。`10.0.0.5/24` 与 `10.0.0.0/24` 若不归一，
//!   集合里就会留下两个元素，`size` 上限会被同义条目吃掉，
//!   而读者以为自己是「两条不同规则」。
//! * **网络位必须清零**。nft 的前缀集合按前缀匹配，`10.0.0.5/24` 的语义就是
//!   `10.0.0.0/24`；不归一只是不好看，但归一之后 `diff` 才有意义
//!   （配置改了没有、改了哪一条）。
//! * **排序保证可复现**。同一份配置两次生成的脚本必须逐字节相同，
//!   否则「回读校验」和「变更前后对比」都会误报。
//!
//! 本层不做的事：不判断业务合法性（那是 `config::validate` 的职责，
//! 它已经拒绝逆序端口段、非法 MAC、超范围前缀长度）；这里遇到非法输入
//! **直接报错**，绝不「跳过坏条目继续」—— 静默跳过会让一条本来要拦 10 个网段的
//! 规则变成拦 9 个，界面却显示规则已生效。

use std::net::IpAddr;

use crate::config::schema::parse_port_range;
use crate::{Error, Result};

/// 一个目的/客户端条目的规范化结果，已按族分好。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Addrs {
    pub v4: Vec<String>,
    pub v6: Vec<String>,
}

impl Addrs {
    pub fn len(&self) -> usize {
        self.v4.len() + self.v6.len()
    }
    pub fn is_empty(&self) -> bool {
        self.v4.is_empty() && self.v6.is_empty()
    }
    /// 合并另一个来源（用于「预置项 + 用户自定义」并集），保持已排序状态。
    pub fn extend_sorted(&mut self, other: &Addrs) {
        merge_into(&mut self.v4, &other.v4);
        merge_into(&mut self.v6, &other.v6);
    }
}

fn merge_into(dst: &mut Vec<String>, src: &[String]) {
    for s in src {
        if !dst.iter().any(|d| d == s) {
            dst.push(s.clone());
        }
    }
    dst.sort();
}

/// 把 `IpAddr` + 前缀长度归一到网络地址，输出 nft 前缀文本（`a.b.c.d/len`）。
///
/// 主机位非零时**不报错**：用户从地址簿里复制 `10.0.0.5/24` 是很常见的写法，
/// 语义明确（就是那个 /24），把它归一而不是拒绝，避免逼用户去学 CIDR 对齐。
pub fn normalize_prefix(s: &str) -> Option<String> {
    let (addr, len) = match s.split_once('/') {
        Some((a, l)) => {
            let a: IpAddr = a.trim().parse().ok()?;
            let max: u8 = if a.is_ipv6() { 128 } else { 32 };
            let l: u8 = l.trim().parse().ok()?;
            if l > max {
                return None;
            }
            (a, l)
        }
        // 裸地址：补满前缀，与 `config::validate` 的解释保持一致。
        None => {
            let a: IpAddr = s.trim().parse().ok()?;
            let max: u8 = if a.is_ipv6() { 128 } else { 32 };
            (a, max)
        }
    };
    let masked = mask(addr, len);
    Some(format!("{masked}/{len}"))
}

/// 按位清零主机位。用 u128 统一两族，避免两套移位代码。
fn mask(addr: IpAddr, len: u8) -> IpAddr {
    match addr {
        IpAddr::V4(v4) => {
            let raw = u32::from(v4);
            let keep: u32 = if len == 0 {
                0
            } else {
                u32::MAX << (32 - len.min(32))
            };
            IpAddr::V4(std::net::Ipv4Addr::from(raw & keep))
        }
        IpAddr::V6(v6) => {
            let raw = u128::from_be_bytes(v6.octets());
            let keep: u128 = if len == 0 {
                0
            } else {
                u128::MAX << (128 - len.min(128))
            };
            let bytes = (raw & keep).to_be_bytes();
            IpAddr::V6(std::net::Ipv6Addr::from(bytes))
        }
    }
}

/// 一批条目 → 按族分拣、归一、排序、去重。
///
/// `kind` 只用于错误信息（例如「目的网段」/「客户端地址」），让 UI 能把话说清楚。
pub fn split_normalize(items: &[String], kind: &str) -> Result<Addrs> {
    let mut out = Addrs::default();
    for raw in items {
        let t = raw.trim();
        if t.is_empty() {
            continue;
        }
        let norm = normalize_prefix(t)
            .ok_or_else(|| Error::Config(format!("{kind} 不是合法的 IP 或 CIDR：{raw}")))?;
        // 归一之后再判族，避免 `::ffff:1.2.3.4` 这类写法被字符串嗅探误分。
        let is_v6 = norm
            .split_once('/')
            .map(|(a, _)| a.parse::<IpAddr>().map(|i| i.is_ipv6()).unwrap_or(false))
            .unwrap_or(false);
        if is_v6 {
            out.v6.push(norm);
        } else {
            out.v4.push(norm);
        }
    }
    out.v4.sort();
    out.v4.dedup();
    out.v6.sort();
    out.v6.dedup();
    Ok(out)
}

/// 端口列表 → nft `th dport { ... }` 的元素文本列表。
///
/// 输出形态：单端口 `443`，范围 `8000-8010`。会拒绝：
/// * 无法解析的写法（含空格、逗号、`!` 取反等 —— 这些在 nft 一行里语义不明）；
/// * `0`（不是可传输端口，且 nft 里 `th dport 0` 几乎总是写错的产物）；
/// * 两端都写却逆序的段（`parse_port_range` 已拒绝，这里复用它保证与校验层同一套规则）。
pub fn normalize_ports(items: &[String]) -> Result<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for raw in items {
        let t = raw.trim();
        if t.is_empty() {
            continue;
        }
        if t.contains(char::is_whitespace) || t.contains(',') || t.starts_with('!') {
            return Err(Error::Config(format!("端口写法非法：{raw}")));
        }
        let r = parse_port_range(t)
            .ok_or_else(|| Error::Config(format!("端口写法非法或逆序：{raw}")))?;
        if r.end == 0 {
            return Err(Error::Config(format!("端口不能为 0：{raw}")));
        }
        if r.start == 0 {
            // 形如 `0-1024`：0 段本身没有意义，把它抬到 1 会静默改变用户意图，
            // 因此拒绝并请用户显式写起点。
            return Err(Error::Config(format!(
                "端口范围不能从 0 开始，请显式写起点（例如 1-{}）：{raw}",
                r.end
            )));
        }
        out.push(if r.start == r.end {
            r.start.to_string()
        } else {
            format!("{}-{}", r.start, r.end)
        });
    }
    out.sort();
    out.dedup();
    Ok(out)
}

/// MAC → 小写冒号分隔（nft `ether_addr` 集合的规范写法）。
///
/// 接受 `aa:bb:cc:dd:ee:ff`、`AA-BB-CC-DD-EE-FF`、`aabb.ccdd.eeff` 三种常见来源
/// （ip/bridge 转储、Windows、Cisco），统一成第一种。**不做前缀匹配、不接受
/// 「厂商 OUI 通配」**，因为半截 MAC 在集合里会变成一个具体地址而不是范围。
pub fn normalize_mac(raw: &str) -> Result<String> {
    let t = raw.trim().to_ascii_lowercase();
    if t.is_empty() {
        return Err(Error::Config("MAC 为空".into()));
    }
    let hex: String = t
        .chars()
        .filter(|c| *c != ':' && *c != '-' && *c != '.')
        .collect();
    if hex.len() != 12 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(Error::Config(format!(
            "MAC 非法（需要 12 个十六进制位）：{raw}"
        )));
    }
    let mut out = String::with_capacity(17);
    for (i, chunk) in hex.as_bytes().chunks(2).enumerate() {
        if i > 0 {
            out.push(':');
        }
        // chunk 来自已验证的 ASCII 十六进制串，长度恒为 2。
        out.push_str(std::str::from_utf8(chunk).unwrap_or_default());
    }
    Ok(out)
}

pub fn normalize_macs(items: &[String]) -> Result<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for raw in items {
        if raw.trim().is_empty() {
            continue;
        }
        out.push(normalize_mac(raw)?);
    }
    out.sort();
    out.dedup();
    Ok(out)
}

/// 域名清洗：去掉首尾点与空白、小写、拒绝带协议/路径/通配符的写法。
///
/// 通配符（`*.example.com`）在这里**拒绝而不是展开**：解析器不会返回「该域的全部子域」，
/// 展开只能靠猜，猜错的直接后果是把别人的 CDN 地址放进白名单。
pub fn normalize_domain(raw: &str) -> Result<String> {
    let t = raw.trim().trim_end_matches('.').to_ascii_lowercase();
    if t.is_empty() {
        return Err(Error::Config("域名为空".into()));
    }
    if t.contains('*') || t.contains('/') || t.contains(':') || t.contains('@') {
        return Err(Error::Config(format!(
            "域名写法不支持（通配符/URL/IP:port 都不做展开）：{raw}"
        )));
    }
    if t.len() > 253
        || !t
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
    {
        return Err(Error::Config(format!("域名非法或过长：{raw}")));
    }
    if t.split('.').count() < 2 || t.split('.').any(|l| l.is_empty()) {
        return Err(Error::Config(format!("域名至少要有一级后缀：{raw}")));
    }
    Ok(t)
}

pub fn normalize_domains(items: &[String]) -> Result<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for raw in items {
        if raw.trim().is_empty() {
            continue;
        }
        let d = normalize_domain(raw)?;
        if !out.iter().any(|e: &String| e == &d) {
            out.push(d);
        }
    }
    out.sort();
    Ok(out)
}

/// 由规则名生成 nft 对象名后缀。
///
/// 必须是 ASCII：nft 集合名进的是内核的命名空间，非 ASCII 在不同 nft 版本上的
/// 接受度不一致，而这里出错会导致整批提交失败。中文规则名保留在
/// `GameSpec.name` 与 nft `comment` 里供 UI 显示。
///
/// 规则：小写；非 `[a-z0-9]` 一律转 `_`；合并连续 `_`；去掉首尾 `_`；截断到 24 字节。
/// 结果为空（纯中文名）时返回空串，由上层用 `rule-<序号>` 兜底，
/// **序号按排序后的顺序给出，因此仍然确定**。
pub fn slug_of(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut prev_us = false;
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
            prev_us = false;
        } else if !prev_us {
            out.push('_');
            prev_us = true;
        }
    }
    let trimmed = out.trim_matches('_').to_string();
    // 截断到 24 字节。这里**不能**用 `crate::clamp_str`：它会追加
    // `…[截断 80→24 字节]` 这种给人看的标记，而 slug 要进 nft 对象名
    // （非 ASCII、还带空格）。本函数产出的字符集只有 `[a-z0-9_]`，
    // 因此按下标切一定是字符边界，不需要 clamp_str 的边界回退。
    let cut = if trimmed.len() > 24 {
        trimmed[..24].to_string()
    } else {
        trimmed
    };
    // 截断可能留下尾随 `_`。
    cut.trim_matches('_').to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_ip_gets_full_prefix() {
        assert_eq!(normalize_prefix("192.168.1.20").unwrap(), "192.168.1.20/32");
        assert_eq!(normalize_prefix("fe80::1").unwrap(), "fe80::1/128");
    }

    #[test]
    fn host_bits_are_masked_off() {
        assert_eq!(normalize_prefix("10.0.0.5/24").unwrap(), "10.0.0.0/24");
        assert_eq!(
            normalize_prefix("172.16.31.9/20").unwrap(),
            "172.16.16.0/20"
        );
        // 全零与全前缀边界。
        assert_eq!(normalize_prefix("0.0.0.0/0").unwrap(), "0.0.0.0/0");
        assert_eq!(normalize_prefix("::/0").unwrap(), "::/0");
        assert_eq!(
            normalize_prefix("2001:db8:ffff:1234::abcd/64").unwrap(),
            "2001:db8:ffff:1234::/64"
        );
    }

    #[test]
    fn rejects_bad_prefix() {
        assert!(normalize_prefix("10.0.0.0/33").is_none());
        assert!(normalize_prefix("::1/129").is_none());
        assert!(normalize_prefix("not-an-ip/24").is_none());
        assert!(normalize_prefix("").is_none());
        // 前缀不是数字：拒绝，不静默当成 /32。
        assert!(normalize_prefix("10.0.0.0/abc").is_none());
    }

    #[test]
    fn split_sorts_dedups_and_masks() {
        let a = split_normalize(
            &[
                "10.0.0.5/24".into(),
                "10.0.0.0/24".into(),
                "2001:db8::1".into(),
            ],
            "目的网段",
        )
        .unwrap();
        assert_eq!(
            a.v4,
            vec!["10.0.0.0/24".to_string()],
            "同义条目必须合成一条"
        );
        assert_eq!(a.v6, vec!["2001:db8::1/128".to_string()]);
        assert_eq!(a.len(), 2);
    }

    #[test]
    fn split_errors_on_junk_instead_of_skipping() {
        // 关键行为：坏条目报错，不能「丢掉它继续」。
        // 丢掉会让「拦 10 段」的规则变成「拦 9 段」，而界面仍显示已生效。
        let e = split_normalize(&["10.0.0.0/24".into(), "10.0.0.0/33".into()], "目的网段");
        assert!(e.is_err());
        assert!(e.unwrap_err().to_string().contains("目的网段"));
    }

    #[test]
    fn split_skips_blank_only() {
        let a = split_normalize(&["".into(), "  ".into(), "1.2.3.4".into()], "x").unwrap();
        assert_eq!(a.v4, vec!["1.2.3.4/32".to_string()]);
    }

    #[test]
    fn ports_normalized_and_sorted() {
        let p = normalize_ports(&["8010-8000-x".into()]).is_err();
        assert!(p, "非法端口文本必须被拒绝");
        let p = normalize_ports(&["443".into(), "8000-8010".into(), "443".into()]).unwrap();
        assert_eq!(p, vec!["443".to_string(), "8000-8010".to_string()]);
        // 排序按文本序：`443` 与 `8000-8010` 的相对次序不影响 nft 集合语义。
    }

    #[test]
    fn port_zero_rejected() {
        assert!(normalize_ports(&["0".to_string()]).is_err());
        assert!(normalize_ports(&["0-1024".to_string()]).is_err());
        assert!(normalize_ports(&["1-65535".to_string()]).unwrap() == vec!["1-65535".to_string()]);
        assert!(
            normalize_ports(&["8000-7999".to_string()]).is_err(),
            "逆序段拒绝"
        );
        assert!(
            normalize_ports(&["443,444".to_string()]).is_err(),
            "逗号不支持"
        );
        assert!(normalize_ports(&[" 443 ".to_string()]).unwrap() == vec!["443".to_string()]);
    }

    #[test]
    fn mac_three_input_forms_unified() {
        for f in [
            "AA:BB:CC:DD:EE:FF",
            "aa-bb-cc-dd-ee-ff",
            "aabb.ccdd.eeff",
            " AA:BB:CC:DD:EE:FF ",
        ] {
            assert_eq!(&normalize_mac(f).unwrap(), "aa:bb:cc:dd:ee:ff");
        }
        assert!(normalize_mac("aa:bb:cc:dd:ee").is_err());
        assert!(normalize_mac("aa:bb:cc:dd:ee:fg").is_err());
        assert!(normalize_mac("aa:bb:cc:dd:ee:ff:00").is_err());
        assert!(normalize_mac("").is_err());
        let v = normalize_macs(&[
            "AA:BB:CC:DD:EE:FF".into(),
            "aa:bb:cc:dd:ee:ff".into(),
            "11:22:33:44:55:66".into(),
        ])
        .unwrap();
        assert_eq!(
            v,
            vec![
                "11:22:33:44:55:66".to_string(),
                "aa:bb:cc:dd:ee:ff".to_string()
            ]
        );
    }

    #[test]
    fn domains_cleaned_and_wildcard_rejected() {
        assert_eq!(
            normalize_domain("Play.Steam-CDN.COM.").unwrap(),
            "play.steam-cdn.com"
        );
        assert!(normalize_domain("*.steam.com").is_err(), "通配符不展开");
        assert!(normalize_domain("https://a.com/").is_err());
        assert!(
            normalize_domain("localhost").is_err(),
            "无后缀的单标签名不当作域名"
        );
        assert!(normalize_domain("a..b.com").is_err());
        let v = normalize_domains(&["B.COM".into(), "a.com".into(), "b.com".into()]).unwrap();
        assert_eq!(v, vec!["a.com".to_string(), "b.com".to_string()]);
    }

    #[test]
    fn slug_is_ascii_and_deterministic() {
        assert_eq!(slug_of("PUBG EU"), "pubg_eu");
        assert_eq!(slug_of("Valorant (NA)"), "valorant_na");
        assert_eq!(slug_of("  --Weird..Name--  "), "weird_name");
        // 纯中文名 → 空串，由上层兜底（不能留空，nft 对象名不能为空）。
        assert_eq!(slug_of("绝地求生"), "");
        let long = slug_of(&"a".repeat(80));
        assert!(long.len() <= 24);
        // 截断可能正好落在 `_` 上，必须再剪一次尾：nft 对象名以分隔符结尾很难读。
        assert!(!slug_of(&("ab_".repeat(20) + "cd")).ends_with('_'));
        assert_eq!(
            slug_of(&("ab_".repeat(20) + "cd")),
            "ab_ab_ab_ab_ab_ab_ab_ab"
        );
        // 数字与字母混排不被破坏（nft 对象名允许字母数字下划线点横线）。
        assert_eq!(slug_of("FIFA 23"), "fifa_23");
    }

    #[test]
    fn extend_sorted_keeps_order_and_unique() {
        let mut a = Addrs {
            v4: vec!["10.0.0.0/24".into()],
            v6: vec![],
        };
        let b = Addrs {
            v4: vec!["10.0.0.0/24".into(), "1.2.3.4/32".into()],
            v6: vec!["2001:db8::/32".into()],
        };
        a.extend_sorted(&b);
        assert_eq!(
            a.v4,
            vec!["1.2.3.4/32".to_string(), "10.0.0.0/24".to_string()]
        );
        assert_eq!(a.v6, vec!["2001:db8::/32".to_string()]);
    }
}

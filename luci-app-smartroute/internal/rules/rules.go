// Package rules 把 xray 格式的规则组编译成 eBPF 表的内容：域名后缀哈希 → 规则组位图、网段 → 规则组位图。
package rules

import (
	"net/netip"
	"path/filepath"
	"slices"
	"strings"
)

type Group struct {
	Bit   uint64 // 该规则组的位
	Rules []string
}

type Prefix struct {
	P    netip.Prefix
	Bits uint64
}

type Result struct {
	Domains map[uint64]uint64 // 域名后缀哈希 → 规则组位图
	V4, V6  []Prefix          // 已合并，可直接写入前缀树
	Skipped map[string]int    // 跳过的规则：原因代码（full keyword regexp dotless plain format domain nofile:文件 nocat:类别；数据文件里自带的为 dat:regexp dat:keyword）→ 条数
	Count   int               // 展开后的条目数
	PerBit  map[uint64]int    // 每个规则组展开后的条目数
	// 写入内核表后 Domains/V4/V6 会被释放，条数另存
	NDomains, NV4, NV6 int
}

// Compile 编译规则组。geosite:/geoip: 读 dir 下的 geosite.dat / geoip.dat，ext:文件:类别 读 dir 下的文件
func Compile(groups []Group, dir string) *Result {
	r := &Result{Domains: map[uint64]uint64{}, Skipped: map[string]int{}, PerBit: map[uint64]int{}}
	var ips []Prefix

	// 先收集每个数据文件需要的类别，每个文件只读一次
	type ref struct {
		file, code, attr string
		g                *Group
	}
	var refs []ref
	need := map[string]map[string]bool{}
	for i := range groups {
		g := &groups[i]
		for _, raw := range g.Rules {
			s := strings.TrimSpace(raw)
			if s == "" || s[0] == '#' {
				continue
			}
			kind, val, _ := strings.Cut(s, ":")
			switch kind {
			case "geosite", "geoip", "ext":
				file := kind + ".dat"
				if kind == "ext" {
					f, c, ok := strings.Cut(val, ":")
					if !ok || strings.ContainsAny(f, "/\\") {
						r.Skipped["format"]++
						continue
					}
					file, val = f, c
				}
				code, attr, _ := strings.Cut(val, "@")
				code = strings.ToUpper(code)
				if need[file] == nil {
					need[file] = map[string]bool{}
				}
				need[file][code] = true
				refs = append(refs, ref{file, code, strings.ToLower(attr), g})
			case "domain", "full":
				if kind == "full" {
					r.Skipped["full"]++
				}
				addDomain(r, val, g.Bit)
			case "keyword", "regexp", "dotless":
				r.Skipped[kind]++
			default:
				if p, ok := ParsePrefix(s); ok {
					ips = append(ips, Prefix{p, g.Bit})
					r.Count++
					r.PerBit[g.Bit]++
				} else {
					r.Skipped["plain"]++
				}
			}
		}
	}

	byCode := map[string][]ref{}
	for _, rf := range refs {
		byCode[rf.file+":"+rf.code] = append(byCode[rf.file+":"+rf.code], rf)
	}
	found := map[string]bool{}
	for file, codes := range need {
		err := ReadDat(filepath.Join(dir, file), codes, func(code string, it *Item) {
			found[file+":"+code] = true
			for _, rf := range byCode[file+":"+code] {
				switch {
				case it.IsIP:
					ips = append(ips, Prefix{it.CIDR, rf.g.Bit})
					r.Count++
					r.PerBit[rf.g.Bit]++
				case !attrMatch(it.Attrs, rf.attr):
				case it.Type == DomRoot, it.Type == DomFull:
					addDomain(r, it.Value, rf.g.Bit)
				case it.Type == DomRegex: // 数据文件自带、用户无法改动：界面上只作普通提示
					r.Skipped["dat:regexp"]++
				default:
					r.Skipped["dat:keyword"]++
				}
			}
		})
		if err != nil {
			r.Skipped["nofile:"+file]++
			found[file+":"] = true // 已报过文件不可用，不再逐个报类别
		}
	}
	for _, rf := range refs {
		if !found[rf.file+":"+rf.code] && !found[rf.file+":"] {
			r.Skipped["nocat:"+strings.ToLower(rf.code)]++
		}
	}

	for _, p := range ips {
		if p.P.Addr().Is4() {
			r.V4 = append(r.V4, p)
		} else {
			r.V6 = append(r.V6, p)
		}
	}
	r.V4, r.V6 = Merge(r.V4), Merge(r.V6)
	r.NDomains, r.NV4, r.NV6 = len(r.Domains), len(r.V4), len(r.V6)
	return r
}

// attrMatch：geosite:类别@属性 只取带该属性的域名，@!属性 取不带的
func attrMatch(attrs [][]byte, want string) bool {
	if want == "" {
		return true
	}
	name := strings.TrimPrefix(want, "!")
	has := slices.ContainsFunc(attrs, func(a []byte) bool { return strings.EqualFold(string(a), name) })
	return has != (len(name) != len(want))
}

func addDomain[T ~string | ~[]byte](r *Result, d T, bit uint64) {
	h, ok := DomainHash(d)
	if !ok {
		r.Skipped["domain"]++
		return
	}
	r.Domains[h] |= bit
	r.Count++
	r.PerBit[bit]++
}

// ParsePrefix 解析网段或单个地址（单个地址按 /32、/128）
func ParsePrefix(s string) (netip.Prefix, bool) {
	if p, err := netip.ParsePrefix(s); err == nil {
		return p.Masked(), true
	}
	if a, err := netip.ParseAddr(s); err == nil {
		return netip.PrefixFrom(a, a.BitLen()), true
	}
	return netip.Prefix{}, false
}

// DomainHash 与 eBPF dom_groups() 一致：线格式（小写，含结尾 0）逆序逐字节 FNV-1a 64。
// 逆序即：结尾 0，然后从最后一个标签起，每个标签先逆序过字符、再过长度字节。不分配内存。
// 线格式超过 128 字节的域名在 eBPF 里存不下，返回 false。
func DomainHash[T ~string | ~[]byte](d T) (uint64, bool) {
	const prime = 0x100000001b3
	end := len(d)
	for end > 0 && (d[end-1] == '.' || d[end-1] == ' ') {
		end--
	}
	start := 0
	for start < end && d[start] == ' ' {
		start++
	}
	if start == end {
		return 0, false
	}
	h := uint64(0xcbf29ce484222325)
	h *= prime // 结尾 0：(h ^ 0) * prime
	total := 1
	for i := end - 1; i >= start-1; i-- {
		if i >= start && d[i] != '.' {
			continue
		}
		n := end - i - 1 // 标签 d[i+1:end]
		if n == 0 || n > 63 {
			return 0, false
		}
		for j := end - 1; j > i; j-- {
			c := d[j]
			if c >= 'A' && c <= 'Z' {
				c |= 0x20
			}
			h = (h ^ uint64(c)) * prime
		}
		h = (h ^ uint64(n)) * prime
		total += n + 1
		end = i
	}
	if total > 128 {
		return 0, false
	}
	return h, true
}

// Merge 合并同一前缀的位图，并让嵌套的内层前缀继承外层位图（eBPF 前缀树只返回最长匹配）。输入须为同一地址族。
func Merge(in []Prefix) []Prefix {
	m := map[netip.Prefix]uint64{}
	for _, p := range in {
		m[p.P.Masked()] |= p.Bits
	}
	out := make([]Prefix, 0, len(m))
	for p, b := range m {
		out = append(out, Prefix{p, b})
	}
	// 按起始地址排序，同起点短前缀在前：外层总排在它包含的前缀之前
	slices.SortFunc(out, func(a, b Prefix) int {
		if c := a.P.Addr().Compare(b.P.Addr()); c != 0 {
			return c
		}
		return a.P.Bits() - b.P.Bits()
	})
	var stack []Prefix
	for i := range out {
		for len(stack) > 0 && !stack[len(stack)-1].P.Contains(out[i].P.Addr()) {
			stack = stack[:len(stack)-1]
		}
		if len(stack) > 0 {
			out[i].Bits |= stack[len(stack)-1].Bits
		}
		stack = append(stack, out[i])
	}
	return out
}

package rules

import (
	"encoding/binary"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

// 参考值来自 PVE 上已验证命中的 m1.sh 实现
func TestDomainHash(t *testing.T) {
	for d, want := range map[string]uint64{"foreign.lab": 0xcb07557d2e8ff7f2, "Foreign.LAB.": 0xcb07557d2e8ff7f2, "lab": 0xb0d9e2be492e299b} {
		if h, ok := DomainHash(d); !ok || h != want {
			t.Errorf("%s = %x", d, h)
		}
	}
	for _, d := range []string{"", "a..b", string(make([]byte, 64)) + ".com"} {
		if _, ok := DomainHash(d); ok {
			t.Errorf("%q 应被拒绝", d)
		}
	}
}

func TestMerge(t *testing.T) {
	p := func(s string, b uint64) Prefix { return Prefix{netip.MustParsePrefix(s), b} }
	got := Merge([]Prefix{p("10.1.2.0/24", 2), p("10.0.0.0/8", 1), p("10.1.0.0/16", 4), p("11.0.0.0/8", 8), p("10.0.0.0/8", 16)})
	want := map[string]uint64{"10.0.0.0/8": 17, "10.1.0.0/16": 21, "10.1.2.0/24": 23, "11.0.0.0/8": 8}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for _, g := range got {
		if want[g.P.String()] != g.Bits {
			t.Errorf("%s = %d, want %d", g.P, g.Bits, want[g.P.String()])
		}
	}
}

// 手工拼 protobuf
func msg(fs ...[]byte) []byte {
	var b []byte
	for _, f := range fs {
		b = append(b, f...)
	}
	return b
}
func bytesF(num int, d []byte) []byte {
	b := binary.AppendUvarint(nil, uint64(num<<3|2))
	b = binary.AppendUvarint(b, uint64(len(d)))
	return append(b, d...)
}
func varF(num int, v uint64) []byte {
	return binary.AppendUvarint(binary.AppendUvarint(nil, uint64(num<<3)), v)
}

func TestCompile(t *testing.T) {
	dir := t.TempDir()
	site := msg(
		bytesF(1, msg(bytesF(1, []byte("CN")), bytesF(2, msg(varF(1, DomRoot), bytesF(2, []byte("cn.lab")))))),
		bytesF(1, msg(bytesF(1, []byte("FOREIGN")),
			bytesF(2, msg(varF(1, DomRoot), bytesF(2, []byte("a.lab")), bytesF(3, bytesF(1, []byte("cn"))))),
			bytesF(2, msg(varF(1, DomFull), bytesF(2, []byte("b.lab")))),
			bytesF(2, msg(bytesF(2, []byte("kw")))), // type 省略 = keyword
			bytesF(2, msg(varF(1, DomRegex), bytesF(2, []byte("^x")))))),
	)
	ip := msg(bytesF(1, msg(bytesF(1, []byte("CN")),
		bytesF(2, msg(bytesF(1, []byte{223, 5, 5, 0}), varF(2, 24))),
		bytesF(2, msg(bytesF(1, netip.MustParseAddr("240e::").AsSlice()), varF(2, 20))))))
	os.WriteFile(filepath.Join(dir, "geosite.dat"), site, 0o644)
	os.WriteFile(filepath.Join(dir, "geoip.dat"), ip, 0o644)

	r := Compile([]Group{
		{Bit: 1, Rules: []string{"geoip:cn", "geosite:cn"}},
		{Bit: 2, Rules: []string{"geosite:foreign@!cn", "domain:x.lab", "keyword:foo", "1.2.3.4", "223.5.5.5", "geosite:nope", "ext:geosite.dat:foreign@cn"}},
	}, dir)

	hash := func(d string) uint64 { h, _ := DomainHash(d); return h }
	for d, want := range map[string]uint64{"cn.lab": 1, "b.lab": 2, "x.lab": 2, "a.lab": 2} {
		if r.Domains[hash(d)] != want {
			t.Errorf("domain %s = %d, want %d", d, r.Domains[hash(d)], want)
		}
	}
	v4 := map[string]uint64{}
	for _, p := range r.V4 {
		v4[p.P.String()] = p.Bits
	}
	if v4["223.5.5.0/24"] != 1 || v4["223.5.5.5/32"] != 3 || v4["1.2.3.4/32"] != 2 || len(r.V6) != 1 || r.V6[0].Bits != 1 {
		t.Errorf("v4 %v v6 %v", v4, r.V6)
	}
	for _, k := range []string{"keyword", "dat:regexp", "dat:keyword", "nocat:nope"} { // 用户写的 keyword 与数据文件自带的分开计数
		if r.Skipped[k] == 0 {
			t.Errorf("skipped 缺少 %q: %v", k, r.Skipped)
		}
	}
}

// 用真实数据文件：DAT_DIR=目录 go test -run Real -v
func TestRealDat(t *testing.T) {
	dir := os.Getenv("DAT_DIR")
	if dir == "" {
		t.Skip("DAT_DIR 未设置")
	}
	r := Compile([]Group{{Bit: 1, Rules: []string{"geosite:cn", "geoip:cn"}}, {Bit: 2, Rules: []string{"geosite:geolocation-!cn"}}}, dir)
	t.Logf("count=%d domains=%d v4=%d v6=%d skipped=%v", r.Count, len(r.Domains), len(r.V4), len(r.V6), r.Skipped)
	if len(r.Domains) < 1000 || len(r.V4) < 1000 {
		t.Fatal("条目过少")
	}
}

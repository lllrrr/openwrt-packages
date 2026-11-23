package rules

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"strings"
	"syscall"
)

// geosite.dat / geoip.dat 是 protobuf：
//   GeoSiteList{1: GeoSite{1: code, 2: Domain{1: type, 2: value, 3: Attribute{1: key}}}}
//   GeoIPList  {1: GeoIP  {1: code, 2: CIDR{1: ip bytes, 2: prefix}}}
// 两者外层结构相同，按条目内容区分：CIDR 的字段 1 是 bytes，Domain 的字段 1 是 varint（或省略）。
// 只解析需要的类别，其余整段跳过；条目逐条回调，不在内存里保留（真实数据十几万条）。

const (
	DomPlain = 0 // keyword，不支持
	DomRegex = 1
	DomRoot  = 2 // domain:
	DomFull  = 3
)

// Item 是数据文件里的一条：网段（IsIP）或域名。Value、Attrs 指向文件内容，回调返回后不再有效
type Item struct {
	IsIP  bool
	CIDR  netip.Prefix
	Type  int
	Value []byte
	Attrs [][]byte
}

var errStop = errors.New("stop")

// fields 逐个遍历 protobuf 字段；wt=0 时 v 为取值，wt=2 时 data 为内容
func fields(b []byte, fn func(num, wt int, v uint64, data []byte) error) error {
	for len(b) > 0 {
		key, n := binary.Uvarint(b)
		if n <= 0 {
			return errors.New("数据文件损坏")
		}
		b = b[n:]
		num, wt := int(key>>3), int(key&7)
		var v uint64
		var data []byte
		switch wt {
		case 0:
			v, n = binary.Uvarint(b)
			if n <= 0 {
				return errors.New("数据文件损坏")
			}
			b = b[n:]
		case 2:
			l, n := binary.Uvarint(b)
			if n <= 0 || l > uint64(len(b)-n) {
				return errors.New("数据文件损坏")
			}
			data, b = b[n:n+int(l)], b[n+int(l):]
		case 1, 5:
			sz := map[int]int{1: 8, 5: 4}[wt]
			if len(b) < sz {
				return errors.New("数据文件损坏")
			}
			b = b[sz:]
			continue
		default:
			return errors.New("数据文件损坏")
		}
		if err := fn(num, wt, v, data); err != nil {
			return err
		}
	}
	return nil
}

// ReadDat 逐条回调数据文件中 codes 列出的类别（大写）的条目
func ReadDat(path string, codes map[string]bool, fn func(code string, it *Item)) error {
	return mmap(path, func(b []byte) error { return parseDat(b, codes, fn) })
}

// CountDat 返回数据文件里的类别数，用于校验下载的内容
func CountDat(path string) (n int, err error) {
	err = mmap(path, func(b []byte) error {
		return fields(b, func(num, wt int, _ uint64, _ []byte) error {
			if num == 1 && wt == 2 {
				n++
			}
			return nil
		})
	})
	return
}

// Codes 返回数据文件里的全部类别（小写）
func Codes(path string) (out []string, err error) {
	err = mmap(path, func(b []byte) error {
		return fields(b, func(num, wt int, _ uint64, ent []byte) error {
			if num == 1 && wt == 2 {
				fields(ent, func(num, wt int, _ uint64, d []byte) error {
					if num == 1 && wt == 2 {
						out = append(out, strings.ToLower(string(d)))
						return errStop
					}
					return nil
				})
			}
			return nil
		})
	})
	return
}

// mmap：不把整个文件读进堆内存，未选中的类别不占内存
func mmap(path string, fn func([]byte) error) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.Size() == 0 {
		return fmt.Errorf("%s 为空", path)
	}
	b, err := syscall.Mmap(int(f.Fd()), 0, int(st.Size()), syscall.PROT_READ, syscall.MAP_SHARED)
	if err != nil {
		return err
	}
	defer syscall.Munmap(b)
	return fn(b)
}

func parseDat(b []byte, codes map[string]bool, fn func(string, *Item)) error {
	var it Item
	return fields(b, func(num, wt int, _ uint64, ent []byte) error {
		if num != 1 || wt != 2 {
			return nil
		}
		code := ""
		fields(ent, func(num, wt int, _ uint64, d []byte) error {
			if num == 1 && wt == 2 {
				code = strings.ToUpper(string(d))
				return errStop
			}
			return nil
		})
		if !codes[code] {
			return nil
		}
		return fields(ent, func(num, wt int, _ uint64, item []byte) error {
			if num != 2 || wt != 2 {
				return nil
			}
			if err := parseItem(item, &it); err != nil {
				return err
			}
			if !it.IsIP || it.CIDR.IsValid() {
				fn(code, &it)
			}
			return nil
		})
	})
}

func parseItem(item []byte, it *Item) error {
	*it = Item{Attrs: it.Attrs[:0]}
	var ip []byte
	prefix := 0
	err := fields(item, func(num, wt int, v uint64, data []byte) error {
		switch {
		case num == 1 && wt == 2:
			ip, it.IsIP = data, true
		case num == 1 && wt == 0:
			it.Type = int(v)
		case num == 2 && wt == 0:
			prefix = int(v)
		case num == 2 && wt == 2:
			it.Value = data
		case num == 3 && wt == 2:
			fields(data, func(num, wt int, _ uint64, k []byte) error {
				if num == 1 && wt == 2 {
					it.Attrs = append(it.Attrs, k)
				}
				return nil
			})
		}
		return nil
	})
	if err == nil && it.IsIP {
		if a, ok := netip.AddrFromSlice(ip); ok {
			if p, e := a.Unmap().Prefix(prefix); e == nil {
				it.CIDR = p
			}
		}
	}
	return err
}

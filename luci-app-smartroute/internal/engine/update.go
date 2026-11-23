package engine

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/r1172464137/luci-app-smartroute/internal/rules"
)

const maxDat = 64 << 20

// Fetch 下载数据文件到 dir/name。只允许 http/https；内容没变不覆盖；下载失败或解析不出类别时保留旧文件。
// mark ≠ 0 时连接带上该出口的 mark，经该出口下载
func Fetch(url, dir, name string, mark uint32) (changed bool, err error) {
	if !strings.HasPrefix(url, "https://") && !strings.HasPrefix(url, "http://") {
		return false, fmt.Errorf("%s: only http/https addresses are allowed", name)
	}
	d := &net.Dialer{Timeout: 30 * time.Second, Control: func(_, _ string, rc syscall.RawConn) error {
		if mark != 0 {
			rc.Control(func(fd uintptr) { unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, int(mark)) })
		}
		return nil
	}}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = d.DialContext
	c := http.Client{Timeout: 5 * time.Minute, Transport: tr}
	resp, err := c.Get(url)
	if err != nil {
		return false, fmt.Errorf("download %s: %w", name, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("download %s: HTTP %d", name, resp.StatusCode)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return false, err
	}
	dst := filepath.Join(dir, name)
	tmp := dst + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return false, err
	}
	defer os.Remove(tmp)
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, maxDat+1))
	f.Close()
	if err != nil {
		return false, fmt.Errorf("download %s: %w", name, err)
	}
	if n > maxDat {
		return false, fmt.Errorf("%s is larger than %d MB", name, maxDat>>20)
	}
	if cnt, err := rules.CountDat(tmp); err != nil || cnt == 0 {
		return false, fmt.Errorf("%s is not a valid data file, the old file is kept", name)
	}
	if old, err := os.Open(dst); err == nil {
		oh := sha256.New()
		io.Copy(oh, old)
		old.Close()
		if bytes.Equal(oh.Sum(nil), h.Sum(nil)) {
			return false, nil
		}
	}
	return true, os.Rename(tmp, dst)
}

// FetchAll 更新 geosite.dat 与 geoip.dat，任一有变化返回 true。mark：下载出口的 mark（0 = 直连）
func FetchAll(s Settings, dir string, mark uint32) (changed bool, errs []error) {
	for _, f := range [][2]string{{s.GeositeURL, "geosite.dat"}, {s.GeoipURL, "geoip.dat"}} {
		c, err := Fetch(f[0], dir, f[1], mark)
		changed = changed || c
		if err != nil {
			errs = append(errs, err)
		}
	}
	return
}

// Package uci 解析 `uci -X show <包>` 的输出，按出现顺序返回配置段。
package uci

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

type Section struct {
	Name, Type string
	Opts       map[string][]string
}

func (s *Section) Get(k string) string {
	if v := s.Opts[k]; len(v) > 0 {
		return v[0]
	}
	return ""
}

func (s *Section) GetDef(k, def string) string {
	if v := s.Get(k); v != "" {
		return v
	}
	return def
}

func (s *Section) Bool(k string, def bool) bool {
	switch s.Get(k) {
	case "1", "on", "true", "yes", "enabled":
		return true
	case "0", "off", "false", "no", "disabled":
		return false
	}
	return def
}

func Load(pkg string) ([]*Section, error) {
	out, err := exec.Command("uci", "-X", "show", pkg).Output()
	if err != nil {
		return nil, fmt.Errorf("uci show %s: %w", pkg, err)
	}
	return Parse(string(out))
}

func Parse(text string) ([]*Section, error) {
	var out []*Section
	idx := map[string]*Section{}
	for n, line := range strings.Split(text, "\n") {
		if line == "" {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("uci 第 %d 行缺少 '='", n+1)
		}
		parts := strings.SplitN(key, ".", 3)
		switch len(parts) {
		case 2:
			s := &Section{Name: parts[1], Type: val, Opts: map[string][]string{}}
			idx[s.Name] = s
			out = append(out, s)
		case 3:
			s := idx[parts[1]]
			if s == nil {
				return nil, fmt.Errorf("uci 第 %d 行：未知配置段 %s", n+1, parts[1])
			}
			vals, err := unquote(val)
			if err != nil {
				return nil, fmt.Errorf("uci 第 %d 行：%w", n+1, err)
			}
			s.Opts[parts[2]] = vals
		}
	}
	return out, nil
}

// unquote 拆分 uci show 的取值：列表为空格分隔的 'a' 'b'，单引号内的 ' 写作 '\”
func unquote(s string) ([]string, error) {
	var out []string
	for s != "" {
		if s[0] == ' ' {
			s = s[1:]
			continue
		}
		var b strings.Builder
		for s != "" && s[0] != ' ' {
			switch {
			case s[0] == '\'':
				end := strings.IndexByte(s[1:], '\'')
				if end < 0 {
					return nil, errors.New("引号未闭合")
				}
				b.WriteString(s[1 : 1+end])
				s = s[2+end:]
			case s[0] == '\\' && len(s) > 1:
				b.WriteByte(s[1])
				s = s[2:]
			default:
				b.WriteByte(s[0])
				s = s[1:]
			}
		}
		out = append(out, b.String())
	}
	return out, nil
}

// workbuddy-pool —— 上游连接池反向代理（常驻小程序）
//
// 为什么需要它：
//
//	luci-app-workbuddy 每次转发都是一次 `curl` 子进程，curl 用完即退，
//	TCP 与 TLS 会话随进程一起消失。于是每个请求都要重新付：
//	    DNS 解析 ~9ms + TCP 三次握手 49~87ms + TLS 握手 80~100ms
//	实测固定开销 130~190ms，占一次 1.5s 推理请求的 9~13%；
//	而 curl 自己只是"发起方"，没有任何跨请求复用的能力。
//
// 它做什么：
//
//	在 127.0.0.1:<port> 上开一个明文 HTTP 反向代理。ucode 侧的 curl 不再直连
//	https://上游，而是连本机回环（几乎零成本），由本进程持有到上游的
//	keep-alive 连接池（含 TLS 会话），按需复用。
//
//	  改动前： curl --(TCP+TLS 握手 ~130-190ms)--> 上游
//	  改动后： curl --(回环 ~0.2ms)--> workbuddy-pool --(复用已建立的连接 ~0ms)--> 上游
//
//	协议约定（只有一条）：请求头 `X-WB-Target: https://host[:port]` 指明上游基址，
//	请求路径与查询串原样透传。例如
//	    POST http://127.0.0.1:8790/v1/chat/completions
//	    X-WB-Target: https://token.sensenova.cn
//	转发到 https://token.sensenova.cn/v1/chat/completions。
//
// 关键设计取舍：
//
//  1. 解压关闭（DisableCompression）：SSE 必须逐字节原样透传。若让 Go 自动加
//     Accept-Encoding 并透明解压，一是会改变上游看到的请求，二是多一层缓冲
//     反而抬高首字节延迟。
//  2. 逐块 Flush：每读到一块就 Write + Flush，保证流式首字节不被 net/http 的
//     写缓冲吞掉（默认 bufio 4KB 会攒够才发，SSE 会被整段延迟，这是本方案
//     最大的风险点，所以单独写了流式回归测试）。
//  3. 保活预热（-keepalive）：这才是池化收益的关键。两轮对话常间隔几十秒，
//     NAT/上游任意一侧都可能把空闲连接回收，若不预热，每个请求照样从零握手，
//     池子等于白建。空闲超过该时长就发一个无害的 GET / 把连接"续上"。
//  4. ResponseHeaderTimeout=0：WorkBuddy 是 agent 上游，可能在长时间思考后才
//     吐首字节。超时判断交给 ucode 的静默看门狗与 curl 的 --speed-time，
//     本进程不重复设一套容易误杀的阈值。
//  5. 只监听回环，且要求 target 带 scheme：主服务对公网开放（wan_access），
//     本进程绝不能成为可被外部利用的开放代理。
//  6. 并发安全：转发在各自 goroutine 里跑，保活循环与 /stats 在别的 goroutine
//     里读同一份数据。计数器用 atomic，环形缓冲与 lastActivity 用互斥锁 ——
//     早期版本漏了锁，`go build -race` 能直接报出来。
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const appVersion = "1.0.0"

// 逐跳头（RFC 7230 §6.1）不得透传，否则会出现"客户端让上游关连接"这类副作用。
var hopHeaders = map[string]bool{
	"connection":          true,
	"proxy-connection":    true,
	"keep-alive":          true,
	"proxy-authenticate":  true,
	"proxy-authorization": true,
	"te":                  true,
	"trailer":             true,
	"transfer-encoding":   true,
	"upgrade":             true,
}

// 定长环形缓冲：只保留最近 N 个样本，进程长跑也不会无界增长。
type ring struct {
	v []float64
}

const ringCap = 256

func (r *ring) add(x float64) {
	r.v = append(r.v, x)
	if len(r.v) > ringCap {
		r.v = r.v[len(r.v)-ringCap:]
	}
}

// 调用方必须已持有宿主互斥锁。
func (r *ring) pct(p float64) float64 {
	n := len(r.v)
	if n == 0 {
		return 0
	}
	c := make([]float64, n)
	copy(c, r.v)
	sort.Float64s(c)
	i := int(p/100*float64(n-1) + 0.5)
	if i < 0 {
		i = 0
	}
	if i >= n {
		i = n - 1
	}
	return c[i]
}

type hostState struct {
	base string // scheme://host[:port]，保活预热用

	requests     atomic.Int64 // 用户请求数（不含预热）
	active       atomic.Int64
	errors       atomic.Int64
	newConns     atomic.Int64 // 未能复用、被迫新建连接的次数
	reusedConns  atomic.Int64 // 命中连接池的次数
	warmRequests atomic.Int64
	bytesOut     atomic.Int64
	lastActive   atomic.Int64 // UnixNano
	lastErr      atomic.Value // string

	// 以下字段由 mu 保护（转发 goroutine 写、/stats 与保活循环读）
	mu       sync.Mutex
	dns      ring
	connWait ring
	tls      ring
	ttfb     ring
	total    ring
	// 新建连接 vs 复用连接的首字节对比：池化到底省了多少，看这两个的差
	ttfbNew    ring
	ttfbReused ring
}

type timings struct {
	dns, connWait, tls, ttfb, total float64
	reused                          bool
}

func (h *hostState) touch() { h.lastActive.Store(time.Now().UnixNano()) }

func (h *hostState) idleSeconds() float64 {
	ns := h.lastActive.Load()
	if ns == 0 {
		return 0
	}
	return time.Since(time.Unix(0, ns)).Seconds()
}

func (h *hostState) addTimings(t timings) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.dns.add(t.dns)
	h.connWait.add(t.connWait)
	h.tls.add(t.tls)
	h.ttfb.add(t.ttfb)
	h.total.add(t.total)
	if t.reused {
		h.ttfbReused.add(t.ttfb)
	} else {
		h.ttfbNew.add(t.ttfb)
	}
}

type pctSet struct {
	dnsP50, connWaitP50, tlsP50 float64
	ttfbP50, ttfbP90, ttfbP99   float64
	totalP50, totalP99          float64
	ttfbNewP50, ttfbReusedP50   float64
	samples                     int
}

func (h *hostState) pcts() pctSet {
	h.mu.Lock()
	defer h.mu.Unlock()
	return pctSet{
		dnsP50: h.dns.pct(50), connWaitP50: h.connWait.pct(50), tlsP50: h.tls.pct(50),
		ttfbP50: h.ttfb.pct(50), ttfbP90: h.ttfb.pct(90), ttfbP99: h.ttfb.pct(99),
		totalP50: h.total.pct(50), totalP99: h.total.pct(99),
		ttfbNewP50: h.ttfbNew.pct(50), ttfbReusedP50: h.ttfbReused.pct(50),
		samples: len(h.total.v),
	}
}

func (h *hostState) setErr(msg string) {
	if len(msg) > 300 {
		msg = msg[:300]
	}
	h.lastErr.Store(msg)
}

func (h *hostState) errString() string {
	if v := h.lastErr.Load(); v != nil {
		return v.(string)
	}
	return ""
}

type server struct {
	listen    string
	keepalive time.Duration
	verbose   bool

	transport *http.Transport

	statsMu sync.Mutex
	hosts   map[string]*hostState

	started  time.Time
	reqTotal atomic.Int64
}

func newServer(listen string, keepalive time.Duration, verbose bool, idlePerHost int) *server {
	dialer := &net.Dialer{
		Timeout:   5 * time.Second,
		KeepAlive: 30 * time.Second,
	}
	tr := &http.Transport{
		Proxy:                 nil, // 绝不读环境变量代理，路由器上没有也不需要
		DialContext:           dialer.DialContext,
		ForceAttemptHTTP2:     true, // 上游支持 h2 时多路复用，一次握手并发多请求
		MaxIdleConns:          idlePerHost * 4,
		MaxIdleConnsPerHost:   idlePerHost,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   8 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		ResponseHeaderTimeout: 0,
		DisableCompression:    true, // 见文件头「关键设计取舍 1」
	}
	return &server{
		listen:    listen,
		keepalive: keepalive,
		verbose:   verbose,
		transport: tr,
		hosts:     map[string]*hostState{},
		started:   time.Now(),
	}
}

func (s *server) state(base string) *hostState {
	s.statsMu.Lock()
	defer s.statsMu.Unlock()
	h, ok := s.hosts[base]
	if !ok {
		h = &hostState{base: base}
		s.hosts[base] = h
	}
	return h
}

func (s *server) snapshotHosts() []*hostState {
	s.statsMu.Lock()
	defer s.statsMu.Unlock()
	out := make([]*hostState, 0, len(s.hosts))
	for _, v := range s.hosts {
		out = append(out, v)
	}
	return out
}

// 路径拼接：target 可能自带前缀（如 https://gw.example.com/api），此时要与
// 请求路径拼起来而不是覆盖。
func joinPath(a, b string) string {
	as := strings.HasSuffix(a, "/")
	bs := strings.HasPrefix(b, "/")
	switch {
	case as && bs:
		return a + b[1:]
	case !as && !bs:
		return a + "/" + b
	default:
		return a + b
	}
}

// forward 是转发核心。warm=true 时是保活预热（不计入用户指标）。
func (s *server) forward(w http.ResponseWriter, r *http.Request, base string, warm bool) {
	bu, err := url.Parse(base)
	if err != nil || bu.Host == "" {
		http.Error(w, `{"error":{"message":"invalid target"}}`, http.StatusBadRequest)
		return
	}
	if bu.Scheme != "https" && bu.Scheme != "http" {
		http.Error(w, `{"error":{"message":"target must be http(s)"}}`, http.StatusBadRequest)
		return
	}

	h := s.state(base)
	start := time.Now()
	h.touch()

	if !warm {
		h.requests.Add(1)
		s.reqTotal.Add(1)
	}
	h.active.Add(1)
	defer h.active.Add(-1)

	outURL := *bu
	if warm {
		outURL.Path = joinPath(bu.Path, "/")
		outURL.RawQuery = ""
	} else {
		outURL.Path = joinPath(bu.Path, r.URL.Path)
		outURL.RawQuery = r.URL.RawQuery
	}

	var body io.Reader
	if !warm {
		body = r.Body
	}
	ctx := r.Context()
	req, err := http.NewRequestWithContext(ctx, r.Method, outURL.String(), body)
	if err != nil {
		s.fail(w, http.StatusBadGateway, "build request: "+err.Error())
		return
	}
	if !warm {
		// 原样搬请求头（跳过逐跳头与内部头）
		for k, vs := range r.Header {
			if hopHeaders[strings.ToLower(k)] {
				continue
			}
			if strings.EqualFold(k, "X-WB-Target") {
				continue
			}
			for _, v := range vs {
				req.Header.Add(k, v)
			}
		}
		// Content-Length 必须显式带上：NewRequest 拿到的是 io.ReadCloser，
		// 推断不出长度，会退化成 chunked；部分上游对 chunked 请求体不友好。
		req.ContentLength = r.ContentLength
	} else {
		req.Header.Set("User-Agent", "workbuddy-pool/"+appVersion+" (keepalive)")
	}
	req.Host = bu.Host

	// 连接复用证据链：Reused 直接说明这次是否吃到了池子；
	// dns / connWait / tls 三项在命中复用时应全部接近 0。
	var reused bool
	var dnsStart, tlsStart time.Time
	var dnsMs, tlsMs float64
	var connWaitMs, ttfbMs float64
	trace := &httptrace.ClientTrace{
		DNSStart: func(httptrace.DNSStartInfo) { dnsStart = time.Now() },
		DNSDone: func(httptrace.DNSDoneInfo) {
			if !dnsStart.IsZero() {
				dnsMs = float64(time.Since(dnsStart).Microseconds()) / 1000
			}
		},
		TLSHandshakeStart: func() { tlsStart = time.Now() },
		TLSHandshakeDone: func(tls.ConnectionState, error) {
			if !tlsStart.IsZero() {
				tlsMs = float64(time.Since(tlsStart).Microseconds()) / 1000
			}
		},
		GotConn: func(ci httptrace.GotConnInfo) {
			reused = ci.Reused
			connWaitMs = float64(time.Since(start).Microseconds()) / 1000
		},
		GotFirstResponseByte: func() {
			ttfbMs = float64(time.Since(start).Microseconds()) / 1000
		},
	}
	req = req.WithContext(httptrace.WithClientTrace(ctx, trace))

	resp, err := s.transport.RoundTrip(req)
	if err != nil {
		if !warm {
			h.errors.Add(1)
			h.setErr(err.Error())
		}
		s.fail(w, http.StatusBadGateway, "upstream: "+err.Error())
		return
	}
	defer resp.Body.Close()

	if warm {
		h.warmRequests.Add(1)
		// 必须把响应体读尽：Go 的 transport 只在 body 读到 EOF 时才把连接归还
		// 空闲池，读到一半就 Close 会直接关掉这条连接 —— 那等于预热把要保的
		// 连接亲手杀掉，下一次真实请求照样重新握手（比不预热更糟）。
		// 所以预热用 HEAD（本就无 body），这里再兜底读尽，双保险。
		io.Copy(io.Discard, resp.Body)
		if s.verbose {
			log.Printf("keepalive %s -> %d", base, resp.StatusCode)
		}
		return
	}

	if reused {
		h.reusedConns.Add(1)
	} else {
		h.newConns.Add(1)
	}

	for k, vs := range resp.Header {
		if hopHeaders[strings.ToLower(k)] {
			continue
		}
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	if resp.StatusCode >= 400 {
		h.errors.Add(1)
	}

	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 32*1024)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				// 客户端先走了（curl 被 --max-time / 看门狗收拾掉），
				// 读侧由 ctx 取消自动收尾。
				break
			}
			h.bytesOut.Add(int64(n))
			if flusher != nil {
				flusher.Flush()
			}
		}
		if rerr != nil {
			break
		}
	}
	totalMs := float64(time.Since(start).Microseconds()) / 1000
	h.addTimings(timings{
		dns: dnsMs, connWait: connWaitMs, tls: tlsMs,
		ttfb: ttfbMs, total: totalMs, reused: reused,
	})
	if s.verbose {
		log.Printf("%s %s -> %d reused=%v conn_wait=%.0fms tls=%.0fms ttfb=%.0fms total=%.0fms",
			r.Method, outURL.String(), resp.StatusCode, reused, connWaitMs, tlsMs, ttfbMs, totalMs)
	}
}

func (s *server) fail(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	fmt.Fprintf(w, `{"error":{"message":%q,"type":"upstream_error"}}`, msg)
}

func (s *server) handleProxy(w http.ResponseWriter, r *http.Request) {
	base := r.Header.Get("X-WB-Target")
	if base == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, `{"error":{"message":"missing X-WB-Target header"}}`)
		return
	}
	s.forward(w, r, strings.TrimRight(base, "/"), false)
}

type hostJSON struct {
	Base         string  `json:"base"`
	Requests     int64   `json:"requests"`
	Active       int64   `json:"active"`
	Errors       int64   `json:"errors"`
	NewConns     int64   `json:"new_conns"`
	ReusedConns  int64   `json:"reused_conns"`
	ReuseRate    float64 `json:"reuse_rate"`
	WarmRequests int64   `json:"warm_requests"`
	BytesOut     int64   `json:"bytes_out"`
	IdleSec      float64 `json:"idle_sec"`
	LastErr      string  `json:"last_error,omitempty"`

	DNSmsP50      float64 `json:"dns_ms_p50"`
	ConnWaitMsP50 float64 `json:"conn_wait_ms_p50"`
	TLSmsP50      float64 `json:"tls_ms_p50"`
	TTFBmsP50     float64 `json:"ttfb_ms_p50"`
	TTFBmsP90     float64 `json:"ttfb_ms_p90"`
	TTFBmsP99     float64 `json:"ttfb_ms_p99"`
	TotalMsP50    float64 `json:"total_ms_p50"`
	TotalMsP99    float64 `json:"total_ms_p99"`

	// 池化收益的直接度量：两者的差就是"省下的握手时间"
	TTFBNewConnP50    float64 `json:"ttfb_new_conn_ms_p50"`
	TTFBReusedConnP50 float64 `json:"ttfb_reused_conn_ms_p50"`
	Samples           int     `json:"samples"`
}

func (s *server) statsJSON() map[string]any {
	hosts := s.snapshotHosts()
	sort.Slice(hosts, func(i, j int) bool { return hosts[i].base < hosts[j].base })

	out := make([]hostJSON, 0, len(hosts))
	for _, h := range hosts {
		req, re := h.requests.Load(), h.reusedConns.Load()
		rate := 0.0
		if req > 0 {
			rate = float64(re) / float64(req)
		}
		p := h.pcts()
		out = append(out, hostJSON{
			Base: h.base, Requests: req, Active: h.active.Load(),
			Errors: h.errors.Load(), NewConns: h.newConns.Load(),
			ReusedConns: re, ReuseRate: rate,
			WarmRequests: h.warmRequests.Load(), BytesOut: h.bytesOut.Load(),
			IdleSec: h.idleSeconds(), LastErr: h.errString(),

			DNSmsP50: p.dnsP50, ConnWaitMsP50: p.connWaitP50, TLSmsP50: p.tlsP50,
			TTFBmsP50: p.ttfbP50, TTFBmsP90: p.ttfbP90, TTFBmsP99: p.ttfbP99,
			TotalMsP50: p.totalP50, TotalMsP99: p.totalP99,

			TTFBNewConnP50: p.ttfbNewP50, TTFBReusedConnP50: p.ttfbReusedP50,
			Samples: p.samples,
		})
	}
	return map[string]any{
		"ok":          true,
		"version":     appVersion,
		"uptime_s":    int64(time.Since(s.started).Seconds()),
		"requests":    s.reqTotal.Load(),
		"keepalive_s": int64(s.keepalive.Seconds()),
		"targets":     out,
	}
}

// keepaliveLoop 定期给"刚用过、随后闲置"的上游续连接。
// 只在 active==0 时发，避免与真实请求抢连接；预热结果不计入用户指标。
func (s *server) keepaliveLoop(ctx context.Context) {
	if s.keepalive <= 0 {
		return
	}
	tick := s.keepalive / 3
	if tick < 5*time.Second {
		tick = 5 * time.Second
	}
	t := time.NewTicker(tick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		for _, h := range s.snapshotHosts() {
			if h.requests.Load() == 0 || h.active.Load() > 0 {
				continue
			}
			if h.idleSeconds() < s.keepalive.Seconds() {
				continue
			}
			// HEAD：无响应体，最省上游开销，也最容易让连接干净地回到池里
			r, err := http.NewRequestWithContext(ctx, http.MethodHead, "http://"+s.listen+"/", nil)
			if err != nil {
				continue
			}
			r.Header.Set("X-WB-Target", h.base)
			s.forward(discardWriter{}, r, h.base, true)
		}
	}
}

type discardWriter struct{}

func (discardWriter) Header() http.Header         { return http.Header{} }
func (discardWriter) Write(b []byte) (int, error) { return len(b), nil }
func (discardWriter) WriteHeader(int)             {}

func main() {
	listen := flag.String("listen", "127.0.0.1:8790", "监听地址（务必保持回环）")
	// 30s：多数反向代理/网关的服务端空闲回收在 60~75s（nginx keepalive_timeout
	// 默认 75s），取半值留足余量，避免预热赶到时连接已被对端关掉。
	keepalive := flag.Duration("keepalive", 30*time.Second, "空闲保活预热间隔，0 关闭")
	idlePerHost := flag.Int("idle-per-host", 8, "每个上游保留的空闲连接数")
	verbose := flag.Bool("v", false, "输出每个请求的转发日志")
	showVer := flag.Bool("version", false, "打印版本")
	flag.Parse()

	if *showVer {
		fmt.Println("workbuddy-pool " + appVersion)
		return
	}

	log.SetFlags(log.LstdFlags)
	s := newServer(*listen, *keepalive, *verbose, *idlePerHost)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.keepaliveLoop(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true, "service": "workbuddy-pool", "version": appVersion,
			"uptime_s": int64(time.Since(s.started).Seconds()),
		})
	})
	mux.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(s.statsJSON())
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// 带 X-WB-Target 的一律转发；否则视为本机探活。
		if r.Header.Get("X-WB-Target") != "" {
			s.handleProxy(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"ok":true,"service":"workbuddy-pool","hint":"POST with X-WB-Target"}`+"\n")
	})

	srv := &http.Server{
		Addr:    *listen,
		Handler: mux,
		// SSE 是长连接：WriteTimeout 必须为 0，否则流式响应会被拦腰截断。
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("listen %s: %v", *listen, err)
	}
	log.Printf("workbuddy-pool %s listening on %s (keepalive=%s idle/host=%d)",
		appVersion, *listen, *keepalive, *idlePerHost)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		cancel()
		shutCtx, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		srv.Shutdown(shutCtx)
	}()

	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatalf("serve: %v", err)
	}
	s.transport.CloseIdleConnections()
	log.Print("stopped")
}

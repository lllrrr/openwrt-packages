// testsse —— 仅供本地回归测试的最小 SSE 源。
//
// 用途：验证 workbuddy-pool 插入后不会缓冲流式响应。
// 它以 300ms 间隔发 5 个事件（总时长约 1.5s），每个事件后显式 Flush。
// 判据：经代理请求时 curl 的 time_starttransfer 应远小于 time_total
// （约 0.02s vs 1.5s）；若代理攒够缓冲才发，两者会接近相等。
//
// 不参与打包，也不被 install.sh 部署。
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"time"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:8791", "监听地址")
	gap := flag.Duration("gap", 300*time.Millisecond, "事件间隔")
	count := flag.Int("count", 5, "事件个数")
	flag.Parse()

	http.HandleFunc("/sse", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(200)
		f, _ := w.(http.Flusher)
		if f != nil {
			f.Flush() // 先送出响应头，让 TTFB 反映"流已开始"
		}
		for i := 0; i < *count; i++ {
			fmt.Fprintf(w, "data: {\"i\":%d,\"t\":%q}\n\n", i, time.Now().Format("15:04:05.000"))
			if f != nil {
				f.Flush()
			}
			time.Sleep(*gap)
		}
		fmt.Fprint(w, "data: [DONE]\n\n")
		if f != nil {
			f.Flush()
		}
	})

	// 保活回归用：返回一个大响应体（64KB）。
	// 用来暴露"预热后连接是否还在池里"——若预热带 body 又没读尽，Go 的
	// transport 会关掉连接，下一次真实请求就会从 reused 变成 new_conns。
	// 注意 HEAD 请求由 net/http 自动省略 body，这正是预热改用 HEAD 的原因。
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		blob := make([]byte, 64*1024)
		for i := range blob {
			blob[i] = 'x'
		}
		w.Write(blob)
	})

	http.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		// 回显请求方法/路径/关键头，用来验证代理是否原样透传
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"method":%q,"path":%q,"query":%q,"auth":%q,"ua":%q,"ct":%q,"cl":%d}`+"\n",
			r.Method, r.URL.Path, r.URL.RawQuery,
			r.Header.Get("Authorization"), r.Header.Get("User-Agent"),
			r.Header.Get("Content-Type"), r.ContentLength)
	})

	log.Printf("testsse listening on %s (gap=%s count=%d)", *listen, *gap, *count)
	log.Fatal(http.ListenAndServe(*listen, nil))
}

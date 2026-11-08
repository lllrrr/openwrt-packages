"""Speed test engine.

Two stages, like the OpenWrt version:

1. Latency screening: every candidate IP is written as the proxy server of a
   throw-away mihomo config, a private SOCKS port is started, and curl measures
   HTTP HEAD ``time_pretransfer`` (N probes, any failure discards the IP).
2. Download test: after every worker has stopped probing, the N lowest-latency
   IPs of each worker are downloaded serially through the same node, and the
   best IP is chosen by measured throughput.

Time-boxed iterative mode runs an independent convergence loop per node until
the deadline or the pool shrinks to ``iterate_converge_count`` candidates.
Retest mode reuses the current result.csv candidates instead of downloading the
online list.
"""

import os
import shutil
import signal
import subprocess
import threading
import time
import traceback
from pathlib import Path

from . import config, core, ddns, iplists, links, lock, paths, result
from .log import Logger

SOCKS_PORT_BASE = 48900
DL_FAST_FAIL_BYTES = 1048576
DL_FAST_FAIL_TIME = 5
DL_FAST_FAIL_BPS = DL_FAST_FAIL_BYTES // DL_FAST_FAIL_TIME
ACCEPT_CODES = {"200", "204", "301", "302", "307", "308",
                "400", "401", "402", "403", "404", "405", "406",
                "407", "408", "409", "410", "411", "412", "413",
                "414", "415", "416", "417", "418", "421", "422",
                "423", "424", "425", "426", "428", "429", "431",
                "451"}


class EngineError(RuntimeError):
    pass


class Engine:
    def __init__(self, cfg, logger, mode, binary, core_type, run_dir,
                 node_names=None, full_run=False):
        self.cfg = cfg
        self.log = logger
        self.mode = mode
        # Empty means "every enabled node"; otherwise only these names run.
        self.node_names = [str(name).strip() for name in (node_names or [])
                           if str(name).strip()]
        # Only a run that covers every configured node may rotate the result
        # history; a partial run merges its rows into the current file.
        self.full_run = bool(full_run)
        self.binary = binary
        self.core_type = core_type
        self.run_dir = Path(run_dir)
        self.curl = core.find_curl()
        self.stop_event = threading.Event()
        self.stop_source = ""
        self.deadline = None
        self._watcher_stop = threading.Event()
        self._watcher_thread = None
        self.ports = {}
        self.iterate_rounds = {}
        self.dl_enabled = bool(cfg.get("download_enabled", True))
        self.hard_stop = False
        self._cores = set()
        # RLock so the SIGTERM handler can clean up even if the main thread
        # already holds this lock.
        self._cores_lock = threading.RLock()

    # ── core process tracking / signal cleanup ───────────────────────────
    def _track_core(self, process):
        with self._cores_lock:
            self._cores.add(process)

    def _untrack_core(self, process):
        with self._cores_lock:
            self._cores.discard(process)

    def stop_all_cores(self):
        with self._cores_lock:
            processes = list(self._cores)
            self._cores.clear()
        for process in processes:
            process.stop()

    def _handle_signal(self, signum, _frame):
        self.hard_stop = True
        self.stop_source = "signal"
        self.stop_event.set()
        self.log.log("收到终止信号（%s），停止内核进程并退出（保留上一次结果）" % signum)
        self.stop_all_cores()

    def _wait_for_download(self):
        """Pause probing while another task owns the download slot.

        Downloads compete for the same WAN bandwidth; a task that is still
        probing would skew the measured throughput.  The wait ends when the
        other task releases the slot, and honours a stop request.
        """
        if not lock.download_active_by_other(os.getpid()):
            return True
        self.log.log("另一任务正在下载实测，暂停探测，对方完成后自动继续")
        while lock.download_active_by_other(os.getpid()):
            if self.stop_event.is_set():
                return False
            time.sleep(0.5)
        self.log.log("对方下载完成，继续探测")
        return True

    # ── setup ────────────────────────────────────────────────────────────
    def _nodes(self):
        nodes = []
        for item in self.cfg.get("nodes", []):
            if not item.get("enabled", True):
                continue
            try:
                parsed = links.parse_link(item.get("link", ""))
            except (links.LinkError, ValueError) as exc:
                self.log.log("节点 %s 链接无效，跳过: %s" % (item.get("name") or "?", exc))
                continue
            try:
                core.validate_proxy(parsed.proxy, self.core_type)
            except core.CoreError as exc:
                self.log.log("节点 %s 与当前内核不兼容，跳过: %s" % (item.get("name") or parsed.name, exc))
                continue
            name = (item.get("name") or parsed.name or "node").strip()
            if any(existing["name"] == name for existing in nodes):
                suffix = 2
                while any(existing["name"] == "%s-%d" % (name, suffix) for existing in nodes):
                    suffix += 1
                name = "%s-%d" % (name, suffix)
            nodes.append({
                "slot": len(nodes) + 1,
                "name": name,
                "ip_list": (item.get("ip_list") or "").strip(),
                "ddns_domain": (item.get("ddns_domain") or "").strip().lower().rstrip("."),
                "parsed": parsed,
            })
        if not nodes:
            raise EngineError(
                "没有可用的节点：请在「节点」页添加至少一条可用分享链接；"
                "当前内核 %s 也可能不支持这些节点的协议" % self.core_type)
        if self.node_names:
            available = {node["name"] for node in nodes}
            missing = [name for name in self.node_names if name not in available]
            if missing:
                self.log.log("所选节点不存在、未启用或与内核不兼容，已跳过: %s"
                             % "、".join(missing))
            nodes = [node for node in nodes if node["name"] in self.node_names]
            # Renumber slots so SOCKS ports and work directories stay dense.
            for slot, node in enumerate(nodes, start=1):
                node["slot"] = slot
            if not nodes:
                raise EngineError(
                    "所选节点没有可运行的项：%s；请检查节点是否已启用、"
                    "名称是否被修改，以及当前内核 %s 是否支持这些协议"
                    % ("、".join(self.node_names), self.core_type))
        return nodes

    def _assign_ports(self, nodes):
        used = set()
        for node in nodes:
            preferred = SOCKS_PORT_BASE + node["slot"] - 1
            port = core.free_port(preferred)
            while port in used:
                port = core.free_port(port + 1)
            used.add(port)
            self.ports[node["name"]] = port

    def _node_workdir(self, node):
        directory = self.run_dir / ("w%d" % node["slot"])
        directory.mkdir(parents=True, exist_ok=True)
        return directory

    # ── stop watcher ─────────────────────────────────────────────────────
    def _start_stop_watcher(self):
        def watch():
            while not self._watcher_stop.wait(0.5):
                if lock.stop_requested(os.getpid()) and not self.stop_event.is_set():
                    self.stop_source = "user"
                    self.stop_event.set()
                    lock.write_state(stop_requested=True, phase="stopping")
                    self.log.log("收到停止请求：各 worker 跑完当前 IP 即停，"
                                 "随后仍会完成已通过 IP 的下载实测并导出结果")

        self._watcher_thread = threading.Thread(target=watch, name="stop-watcher", daemon=True)
        self._watcher_thread.start()

    def _stop_watcher(self):
        self._watcher_stop.set()
        if self._watcher_thread:
            self._watcher_thread.join(timeout=2)

    # ── probe / download through one candidate IP ───────────────────────
    def _config_matches(self, path, ip):
        try:
            text = Path(path).read_text(encoding="utf-8")
        except OSError:
            return False
        return ('server: "%s"' % ip) in text or ('"address": "%s"' % ip) in text

    def _start_candidate_core(self, node, ip, tag):
        if self.hard_stop:
            raise EngineError("已收到终止信号，不再启动新内核")
        workdir = self._node_workdir(node)
        port = self.ports[node["name"]]
        dns = (self.cfg.get("core") or {}).get("dns_nameserver", "")
        # start_core writes the config; verify afterwards that it points at the
        # candidate, so a stale file can never be measured as this IP.
        # Keep one shared core log under /var/log so a failed node can be
        # diagnosed after the per-run work directory is removed.
        paths.LOG_DIR.mkdir(parents=True, exist_ok=True)
        extension = "json" if self.core_type == "xray" else "yaml"
        process, config_path = core.start_core(
            self.binary, self.core_type, node["parsed"].proxy, ip, port, workdir,
            paths.LOG_DIR / ("%s.log" % self.core_type), dns,
            config_name="cfg-%s-%s.%s" % (node["slot"], tag, extension))
        if not self._config_matches(config_path, ip):
            process.stop()
            raise EngineError("生成的 SOCKS 配置未指向候选 IP %s" % ip)
        self._track_core(process)
        return process, config_path

    def _curl(self, args, timeout):
        try:
            completed = subprocess.run(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=timeout,
            )
            return completed.returncode, completed.stdout.decode("utf-8", "replace").strip()
        except (subprocess.TimeoutExpired, OSError):
            return 124, ""

    def _probe_ip(self, node, ip, tag):
        """Return (keep, sent, recv, loss, avg_ms, reason).

        ``reason`` is empty when the IP is kept; otherwise it names the filter
        that rejected it, so the log explains every ``[丢弃]``.
        """
        port = self.ports[node["name"]]
        workdir = self._node_workdir(node)
        process = config_path = None
        sent = recv = 0
        latencies = []
        failed = False
        try:
            try:
                process, config_path = self._start_candidate_core(node, ip, tag)
            except (core.CoreError, EngineError) as exc:
                self.log.log("核心启动失败: %s" % exc)
                return 0, 0, 0, 1.0, 0.0, "核心启动失败"

            done = 0
            not_ready = 0
            while done < self.cfg["probes"]:
                if process.proc.poll() is not None:
                    break
                args = [
                    self.curl,
                    "-x", "socks5h://127.0.0.1:%d" % port,
                    "-I", "-skL",
                    "--connect-timeout", "3",
                    "--max-time", str(self.cfg["probe_timeout"]),
                    "-o", os.devnull,
                    "-w", "%{http_code}:%{time_pretransfer}",
                    self.cfg["probe_url"],
                ]
                rc, out = self._curl(args, self.cfg["probe_timeout"] + 5)
                if rc == 7:
                    not_ready += 1
                    if not_ready >= 10:
                        break
                    time.sleep(1)
                    continue
                not_ready = 0
                sent += 1
                done += 1
                code, _, transfer = out.partition(":")
                if code in ACCEPT_CODES and transfer:
                    try:
                        latencies.append(float(transfer))
                        recv += 1
                    except ValueError:
                        failed = True
                        break
                else:
                    failed = True
                    break
        finally:
            if process:
                process.stop()
                self._untrack_core(process)
            if config_path:
                try:
                    config_path.unlink()
                except OSError:
                    pass

        loss = (sent - recv) / sent if sent else 1.0
        avg_ms = (sum(latencies) / len(latencies) * 1000.0) if latencies else 0.0
        keep = 1
        reason = ""
        if failed or recv < self.cfg["probes"]:
            keep = 0
            reason = "探测未全部成功（%d/%d 次）" % (recv, self.cfg["probes"])
        else:
            if self.cfg["latency_max"] > 0 and avg_ms > self.cfg["latency_max"]:
                keep = 0
                reason = "延迟 %.0fms > 上限 %dms" % (avg_ms, self.cfg["latency_max"])
            if self.cfg["latency_min"] > 0 and avg_ms < self.cfg["latency_min"]:
                keep = 0
                reason = "延迟 %.0fms < 下限 %dms" % (avg_ms, self.cfg["latency_min"])
            if loss > self.cfg["loss_max"]:
                keep = 0
                reason = "丢包 %.2f > 上限 %.2f" % (loss, self.cfg["loss_max"])
        return keep, sent, recv, loss, avg_ms, reason

    def _download_one(self, node, ip, tag):
        """Return speed in MB/s (0 on failure)."""
        port = self.ports[node["name"]]
        process = config_path = None
        try:
            try:
                process, config_path = self._start_candidate_core(node, ip, tag)
            except (core.CoreError, EngineError) as exc:
                self.log.log("下载测速核心启动失败: %s" % exc)
                return 0.0

            args = [
                self.curl,
                "-x", "socks5h://127.0.0.1:%d" % port,
                "-sL", "-o", os.devnull,
                "--connect-timeout", "3",
                "--max-time", str(self.cfg["download_time"]),
                "--speed-limit", str(DL_FAST_FAIL_BPS),
                "--speed-time", str(DL_FAST_FAIL_TIME),
                "-w", "%{http_code} %{size_download} %{speed_download}",
                self.cfg["download_url"],
            ]
            rc, out = self._curl(args, self.cfg["download_time"] + 10)
            if rc == 7:
                # SOCKS not ready yet; retry a few times unless the core died.
                for _ in range(10):
                    if process.proc.poll() is not None:
                        break
                    time.sleep(1)
                    rc, out = self._curl(args, self.cfg["download_time"] + 10)
                    if rc != 7:
                        break
            if rc not in (0, 28):
                return 0.0
            parts = out.split()
            if len(parts) < 3:
                return 0.0
            code, size, speed = parts[0], parts[1], parts[2]
            if not code.startswith("2"):
                return 0.0
            try:
                size = float(size)
                speed = float(speed)
            except ValueError:
                return 0.0
            if size < 16384 or speed <= 0:
                return 0.0
            if rc == 28 and speed < DL_FAST_FAIL_BPS:
                self.log.log("下载测速快速死亡：%s %ds 内不足 %d 字节，判失败" % (
                    ip, DL_FAST_FAIL_TIME, DL_FAST_FAIL_BYTES))
                return 0.0
            return round(speed / 1048576.0, 2)
        finally:
            if process:
                process.stop()
                self._untrack_core(process)
            if config_path:
                try:
                    config_path.unlink()
                except OSError:
                    pass

    # ── latency workers ─────────────────────────────────────────────────
    def _latency_worker(self, node, candidates):
        rows = []
        ips = candidates.for_node(node["name"], node["ip_list"])
        total = len(ips)
        if not total:
            self.log.log("worker [%s] 候选 IP 为空，跳过" % node["name"])
            return rows
        # 记录收到有效响应的延迟，用于「阈值全灭」时给出诊断信息。
        responded = []
        probed = 0
        for index, ip in enumerate(ips, start=1):
            if self.stop_event.is_set():
                self.log.log("worker [%s] 收到停止信号，跑完当前 IP 即停（已完成 %d/%d）" % (
                    node["name"], index - 1, total))
                break
            if not self._wait_for_download():
                break
            self.log.size_guard()
            probed = index
            keep, sent, recv, loss, avg, reason = self._probe_ip(
                node, ip, "p%d-%d" % (index, int(time.time() * 1000) % 100000))
            if recv > 0 and avg > 0:
                responded.append(avg)
            if keep:
                rows.append(result.Row(ip=ip, sent=sent, recv=recv, loss=loss,
                                       latency=avg, speed=0.0))
            self.log.log("进度: 走节点测速 [%s] %d/%d (%d%%) - %s 延迟 %.2fms 丢包 %.2f [%s]" % (
                node["name"], index, total, index * 100 // total, ip, avg, loss,
                "保留" if keep else ("丢弃: %s" % reason if reason else "丢弃")))
        if not rows and responded and probed:
            self.log.log(
                "worker [%s] 已测 %d 个候选全部被阈值过滤，未保留任何 IP；"
                "探测成功者的延迟范围 %.0f–%.0fms，当前阈值：延迟上限 %s、下限 %s、丢包上限 %.2f。"
                "若节点本身延迟较高，请到「设置」把延迟上限调大或设为 0（不限）后重测。" % (
                    node["name"], probed, min(responded), max(responded),
                    self.cfg["latency_max"] or "不限",
                    self.cfg["latency_min"] or "不限",
                    self.cfg["loss_max"]))
        return result.sort_rows(rows, "latency")

    # ── iterative worker ────────────────────────────────────────────────
    def _iterate_worker(self, node, candidates):
        name = node["name"]
        all_rows, _ = result.read_result()
        previous = [row for row in all_rows if row.node == name]
        previous = result.sort_rows(previous, "latency")
        current = list(previous)
        ips = candidates.for_node(name, node["ip_list"])
        if not ips:
            self.log.log("迭代 [%s] 初始候选为空，跳过" % name)
            return current

        keep_max = self.cfg["iterate_converge_count"]
        passed_any = False
        round_no = 0
        while True:
            if self.stop_event.is_set() or time.time() >= self.deadline:
                break
            round_no += 1
            pass_rows = []
            probed = set()
            total = len(ips)
            for index, ip in enumerate(ips, start=1):
                if self.stop_event.is_set():
                    self.log.log("迭代 [%s] 第 %d 轮收到停止信号，跑完当前 IP 即停" % (name, round_no))
                    break
                if time.time() >= self.deadline:
                    self.log.log("迭代 [%s] 到达时长上限，跑完当前 IP 即停" % name)
                    break
                if not self._wait_for_download():
                    break
                self.log.size_guard()
                probed.add(ip)
                keep, sent, recv, loss, avg, reason = self._probe_ip(
                    node, ip, "p%d-%d-%d" % (round_no, index, int(time.time() * 1000) % 100000))
                if keep:
                    pass_rows.append(result.Row(ip=ip, sent=sent, recv=recv, loss=loss,
                                                latency=avg, speed=0.0))
                self.log.log("迭代: [%s] 第 %d 轮 %d/%d (%d%%) - %s 延迟 %.2fms 丢包 %.2f [%s]" % (
                    name, round_no, index, total, index * 100 // total, ip, avg, loss,
                    "保留" if keep else ("丢弃: %s" % reason if reason else "丢弃")))

            if pass_rows:
                passed_any = True
                passed_now = len(pass_rows)
                truncated = len(probed) < total
                if truncated:
                    carried = [row for row in current if row.ip not in probed]
                    if carried:
                        pass_rows.extend(carried)
                        self.log.log("迭代 [%s] 第 %d 轮未测完（%d/%d），未测到的 %d 个 IP 沿用上一轮结果" % (
                            name, round_no, len(probed), total, len(carried)))
                pass_rows = result.sort_rows(pass_rows, "latency")
                current = pass_rows
                ips = [row.ip for row in current]
                self.log.log("迭代 [%s] 第 %d 轮完成，通过 %d/%d，下一轮候选 %d 个" % (
                    name, round_no, passed_now, total, len(ips)))
                if not truncated and 0 < len(ips) <= keep_max:
                    self.log.log("迭代 [%s] 候选收敛至 %d 个（阈值 %d），保存结果，该节点提前结束" % (
                        name, len(ips), keep_max))
                    break
                if not ips:
                    break
            else:
                self.log.log("迭代 [%s] 第 %d 轮全部失败，保留第 %d 轮结果，该节点提前结束" % (
                    name, round_no, round_no - 1))
                break

        self.iterate_rounds[name] = round_no
        if not passed_any:
            self.log.log("迭代 [%s] 本会话无通过 IP，沿用上一次结果" % name)
            current = previous
        return result.sort_rows(current, "latency")

    # ── worker orchestration ────────────────────────────────────────────
    def _worker_entry(self, node, candidates, semaphore, first_done, rows_by_node):
        if self.cfg["iterate_enabled"]:
            rows = self._iterate_worker(node, candidates)
        else:
            rows = []
            acquired = False
            try:
                semaphore.acquire()
                acquired = True
                if not self.stop_event.is_set():
                    rows = self._latency_worker(node, candidates)
            finally:
                if acquired:
                    semaphore.release()
        rows_by_node[node["name"]] = rows
        if rows and not self.cfg["iterate_enabled"] and not self.stop_event.is_set():
            self.stop_source = "first_done"
            first_done.set()
            self.stop_event.set()
            self.log.log("worker [%s] 首个完成并取得有效结果，其余 worker 跑完当前 IP 即停" % node["name"])

    def _run_workers(self, nodes, candidates):
        rows_by_node = {}
        first_done = threading.Event()
        if self.cfg["iterate_enabled"]:
            self.log.log("迭代模式：%d 个待测节点各跑独立收敛循环至时限，全部同时运行" % len(nodes))
            semaphore = threading.Semaphore(len(nodes))
        else:
            limit = self.cfg["max_workers"] or len(nodes)
            limit = max(1, min(limit, len(nodes)))
            self.log.log("开始走节点测速（%d 个 worker，并发上限 %d，每 IP 探测 %d 次，超时 %ds）" % (
                len(nodes), limit, self.cfg["probes"], self.cfg["probe_timeout"]))
            semaphore = threading.Semaphore(limit)

        threads = []
        for node in nodes:
            thread = threading.Thread(
                target=self._worker_entry,
                args=(node, candidates, semaphore, first_done, rows_by_node),
                name="worker-%d" % node["slot"],
                daemon=True,
            )
            thread.start()
            threads.append(thread)
        for thread in threads:
            thread.join()
        return rows_by_node

    # ── download stage ──────────────────────────────────────────────────
    def _download_phase(self, node, rows):
        """Download-test the node's best IPs.

        Returns ``(rows, kept)`` where ``kept`` is how many IPs passed the
        download test; 0 with non-empty rows means every download failed.
        """
        if not rows:
            return rows, 0
        ordered = result.sort_rows(rows, "latency")
        count = self.cfg["download_count"]
        tested = ordered[:count]
        rest = ordered[count:]
        kept = []
        self.log.log("下载测速 [%s] 开始：对延迟最优的 %d 个 IP 实测下载（%s，单 IP 上限 %ds）" % (
            node["name"], len(tested), self.cfg["download_url"], self.cfg["download_time"]))
        for index, row in enumerate(tested, start=1):
            if self.hard_stop:
                self.log.log("收到终止信号，跳过剩余下载实测")
                break
            speed = self._download_one(
                node, row.ip, "d%d-%d" % (index, int(time.time() * 1000) % 100000))
            self.log.size_guard()
            if speed > 0:
                row.speed = speed
                kept.append(row)
                self.log.log("下载测速 [%s] %d/%d - %s 速度 %.2f MB/s [保留]" % (
                    node["name"], index, len(tested), row.ip, speed))
            else:
                self.log.log("下载测速 [%s] %d/%d - %s 下载失败 [丢弃]" % (
                    node["name"], index, len(tested), row.ip))
        if kept:
            out = result.sort_rows(kept, "speed") + rest
            best = out[0]
            self.log.log("下载测速 [%s] 完成：成功 %d/%d，最优 %s %.2f MB/s" % (
                node["name"], len(kept), len(tested), best.ip, best.speed))
            return out, len(kept)
        self.log.log("下载测速 [%s] 未取得任何有效速度，保留延迟排序结果" % node["name"])
        return ordered, 0

    def _download_stage(self, nodes, rows_by_node):
        """Run the serial download stage; return nodes whose downloads all failed."""
        if not self.dl_enabled:
            return []
        if self.stop_event.is_set() and self.stop_source == "user":
            self.log.log("用户已停止一轮测速，仍继续完成下载实测后再导出结果")
        lock.write_state(phase="download")
        self.log.log("下载实测阶段开始：所有 worker 已停止探测，逐节点串行实测下载速度")
        failed = []
        for node in nodes:
            if self.hard_stop:
                self.log.log("收到终止信号，跳过剩余节点的下载实测")
                break
            original = rows_by_node.get(node["name"]) or []
            rows, kept = self._download_phase(node, original)
            rows_by_node[node["name"]] = rows
            # 有候选却一个下载都没成功：等其他节点测完后复测一轮。
            if original and not kept:
                failed.append(node)
        return failed

    def _retest_download_failures(self, nodes, rows_by_node):
        """Give nodes whose downloads all failed one more full retest round.

        Runs after every other node's download stage, so the retest is not
        competing with them for WAN bandwidth.  Candidates follow the normal
        retest semantics (current result.csv row + the node's address).
        """
        if not nodes or self.hard_stop:
            return
        if self.stop_source == "user":
            self.log.log("用户已停止，跳过下载失败节点的复测")
            return
        self.log.log("下载全部失败的节点: %s；其他节点下载结束后各复测一轮" % (
            "、".join(node["name"] for node in nodes)))
        try:
            candidates = iplists.retest_candidates(self.cfg, nodes, self.log)
        except iplists.IpListError as exc:
            self.log.log("下载失败节点无法复测: %s" % exc)
            return

        for node in nodes:
            if self.hard_stop:
                break
            name = node["name"]
            # 复测不受第一轮 “首个完成即停” 的 stop_event 影响，单独用一个事件。
            original_event = self.stop_event
            self.stop_event = threading.Event()
            try:
                rows = self._latency_worker(node, candidates)
            finally:
                self.stop_event = original_event
            if not rows:
                self.log.log("复测 [%s] 没有通过延迟筛选的 IP，保留上一轮结果" % name)
                continue
            rows, kept = self._download_phase(node, rows)
            if kept:
                rows_by_node[name] = rows
                self.log.log("复测 [%s] 下载成功 %d 个，已用复测结果替换该节点结果" % (
                    name, kept))
            else:
                self.log.log("复测 [%s] 下载仍全部失败，保留上一轮结果" % name)

    # ── commit ──────────────────────────────────────────────────────────
    def _iterate_summary(self, node, rows):
        top = rows[:10]
        self.log.log("迭代 [%s] 最终结果（第 %s 轮，共 %d 条，完整列表见 Web 结果表）:" % (
            node["name"], self.iterate_rounds.get(node["name"], "?"), len(rows)))
        for row in top:
            suffix = " 下载 %.2f MB/s" % row.speed if row.speed > 0 else ""
            self.log.log("  %s 延迟 %.2fms 丢包 %.2f%s" % (row.ip, row.latency, row.loss, suffix))
        if len(rows) > len(top):
            self.log.log("  ……其余 %d 条见结果表" % (len(rows) - len(top)))

    def _commit(self, nodes, rows_by_node):
        if self.hard_stop:
            self.log.log("收到终止信号，保留上一次结果，不写入本次结果")
            return False
        lock.write_state(phase="commit")
        merged = []
        for node in nodes:
            rows = result.sort_rows(rows_by_node.get(node["name"]) or [])
            if rows:
                best = rows[0]
                suffix = " %.2f MB/s" % best.speed if best.speed > 0 else ""
                self.log.log("走节点测速完成 [%s]，最优 IP %s%s" % (node["name"], best.ip, suffix))
            else:
                self.log.log("走节点测速 [%s] 结果为空，保留该节点上一次结果" % node["name"])
            if self.cfg["iterate_enabled"] and rows:
                self._iterate_summary(node, rows)
            for row in rows:
                row.node = node["name"]
                row.node_id = str(node.get("id") or "")
                merged.append(row)

        merged = result.sort_rows(merged, "speed")
        if not merged:
            self.log.log("所有 worker 结果均为空，保留上一次结果")
            lock.write_state(phase="failed", error="所有 worker 结果为空")
            return False

        when = result.now_text()
        result.append_history(merged, when)
        # Full runs replace the whole file (and rotate history); partial runs
        # replace only their own nodes and keep the other nodes' rows.
        if self.full_run:
            result.rotate_results()
        node_names = [node["name"] for node in nodes]
        combined = result.merge_result(merged, node_names)
        if not combined:
            combined = merged
        result.write_result(paths.RESULT_FILE, combined, when)
        if self.cfg.get("export", {}).get("json", True):
            result.export_json(combined, when)

        # DDNS is opt-in and isolated: a DNS failure must never turn a
        # successful speed test into a failed run.
        ddns_report = None
        if (self.cfg.get("ddns") or {}).get("enabled"):
            try:
                ddns_report = ddns.apply(
                    self.cfg, nodes, merged, log=self.log.log, when=when)
            except Exception as exc:
                ddns_report = {
                    "enabled": True, "provider": "cloudflare", "at": when,
                    "ok": False, "nodes": [], "error": str(exc),
                }
                self.log.log("DDNS 写入异常: %s" % exc)

        best = combined[0]
        state_fields = {
            "phase": "done",
            "finished_at": int(time.time()),
            "best_ip": best.ip,
            "best_latency": round(best.latency, 2),
            "best_speed": round(best.speed, 2),
            "last_time": when,
            "error": "",
        }
        if ddns_report is not None:
            state_fields["ddns"] = ddns_report
        lock.write_state(**state_fields)
        suffix = " %.2f MB/s" % best.speed if best.speed > 0 else ""
        self.log.log("全部完成，全局最优 IP %s（延迟 %.2fms%s），结果已导出到 %s" % (
            best.ip, best.latency, suffix, paths.STATE_DIR))
        return True

    # ── entry ───────────────────────────────────────────────────────────
    def execute(self):
        cfg = self.cfg
        started = time.time()
        try:
            self.log.log("使用代理内核: %s" % self.core_type)
            nodes = self._nodes()
            self._assign_ports(nodes)
            lock.write_state(phase="latency", core_type=self.core_type)
            candidates = iplists.select(cfg, nodes, self.mode, self.log)
            if cfg["iterate_enabled"]:
                self.deadline = time.time() + cfg["iterate_minutes"] * 60
                self.log.log("════ 限时迭代测速开始（时长上限 %d 分钟，各节点独立收敛）════" % cfg["iterate_minutes"])
            else:
                self.log.log("════ 走节点测速开始（%d 个节点）════" % len(nodes))
            self._log_download_note()
            old_handlers = {}
            for sig in (signal.SIGINT, signal.SIGTERM):
                try:
                    old_handlers[sig] = signal.signal(sig, self._handle_signal)
                except (ValueError, OSError):
                    pass
            self._start_stop_watcher()
            try:
                rows_by_node = self._run_workers(nodes, candidates)
                # Download + write-back is globally serialized.  A run that
                # already finished probing still waits here after a stop; it
                # must complete its own download list.
                if not lock.acquire_commit(self.log):
                    self.log.log("未拿到下载锁，本次放弃（保留上一次结果）")
                    ok = False
                else:
                    try:
                        failed_nodes = self._download_stage(nodes, rows_by_node)
                        self._retest_download_failures(failed_nodes, rows_by_node)
                        ok = self._commit(nodes, rows_by_node)
                    finally:
                        lock.release_commit()
            finally:
                self.stop_all_cores()
                self._stop_watcher()
                for sig, handler in old_handlers.items():
                    try:
                        signal.signal(sig, handler)
                    except (ValueError, OSError):
                        pass
            return 0 if ok else 1
        finally:
            if self.cfg["iterate_enabled"]:
                self.log.log("════ 迭代测速结束（累计 %ds）════" % int(time.time() - started))

    def _log_download_note(self):
        if not self.dl_enabled:
            return
        self.log.log("下载实测已启用：所有 worker 完成一轮延迟测试后，逐节点串行实测每个 worker "
                     "延迟最优的 %d 个 IP（%s，单 IP 上限 %ds）" % (
                         self.cfg["download_count"], self.cfg["download_url"],
                         self.cfg["download_time"]))


def run(mode="start", node_names=None):
    """Run one full test.  Returns a process exit code.

    ``node_names`` limits the run to those configured nodes; empty/None keeps
    the default of testing every enabled node.
    """
    mode = mode if mode in ("start", "test", "retest") else "start"
    node_names = [str(name).strip() for name in (node_names or [])
                  if str(name).strip()]
    cfg = config.load()
    paths.ensure_dirs()
    logger = Logger(paths.RUN_LOG)

    enabled = [node for node in cfg.get("nodes", [])
               if node.get("enabled", True)]
    enabled_names = [node.get("name", "") for node in enabled]
    if node_names:
        missing = [name for name in node_names if name not in enabled_names]
        if missing:
            logger.log("所选节点不存在或未启用，已忽略: %s" % "、".join(missing))
        requested = [name for name in enabled_names if name in node_names]
    else:
        requested = list(enabled_names)

    try:
        binary, core_type = core.ensure_core(cfg)
    except core.CoreError as exc:
        logger.log(str(exc))
        lock.write_state(phase="failed", error=str(exc), finished_at=int(time.time()))
        logger.persist(paths.LAST_LOG)
        return 1

    if not shutil.which("curl") and not Path(core.find_curl()).exists():
        logger.log("未找到 curl，请先安装（Debian: apt install curl；OpenWrt: opkg install curl）")
        logger.persist(paths.LAST_LOG)
        return 1

    run_lock = lock.RunLock(logger)
    if not run_lock.acquire(iterate=cfg["iterate_enabled"],
                            iterate_minutes=cfg["iterate_minutes"],
                            nodes=requested):
        return 1
    acquired = list(run_lock.node_names)
    full_run = (not node_names) and set(acquired) == set(enabled_names)

    # Shared log: do not rotate/clear the stop flag of another active run.
    other = lock.other_runs_active()
    if not other:
        logger.rotate()
        lock.clear_stop()
    # 清掉本进程可能残留的单 worker 停止请求（上一轮异常退出等）。
    lock.clear_stop(os.getpid())
    label = "复测现有最优 IP" if mode == "retest" else "Cloudflare IP 测速"
    logger.log("════ %s 开始 ════" % label)
    lock.write_state(
        running=True,
        pid=os.getpid(),
        mode=mode,
        phase="starting",
        started_at=int(time.time()),
        finished_at=0,
        stop_requested=False,
        error="",
        iterate=bool(cfg["iterate_enabled"]),
        node_count=len(acquired),
        nodes=acquired if not full_run else [],
        core_type=core_type,
    )

    engine = Engine(cfg, logger, mode, binary, core_type, run_lock.run_dir,
                    node_names=acquired, full_run=full_run)
    ok = False
    try:
        ok = engine.execute() == 0
    except Exception as exc:  # keep the previous result on any engine failure
        logger.log("测速失败: %s" % exc)
        logger.log(traceback.format_exc())
        lock.write_state(phase="failed", error=str(exc))
    finally:
        engine.stop_all_cores()
        lock.write_state(
            running=False,
            phase="done" if ok else "failed",
            finished_at=int(time.time()),
            stop_requested=lock.stop_requested(),
        )
        logger.persist(paths.LAST_LOG)
        run_lock.release()
    return 0 if ok else 1

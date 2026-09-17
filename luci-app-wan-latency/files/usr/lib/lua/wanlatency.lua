-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 xiaokeikei
-- wanlatency.lua: per-target timeseries + target list (Lua 5.1)
module("wanlatency", package.seeall)

MAGIC = "WLAT2\0\0\0"
MAGIC1 = "WLAT1\0\0\0"
REC_SIZE = 8
HDR_SIZE = 8
LATEST_PATH = "/tmp/wan-latency-latest.json"
TARGET_CONF = "/etc/wan-latency/targets.conf"
INTERVAL_PATH = "/etc/wan-latency/interval"
MAX_TARGETS = 12
ALLOWED_INTERVALS = {2,5,10,15,30,60,120,300}

local function uci_number(option, default, minimum, maximum)
  local p = io.popen("uci -q get wan-latency.global." .. option .. " 2>/dev/null")
  local n
  if p then n = tonumber(p:read("*l") or ""); p:close() end
  n = math.floor(n or default)
  if n < minimum then n = minimum end
  if n > maximum then n = maximum end
  return n
end

function load_retain_days()
  return uci_number("retain_days", 366, 1, 3660)
end

function load_latency_threshold()
  return uci_number("latency_threshold_ms", 150, 1, 60000)
end

function load_loss_alert_consecutive()
  return uci_number("loss_alert_consecutive", 3, 1, 100)
end

function normalize_interval(n)
  n = tonumber(n)
  if not n then return 5 end
  n = math.floor(n)
  for i = 1, #ALLOWED_INTERVALS do
    if ALLOWED_INTERVALS[i] == n then return n end
  end
  return 5
end

function load_interval()
  local f = io.open(INTERVAL_PATH, "r")
  if f then
    local n = tonumber(f:read("*l") or "")
    f:close()
    if n then return normalize_interval(n) end
  end
  local p = io.popen("uci -q get wan-latency.global.interval 2>/dev/null")
  if p then
    local n = tonumber(p:read("*l") or "")
    p:close()
    if n then return normalize_interval(n) end
  end
  return 5
end

function save_interval(n)
  n = normalize_interval(n)
  os.execute("mkdir -p /etc/wan-latency")
  local f = io.open(INTERVAL_PATH, "w")
  if f then f:write(tostring(n) .. "\n"); f:close() end
  os.execute("uci -q set wan-latency.global.interval=" .. tostring(n) .. " ; uci -q commit wan-latency")
  return n
end

DATA_DIR = "/overlay/wan-latency/data"
RAW_PATH = DATA_DIR .. "/samples.bin"
ROLLUP_PATH = DATA_DIR .. "/rollup_1m.bin"

PALETTE = {"#ff7a1a","#2ec7ff","#8bdc63","#f6c445","#c084fc","#fb7185","#22d3ee","#a3e635","#f97316","#60a5fa","#e879f9","#34d399"}

PRESETS = {
  {id="ali", name="阿里云", host="223.5.5.5", color="#ff7a1a"},
  {id="tencent", name="腾讯云", host="119.29.29.29", color="#2ec7ff"},
  {id="steam", name="Steam", host="store.steampowered.com", color="#8bdc63"}
}

function load_paths()
  local f = io.open("/tmp/wan-latency.datadir", "r")
  local dir
  if f then dir = f:read("*l"); f:close() end
  if not dir or dir == "" then dir = "/overlay/wan-latency/data" end
  DATA_DIR = dir
  RAW_PATH = dir .. "/samples.bin"
  ROLLUP_PATH = dir .. "/rollup_1m.bin"
end

load_paths()

function raw_path(id) return DATA_DIR .. "/t_" .. id .. ".bin" end
function rollup_path(id) return DATA_DIR .. "/t_" .. id .. "_1m.bin" end

local function u32(n)
  n = math.floor(tonumber(n) or 0)
  if n < 0 then n = 0 end
  n = n % 4294967296
  local b1 = n % 256; n = math.floor(n / 256)
  local b2 = n % 256; n = math.floor(n / 256)
  local b3 = n % 256; n = math.floor(n / 256)
  local b4 = n % 256
  return string.char(b1, b2, b3, b4)
end

local function u16(n)
  n = math.floor(tonumber(n) or 0)
  if n < 0 then n = n + 65536 end
  n = n % 65536
  return string.char(n % 256, math.floor(n / 256) % 256)
end

function enc_rtt(ms)
  if ms == nil then return -1 end
  local v = math.floor(ms * 10 + 0.5)
  if v < 0 then v = 0 end
  if v > 32767 then v = 32767 end
  return v
end

function dec_rtt(v)
  v = tonumber(v)
  if v == nil or v < 0 then return nil end
  return v / 10
end

function pack_rec(ts, rtt, flags)
  return u32(ts) .. u16(enc_rtt(rtt)) .. u16(flags or 0)
end

function unpack_u32(s, off)
  local b1, b2, b3, b4 = s:byte(off, off + 3)
  if not b4 then return nil end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

function unpack_i16(s, off)
  local b1, b2 = s:byte(off, off + 1)
  if not b2 then return nil end
  local u = b1 + b2 * 256
  if u >= 32768 then return u - 65536 end
  return u
end

function unpack_rec(s)
  if not s or #s < REC_SIZE then return nil end
  return { ts = unpack_u32(s, 1), rtt = dec_rtt(unpack_i16(s, 5)), flags = unpack_i16(s, 7) }
end

function ensure_dir()
  os.execute("mkdir -p '" .. DATA_DIR .. "' /etc/wan-latency")
end

function ensure_file(path)
  local f = io.open(path, "rb")
  if f then
    local hdr = f:read(HDR_SIZE)
    f:close()
    if hdr == MAGIC then return true end
    os.execute("mv '" .. path .. "' '" .. path .. ".bad' 2>/dev/null")
  end
  local w = io.open(path, "wb")
  if not w then return false end
  w:write(MAGIC)
  w:close()
  return true
end

function file_count(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local sz = f:seek("end")
  f:close()
  if not sz or sz < HDR_SIZE then return 0 end
  return math.floor((sz - HDR_SIZE) / REC_SIZE)
end

function append_recs(path, blob)
  if not blob or #blob == 0 then return true end
  ensure_file(path)
  local f = io.open(path, "ab")
  if not f then return false end
  f:write(blob)
  f:flush()
  f:close()
  return true
end

local function rec_ts_at(f, idx)
  f:seek("set", HDR_SIZE + idx * REC_SIZE)
  local s = f:read(4)
  if not s or #s < 4 then return nil end
  return unpack_u32(s, 1)
end

function first_last_ts(path)
  local n = file_count(path)
  if n <= 0 then return nil, nil, 0 end
  local f = io.open(path, "rb")
  if not f then return nil, nil, 0 end
  local a = rec_ts_at(f, 0)
  local b = rec_ts_at(f, n - 1)
  f:close()
  return a, b, n
end

function lower_bound(f, n, ts)
  local lo, hi = 0, n
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local t = rec_ts_at(f, mid)
    if t and t < ts then lo = mid + 1 else hi = mid end
  end
  return lo
end

function choose_step(from_ts, to_ts, min_step)
  min_step = tonumber(min_step) or load_interval()
  min_step = math.floor(min_step)
  if min_step < 1 then min_step = 5 end
  local span = math.max(1, (to_ts or 0) - (from_ts or 0))
  local need = math.ceil(span / 1600)
  local candidates = {2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600}
  local step = 3600
  for i = 1, #candidates do
    local c = candidates[i]
    if c >= min_step and c >= need then
      step = c
      break
    end
  end
  if step < min_step then step = min_step end
  return step
end

function query_one(path, from_ts, to_ts, step)
  local empty = { t = {}, avg = {}, min = {}, max = {}, count = 0 }
  local n = file_count(path)
  if n <= 0 then return empty end
  local f = io.open(path, "rb")
  if not f then return empty end
  local first = rec_ts_at(f, 0)
  local last = rec_ts_at(f, n - 1)
  from_ts = tonumber(from_ts) or first
  to_ts = tonumber(to_ts) or last
  if from_ts < first then from_ts = first end
  if to_ts > last then to_ts = last end
  if to_ts < from_ts then f:close(); return empty end
  local i0 = lower_bound(f, n, from_ts)
  local i1 = lower_bound(f, n, to_ts + 1) - 1
  if i1 < i0 then f:close(); return empty end
  step = step or 5
  local out = { t = {}, avg = {}, min = {}, max = {}, count = i1 - i0 + 1 }
  local bts, bn, bsum, bmin, bmax = nil, 0, 0, nil, nil
  local function flush()
    if bts == nil then return end
    out.t[#out.t + 1] = bts
    if bn > 0 then
      local avg = math.floor(bsum / bn * 10 + 0.5) / 10
      out.avg[#out.avg + 1] = avg
      out.min[#out.min + 1] = math.floor(bmin * 10 + 0.5) / 10
      out.max[#out.max + 1] = math.floor(bmax * 10 + 0.5) / 10
    else
      out.avg[#out.avg + 1] = nil
      out.min[#out.min + 1] = nil
      out.max[#out.max + 1] = nil
    end
  end
  local idx = i0
  local CHUNK = 256
  while idx <= i1 do
    local take = i1 - idx + 1
    if take > CHUNK then take = CHUNK end
    f:seek("set", HDR_SIZE + idx * REC_SIZE)
    local blob = f:read(take * REC_SIZE) or ""
    local recs = math.floor(#blob / REC_SIZE)
    for i = 0, recs - 1 do
      local rec = unpack_rec(blob:sub(i * REC_SIZE + 1, i * REC_SIZE + REC_SIZE))
      if rec and rec.ts >= from_ts and rec.ts <= to_ts then
        local bt = math.floor(rec.ts / step) * step
        if bts and bts ~= bt then flush(); bn, bsum, bmin, bmax = 0, 0, nil, nil end
        bts = bt
        if rec.rtt ~= nil then
          bn = bn + 1
          bsum = bsum + rec.rtt
          if bmin == nil or rec.rtt < bmin then bmin = rec.rtt end
          if bmax == nil or rec.rtt > bmax then bmax = rec.rtt end
        end
      end
    end
    idx = idx + recs
    if recs == 0 then break end
  end
  flush()
  f:close()
  return out
end

function compact(path, min_ts)
  local n = file_count(path)
  if n <= 0 then return true end
  local f = io.open(path, "rb")
  if not f then return false end
  local first = rec_ts_at(f, 0)
  if not first or first >= min_ts then f:close(); return true end
  local i0 = lower_bound(f, n, min_ts)
  local tmp = path .. ".tmp"
  local w = io.open(tmp, "wb")
  if not w then f:close(); return false end
  w:write(MAGIC)
  local idx = i0
  while idx < n do
    local take = n - idx
    if take > 512 then take = 512 end
    f:seek("set", HDR_SIZE + idx * REC_SIZE)
    local blob = f:read(take * REC_SIZE) or ""
    if #blob == 0 then break end
    w:write(blob)
    idx = idx + math.floor(#blob / REC_SIZE)
  end
  f:close(); w:flush(); w:close()
  os.rename(tmp, path)
  return true
end

function json_escape(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "")
  return s
end

function json_num_or_null(v)
  if v == nil or v ~= v then return "null" end
  return string.format("%.1f", v)
end

function json_array(arr, as_int, n)
  n = n or #(arr or {})
  local t = {}
  for i = 1, n do
    local v = arr and arr[i]
    if v == nil then t[i] = "null"
    elseif as_int then t[i] = tostring(math.floor(v))
    else t[i] = json_num_or_null(v) end
  end
  return "[" .. table.concat(t, ",") .. "]"
end

function valid_host(host)
  host = tostring(host or "")
  if #host < 1 or #host > 253 then return false end
  if not host:match("^[%w%.%-%:]+$") then return false end
  if host:find("%.%.", 1, true) then return false end
  return true
end

function valid_id(id)
  return id and id:match("^[%a_][%w_]*$") and #id <= 32
end

function make_id(host)
  for i = 1, #PRESETS do
    if PRESETS[i].host == host then return PRESETS[i].id end
  end
  local s = tostring(host or ""):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if s == "" then s = "t" .. tostring(os.time()) end
  if s:match("^%d") then s = "t_" .. s end
  if #s > 28 then s = s:sub(1, 28) end
  return s
end

function sanitize_name(name)
  name = tostring(name or ""):gsub("[%c|]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil end
  if #name > 32 then name = name:sub(1, 32) end
  return name
end

function normalize_color(color, fallback)
  color = tostring(color or "")
  if color:match("^#[%x][%x][%x][%x][%x][%x]$") then return color end
  return fallback or PALETTE[1]
end

function load_targets()
  local list = {}
  local f = io.open(TARGET_CONF, "r")
  if f then
    for line in f:lines() do
      line = line:gsub("\r", "")
      if line ~= "" and not line:match("^#") then
        local id, name, host, color = line:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
        if valid_id(id) and valid_host(host) then
          list[#list + 1] = { id = id, name = sanitize_name(name) or id, host = host, color = normalize_color(color, PALETTE[1]) }
        end
      end
    end
    f:close()
  end
  if #list == 0 then
    for i = 1, #PRESETS do list[i] = { id = PRESETS[i].id, name = PRESETS[i].name, host = PRESETS[i].host, color = PRESETS[i].color } end
    save_targets(list)
  end
  return list
end

function save_targets(list)
  ensure_dir()
  os.execute("mkdir -p /etc/wan-latency")
  local tmp = TARGET_CONF .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write("# id|name|host|color\n")
  for i = 1, #list do
    local t = list[i]
    f:write(string.format("%s|%s|%s|%s\n", t.id, t.name, t.host, normalize_color(t.color, PALETTE[((i-1)%#PALETTE)+1])))
  end
  f:close()
  os.rename(tmp, TARGET_CONF)
  return true
end

function with_target_lock(callback)
  local ok_nixio, nixio = pcall(require, "nixio")
  local lock = "/tmp/wan-latency-targets.lock"
  local acquired = false
  for _ = 1, 50 do
    local rc = os.execute("mkdir '" .. lock .. "' 2>/dev/null")
    if rc == 0 or rc == true then acquired = true; break end
    if ok_nixio and nixio.nanosleep then pcall(nixio.nanosleep, 0, 100000000)
    else os.execute("sleep 1") end
  end
  if not acquired then return false, "配置正忙，请稍后重试" end
  local ok, a, b = pcall(callback)
  os.execute("rmdir '" .. lock .. "' 2>/dev/null")
  if not ok then return false, tostring(a) end
  return true, a, b
end

function next_color(list)
  local used = {}
  for i = 1, #list do used[list[i].color] = true end
  for i = 1, #PALETTE do
    if not used[PALETTE[i]] then return PALETTE[i] end
  end
  return PALETTE[(#list % #PALETTE) + 1]
end

function migrate_v1()
  load_paths()
  local path = DATA_DIR .. "/samples.bin"
  local f = io.open(path, "rb")
  if not f then return false end
  local hdr = f:read(8)
  if hdr ~= MAGIC1 then f:close(); return false end
  local sz = f:seek("end") or 0
  local n = math.floor((sz - 8) / 12)
  if n <= 0 then f:close(); return false end
  local blobs = { ali = {}, tencent = {}, steam = {} }
  f:seek("set", 8)
  for i = 1, n do
    local rec = f:read(12)
    if rec and #rec == 12 then
      local ts = unpack_u32(rec, 1)
      local ali = dec_rtt(unpack_i16(rec, 5))
      local tx = dec_rtt(unpack_i16(rec, 7))
      local st = dec_rtt(unpack_i16(rec, 9))
      blobs.ali[#blobs.ali + 1] = pack_rec(ts, ali, 0)
      blobs.tencent[#blobs.tencent + 1] = pack_rec(ts, tx, 0)
      blobs.steam[#blobs.steam + 1] = pack_rec(ts, st, 0)
    end
  end
  f:close()
  append_recs(raw_path("ali"), table.concat(blobs.ali))
  append_recs(raw_path("tencent"), table.concat(blobs.tencent))
  append_recs(raw_path("steam"), table.concat(blobs.steam))
  os.rename(path, path .. ".v1bak")
  local rp = DATA_DIR .. "/rollup_1m.bin"
  os.rename(rp, rp .. ".v1bak")
  return true
end

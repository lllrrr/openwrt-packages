-- AdGuard Home 管理中心 - 后台任务锁
-- 内核更新、插件更新、配置动作三类任务共用同一套判定逻辑：
-- 标记文件 + pid 存活 + 启动宽限 + 过期清理，避免各层重复实现导致行为不一致。

local M = {}

-- 默认超时（秒）：控制器会传入 TTL 覆盖，单元测试直接使用默认值
M.DEFAULTS = {
    update_grace = 60,      -- 锁已创建但 pid 尚未写入时的启动宽限
    plugin_max_age = 1800,  -- 插件更新标记最长存活时间
    action_grace = 20,      -- 动作刚启动、pid 尚未写入时的宽限
    action_max_age = 1800,  -- 动作标记最长存活时间，防止僵尸锁
}

local function read_pid(fs, path)
    local pid = (fs.readfile(path) or ""):gsub("%s+", "")
    if pid:match("^%d+$") then
        return tonumber(pid)
    end
    return nil
end

-- kill -0 只检测进程是否存在，不发送信号
local function alive(sys, pid)
    return sys.call("kill -0 " .. tostring(pid) .. " >/dev/null 2>&1") == 0
end

-- 内核安装/更新：update_core.sh 用锁目录 + pid 文件
function M.update_running(fs, run, sys, grace)
    local lock = run .. "_update.lock"
    if not fs.access(lock) then
        return false
    end

    local pidfile = run .. "_update.pid"
    local pid = read_pid(fs, pidfile)
    if pid then
        if alive(sys, pid) then
            return true
        end
        -- pid 已落盘但进程已退出：任务结束，立即释放锁
        fs.remove(lock)
        fs.remove(pidfile)
        return false
    end

    -- 刚创建锁但 pid 尚未写入时，给任务一个短暂的启动时间
    local mtime = fs.stat(lock, "mtime")
    if mtime and (os.time() - mtime) < (grace or M.DEFAULTS.update_grace) then
        return true
    end

    -- 锁文件已过期，清理后允许重新执行
    fs.remove(lock)
    fs.remove(pidfile)
    return false
end

-- 插件在线更新：plugin_update.sh 用目录锁 + running 标记，这里只看标记存活时间
function M.plugin_running(fs, run, max_age)
    local path = run .. "_plugin_update.running"
    local mtime = fs.stat(path, "mtime")
    if not mtime then
        return false
    end
    if (os.time() - mtime) > (max_age or M.DEFAULTS.plugin_max_age) then
        fs.remove(path)
        return false
    end
    return true
end

-- 配置动作的日志、返回码与 pid 按动作名分开存放，避免并发时互相覆盖
function M.action_files(run, name)
    local base = run .. "_action_" .. name
    return base .. ".log", base .. ".code", base .. ".pid", base .. ".running"
end

function M.action_name(fs, run)
    return ((fs.readfile(run .. "_action.name") or ""):gsub("%s+", ""))
end

-- 判断最近一次动作是否仍在运行：优先看 pid，pid 尚未落盘时给刚启动的动作一个宽限期
function M.action_running(fs, run, sys, actions, opts)
    opts = opts or {}
    local name = M.action_name(fs, run)
    if name == "" or not actions[name] then
        return false
    end

    local _, _, pidfile, running = M.action_files(run, name)
    if not fs.access(running) then
        return false
    end

    local mtime = fs.stat(running, "mtime") or 0
    -- 进程卡死或 pid 被复用时标记会永久残留，超过上限直接清理
    if (os.time() - mtime) > (opts.max_age or M.DEFAULTS.action_max_age) then
        fs.remove(running)
        fs.remove(pidfile)
        return false
    end

    local pid = read_pid(fs, pidfile)
    if pid then
        if alive(sys, pid) then
            return true
        end
        fs.remove(running)
        fs.remove(pidfile)
        return false
    end

    -- 子 shell 刚启动时 pid 可能还没写入，短暂宽限避免误判为已结束
    if (os.time() - mtime) <= (opts.grace or M.DEFAULTS.action_grace) then
        return true
    end
    fs.remove(running)
    fs.remove(pidfile)
    return false
end

-- 统一忙判定：返回 reason 供 json_error 使用，nil 表示空闲。
-- 顺序固定为「内核更新 > 插件更新 > 配置动作」，提示语由各入口自行决定。
function M.busy(fs, run, sys, actions, opts)
    opts = opts or {}
    if M.update_running(fs, run, sys, opts.update_grace) then
        return "update_busy"
    end
    if M.plugin_running(fs, run, opts.plugin_max_age) then
        return "plugin_update_busy"
    end
    if M.action_running(fs, run, sys, actions, opts) then
        return "action_busy"
    end
    return nil
end

return M

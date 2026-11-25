-- AdGuard Home 管理中心 - 后台任务标记
-- 只做标记文件的时间判断，避免各动作层重复实现。

local M = {}

-- 插件在线更新任务是否仍在运行。
-- 任务异常退出可能留下标记，超过 30 分钟视为过期并顺手清理。
function M.plugin_running(fs, run)
    local path = run .. "_plugin_update.running"
    local mtime = fs.stat(path, "mtime")
    if not mtime then
        return false
    end
    if (os.time() - mtime) > 1800 then
        fs.remove(path)
        return false
    end
    return true
end

return M

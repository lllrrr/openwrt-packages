--[[
    systools/common.lua - System Tools 公共Lua模块
    提供 shell_escape 命令转义和 sanitize_path 路径净化函数
    所有CBI页面共享的安全工具函数
]]--

-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.
--
-- systools 公共 Lua 模块
-- 提供通用的工具函数，供各 CBI 页面复用

module("luci.model.cbi.systools.common", package.seeall)

-- Shell 命令转义，防止命令注入
-- 用单引号包裹字符串，并转义内部的单引号
function shell_escape(str)
    if not str then return "" end
    return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

-- 路径净化，防止路径遍历攻击
-- 循环净化直到没有变化，覆盖 ../、..\、....// 等各种变形
function sanitize_path(path)
    if not path then return "" end
    local prev
    repeat
        prev = path
        -- 移除各种路径遍历模式
        path = path:gsub("%.%./", "")      -- ../
        path = path:gsub("%.%.\\", "")     -- ..\
        path = path:gsub("%.%.%.%./", "")  -- ..../
        path = path:gsub("//+", "/")       -- 多个连续斜杠
        path = path:gsub("\\\\+", "\\")    -- 多个连续反斜杠
    until path == prev
    return path
end

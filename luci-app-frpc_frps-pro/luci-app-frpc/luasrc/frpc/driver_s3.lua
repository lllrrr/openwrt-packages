-- Copyright 2026 luci-app-frpc-pro
-- Licensed to the public under the MIT License.
-- ⚠️ 一期空壳实现：S3 driver 接口预留，二期补全 AWS Sig V4 签名 + 上传/下载逻辑

local M = {}

local Driver = {}
Driver.__index = Driver

local NOT_IMPL = "S3 driver 一期未实现，请等待二期版本"

function M.new(cfg)
    local self = setmetatable({}, Driver)
    self.cfg = cfg or {}
    return self
end

function Driver:test()
    return false, NOT_IMPL
end

function Driver:list()
    return {}, NOT_IMPL
end

function Driver:put(local_path, remote_name, progress_cb)
    return false, NOT_IMPL
end

function Driver:get(remote_name, local_path, progress_cb)
    return false, NOT_IMPL
end

function Driver:remove(remote_name)
    return false, NOT_IMPL
end

return M

-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 smallprogram
-- Repository: https://github.com/smallprogram/luci-app-ghfu

module("luci.controller.ghfu", package.seeall)

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local i18n = require "luci.i18n"
local uci = require("luci.model.uci").cursor()
local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"

local CFG = "ghfu"
local SEC = "main"
local tr = i18n.translate

local function json_resp(tbl)
    http.prepare_content("application/json")
    http.write_json(tbl)
end

local function to_bool(v)
    return v == "1" or v == "true" or v == "on" or v == "yes"
end

local function trim(s)
    if not s then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_cfg()
    return {
        github_repo = uci:get(CFG, SEC, "github_repo") or "smallprogram/OpenWrtAction",
        selected_release = uci:get(CFG, SEC, "selected_release") or "",
        keep_config = uci:get(CFG, SEC, "keep_config") or "1",
        fetch_timeout = uci:get(CFG, SEC, "fetch_timeout") or "15"
    }
end

local function set_cfg(repo, selected_release, keep_config, fetch_timeout)
    if not uci:get(CFG, SEC) then
        uci:section(CFG, "ghfu", SEC, {})
    end

    if repo and repo ~= "" then
        uci:set(CFG, SEC, "github_repo", repo)
    end

    if selected_release ~= nil then
        uci:set(CFG, SEC, "selected_release", selected_release)
    end

    if keep_config ~= nil then
        uci:set(CFG, SEC, "keep_config", keep_config)
    end

    if fetch_timeout ~= nil then
        local t = tonumber(fetch_timeout)
        if t and t >= 5 and t <= 300 then
            uci:set(CFG, SEC, "fetch_timeout", tostring(math.floor(t)))
        end
    end

    uci:commit(CFG)
end

local function get_install_epoch()
    -- Prefer dedicated flash timestamp written by uci-defaults on every post-flash boot
    local f = io.open("/etc/ghfu_flash_epoch", "r")
    if f then
        local v = f:read("*l")
        f:close()
        local epoch = tonumber(v)
        if epoch and epoch > 0 then
            return epoch
        end
    end
    -- Fallback: mtime of /etc/openwrt_version
    local st = fs.stat("/etc/openwrt_version")
    if st and st.mtime then
        return tonumber(st.mtime) or 0
    end
    return 0
end

local function epoch_to_iso_utc(epoch)
    if not epoch or epoch <= 0 then
        return ""
    end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

local function epoch_to_local_string(epoch)
    if not epoch or epoch <= 0 then
        return ""
    end
    return os.date("%Y-%m-%d %H:%M:%S", epoch)
end

local function get_tz_offset_minutes()
    local z = os.date("%z") or "+0000"
    local sign, hh, mm = z:match("([%+%-])(%d%d)(%d%d)")
    if not sign then
        return 0
    end

    local v = (tonumber(hh) or 0) * 60 + (tonumber(mm) or 0)
    if sign == "-" then
        v = -v
    end
    return v
end

local function normalize_repo(repo)
    repo = trim(repo)
    repo = repo:gsub("^https://github.com/", "")
    repo = repo:gsub("^http://github.com/", "")
    repo = repo:gsub("^github.com/", "")
    repo = repo:gsub("/*$", "")
    return repo
end

local function parse_assets(raw_assets)
    local assets = {}
    if not raw_assets or type(raw_assets) ~= "table" then
        return assets
    end

    local tmp = {}
    for k, a in pairs(raw_assets) do
        if type(a) == "table" then
            tmp[#tmp + 1] = {
                idx = tonumber(k) or (1000000 + #tmp),
                name = a.name or "",
                url = a.browser_download_url or "",
                size = a.size or 0
            }
        end
    end

    table.sort(tmp, function(x, y)
        return (x.idx or 0) < (y.idx or 0)
    end)

    for _, a in ipairs(tmp) do
        assets[#assets + 1] = {
            name = a.name,
            url = a.url,
            size = a.size
        }
    end

    return assets
end

local function release_from_obj(obj)
    return {
        tag_name = obj.tag_name or "",
        release_name = obj.name or obj.tag_name or "",
        published_at = obj.published_at or "",
        html_url = obj.html_url or "",
        assets = parse_assets(obj.assets)
    }
end

local fetch_github_json

local function fetch_previous_release_with_assets(repo, timeout, accept_header, exclude_tag)
    local releases_url = "https://api.github.com/repos/" .. repo .. "/releases?per_page=10"
    local rel_obj = fetch_github_json(releases_url, timeout, accept_header)
    if not rel_obj or type(rel_obj) ~= "table" then
        return nil
    end

    local rel_tmp = {}
    for k, v in pairs(rel_obj) do
        if type(v) == "table" then
            rel_tmp[#rel_tmp + 1] = {
                idx = tonumber(k) or (1000000 + #rel_tmp),
                item = v
            }
        end
    end

    table.sort(rel_tmp, function(x, y)
        return (x.idx or 0) < (y.idx or 0)
    end)

    for _, r in ipairs(rel_tmp) do
        local candidate = release_from_obj(r.item)
        if candidate.tag_name ~= "" and candidate.tag_name ~= exclude_tag and #candidate.assets > 0 then
            return candidate
        end
    end

    return nil
end

fetch_github_json = function(url, timeout, accept_header)
    local cmd = "uclient-fetch -T " .. tostring(timeout) .. " -H " .. util.shellquote(accept_header) .. " -qO- " .. util.shellquote(url) .. " 2>/dev/null"
    local raw = sys.exec(cmd)

    -- Fallback for uclient-fetch variants without custom-header support.
    if not raw or raw == "" then
        local fallback = "uclient-fetch -T " .. tostring(timeout) .. " -qO- " .. util.shellquote(url) .. " 2>/dev/null"
        raw = sys.exec(fallback)
    end

    if not raw or raw == "" then
        return nil, tr("Failed to fetch GitHub release data")
    end

    local obj = jsonc.parse(raw)
    if not obj then
        return nil, tr("Failed to parse GitHub API response")
    end

    return obj
end

local function fetch_latest_release(repo, timeout)
    local t = math.floor(tonumber(timeout) or 15)
    if t < 5 then t = 5 end
    if t > 300 then t = 300 end
    local accept = "Accept: application/vnd.github.full+json"
    local latest_url = "https://api.github.com/repos/" .. repo .. "/releases/latest"
    local obj, err = fetch_github_json(latest_url, t, accept)
    if not obj then
        return nil, err
    end

    if obj.message and not obj.tag_name then
        return nil, tr("GitHub API error: ") .. tostring(obj.message)
    end

    local latest = release_from_obj(obj)
    local info = {
        fallback_used = false,
        partial_assets = false
    }

    if #latest.assets > 0 then
        local prev = fetch_previous_release_with_assets(repo, t, accept, latest.tag_name)
        if prev and #prev.assets > #latest.assets then
            info.partial_assets = true
        end
        return latest, nil, info
    end

    -- Latest release exists but assets are not ready yet (e.g. CI still uploading).
    -- Fallback to the previous release that already has assets.
    local fallback = fetch_previous_release_with_assets(repo, t, accept, latest.tag_name)
    if fallback then
        info.fallback_used = true
        return fallback, nil, info
    end

    return latest, nil, info
end

function index()
    if not fs.access("/etc/config/ghfu") then
        return
    end

    entry({"admin", "system", "ghfu"}, call("action_index"), _("GitHub Firmware Upgrade"), 65)
    entry({"admin", "system", "ghfu", "status"}, call("action_status")).leaf = true
    entry({"admin", "system", "ghfu", "download"}, call("action_download")).leaf = true
    entry({"admin", "system", "ghfu", "upgrade"}, call("action_upgrade")).leaf = true
    entry({"admin", "system", "ghfu", "backup"}, call("action_backup")).leaf = true
end

function action_index()
    luci.template.render("ghfu/main")
end

function action_status()
    local cfg = get_cfg()
    local repo_input = normalize_repo(http.formvalue("repo") or cfg.github_repo)

    -- Read and validate fetch_timeout from form; fall back to saved config
    local timeout_raw = trim(http.formvalue("fetch_timeout") or "")
    local fetch_timeout = tonumber(timeout_raw)
    if not fetch_timeout or fetch_timeout < 5 or fetch_timeout > 300 then
        fetch_timeout = tonumber(cfg.fetch_timeout) or 15
    end
    fetch_timeout = math.floor(fetch_timeout)

    -- Persist timeout setting
    set_cfg(nil, nil, nil, tostring(fetch_timeout))

    if repo_input == "" then
        json_resp({
            ok = false,
            msg = tr("GitHub repository cannot be empty"),
            config = cfg
        })
        return
    end

    local install_epoch = get_install_epoch()
    local install_iso = epoch_to_iso_utc(install_epoch)
    local install_local = epoch_to_local_string(install_epoch)

    local latest, err, rel_info = fetch_latest_release(repo_input, fetch_timeout)
    if not latest then
        local timed_out = (err == tr("Failed to fetch GitHub release data"))
        json_resp({
            ok = false,
            msg = timed_out and tr("Unable to fetch GitHub Release, please check your network connection") or err,
            config = cfg,
            install_epoch = install_epoch,
            install_time = install_local,
            tz_offset_min = get_tz_offset_minutes(),
            fetch_timeout = fetch_timeout
        })
        return
    end

    local has_new = false
    if latest.published_at ~= "" and install_iso ~= "" then
        has_new = latest.published_at > install_iso
    end

    local msg
    if has_new then
        msg = tr("New firmware is available")
    else
        msg = tr("No firmware newer than current system was found")
    end

    json_resp({
        ok = true,
        msg = msg,
        has_new = has_new,
        fallback_used = rel_info and rel_info.fallback_used or false,
        partial_assets = rel_info and rel_info.partial_assets or false,
        repo = repo_input,
        install_epoch = install_epoch,
        install_time = install_local,
        tz_offset_min = get_tz_offset_minutes(),
        fetch_timeout = fetch_timeout,
        config = cfg,
        latest = latest
    })
end

function action_download()
    local repo = normalize_repo(http.formvalue("repo") or "")
    local selected_release = trim(http.formvalue("selected_release") or "")
    local keep_config = to_bool(http.formvalue("keep_config")) and "1" or "0"
    local asset_url = trim(http.formvalue("asset_url") or "")
    local asset_name = trim(http.formvalue("asset_name") or "firmware.bin.gz")

    local logs = {}

    if repo == "" then
        logs[#logs + 1] = tr("GitHub repository cannot be empty")
        json_resp({ ok = false, logs = logs })
        return
    end

    set_cfg(repo, selected_release, keep_config)

    if selected_release == "" then
        logs[#logs + 1] = tr("Please select firmware to upgrade")
        json_resp({ ok = false, logs = logs })
        return
    end

    if asset_url == "" then
        logs[#logs + 1] = tr("Please select a firmware asset")
        json_resp({ ok = false, logs = logs })
        return
    end

    if not asset_url:match("^https://") then
        logs[#logs + 1] = tr("Invalid firmware URL, only https is supported")
        json_resp({ ok = false, logs = logs })
        return
    end

    local clean_name = asset_name:gsub("[^%w%._%-]", "_")
    if clean_name == "" then
        clean_name = "firmware.bin.gz"
    end

    local fw_path = "/tmp/ghfu_" .. clean_name
    local dl_cmd = "uclient-fetch -qO " .. util.shellquote(fw_path) .. " " .. util.shellquote(asset_url)

    logs[#logs + 1] = tr("Downloading firmware: ") .. clean_name
    local rc = sys.call(dl_cmd .. " >/tmp/ghfu-download.log 2>&1")
    if rc ~= 0 or not fs.access(fw_path) then
        logs[#logs + 1] = tr("Firmware download failed, please check network or GitHub repository")
        json_resp({ ok = false, logs = logs })
        return
    end

    logs[#logs + 1] = clean_name .. tr(" downloaded successfully")
    json_resp({ ok = true, logs = logs, fw_name = clean_name })
end

function action_upgrade()
    local keep_config = to_bool(http.formvalue("keep_config")) and "1" or "0"
    local fw_name = trim(http.formvalue("fw_name") or "")

    local logs = {}

    -- Prevent path traversal: only allow safe filenames
    if fw_name == "" or not fw_name:match("^[%w%._%-]+$") then
        logs[#logs + 1] = tr("Invalid firmware file name")
        json_resp({ ok = false, logs = logs })
        return
    end

    local fw_path = "/tmp/ghfu_" .. fw_name
    if not fs.access(fw_path) then
        logs[#logs + 1] = tr("Firmware file not found, please download again")
        json_resp({ ok = false, logs = logs })
        return
    end

    local keep_flag = (keep_config == "1") and "" or "-n"
    local up_cmd = "/sbin/sysupgrade " .. keep_flag .. " " .. util.shellquote(fw_path)

    logs[#logs + 1] = tr("Starting system upgrade")
    logs[#logs + 1] = (keep_config == "1") and tr("Upgrade mode: keep configuration") or tr("Upgrade mode: do not keep configuration")

    local bg = string.format("(sleep 2; %s >/tmp/ghfu-upgrade.log 2>&1) &", up_cmd)
    sys.call(bg)

    json_resp({
        ok = true,
        logs = logs,
        rebooting = true
    })
end

function action_backup()
    local tmp = "/tmp/ghfu-backup.tar.gz"
    fs.unlink(tmp)
    local rc = sys.call("sysupgrade --create-backup " .. util.shellquote(tmp) .. " >/dev/null 2>&1")
    if rc ~= 0 or not fs.access(tmp) then
        http.status(500, "Internal Server Error")
        http.prepare_content("text/plain; charset=utf-8")
        http.write(tr("Backup failed"))
        return
    end
    local st = fs.stat(tmp)
    local hostname = trim(sys.exec("cat /proc/sys/kernel/hostname 2>/dev/null"))
    if hostname == "" then
        hostname = "OpenWrt"
    end
    hostname = hostname:gsub("[^%w%._%-]", "_")
    local fname = "backup-" .. hostname .. "-" .. os.date("%Y-%m-%d") .. ".tar.gz"
    http.header("Content-Disposition", 'attachment; filename="' .. fname .. '"')
    if st then
        http.header("Content-Length", tostring(st.size))
    end
    http.prepare_content("application/octet-stream")
    local f = io.open(tmp, "rb")
    if f then
        repeat
            local chunk = f:read(65536)
            if chunk then http.write(chunk) end
        until not chunk
        f:close()
        fs.unlink(tmp)
    end
end

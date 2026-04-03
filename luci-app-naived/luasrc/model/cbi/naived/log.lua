require "luci.util"
require "nixio.fs"
require "luci.sys"
require "luci.http"

f = SimpleForm("logview")
f.reset = false
f.submit = false
f:append(Template("naived/log"))

-- Custom log helper
function log(...)
    local result = os.date("%Y-%m-%d %H:%M:%S: ") .. table.concat({...}, " ")
    local f, err = io.open("/var/log/naived.log", "a")
    if f and err == nil then
        f:write(result .. "\n")
        f:close()
    end
end

-- Create the backup and restore form
fb = SimpleForm('backup-restore')
fb.reset = false
fb.submit = false
s = fb:section(SimpleSection, translate("Backup and Restore"), translate("Backup or Restore Client and Server Configurations.") ..
                            "<br><font style='color:red'><b>" ..
                            translate("Note: Restoring configurations across different versions may cause compatibility issues.") ..
                            "</b></font>")
s.anonymous = true
s:append(Template("naived/backup_restore"))

-- Define backup target files and directories
local backup_targets = {
    files = {
        "/etc/config/naived"
    },
    dirs = {
        "/etc/naived"
    }
}

local file_path = '/tmp/naived_upload.tar.gz'
local temp_dir = '/tmp/naived_bak'
local fd

-- Handle uploaded files
luci.http.setfilehandler(function(meta, chunk, eof)
    if not fd and meta and meta.name == "ulfile" and chunk then
        -- Initialize upload handling
        luci.sys.call("rm -rf " .. temp_dir)
        nixio.fs.remove(file_path)
        fd = nixio.open(file_path, "w")
        luci.sys.call("echo '' > /var/log/naived.log")
    end

    if fd and chunk then
        fd:write(chunk)
    end

    if eof and fd then
        fd:close()
        fd = nil
        if nixio.fs.access(file_path) then
            log(" * naived configuration archive uploaded successfully...")  -- Use the custom log helper
            luci.sys.call("mkdir -p " .. temp_dir)

            if luci.sys.call("tar -xzf " .. file_path .. " -C " .. temp_dir) == 0 then
                -- Restore regular files
                for _, target in ipairs(backup_targets.files) do
                    local temp_file = temp_dir .. target
                    if nixio.fs.access(temp_file) then
                        luci.sys.call(string.format("cp -f '%s' '%s'", temp_file, target))
                        log(" * File " .. target .. " restored successfully...")  -- Use the custom log helper
                    end
                end

                -- Restore directories
                for _, target in ipairs(backup_targets.dirs) do
                    local temp_dir_path = temp_dir .. target
                    if nixio.fs.access(temp_dir_path) then
                        luci.sys.call(string.format("cp -rf '%s'/* '%s/'", temp_dir_path, target))
                        log(" * Directory " .. target .. " restored successfully...")  -- Use the custom log helper
                    end
                end

                log(" * naived configuration restored successfully...")  -- Use the custom log helper
                log(" * Restarting the naived service...\n")  -- Use the custom log helper
                luci.sys.call('/etc/init.d/naived restart > /dev/null 2>&1 &')
            else
                log(" * Failed to extract the naived configuration archive, please try again!")  -- Use the custom log helper
            end
        else
            log(" * Failed to upload the naived configuration archive, please try again!")  -- Use the custom log helper
        end

        -- Clean up temporary files
        luci.sys.call("rm -rf " .. temp_dir)
        nixio.fs.remove(file_path)
    end
end)

return f, fb

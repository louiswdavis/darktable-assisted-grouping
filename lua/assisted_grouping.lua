--[[
    assisted_grouping.lua — darktable glue for Assisted Grouping

    Reads the selection, gets sub-second capture times from python/exif_times.py,
    runs the layers in grouping_core.lua and writes the group tags and native
    groups. The functions
    above the `require "darktable"` line need no darktable and load in plain `lua`.
]]

local THIS_DIR = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")) or "."
package.path = THIS_DIR .. "/?.lua;" .. package.path
local C = require("grouping_core")

local M = {}

-- Pure helpers ------------------------------------------------------------------

local function blank_to_nil(s)
    if s == nil or s == "" then return nil end
    return s
end

-- Joined with the separator the folder already uses, so Windows paths stay native.
local function join_path(dir, file)
    local sep = (dir:find("\\", 1, true) and not dir:find("/", 1, true)) and "\\" or "/"
    return dir:gsub("[/\\]+$", "") .. sep .. file
end

-- Tag names of a darktable image as a set. Assigned once darktable is loaded.
M.tags_of = nil

-- One record per darktable image. `dir` + `filename` is what grouping_core.collapse
-- pairs RAW+JPEG by; `file` is the full path the helper reads; `img` is the
-- darktable image the tags are written to.
function M.build_images(images)
    local out = {}
    for _, img in ipairs(images) do
        local taken = blank_to_nil(img.exif_datetime_taken)
        out[#out + 1] = {
            id = tonumber(img.id),
            img = img,
            dir = img.path,
            filename = img.filename,
            file = join_path(img.path or "", img.filename or ""),
            epoch = C.exif_time_to_epoch(taken),
            maker = blank_to_nil(img.exif_maker),
            model = blank_to_nil(img.exif_model),
            lens = blank_to_nil(img.exif_lens),
            tags = M.tags_of(img),
        }
    end
    return out
end

-- `id,path` rows for exif_times.py. Frames darktable has no capture time for are
-- left out: they are their own group whatever the helper reads.
function M.manifest_rows(records)
    local rows = {}
    for _, r in ipairs(records) do
        if r.epoch then rows[#rows + 1] = { r.id, r.file } end
    end
    table.sort(rows, function(a, b) return a[1] < b[1] end)
    return rows
end

-- exif_times.py's results: id (number) → epoch text ("" when unreadable), and the
-- `#precision` value.
function M.parse_helper_results(text)
    local by_id, precision = {}, nil
    for _, row in ipairs(C.parse_csv(text or "")) do
        if row[1] == "#precision" then
            precision = row[2]
        else
            local id = tonumber(row[1])
            if id then by_id[id] = row[2] or "" end
        end
    end
    return by_id, precision
end

-- Adds the helper's sub-second fraction to each record's whole-second epoch, only
-- when every manifest row came back with a fraction and the helper says
-- `subsecond`. Only the fraction is taken: the helper's whole part (timegm) and
-- the core's (os.time) can differ by the local offset. Returns "subsecond" or
-- "whole" and, for "whole", why.
function M.apply_subsec(records, text)
    local rows = M.manifest_rows(records)
    if #rows == 0 then return "whole", "no frame has a capture time" end
    local by_id, precision = M.parse_helper_results(text)
    if precision ~= "subsecond" then
        return "whole", "the helper reported whole-second precision"
    end
    local frac_of = {}
    for _, row in ipairs(rows) do
        local s = by_id[row[1]]
        local e = s and s:find(".", 1, true) and tonumber(s)
        if not e then
            return "whole", string.format("image %d has no readable sub-second time", row[1])
        end
        frac_of[row[1]] = e - math.floor(e)
    end
    for _, r in ipairs(records) do
        if r.epoch and frac_of[r.id] then r.epoch = r.epoch + frac_of[r.id] end
    end
    return "subsecond"
end

-- Per image: the sorted tags to attach and detach, and the plugin's tags after the
-- change. Ledger tags no longer on the image (removed by hand) are dropped.
function M.plan_tag_changes(records, wanted, ledger)
    local plans = {}
    for _, r in ipairs(records) do
        local entry = ledger[r.id]
        local mine = {}
        for name in pairs(entry and entry.tags or {}) do
            if r.tags[name] then mine[name] = true end
        end
        local add, remove = C.plan_replace(r.tags, mine, wanted[r.id] or {})
        plans[#plans + 1] = { record = r, add = add, remove = remove, mine = mine }
    end
    return plans
end

-- Sets a ledger entry's tags, dropping the entry when nothing of the plugin's is left.
function M.set_ledger_tags(ledger, id, mine)
    local entry = ledger[id] or { tags = {} }
    entry.tags = mine
    if next(mine) or entry.native then ledger[id] = entry else ledger[id] = nil end
end

-- Sets a ledger entry's native group leader (nil clears it), dropping the entry
-- when nothing of the plugin's is left.
function M.set_ledger_native(ledger, id, leader)
    local entry = ledger[id] or { tags = {} }
    entry.native = leader
    if leader or next(entry.tags or {}) then ledger[id] = entry else ledger[id] = nil end
end

-- The run stamp for `now` (os.time), and the time it stands for. Never at or before
-- `last_time`, so runs in the same second get different stamps and their groups
-- never merge.
function M.run_stamp(now, last_time)
    local t = (last_time and now <= last_time) and last_time + 1 or now
    return os.date("%Y-%m-%d %H:%M:%S", t), t
end

-- UTF-8 → UTF-16LE (no BOM), for the .vbs launcher: wscript reads a script as
-- ANSI unless it's UTF-16, which garbles a non-ASCII tmp path.
function M.utf16le(s)
    local out = {}
    for _, c in utf8.codes(s) do
        if c >= 0x10000 then
            c = c - 0x10000
            local hi, lo = 0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF)
            out[#out + 1] = string.char(hi & 0xFF, hi >> 8, lo & 0xFF, lo >> 8)
        else
            out[#out + 1] = string.char(c & 0xFF, c >> 8)
        end
    end
    return table.concat(out)
end

local ok, dt = pcall(require, "darktable")
if not ok then return M end

local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local tags = dt.tags

du.check_min_api_version("7.0.0", "assisted_grouping")

-- Every tag attach/detach rewrites the XMP sidecar, so writes are paced: after a
-- budget of writes the GUI gets a short sleep.
local WRITE_BUDGET = 12
local WRITE_SLEEP_MS = 20
-- exif_times.py reports no progress, so a run that hasn't finished in this long is
-- given up on and the run uses whole seconds.
local HELPER_TIMEOUT_SECONDS = 600

local IS_WINDOWS = dt.configuration.running_os == "windows"
local TMP_DIR = dt.configuration.tmp_dir
local MANIFEST_PATH = TMP_DIR .. "/dt_assisted_grouping_manifest.csv"
local RESULTS_PATH = TMP_DIR .. "/dt_assisted_grouping_results.csv"
local DONE_PATH = TMP_DIR .. "/dt_assisted_grouping_done.txt"
local BAT_PATH = TMP_DIR .. "/dt_assisted_grouping_run.bat"
local VBS_PATH = TMP_DIR .. "/dt_assisted_grouping_run.vbs"
local LOG_PATH = dt.configuration.config_dir .. "/assisted_grouping.log"
local PREV_LOG_PATH = dt.configuration.config_dir .. "/assisted_grouping.prev.log"
local LEDGER_DIR = dt.configuration.config_dir .. "/assisted_grouping"
local LEDGER_PATH = LEDGER_DIR .. "/ledger.csv"

M.tags_of = function(img)
    local have = {}
    for _, t in ipairs(tags.get_tags(img)) do have[t.name] = true end
    return have
end

local function file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then f:close(); return true else return false end
end

local function first_existing(paths)
    for _, p in ipairs(paths) do
        if p and p ~= "" and file_exists(p) then
            return p
        end
    end
    return nil
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local t = f:read("*a")
    f:close()
    return t
end

local function shell_quote(s)
    if IS_WINDOWS then return '"' .. s .. '"' end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function make_dir(dir)
    if IS_WINDOWS then
        os.execute(string.format('mkdir "%s" 2>nul', dir:gsub("/", "\\")))
    else
        os.execute("mkdir -p " .. shell_quote(dir) .. " 2>/dev/null")
    end
end

-- Log lines wait here while exif_times.py may append its stderr to the same file.
local log_buffer = {}

local function log(msg)
    log_buffer[#log_buffer + 1] = os.date("%H:%M:%S ") .. "lua: " .. msg
end

-- Only call while no exif_times.py process is running.
local function flush_log()
    if #log_buffer == 0 then return end
    local f = io.open(LOG_PATH, "a")
    if not f then return end
    f:write(table.concat(log_buffer, "\n"), "\n")
    f:close()
    log_buffer = {}
end

local function say(msg)
    dt.print(msg)
    log(msg)
end

-- dt.print_error only writes to darktable's log (-d lua); users never see it.
local function notify_error(msg)
    dt.print(msg)
    dt.print_error(msg)
    log(msg)
end

local function start_log(n)
    flush_log()
    pcall(os.remove, PREV_LOG_PATH)
    pcall(os.rename, LOG_PATH, PREV_LOG_PATH)
    log(string.format("group started: darktable %s, %d images", tostring(dt.configuration.version), n))
end

local function plugin_folder_pref()
    return (dt.preferences.read("assisted_grouping", "plugin_folder", "directory") or ""):gsub("[/\\]+$", "")
end

-- From the plugin folder preference alone when it's set; a wrong folder is an
-- error rather than a quiet switch to some other copy.
local function helper_script()
    local folder = plugin_folder_pref()
    if folder ~= "" then
        local script = folder .. "/python/exif_times.py"
        if not file_exists(script) then
            error(string.format("Assisted Grouping: the plugin folder preference (%s) has no python/exif_times.py. Point it at the darktable-assisted-grouping folder, or clear it to auto-detect.", folder), 0)
        end
        return script
    end
    local home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
    local found = first_existing({
        THIS_DIR .. "/exif_times.py",
        THIS_DIR .. "/python/exif_times.py",
        THIS_DIR .. "/../python/exif_times.py",
        THIS_DIR .. "/../../python/exif_times.py",
        home .. "/Pictures/DarkTable/Settings/Plugins/darktable-assisted-grouping/python/exif_times.py",
    })
    return found or (THIS_DIR .. "/../python/exif_times.py")
end

local function plugin_root(script)
    local folder = plugin_folder_pref()
    if folder ~= "" then return folder end
    local script_dir = (script and script:match("^(.*)[/\\]")) or THIS_DIR
    return script_dir:match("^(.*)[/\\]python$") or script_dir
end

local function python_bin(script)
    local pref = dt.preferences.read("assisted_grouping", "python_bin", "file")
    if pref and pref ~= "" then return pref end

    local home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
    local root = plugin_root(script)
    local found = first_existing({
        root .. "/.venv/Scripts/python.exe",
        root .. "/.venv/bin/python",
        THIS_DIR .. "/../.venv/Scripts/python.exe",
        THIS_DIR .. "/../.venv/bin/python",
        home .. "/Pictures/DarkTable/Settings/Plugins/darktable-assisted-grouping/.venv/Scripts/python.exe",
    })
    if found then return found end

    local v = df.check_if_bin_exists(IS_WINDOWS and "python" or "python3")
    if not v then
        v = IS_WINDOWS and "python" or "python3"
    end
    return v
end

-- The exit code goes to a temp file renamed onto done_path, so done_path
-- never exists without its code in it. Returns false when it couldn't launch.
local function run_async_command(cmd, done_path)
    local done_tmp = done_path .. ".tmp"
    if IS_WINDOWS then
        local f = io.open(BAT_PATH, "w")
        if not f then return false end
        local win_done, win_tmp = done_path:gsub("/", "\\"), done_tmp:gsub("/", "\\")
        f:write("@echo off\r\nchcp 65001>nul\r\n")
        f:write(cmd, " < NUL\r\n")
        -- redirect first: "echo 0> f" would redirect handle 0 and leave f empty
        f:write('> "', win_tmp, '" echo %ERRORLEVEL%\r\n')
        f:write('move /y "', win_tmp, '" "', win_done, '" >nul\r\n')
        f:close()
        local f_vbs = io.open(VBS_PATH, "wb")
        if not f_vbs then return false end
        f_vbs:write("\xFF\xFE", M.utf16le('Set WshShell = CreateObject("WScript.Shell")\r\n'
            .. 'WScript.Quit WshShell.Run(Chr(34) & "' .. BAT_PATH:gsub("/", "\\") .. '" & Chr(34), 0, False)\r\n'))
        f_vbs:close()
        os.execute('wscript.exe "' .. VBS_PATH:gsub("/", "\\") .. '"')
    else
        os.execute('( ' .. cmd .. ' ; echo $? > ' .. shell_quote(done_tmp)
            .. ' ; mv -f ' .. shell_quote(done_tmp) .. ' ' .. shell_quote(done_path) .. ' ) >/dev/null 2>&1 &')
    end
    return true
end

-- One run at a time: runs share the tmp files and the .bat/.vbs launcher. `orphan` is
-- a helper that hadn't exited when its run was cancelled; nothing starts until its
-- done file appears.
local busy, orphan = false, false
-- The time the last run's stamp stands for, this session.
local last_stamp_time = nil

local function cleanup_tmp()
    -- cmd.exe may still be reading an orphan's .bat, so leave the files until it exits.
    if orphan then return end
    for _, p in ipairs({ MANIFEST_PATH, RESULTS_PATH, DONE_PATH, DONE_PATH .. ".tmp", BAT_PATH, VBS_PATH }) do
        pcall(os.remove, p)
    end
end

local function orphan_gone()
    if orphan and file_exists(DONE_PATH) then
        orphan = false
        cleanup_tmp()
    end
    return not orphan
end

local function cancelled(job)
    return M.cancel_requested or (job and not job.valid)
end

-- Ends a job once. Setting valid = false destroys darktable's progress object without
-- checking it still exists (src/lua/gui.c), so a second call would free it twice.
local function end_job(job)
    if job and job.valid then job.valid = false end
end

local function stop_job(job)
    M.cancel_requested = true
    end_job(job)
end

local function write_rows(path, rows)
    local f = io.open(path, "w")
    if not f then return false end
    for _, r in ipairs(rows) do f:write(C.csv_line(r), "\n") end
    f:close()
    return true
end

-- Runs exif_times.py and blocks until it exits. Returns the results text, or nil
-- plus "cancelled" or a reason the run falls back to whole seconds.
local function read_helper_times(records, job)
    local rows = M.manifest_rows(records)
    if #rows == 0 then return nil, "no frame has a capture time" end
    pcall(os.remove, RESULTS_PATH)
    pcall(os.remove, DONE_PATH)
    if not write_rows(MANIFEST_PATH, rows) then
        return nil, "couldn't write the image list to darktable's tmp folder"
    end
    local script = helper_script()
    local cmd = shell_quote(python_bin(script)) .. " -u " .. shell_quote(script) .. " "
        .. shell_quote(MANIFEST_PATH) .. " " .. shell_quote(RESULTS_PATH)
        .. " 2>> " .. shell_quote(LOG_PATH)
    log("running: " .. cmd)
    flush_log()
    if not run_async_command(cmd, DONE_PATH) then
        return nil, "couldn't start exif_times.py (no write access to darktable's tmp folder)"
    end
    local start = os.time()
    while true do
        if cancelled(job) then
            for _ = 1, 50 do
                if file_exists(DONE_PATH) then return nil, "cancelled" end
                dt.control.sleep(100)
            end
            orphan = true
            log("exif_times.py hasn't exited yet; the next run waits for it")
            return nil, "cancelled"
        end
        if file_exists(DONE_PATH) then
            local code = tonumber((read_file(DONE_PATH) or ""):match("%d+"))
            log("exif_times.py exit " .. tostring(code))
            if code ~= 0 then
                return nil, string.format("exif_times.py stopped with exit code %s (see assisted_grouping.log)", tostring(code or "?"))
            end
            local text = read_file(RESULTS_PATH)
            if not text then return nil, "exif_times.py wrote no results" end
            return text
        end
        if os.time() - start > HELPER_TIMEOUT_SECONDS then
            orphan = true
            return nil, string.format("exif_times.py didn't finish within %d minutes", HELPER_TIMEOUT_SECONDS // 60)
        end
        dt.control.sleep(150)
    end
end

local function read_ledger()
    return C.ledger_parse(read_file(LEDGER_PATH))
end

-- Writes the ledger of the tags and native groups this plugin made.
local function write_ledger(ledger)
    make_dir(LEDGER_DIR)
    local lf = io.open(LEDGER_PATH, "w")
    if lf then
        lf:write(C.ledger_format(ledger))
        lf:close()
    else
        log("couldn't write the ledger " .. LEDGER_PATH .. "; tags this run attached will count as yours next run")
    end
end

-- Syncs each image's group tags to `wanted`. Sets run.applying before the first write
-- and updates run.ledger per image, so the caller can save the ledger even when this
-- stops or errors partway.
local function apply_tags(run, records, wanted, job)
    local ledger = run.ledger
    local tag_objs, writes, failed, first_error = {}, 0, 0, nil
    local n_added, n_removed = 0, 0
    local function tag_named(name)
        tag_objs[name] = tag_objs[name] or tags.create(name)
        return tag_objs[name]
    end

    run.applying = true
    for i, plan in ipairs(M.plan_tag_changes(records, wanted, ledger)) do
        local r, mine = plan.record, plan.mine
        local okw, werr = pcall(function()
            for _, name in ipairs(plan.remove) do
                tags.detach(tag_named(name), r.img)
                mine[name] = nil
                n_removed = n_removed + 1
            end
            for _, name in ipairs(plan.add) do
                tags.attach(tag_named(name), r.img)
                mine[name] = true
                n_added = n_added + 1
            end
        end)
        M.set_ledger_tags(ledger, r.id, mine)
        if not okw then
            failed = failed + 1
            first_error = first_error or tostring(werr)
        end
        writes = writes + #plan.add + #plan.remove
        if writes >= WRITE_BUDGET then
            writes = 0
            dt.control.sleep(WRITE_SLEEP_MS)
        end
        if not job.valid then
            say(string.format("Assisted Grouping: stopped while writing tags; %d of %d images were updated. Run again to finish.",
                i, #records))
            return false
        end
    end
    log(string.format("tags: %d attached, %d detached", n_added, n_removed))    if failed > 0 then
        notify_error(string.format("Assisted Grouping: couldn't write tags on %d images: %s", failed, first_error))
    end
    return true
end

-- Writes one native group per final group of 2+ images, led by its lowest id.
-- Every image is detached into its own group before any attach: `group_with` on an
-- image still in an old group would scatter it. Updates the ledger per image, so a
-- partial failure still leaves it accurate.
function M.apply_native_groups(units, final_of, ledger)
    local img_of, members_of = {}, {}
    for _, unit in ipairs(units) do
        for _, m in ipairs(unit.members) do
            img_of[m.id] = m.img
            local list = {}
            for _, other in ipairs(m.img:get_group_members()) do
                list[#list + 1] = { id = tonumber(other.id), dir = other.path, filename = other.filename }
            end
            members_of[m.id] = list
        end
    end

    local plan = C.plan_native(units, final_of, ledger, members_of)
    local writes, failed, first_error, grouped = 0, 0, nil, 0
    local function write(fn)
        local okw, werr = pcall(fn)
        if not okw then
            failed = failed + 1
            first_error = first_error or tostring(werr)
        end
        writes = writes + 1
        if writes >= WRITE_BUDGET then
            writes = 0
            dt.control.sleep(WRITE_SLEEP_MS)
        end
        return okw
    end

    local detached = {}
    for _, id in ipairs(plan.detach) do
        -- No leader argument: darktable moves the image into a group of its own.
        if write(function() img_of[id]:group_with() end) then
            detached[id] = true
            M.set_ledger_native(ledger, id, nil)
        end
    end
    for _, group in ipairs(plan.groups) do
        local leader = group.leader
        if detached[leader] then
            local attached = 0
            for _, id in ipairs(group.members) do
                if id ~= leader and detached[id]
                    and write(function() img_of[id]:group_with(img_of[leader]) end) then
                    M.set_ledger_native(ledger, id, leader)
                    attached = attached + 1
                end
            end
            if attached > 0 then
                M.set_ledger_native(ledger, leader, leader)
                grouped = grouped + attached + 1
            end
        end
    end
    if failed > 0 then
        notify_error(string.format("Assisted Grouping: %d native group changes failed: %s", failed, first_error))
    end
    return { grouped = grouped, skipped = plan.skipped }
end

local function count_groups(group_of)
    local seen, n = {}, 0
    for _, g in pairs(group_of) do
        if not seen[g] then seen[g] = true; n = n + 1 end
    end
    return n
end

-- Units the parent layer couldn't split: no child under the parent, or several.
local function count_parent_unsplit(units, parent)
    local key_of, n = C.parent_key(parent), 0
    for _, unit in ipairs(units) do
        if key_of(unit) == nil then n = n + 1 end
    end
    return n
end

-- opts = { gap, camera, tag, parent, refine, write_tags, native_groups }
function M.group_images(images, opts)
    if busy then
        dt.print("Assisted Grouping: another job is still running. Wait for it to finish, or cancel it first.")
        return
    end
    if not orphan_gone() then
        dt.print("Assisted Grouping: the last run is still stopping. Try again in a moment.")
        return
    end
    if not opts.write_tags and not opts.native_groups then
        dt.print("Assisted Grouping: turn on at least one output (group tags or darktable groups)")
        return
    end
    if not images or #images == 0 then
        dt.print("Assisted Grouping: select some images first")
        return
    end
    local stamp
    stamp, last_stamp_time = M.run_stamp(os.time(), last_stamp_time)
    busy = true
    M.cancel_requested = false
    start_log(#images)
    log(string.format("run stamp %s; gap %s s, camera %s, tag %s, parent %s, refine %s, tags %s, native groups %s",
        stamp, tostring(opts.gap), tostring(opts.camera), tostring(opts.tag), tostring(opts.parent),
        tostring(opts.refine), tostring(opts.write_tags), tostring(opts.native_groups)))

    local job, run = nil, { ledger = nil, applying = false }
    local okr, err = pcall(function()
        job = dt.gui.create_job("Assisted Grouping", true, stop_job)
        job.percent = 0.0
        local records = M.build_images(images)

        local text, why = read_helper_times(records, job)
        flush_log()
        if why == "cancelled" then
            say("Assisted Grouping: cancelled, nothing was changed.")
            return
        end
        local precision, reason = "whole", why
        if text then precision, reason = M.apply_subsec(records, text) end
        if precision == "subsecond" then
            log("timing: sub-second")
        else
            log("timing: whole seconds for the whole run (" .. tostring(reason) .. ")")
        end
        job.percent = 0.5

        local units = C.collapse(records)
        local layer_opts = { gap = opts.gap, camera = opts.camera, tag = opts.tag, parent = opts.parent }
        if opts.refine then layer_opts.base_of = C.base_of_from_tags(units) end
        local result = C.run_layers(units, layer_opts)
        local wanted = C.wanted_tags(units, result, stamp, layer_opts)
        log(string.format("%d frames in %d groups (%d bursts)", #units, count_groups(result.final_of),
            count_groups(result.burst_of)))
        if opts.parent then
            log(string.format("parent layer: %d frames have no child or several under %s, not split",
                count_parent_unsplit(units, opts.parent), opts.parent))
        end

        -- Groups need the whole selection, so a cancelled run writes nothing.
        if cancelled(job) then
            say("Assisted Grouping: cancelled, nothing was changed.")
            return
        end
        run.ledger = read_ledger()
        if opts.write_tags then
            if not apply_tags(run, records, wanted, job) then return end
        end
        if opts.native_groups then
            run.applying = true
            local counts = M.apply_native_groups(units, result.final_of, run.ledger)
            log(string.format("native groups: %d images grouped, %d skipped (already in a hand-made group)",
                counts.grouped, counts.skipped))
        end
        say(string.format("Assisted Grouping: %d images in %d groups (%s timing). Run %s.",
            #records, count_groups(result.final_of), precision == "subsecond" and "sub-second" or "whole-second", stamp))
    end)

    -- Saved once anything may have changed, even if the apply stopped or errored partway,
    -- so what this run made isn't mistaken for the user's next time.
    if run.applying then write_ledger(run.ledger) end
    end_job(job)
    busy = false
    if not okr then notify_error("Assisted Grouping: couldn't run. " .. tostring(err)) end
    cleanup_tmp()
    log("run finished")
    flush_log()
end

return M

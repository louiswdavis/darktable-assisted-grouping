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
-- darktable image the tags are written to. `with_tags` false leaves `tags` empty
-- (one darktable query per image saved) for runs that read and write no tags.
function M.build_images(images, with_tags)
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
            tags = with_tags == false and {} or M.tags_of(img),
        }
    end
    return out
end

-- Tags feed the tag, parent and Refine layers and the tag writer; nothing else.
function M.needs_tags(opts)
    return (opts.tag or opts.parent or opts.refine or opts.write_tags) and true or false
end

-- Units whose capture time the burst layer uses: timing on, a capture time, and
-- no group from Refine's base_of. Frames darktable has no capture time for are
-- their own group whatever the helper reads.
function M.units_to_time(units, timing, base_of)
    local out = {}
    if timing == false then return out end
    for _, unit in ipairs(units) do
        if unit.epoch and not (base_of and base_of[unit.id]) then out[#out + 1] = unit end
    end
    return out
end

-- How many units carry `tag` (the tag layer's "has" side).
function M.count_tagged(units, tag)
    local n = 0
    for _, unit in ipairs(units) do
        if unit.tags and unit.tags[tag] then n = n + 1 end
    end
    return n
end

-- Every member of `units`, the records apply_subsec works on.
function M.members_of(units)
    local out = {}
    for _, unit in ipairs(units) do
        for _, m in ipairs(unit.members or { unit }) do out[#out + 1] = m end
    end
    return out
end

local function is_jpeg(r)
    local ext = ((r.filename or ""):match("%.([^./\\]+)$") or ""):lower()
    return ext == "jpg" or ext == "jpeg"
end

-- `id,path` rows for exif_times.py, one per unit: its JPEG when it has a dated one
-- (a fast Pillow read), else its lowest-id dated member. The unit's other members
-- borrow that fraction (grouping_core.subsec_fractions), so a RAW+JPEG pair costs one read.
function M.manifest_rows(units)
    local rows = {}
    for _, unit in ipairs(units) do
        local pick
        for _, m in ipairs(unit.members or { unit }) do
            if m.epoch and (pick == nil or (is_jpeg(m) and not is_jpeg(pick))) then pick = m end
        end
        if pick then rows[#rows + 1] = { pick.id, pick.file } end
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
-- when every timed frame has a fraction (its own, or borrowed from the JPEG of its
-- RAW+JPEG pair, see grouping_core.subsec_fractions) and the helper says
-- `subsecond`. Only the fraction is taken: the helper's whole part (timegm) and
-- the core's (os.time) can differ by the local offset. `records` are the members
-- of the timed units (members_of). Returns "subsecond" or "whole" and, for
-- "whole", why.
function M.apply_subsec(records, text)
    local any_timed = false
    for _, r in ipairs(records) do
        if r.epoch then any_timed = true; break end
    end
    if not any_timed then return "whole", "no frame has a capture time" end
    local by_id, precision = M.parse_helper_results(text)
    if precision ~= "subsecond" then
        return "whole", "the helper reported whole-second precision"
    end
    local frac_of, missing = C.subsec_fractions(records, by_id)
    if missing then
        return "whole", string.format("image %d has no readable sub-second time", missing)
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

-- Writes `text` to `path`.tmp, then moves it onto `path`, so a failed or cut-short
-- write leaves the old file. os.rename won't replace a file on Windows, so on a
-- failed rename the old file is removed and the rename retried; a crash in that gap
-- leaves only `path`.tmp, which read_file_or_tmp falls back to. Returns true, or nil and why.
function M.write_file_atomic(path, text)
    local tmp = path .. ".tmp"
    local f, oerr = io.open(tmp, "w")
    if not f then return nil, oerr end
    local okw, werr = f:write(text)
    local okc, cerr = f:close()
    if not okw or not okc then
        pcall(os.remove, tmp)
        return nil, werr or cerr
    end
    local okr, rerr = os.rename(tmp, path)
    if not okr then
        os.remove(path)
        okr, rerr = os.rename(tmp, path)
    end
    if not okr then return nil, rerr end
    return true
end

-- `path`'s text, or `path`.tmp's when `path` is missing (see write_file_atomic).
function M.read_file_or_tmp(path)
    for _, p in ipairs({ path, path .. ".tmp" }) do
        local f = io.open(p, "r")
        if f then
            local t = f:read("a")
            f:close()
            return t
        end
    end
    return nil
end

-- python.exe → the pythonw.exe beside it (venvs and python.org installs ship both),
-- which opens no console window. nil for any other name.
function M.pythonw_of(py)
    local dir, name = py:match("^(.-)([^/\\]*)$")
    name = name:lower()
    if name == "python.exe" then return dir .. "pythonw.exe" end
    if name == "python" then return dir .. "pythonw" end
    return nil
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
local LOG_PATH = dt.configuration.config_dir .. "/assisted_grouping.log"
local PREV_LOG_PATH = dt.configuration.config_dir .. "/assisted_grouping.prev.log"
local LEDGER_DIR = dt.configuration.config_dir .. "/assisted_grouping"
local LEDGER_PATH = LEDGER_DIR .. "/ledger.csv"

if dt.gui then
    dt.preferences.register("assisted_grouping", "python_bin", "file",
        "Assisted Grouping: Python interpreter",
        "Python executable with Pillow and exifread installed (python/requirements.txt, e.g. .venv\\Scripts\\python.exe). Empty = auto-detect the repo's .venv",
        "")
    dt.preferences.register("assisted_grouping", "plugin_folder", "directory",
        "Assisted Grouping: plugin folder",
        "The darktable-assisted-grouping folder (holds python/ and .venv). Empty = auto-detect",
        "")
    -- A string, not an integer like the sibling plugins' gap: decimals are allowed.
    dt.preferences.register("assisted_grouping", "burst_gap_seconds", "string",
        "Assisted Grouping: burst gap (seconds)",
        "Photos taken closer together than this are one burst. Decimals are allowed (e.g. 0.5 or 1,5); the default is 2",
        "2")
end

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

-- Log lines wait here and reach the file at flush_log.
local log_buffer = {}

local function log(msg)
    log_buffer[#log_buffer + 1] = os.date("%H:%M:%S ") .. "lua: " .. msg
end

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

-- `what` names the job in the header: "group" or "clear".
local function start_log(what, n)
    flush_log()
    pcall(os.remove, PREV_LOG_PATH)
    pcall(os.rename, LOG_PATH, PREV_LOG_PATH)
    log(string.format("%s started: darktable %s, %d images", what, tostring(dt.configuration.version), n))
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

-- "py -u argv..." quoted for the shell: the log line, and the launch off Windows.
local function command_line(py, argv)
    local parts = { shell_quote(py), "-u" }
    for _, a in ipairs(argv) do parts[#parts + 1] = shell_quote(a) end
    return table.concat(parts, " ")
end

-- Starts `py -u argv...` without waiting, stderr to err_path (appended when `append`).
-- The exit code goes to a temp file renamed onto done_path, so done_path never exists
-- without its code in it. On Windows python/launch.py runs it under pythonw.exe: no
-- console window, no script host, nothing executable written to tmp (antivirus
-- behaviour checks flag a hidden .vbs/.bat chain). Returns false plus why it didn't start.
local function run_async_python(py, argv, err_path, append, done_path)
    if IS_WINDOWS then
        local pyw = M.pythonw_of(py)
        if not pyw then return false, "the Python preference must point at a python.exe" end
        if pyw:find("[/\\]") and not file_exists(pyw) then return false, pyw .. " is missing" end
        local job = done_path .. ".job"
        local f = io.open(job, "w")
        if not f then return false, "no write access to darktable's tmp folder" end
        f:write(done_path, "\n", err_path, "\n", append and "a" or "w", "\n", table.concat(argv, "\n"), "\n")
        f:close()
        local launcher = (argv[1]:match("^(.*)[/\\]") or ".") .. "/launch.py"
        local ok = os.execute('start "" /B ' .. shell_quote((pyw:gsub("/", "\\")))
            .. " " .. shell_quote((launcher:gsub("/", "\\"))) .. " " .. shell_quote((job:gsub("/", "\\"))))
        if not ok then
            pcall(os.remove, job)
            return false, pyw .. " didn't start"
        end
        return true
    end
    local done_tmp = done_path .. ".tmp"
    os.execute('( ' .. command_line(py, argv) .. (append and " 2>> " or " 2> ") .. shell_quote(err_path)
        .. ' ; echo $? > ' .. shell_quote(done_tmp)
        .. ' ; mv -f ' .. shell_quote(done_tmp) .. ' ' .. shell_quote(done_path) .. ' ) >/dev/null 2>&1 &')
    return true
end

-- One run at a time.
local busy = false
-- The time the last run's stamp stands for, this session.
local last_stamp_time = nil
-- Jobs clicked while another runs: { label, run }, oldest first.
local queue = {}

-- A helper call's temp files. Each call gets its own names, so a helper still
-- running after its run was cancelled or timed out can't touch the next run's files.
local run_seq = 0
local function new_run_paths()
    run_seq = run_seq + 1
    local base = string.format("%s/dt_assisted_grouping_%d_%d_", TMP_DIR, os.time(), run_seq)
    return { manifest = base .. "manifest.csv", results = base .. "results.csv",
        stderr = base .. "stderr.txt", done = base .. "done.txt" }
end

-- Only once the helper has exited: it still reads the manifest and writes its results.
local function remove_run_files(p)
    for _, f in ipairs({ p.manifest, p.results, p.stderr, p.done, p.done .. ".tmp", p.done .. ".job" }) do
        pcall(os.remove, f)
    end
end

-- Copies the helper's stderr into the log. The helper writes it to its own temp
-- file, so a straggler never holds the log open (Windows then can't rotate it).
local function log_helper_stderr(p)
    local text = read_file(p.stderr)
    for line in (text or ""):gmatch("[^\r\n]+") do log_buffer[#log_buffer + 1] = line end
end

local function cancelled(job)
    return M.cancel_requested or (job and not job.valid)
end

-- Ends a job once. Setting valid = false destroys darktable's progress object without
-- checking it still exists (src/lua/gui.c), so a second call would free it twice.
local function end_job(job)
    if job and job.valid then job.valid = false end
end

-- Drops every queued job; a cancel means "stop what I started", not "run the rest".
local function clear_queue()
    if #queue == 0 then return end
    dt.print(string.format("Assisted Grouping: %d queued jobs dropped.", #queue))
    queue = {}
end

local function stop_job(job)
    M.cancel_requested = true
    clear_queue()
    end_job(job)
end

-- While a job runs, remembers `run` to start when it finishes and returns true. Returns
-- false (do nothing) when nothing is running or there is nothing to queue (`has_input`
-- false), so the caller's normal checks print their own message.
local function queue_if_busy(label, has_input, run)
    if not busy or not has_input then return false end
    queue[#queue + 1] = { label = label, run = run }
    dt.print(string.format("Assisted Grouping: %s queued (%d waiting); it starts when the current job finishes.",
        label, #queue))
    return true
end

-- Starts the oldest queued job. Called by every job as it finishes, after busy is cleared.
local function run_next()
    if busy or #queue == 0 then return end
    local nxt = table.remove(queue, 1)
    log("starting queued job: " .. nxt.label)
    nxt.run()
end

local function write_rows(path, rows)
    local f = io.open(path, "w")
    if not f then return false end
    for _, r in ipairs(rows) do f:write(C.csv_line(r), "\n") end
    f:close()
    return true
end

-- Runs exif_times.py on one file per unit and blocks until it exits. Returns the
-- results text, or nil plus "cancelled" or a reason the run falls back to whole
-- seconds. A helper still running at a cancel or the timeout keeps its temp files;
-- the next run uses new names, so it needn't wait.
local function read_helper_times(units, job)
    local rows = M.manifest_rows(units)
    if #rows == 0 then return nil, "no frame has a capture time" end
    local p = new_run_paths()
    if not write_rows(p.manifest, rows) then
        return nil, "couldn't write the image list to darktable's tmp folder"
    end
    local script = helper_script()
    local py, argv = python_bin(script), { script, p.manifest, p.results }
    log(string.format("running (%d files): %s", #rows, command_line(py, argv)))
    flush_log()
    local launched, why = run_async_python(py, argv, p.stderr, false, p.done)
    if not launched then
        return nil, "couldn't start exif_times.py: " .. why
    end
    local start = os.time()
    while true do
        if file_exists(p.done) then
            local code = tonumber((read_file(p.done) or ""):match("%d+"))
            log_helper_stderr(p)
            log("exif_times.py exit " .. tostring(code))
            local text = read_file(p.results)
            remove_run_files(p)
            if cancelled(job) then return nil, "cancelled" end
            if code ~= 0 then
                return nil, string.format("exif_times.py stopped with exit code %s (see assisted_grouping.log)", tostring(code or "?"))
            end
            if not text then return nil, "exif_times.py wrote no results" end
            return text
        end
        if cancelled(job) then
            log("exif_times.py is still running; its temp files stay in darktable's tmp folder (" .. p.done .. ")")
            return nil, "cancelled"
        end
        if os.time() - start > HELPER_TIMEOUT_SECONDS then
            log("exif_times.py is still running; its temp files stay in darktable's tmp folder (" .. p.done .. ")")
            return nil, string.format("exif_times.py didn't finish within %d minutes", HELPER_TIMEOUT_SECONDS // 60)
        end
        dt.control.sleep(150)
    end
end

local function read_ledger()
    return C.ledger_parse(M.read_file_or_tmp(LEDGER_PATH))
end

-- Writes the ledger of the tags and native groups this plugin made.
local function write_ledger(ledger)
    make_dir(LEDGER_DIR)
    local ok_w, err = M.write_file_atomic(LEDGER_PATH, C.ledger_format(ledger))
    if not ok_w then
        notify_error(string.format("Assisted Grouping: couldn't save the ledger %s (%s). Tags and groups this run made will count as yours next run.",
            LEDGER_PATH, tostring(err)))
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
    log(string.format("tags: %d attached, %d detached", n_added, n_removed))
    if failed > 0 then
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

-- opts = { timing, gap, camera, tag, parent, refine, write_tags, native_groups }, as
-- grouping_core.panel_options returns them.
function M.group_images(images, opts)
    if busy then
        dt.print("Assisted Grouping: another job is still running. Wait for it to finish, or cancel it first.")
        return
    end
    if not opts.write_tags and not opts.native_groups then
        dt.print("Assisted Grouping: " .. C.ERR_NO_OUTPUT)
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
    start_log("group", #images)
    log(string.format("run stamp %s; timing %s, gap %s s, camera %s, tag %s, parent %s, refine %s, tags %s, native groups %s",
        stamp, tostring(opts.timing ~= false), tostring(opts.gap), tostring(opts.camera), tostring(opts.tag), tostring(opts.parent),
        tostring(opts.refine), tostring(opts.write_tags), tostring(opts.native_groups)))

    local job, run = nil, { ledger = nil, applying = false }
    local okr, err = pcall(function()
        job = dt.gui.create_job("Assisted Grouping", true, stop_job)
        job.percent = 0.0
        local records = M.build_images(images, M.needs_tags(opts))
        local units = C.collapse(records)
        local layer_opts = { gap = opts.gap, timing = opts.timing, camera = opts.camera, tag = opts.tag,
            parent = opts.parent }
        if opts.refine then layer_opts.base_of = C.base_of_from_tags(units) end

        -- Only frames the burst layer times need the helper.
        local to_time = M.units_to_time(units, opts.timing, layer_opts.base_of)
        local precision = "whole"
        if opts.timing == false then
            log("timing: off, capture times not read")
        elseif #to_time == 0 then
            log("timing: not needed (every frame has a group tag or no capture time)")
        else
            local text, why = read_helper_times(to_time, job)
            flush_log()
            if why == "cancelled" then
                say("Assisted Grouping: cancelled, nothing was changed.")
                return
            end
            local reason = why
            if text then precision, reason = M.apply_subsec(M.members_of(to_time), text) end
            if precision == "subsecond" then
                log("timing: sub-second")
                units = C.collapse(records) -- unit epochs are copied from members at collapse
            else
                log("timing: whole seconds for the whole run (" .. tostring(reason) .. ")")
            end
        end
        job.percent = 0.5

        local result = C.run_layers(units, layer_opts)
        local wanted = C.wanted_tags(units, result, stamp, layer_opts)
        log(string.format("%d frames in %d groups (%d %s)", #units, count_groups(result.final_of),
            count_groups(result.burst_of), result.timing and "bursts" or "starting groups, timing off"))
        if opts.parent then
            log(string.format("parent layer: %d frames have no child or several under %s, not split",
                count_parent_unsplit(units, opts.parent), opts.parent))
        end
        local note = ""
        if opts.tag then
            local n_has = M.count_tagged(units, opts.tag)
            log(string.format("tag layer: %d of %d frames have %s", n_has, #units, opts.tag))
            if n_has == 0 then
                note = string.format(" No selected photo has the tag %s, so it split nothing; check its spelling and spaces.", opts.tag)
            end
        end
        local timing_label = opts.timing == false and "timing off"
            or #to_time == 0 and "no timing needed"
            or precision == "subsecond" and "sub-second timing" or "whole-second timing"

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
            -- Cancel is ignored from here on: half-built native groups are worse than finishing.
            log("native groups: started; a cancel from now on is ignored so no group is left half-built")
            local counts = M.apply_native_groups(units, result.final_of, run.ledger)
            log(string.format("native groups: %d images grouped, %d skipped (already in a hand-made group)",
                counts.grouped, counts.skipped))
        end
        say(string.format("Assisted Grouping: %d images in %d groups (%s). Run %s.%s",
            #records, count_groups(result.final_of), timing_label, stamp, note))
    end)

    -- Saved once anything may have changed, even if the apply stopped or errored partway,
    -- so what this run made isn't mistaken for the user's next time.
    if run.applying then write_ledger(run.ledger) end
    end_job(job)
    busy = false
    if not okr then notify_error("Assisted Grouping: couldn't run. " .. tostring(err)) end
    log("run finished")
    flush_log()
    run_next()
end

-- Detaches the ledger's tags and takes images out of the ledger's native groups for
-- the selection, then drops their ledger rows. Hand-made tags and groups stay. A
-- write that fails keeps its part of the row, so clearing again retries it.
function M.clear_marks(images)
    if busy then
        dt.print("Assisted Grouping: another job is still running. Wait for it to finish, or cancel it first.")
        return
    end
    if not images or #images == 0 then
        dt.print("Assisted Grouping: select some images first")
        return
    end
    busy = true
    start_log("clear", #images)
    local ledger, changed = nil, false
    local okr, err = pcall(function()
        ledger = read_ledger()
        local records, members_of = {}, {}
        for _, img in ipairs(images) do
            local id = tonumber(img.id)
            if ledger[id] then
                records[#records + 1] = { id = id, img = img, tags = M.tags_of(img), dir = img.path, filename = img.filename }
                local list = {}
                for _, other in ipairs(img:get_group_members()) do list[#list + 1] = { id = tonumber(other.id) } end
                members_of[id] = list
            end
        end
        if #records == 0 then
            say("Assisted Grouping: nothing to clear; the selection has no grouping marks.")
            return
        end

        local img_of = {}
        for _, r in ipairs(records) do img_of[r.id] = r.img end
        local writes, failed, first_error, n_tags, n_ungrouped = 0, 0, nil, 0, 0
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

        changed = true
        local plans, restore = C.plan_clear(records, ledger, members_of)
        local ungrouped = {}
        for _, plan in ipairs(plans) do
            local entry, img = ledger[plan.id], img_of[plan.id]
            local left = {}
            for _, name in ipairs(plan.detach) do
                local tag = tags.find(name)
                if tag and write(function() tags.detach(tag, img) end) then
                    n_tags = n_tags + 1
                elseif tag then
                    left[name] = true
                end
            end
            local native = nil
            if plan.ungroup then
                -- No leader argument: darktable moves the image into a group of its own.
                if write(function() img:group_with() end) then
                    n_ungrouped = n_ungrouped + 1
                    ungrouped[plan.id] = true
                else
                    native = entry.native
                end
            end
            M.set_ledger_tags(ledger, plan.id, left)
            M.set_ledger_native(ledger, plan.id, native)
        end
        -- Every image above was detached into a group of its own before any attach here,
        -- so re-forming a frame's group can't pull a leader out of another group.
        -- These are darktable's import groups, not the plugin's, so the ledger skips them.
        local n_restored = 0
        for _, group in ipairs(restore) do
            local ok_ids = {}
            for _, id in ipairs(group.members) do
                if ungrouped[id] then ok_ids[#ok_ids + 1] = id end
            end
            if #ok_ids >= 2 then
                local leader = img_of[ok_ids[1]]
                for i = 2, #ok_ids do
                    write(function() img_of[ok_ids[i]]:group_with(leader) end)
                end
                n_restored = n_restored + 1
            end
        end
        log(string.format("clear: %d images, %d tags detached, %d taken out of native groups, %d frame groups restored, %d failed",
            #records, n_tags, n_ungrouped, n_restored, failed))
        if failed > 0 then
            notify_error(string.format("Assisted Grouping: couldn't clear %d marks: %s", failed, first_error))
        end
        say(string.format("Assisted Grouping: cleared grouping marks from %d images.", #records))
    end)

    if changed then write_ledger(ledger) end
    busy = false
    if not okr then notify_error("Assisted Grouping: clearing marks failed. " .. tostring(err)) end
    flush_log()
    run_next()
end

-- Panel -----------------------------------------------------------------------

-- dt.gui.action_images changes with the selection; queued jobs keep the images they were
-- clicked with.
local function copy_images(images)
    local out = {}
    for _, img in ipairs(images or {}) do out[#out + 1] = img end
    return out
end

-- Culling's partial-burst warning. GTK labels here don't wrap, so the lines are broken by hand.
local PARTIAL_BURST_WARNING = "Bursts are grouped from the selected\nframes only, so selecting part of a\n"
    .. "burst splits it. Select whole bursts,\nor the whole shoot."

local function install_panel()
    if M.module_installed then return end
    M.module_installed = true

    local timing_check = dt.new_widget("check_button") {
        label = "Burst timing",
        tooltip = "Start a new group when the gap to the previous photo is longer than the burst gap (preferences → Lua options, default 2 seconds, decimals allowed).",
        value = true,
    }
    local camera_check = dt.new_widget("check_button") {
        label = "Camera and lens",
        tooltip = "Divide each group by camera maker, model and lens.",
        value = false,
    }
    local tag_entry = dt.new_widget("entry") {
        tooltip = "Divide each group into photos that carry exactly this tag and photos that don't (child tags don't count). Empty = off.",
        placeholder = "tag, e.g. Cars|Red",
        text = "",
    }
    local parent_entry = dt.new_widget("entry") {
        tooltip = "Divide each group by which tag directly under this node a photo carries. Photos with none, or several, aren't split by it (the log counts them). Empty = off.",
        placeholder = "parent tag, e.g. Cars|Number",
        text = "",
    }
    local refine_check = dt.new_widget("check_button") {
        label = "Refine existing groups",
        tooltip = "Start from each photo's group tag from the latest earlier run instead of burst timing; photos without one are timed among themselves (or share one group when Burst timing is off). The other layers then divide as usual.",
        value = false,
    }
    local native_check = dt.new_widget("check_button") {
        label = "Apply darktable groups",
        tooltip = "Default, quick output. Make one darktable group per final group of two or more photos. Photos already in a group you made by hand are skipped. Once this step starts, cancel is ignored so no group is left half-built.",
        value = true,
    }
    local tags_check = dt.new_widget("check_button") {
        label = "Write group tags",
        tooltip = "Tag each photo under Assisted Grouping|<run time>|... with its group and each layer's result. Adds time on a large selection.",
        value = false,
    }

    local function read_options()
        return C.panel_options({
            timing = timing_check.value,
            gap_text = dt.preferences.read("assisted_grouping", "burst_gap_seconds", "string"),
            camera = camera_check.value,
            tag = tag_entry.text,
            parent = parent_entry.text,
            refine = refine_check.value,
            write_tags = tags_check.value,
            native_groups = native_check.value,
        })
    end

    local group_button = dt.new_widget("button") {
        label = "Group selection",
        tooltip = "Group the selected photos by the layers above. Cancel from the progress bar: before anything is written it changes nothing, while tags are being written it stops partway (partial tags stay), and once darktable groups have started it is ignored.",
        clicked_callback = function()
            local opts, why = read_options()
            if not opts then
                dt.print("Assisted Grouping: " .. why)
                return
            end
            local images = copy_images(dt.gui.action_images)
            if queue_if_busy("Group selection", #images > 0, function() M.group_images(images, opts) end) then return end
            M.group_images(images, opts)
        end,
    }
    local warning_label = dt.new_widget("label") {
        label = PARTIAL_BURST_WARNING,
        halign = "start",
    }
    local clear_button = dt.new_widget("button") {
        label = "Clear grouping marks",
        tooltip = "Remove the group tags and darktable groups this plugin made from the selected photos. Tags and groups you made by hand stay.",
        clicked_callback = function()
            local images = copy_images(dt.gui.action_images)
            if queue_if_busy("Clear grouping marks", #images > 0, function() M.clear_marks(images) end) then return end
            M.clear_marks(images)
        end,
    }

    local panel_box = dt.new_widget("box") {
        orientation = "vertical",
        dt.new_widget("section_label") { label = "layers" },
        timing_check,
        camera_check,
        tag_entry,
        parent_entry,
        refine_check,
        dt.new_widget("section_label") { label = "output" },
        native_check,
        tags_check,
        group_button,
        warning_label,
        clear_button,
    }

    dt.register_lib(
        "assisted_grouping", "Assisted Grouping", true, true,
        { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100 } },
        panel_box
    )
end

local function destroy()
    if dt.gui.libs["assisted_grouping"] then
        dt.gui.libs["assisted_grouping"].visible = false
    end
end

local function restart()
    if dt.gui.libs["assisted_grouping"] then
        dt.gui.libs["assisted_grouping"].visible = true
    end
end

M.destroy = destroy
M.restart = restart
M.destroy_method = "hide"
M.show = restart
M.metadata = {
    name = "Assisted Grouping",
    purpose = "Group a selection into bursts, optionally divided by camera, tag and parent tag",
    author = "Custom Script",
    help = ""
}

if dt.gui then
    if dt.gui.current_view().id == "lighttable" then
        install_panel()
        restart()
    else
        if not M.event_registered then
            dt.register_event("assisted_grouping", "view-changed", function(event, old_view, new_view)
                if new_view.name == "lighttable" or new_view.id == "lighttable" then
                    install_panel()
                    restart()
                end
            end)
            M.event_registered = true
        end
    end
end

return M

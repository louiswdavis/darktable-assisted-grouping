-- Run with: lua test_assisted_gui.lua
-- Runs the darktable half of assisted_grouping.lua for real: the panel is built and its buttons
-- are clicked. Only the edges are faked: the darktable API (tags and groups held in memory), the
-- plugin folder (empty files) and the exif_times.py process (os.execute), which answers from PYTHON below.

package.path = package.path .. ";./?.lua"

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %s", name))
    end
end

local WINDOWS = package.config:sub(1, 1) == "\\"
local real_execute = os.execute

local function make_dir(dir)
    real_execute(WINDOWS and ('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul') or ("mkdir -p '" .. dir .. "'"))
end

local function write_file(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end

-- Folders -------------------------------------------------------------------------
local ROOT = ((os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/"):gsub("/$", ""))
    .. "/ag_gui_test_" .. os.time() .. "_" .. math.random(100000, 999999)
local PLUGIN = ROOT .. "/plugins/darktable-assisted-grouping"
for _, dir in ipairs({ "/tmp", "/config", "/plugins/darktable-assisted-grouping/python",
    "/plugins/darktable-assisted-grouping/.venv/Scripts", "/plugins/darktable-assisted-grouping/.venv/bin" }) do
    make_dir(ROOT .. dir)
end
for _, file in ipairs({ "/python/exif_times.py", "/python/launch.py", "/.venv/Scripts/python.exe",
    "/.venv/Scripts/pythonw.exe", "/.venv/bin/python" }) do
    write_file(PLUGIN .. file, "")
end

-- exif_times.py -------------------------------------------------------------------
-- What the fake process writes, and what it was last asked.
local PYTHON = { results = "", exit = 0, runs = {} }

-- The launch as plugin_common.run_async_python writes it: a job file on Windows, a shell line elsewhere.
os.execute = function(cmd)
    if not cmd or not cmd:find("exif_times.py", 1, true) and not cmd:find("launch.py", 1, true) then return real_execute(cmd) end
    local argv, done_path = {}, nil
    if WINDOWS then
        local job
        for quoted in cmd:gmatch('"([^"]*)"') do job = quoted end
        local lines = {}
        for line in (read_file(job) or ""):gmatch("[^\r\n]+") do lines[#lines + 1] = line end
        done_path = lines[1]
        for i = 4, #lines do argv[#argv + 1] = lines[i] end
    else
        local tokens = {}
        for quoted in cmd:gmatch("'([^']*)'") do tokens[#tokens + 1] = quoted end
        done_path = tokens[#tokens]
        for i = 2, #tokens - 4 do argv[#argv + 1] = tokens[i] end
    end
    PYTHON.runs[#PYTHON.runs + 1] = { argv = argv, manifest = read_file(argv[2]) }
    write_file(argv[3], PYTHON.results)
    write_file(done_path, PYTHON.exit .. "\n")
    return true
end

-- darktable -----------------------------------------------------------------------
local prints, jobs, images_by_id, tags_by_name, panel = {}, {}, {}, {}, nil
local prefs = { ["assisted_plugins/plugins_root"] = ROOT .. "/plugins" }
local PREF_EMPTY = { string = "", directory = "", file = "", integer = 0, float = 0, bool = false }
local group_error = nil -- set to make every darktable group change fail
local group_writes = 0

local dt = {
    configuration = { tmp_dir = ROOT .. "/tmp", config_dir = ROOT .. "/config", version = "test", running_os = WINDOWS and "windows" or "macos" },
    gettext = { gettext = function(msgid) return msgid end },
    preferences = {
        register = function() end,
        read = function(group, name, kind)
            local value = prefs[group .. "/" .. name]
            if value == nil then return PREF_EMPTY[kind] end
            return value
        end,
        write = function(group, name, _kind, value) prefs[group .. "/" .. name] = value end,
    },
    print = function(msg) prints[#prints + 1] = msg end,
    print_error = function() end,
    print_hinter = function() error("print_hinter crashes darktable 5.6 when called often") end,
    tags = {
        get_tags = function(img) return img.tags end,
        find = function(name) return tags_by_name[name] end,
        create = function(name)
            tags_by_name[name] = tags_by_name[name] or { name = name }
            return tags_by_name[name]
        end,
        attach = function(tag, img)
            for _, have in ipairs(img.tags) do
                if have == tag then return end
            end
            img.tags[#img.tags + 1] = tag
        end,
        detach = function(tag, img)
            for i, have in ipairs(img.tags) do
                if have == tag then table.remove(img.tags, i); return end
            end
        end,
    },
    control = { sleep = function() end, dispatch = function(fn) fn() end },
    database = { get_image = function(id) return images_by_id[id] end },
    register_event = function() end,
    destroy_event = function() end,
    register_lib = function(...) panel = select(select("#", ...), ...) end,
    -- a widget is its own property table: children in the array part, values as fields
    new_widget = function(kind)
        return function(props)
            props.kind = kind
            return props
        end
    end,
    gui = {
        libs = {},
        views = { lighttable = {} },
        selection = function() return {} end,
        action_images = {},
        current_view = function() return { id = "lighttable" } end,
        create_job = function(title)
            local job = { valid = true, percent = 0, title = title }
            jobs[#jobs + 1] = job
            return job
        end,
    },
}
package.loaded["darktable"] = dt
package.loaded["lib/dtutils"] = { check_min_api_version = function() end }
package.loaded["lib/dtutils.file"] = {
    check_if_bin_exists = function() return false end,
    test_file = function(path) return os.rename(path, path) and true or false end,
}

-- An image as darktable hands it over; `group` is the id of its group leader.
local function image(id, filename, taken)
    local img = { id = id, filename = filename, path = "/photos", exif_datetime_taken = taken,
        exif_maker = "Sony", exif_model = "A1", exif_lens = "70-200", tags = {}, group = id }
    function img:get_group_members()
        local members = {}
        for other_id = 1, #images_by_id do
            if images_by_id[other_id].group == self.group then members[#members + 1] = images_by_id[other_id] end
        end
        return members
    end
    -- As in darktable: taking a leader out hands its group to the next member and rewrites
    -- every image left in it. `group_writes` counts the images darktable rewrites.
    function img:group_with(leader)
        if group_error then error(group_error, 0) end
        group_writes = group_writes + 1
        if self.group == self.id then
            local new_leader = nil
            for other_id = 1, #images_by_id do
                local other = images_by_id[other_id]
                if other ~= self and other.group == self.id then
                    new_leader = new_leader or other.id
                    other.group = new_leader
                    group_writes = group_writes + 1
                end
            end
        end
        self.group = leader and leader.group or self.id
    end
    images_by_id[id] = img
    return setmetatable(img, { __index = function(self, key)
        if key == "group_leader" then return images_by_id[self.group] end
    end })
end

local function printed(text)
    for _, msg in ipairs(prints) do
        if msg:find(text, 1, true) then return true end
    end
    return false
end

local function last_print()
    return prints[#prints] or ""
end

local function button(widget, label)
    if type(widget) ~= "table" then return nil end
    if widget.kind == "button" and widget.label == label then return widget end
    for _, child in ipairs(widget) do
        local found = button(child, label)
        if found then return found end
    end
    return nil
end

-- The selected images are read at the click, as in darktable.
local function click(label, images)
    prints, jobs, PYTHON.runs = {}, {}, {}
    dt.gui.action_images = images
    button(panel, label).clicked_callback()
end

local function group_tag_count(img)
    local n = 0
    for _, tag in ipairs(img.tags) do
        if tag.name:find("^Assisted Grouping|") then n = n + 1 end
    end
    return n
end

local function lua_errors()
    return read_file(ROOT .. "/config/assisted_grouping.lua.log")
end

-- Startup -------------------------------------------------------------------------
local G = require("assisted_grouping")
check("the panel is installed at startup", panel ~= nil, true)
check("startup has no Lua error", lua_errors(), nil)

-- Two frames in one second, one 30 s later, and the first frame's RAW.
local jpeg1 = image(1, "DSC00001.JPG", "2026:05:01 10:00:00")
local jpeg2 = image(2, "DSC00002.JPG", "2026:05:01 10:00:00")
local jpeg3 = image(3, "DSC00003.JPG", "2026:05:01 10:00:30")
local raw1 = image(4, "DSC00001.ARW", "2026:05:01 10:00:00")
local all = { jpeg1, jpeg2, jpeg3, raw1 }
local epoch = G.exif_time_to_epoch("2026:05:01 10:00:00")
PYTHON.results = string.format("1,%d.10\n2,%d.60\n3,%d.00\n#precision,subsecond\n", epoch, epoch, epoch + 30)

-- Group selection -------------------------------------------------------------------
click("Group selection", {})
check("group, nothing selected: asks for a selection", last_print(), "Assisted Grouping: select some images first")
check("group, nothing selected: no job bar", #jobs, 0)

click("Group selection", all)
check("group: says it started as soon as it is clicked", prints[1], "Assisted Grouping: Group selection started on 4 images…")
check("group: one job bar, named", #jobs == 1 and jobs[1].title, "Assisted Grouping: Group selection")
check("group: the job bar is closed", jobs[1] and jobs[1].valid, false)
check("group: exif_times.py is asked for one file per frame", PYTHON.runs[1] and PYTHON.runs[1].manifest,
    G.csv_line({ 1, "/photos/DSC00001.JPG" }) .. "\n" .. G.csv_line({ 2, "/photos/DSC00002.JPG" }) .. "\n"
        .. G.csv_line({ 3, "/photos/DSC00003.JPG" }) .. "\n")
check("group: the end toast leads with the outcome",
    last_print():find("Assisted Grouping: done. 4 images in 2 groups (sub-second timing). Run ", 1, true) ~= nil, true)
check("group: the burst and the RAW share a darktable group", jpeg2.group == jpeg1.group and raw1.group == jpeg1.group, true)
check("group: the later frame stays alone", jpeg3.group ~= jpeg1.group, true)
check("group, tags off: no tag is written", group_tag_count(jpeg1), 0)
check("group: no Lua error", lua_errors(), nil)

PYTHON.exit = 1
click("Group selection", all)
check("group, helper failed: still groups, on whole seconds",
    last_print():find("done. 4 images in 2 groups (whole-second timing)", 1, true) ~= nil, true)
PYTHON.exit = 0

-- Group tags on, as the panel's checkbox sets it
prints, jobs, PYTHON.runs = {}, {}, {}
G.group_images(all, { timing = true, gap = 2, camera = false, refine = false, write_tags = true, trace_tags = false, native_groups = true })
check("group with tags: every image gets one group tag",
    group_tag_count(jpeg1) + group_tag_count(jpeg2) + group_tag_count(jpeg3) + group_tag_count(raw1), 4)
check("group with tags: the burst shares its tag", jpeg1.tags[1] == jpeg2.tags[1] and jpeg1.tags[1] == raw1.tags[1], true)
check("group with tags: the later frame has its own", jpeg3.tags[1] ~= jpeg1.tags[1], true)

-- Browse as pairs -------------------------------------------------------------------
click("pairs", { jpeg1 })
check("pairs: says it started", prints[1], "Assisted Grouping: Reset to RAW+JPEG pairs started on 1 image…")
check("pairs: the job bar is closed", #jobs == 1 and jobs[1].valid, false)
check("pairs: reports the images in the selection's groups", last_print(),
    "Assisted Grouping: reset 3 images to 1 RAW+JPEG pairs. Tags kept.")
check("pairs: the RAW is stacked with its JPEG", raw1.group == jpeg1.group, true)
check("pairs: the next frame is out of the group", jpeg2.group ~= jpeg1.group, true)
check("pairs: tags stay", group_tag_count(jpeg2), 1)
check("pairs: the job bar reaches the end", jobs[1] and jobs[1].percent, 1.0)

-- A large hand-made group: selecting one frame resets all of it, leader last.
local stack = {}
for id = 101, 140 do stack[#stack + 1] = id end
for id = 5, 100 do image(id, string.format("PAD%05d.JPG", id), "2026:05:02 09:00:00") end
for _, id in ipairs(stack) do
    image(id, string.format("DSC%05d.JPG", id), "2026:05:02 10:00:00").group = 101
end
group_writes = 0
click("pairs", { images_by_id[101] })
check("pairs, large group: says how many images the groups hold", printed(
    "Assisted Grouping: the selection's groups hold 40 images; resetting all of them."), true)
check("pairs, large group: every image is rewritten once", group_writes, 40)
check("pairs, large group: reports them all", last_print(),
    "Assisted Grouping: reset 40 images to 0 RAW+JPEG pairs. Tags kept.")

-- Browse as bursts ------------------------------------------------------------------
click("bursts", all)
check("bursts: says it started", prints[1], "Assisted Grouping: Browse as bursts started on 4 images…")
check("bursts: the job bar is closed", #jobs == 1 and jobs[1].valid, false)
check("bursts: reports the bursts", last_print(), "Assisted Grouping: browsing 4 images as 2 bursts from their group tags.")
check("bursts: the burst is back in one group", jpeg2.group == jpeg1.group and raw1.group == jpeg1.group, true)
check("bursts: exif_times.py isn't started", #PYTHON.runs, 0)

local untagged = image(5, "DSC00005.JPG", "2026:05:01 11:00:00")
click("bursts", { untagged })
check("bursts, no group tags: says what to do", last_print(),
    "Assisted Grouping: nothing to browse. The selection has no group tags; run Group selection with Group tags on first.")

-- A darktable group change that fails ------------------------------------------------
group_error = "database is locked"
click("pairs", { jpeg1 })
check("pairs, darktable refuses: one toast with the count and the cause", last_print(),
    "Assisted Grouping: reset 3 images to 0 RAW+JPEG pairs, but 3 group changes failed (database is locked). Reset again to retry. Tags kept.")
check("pairs, darktable refuses: the job bar is closed", #jobs == 1 and jobs[1].valid, false)
click("Clear grouping marks", all)
check("clear, darktable refuses: one toast with the count and the cause", last_print(),
    "Assisted Grouping: cleared grouping marks from 4 images, but 3 marks couldn't be cleared (database is locked). Clear again to retry.")
check("clear, darktable refuses: the tags it could detach are gone", group_tag_count(jpeg1), 0)
group_error = nil

-- Clear grouping marks ----------------------------------------------------------------
click("Clear grouping marks", all)
check("clear: says it started", prints[1], "Assisted Grouping: Clear grouping marks started on 4 images…")
check("clear: the job bar is closed", #jobs == 1 and jobs[1].valid, false)
check("clear retry: reports the images cleared", last_print(), "Assisted Grouping: cleared grouping marks from 3 images.")
check("clear: the burst is split", jpeg2.group ~= jpeg1.group, true)
check("clear: the RAW is stacked with its JPEG again", raw1.group == jpeg1.group, true)

click("Clear grouping marks", all)
check("clear, nothing left: says so", last_print(), "Assisted Grouping: nothing to clear; the selection has no grouping marks.")
check("clear, nothing left: the job bar is closed", #jobs == 1 and jobs[1].valid, false)
check("the whole session has no Lua error", lua_errors(), nil)
check("print_hinter is never called", printed("print_hinter"), false)

os.execute = real_execute
real_execute(WINDOWS and ('rmdir /s /q "' .. ROOT:gsub("/", "\\") .. '"') or ("rm -rf '" .. ROOT .. "'"))

print(string.format("\n%s (%d failed)", failures == 0 and "all passed" or "FAILED", failures))
os.exit(failures == 0 and 0 or 1)

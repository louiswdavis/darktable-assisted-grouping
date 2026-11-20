--[[
    assisted_grouping.lua — Assisted Grouping for darktable

    Reads the selection, gets sub-second capture times from python/exif_times.py,
    runs the grouping layers and writes the group tags and native groups.
    Everything above the `require "darktable"` line needs no darktable and loads
    in plain `lua`, which is how lua/test_assisted_grouping.lua tests it.
]]

local THIS_DIR = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")) or "."

-- plugin_common.lua lives beside this file; when this file was copied into lua/contrib by
-- hand it is found through the plugins folder preference (or the old plugin folder one).
-- C.plugin_folder isn't loaded yet, so both keys are read here directly.
local function load_common()
    local dirs, tried = { THIS_DIR }, {}
    local ok_dt, dt0 = pcall(require, "darktable")
    if ok_dt then
        local ok_r, root = pcall(dt0.preferences.read, "assisted_plugins", "plugins_root", "directory")
        if ok_r and root and root ~= "" then dirs[#dirs + 1] = root .. "/darktable-assisted-grouping/lua" end
        local ok_p, folder = pcall(dt0.preferences.read, "assisted_grouping", "plugin_folder", "directory")
        if ok_p and folder and folder ~= "" then dirs[#dirs + 1] = folder .. "/lua" end
    end
    for _, dir in ipairs(dirs) do
        local path = dir .. "/plugin_common.lua"
        local chunk = loadfile(path)
        if chunk then return chunk() end
        tried[#tried + 1] = path
    end
    error("assisted_grouping: plugin_common.lua not found (tried " .. table.concat(tried, ", ")
        .. "). Copy it next to assisted_grouping.lua, or set the plugins folder preference.")
end
local C = load_common()

local M = {}

-- Grouping logic ----------------------------------------------------------------

M.BURST_GAP_SECONDS = 2

function M.exif_time_to_epoch(s)
    if not s then return nil end
    local y, mo, d, h, mi, se = s:match("(%d+):(%d+):(%d+) (%d+):(%d+):(%d+)")
    -- Before 1970 (a zero date, an old scan) os.time raises on Windows: undated.
    if not y or tonumber(y) < 1970 then return nil end
    local ok, epoch = pcall(os.time, {
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
        isdst = false, -- constant offset, so a DST change can't split a burst
    })
    return ok and epoch or nil
end

-- Directory plus filename without its extension; RAW+JPEG pairs and
-- duplicates (versions of one file) share this key. The stem is compared
-- ignoring case, as darktable's import grouping does (`filename LIKE 'stem.%'`
-- in one film roll; SQLite's LIKE ignores ASCII case).
local function frame_key(image)
    local stem = (image.filename or ""):match("^(.*)%.[^./\\]*$") or image.filename or ""
    return (image.dir or "") .. "\0" .. stem:lower()
end

-- Sub-second fraction of each timed record from the helper's epoch text (by_id[id]).
-- A record whose text is blank or absent (a RAW the helper still can't read)
-- borrows the fraction of a record of the same frame (frame_key: same dir and
-- stem ignoring case, extension ignored) that has its own. Returns id → fraction,
-- and the id of the first timed record (lowest id) left without one, or nil.
function M.subsec_fractions(records, by_id)
    local own, timed = {}, {}
    for _, r in ipairs(records) do
        if r.epoch then
            timed[#timed + 1] = r
            local s = by_id[r.id]
            local e = s and s:find(".", 1, true) and tonumber(s)
            if e then own[r.id] = e - math.floor(e) end
        end
    end
    local by_frame = {}
    for _, r in ipairs(timed) do
        local k = frame_key(r)
        if own[r.id] and by_frame[k] == nil then by_frame[k] = own[r.id] end
    end
    table.sort(timed, function(a, b) return a.id < b.id end)
    local frac_of, missing = {}, nil
    for _, r in ipairs(timed) do
        local s = by_id[r.id]
        local f = own[r.id]
        if f == nil and (s == nil or s == "") then f = by_frame[frame_key(r)] end
        if f then frac_of[r.id] = f elseif not missing then missing = r.id end
    end
    return frac_of, missing
end

function M.collapse(images)
    local by_key, units = {}, {}
    for _, image in ipairs(images) do
        local key = frame_key(image)
        local unit = by_key[key]
        if not unit then
            unit = { members = {}, tags = {} }
            by_key[key] = unit
            units[#units + 1] = unit
        end
        unit.members[#unit.members + 1] = image
        for tag in pairs(image.tags or {}) do unit.tags[tag] = true end
    end

    for _, unit in ipairs(units) do
        table.sort(unit.members, function(a, b) return a.id < b.id end)
        unit.id = unit.members[1].id
        -- Lowest-id member first; later members fill fields it lacks.
        for _, field in ipairs({ "epoch", "maker", "model", "lens", "focal", "exposure", "focus" }) do
            for _, member in ipairs(unit.members) do
                if member[field] ~= nil then
                    unit[field] = member[field]
                    break
                end
            end
        end
    end
    table.sort(units, function(a, b) return a.id < b.id end)
    return units
end

function M.cluster_by_time(units, gap_seconds)
    gap_seconds = gap_seconds or M.BURST_GAP_SECONDS
    local timed, untimed = {}, {}
    for _, unit in ipairs(units) do
        if unit.epoch then timed[#timed + 1] = unit else untimed[#untimed + 1] = unit end
    end
    -- (epoch, id) is a total order, so the sort is stable across runs.
    table.sort(timed, function(a, b)
        if a.epoch ~= b.epoch then return a.epoch < b.epoch end
        return a.id < b.id
    end)
    table.sort(untimed, function(a, b) return a.id < b.id end)

    local group_of = {}
    local next_group = 0
    local prev_epoch = nil
    for _, unit in ipairs(timed) do
        -- Tolerance: at ~1.78e9 a double steps by ~2.4e-7, so an exact-gap
        -- delta can land just over the gap. Sub-second data is in hundredths.
        if prev_epoch == nil or (unit.epoch - prev_epoch) > gap_seconds + 1e-3 then
            next_group = next_group + 1
        end
        group_of[unit.id] = next_group
        prev_epoch = unit.epoch
    end
    for _, unit in ipairs(untimed) do
        next_group = next_group + 1
        group_of[unit.id] = next_group
    end
    return group_of
end

-- Auto burst gap: a histogram of log10 gaps between consecutive capture times.
M.AUTO_GAP_MIN_GAPS = 30
M.AUTO_GAP_BIN = 0.1 -- decades per bin
M.AUTO_GAP_LOG_RANGE = { -2, 4 } -- 0.01 s to 10000 s; gaps outside land in the end bins
M.AUTO_GAP_VALLEY = 0.5 -- the valley is at most this share of the smaller peak
M.AUTO_GAP_CLAMP = { 0.3, 10 }

-- whole_seconds is true (every timeline), false/nil (none) or, with Camera on, a set of
-- the camera_keys on whole seconds (M.apply_subsec's whole_of).
local function is_whole(whole_seconds, key)
    return whole_seconds == true or type(whole_seconds) == "table" and whole_seconds[key] ~= nil
end

-- Gaps between consecutive timed units, each camera_key on its own timeline when
-- by_camera (two bodies shooting at once interleave, so their cross gaps are not bursts).
-- A whole-second timeline's gaps are at least 1 s, so its 0 s and 1 s gaps share a bin.
local function capture_gaps(units, by_camera, whole_seconds)
    local lines = {}
    for _, unit in ipairs(units) do
        if unit.epoch then
            local k = by_camera and M.camera_key(unit) or ""
            lines[k] = lines[k] or {}
            table.insert(lines[k], unit.epoch)
        end
    end
    local gaps = {}
    for k, epochs in pairs(lines) do
        local floor_gap = is_whole(whole_seconds, k) and 1 or 0
        table.sort(epochs)
        for i = 2, #epochs do gaps[#gaps + 1] = math.max(epochs[i] - epochs[i - 1], floor_gap) end
    end
    return gaps
end

-- Returns (gap seconds, how) for gap = "auto": the lowest point of the smoothed histogram
-- between its two biggest peaks, clamped to AUTO_GAP_CLAMP, or M.BURST_GAP_SECONDS when
-- there are too few gaps or no clear valley. how is "valley", "valley, clamped" or
-- "fallback: <why>". whole_seconds (see is_whole): a timeline without sub-second parts has
-- its 0 s and 1 s gaps in one bin, and with any such timeline the cut is at least 1 s.
function M.auto_gap(units, by_camera, whole_seconds)
    local gaps = capture_gaps(units, by_camera, whole_seconds)
    if #gaps < M.AUTO_GAP_MIN_GAPS then
        return M.BURST_GAP_SECONDS, string.format("fallback: %d gaps, fewer than %d", #gaps, M.AUTO_GAP_MIN_GAPS)
    end
    local lo, hi = M.AUTO_GAP_LOG_RANGE[1], M.AUTO_GAP_LOG_RANGE[2]
    local n = math.floor((hi - lo) / M.AUTO_GAP_BIN + 0.5)
    local hist = {}
    for i = 1, n do hist[i] = 0 end
    for _, g in ipairs(gaps) do
        local b = math.floor((math.log(math.max(g, 10 ^ lo), 10) - lo) / M.AUTO_GAP_BIN) + 1
        b = math.min(math.max(b, 1), n)
        hist[b] = hist[b] + 1
    end
    local s = {}
    for i = 1, n do s[i] = ((hist[i - 1] or 0) + hist[i] + (hist[i + 1] or 0)) / 3 end

    local p1 = 1
    for i = 2, n do if s[i] > s[p1] then p1 = i end end
    local p2, cut
    for i = 1, n do
        local a, b = math.min(i, p1), math.max(i, p1)
        if b - a >= 2 and (not p2 or s[i] > s[p2]) then
            local low = a + 1
            for j = a + 1, b - 1 do if s[j] < s[low] then low = j end end
            if s[low] <= M.AUTO_GAP_VALLEY * s[i] then p2, cut = i, low end
        end
    end
    if not p2 then return M.BURST_GAP_SECONDS, "fallback: one peak" end
    -- centre of the run of equal lowest bins
    local last = cut
    while last + 1 < math.max(p1, p2) and s[last + 1] == s[cut] do last = last + 1 end
    local gap = 10 ^ (lo + ((cut + last) / 2 - 0.5) * M.AUTO_GAP_BIN)
    local any_whole = whole_seconds == true or type(whole_seconds) == "table" and next(whole_seconds) ~= nil
    local min_gap = any_whole and math.max(1, M.AUTO_GAP_CLAMP[1]) or M.AUTO_GAP_CLAMP[1]
    local clamped = math.min(math.max(gap, min_gap), M.AUTO_GAP_CLAMP[2])
    return clamped, clamped == gap and "valley" or "valley, clamped"
end

-- Tag hierarchy uses `|` and the ledger CSV uses `,` and `"`, so those
-- (plus `;` and control characters) never reach a key.
function M.sanitize(s)
    s = (s or ""):gsub('[|;,"%c]', " "):gsub("%s+", " ")
    return (s:gsub("^ ", ""):gsub(" $", ""))
end

function M.camera_key(unit)
    return M.sanitize(table.concat({ unit.maker or "", unit.model or "", unit.lens or "" }, " "))
end

function M.tag_key(tag)
    return function(unit)
        return unit.tags[tag] and "1" or "0"
    end
end

-- The single tag directly under `parent`; nil when there are none or several.
function M.parent_key(parent)
    local prefix = parent .. "|"
    return function(unit)
        local found
        for tag in pairs(unit.tags) do
            if tag:sub(1, #prefix) == prefix then
                local child = tag:sub(#prefix + 1)
                if child ~= "" and not child:find("|", 1, true) then
                    if found then return nil end
                    found = child
                end
            end
        end
        return found
    end
end

-- Splits each group by key. Nil-key units join the group's first part.
-- New numbers are dense from 1, by old group then first appearance.
function M.divide(group_of, key_of, units)
    local by_group, olds = {}, {}
    for _, unit in ipairs(units) do
        local old = group_of[unit.id]
        if old ~= nil then
            if not by_group[old] then
                by_group[old] = {}
                olds[#olds + 1] = old
            end
            local list = by_group[old]
            list[#list + 1] = unit
        end
    end
    table.sort(olds)

    local out, next_group = {}, 0
    for _, old in ipairs(olds) do
        local part_of, first_part, nil_units = {}, nil, {}
        for _, unit in ipairs(by_group[old]) do
            local key = key_of(unit)
            if key == nil then
                nil_units[#nil_units + 1] = unit
            else
                if not part_of[key] then
                    next_group = next_group + 1
                    part_of[key] = next_group
                    first_part = first_part or next_group
                end
                out[unit.id] = part_of[key]
            end
        end
        if #nil_units > 0 and not first_part then
            next_group = next_group + 1
            first_part = next_group
        end
        for _, unit in ipairs(nil_units) do out[unit.id] = first_part end
    end
    return out
end

-- With timing off, every unit outside base_of shares one group, timed or not.
local function one_group(units)
    local group_of = {}
    for _, unit in ipairs(units) do group_of[unit.id] = 1 end
    return group_of
end

-- Every unit gets a group of its own, numbered in unit order.
local function each_alone(units)
    local group_of = {}
    for i, unit in ipairs(units) do group_of[unit.id] = i end
    return group_of
end

-- cluster_by_time on each camera_key's own timeline, so one body's frames never chain
-- through another's. Cameras are numbered in order of their first capture time, then
-- by key; groups are dense across them.
local function cluster_per_camera(units, gap)
    local lines, keys, first = {}, {}, {}
    for _, unit in ipairs(units) do
        local k = M.camera_key(unit)
        if not lines[k] then
            lines[k], keys[#keys + 1], first[k] = {}, k, math.huge
        end
        table.insert(lines[k], unit)
        if unit.epoch and unit.epoch < first[k] then first[k] = unit.epoch end
    end
    table.sort(keys, function(a, b)
        if first[a] ~= first[b] then return first[a] < first[b] end
        return a < b
    end)
    local group_of, offset = {}, 0
    for _, k in ipairs(keys) do
        local top = 0
        for id, grp in pairs(M.cluster_by_time(lines[k], gap)) do
            group_of[id] = offset + grp
            if grp > top then top = grp end
        end
        offset = offset + top
    end
    return group_of
end

local function burst_layer(units, gap, base_of, timing, alone, by_camera)
    local cluster = alone and each_alone
        or timing and by_camera and function(list) return cluster_per_camera(list, gap) end
        or timing and function(list) return M.cluster_by_time(list, gap) end or one_group
    if not base_of then return cluster(units) end
    local burst_of, rest, max_base = {}, {}, 0
    for _, unit in ipairs(units) do
        local grp = base_of[unit.id]
        if grp ~= nil then
            burst_of[unit.id] = grp
            if grp > max_base then max_base = grp end
        else
            rest[#rest + 1] = unit
        end
    end
    for id, grp in pairs(cluster(rest)) do
        burst_of[id] = max_base + grp
    end
    return burst_of
end

-- Groups of fewer than min_frames units are dissolved: each of their units gets a group of
-- its own. New numbers are dense from 1, by old group then unit order. Also returns how
-- many groups of 2+ units were dissolved.
function M.dissolve_small(group_of, units, min_frames)
    local size, olds = {}, {}
    for _, unit in ipairs(units) do
        local old = group_of[unit.id]
        if not size[old] then olds[#olds + 1] = old end
        size[old] = (size[old] or 0) + 1
    end
    table.sort(olds)
    local first, next_group, dissolved = {}, 0, 0
    for _, old in ipairs(olds) do
        first[old] = next_group + 1
        local small = size[old] < min_frames
        next_group = next_group + (small and size[old] or 1)
        if small and size[old] > 1 then dissolved = dissolved + 1 end
    end
    local out, used = {}, {}
    for _, unit in ipairs(units) do
        local old = group_of[unit.id]
        out[unit.id] = first[old] + (used[old] or 0)
        if size[old] < min_frames then used[old] = (used[old] or 0) + 1 end
    end
    return out, dissolved
end

-- opts = { gap (seconds or "auto"), timing = bool (default true), camera = bool, tag = string|nil,
-- parent = string|nil, base_of = group_of|nil, alone = bool, whole_seconds = bool,
-- min_frames = number|nil, session_gap = seconds|nil }. With timing false,
-- burst_of is base_of plus one group for the rest, and result.timing is false. With
-- alone, each unit outside base_of gets its own group and result.timing is false. With
-- gap "auto" and timing on, result.gap and result.gap_how are M.auto_gap's answer for the
-- units outside base_of. With min_frames above 2, result.min_of is the last layer
-- (M.dissolve_small) and result.dissolved its count. With session_gap, result.session_of
-- is M.sessions_of's answer; it splits no group.
function M.run_layers(units, opts)
    local result = { timing = opts.timing ~= false and not opts.alone }
    local gap = opts.gap
    if gap == "auto" then
        local rest = {}
        for _, unit in ipairs(units) do
            if not (opts.base_of and opts.base_of[unit.id] ~= nil) then rest[#rest + 1] = unit end
        end
        if result.timing then
            gap, result.gap_how = M.auto_gap(rest, opts.camera, opts.whole_seconds)
            result.gap = gap
        else
            gap = nil
        end
    end
    result.burst_of = burst_layer(units, gap, opts.base_of, result.timing, opts.alone, opts.camera)
    result.final_of = result.burst_of
    if opts.camera then
        result.camera_of = M.divide(result.final_of, M.camera_key, units)
        result.final_of = result.camera_of
    end
    if opts.tag then
        result.tag_of = M.divide(result.final_of, M.tag_key(opts.tag), units)
        result.final_of = result.tag_of
    end
    if opts.parent then
        result.parent_of = M.divide(result.final_of, M.parent_key(opts.parent), units)
        result.final_of = result.parent_of
    end
    if opts.min_frames and opts.min_frames > 2 then
        result.min_of, result.dissolved = M.dissolve_small(result.final_of, units, opts.min_frames)
        result.final_of = result.min_of
    end
    if opts.session_gap then result.session_of = M.sessions_of(units, opts.session_gap) end
    return result
end

-- Sessions sit above the groups: timed units in capture order, a new session when the gap
-- to the previous one is longer than gap_seconds. Units with no capture time are left out.
function M.sessions_of(units, gap_seconds)
    local timed = {}
    for _, unit in ipairs(units) do
        if unit.epoch then timed[#timed + 1] = unit end
    end
    table.sort(timed, function(a, b)
        if a.epoch ~= b.epoch then return a.epoch < b.epoch end
        return a.id < b.id
    end)
    local session_of, session = {}, 0
    for i, unit in ipairs(timed) do
        if i == 1 or unit.epoch - timed[i - 1].epoch > gap_seconds then session = session + 1 end
        session_of[unit.id] = session
    end
    return session_of
end

-- Each group's weakest link: its largest capture-time gap between neighbouring frames.
-- Returns { { group, frames, gap, after = the unit that follows the gap } }, widest gap
-- first, for groups with two or more timed frames. `frames` is the group's size, untimed
-- frames included.
function M.weakest_links(units, group_of)
    local by_group, numbers, size = {}, {}, {}
    for _, unit in ipairs(units) do
        local group = group_of[unit.id]
        size[group] = (size[group] or 0) + 1
        if unit.epoch then
            if not by_group[group] then
                by_group[group] = {}
                numbers[#numbers + 1] = group
            end
            table.insert(by_group[group], unit)
        end
    end
    local links = {}
    for _, group in ipairs(numbers) do
        local timed = by_group[group]
        if #timed >= 2 then
            table.sort(timed, function(a, b)
                if a.epoch ~= b.epoch then return a.epoch < b.epoch end
                return a.id < b.id
            end)
            local link = { group = group, frames = size[group], gap = -1 }
            for i = 2, #timed do
                local gap = timed[i].epoch - timed[i - 1].epoch
                if gap > link.gap then link.gap, link.after = gap, timed[i] end
            end
            links[#links + 1] = link
        end
    end
    table.sort(links, function(a, b)
        if a.gap ~= b.gap then return a.gap > b.gap end
        return a.group < b.group
    end)
    return links
end

M.WEAKEST_LINKS_LOGGED = 10

-- How far a setting must move between neighbouring frames to count as a jump: the larger
-- value over the smaller. Exposure 4 is two stops.
M.CUT_HINT_RATIO = { focal = 1.5, exposure = 4, focus = 2 }

local function exposure_text(seconds)
    if seconds < 1 then return string.format("1/%.0f", 1 / seconds) end
    return string.format("%.14g", seconds)
end

local CUT_HINT_FIELDS = {
    { key = "focal", text = function(a, b) return string.format("focal length %.14g to %.14g mm", a, b) end },
    { key = "exposure", text = function(a, b) return "exposure " .. exposure_text(a) .. " to " .. exposure_text(b) .. " s" end },
    { key = "focus", text = function(a, b) return string.format("focus distance %.14g to %.14g m", a, b) end },
}

-- Places inside a group where focal length, exposure time or focus distance jumps between
-- neighbouring frames in capture order: a sign the group may hold two bursts. Returns
-- { { group, after = the unit that follows the jump, jumps = { text, ... } } } by group,
-- then capture time. Untimed frames, and a setting either neighbour lacks, are skipped.
function M.cut_hints(units, group_of)
    local by_group, numbers = {}, {}
    for _, unit in ipairs(units) do
        if unit.epoch then
            local group = group_of[unit.id]
            if not by_group[group] then
                by_group[group] = {}
                numbers[#numbers + 1] = group
            end
            table.insert(by_group[group], unit)
        end
    end
    table.sort(numbers)
    local hints = {}
    for _, group in ipairs(numbers) do
        local timed = by_group[group]
        table.sort(timed, function(a, b)
            if a.epoch ~= b.epoch then return a.epoch < b.epoch end
            return a.id < b.id
        end)
        for i = 2, #timed do
            local jumps = {}
            for _, field in ipairs(CUT_HINT_FIELDS) do
                local a, b = timed[i - 1][field.key], timed[i][field.key]
                if a and b and math.max(a, b) / math.min(a, b) >= M.CUT_HINT_RATIO[field.key] then
                    jumps[#jumps + 1] = field.text(a, b)
                end
            end
            if #jumps > 0 then hints[#hints + 1] = { group = group, after = timed[i], jumps = jumps } end
        end
    end
    return hints
end

M.CUT_HINTS_LOGGED = 10

-- Stamped tag names ----------------------------------------------------------

M.PREFIX = "Assisted Grouping"

-- `Group`, `Burst` and `Session` take the zero-padded number; `Camera`, `Tag`, `Parent`
-- take `label`, which must already be sanitized.
function M.group_tag(stamp, layer, n, label)
    local leaf = (layer == "Group" or layer == "Burst" or layer == "Session") and string.format("%04d", n) or label
    return table.concat({ M.PREFIX, stamp, layer, leaf }, "|")
end

local function last_segment(tag)
    return tag:match("([^|]*)$")
end

-- opts as for run_layers, plus trace: the Burst/Camera/Tag/Parent names are written only
-- when it is true. A layer counts as run when its map is in `result`. A unit in
-- result.session_of also gets its Session name, trace or not.
function M.wanted_tags(units, result, stamp, opts)
    local wanted = {}
    local child_of = opts.parent and M.parent_key(opts.parent)
    local tag_label = opts.tag and M.sanitize(last_segment(opts.tag))
    for _, unit in ipairs(units) do
        local set = {}
        set[M.group_tag(stamp, "Group", result.final_of[unit.id])] = true
        if result.session_of and result.session_of[unit.id] then
            set[M.group_tag(stamp, "Session", result.session_of[unit.id])] = true
        end
        if opts.trace and result.timing ~= false and result.final_of ~= result.burst_of then
            set[M.group_tag(stamp, "Burst", result.burst_of[unit.id])] = true
        end
        if opts.trace and result.camera_of then
            local cam = M.camera_key(unit)
            set[M.group_tag(stamp, "Camera", nil, cam ~= "" and cam or "unknown")] = true
        end
        if opts.trace and result.tag_of then
            local prefix = unit.tags[opts.tag] and "has " or "not "
            set[M.group_tag(stamp, "Tag", nil, prefix .. tag_label)] = true
        end
        if opts.trace and result.parent_of then
            local child = child_of(unit)
            child = child and M.sanitize(child) or ""
            set[M.group_tag(stamp, "Parent", nil, child ~= "" and child or "none")] = true
        end
        for _, member in ipairs(unit.members or { unit }) do
            local copy = {}
            for name in pairs(set) do copy[name] = true end
            wanted[member.id] = copy
        end
    end
    return wanted
end

M.latest_group_tag = C.latest_group_tag

-- Units with no group tag are left out of the result.
function M.base_of_from_tags(units)
    local group_of, number_of, next_group = {}, {}, 0
    for _, unit in ipairs(units) do
        local tag = M.latest_group_tag(unit.tags)
        if tag then
            if not number_of[tag] then
                next_group = next_group + 1
                number_of[tag] = next_group
            end
            group_of[unit.id] = number_of[tag]
        end
    end
    return group_of
end

-- Ledger -----------------------------------------------------------------------

function M.csv_line(fields)
    local out = {}
    for i, v in ipairs(fields) do
        out[i] = '"' .. tostring(v):gsub('"', '""') .. '"'
    end
    return table.concat(out, ",")
end

-- Quote-aware: a quoted field may hold `,`, `""` and line breaks.
function M.parse_csv(text)
    local rows, row, field = {}, {}, {}
    local i, n, quoted = 1, #text, false
    local function end_field()
        row[#row + 1] = table.concat(field)
        field = {}
    end
    local function end_row()
        end_field()
        if not (#row == 1 and row[1] == "") then rows[#rows + 1] = row end
        row = {}
    end
    while i <= n do
        local c = text:sub(i, i)
        if quoted then
            if c == '"' then
                if text:sub(i + 1, i + 1) == '"' then
                    field[#field + 1] = '"'
                    i = i + 1
                else
                    quoted = false
                end
            else
                field[#field + 1] = c
            end
        elseif c == '"' then
            quoted = true
        elseif c == "," then
            end_field()
        elseif c == "\r" or c == "\n" then
            if c == "\r" and text:sub(i + 1, i + 1) == "\n" then i = i + 1 end
            end_row()
        else
            field[#field + 1] = c
        end
        i = i + 1
    end
    if #field > 0 or #row > 0 then end_row() end
    return rows
end

-- Rows: `<library>,id,tag,<name>` for each tag the plugin attached, `<library>,id,group,<leader id>`
-- for a native group it made. Anything not in the ledger was made by hand. `library` is
-- C.library_key: image ids restart in every library, so only the rows of library `lib` are
-- parsed (keyed by id); the other libraries' rows are kept as text in ledger.other and written
-- back unchanged. Rows from before the library column (3 fields) belong to `lib`.
function M.ledger_parse(text, lib)
    lib = lib or ""
    local ledger = { other = {} }
    for _, row in ipairs(M.parse_csv(text or "")) do
        if #row == 3 then table.insert(row, 1, lib) end
        local id = tonumber(row[2])
        if #row == 4 and row[1] ~= lib then
            ledger.other[#ledger.other + 1] = M.csv_line(row)
        elseif id and #row == 4 and row[4] ~= "" then
            local entry = ledger[id] or { tags = {} }
            ledger[id] = entry
            if row[3] == "tag" then
                entry.tags[row[4]] = true
            elseif row[3] == "group" then
                entry.native = tonumber(row[4])
            end
        end
    end
    return ledger
end

function M.ledger_format(ledger, lib)
    lib = lib or ""
    local ids = {}
    for id in pairs(ledger) do
        if type(id) == "number" then ids[#ids + 1] = id end
    end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do
        local entry = ledger[id]
        local names = {}
        for name in pairs(entry.tags or {}) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do out[#out + 1] = M.csv_line({ lib, id, "tag", name }) end
        if entry.native then out[#out + 1] = M.csv_line({ lib, id, "group", entry.native }) end
    end
    for _, line in ipairs(ledger.other or {}) do out[#out + 1] = line end
    return #out > 0 and table.concat(out, "\n") .. "\n" or ""
end

M.ledger_prune = C.ledger_prune

-- Run after ledger_prune: entries whose native leader is no longer in the library
-- (`exists(id)` false) point at the lowest surviving id of that group instead, and a
-- lone survivor's native is cleared. Returns the number of groups changed.
function M.repoint_stale_leaders(ledger, exists)
    local by_leader = {}
    for id, entry in pairs(ledger) do
        if type(id) == "number" and entry.native and entry.native ~= id then
            by_leader[entry.native] = by_leader[entry.native] or {}
            table.insert(by_leader[entry.native], id)
        end
    end
    local n = 0
    for leader, ids in pairs(by_leader) do
        if not ledger[leader] and not exists(leader) then
            table.sort(ids)
            for _, id in ipairs(ids) do
                M.set_ledger_native(ledger, id, #ids >= 2 and ids[1] or nil)
            end
            n = n + 1
        end
    end
    return n
end

-- Only ledger tags are ever removed, so hand-made tags survive a re-run.
-- Both lists are sorted.
function M.plan_replace(have, ledger_tags, wanted)
    local add, remove = {}, {}
    for name in pairs(wanted) do
        if not have[name] then add[#add + 1] = name end
    end
    for name in pairs(ledger_tags) do
        if have[name] and not wanted[name] then remove[#remove + 1] = name end
    end
    table.sort(add)
    table.sort(remove)
    return add, remove
end

-- Plans the native groups for `final_of`. `members_of[id]` lists each selected
-- image's current native group as `{ id, dir, filename }` records, itself included.
-- A frame is skipped when one of its images shares a group with another frame's image
-- that is not of its ledger group: that group was made, merged or moved into by hand,
-- and the frames on both sides of a move keep it. A frame is skipped too when one of
-- its images is alone while the ledger still holds another image of its group: it was
-- taken out by hand, or its group was broken up by hand. Every
-- image of a kept frame in a final group of 2+ images is detached, then the group's
-- lowest id leads. Selected ledger images of smaller groups are detached too, so
-- the plugin's old groups dissolve on a re-run. A final group that is already one
-- native group with exactly those images, led by the lowest id (`members_of[id].leader`),
-- is left as it is.
-- Returns { detach = sorted ids, groups = { { leader, members = sorted ids } }, skipped = n images, unchanged = n images,
-- hand = { [unit id] = true } for the frames skipped }.
function M.plan_native(units, final_of, ledger, members_of)
    local by_group, order = {}, {}
    for _, unit in ipairs(units) do
        local g = final_of[unit.id]
        if not by_group[g] then
            by_group[g] = {}
            order[#order + 1] = g
        end
        table.insert(by_group[g], unit)
    end

    local ledger_size = {}
    for id, entry in pairs(ledger) do
        if type(id) == "number" and entry.native then
            ledger_size[entry.native] = (ledger_size[entry.native] or 0) + 1
        end
    end

    local function hand_made(unit)
        local own = frame_key(unit.members[1])
        for _, m in ipairs(unit.members) do
            local leader = ledger[m.id] and ledger[m.id].native
            local now = members_of[m.id] or {}
            if leader and #now == 1 and ledger_size[leader] >= 2 then return true end
            for _, other in ipairs(now) do
                local oid = tonumber(other.id)
                local ledger_mate = leader and (oid == leader or (ledger[oid] and ledger[oid].native == leader))
                if frame_key(other) ~= own and not ledger_mate then return true end
            end
        end
        return false
    end

    local function in_place(kept)
        local now = members_of[kept[1]] or {}
        if now.leader ~= kept[1] or #now ~= #kept then return false end
        local ids = {}
        for _, m in ipairs(now) do ids[#ids + 1] = m.id end
        table.sort(ids)
        return table.concat(ids, ",") == table.concat(kept, ",")
    end

    local plan, detach = { detach = {}, groups = {}, skipped = 0, unchanged = 0, hand = {} }, {}
    local settled = {}
    for _, g in ipairs(order) do
        local n = 0
        for _, unit in ipairs(by_group[g]) do n = n + #unit.members end
        if n >= 2 then
            local kept = {}
            for _, unit in ipairs(by_group[g]) do
                if hand_made(unit) then
                    plan.hand[unit.id] = true
                    plan.skipped = plan.skipped + #unit.members
                else
                    for _, m in ipairs(unit.members) do kept[#kept + 1] = m.id end
                end
            end
            if #kept >= 2 then
                table.sort(kept)
                if in_place(kept) then
                    plan.unchanged = plan.unchanged + #kept
                    for _, id in ipairs(kept) do settled[id] = true end
                else
                    plan.groups[#plan.groups + 1] = { leader = kept[1], members = kept }
                    for _, id in ipairs(kept) do detach[id] = true end
                end
            end
        end
    end
    for _, unit in ipairs(units) do
        if not plan.hand[unit.id] then
            for _, m in ipairs(unit.members) do
                if ledger[m.id] and ledger[m.id].native and not settled[m.id] then detach[m.id] = true end
            end
        end
    end
    for id in pairs(detach) do plan.detach[#plan.detach + 1] = id end
    table.sort(plan.detach)
    return plan
end

-- What Verify selection reports; nothing is written. `fresh` lists the frames a Group selection
-- run with `opts` would change, as { unit, reasons }, in unit order. Frames the run skips as
-- hand-made (M.plan_native) are left out when native groups are on. Group tags are compared by
-- which frames share each frame's newest one, since every run stamps new names. `broken` is the
-- sorted ids of images whose darktable group has no leader inside it (`members_of[id].broken`).
function M.plan_verify(units, final_of, ledger, members_of, opts)
    local plan = M.plan_native(units, final_of, ledger, members_of)
    local differs = {}
    for _, id in ipairs(plan.detach) do differs[id] = true end

    -- unit -> the ids of the units sharing its key, in unit order, so equal sets give equal text
    local function mates(key_of)
        local ids_of, text_of = {}, {}
        for _, unit in ipairs(units) do
            local key = key_of(unit)
            if key then
                ids_of[key] = ids_of[key] or {}
                table.insert(ids_of[key], unit.id)
            end
        end
        for _, unit in ipairs(units) do
            local key = key_of(unit)
            text_of[unit.id] = key and table.concat(ids_of[key], ",")
        end
        return text_of
    end
    local by_tag = mates(function(unit) return M.latest_group_tag(unit.tags) end)
    local by_final = mates(function(unit) return final_of[unit.id] end)

    local result = { fresh = {}, broken = {} }
    for _, unit in ipairs(units) do
        local reasons = {}
        if opts.native_groups and not plan.hand[unit.id] then
            for _, m in ipairs(unit.members) do
                if differs[m.id] then
                    reasons[1] = "darktable group differs"
                    break
                end
            end
        end
        if opts.write_tags and not (opts.native_groups and plan.hand[unit.id]) then
            if not by_tag[unit.id] then
                reasons[#reasons + 1] = "no Group tag"
            elseif by_tag[unit.id] ~= by_final[unit.id] then
                reasons[#reasons + 1] = "Group tag differs"
            end
        end
        if #reasons > 0 then result.fresh[#result.fresh + 1] = { unit = unit, reasons = reasons } end
        for _, m in ipairs(unit.members) do
            if members_of[m.id].broken then result.broken[#result.broken + 1] = m.id end
        end
    end
    table.sort(result.broken)
    return result
end

-- Panel options ----------------------------------------------------------------

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

-- Burst gap from the preference text: a number above 0, `.` or `,` as the decimal
-- mark, or "auto" (any case) for M.auto_gap. Nil for anything else (hex, exponents, signs, blank).
function M.parse_gap(s)
    local t = trim(type(s) == "number" and tostring(s) or s):gsub(",", ".")
    if t:lower() == "auto" then return "auto" end
    if not t:match("^%d*%.?%d*$") or not t:match("%d") then return nil end
    local n = tonumber(t)
    if not n or n <= 0 then return nil end
    return n
end

-- Minimum burst size from the panel text: a whole number of frames, 2 or more. Nil for
-- anything else.
function M.parse_min_size(s)
    local t = trim(type(s) == "number" and string.format("%.14g", s) or s)
    if not t:match("^%d+$") then return nil end
    local n = tonumber(t)
    if n < 2 then return nil end
    return n
end

-- Session gap from the panel text, in minutes: 0 or blank for off, else a number above 0
-- (`.` or `,` as the decimal mark). Nil for anything else.
function M.parse_session_gap(s)
    local t = trim(type(s) == "number" and string.format("%.14g", s) or s):gsub(",", ".")
    if t == "" then return 0 end
    if not t:match("^%d*%.?%d*$") or not t:match("%d") then return nil end
    return tonumber(t)
end

M.ERR_NO_OUTPUT = "turn on at least one output (group tags or darktable groups)"
M.ERR_BAD_GAP = "the burst gap must be auto or a number of seconds above 0, e.g. 2 or 0.5"
M.ERR_BAD_MIN_SIZE = "the minimum burst size must be a whole number of frames, 2 or more"
M.ERR_BAD_SESSION_GAP = "the session gap must be a number of minutes, e.g. 30, or 0 for off"

-- Stored start_from values (combobox order) and their panel labels.
M.START_FROM = { "time", "tags", "one" }
M.START_FROM_LABELS = { "capture time", "last run's groups", "one group" }

-- Every panel setting a preset stores, in panel order.
M.PRESET_SCHEMA = {
    { key = "start_from", kind = "choice", choices = M.START_FROM, default = "time" },
    { key = "burst_gap_seconds", kind = "number", default = 2 },
    { key = "burst_gap_auto", kind = "bool", default = false }, -- the gap entry reads "auto"; burst_gap_seconds keeps the last number
    { key = "min_burst_size", kind = "number", default = 2 }, -- frames; a final group with fewer is left as single frames
    { key = "camera", kind = "bool", default = false },
    { key = "tag", kind = "string", default = "" },
    { key = "parent", kind = "string", default = "" },
    { key = "native_groups", kind = "bool", default = true },
    { key = "write_tags", kind = "bool", default = false },
    { key = "trace_tags", kind = "bool", default = false },
    { key = "session_gap_minutes", kind = "number", default = 0 }, -- 0 = no Session tags
}

-- The panel's pages and the preset keys each page's widgets edit (C.page_coverage checks them).
M.PANEL_PAGES = {
    { number = 1, title = "start groups", keys = { "start_from", "burst_gap_seconds", "burst_gap_auto", "min_burst_size" } },
    { number = 2, title = "divide groups", keys = { "camera", "tag", "parent" } },
    { number = 3, title = "output", keys = { "native_groups", "write_tags", "trace_tags", "session_gap_minutes" } },
    { number = 4, title = "run", keys = {} },
    { number = 5, title = "tools", keys = {} },
}
M.PANEL_OTHER_KEYS = {}

-- Tag switches by kind, for the tests and the README; the panel places its widgets by hand.
M.TAG_TOGGLES = {
    { key = "write_tags", label = "Group tags", kind = "output", writes = { "Group", "Session" } },
    { key = "trace_tags", label = "Layer trace tags", kind = "diag", writes = { "Burst", "Camera", "Tag", "Parent" } },
}
M.TAG_KINDS = {
    { kind = "output", label = "outputs" },
    { kind = "check", label = "checks" },
    { kind = "diag", label = "how it decided" },
}
M.ERR_NO_LAYER = "turn on at least one divide layer (camera and lens, tag or parent tag), or start from capture time or last run's groups"
M.NOTICE_TAGS_OFF = "turn on Group tags, or this run's groups aren't saved for the next run to start from"
M.NOTICE_NO_LAYER = "one group needs a divide layer: turn on Camera and lens, or type a Tag or Parent tag"
M.NOTICE_SESSION_TAGS_OFF = "turn on Group tags, or no Session tags are written"

-- Maps the pre-start_from preset keys to a start_from value; refine wins over timing.
function M.start_from_of(timing, refine)
    if refine then return "tags" end
    if timing == false then return "one" end
    return "time"
end

-- Returns preset text that holds start_from (derived from the old timing/refine keys when
-- absent) and trace_tags (on when write_tags was on), plus a list of log lines for what
-- changed, nil when nothing did. Text that does not decode comes back unchanged.
function M.upgrade_preset_text(text)
    local decoded = C.preset_decode(text)
    if not decoded then return text end
    local notes
    local changed = false
    if decoded.start_from == nil then
        decoded.start_from = M.start_from_of(decoded.timing, decoded.refine)
        changed = true
    end
    if decoded.trace_tags == nil and decoded.write_tags == true then
        decoded.trace_tags = true
        notes = { "preset upgraded: trace_tags set from write_tags (Layer trace tags is a separate switch)" }
        changed = true
    end
    if not changed then return text end
    return C.preset_encode(M.PRESET_SCHEMA, decoded), notes
end

local function has_layer(p)
    local tag, parent = trim(p.tag), trim(p.parent):gsub("|+$", "")
    return p.start_from == "time" or p.start_from == "tags" or (p.camera and true or false) or tag ~= "" or parent ~= ""
end

local function layers_of(p)
    return p.start_from == "time", p.start_from == "tags"
end

-- p = { start_from, gap_text, min_size_text, session_gap_text, camera, tag, parent, write_tags,
-- trace_tags, native_groups } as the panel reads them. Returns group_images options (blank tag/parent
-- → nil, a trailing `|` on the parent dropped), or nil and why the run can't start.
function M.panel_options(p)
    if not p.write_tags and not p.native_groups then return nil, M.ERR_NO_OUTPUT end
    local timing, refine = layers_of(p)
    local gap = M.parse_gap(p.gap_text)
    if timing and not gap then return nil, M.ERR_BAD_GAP end
    local min_frames = M.parse_min_size(p.min_size_text)
    if not min_frames then return nil, M.ERR_BAD_MIN_SIZE end
    local session_minutes = M.parse_session_gap(p.session_gap_text)
    if not session_minutes then return nil, M.ERR_BAD_SESSION_GAP end
    local tag = trim(p.tag)
    local parent = trim(p.parent):gsub("|+$", "")
    local opts = {
        timing = timing,
        gap = gap,
        min_frames = min_frames,
        session_gap = session_minutes > 0 and session_minutes * 60 or nil,
        camera = p.camera and true or false,
        tag = tag ~= "" and tag or nil,
        parent = parent ~= "" and parent or nil,
        refine = refine,
        write_tags = p.write_tags and true or false,
        trace_tags = p.trace_tags and true or false,
        native_groups = p.native_groups and true or false,
    }
    if not has_layer(p) then
        return nil, M.ERR_NO_LAYER
    end
    return opts
end

-- The one line the panel shows under its settings: "" when nothing is wrong.
function M.panel_notice(p)
    if not p.write_tags and not p.native_groups then return M.ERR_NO_OUTPUT end
    local timing, refine = layers_of(p)
    if timing and not M.parse_gap(p.gap_text) then return M.ERR_BAD_GAP end
    if not M.parse_min_size(p.min_size_text) then return M.ERR_BAD_MIN_SIZE end
    local session_minutes = M.parse_session_gap(p.session_gap_text)
    if not session_minutes then return M.ERR_BAD_SESSION_GAP end
    if refine and not p.write_tags then return M.NOTICE_TAGS_OFF end
    if not has_layer(p) then return M.NOTICE_NO_LAYER end
    if session_minutes > 0 and not p.write_tags then return M.NOTICE_SESSION_TAGS_OFF end
    return ""
end

-- Clear ------------------------------------------------------------------------

-- True when the image's current native group still holds another member of the
-- ledger group led by `leader`; false when the image was moved or its group is gone.
local function still_in_ledger_group(id, leader, members, ledger)
    for _, m in ipairs(members or {}) do
        local mid = tonumber(m.id)
        if mid ~= id and (mid == leader or (ledger[mid] and ledger[mid].native == leader)) then
            return true
        end
    end
    return false
end

-- The unselected partners Clear takes along: candidates with a ledger entry that share a
-- frame (frame_key: same dir and stem) with a selected record, so a RAW+JPEG pair never
-- ends up half cleared. records and candidates = { id, dir, filename }. Returns the
-- partners sorted by id, each once.
function M.plan_partners(records, candidates, ledger)
    local frames, selected = {}, {}
    for _, r in ipairs(records) do
        selected[r.id] = true
        if r.filename then frames[frame_key(r)] = true end
    end
    local partners = {}
    for _, c in ipairs(candidates) do
        if ledger[c.id] and not selected[c.id] and c.filename and frames[frame_key(c)] then
            selected[c.id] = true
            partners[#partners + 1] = c
        end
    end
    table.sort(partners, function(a, b) return a.id < b.id end)
    return partners
end

-- What Clear grouping marks does to each selected image with a ledger entry:
-- detach = sorted ledger tags still on it, ungroup = whether to take it out of a
-- native group the plugin made. records = { id, tags = set }; members_of[id] = the
-- image's current native group members ({ id }). Hand-made tags and groups are
-- never listed. Returns plans in record order, and restore groups: ungrouped images
-- of one frame (frame_key: same dir and stem; records need `dir` and `filename` to
-- join one) that number 2+ go back into one native group under their lowest id, so
-- Clear doesn't break up a RAW+JPEG pair or duplicates that darktable grouped at
-- import. Restore = { { leader, members = sorted ids } }, sorted by leader.
function M.plan_clear(records, ledger, members_of)
    local plans, by_frame = {}, {}
    for _, r in ipairs(records) do
        local entry = ledger[r.id]
        if entry then
            local detach = {}
            for name in pairs(entry.tags or {}) do
                if r.tags[name] then detach[#detach + 1] = name end
            end
            table.sort(detach)
            local ungroup = entry.native ~= nil
                and still_in_ledger_group(r.id, entry.native, members_of[r.id], ledger)
            plans[#plans + 1] = { id = r.id, detach = detach, ungroup = ungroup }
            if ungroup and r.filename then
                local k = frame_key(r)
                by_frame[k] = by_frame[k] or {}
                table.insert(by_frame[k], r.id)
            end
        end
    end
    local restore = {}
    for _, ids in pairs(by_frame) do
        if #ids >= 2 then
            table.sort(ids)
            restore[#restore + 1] = { leader = ids[1], members = ids }
        end
    end
    table.sort(restore, function(a, b) return a.leader < b.leader end)
    return plans, restore
end

-- Reset to pairs: the native groups that put each frame's files back together
-- (frame_key: same dir and stem, ignoring case), as darktable groups RAW+JPEG
-- pairs and duplicates at import. records = { id, dir, filename }, duplicates by
-- id ignored. Returns { { leader = lowest id, members = sorted ids } } for frames
-- of 2+ files, sorted by leader; every other image ends up alone.
function M.plan_pairs(records)
    local by_frame, seen = {}, {}
    for _, r in ipairs(records) do
        if not seen[r.id] and r.filename then
            seen[r.id] = true
            local k = frame_key(r)
            by_frame[k] = by_frame[k] or {}
            table.insert(by_frame[k], r.id)
        end
    end
    local groups = {}
    for _, ids in pairs(by_frame) do
        if #ids >= 2 then
            table.sort(ids)
            groups[#groups + 1] = { leader = ids[1], members = ids }
        end
    end
    table.sort(groups, function(a, b) return a.leader < b.leader end)
    return groups
end

-- Merge groups: `groups` are the selected images' native groups as member lists
-- ({ id }, with `leader`), repeats allowed. Every image joins the group of the lowest id.
-- Returns { target = lowest id, join = sorted ids outside the target's group,
-- ids = all sorted ids, groups = n distinct groups }.
function M.plan_merge(groups)
    local seen_group, seen, ids, n = {}, {}, {}, 0
    for _, g in ipairs(groups) do
        if not seen_group[g.leader] then
            seen_group[g.leader] = true
            n = n + 1
            for _, m in ipairs(g) do
                if not seen[m.id] then
                    seen[m.id] = g.leader
                    ids[#ids + 1] = m.id
                end
            end
        end
    end
    table.sort(ids)
    local target_group, join = seen[ids[1]], {}
    for _, id in ipairs(ids) do
        if seen[id] ~= target_group then join[#join + 1] = id end
    end
    return { target = ids[1], join = join, ids = ids, groups = n }
end

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

-- One record per darktable image. `dir` + `filename` is what M.collapse
-- pairs RAW+JPEG by; `file` is the full path the helper reads; `img` is the
-- darktable image the tags are written to. `with_tags` false leaves `tags` empty
-- (one darktable query per image saved) for runs that read and write no tags.
local function positive_or_nil(v)
    return type(v) == "number" and v > 0 and v or nil
end

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
            epoch = M.exif_time_to_epoch(taken),
            maker = blank_to_nil(img.exif_maker),
            model = blank_to_nil(img.exif_model),
            lens = blank_to_nil(img.exif_lens),
            focal = positive_or_nil(img.exif_focal_length),
            exposure = positive_or_nil(img.exif_exposure),
            focus = positive_or_nil(img.exif_focus_distance),
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
-- borrow that fraction (M.subsec_fractions), so a RAW+JPEG pair costs one read. With
-- by_camera a third column holds the unit's camera_key, so the helper decides
-- precision per camera.
function M.manifest_rows(units, by_camera)
    local rows = {}
    for _, unit in ipairs(units) do
        local pick
        for _, m in ipairs(unit.members or { unit }) do
            if m.epoch and (pick == nil or (is_jpeg(m) and not is_jpeg(pick))) then pick = m end
        end
        if pick then
            rows[#rows + 1] = by_camera and { pick.id, pick.file, M.camera_key(unit) } or { pick.id, pick.file }
        end
    end
    table.sort(rows, function(a, b) return a[1] < b[1] end)
    return rows
end

-- exif_times.py's results: id (number) → epoch text ("" when unreadable), the run's
-- `#precision` value, and camera_key → precision from its `#precision,<value>,<camera>`
-- rows (a manifest with cameras only).
function M.parse_helper_results(text)
    local by_id, precision, precision_of = {}, nil, {}
    for _, row in ipairs(M.parse_csv(text or "")) do
        if row[1] == "#precision" and row[3] then
            precision_of[row[3]] = row[2]
        elseif row[1] == "#precision" then
            precision = row[2]
        else
            local id = tonumber(row[1])
            if id then by_id[id] = row[2] or "" end
        end
    end
    return by_id, precision, precision_of
end

-- Adds the helper's sub-second fraction to the whole-second epoch of each member of
-- the timed `units`, per timeline: one timeline with by_camera off, one per camera_key
-- with it on. A timeline keeps fractions only when every timed frame on it has one (its
-- own, or borrowed from the JPEG of its RAW+JPEG pair, see M.subsec_fractions) and the
-- helper says `subsecond` for it; otherwise all its frames stay on whole seconds, so no
-- timeline mixes the two. Only the fraction is taken: the helper's whole part (timegm)
-- and the core's (os.time) can differ by the local offset. Returns "subsecond", "whole"
-- or "mixed" (some cameras on whole seconds), why for "whole", and whole_of: the
-- timeline's camera_key ("" with by_camera off) → why, for each timeline on whole seconds.
function M.apply_subsec(units, text, by_camera)
    local lines, keys = {}, {}
    for _, unit in ipairs(units) do
        if unit.epoch then
            local k = by_camera and M.camera_key(unit) or ""
            if not lines[k] then lines[k] = {}; keys[#keys + 1] = k end
            table.insert(lines[k], unit)
        end
    end
    if #keys == 0 then return "whole", "no frame has a capture time", {} end
    table.sort(keys)
    local by_id, precision, precision_of = M.parse_helper_results(text)
    local whole_of = {}
    for _, k in ipairs(keys) do
        local records = M.members_of(lines[k])
        local frac_of, missing = M.subsec_fractions(records, by_id)
        if missing then
            local lacking = 0
            for _, unit in ipairs(lines[k]) do
                for _, m in ipairs(unit.members or { unit }) do
                    if m.epoch and not frac_of[m.id] then lacking = lacking + 1; break end
                end
            end
            whole_of[k] = string.format("%d of %d frames had none", lacking, #lines[k])
        elseif (by_camera and precision_of[k] or precision) ~= "subsecond" then
            whole_of[k] = "the helper reported whole-second precision"
        else
            for _, r in ipairs(records) do
                if r.epoch and frac_of[r.id] then r.epoch = r.epoch + frac_of[r.id] end
            end
        end
    end
    local n_whole = 0
    for _ in pairs(whole_of) do n_whole = n_whole + 1 end
    if n_whole == 0 then return "subsecond", nil, whole_of end
    if n_whole < #keys then return "mixed", nil, whole_of end
    return "whole", #keys == 1 and whole_of[keys[1]] or "no camera had sub-second time on every frame", whole_of
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
        local add, remove = M.plan_replace(r.tags, mine, wanted[r.id] or {})
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
-- never merge. Written in UTC, so string order is time order across DST changes.
function M.run_stamp(now, last_time)
    local t = (last_time and now <= last_time) and last_time + 1 or now
    return os.date("!%Y-%m-%d %H:%M:%S", t), t
end

-- Shared with culling and tagging (plugin_common.lua); re-exported for the tests.
M.write_file_atomic, M.read_file_or_tmp, M.pythonw_of = C.write_file_atomic, C.read_file_or_tmp, C.pythonw_of
for name, fn in pairs(C) do
    if type(name) == "string" and name:match("^preset_") then M[name] = fn end
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
local WRITE_PAUSE_MAX_MS = 300 -- Clear pauses as long as darktable took to catch up, at most this
-- exif_times.py reports no progress, so a run that hasn't finished in this long is
-- given up on and the run uses whole seconds.
local HELPER_TIMEOUT_SECONDS = 600

local IS_WINDOWS = C.IS_WINDOWS
local TMP_DIR = dt.configuration.tmp_dir
-- Leftovers of a darktable that crashed or was killed mid-run; a day old is surely not live.
C.sweep_temp(TMP_DIR, "dt_assisted_grouping_", 86400)
local LOG_PATH = dt.configuration.config_dir .. "/assisted_grouping.log"
-- The 5 runs before the current one are kept as .prev.log, .prev2.log to .prev5.log.
local LOGS_KEPT = 5
-- Lua errors (panel build, callbacks, events) go to their own log, which runs never rotate.
local LUA_LOG_PATH = dt.configuration.config_dir .. "/assisted_grouping.lua.log"
local guard = C.error_guard(dt, LUA_LOG_PATH, "Assisted Grouping")
local new_widget = C.guarded_widget_maker(dt, guard)
local LEDGER_DIR = dt.configuration.config_dir .. "/assisted_grouping"
local LEDGER_PATH = LEDGER_DIR .. "/ledger.csv"
local LIB_KEY = C.library_key(dt)

if dt.gui then
    C.register_shared_prefs(dt)
end

M.tags_of = function(img)
    local have = {}
    for _, t in ipairs(tags.get_tags(img)) do have[t.name] = true end
    return have
end

local file_exists, first_existing, read_file, shell_quote =
    C.file_exists, C.first_existing, C.read_file, C.shell_quote

local function make_dir(dir)
    if IS_WINDOWS then
        os.execute(string.format('mkdir "%s" 2>nul', dir:gsub("/", "\\")))
    else
        os.execute("mkdir -p " .. shell_quote(dir) .. " 2>/dev/null")
    end
end

-- Every line reaches disk at once: the helper writes its stderr to its own file, never to this log.
local run_log = C.run_log(LOG_PATH)
local log, flush_log = run_log.log, run_log.flush

local function say(msg)
    dt.print(msg)
    log(msg)
end

-- the "To check" box at the foot of the panel; `fixes` is filled once the actions exist
local fixes = {}
local alerts = C.alerts_box(new_widget, dt.configuration.config_dir .. "/assisted_grouping.checks.txt", log, fixes)

-- dt.print_error only writes to darktable's log (-d lua); users never see it. Errors also go to To check.
local function notify_error(msg)
    dt.print(msg)
    dt.print_error(msg)
    log(msg)
    alerts.add((msg:gsub("^Assisted Grouping: ", "")))
end

local ACTION_NAMES = { group = "Group", verify = "Verify selection", clear = "Clear", pairs = "Reset to pairs", bursts = "Browse as bursts", merge = "Merge groups" }

-- `what` names the job in the header: "group", "verify" or "clear". The action's earlier To check items go.
local function start_log(what, n)
    alerts.begin(ACTION_NAMES[what])
    flush_log()
    run_log.rotate(LOGS_KEPT)
    log(string.format("%s started: darktable %s, %d images", what, tostring(dt.configuration.version), n))
end

local function plugin_folder_pref()
    return C.plugin_folder(dt, "assisted_grouping", "darktable-assisted-grouping", log)
end

-- From the plugin folder preference alone when it's set; a wrong folder is an
-- error rather than a quiet switch to some other copy.
local function helper_script()
    local folder = plugin_folder_pref()
    if folder ~= "" then
        local script = folder .. "/python/exif_times.py"
        if not file_exists(script) then
            error(string.format("Assisted Grouping: the plugins folder preference gives %s, which has no python/exif_times.py. Point it at the folder holding darktable-assisted-grouping, or clear it to auto-detect.", folder), 0)
        end
        return script
    end
    local found = first_existing({
        THIS_DIR .. "/exif_times.py",
        THIS_DIR .. "/python/exif_times.py",
        THIS_DIR .. "/../python/exif_times.py",
        THIS_DIR .. "/../../python/exif_times.py",
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
    local root = plugin_root(script)
    local found = first_existing({
        root .. "/.venv/Scripts/python.exe",
        root .. "/.venv/bin/python",
        THIS_DIR .. "/../.venv/Scripts/python.exe",
        THIS_DIR .. "/../.venv/bin/python",
    })
    if found then return found end

    local v = df.check_if_bin_exists(IS_WINDOWS and "python" or "python3")
    if not v then
        v = IS_WINDOWS and "python" or "python3"
    end
    return v
end

local command_line, run_async_python = C.command_line, C.run_async_python

-- One run at a time.
local busy = false
-- The time the last run's stamp stands for, this session.
local last_stamp_time = nil
-- Jobs clicked while another runs: { label, run }, oldest first.
local queue = {}
-- Set by install_panel. Re-setting its label is a GUI call that waits until darktable has
-- processed every write queued before it.
local clear_button = nil

-- A helper call's temp files. Each call gets its own names, so a helper still
-- running after its run was cancelled or timed out can't touch the next run's files.
local function new_run_paths()
    local base = C.temp_base(TMP_DIR, "dt_assisted_grouping_")
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
    run_log.append_lines(read_file(p.stderr))
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

-- Puts `what` on darktable's job list and says it has started, before the action's first read of
-- the selection, so a click on a large selection shows at once. Only a job that checks
-- M.cancel_requested is `cancellable`; the others get no cancel button.
local function start_job(what, n, cancellable)
    local job = dt.gui.create_job("Assisted Grouping: " .. what, true, cancellable and stop_job or nil)
    job.percent = 0.0
    say(string.format("Assisted Grouping: %s started on %s…", what, n == 1 and "1 image" or n .. " images"))
    return job
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
    for _, r in ipairs(rows) do f:write(M.csv_line(r), "\n") end
    f:close()
    return true
end

-- Runs exif_times.py on one file per unit and blocks until it exits. Returns the
-- results text, or nil plus "cancelled" or a reason the run falls back to whole
-- seconds. A helper still running at a cancel or the timeout keeps its temp files;
-- the next run uses new names, so it needn't wait.
local function read_helper_times(units, by_camera, job)
    local rows = M.manifest_rows(units, by_camera)
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
    return M.ledger_parse(M.read_file_or_tmp(LEDGER_PATH), LIB_KEY)
end

-- Whether image `id` is still in the library. A get_image error counts as gone, as does a
-- stale image whose fields can't be read; ledger_prune skips the prune when nothing resolves.
local function image_exists(id)
    local ok, name = pcall(function()
        local img = dt.database.get_image(id)
        return img and img.filename
    end)
    return ok and name ~= nil
end

-- Writes the ledger of the tags and native groups this plugin made, first dropping the
-- rows of images no longer in the library and re-pointing groups whose leader is gone.
-- A failed write is tried once more.
local function write_ledger(ledger)
    local pruned, skipped = M.ledger_prune(ledger, image_exists)
    if pruned > 0 then log(string.format("ledger: dropped %d images no longer in the library", pruned)) end
    if skipped then
        log("ledger: prune skipped, no image id resolved")
    else
        local repointed = M.repoint_stale_leaders(ledger, image_exists)
        if repointed > 0 then log(string.format("ledger: %d groups had a leader no longer in the library; re-pointed to their lowest id", repointed)) end
    end
    make_dir(LEDGER_DIR)
    local text = M.ledger_format(ledger, LIB_KEY)
    local ok_w, err = M.write_file_atomic(LEDGER_PATH, text)
    if not ok_w then
        dt.control.sleep(200)
        ok_w, err = M.write_file_atomic(LEDGER_PATH, text)
    end
    if not ok_w then
        log("ledger: couldn't save " .. LEDGER_PATH .. " after two tries: " .. tostring(err))
        notify_error(string.format("Assisted Grouping: couldn't save the ledger %s (%s). Tags and groups this run made will count as yours next run.",
            LEDGER_PATH, tostring(err)))
    end
end

-- Syncs each image's group tags to `wanted`. Sets run.applying before the first write
-- and updates run.ledger per image, so the caller can save the ledger even when this
-- stops or errors partway.
local function apply_tags(run, records, wanted, job, progress)
    local ledger = run.ledger
    local tag_objs = {}
    local w = C.paced_writer(dt, WRITE_BUDGET, WRITE_SLEEP_MS, log)
    local n_added, n_removed = 0, 0
    local function tag_named(name)
        tag_objs[name] = tag_objs[name] or tags.create(name)
        return tag_objs[name]
    end

    run.applying = true
    local plans = M.plan_tag_changes(records, wanted, ledger)
    for i, plan in ipairs(plans) do
        local r, mine = plan.record, plan.mine
        w.write(function()
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
        end, #plan.add + #plan.remove, string.format("image %d (%s): write group tags", r.id, r.filename))
        M.set_ledger_tags(ledger, r.id, mine)
        progress(i / #plans)
        if not job.valid then
            say(string.format("Assisted Grouping: stopped while writing tags; %d of %d images were updated. Run again to finish.",
                i, #records))
            return false
        end
    end
    log(string.format("tags: %d attached, %d detached", n_added, n_removed))
    log(string.format("tags: timing: %.1fs in tag calls (database, undo, sidecar), %d pauses of %d ms",
        w.call_s, w.sleeps, WRITE_SLEEP_MS))
    if w.failed > 0 then
        notify_error(string.format("Assisted Grouping: couldn't write tags on %d images: %s", w.failed, w.first_error))
    end
    return true
end

-- The images in `img`'s darktable group as { id, dir, filename, img } records, itself included.
-- `broken` is set when the group's leader is missing or not among them.
-- `cache` is keyed by group leader, so each group is read from darktable once.
local function group_members(img, cache)
    local leader = img.group_leader
    local key = tonumber(leader and leader.id or img.id)
    if not cache[key] then
        local list = { leader = key, broken = not leader }
        local found = false
        for _, other in ipairs(img:get_group_members()) do
            list[#list + 1] = { id = tonumber(other.id), dir = other.path, filename = other.filename, img = other }
            found = found or list[#list].id == key
        end
        list.broken = list.broken or not found
        cache[key] = list
    end
    return cache[key]
end

-- id -> darktable image and id -> its group's members (group_members), for every image of `units`.
local function read_members(units)
    local img_of, members_of, group_cache = {}, {}, {}
    for _, unit in ipairs(units) do
        for _, m in ipairs(unit.members) do
            img_of[m.id] = m.img
            members_of[m.id] = group_members(m.img, group_cache)
        end
    end
    return img_of, members_of
end

-- `ids` with group leaders moved to the end. Taking a leader out makes darktable rewrite every
-- image left in its group, so leader-first costs the group size squared.
local function leaders_last(ids, img_of)
    local followers, leaders = {}, {}
    for _, id in ipairs(ids) do
        local leader = img_of[id].group_leader
        if leader and tonumber(leader.id) ~= id then
            followers[#followers + 1] = id
        else
            leaders[#leaders + 1] = id
        end
    end
    for _, id in ipairs(leaders) do followers[#followers + 1] = id end
    return followers
end

-- Writes one native group per final group of 2+ images, led by its lowest id.
-- Every image is detached into its own group before any attach: `group_with` on an
-- image still in an old group would scatter it. Updates the ledger per image, so a
-- partial failure still leaves it accurate.
-- `progress(fraction)` is called as the work advances: detaching is the first half, attaching the second.
function M.apply_native_groups(units, final_of, ledger, progress)
    local img_of, members_of = read_members(units)
    local plan = M.plan_native(units, final_of, ledger, members_of)
    local w = C.paced_writer(dt, WRITE_BUDGET, WRITE_SLEEP_MS, log)
    local write, grouped = w.write, 0

    local detached = {}
    for i, id in ipairs(leaders_last(plan.detach, img_of)) do
        -- No leader argument: darktable moves the image into a group of its own.
        if write(function() img_of[id]:group_with() end, 1, string.format("image %d (%s): take out of its darktable group", id, img_of[id].filename)) then
            detached[id] = true
            M.set_ledger_native(ledger, id, nil)
        end
        if progress then progress(0.5 * i / #plan.detach) end
    end
    for g, group in ipairs(plan.groups) do
        local leader = group.leader
        if detached[leader] then
            local attached = 0
            for _, id in ipairs(group.members) do
                if id ~= leader and detached[id]
                    and write(function() img_of[id]:group_with(img_of[leader]) end, 1, string.format("image %d (%s): group with image %d", id, img_of[id].filename, leader)) then
                    M.set_ledger_native(ledger, id, leader)
                    attached = attached + 1
                end
            end
            if attached > 0 then
                M.set_ledger_native(ledger, leader, leader)
                grouped = grouped + attached + 1
            end
        end
        if progress then progress(0.5 + 0.5 * g / #plan.groups) end
    end
    log(string.format("native groups: timing: %.1fs in darktable calls, %d pauses of %d ms", w.call_s, w.sleeps, WRITE_SLEEP_MS))
    if w.failed > 0 then
        notify_error(string.format("Assisted Grouping: %d native group changes failed: %s", w.failed, w.first_error))
    end
    return { grouped = grouped, skipped = plan.skipped, unchanged = plan.unchanged }
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
    local key_of, n = M.parent_key(parent), 0
    for _, unit in ipairs(units) do
        if key_of(unit) == nil then n = n + 1 end
    end
    return n
end

-- The end of every job: saves `ledger` (nil for nothing to save), closes the job bar and
-- clears busy. A step that raises is reported and the rest still run.
local function finish_job(job, ledger)
    local ok_l, err_l = true, nil
    if ledger then ok_l, err_l = pcall(write_ledger, ledger) end
    local ok_j, err_j = pcall(end_job, job)
    busy = false
    if not ok_l then
        notify_error("Assisted Grouping: couldn't save the ledger: " .. tostring(err_l)
            .. ". Tags and groups this run made will count as yours next run.")
    end
    if not ok_j then notify_error("Assisted Grouping: couldn't close the job bar: " .. tostring(err_j)) end
end

-- opts = { timing, gap, min_frames, session_gap, camera, tag, parent, refine, write_tags, trace_tags,
-- native_groups }, as M.panel_options returns them. With `verify` set, the run writes nothing and
-- puts what a real run would change in To check (M.plan_verify).
function M.group_images(images, opts)
    if busy then
        dt.print("Assisted Grouping: another job is still running. Wait for it to finish, or cancel it first.")
        return
    end
    if not opts.write_tags and not opts.native_groups then
        dt.print("Assisted Grouping: " .. M.ERR_NO_OUTPUT)
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
    start_log(opts.verify and "verify" or "group", #images)
    log(string.format("run stamp %s; timing %s, gap %s s, min frames %s, session gap %s s, camera %s, tag %s, parent %s, refine %s, tags %s, native groups %s",
        stamp, tostring(opts.timing ~= false), tostring(opts.gap), tostring(opts.min_frames), tostring(opts.session_gap),
        tostring(opts.camera), tostring(opts.tag), tostring(opts.parent),
        tostring(opts.refine), tostring(opts.write_tags), tostring(opts.native_groups)))

    local job, run = nil, { ledger = nil, applying = false }
    local run_began = os.time()
    local okr, err = C.logged_call(log, "group selection", function()
        job = start_job(opts.verify and "Verify selection" or "Group selection", #images, true)
        local records = M.build_images(images, M.needs_tags(opts))
        local units = M.collapse(records)
        local layer_opts = { gap = opts.gap, timing = opts.timing, camera = opts.camera, tag = opts.tag,
            parent = opts.parent, trace = opts.trace_tags, min_frames = opts.min_frames,
            session_gap = opts.write_tags and opts.session_gap or nil }
        if opts.refine then layer_opts.base_of = M.base_of_from_tags(units) end

        -- Only frames the burst layer times need the helper.
        local to_time = M.units_to_time(units, opts.timing, layer_opts.base_of)
        local precision, whole_of = "whole", nil
        if opts.timing == false then
            log("timing: off, capture times not read")
        elseif #to_time == 0 then
            log("timing: not needed (every frame has a group tag or no capture time)")
        else
            local text, why = read_helper_times(to_time, opts.camera, job)
            flush_log()
            if why == "cancelled" then
                say("Assisted Grouping: cancelled, nothing was changed.")
                return
            end
            local reason = why
            if text then precision, reason, whole_of = M.apply_subsec(to_time, text, opts.camera) end
            if opts.camera and precision ~= "subsecond" then
                local cameras = {}
                for k in pairs(whole_of or {}) do cameras[#cameras + 1] = k end
                table.sort(cameras)
                for _, k in ipairs(cameras) do
                    log(string.format("Sub-second time off for %s (%s)", k ~= "" and k or "an unnamed camera", whole_of[k]))
                end
            end
            if precision == "subsecond" or precision == "mixed" then
                log(precision == "subsecond" and "timing: sub-second" or "timing: sub-second, except the cameras above")
                units = M.collapse(records) -- unit epochs are copied from members at collapse
            else
                log("timing: whole seconds for the whole run (" .. tostring(reason) .. ")")
            end
        end
        job.percent = 0.5

        layer_opts.whole_seconds = precision == "mixed" and whole_of or precision ~= "subsecond"
        local result = M.run_layers(units, layer_opts)
        if result.gap_how then
            log(string.format("auto gap %.2g s (%s)", result.gap, result.gap_how))
        end
        local wanted = M.wanted_tags(units, result, stamp, layer_opts)
        log(string.format("%d frames in %d groups (%d %s)", #units, count_groups(result.final_of),
            count_groups(result.burst_of), result.timing and "bursts" or "starting groups, timing off"))
        if result.min_of then
            log(string.format("minimum burst size %d: %d smaller groups left as single frames",
                opts.min_frames, result.dissolved))
        end
        if result.session_of then
            log(string.format("sessions: %d (a new one after a gap above %.14g minutes)",
                count_groups(result.session_of), opts.session_gap / 60))
        end
        local links = M.weakest_links(units, result.final_of)
        if #links > 0 then
            log(string.format("weakest links: largest time gap inside each of %d groups, widest first (top %d)",
                #links, math.min(#links, M.WEAKEST_LINKS_LOGGED)))
            for i = 1, math.min(#links, M.WEAKEST_LINKS_LOGGED) do
                local link = links[i]
                log(string.format("  group %04d: %d frames, %.2f s before %s",
                    link.group, link.frames, link.gap, link.after.members[1].filename))
            end
        end
        local hints = M.cut_hints(units, result.final_of)
        if #hints > 0 then
            log(string.format("cut hints: %d places inside a group where a lens or exposure setting jumps (first %d)",
                #hints, math.min(#hints, M.CUT_HINTS_LOGGED)))
            for i = 1, math.min(#hints, M.CUT_HINTS_LOGGED) do
                local hint = hints[i]
                log(string.format("  group %04d before %s: %s",
                    hint.group, hint.after.members[1].filename, table.concat(hint.jumps, "; ")))
            end
        end
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
            or precision == "subsecond" and "sub-second timing"
            or precision == "mixed" and "sub-second timing, some cameras whole seconds" or "whole-second timing"

        -- Groups need the whole selection, so a cancelled run writes nothing.
        if cancelled(job) then
            say("Assisted Grouping: cancelled, nothing was changed.")
            return
        end
        if opts.verify then
            local _, members_of = read_members(units)
            local found = M.plan_verify(units, result.final_of, read_ledger(), members_of, opts)
            local fresh_ids, fresh_why, broken_why, filename_of = {}, {}, {}, {}
            for _, f in ipairs(found.fresh) do
                for _, m in ipairs(f.unit.members) do fresh_ids[#fresh_ids + 1] = m.id end
                fresh_why[#fresh_why + 1] = f.unit.members[1].filename .. ": " .. table.concat(f.reasons, "; ")
            end
            for _, r in ipairs(records) do filename_of[r.id] = r.filename end
            for _, id in ipairs(found.broken) do broken_why[#broken_why + 1] = filename_of[id] .. ": no leader inside its group" end
            say(string.format("Assisted Grouping: verify only, nothing changed. %d of %d images differ from a fresh Group selection run, %d are in a group with no leader inside it.",
                #fresh_ids, #records, #found.broken))
            if #fresh_ids > 0 then
                alerts.add(string.format("%d photos differ from a fresh Group selection run with these settings. Fix runs Group selection on them.",
                    #fresh_ids), fresh_ids, "group", fresh_why)
            end
            if #found.broken > 0 then
                alerts.add(string.format("%d photos are in a darktable group whose leader is missing or outside it. Fix makes the group's lowest image its leader.",
                    #found.broken), found.broken, "leader", broken_why)
            end
            return
        end
        run.ledger = read_ledger()
        -- The job bar's second half is the writes: tags, then darktable groups.
        local tags_share = not opts.write_tags and 0 or opts.native_groups and 0.25 or 0.5
        if opts.write_tags then
            log("tags: started")
            flush_log()
            local tags_began = os.time()
            local tags_done = apply_tags(run, records, wanted, job, function(fraction)
                if job.valid then job.percent = 0.5 + tags_share * fraction end
            end)
            log(string.format("tags: %s, %ds", tags_done and "done" or "stopped", os.time() - tags_began))
            if not tags_done then return end
        end
        if opts.native_groups then
            run.applying = true
            -- Cancel is ignored from here on: half-built native groups are worse than finishing.
            log("native groups: started; a cancel from now on is ignored so no group is left half-built")
            flush_log()
            local native_began = os.time()
            local counts = M.apply_native_groups(units, result.final_of, run.ledger, function(fraction)
                if job.valid then job.percent = 0.5 + tags_share + (0.5 - tags_share) * fraction end
            end)
            log(string.format("native groups: %d images grouped, %d left as they were (already grouped this way), %d skipped (already in a hand-made group)",
                counts.grouped, counts.unchanged, counts.skipped))
            log(string.format("native groups: done, %ds", os.time() - native_began))
        end
        say(string.format("Assisted Grouping: done. %d images in %d groups (%s). Run %s.%s",
            #records, count_groups(result.final_of), timing_label, stamp, note))
    end)

    -- Saved once anything may have changed, even if the apply stopped or errored partway,
    -- so what this run made isn't mistaken for the user's next time.
    finish_job(job, run.applying and run.ledger or nil)
    if not okr then notify_error("Assisted Grouping: couldn't run. " .. tostring(err)) end
    log(string.format("run finished, %ds in total", os.time() - run_began))
    flush_log()
    run_next()
end

-- Detaches the ledger's tags and takes images out of the ledger's native groups for
-- the selection and its unselected RAW/JPEG partners (M.plan_partners), then drops their
-- ledger rows. Hand-made tags and groups stay. A
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
    M.cancel_requested = false
    start_log("clear", #images)
    local job, ledger, changed = nil, nil, false
    local okr, err = C.logged_call(log, "clearing marks", function()
        job = start_job("Clear grouping marks", #images, true)
        ledger = read_ledger()
        local selected, films = {}, {}
        for _, img in ipairs(images) do
            selected[#selected + 1] = { id = tonumber(img.id), img = img, dir = img.path, filename = img.filename }
            local okf, film = pcall(function() return img.film end)
            if okf and film then films[film.id] = film end
        end
        -- Only images the ledger lists can be partners, so the film rolls are read by id first.
        local candidates = {}
        for _, film in pairs(films) do
            local okr = pcall(function()
                for i = 1, #film do
                    local img = film[i]
                    local id = tonumber(img.id)
                    if ledger[id] then candidates[#candidates + 1] = { id = id, img = img, dir = img.path, filename = img.filename } end
                end
            end)
            if not okr then log("clear: couldn't read film roll " .. tostring(film.path) .. "; its unselected RAW/JPEG partners keep their marks") end
        end
        local partners = M.plan_partners(selected, candidates, ledger)
        for _, p in ipairs(partners) do selected[#selected + 1] = p end
        local records, members_of, group_cache = {}, {}, {}
        for _, s in ipairs(selected) do
            if ledger[s.id] then
                records[#records + 1] = { id = s.id, img = s.img, tags = M.tags_of(s.img), dir = s.dir, filename = s.filename }
                members_of[s.id] = group_members(s.img, group_cache)
            end
        end
        if #partners > 0 then log(string.format("clear: %d unselected RAW/JPEG partners of the selection included", #partners)) end
        if #records == 0 then
            say("Assisted Grouping: nothing to clear; the selection has no grouping marks.")
            return
        end

        local img_of = {}
        for _, r in ipairs(records) do img_of[r.id] = r.img end
        local w = C.paced_writer(dt, WRITE_BUDGET, WRITE_SLEEP_MS, log)
        local write, n_tags, n_ungrouped = w.write, 0, 0

        changed = true
        local plans, restore = M.plan_clear(records, ledger, members_of)
        local plan_of, plan_ids = {}, {}
        for _, plan in ipairs(plans) do
            plan_of[plan.id] = plan
            plan_ids[#plan_ids + 1] = plan.id
        end
        flush_log()
        -- Clearing is the first 80% of the job bar, restoring the frame groups the rest.
        -- Each write makes darktable rebuild its tagging lists. After each image the run waits
        -- for darktable to catch up, then pauses as long again, so the backlog can't grow over
        -- thousands of images. A cancel still restores the frame groups of the images reached.
        local ungrouped, reached, stopped = {}, 0, false
        local wait_s, pause_s, started = 0, 0, os.time()
        local order = leaders_last(plan_ids, img_of)
        for i, id in ipairs(order) do
            if cancelled(job) then
                stopped = true
                break
            end
            local plan = plan_of[id]
            local entry, img = ledger[plan.id], img_of[plan.id]
            local left = {}
            for _, name in ipairs(plan.detach) do
                local tag = tags.find(name)
                if tag and write(function() tags.detach(tag, img) end, 1, string.format("image %d (%s): detach tag %s", plan.id, img.filename, name)) then
                    n_tags = n_tags + 1
                elseif tag then
                    left[name] = true
                end
            end
            local native = nil
            if plan.ungroup then
                -- No leader argument: darktable moves the image into a group of its own.
                if write(function() img:group_with() end, 1, string.format("image %d (%s): take out of its darktable group", plan.id, img.filename)) then
                    n_ungrouped = n_ungrouped + 1
                    ungrouped[plan.id] = true
                else
                    native = entry.native
                end
            end
            M.set_ledger_tags(ledger, plan.id, left)
            M.set_ledger_native(ledger, plan.id, native)
            reached = i
            if (#plan.detach > 0 or plan.ungroup) and clear_button then
                local wait_start = os.clock()
                clear_button.label = clear_button.label
                local waited_s = os.clock() - wait_start
                local pause_ms = math.max(WRITE_SLEEP_MS, math.min(WRITE_PAUSE_MAX_MS, math.floor(waited_s * 1000)))
                dt.control.sleep(pause_ms)
                wait_s, pause_s = wait_s + waited_s, pause_s + pause_ms / 1000
            end
            job.percent = 0.8 * i / #plans
        end
        -- Every image above was detached into a group of its own before any attach here,
        -- so re-forming a frame's group can't pull a leader out of another group.
        -- These are darktable's import groups, not the plugin's, so the ledger skips them.
        local n_restored = 0
        for g, group in ipairs(restore) do
            local ok_ids = {}
            for _, id in ipairs(group.members) do
                if ungrouped[id] then ok_ids[#ok_ids + 1] = id end
            end
            if #ok_ids >= 2 then
                local leader = img_of[ok_ids[1]]
                for i = 2, #ok_ids do
                    write(function() img_of[ok_ids[i]]:group_with(leader) end, 1, string.format("image %d (%s): group with image %d", ok_ids[i], img_of[ok_ids[i]].filename, ok_ids[1]))
                end
                n_restored = n_restored + 1
            end
            job.percent = 0.8 + 0.2 * g / #restore
        end
        log(string.format("clear: %d images, %d tags detached, %d taken out of native groups, %d frame groups restored, %d failed",
            #records, n_tags, n_ungrouped, n_restored, w.failed))
        log(string.format("clear: timing: %d of %d images in %ds; %.1fs in darktable calls, %.1fs waiting for darktable, %.1fs paused, %d pauses of %d ms%s",
            reached, #plans, os.time() - started, w.call_s, wait_s, pause_s, w.sleeps, WRITE_SLEEP_MS,
            stopped and ", stopped at the job bar" or ""))
        if stopped then
            say(string.format("Assisted Grouping: clear cancelled. Cleared grouping marks from %d of %d images%s; %d not reached keep their marks.",
                reached, #plans, w.failed > 0 and (", " .. w.failed .. " marks couldn't be cleared") or "", #plans - reached))
            local unreached = {}
            for i = reached + 1, #order do unreached[#unreached + 1] = order[i] end
            alerts.add(string.format("clear cancelled: %d photos not reached keep their marks", #unreached), unreached)
        elseif w.failed > 0 then
            notify_error(string.format("Assisted Grouping: cleared grouping marks from %d images, but %d marks couldn't be cleared (%s). Clear again to retry.",
                #records, w.failed, w.first_error))
        else
            say(string.format("Assisted Grouping: cleared grouping marks from %d images%s.", #records,
                #partners > 0 and string.format(", %d of them unselected RAW/JPEG partners", #partners) or ""))
        end
    end)

    finish_job(job, changed and ledger or nil)
    if not okr then notify_error("Assisted Grouping: clearing marks failed. " .. tostring(err)) end
    flush_log()
    run_next()
end

-- Reset to RAW+JPEG pairs: takes the selection, and everything grouped with it, out
-- of its darktable groups, then groups each frame's files again (M.plan_pairs).
-- Group tags stay, so the plugin's groups come back with Group selection.
-- Hand-made groups are reset too. The ledger forgets the plugin's native groups here.
function M.reset_to_pairs(images)
    if busy then
        dt.print("Assisted Grouping: another job is still running. Wait for it to finish, or cancel it first.")
        return
    end
    if not images or #images == 0 then
        dt.print("Assisted Grouping: select some images first")
        return
    end
    busy = true
    local job, ledger, changed = nil, nil, false
    local okr, err = C.logged_call(log, "reset to pairs", function()
        job = start_job("Reset to RAW+JPEG pairs", #images)
        local records, img_of, group_cache = {}, {}, {}
        for _, img in ipairs(images) do
            for _, member in ipairs(group_members(img, group_cache)) do
                if not img_of[member.id] then
                    img_of[member.id] = member.img
                    records[#records + 1] = { id = member.id, dir = member.dir, filename = member.filename }
                end
            end
        end
        start_log("pairs", #records)
        if #records > #images then
            say(string.format("Assisted Grouping: the selection's groups hold %d images; resetting all of them.", #records))
        end
        flush_log()
        ledger = read_ledger()

        local w = C.paced_writer(dt, WRITE_BUDGET, WRITE_SLEEP_MS, log)
        local write = w.write

        local record_ids = {}
        for _, r in ipairs(records) do record_ids[#record_ids + 1] = r.id end

        -- Every image is detached before any attach, so no leader is pulled out of a group mid-way.
        -- The detach pass is the first half of the job bar, the attach pass the second.
        local alone = {}
        for i, id in ipairs(leaders_last(record_ids, img_of)) do
            if write(function() img_of[id]:group_with() end, 1, string.format("image %d (%s): take out of its darktable group", id, img_of[id].filename)) then
                alone[id] = true
                if ledger[id] and ledger[id].native then
                    M.set_ledger_native(ledger, id, nil)
                    changed = true
                end
            end
            job.percent = 0.5 * i / #records
        end
        local n_pairs = 0
        local groups = M.plan_pairs(records)
        for g, group in ipairs(groups) do
            local ok_ids = {}
            for _, id in ipairs(group.members) do
                if alone[id] then ok_ids[#ok_ids + 1] = id end
            end
            if #ok_ids >= 2 then
                local leader = img_of[ok_ids[1]]
                for i = 2, #ok_ids do
                    write(function() img_of[ok_ids[i]]:group_with(leader) end, 1, string.format("image %d (%s): group with image %d", ok_ids[i], img_of[ok_ids[i]].filename, ok_ids[1]))
                end
                n_pairs = n_pairs + 1
            end
            job.percent = 0.5 + 0.5 * g / #groups
        end
        log(string.format("pairs: %d images ungrouped, %d frame groups made, %d failed",
            #records, n_pairs, w.failed))
        log(string.format("pairs: timing: %.1fs in darktable calls, %d pauses of %d ms", w.call_s, w.sleeps, WRITE_SLEEP_MS))
        if w.failed > 0 then
            notify_error(string.format("Assisted Grouping: reset %d images to %d RAW+JPEG pairs, but %d group changes failed (%s). Reset again to retry. Tags kept.",
                #records, n_pairs, w.failed, w.first_error))
        else
            say(string.format("Assisted Grouping: reset %d images to %d RAW+JPEG pairs. Tags kept.", #records, n_pairs))
        end
    end)

    finish_job(job, changed and ledger or nil)
    if not okr then notify_error("Assisted Grouping: reset to pairs failed. " .. tostring(err)) end
    flush_log()
    run_next()
end

-- Browse as bursts: regroups the selection from its group tags alone. Each tagged
-- group becomes one native group and every untagged frame stays alone. Nothing is
-- timed and no tags are written.
function M.browse_bursts(images)
    if busy then
        dt.print("Assisted Grouping: another job is still running. Wait for it to finish, or cancel it first.")
        return
    end
    if not images or #images == 0 then
        dt.print("Assisted Grouping: select some images first")
        return
    end
    busy = true
    local job, ledger, changed = nil, nil, false
    local okr, err = C.logged_call(log, "browse as bursts", function()
        job = start_job("Browse as bursts", #images)
        local records = M.build_images(images, true)
        local units = M.collapse(records)
        local base_of = M.base_of_from_tags(units)
        start_log("bursts", #records)
        flush_log()
        if next(base_of) == nil then
            say("Assisted Grouping: nothing to browse. The selection has no group tags; run Group selection with Group tags on first.")
            return
        end
        local result = M.run_layers(units, { alone = true, base_of = base_of })
        local untagged = 0
        for _, unit in ipairs(units) do
            if base_of[unit.id] == nil then untagged = untagged + 1 end
        end
        ledger = read_ledger()
        changed = true
        local counts = M.apply_native_groups(units, result.final_of, ledger, function(fraction)
            job.percent = fraction
        end)
        log(string.format("bursts: %d images in %d groups, %d frames without a group tag, %d skipped (already in a hand-made group)",
            #records, count_groups(result.final_of), untagged, counts.skipped))
        local msg = string.format("Assisted Grouping: browsing %d images as %d bursts from their group tags.",
            #records, count_groups(result.final_of))
        if untagged > 0 then msg = msg .. string.format(" %d frames have no group tag and stay alone.", untagged) end
        say(msg)
    end)

    finish_job(job, changed and ledger or nil)
    if not okr then notify_error("Assisted Grouping: browse as bursts failed. " .. tostring(err)) end
    flush_log()
    run_next()
end

-- Merge groups: joins the darktable groups of the selected images into one. The merged
-- images leave the ledger's native groups (tags stay), so the merge counts as made by
-- hand: Group selection keeps it and Clear leaves it.
function M.merge_groups(images)
    if busy then
        dt.print("Assisted Grouping: another job is still running. Wait for it to finish, or cancel it first.")
        return
    end
    if not images or #images == 0 then
        dt.print("Assisted Grouping: select some images first")
        return
    end
    busy = true
    local job, ledger, changed = nil, nil, false
    local okr, err = C.logged_call(log, "merge groups", function()
        local groups, img_of, group_cache = {}, {}, {}
        for _, img in ipairs(images) do
            local members = group_members(img, group_cache)
            groups[#groups + 1] = members
            for _, member in ipairs(members) do img_of[member.id] = member.img end
        end
        local plan = M.plan_merge(groups)
        if plan.groups < 2 then
            say("Assisted Grouping: nothing to merge. Select images from two or more groups.")
            return
        end
        job = start_job("Merge groups", #plan.join)
        start_log("merge", #plan.ids)
        flush_log()
        ledger = read_ledger()
        changed = true

        local w = C.paced_writer(dt, WRITE_BUDGET, WRITE_SLEEP_MS, log)
        local target = img_of[plan.target]
        for i, id in ipairs(leaders_last(plan.join, img_of)) do
            w.write(function() img_of[id]:group_with(target) end, 1, string.format("image %d (%s): group with image %d", id, img_of[id].filename, plan.target))
            job.percent = i / #plan.join
        end
        for _, id in ipairs(plan.ids) do
            if ledger[id] and ledger[id].native then M.set_ledger_native(ledger, id, nil) end
        end
        log(string.format("merge: %d groups, %d images, %d moved, %d failed", plan.groups, #plan.ids, #plan.join, w.failed))
        if w.failed > 0 then
            notify_error(string.format("Assisted Grouping: merged %d groups, but %d moves failed (%s). Merge again to retry.",
                plan.groups, w.failed, w.first_error))
        else
            say(string.format("Assisted Grouping: merged %d groups into one of %d images. Group selection keeps it.", plan.groups, #plan.ids))
        end
    end)

    finish_job(job, changed and ledger or nil)
    if not okr then notify_error("Assisted Grouping: merge groups failed. " .. tostring(err)) end
    flush_log()
    run_next()
end

-- To check fixes ------------------------------------------------------------------
-- fixes.group needs the panel's options, so the panel adds it.

-- Verify's no-leader row: makes the lowest image of each group in `images` its leader.
fixes.leader = function(images)
    local done, n = {}, 0
    for _, img in ipairs(images) do
        local lowest
        for _, other in ipairs(img:get_group_members()) do
            if not lowest or other.id < lowest.id then lowest = other end
        end
        if not done[lowest.id] then
            done[lowest.id] = true
            lowest:make_group_leader()
            n = n + 1
        end
    end
    say(string.format("Assisted Grouping: %d darktable groups now led by their lowest image.", n))
end

local preset_file_store, make_preset_controls = C.preset_file_store, C.make_preset_controls


-- Panel -----------------------------------------------------------------------

-- dt.gui.action_images changes with the selection; queued jobs keep the images they were
-- clicked with.
local function copy_images(images)
    local out = {}
    for _, img in ipairs(images or {}) do out[#out + 1] = img end
    return out
end

-- Culling's partial-burst warning. GTK labels here don't wrap, so the lines are broken by hand.
local PARTIAL_BURST_WARNING = "Select whole bursts ?"

local function install_panel()
    if M.module_installed then return end
    M.module_installed = true

    local ctl
    local function changed()
        if ctl then ctl.check_dirty() end
    end

    local notice
    local refresh_notice

    -- changed_callback fires on every `selected` assignment, so act only when the value differs.
    local shown_start = "time"
    local gap_box
    local start_combo = new_widget("combobox") {
        label = "start from",
        tooltip = "Where the groups begin, before page 2 divides them. Default: capture time.\ncapture time: a new group starts when the gap to the previous photo is longer than the burst gap below.\nlast run's groups: each photo's newest Group tag from an earlier run; photos without one share one group. No capture times are read.\none group: every photo starts together, and only the divide layers on page 2 split it.",
        changed_callback = function(widget)
            local value = M.START_FROM[widget.selected]
            if not value or value == shown_start then return end
            shown_start = value
            gap_box.visible = (value == "time")
            changed()
            refresh_notice()
        end,
        table.unpack(M.START_FROM_LABELS),
    }
    start_combo.selected = 1

    local gap_entry = new_widget("entry") {
        tooltip = "Burst gap in seconds: photos taken closer together than this are one burst. Must be above 0. Default: 2. Decimals are allowed (0.5 or 1,5). Lower it when separate bursts end up in one group; raise it when a burst with pauses is split. Type auto to pick the gap from the selection's own timing, between 0.3 and 10 s (the log shows the gap it chose; with under 30 gaps or no clear split, it uses 2).",
        placeholder = "burst gap (seconds or auto), e.g. 2",
        text = "2",
    }
    gap_box = new_widget("box") {
        orientation = "vertical",
        new_widget("label") { label = "burst gap (seconds)", halign = "start" },
        gap_entry,
    }
    local min_entry = new_widget("entry") {
        tooltip = "Minimum burst size in frames (a RAW+JPEG pair is one frame). A final group (after page 2's layers) with fewer frames than this is left as single frames: each frame gets its own Group tag, and a RAW+JPEG pair still stacks as a pair. Default: 2, so any two frames can group. Raise it to 3 or more to keep stray pairs out of the groups.",
        placeholder = "minimum burst size (frames), e.g. 2",
        text = "2",
    }
    local camera_check = new_widget("check_button") {
        label = "Camera and lens",
        tooltip = "Divide each group by camera maker, model and lens. With start from capture time, each camera is also timed on its own, so one body's frames never join another's burst. Default: off.",
        value = false,
        clicked_callback = function() changed(); refresh_notice() end,
    }
    local tag_entry = new_widget("entry") {
        tooltip = "Divide each group into photos that carry exactly this tag and photos that don't (child tags don't count). Empty = off. Example: Cars|Red.",
        placeholder = "tag, e.g. Cars|Red",
        text = "",
    }
    local parent_entry = new_widget("entry") {
        tooltip = "Divide each group by which tag directly under this node a photo carries. Photos with none, or several, aren't split off: they stay with the group's first part (the log counts them). Empty = off. Example: Cars|Number. Type the Assisted Tagging prefix (e.g. Rally|2026) to split bursts by car number.",
        placeholder = "parent tag, e.g. Cars|Number",
        text = "",
    }
    local native_check = new_widget("check_button") {
        label = "Apply darktable groups",
        tooltip = "Make one darktable group per final group of two or more images (a lone RAW+JPEG frame counts). Images already in a group you made by hand are skipped. Default: on; the quicker output. Once this step starts, cancel is ignored so no group is left half-built.",
        clicked_callback = function() changed(); refresh_notice() end,
    }
    local tags_check = new_widget("check_button") {
        label = "Group tags",
        tooltip = "Tag each photo with its Group under Assisted Grouping|<run time>|Group|... One tag per final group. Needed for start from last run's groups and for browse as bursts (page 4). Default: off; slower on a large selection.",
        value = false,
        clicked_callback = function() changed(); refresh_notice() end,
    }
    local session_entry = new_widget("entry") {
        tooltip = "Sessions: a level above the groups. With a number above 0, each photo with a capture time also gets a Session tag under Assisted Grouping|<run time>|Session|...: a new session starts when the gap to the previous photo is longer than this many minutes. It splits no group. Written only when Group tags is on. Default: 0 (off). Example: 30.",
        placeholder = "session gap (minutes), 0 = off",
        text = "0",
    }
    local trace_check = new_widget("check_button") {
        label = "Layer trace tags",
        tooltip = "Also write the Burst, Camera, Tag and Parent tags that show which layer split each group. Each is written only when its layer runs (Burst: start from capture time plus another layer, or a minimum burst size above 2). Written only when Group tags is on. Default: off; slower on a large selection.",
        value = false,
        clicked_callback = function() changed(); refresh_notice() end,
    }

    local function panel_state()
        return {
            start_from = M.START_FROM[start_combo.selected],
            gap_text = gap_entry.text,
            min_size_text = min_entry.text,
            session_gap_text = session_entry.text,
            camera = camera_check.value,
            tag = tag_entry.text,
            parent = parent_entry.text,
            write_tags = tags_check.value,
            trace_tags = trace_check.value,
            native_groups = native_check.value,
        }
    end

    notice = new_widget("label") { label = "", halign = "start", visible = false }
    refresh_notice = function()
        local text = M.panel_notice(panel_state())
        notice.label = text
        notice.visible = (text ~= "")
    end

    local last_gap_number -- the number a preset stored, kept while the entry reads "auto"
    local function read_panel()
        local start_from = M.START_FROM[start_combo.selected]
        local gap = M.parse_gap(gap_entry.text)
        if not gap then
            if start_from == "time" then return nil, M.ERR_BAD_GAP end
            gap = M.preset_defaults(M.PRESET_SCHEMA).burst_gap_seconds
        end
        local auto = gap == "auto"
        if auto then gap = last_gap_number or M.preset_defaults(M.PRESET_SCHEMA).burst_gap_seconds end
        local min_size = M.parse_min_size(min_entry.text)
        if not min_size then return nil, M.ERR_BAD_MIN_SIZE end
        local session_minutes = M.parse_session_gap(session_entry.text)
        if not session_minutes then return nil, M.ERR_BAD_SESSION_GAP end
        return {
            start_from = start_from,
            burst_gap_seconds = gap,
            burst_gap_auto = auto,
            min_burst_size = min_size,
            camera = camera_check.value,
            tag = tag_entry.text,
            parent = parent_entry.text,
            native_groups = native_check.value,
            write_tags = tags_check.value,
            trace_tags = trace_check.value,
            session_gap_minutes = session_minutes,
        }
    end

    local function show_panel(s)
        last_gap_number = s.burst_gap_seconds
        gap_entry.text = s.burst_gap_auto and "auto" or string.format("%.14g", s.burst_gap_seconds)
        shown_start = s.start_from
        for i, v in ipairs(M.START_FROM) do
            if v == s.start_from and start_combo.selected ~= i then start_combo.selected = i end
        end
        gap_box.visible = (s.start_from == "time")
        min_entry.text = string.format("%.14g", s.min_burst_size)
        camera_check.value = s.camera
        tag_entry.text = s.tag
        parent_entry.text = s.parent
        native_check.value = s.native_groups
        tags_check.value = s.write_tags
        trace_check.value = s.trace_tags
        session_entry.text = string.format("%.14g", s.session_gap_minutes)
        refresh_notice()
    end

    local function read_options()
        changed()
        return M.panel_options(panel_state())
    end

    -- Group selection, or Verify selection when `verify`, on `images` with the panel's options.
    local function run_group(images, verify)
        refresh_notice()
        local opts, why = read_options()
        if not opts then
            dt.print("Assisted Grouping: " .. why)
            return
        end
        opts.verify = verify
        local label = verify and "Verify selection" or "Group selection"
        if queue_if_busy(label, #images > 0, function() M.group_images(images, opts) end) then return end
        M.group_images(images, opts)
    end
    fixes.group = function(images) run_group(images, false) end

    local group_button = new_widget("button") {
        label = "Group selection",
        tooltip = "Group the selected photos with the settings on pages 1 to 3. Cancel from the progress bar: before anything is written it changes nothing, while tags are being written it stops partway (partial tags stay), and once darktable groups have started it is ignored.",
        clicked_callback = function() run_group(copy_images(dt.gui.action_images), false) end,
    }
    local verify_button = new_widget("button") {
        label = "Verify selection",
        tooltip = "Check the selected photos against a fresh Group selection run with the settings on pages 1 to 3, and list what differs in To check. Nothing is written. Photos in a group you made by hand are left out, as Group selection skips them. Also lists photos in a darktable group with no leader inside it.",
        clicked_callback = function() run_group(copy_images(dt.gui.action_images), true) end,
    }
    local warning_label = new_widget("label") {
        label = PARTIAL_BURST_WARNING,
        halign = "start",
        tooltip = "Bursts are grouped from the selected photos only, so selecting part of a burst splits it. Select whole bursts, or the whole shoot.",
    }
    clear_button = new_widget("button") {
        label = "Clear grouping marks",
        tooltip = "Remove the tags (Group, Session and layer trace) and darktable groups this plugin made from the selected photos, with a job bar you can cancel. RAW+JPEG pairs are stacked again. Tags and groups you made by hand stay.",
        clicked_callback = function()
            local images = copy_images(dt.gui.action_images)
            if queue_if_busy("Clear grouping marks", #images > 0, function() M.clear_marks(images) end) then return end
            M.clear_marks(images)
        end,
    }
    local bursts_button = new_widget("button") {
        label = "bursts",
        tooltip = "Put the selected photos back into darktable groups from each photo's newest Group tag. Photos without one stay alone, and photos in a group you made by hand are skipped. No capture times are read and no tags are written. Run Group selection with Group tags on first.",
        clicked_callback = function()
            local images = copy_images(dt.gui.action_images)
            if queue_if_busy("browse as bursts", #images > 0, function() M.browse_bursts(images) end) then return end
            M.browse_bursts(images)
        end,
    }
    local pairs_button = new_widget("button") {
        label = "pairs",
        tooltip = "Take the selected photos, and everything grouped with them, out of their darktable groups, then stack each RAW with its JPEG again, as at import. Hand-made groups are reset too. Group tags stay, so bursts brings the groups back.",
        clicked_callback = function()
            local images = copy_images(dt.gui.action_images)
            if queue_if_busy("browse as pairs", #images > 0, function() M.reset_to_pairs(images) end) then return end
            M.reset_to_pairs(images)
        end,
    }
    local merge_button = new_widget("button") {
        label = "Merge groups",
        tooltip = "Join the darktable groups of the selected photos into one, for a burst the run split. The merged group counts as made by hand: Group selection keeps it and Clear leaves it. Tags stay. pairs takes it apart again.",
        clicked_callback = function()
            local images = copy_images(dt.gui.action_images)
            if queue_if_busy("Merge groups", #images > 0, function() M.merge_groups(images) end) then return end
            M.merge_groups(images)
        end,
    }

    local store = preset_file_store(LEDGER_DIR .. "/presets")
    local raw_read = store.read
    store.read = function(name)
        local text = raw_read(name)
        if not text then return nil end
        local upgraded, notes = M.upgrade_preset_text(text)
        -- saved back, so the upgrade (and its log lines) happens once
        if upgraded ~= text then
            if store.write(name, upgraded) then
                for _, note in ipairs(notes or {}) do log(note) end
            else
                log("preset " .. name .. ": couldn't save the upgraded preset to " .. store.path(name))
            end
            flush_log()
        end
        return upgraded
    end

    ctl = make_preset_controls({
        prefix = "Assisted Grouping",
        plugin = "assisted_grouping",
        schema = M.PRESET_SCHEMA,
        store = store,
        read_panel = read_panel,
        show = show_panel,
        remember = function(name) dt.preferences.write("assisted_grouping", "preset", "string", name) end,
        initial = dt.preferences.read("assisted_grouping", "preset", "string"),
        log = function(msg) log(msg); flush_log() end,
        allow_store_new = true,
    })

    local page_widgets = {
        {
            start_combo,
            gap_box,
            new_widget("label") { label = "minimum burst size (frames)", halign = "start" },
            min_entry,
        },
        {
            camera_check,
            new_widget("label") { label = "Tag", halign = "start" },
            tag_entry,
            new_widget("label") { label = "Parent tag", halign = "start" },
            parent_entry,
        },
        {
            new_widget("section_label") { label = "outputs" },
            native_check,
            tags_check,
            new_widget("label") { label = "session gap (minutes, 0 = off)", halign = "start" },
            session_entry,
            new_widget("section_label") { label = "how it decided" },
            trace_check,
        },
        {
            new_widget("section_label") { label = "group (uses pages 1 to 3)" },
            group_button,
            verify_button,
            new_widget("section_label") { label = "browse as (darktable groups only; tags kept)" },
            new_widget("box") {
                orientation = "horizontal",
                bursts_button,
                pairs_button,
            },
            new_widget("section_label") { label = "fix by hand (kept on the next run)" },
            merge_button,
        },
        {
            new_widget("section_label") { label = "undo" },
            clear_button,
        },
    }
    local pages = {}
    for i, page in ipairs(M.PANEL_PAGES) do
        pages[i] = { number = page.number, title = page.title, widgets = page_widgets[i] }
    end

    local panel_box = new_widget("box") {
        orientation = "vertical",
        reset_callback = function()
            show_panel(M.preset_defaults(M.PRESET_SCHEMA))
            changed()
            refresh_notice()
        end,
        ctl.widget,
        C.paged_sections("assisted_grouping", pages),
        alerts.widget,
        warning_label, -- below the pages so it shows whichever is open
        notice,
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
        guard("panel install", function()
            install_panel()
            restart()
        end)
    else
        if not M.event_registered then
            dt.register_event("assisted_grouping", "view-changed", function(event, old_view, new_view)
                if new_view.name == "lighttable" or new_view.id == "lighttable" then
                    guard("panel install", function()
                        install_panel()
                        restart()
                    end)
                end
            end)
            M.event_registered = true
        end
    end
end

return M

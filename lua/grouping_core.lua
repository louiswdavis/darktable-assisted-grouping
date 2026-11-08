--[[
    grouping_core.lua — pure grouping logic for Assisted Grouping

    No darktable access: loadable and testable with plain `lua`.
    assisted_grouping.lua reads the selection and applies the results.
]]

local M = {}

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
-- duplicates (versions of one file) share this key.
local function frame_key(image)
    local stem = (image.filename or ""):match("^(.*)%.[^./\\]*$") or image.filename or ""
    return (image.dir or "") .. "\0" .. stem
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
        for _, field in ipairs({ "epoch", "maker", "model", "lens" }) do
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

local function burst_layer(units, gap, base_of)
    if not base_of then return M.cluster_by_time(units, gap) end
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
    for id, grp in pairs(M.cluster_by_time(rest, gap)) do
        burst_of[id] = max_base + grp
    end
    return burst_of
end

-- opts = { gap, camera = bool, tag = string|nil, parent = string|nil, base_of = group_of|nil }
function M.run_layers(units, opts)
    local result = {}
    result.burst_of = burst_layer(units, opts.gap, opts.base_of)
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
    return result
end

-- Stamped tag names ----------------------------------------------------------

M.PREFIX = "Assisted Grouping"

-- `Group` and `Burst` take the zero-padded number; `Camera`, `Tag`, `Parent`
-- take `label`, which must already be sanitized.
function M.group_tag(stamp, layer, n, label)
    local leaf = (layer == "Group" or layer == "Burst") and string.format("%04d", n) or label
    return table.concat({ M.PREFIX, stamp, layer, leaf }, "|")
end

local function last_segment(tag)
    return tag:match("([^|]*)$")
end

-- opts as for run_layers; a layer counts as run when its map is in `result`.
function M.wanted_tags(units, result, stamp, opts)
    local wanted = {}
    local child_of = opts.parent and M.parent_key(opts.parent)
    local tag_label = opts.tag and M.sanitize(last_segment(opts.tag))
    for _, unit in ipairs(units) do
        local set = {}
        set[M.group_tag(stamp, "Group", result.final_of[unit.id])] = true
        set[M.group_tag(stamp, "Burst", result.burst_of[unit.id])] = true
        if result.camera_of then
            local cam = M.camera_key(unit)
            set[M.group_tag(stamp, "Camera", nil, cam ~= "" and cam or "unknown")] = true
        end
        if result.tag_of then
            local prefix = unit.tags[opts.tag] and "has " or "not "
            set[M.group_tag(stamp, "Tag", nil, prefix .. tag_label)] = true
        end
        if result.parent_of then
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

local GROUP_TAG_PATTERN = "^" .. M.PREFIX:gsub("%p", "%%%0") .. "|(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)|Group|%d+$"

-- Stamps are `YYYY-MM-DD HH:MM:SS`, so string order is time order.
function M.latest_group_tag(have)
    local best, best_stamp
    for name in pairs(have or {}) do
        local stamp = name:match(GROUP_TAG_PATTERN)
        if stamp and (not best_stamp or stamp > best_stamp
                or (stamp == best_stamp and name > best)) then
            best, best_stamp = name, stamp
        end
    end
    return best
end

-- Units with no group tag are left out, so run_layers times them afresh.
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

-- Rows: `id,tag,<name>` for each tag the plugin attached, `id,group,<leader id>`
-- for a native group it made. Anything not in the ledger was made by hand.
function M.ledger_parse(text)
    local ledger = {}
    for _, row in ipairs(M.parse_csv(text or "")) do
        local id = tonumber(row[1])
        if id and #row == 3 and row[3] ~= "" then
            local entry = ledger[id] or { tags = {} }
            ledger[id] = entry
            if row[2] == "tag" then
                entry.tags[row[3]] = true
            elseif row[2] == "group" then
                entry.native = tonumber(row[3])
            end
        end
    end
    return ledger
end

function M.ledger_format(ledger)
    local ids = {}
    for id in pairs(ledger) do ids[#ids + 1] = id end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do
        local entry = ledger[id]
        local names = {}
        for name in pairs(entry.tags or {}) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do out[#out + 1] = M.csv_line({ id, "tag", name }) end
        if entry.native then out[#out + 1] = M.csv_line({ id, "group", entry.native }) end
    end
    return #out > 0 and table.concat(out, "\n") .. "\n" or ""
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

return M

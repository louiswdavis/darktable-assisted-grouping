-- Run with: lua lua/test_assisted_grouping.lua (from the repo) or lua test_assisted_grouping.lua (from lua/)
-- Exercises assisted_grouping.lua's pure functions; no darktable needed.

local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = script_dir .. "/?.lua;./?.lua;" .. package.path
local A = require("assisted_grouping")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %s", name))
    end
end

-- plugin_common.lua ---------------------------------------------------------------
-- The same file in all three plugin repos; COMMON_HASH pins it. After changing it, copy it to the
-- other two repos and put the hash this prints into their tests too.
local COMMON_HASH = "4028fb69"
local PC = dofile(script_dir .. "/plugin_common.lua")
local function fnv1a(text)
    local h = 2166136261
    for i = 1, #text do h = ((h ~ text:byte(i)) * 16777619) & 0xffffffff end
    return string.format("%08x", h)
end
local cf = assert(io.open(script_dir .. "/plugin_common.lua", "rb"))
local common_text = cf:read("a"):gsub("\r\n", "\n")
cf:close()
check("plugin_common.lua matches COMMON_HASH (copy it to the other repos after a change)", fnv1a(common_text), COMMON_HASH)
check("shell_quote: Windows escapes quotes, keeps %", PC.shell_quote('C:\\x %y% "z"', true), '"C:\\x %y% \\"z\\""')
check("shell_quote: POSIX escapes single quotes", PC.shell_quote("a'b", false), "'a'\\''b'")
check("parse_csv_line: quoted comma and doubled quote", PC.parse_csv_line('1,"a ""x"", b.jpg",3\r', 3)[2], 'a "x", b.jpg')
check("parse_csv_line: wrong field count is nil", PC.parse_csv_line("a,b", 3), nil)
check("lead_rank: full-size JPEG beats RAW", PC.lead_rank("x.JPG") > PC.lead_rank("x.nef"), true)
do -- temp_base / sweep_temp: leftovers older than max_age go, newer ones and other prefixes stay
    local dir = os.tmpname()
    os.remove(dir)
    os.execute(PC.IS_WINDOWS and ('mkdir "' .. dir .. '"') or ("mkdir -p '" .. dir .. "'"))
    local function touch(name) local f = assert(io.open(dir .. "/" .. name, "w")); f:write("x"); f:close() end
    touch("dt_assisted_x_1000_1_old.csv"); touch("dt_assisted_x_5000_1_new.csv"); touch("dt_assisted_y_1000_1_other.csv")
    local base = PC.temp_base(dir, "dt_assisted_x_")
    check("temp_base: <dir>/<prefix><epoch>_<seq>_", base:match("^" .. dir:gsub("%p", "%%%0") .. "/dt_assisted_x_%d+_%d+_$") ~= nil, true)
    local removed = PC.sweep_temp(dir, "dt_assisted_x_", 86400, 1000 + 86401)
    check("sweep_temp: removes only this prefix's stale files", table.concat(removed, ","), "dt_assisted_x_1000_1_old.csv")
    check("sweep_temp: newer file kept", PC.file_exists(dir .. "/dt_assisted_x_5000_1_new.csv"), true)
    check("sweep_temp: other prefix kept", PC.file_exists(dir .. "/dt_assisted_y_1000_1_other.csv"), true)
    for _, n in ipairs(PC.list_dir(dir)) do os.remove(dir .. "/" .. n) end
    os.remove(dir)
end

local function keys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, " + ")
end

-- exif_time_to_epoch -------------------------------------------------------
check("parses a normal timestamp", A.exif_time_to_epoch("2026:06:01 14:30:00") ~= nil, true)
check("returns nil for missing timestamp", A.exif_time_to_epoch(nil), nil)
check("returns nil for garbage input", A.exif_time_to_epoch("not a date"), nil)
check("returns nil for an all-zero date", A.exif_time_to_epoch("0000:00:00 00:00:00"), nil)
check("returns nil for a pre-1970 date", A.exif_time_to_epoch("1965:03:01 12:00:00"), nil)
check("normal date unchanged by the pre-1970 guard",
    A.exif_time_to_epoch("2026:06:01 14:30:00"),
    os.time({ year = 2026, month = 6, day = 1, hour = 14, min = 30, sec = 0, isdst = false }))
do
    local zero_units = A.collapse({
        { id = 1, dir = "d", filename = "a.jpg", epoch = A.exif_time_to_epoch("2026:06:01 14:30:00") },
        { id = 2, dir = "d", filename = "b.jpg", epoch = A.exif_time_to_epoch("0000:00:00 00:00:00") },
        { id = 3, dir = "d", filename = "c.jpg", epoch = A.exif_time_to_epoch("2026:06:01 14:30:01") },
    })
    local zg = A.cluster_by_time(zero_units, 2)
    check("zero-dated frame is kept", zg[2] ~= nil, true)
    check("zero-dated frame is its own group", zg[2] ~= zg[1] and zg[2] ~= zg[3], true)
    check("dated neighbours still share a burst", zg[1], zg[3])
end

-- collapse -----------------------------------------------------------------
local units = A.collapse({
    { id = 5, dir = "/shoot", filename = "A.JPG", epoch = 100, tags = { jpg = true } },
    { id = 3, dir = "/shoot", filename = "A.ARW", epoch = 100, tags = { raw = true } },
    { id = 7, dir = "/shoot", filename = "B.ARW", epoch = 200, tags = {} },
})
check("RAW+JPEG pair and a single give 2 units", #units, 2)
check("pair unit has 2 members", #units[1].members, 2)
check("pair unit id is the lowest member id", units[1].id, 3)
check("pair unit tags are the union", keys(units[1].tags), "jpg + raw")
check("single unit keeps its id", units[2].id, 7)

local case_units = A.collapse({
    { id = 1, dir = "/d", filename = "A.arw", tags = {} },
    { id = 2, dir = "/d", filename = "A.JPG", tags = {} },
    { id = 3, dir = "/other", filename = "A.JPG", tags = {} },
})
check("extension case ignored, other dir kept apart", #case_units, 2)

local dup_units = A.collapse({
    { id = 10, dir = "/d", filename = "X.ARW", epoch = 1, tags = { a = true } },
    { id = 11, dir = "/d", filename = "X.ARW", epoch = 1, tags = { b = true } },
})
check("same path twice gives 1 unit", #dup_units, 1)
check("duplicate unit has 2 members", #dup_units[1].members, 2)

-- cluster_by_time ------------------------------------------------------------
local function u(id, epoch) return { id = id, epoch = epoch } end

local g = A.cluster_by_time({ u(1, 0), u(2, 0.4), u(3, 0.8), u(4, 5) }, 2)
check("sub-second frames share group 1", g[1] .. g[2] .. g[3], "111")
check("frame past the gap is group 2", g[4], 2)

local edge = A.cluster_by_time({ u(1, 0), u(2, 2), u(3, 4.01) }, 2)
check("gap exactly 2 stays in the group", edge[2], edge[1])
check("gap 2.01 splits", edge[3], 2)

local eq = A.cluster_by_time({ u(2, 10), u(1, 10) }, 2)
check("equal epochs share a group", eq[1], eq[2])

local mixed = A.cluster_by_time({ u(1, 0), u(2, nil), u(3, 1), u(4, nil) }, 2)
check("timed units come first", mixed[1] .. mixed[3], "11")
check("untimed units get distinct numbers after the timed ones",
    mixed[2] ~= mixed[4] and mixed[2] > 1 and mixed[4] > 1, true)
check("untimed numbering follows id order", mixed[2] .. mixed[4], "23")

local untimed = A.cluster_by_time({ u(9, nil), u(8, nil), u(7, nil) }, 2)
check("all-untimed input yields one group per unit", untimed[7] .. untimed[8] .. untimed[9], "123")

local single = A.cluster_by_time({ u(42, 100) }, 2)
check("single unit yields group 1", single[42], 1)
check("single unit yields exactly one entry", keys(single), "42")

local float_gap = A.cluster_by_time({ u(1, 0.1), u(2, 2.1) }, 2)
check("0.1 and 2.1 with gap 2 stay together (float tolerance)", float_gap[2], float_gap[1])
local float_split = A.cluster_by_time({ u(1, 0.1), u(2, 2.2) }, 2)
check("0.1 and 2.2 with gap 2 split", float_split[2], 2)
-- 4.4 - 2.4 is 2.0000000000000004 in doubles, so this one needs the tolerance.
local float_round = A.cluster_by_time({ u(1, 2.4), u(2, 4.4) }, 2)
check("2.4 and 4.4 with gap 2 stay together (float tolerance)", float_round[2], float_round[1])
-- At real epoch sizes a double steps by ~2.4e-7, so the tolerance must cover that.
local real_gap = A.cluster_by_time({ u(1, 1780000000.10), u(2, 1780000001.60) }, 1.5)
check("real epochs exactly 1.5 apart with gap 1.5 stay together", real_gap[2], real_gap[1])
local real_split = A.cluster_by_time({ u(1, 1780000000.10), u(2, 1780000001.70) }, 1.5)
check("real epochs 1.6 apart with gap 1.5 split", real_split[2], 2)
-- 1.5 is exact in binary; 0.1 is not, and this pair's delta is 0.100000143.
local real_tenth = A.cluster_by_time({ u(1, 1780000000.03), u(2, 1780000000.13) }, 0.1)
check("real epochs exactly 0.1 apart with gap 0.1 stay together", real_tenth[2], real_tenth[1])

local jpeg_only = A.collapse({
    { id = 20, dir = "/shoot", filename = "P.JPG", epoch = 50, tags = {} },
    { id = 21, dir = "/shoot", filename = "Q.ARW", epoch = 51, tags = {} },
})
check("JPEG-only half of a pair gives a 1-member unit", #jpeg_only[1].members, 1)
local jpeg_only_g = A.cluster_by_time(jpeg_only, 2)
check("JPEG-only half of a pair still clusters", jpeg_only_g[20] .. jpeg_only_g[21], "11")

-- sanitize / camera_key ------------------------------------------------------
check("sanitize collapses and trims", A.sanitize('  a|b;c,d"e\tf\n  g  '), "a b c d e f g")

check("camera_key joins maker model lens",
    A.camera_key({ maker = "SONY", model = "ZV-E10", lens = "E 18-105mm F4 G OSS" }),
    "SONY ZV-E10 E 18-105mm F4 G OSS")
local dirty = A.camera_key({ maker = "SONY", model = "ZV-E10", lens = 'A|B,C;"D"' })
check("camera_key strips | ; , and \"", dirty:find('[|;,"]'), nil)
check("camera_key keeps the rest of a dirty lens", dirty, "SONY ZV-E10 A B C D")
check("camera_key with missing fields has no stray spaces", A.camera_key({ model = "X100" }), "X100")

-- divide ---------------------------------------------------------------------
local function cu(id, extra)
    local unit = { id = id, tags = {} }
    for k, v in pairs(extra or {}) do unit[k] = v end
    return unit
end

local cam_units = { cu(1, { model = "a" }), cu(2, { model = "b" }), cu(3, { model = "a" }) }
local by_cam = A.divide({ [1] = 1, [2] = 1, [3] = 1 }, A.camera_key, cam_units)
check("divide by camera: units 1 and 3 together", by_cam[1], by_cam[3])
check("divide by camera: unit 2 apart", by_cam[2] ~= by_cam[1], true)
check("divide by camera: dense numbering", by_cam[1] .. by_cam[2], "12")

local multi = A.divide({ [1] = 1, [2] = 2, [3] = 2 },
    function(unit) return unit.k end,
    { cu(1, { k = "x" }), cu(2, { k = "x" }), cu(3, { k = "y" }) })
check("divide numbers by old group then first appearance", multi[1] .. multi[2] .. multi[3], "123")

-- tag_key --------------------------------------------------------------------
local red = A.tag_key("Cars|Red")
check("tag_key matches an exact tag", red(cu(1, { tags = { ["Cars|Red"] = true } })), "1")
check("tag_key: untagged is 0", red(cu(2)), "0")
check("tag_key: child tag does not match its parent", red(cu(3, { tags = { ["Cars|Red|X"] = true } })), "0")
local tag_split = A.divide({ [1] = 1, [2] = 1 }, red,
    { cu(1, { tags = { ["Cars|Red"] = true } }), cu(2) })
check("tag_key splits tagged from untagged", tag_split[1] ~= tag_split[2], true)

-- parent_key -----------------------------------------------------------------
local num = A.parent_key("Cars|Number")
check("parent_key: one child gives that child",
    num(cu(1, { tags = { ["Cars|Number|7"] = true, ["Other"] = true } })), "7")
check("parent_key: no child gives nil", num(cu(2, { tags = { ["Cars|Red"] = true } })), nil)
check("parent_key: two children give nil",
    num(cu(3, { tags = { ["Cars|Number|7"] = true, ["Cars|Number|8"] = true } })), nil)
check("parent_key: grandchild is not a direct child",
    num(cu(4, { tags = { ["Cars|Number|7|a"] = true } })), nil)

local par_units = {
    cu(1, { tags = { ["Cars|Number|7"] = true } }),
    cu(2, { tags = {} }),
    cu(3, { tags = { ["Cars|Number|8"] = true } }),
}
local by_par = A.divide({ [1] = 1, [2] = 1, [3] = 1 }, num, par_units)
check("parent divide: two children split", by_par[1] ~= by_par[3], true)
check("parent divide: nil-key unit stays with the group's first part", by_par[2], by_par[1])
check("parent divide: nil key forms no extra group", by_par[3], 2)

local all_nil = A.divide({ [1] = 1, [2] = 1 }, num, { cu(1), cu(2) })
check("parent divide: all-nil group stays one group", all_nil[1] .. all_nil[2], "11")

-- run_layers -----------------------------------------------------------------
local run_units = {
    cu(1, { epoch = 0, model = "a", tags = { ["Cars|Red"] = true, ["Cars|Number|7"] = true } }),
    cu(2, { epoch = 1, model = "b", tags = { ["Cars|Number|7"] = true } }),
    cu(3, { epoch = 1.5, model = "a", tags = { ["Cars|Red"] = true, ["Cars|Number|8"] = true } }),
    cu(4, { epoch = 10, model = "a", tags = {} }),
    cu(5, { epoch = 11, model = "a", tags = { ["Cars|Red"] = true } }),
    cu(6, { model = "a", tags = {} }),
}
local function same_map(a, b)
    for id, grp in pairs(a) do if b[id] ~= grp then return false end end
    for id in pairs(b) do if a[id] == nil then return false end end
    return true
end

local off = A.run_layers(run_units, { gap = 2 })
check("all layers off: final_of is burst_of", off.final_of, off.burst_of)
check("all layers off: other layers are nil", off.camera_of == nil and off.tag_of == nil and off.parent_of == nil, true)
check("burst_of matches cluster_by_time", same_map(off.burst_of, A.cluster_by_time(run_units, 2)), true)

local cam = A.run_layers(run_units, { gap = 2, camera = true })
check("camera on: final_of is camera_of", cam.final_of, cam.camera_of)

local all = A.run_layers(run_units, { gap = 2, camera = true, tag = "Cars|Red", parent = "Cars|Number" })
check("all on: final_of is parent_of", all.final_of, all.parent_of)
check("all on: every layer ran", all.camera_of ~= nil and all.tag_of ~= nil, true)
local merged = false
for _, a in ipairs(run_units) do
    for _, b in ipairs(run_units) do
        if all.burst_of[a.id] ~= all.burst_of[b.id] and all.final_of[a.id] == all.final_of[b.id] then
            merged = true
        end
    end
end
check("layers never merge across bursts", merged, false)
check("all on: every unit has a final group", keys(all.final_of), "1 + 2 + 3 + 4 + 5 + 6")

-- ticket 47: body A at 0,1,3,4 s and body B at 2 s, gap 1.5 s
local two_bodies = {
    cu(1, { epoch = 0, model = "a" }), cu(2, { epoch = 1, model = "a" }), cu(3, { epoch = 2, model = "b" }),
    cu(4, { epoch = 3, model = "a" }), cu(5, { epoch = 4, model = "a" }),
}
local per_cam = A.run_layers(two_bodies, { gap = 1.5, camera = true })
check("camera on: each body's bursts are found on its own timeline",
    table.concat({ per_cam.burst_of[1], per_cam.burst_of[2], per_cam.burst_of[3], per_cam.burst_of[4], per_cam.burst_of[5] }, ","),
    "1,1,3,2,2")
local one_line = A.run_layers(two_bodies, { gap = 1.5 })
check("camera off: one timeline chains all five frames",
    table.concat({ one_line.burst_of[1], one_line.burst_of[2], one_line.burst_of[3], one_line.burst_of[4], one_line.burst_of[5] }, ","),
    "1,1,1,1,1")

local based = A.run_layers({ cu(1, { epoch = 0 }), cu(2, { epoch = 100 }), cu(3, { epoch = 0 }) },
    { gap = 2, base_of = { [1] = 1, [2] = 2 } })
check("base_of keeps its groups", based.burst_of[1] .. based.burst_of[2], "12")
check("unit outside base_of is numbered after the base groups", based.burst_of[3], 3)

-- minimum burst size: bursts of 3 (0,1,2 s), 2 (10,11 s) and 1 (20 s) frames
local sized = {
    cu(1, { epoch = 0 }), cu(2, { epoch = 1 }), cu(3, { epoch = 2 }),
    cu(4, { epoch = 10 }), cu(5, { epoch = 11 }), cu(6, { epoch = 20 }),
}
local function groups_str(group_of)
    local out = {}
    for id = 1, 6 do out[id] = group_of[id] end
    return table.concat(out, ",")
end
local min2 = A.run_layers(sized, { gap = 2, min_frames = 2 })
check("min_frames 2: final_of is still burst_of", min2.final_of, min2.burst_of)
check("min_frames 2: groups as without it", groups_str(min2.final_of), "1,1,1,2,2,3")
check("min_frames unset: groups as with 2", groups_str(A.run_layers(sized, { gap = 2 }).final_of), "1,1,1,2,2,3")
local min3 = A.run_layers(sized, { gap = 2, min_frames = 3 })
check("min_frames 3: the pair is left as single frames, numbered densely", groups_str(min3.final_of), "1,1,1,2,3,4")
check("min_frames 3: final_of is min_of, burst_of keeps the pair",
    tostring(min3.final_of == min3.min_of) .. " " .. groups_str(min3.burst_of), "true 1,1,1,2,2,3")
check("min_frames 3: one group of 2+ was dissolved", min3.dissolved, 1)
check("min_frames 4: nothing is big enough", groups_str(A.run_layers(sized, { gap = 2, min_frames = 4 }).final_of), "1,2,3,4,5,6")
local min_cam = A.run_layers({ cu(1, { epoch = 0, model = "a" }), cu(2, { epoch = 0.5, model = "a" }), cu(3, { epoch = 1, model = "b" }),
    cu(4, { epoch = 1.5, model = "a" }), cu(5, { epoch = 2, model = "b" }), cu(6, { epoch = 2.5, model = "a" }) },
    { gap = 2, camera = true, min_frames = 3 })
check("min_frames counts the final group, after the divide layers", groups_str(min_cam.final_of), "1,1,2,1,3,1")
-- weakest_links: group 1 at 0, 0.5, 2 s; group 2 at 10, 13 s plus an untimed frame; group 3
-- one timed and one untimed frame
local link_units = {
    cu(1, { epoch = 2 }), cu(2, { epoch = 0 }), cu(3, { epoch = 0.5 }),
    cu(4, { epoch = 10 }), cu(5, { epoch = 13 }), cu(6, { epoch = 50 }), cu(7, {}), cu(8, {}),
}
local link_strs = {}
for _, link in ipairs(A.weakest_links(link_units, { [1] = 1, [2] = 1, [3] = 1, [4] = 2, [5] = 2, [6] = 3, [7] = 3, [8] = 2 })) do
    link_strs[#link_strs + 1] = string.format("g%d n%d %.1f before %d", link.group, link.frames, link.gap, link.after.id)
end
check("weakest_links: widest gap first, by capture time; frames counts untimed ones; groups under two timed frames left out",
    table.concat(link_strs, "; "), "g2 n3 3.0 before 5; g1 n3 1.5 before 1")
check("weakest_links: no groups of two, no links", #A.weakest_links(link_units, { [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6, [7] = 7, [8] = 8 }), 0)
-- cut_hints: group 1 zooms 70 to 200 mm then holds; group 2 slows two stops and refocuses
do
    local hint_units = {
        cu(1, { epoch = 0, focal = 70, exposure = 0.001 }), cu(2, { epoch = 1, focal = 200, exposure = 0.001 }),
        cu(3, { epoch = 2, focal = 210, exposure = 0.002 }), cu(4, { epoch = 11, exposure = 0.25, focus = 20 }),
        cu(5, { epoch = 10, exposure = 1 / 1000, focus = 5 }), cu(6, { focal = 400 }), cu(7, { epoch = 12, focal = 14 }),
    }
    local hint_strs = {}
    for _, hint in ipairs(A.cut_hints(hint_units, { [1] = 1, [2] = 1, [3] = 1, [4] = 2, [5] = 2, [6] = 1, [7] = 2 })) do
        hint_strs[#hint_strs + 1] = string.format("g%d before %d: %s", hint.group, hint.after.id, table.concat(hint.jumps, "; "))
    end
    check("cut_hints: jumps by group then capture time; small moves, untimed frames and missing settings skipped",
        table.concat(hint_strs, " | "),
        "g1 before 2: focal length 70 to 200 mm | g2 before 4: exposure 1/1000 to 1/4 s; focus distance 5 to 20 m")
    check("cut_hints: a jump across two groups is no hint",
        #A.cut_hints(hint_units, { [1] = 1, [2] = 2, [3] = 2, [4] = 3, [5] = 4, [6] = 5, [7] = 6 }), 0)
    local zoomed = A.collapse(A.build_images({
        { id = 1, path = "/p", filename = "A_1.ARW", exif_datetime_taken = "2026:05:01 10:00:00", exif_focal_length = 0,
            exif_exposure = 0, exif_focus_distance = 0 },
        { id = 2, path = "/p", filename = "A_1.JPG", exif_datetime_taken = "2026:05:01 10:00:00", exif_focal_length = 85,
            exif_exposure = 0.004, exif_focus_distance = 3.5 },
    }, false))
    check("build_images: zero EXIF settings are unknown, and the pair's other file fills them",
        string.format("%d %s %s %s", #zoomed, zoomed[1].focal, zoomed[1].exposure, zoomed[1].focus), "1 85 0.004 3.5")
end

local dissolved_of, dissolved_n = A.dissolve_small({ [1] = 2, [2] = 5, [3] = 2, [4] = 5, [5] = 5, [6] = 9 }, sized, 3)
check("dissolve_small: old group order, then unit order", groups_str(dissolved_of) .. " / " .. dissolved_n, "1,3,2,3,3,4 / 1")

-- group_tag ------------------------------------------------------------------
local STAMP = "2026-11-08 22:45:10"
check("group_tag pads the final group number",
    A.group_tag(STAMP, "Group", 42), "Assisted Grouping|2026-11-08 22:45:10|Group|0042")
check("group_tag pads the burst number",
    A.group_tag(STAMP, "Burst", 7), "Assisted Grouping|2026-11-08 22:45:10|Burst|0007")
check("group_tag uses the label for Camera",
    A.group_tag(STAMP, "Camera", 3, "SONY ZV-E10"), "Assisted Grouping|2026-11-08 22:45:10|Camera|SONY ZV-E10")

-- wanted_tags ----------------------------------------------------------------
local pair = A.collapse({
    { id = 10, dir = "/p", filename = "IMG_1.ARW", epoch = 0, model = "a", tags = { ["Cars|Red"] = true, ["Cars|Number|7"] = true } },
    { id = 11, dir = "/p", filename = "IMG_1.JPG", epoch = 0, model = "a", tags = {} },
    { id = 12, dir = "/p", filename = "IMG_2.JPG", epoch = 50, tags = {} },
})
local pair_opts = { gap = 2, camera = true, tag = "Cars|Red", parent = "Cars|Number", trace = true }
local pair_result = A.run_layers(pair, pair_opts)
local wanted = A.wanted_tags(pair, pair_result, STAMP, pair_opts)
check("wanted_tags: both members of a pair get the same set", keys(wanted[10]), keys(wanted[11]))
check("wanted_tags: trace on writes the layer trace tags", keys(wanted[10]),
    "Assisted Grouping|2026-11-08 22:45:10|Burst|0001 + Assisted Grouping|2026-11-08 22:45:10|Camera|a"
    .. " + Assisted Grouping|2026-11-08 22:45:10|Group|0001 + Assisted Grouping|2026-11-08 22:45:10|Parent|7"
    .. " + Assisted Grouping|2026-11-08 22:45:10|Tag|has Red")
check("wanted_tags: absent tag and child read not/none", wanted[12]["Assisted Grouping|2026-11-08 22:45:10|Tag|not Red"]
    and wanted[12]["Assisted Grouping|2026-11-08 22:45:10|Parent|none"], true)
local untraced_opts = { gap = 2, camera = true, tag = "Cars|Red", parent = "Cars|Number", trace = false }
local untraced = A.wanted_tags(pair, A.run_layers(pair, untraced_opts), STAMP, untraced_opts)
check("wanted_tags: trace off writes Group only", keys(untraced[10]),
    "Assisted Grouping|2026-11-08 22:45:10|Group|0001")
local plain = A.wanted_tags(pair, A.run_layers(pair, { gap = 2 }), STAMP, { gap = 2 })
check("wanted_tags: timing alone writes Group only (Burst would be identical)", keys(plain[12]),
    "Assisted Grouping|2026-11-08 22:45:10|Group|0002")

-- Minimum burst size above 2 is a layer of its own: Burst keeps the bursts it dissolved.
do
    local min_trace_opts = { gap = 2, min_frames = 3, trace = true }
    local min_trace = A.wanted_tags(pair, A.run_layers(pair, min_trace_opts), STAMP, min_trace_opts)
    check("wanted_tags: minimum burst size 3 with trace on writes Burst beside Group", keys(min_trace[12]),
        "Assisted Grouping|2026-11-08 22:45:10|Burst|0002 + Assisted Grouping|2026-11-08 22:45:10|Group|0002")
    local min2_trace_opts = { gap = 2, min_frames = 2, trace = true }
    local min2_trace = A.wanted_tags(pair, A.run_layers(pair, min2_trace_opts), STAMP, min2_trace_opts)
    check("wanted_tags: minimum burst size 2 is no layer, so no Burst", keys(min2_trace[12]),
        "Assisted Grouping|2026-11-08 22:45:10|Group|0002")
    local min_alone_opts = { alone = true, tag = "Cars|Red", min_frames = 3, trace = true }
    local min_alone = A.wanted_tags(pair, A.run_layers(pair, min_alone_opts), STAMP, min_alone_opts)
    check("wanted_tags: minimum burst size 3 without timing writes no Burst",
        min_alone[12]["Assisted Grouping|2026-11-08 22:45:10|Burst|0002"], nil)
end

-- sessions: frames at 0 s, 10 min, 50 min and 55 min, one with no capture time; gap 30 min
local session_units = {
    cu(1, { epoch = 3000 }), cu(2, { epoch = 0 }), cu(3, { epoch = 600 }), cu(4, { epoch = 3300 }), cu(5, {}),
}
local session_of = A.sessions_of(session_units, 1800)
check("sessions_of: a gap above the session gap starts a new session; untimed frames have none",
    string.format("%s %s %s %s %s", session_of[1], session_of[2], session_of[3], session_of[4], session_of[5]), "2 1 1 2 nil")
check("sessions_of: a gap equal to the session gap does not split", A.sessions_of({ cu(1, { epoch = 0 }), cu(2, { epoch = 1800 }) }, 1800)[2], 1)
check("run_layers: no session_gap, no session_of", A.run_layers(session_units, { gap = 2 }).session_of, nil)
local session_opts = { gap = 2, session_gap = 1800 }
local session_result = A.run_layers(session_units, session_opts)
check("run_layers: session_gap leaves the groups alone", session_result.final_of, session_result.burst_of)
local session_wanted = A.wanted_tags(session_units, session_result, STAMP, session_opts)
check("wanted_tags: a timed frame gets Group and Session, trace off", keys(session_wanted[4]),
    "Assisted Grouping|2026-11-08 22:45:10|Group|" .. string.format("%04d", session_result.final_of[4])
    .. " + Assisted Grouping|2026-11-08 22:45:10|Session|0002")
check("wanted_tags: an untimed frame gets no Session", keys(session_wanted[5]),
    "Assisted Grouping|2026-11-08 22:45:10|Group|" .. string.format("%04d", session_result.final_of[5]))
check("latest_group_tag ignores Session tags",
    A.latest_group_tag({ ["Assisted Grouping|2026-11-08 22:45:10|Session|0002"] = true }), nil)

-- latest_group_tag -----------------------------------------------------------
local older = "Assisted Grouping|2026-01-01 10:00:00|Group|0003"
local newer = "Assisted Grouping|2026-11-08 22:45:10|Group|0001"
check("latest_group_tag picks the later stamp",
    A.latest_group_tag({ [older] = true, [newer] = true, ["Assisted Grouping|2026-12-01 00:00:00|Burst|0001"] = true }), newer)
check("latest_group_tag returns nil with none", A.latest_group_tag({ ["Cars|Red"] = true }), nil)
check("latest_group_tag ignores another prefix",
    A.latest_group_tag({ [older] = true, ["Other|2027-01-01 00:00:00|Group|0001"] = true }), older)

local five = "Assisted Grouping|2026-11-09 08:00:00|Group|10000"
check("latest_group_tag accepts a 5-digit group on a later stamp",
    A.latest_group_tag({ [older] = true, [five] = true }), five)
check("latest_group_tag ignores a malformed stamp",
    A.latest_group_tag({ ["Assisted Grouping|zzz|Group|0001"] = true }), nil)
check("latest_group_tag: malformed stamp cannot beat a real one",
    A.latest_group_tag({ [older] = true, ["Assisted Grouping|zzz|Group|0001"] = true }), older)

-- base_of_from_tags ----------------------------------------------------------
local base = A.base_of_from_tags({
    cu(1, { tags = { [newer] = true, [older] = true } }),
    cu(2, { tags = { [older] = true } }),
    cu(3, { tags = { ["Cars|Red"] = true } }),
    cu(4, { tags = { [newer] = true } }),
})
check("base_of_from_tags: shared latest tag shares a number", base[1] == base[4], true)
check("base_of_from_tags: dense from 1 by first appearance", base[1] .. base[2], "12")
check("base_of_from_tags: unit with no group tag is absent", base[3], nil)

-- ledger -----------------------------------------------------------------------
local odd = 'My "odd", tag'
local ledger_text = A.ledger_format({
    [5] = { tags = { [odd] = true, [newer] = true }, native = 3 },
    [3] = { tags = { [newer] = true } },
})
local parsed = A.ledger_parse(ledger_text)
check("ledger round trip keeps a name with , and \"", parsed[5] and parsed[5].tags[odd], true)
check("ledger round trip keeps the native leader", parsed[5] and parsed[5].native, 3)
check("ledger round trip: no native means nil", parsed[3] and parsed[3].native, nil)
check("ledger round trip keeps tag sets", parsed[5] and keys(parsed[5].tags), keys({ [odd] = true, [newer] = true }))
check("ledger_format is stable", A.ledger_format(parsed), ledger_text)
check("ledger_format quotes every field", ledger_text:match('^"","3","tag","') ~= nil, true)
check("ledger_parse of empty text", next(A.ledger_parse(""), "other") or #A.ledger_parse("").other, 0)
do -- library column: rows of other libraries pass through, 3-field rows belong to the current library
    local mixed = A.ledger_format({ [7] = { tags = { ["AG|x"] = true }, native = 7 } }, "libA")
    check("ledger_format writes the library key first", mixed:match('^"libA","7","tag","AG|x"\n') ~= nil, true)
    local old_rows = '"9","tag","AG|old"\n"9","group","9"\n'
    local l = A.ledger_parse(mixed .. old_rows, "libB")
    check("ledger_parse: another library's rows aren't ours", l[7], nil)
    check("ledger_parse: rows without a library column are ours", l[9] and l[9].tags["AG|old"] and l[9].native, 9)
    check("ledger_parse: the other library's rows are kept", #l.other, 2)
    local back = A.ledger_format(l, "libB")
    check("ledger_format: ours first, the other library's rows after",
        back, '"libB","9","tag","AG|old"\n"libB","9","group","9"\n"libA","7","tag","AG|x"\n"libA","7","group","7"\n')
    check("ledger_format of an unchanged file is stable", A.ledger_format(A.ledger_parse(back, "libB"), "libB"), back)
    local pruned, skipped = A.ledger_prune(l, function(id) return id == 9 end)
    check("ledger_prune keeps the image that exists", pruned .. "," .. tostring(skipped) .. "," .. tostring(l[9] ~= nil), "0,false,true")
    l[10] = { tags = { ["AG|gone"] = true } }
    pruned = A.ledger_prune(l, function(id) return id == 9 end)
    check("ledger_prune drops an image that's gone", pruned .. "," .. tostring(l[10]), "1,nil")
    pruned, skipped = A.ledger_prune(l, function() return false end)
    check("ledger_prune: nothing resolving means the lookup failed, not every image gone",
        pruned .. "," .. tostring(skipped) .. "," .. tostring(l[9] ~= nil), "0,true,true")
end

-- plan_replace -----------------------------------------------------------------
local add, remove = A.plan_replace(
    { ["Cars|Red"] = true, [older] = true, [newer] = true },
    { ["Cars|Red_not_in_ledger"] = true, [older] = true, [newer] = true },
    { [newer] = true, ["Assisted Grouping|x|Group|0009"] = true })
check("plan_replace never removes a user tag", table.concat(remove, " + "):find("Cars|Red", 1, true), nil)
check("plan_replace removes an old ledger tag no longer wanted", table.concat(remove, " + "), older)
check("plan_replace does not re-add a present wanted tag", table.concat(add, " + "), "Assisted Grouping|x|Group|0009")

-- plan_native ------------------------------------------------------------------
local function rec(id, filename) return { id = id, dir = "/shoot", filename = filename, tags = {} } end
local function alone(records)
    local out = {}
    for _, r in ipairs(records) do out[r.id] = { r } end
    return out
end
local function plan_str(plan)
    local groups = {}
    for _, g in ipairs(plan.groups) do
        groups[#groups + 1] = g.leader .. ":" .. table.concat(g.members, ",")
    end
    return string.format("detach %s; groups %s; skipped %d",
        table.concat(plan.detach, ","), table.concat(groups, " "), plan.skipped)
end

local r1, r2, r3, r4 = rec(1, "a.cr2"), rec(2, "b.cr2"), rec(3, "c.cr2"), rec(4, "d.cr2")
local units = A.collapse({ r3, r1, r4, r2 })
local final = { [1] = 1, [2] = 1, [3] = 1, [4] = 2 }
check("plan_native groups a fresh burst under its lowest id; a single frame stays alone",
    plan_str(A.plan_native(units, final, {}, alone({ r1, r2, r3, r4 }))),
    "detach 1,2,3; groups 1:1,2,3; skipped 0")

local hand = alone({ r1, r2, r3, r4 })
hand[2] = { r2, rec(9, "z.cr2") }
check("plan_native skips an image in a hand-made group and counts it",
    plan_str(A.plan_native(units, final, {}, hand)), "detach 1,3; groups 1:1,3; skipped 1")

local ledger = { [2] = { tags = {}, native = 1 }, [9] = { tags = {}, native = 1 } }
check("plan_native regroups an image whose group the plugin made",
    plan_str(A.plan_native(units, final, ledger, hand)), "detach 1,2,3; groups 1:1,2,3; skipped 0")

check("plan_native dissolves a ledger group for an image now alone",
    plan_str(A.plan_native(units, final, { [4] = { tags = {}, native = 3 } }, alone({ r1, r2, r3, r4 }))),
    "detach 1,2,3,4; groups 1:1,2,3; skipped 0")

local hand_two = alone({ r1, r2 })
hand_two[2] = { r2, rec(9, "z.cr2") }
local two = A.collapse({ r1, r2 })
check("plan_native forms no group when skipping leaves one image",
    plan_str(A.plan_native(two, { [1] = 1, [2] = 1 }, {}, hand_two)), "detach ; groups ; skipped 1")

check("plan_native leaves a lone image in a hand-made group uncounted",
    plan_str(A.plan_native(A.collapse({ r2 }), { [2] = 1 }, {}, hand_two)), "detach ; groups ; skipped 0")

do
local function grouped(leader, records)
    local out = {}
    for _, r in ipairs(records) do out[#out + 1] = r end
    out.leader = leader
    return out
end
local burst_now = grouped(1, { r1, r2, r3 })
local settled = { [1] = burst_now, [2] = burst_now, [3] = burst_now, [4] = grouped(4, { r4 }) }
local settled_ledger = { [1] = { tags = {}, native = 1 }, [2] = { tags = {}, native = 1 }, [3] = { tags = {}, native = 1 } }
check("plan_native leaves a group that already matches, led by its lowest id",
    plan_str(A.plan_native(units, final, settled_ledger, settled)) .. "; unchanged "
        .. A.plan_native(units, final, settled_ledger, settled).unchanged,
    "detach ; groups ; skipped 0; unchanged 3")
local led_by_2 = grouped(2, { r1, r2, r3 })
check("plan_native regroups a matching group led by another image",
    plan_str(A.plan_native(units, final, settled_ledger, { [1] = led_by_2, [2] = led_by_2, [3] = led_by_2, [4] = grouped(4, { r4 }) })),
    "detach 1,2,3; groups 1:1,2,3; skipped 0")
local wider = grouped(1, { r1, r2, r3, r4 })
check("plan_native regroups when the current group holds an image the plan leaves out",
    plan_str(A.plan_native(units, final, { [1] = { tags = {}, native = 1 }, [2] = { tags = {}, native = 1 },
        [3] = { tags = {}, native = 1 }, [4] = { tags = {}, native = 1 } },
        { [1] = wider, [2] = wider, [3] = wider, [4] = wider })),
    "detach 1,2,3,4; groups 1:1,2,3; skipped 0")
end

local raw, jpg, r7 = rec(5, "e.cr2"), rec(6, "e.jpg"), rec(7, "f.cr2")
local pair_units = A.collapse({ raw, jpg, r7 })
local paired = { [5] = { raw, jpg }, [6] = { raw, jpg }, [7] = { r7 } }
check("plan_native takes a RAW+JPEG pair darktable grouped on import into the burst",
    plan_str(A.plan_native(pair_units, { [5] = 1, [7] = 1 }, {}, paired)),
    "detach 5,6,7; groups 5:5,6,7; skipped 0")
check("plan_native groups a pair that is its own final group",
    plan_str(A.plan_native(pair_units, { [5] = 1, [7] = 2 }, {}, paired)),
    "detach 5,6; groups 5:5,6; skipped 0")
check("plan_native treats an unselected JPEG in the RAW's group as the same frame",
    plan_str(A.plan_native(A.collapse({ raw, r7 }), { [5] = 1, [7] = 1 }, {}, paired)),
    "detach 5,7; groups 5:5,7; skipped 0")

local mixed = { [5] = { raw, jpg }, [6] = { jpg, rec(9, "z.cr2") }, [7] = { r7 } }
check("plan_native skips the whole frame when one of its images is in a hand-made group",
    plan_str(A.plan_native(pair_units, { [5] = 1, [7] = 1 }, {}, mixed)), "detach ; groups ; skipped 2")

do
-- run 1 grouped 1,2 (leader 1) and 3,4 (leader 3); then 2 was moved into 3's group by hand
local moved_ledger = { [1] = { tags = {}, native = 1 }, [2] = { tags = {}, native = 1 },
    [3] = { tags = {}, native = 3 }, [4] = { tags = {}, native = 3 } }
local target = { r2, r3, r4 }
target.leader = 3
local moved = { [1] = { r1 }, [2] = target, [3] = target, [4] = target }
check("plan_native keeps an image moved by hand into another plugin group, that group, and the image left behind",
    plan_str(A.plan_native(units, { [1] = 1, [2] = 1, [3] = 1, [4] = 1 }, moved_ledger, moved)),
    "detach ; groups ; skipped 4")
end

do
-- run 1 grouped 1,2,3 (leader 1); then 2 was taken out by hand to stand alone
local out_ledger = { [1] = { tags = {}, native = 1 }, [2] = { tags = {}, native = 1 }, [3] = { tags = {}, native = 1 } }
local rest = { r1, r3 }
rest.leader = 1
local taken_out = { [1] = rest, [2] = { r2 }, [3] = rest, [4] = { r4 } }
check("plan_native keeps an image taken out of a plugin group by hand alone",
    plan_str(A.plan_native(units, final, out_ledger, taken_out)), "detach ; groups ; skipped 1")
-- the leader taken out: darktable hands the group to the next image
local rest_led_by_2 = { r2, r3 }
rest_led_by_2.leader = 2
check("plan_native keeps a leader taken out of a plugin group by hand alone",
    plan_str(A.plan_native(units, final, out_ledger, { [1] = { r1 }, [2] = rest_led_by_2, [3] = rest_led_by_2, [4] = { r4 } })),
    "detach ; groups ; skipped 1")
local split = { [1] = { r1 }, [2] = { r2 }, [3] = { r3 }, [4] = { r4 } }
local pair_ledger = { [1] = { tags = {}, native = 1 }, [2] = { tags = {}, native = 1 } }
check("plan_native leaves a two-image plugin group split by hand apart",
    plan_str(A.plan_native(units, { [1] = 1, [2] = 1, [3] = 2, [4] = 2 }, pair_ledger, split)),
    "detach 3,4; groups 3:3,4; skipped 2")
end

-- plan_verify --------------------------------------------------------------------
do
local stamp = A.run_stamp(1000000)
local function tagged(id, n)
    local r = rec(id, "v" .. id .. ".cr2")
    if n then r.tags[A.group_tag(stamp, "Group", n)] = true end
    return r
end
local function verify_str(v)
    local out = {}
    for _, f in ipairs(v.fresh) do out[#out + 1] = f.unit.id .. " " .. table.concat(f.reasons, "+") end
    return table.concat(out, "; ") .. " | broken " .. table.concat(v.broken, ",")
end
local both = { native_groups = true, write_tags = true }
local bare = { tagged(1), tagged(2), tagged(3), tagged(4) }
check("plan_verify lists every frame of a never-grouped selection",
    verify_str(A.plan_verify(A.collapse(bare), final, {}, alone(bare), both)),
    "1 darktable group differs+no Group tag; 2 darktable group differs+no Group tag; "
        .. "3 darktable group differs+no Group tag; 4 no Group tag | broken ")

local done = { tagged(1, 1), tagged(2, 1), tagged(3, 1), tagged(4, 2) }
local burst_now = { done[1], done[2], done[3], leader = 1 }
local done_ledger = { [1] = { tags = {}, native = 1 }, [2] = { tags = {}, native = 1 }, [3] = { tags = {}, native = 1 } }
check("plan_verify lists nothing when tags and groups match a fresh run",
    verify_str(A.plan_verify(A.collapse(done), final, done_ledger,
        { [1] = burst_now, [2] = burst_now, [3] = burst_now, [4] = { done[4], leader = 4 } }, both)),
    " | broken ")

local split = { tagged(1, 1), tagged(2, 1), tagged(3, 2), tagged(4, 3) }
check("plan_verify compares Group Tags by which frames share them, not by name",
    verify_str(A.plan_verify(A.collapse(split), final, {}, alone(split), { write_tags = true })),
    "1 Group tag differs; 2 Group tag differs; 3 Group tag differs | broken ")

local by_hand = alone(bare)
by_hand[2] = { bare[2], rec(9, "z.cr2") }
check("plan_verify leaves out a frame the run skips as hand-made, tags too",
    verify_str(A.plan_verify(A.collapse(bare), final, {}, by_hand, both)),
    "1 darktable group differs+no Group tag; 3 darktable group differs+no Group tag; 4 no Group tag | broken ")

local leaderless = alone(done)
leaderless[4] = { done[4], leader = 4, broken = true }
check("plan_verify lists an image whose darktable group has no leader inside it",
    verify_str(A.plan_verify(A.collapse(done), final, {}, leaderless, { native_groups = true })),
    "1 darktable group differs; 2 darktable group differs; 3 darktable group differs | broken 4")
end

-- plan_merge ---------------------------------------------------------------------
do
local function group(leader, ids)
    local out = { leader = leader }
    for _, id in ipairs(ids) do out[#out + 1] = { id = id } end
    return out
end
local g1, g5 = group(1, { 1, 2 }), group(5, { 5, 6, 3 })
local mplan = A.plan_merge({ g5, g1, g5 })
check("plan_merge joins every image of the selection's groups to the lowest id's group",
    mplan.target .. "; join " .. table.concat(mplan.join, ",") .. "; groups " .. mplan.groups .. "; images " .. #mplan.ids,
    "1; join 3,5,6; groups 2; images 5")
check("plan_merge: one group has nothing to merge", A.plan_merge({ g1, g1 }).groups, 1)
end

-- repoint_stale_leaders ------------------------------------------------------------
do
local sl = { [2] = { tags = {}, native = 1 }, [3] = { tags = {}, native = 1 },
    [5] = { tags = { x = true }, native = 4 }, [7] = { tags = {}, native = 7 }, [8] = { tags = {}, native = 7 } }
local n = A.repoint_stale_leaders(sl, function(id) return id ~= 1 and id ~= 4 end)
check("repoint_stale_leaders points a group at its lowest surviving id and frees a lone survivor",
    string.format("%d; %s %s %s %s %s", n, sl[2].native, sl[3].native, tostring(sl[5].native), sl[7].native, sl[8].native),
    "2; 2 2 nil 7 7")
end

-- run_layers with timing off ----------------------------------------------------
local untimed_off = A.run_layers(run_units, { gap = 2, timing = false })
check("timing off: every unit, timed or not, shares group 1", keys(untimed_off.burst_of) .. " / "
    .. untimed_off.burst_of[1] .. untimed_off.burst_of[4] .. untimed_off.burst_of[6], "1 + 2 + 3 + 4 + 5 + 6 / 111")
check("timing off: result.timing is false", untimed_off.timing, false)
check("timing default: result.timing is true", A.run_layers(run_units, { gap = 2 }).timing, true)
local cam_only = A.run_layers(run_units, { timing = false, camera = true })
check("timing off + camera: splits by camera only", cam_only.final_of[1] == cam_only.final_of[4]
    and cam_only.final_of[1] ~= cam_only.final_of[2], true)
local based_off = A.run_layers({ cu(1, { epoch = 0 }), cu(2, { epoch = 100 }), cu(3, { epoch = 0 }), cu(4, { epoch = 500 }) },
    { timing = false, base_of = { [1] = 1, [2] = 2 } })
check("timing off + base_of: the rest share one group after the base groups",
    based_off.burst_of[1] .. based_off.burst_of[2] .. based_off.burst_of[3] .. based_off.burst_of[4], "1233")
local alone_units = { cu(1, { epoch = 0 }), cu(2, { epoch = 1 }), cu(3, { epoch = 2 }), cu(4, { epoch = 3 }) }
local alone_run = A.run_layers(alone_units, { alone = true, base_of = { [1] = 1, [2] = 1 } })
check("run_layers alone: base groups kept, rest each alone",
    alone_run.burst_of[1] == 1 and alone_run.burst_of[2] == 1 and alone_run.burst_of[3] ~= alone_run.burst_of[4]
    and alone_run.burst_of[3] ~= 1 and alone_run.burst_of[4] ~= 1, true)
check("run_layers alone: result.timing is false", alone_run.timing, false)
local alone_empty = A.run_layers(alone_units, { alone = true, base_of = {} })
check("run_layers alone: empty base_of gives one group per unit",
    alone_empty.burst_of[1] .. alone_empty.burst_of[2] .. alone_empty.burst_of[3] .. alone_empty.burst_of[4], "1234")
local no_burst = A.wanted_tags(pair, A.run_layers(pair, { timing = false }), STAMP, { trace = true })
check("wanted_tags: timing off writes no Burst tag", keys(no_burst[12]),
    "Assisted Grouping|2026-11-08 22:45:10|Group|0001")

-- parse_gap --------------------------------------------------------------------
check("parse_gap: integer text", A.parse_gap("2"), 2)
check("parse_gap: decimal point", A.parse_gap("0.5"), 0.5)
check("parse_gap: decimal comma", A.parse_gap("1,5"), 1.5)
check("parse_gap: surrounding spaces", A.parse_gap("  3 "), 3)
check("parse_gap: leading dot", A.parse_gap(".25"), 0.25)
check("parse_gap: number input", A.parse_gap(2), 2)
check("parse_gap: zero is rejected", A.parse_gap("0"), nil)
check("parse_gap: negative is rejected", A.parse_gap("-1"), nil)
check("parse_gap: hex is rejected", A.parse_gap("0x10"), nil)
check("parse_gap: exponent is rejected", A.parse_gap("1e3"), nil)
check("parse_gap: blank is rejected", A.parse_gap(""), nil)
check("parse_gap: lone dot is rejected", A.parse_gap("."), nil)
check("parse_gap: nil is rejected", A.parse_gap(nil), nil)
check("parse_gap: two dots are rejected", A.parse_gap("1.2.3"), nil)

-- panel_options ------------------------------------------------------------------
local function panel(over)
    local p = { start_from = "time", gap_text = "2", min_size_text = "2", camera = false, tag = "", parent = "",
        write_tags = true, native_groups = false }
    for k, v in pairs(over or {}) do p[k] = v end
    return p
end
local o, why = A.panel_options(panel({ write_tags = false, native_groups = false }))
check("panel_options: both outputs off refuses", tostring(o) .. " / " .. tostring(why), "nil / " .. A.ERR_NO_OUTPUT)
o, why = A.panel_options(panel({ gap_text = "abc" }))
check("panel_options: bad gap with timing on refuses", why, A.ERR_BAD_GAP)
o = A.panel_options(panel({ gap_text = "abc", start_from = "one", camera = true }))
check("panel_options: bad gap ignored with timing off", o and o.gap, nil)
check("panel_options: timing off passes timing = false", o and o.timing, false)
o, why = A.panel_options(panel({ start_from = "one" }))
check("panel_options: no layer and no refine refuses", why, A.ERR_NO_LAYER)
o = A.panel_options(panel({ start_from = "tags", native_groups = true, write_tags = false }))
check("panel_options: refine alone is enough", o ~= nil and o.refine and o.native_groups and not o.write_tags, true)
o = A.panel_options(panel({ gap_text = "0,5", tag = "  Cars|Red ", parent = " Cars|Number| " }))
check("panel_options: gap parsed, tag trimmed, trailing | dropped from parent",
    o.gap .. " / " .. o.tag .. " / " .. o.parent, "0.5 / Cars|Red / Cars|Number")
o = A.panel_options(panel({ tag = "   ", parent = "|" }))
check("panel_options: blank tag and parent become nil", o.tag == nil and o.parent == nil, true)
check("panel_options: minimum burst size 2 by default text", o.min_frames, 2)
check("panel_options: minimum burst size parsed", A.panel_options(panel({ min_size_text = " 4 " })).min_frames, 4)
o, why = A.panel_options(panel({ min_size_text = "1" }))
check("panel_options: minimum burst size under 2 refuses", tostring(o) .. " / " .. tostring(why), "nil / " .. A.ERR_BAD_MIN_SIZE)
o, why = A.panel_options(panel({ min_size_text = "abc", start_from = "one", camera = true }))
check("panel_options: bad minimum refuses with timing off too", why, A.ERR_BAD_MIN_SIZE)

local parsed_sizes = {}
for _, text in ipairs({ "2", " 10 ", "1", "0", "2.5", "-3", "", "three", "3 4" }) do
    parsed_sizes[#parsed_sizes + 1] = tostring(A.parse_min_size(text))
end
check("parse_min_size: whole numbers of 2 or more only", table.concat(parsed_sizes, " "), "2 10 nil nil nil nil nil nil nil")
check("parse_min_size: a number from a preset", A.parse_min_size(3), 3)

check("panel_options: session gap off by default", A.panel_options(panel()).session_gap, nil)
check("panel_options: session gap 0 is off", A.panel_options(panel({ session_gap_text = "0" })).session_gap, nil)
check("panel_options: session gap minutes become seconds", A.panel_options(panel({ session_gap_text = " 1,5 " })).session_gap, 90)
o, why = A.panel_options(panel({ session_gap_text = "soon" }))
check("panel_options: bad session gap refuses", tostring(o) .. " / " .. tostring(why), "nil / " .. A.ERR_BAD_SESSION_GAP)
local parsed_sessions = {}
for _, text in ipairs({ "", "0", "30", "0.5", "2,5", "-1", "1e3", "half", "." }) do
    parsed_sessions[#parsed_sessions + 1] = tostring(A.parse_session_gap(text))
end
check("parse_session_gap: blank and 0 are off, numbers above 0 pass", table.concat(parsed_sessions, " "), "0 0 30 0.5 2.5 nil nil nil nil")

check("start_from_of: refine wins", A.start_from_of(true, true), "tags")
check("start_from_of: timing off", A.start_from_of(false, false), "one")
check("start_from_of: nil keys default to time", A.start_from_of(nil, nil), "time")

local function upgraded(text) return A.preset_merge(A.PRESET_SCHEMA, A.preset_decode((A.upgrade_preset_text(text)))) end
check("upgrade_preset_text: timing=false, refine=true loads as tags",
    (upgraded('{"version": 1, "timing": false, "refine": true}')).start_from, "tags")
check("upgrade_preset_text: both on loads as tags",
    (upgraded('{"version": 1, "timing": true, "refine": true}')).start_from, "tags")
check("upgrade_preset_text: timing=false, refine=false loads as one",
    (upgraded('{"version": 1, "timing": false, "refine": false}')).start_from, "one")
local empty_s, empty_problems = upgraded("{}")
check("upgrade_preset_text: empty object loads as time", empty_s.start_from .. " " .. #empty_problems, "time 0")
local has_start = '{"version": 1, "start_from": "one"}'
check("upgrade_preset_text: start_from present is returned unchanged", A.upgrade_preset_text(has_start), has_start)
check("upgrade_preset_text: undecodable text is returned unchanged", A.upgrade_preset_text("not json"), "not json")

local up_on, up_on_notes = A.upgrade_preset_text('{"write_tags":true}')
check("upgrade_preset_text: write_tags true turns trace_tags on", A.preset_decode(up_on).trace_tags, true)
check("upgrade_preset_text: write_tags true notes one line", up_on_notes and #up_on_notes, 1)
local _, up_off_notes = A.upgrade_preset_text('{"write_tags":false}')
check("upgrade_preset_text: write_tags false leaves trace_tags default",
    (upgraded('{"write_tags":false}')).trace_tags, false)
check("upgrade_preset_text: write_tags false has no note", up_off_notes, nil)
local kept = '{"write_tags":true,"trace_tags":false,"start_from":"time"}'
local kept_text, kept_notes = A.upgrade_preset_text(kept)
check("upgrade_preset_text: trace_tags present is kept", kept_text .. tostring(kept_notes), kept .. "nil")
local json_text, json_notes = A.upgrade_preset_text("not json")
check("upgrade_preset_text: undecodable text has no notes", tostring(json_notes), "nil")
local kinds = {}
for _, k in ipairs(A.TAG_KINDS) do kinds[k.kind] = true end
local toggles_ok = true
for _, t in ipairs(A.TAG_TOGGLES) do if not kinds[t.kind] then toggles_ok = false end end
check("TAG_TOGGLES: every row has a kind in TAG_KINDS", toggles_ok, true)
check("NOTICE_TAGS_OFF names Group Tags", A.NOTICE_TAGS_OFF,
    "Turn on Group Tags, or this run's groups aren't saved for the next run to start from.")

check("panel_notice: fine is empty", A.panel_notice(panel()), "")
check("panel_notice: both outputs off", A.panel_notice(panel({ write_tags = false, native_groups = false })), A.ERR_NO_OUTPUT)
check("panel_notice: bad gap with capture time", A.panel_notice(panel({ gap_text = "abc" })), A.ERR_BAD_GAP)
check("panel_notice: bad minimum burst size", A.panel_notice(panel({ min_size_text = "1" })), A.ERR_BAD_MIN_SIZE)
check("panel_notice: bad session gap", A.panel_notice(panel({ session_gap_text = "soon" })), A.ERR_BAD_SESSION_GAP)
check("panel_notice: session gap with Group Tags on is fine", A.panel_notice(panel({ session_gap_text = "30" })), "")
check("panel_notice: session gap without Group Tags",
    A.panel_notice(panel({ session_gap_text = "30", write_tags = false, native_groups = true })), A.NOTICE_SESSION_TAGS_OFF)
check("panel_notice: bad gap comes before a bad minimum", A.panel_notice(panel({ gap_text = "abc", min_size_text = "1" })), A.ERR_BAD_GAP)
check("panel_notice: bad gap ignored with one group", A.panel_notice(panel({ gap_text = "abc", start_from = "one", camera = true })), "")
check("panel_notice: tags source without write tags", A.panel_notice(panel({ start_from = "tags", write_tags = false, native_groups = true })), A.NOTICE_TAGS_OFF)
check("panel_notice: tags source counts as a layer", A.panel_notice(panel({ start_from = "tags", write_tags = true })), "")
check("panel_notice: one group without a layer", A.panel_notice(panel({ start_from = "one" })), A.NOTICE_NO_LAYER)
check("panel_notice: outputs off outranks bad gap",
    A.panel_notice(panel({ gap_text = "abc", write_tags = false, native_groups = false })), A.ERR_NO_OUTPUT)

-- plan_clear -----------------------------------------------------------------------
local clear_ledger = {
    [1] = { tags = { ["AG|a"] = true, ["AG|gone"] = true }, native = 1 },
    [2] = { tags = {}, native = 1 },
    [3] = { tags = { ["AG|b"] = true }, native = 3 },
    [4] = { tags = {}, native = 9 },
}
local clear_records = {
    { id = 1, tags = { ["AG|a"] = true, ["Mine"] = true } },
    { id = 2, tags = {} },
    { id = 3, tags = { ["AG|b"] = true } },
    { id = 4, tags = {} },
    { id = 5, tags = { ["AG|a"] = true } },
}
local clear_members = {
    [1] = { { id = 1 }, { id = 2 } },
    [2] = { { id = 1 }, { id = 2 } },
    [3] = { { id = 3 } },
    [4] = { { id = 4 }, { id = 7 } },
    [5] = { { id = 5 } },
}
local cplans = A.plan_clear(clear_records, clear_ledger, clear_members)
local function cplan_str(pl)
    local out = {}
    for _, x in ipairs(pl) do
        out[#out + 1] = string.format("%d:%s:%s", x.id, table.concat(x.detach, ","), tostring(x.ungroup))
    end
    return table.concat(out, " ")
end
check("plan_clear: ledger tags on the image only, hand tags and unledgered images left",
    cplan_str(cplans), "1:AG|a:true 2::true 3:AG|b:false 4::false")
check("plan_clear: a leader alone in its group is not ungrouped", cplans[3].ungroup, false)
check("plan_clear: an image moved into a hand-made group is not ungrouped", cplans[4].ungroup, false)
local stale = A.plan_clear({ { id = 2, tags = {} } }, { [2] = { tags = {}, native = 1 }, [6] = { tags = {}, native = 1 } },
    { [2] = { { id = 2 }, { id = 6 } } })
check("plan_clear: group still ours after its leader left (another member shares the leader id)",
    stale[1].ungroup, true)
local _, no_name_restore = A.plan_clear(clear_records, clear_ledger, clear_members)
check("plan_clear: records without filenames get no restore group", #no_name_restore, 0)

-- Two RAW+JPEG frames (11/12 and 13/14) regrouped by the plugin under 11, then cleared;
-- 15 is a lone image in the same plugin group; 21/22 are two frames with plugin tags that
-- the user grouped by hand.
local function crec(id, filename) return { id = id, tags = {}, dir = "/s", filename = filename } end
local pair_ledger = {
    [11] = { tags = {}, native = 11 }, [12] = { tags = {}, native = 11 },
    [13] = { tags = {}, native = 11 }, [14] = { tags = {}, native = 11 },
    [15] = { tags = {}, native = 11 },
    [21] = { tags = { ["AG|x"] = true } }, [22] = { tags = { ["AG|x"] = true } },
}
local plugin_group = { { id = 11 }, { id = 12 }, { id = 13 }, { id = 14 }, { id = 15 } }
local hand_group = { { id = 21 }, { id = 22 } }
local pplans, prestore = A.plan_clear(
    { crec(11, "DSC1.ARW"), crec(12, "DSC1.JPG"), crec(13, "DSC2.ARW"), crec(14, "DSC2.JPG"),
      crec(15, "DSC3.ARW"), crec(21, "DSC4.JPG"), crec(22, "DSC5.JPG") },
    pair_ledger,
    { [11] = plugin_group, [12] = plugin_group, [13] = plugin_group, [14] = plugin_group,
      [15] = plugin_group, [21] = hand_group, [22] = hand_group })
local function restore_str(rs)
    local out = {}
    for _, g in ipairs(rs) do out[#out + 1] = g.leader .. ":" .. table.concat(g.members, ",") end
    return table.concat(out, " ")
end
check("plan_clear: two cleared RAW+JPEG pairs -> two restore groups under their lowest ids",
    restore_str(prestore), "11:11,12 13:13,14")
check("plan_clear: a lone image gets no restore group", restore_str(prestore):find("15") == nil, true)
check("plan_clear: hand-made cross-frame group is left alone", pplans[6].ungroup or pplans[7].ungroup, false)

-- plan_partners -----------------------------------------------------------------------
do
local partner_ledger = { [11] = { tags = {} }, [12] = { tags = {} }, [14] = { tags = {} }, [16] = { tags = {} } }
local partners = A.plan_partners({ crec(11, "DSC1.ARW"), crec(13, "DSC2.ARW") },
    { crec(12, "dsc1.jpg"), crec(11, "DSC1.ARW"), crec(14, "DSC2.JPG"), crec(15, "DSC2.HEIC"), crec(16, "DSC3.JPG"), crec(12, "dsc1.jpg") },
    partner_ledger)
local ids = {}
for _, p in ipairs(partners) do ids[#ids + 1] = p.id end
check("plan_partners: unselected same-frame images the ledger lists, each once; selected, unledgered and other frames left",
    table.concat(ids, ","), "12,14")
end

-- plan_pairs --------------------------------------------------------------------------
local pair_groups = A.plan_pairs({
    crec(14, "DSC0002.JPG"), crec(11, "DSC0001.ARW"), crec(12, "dsc0001.jpg"), crec(13, "DSC0002.ARW"),
    crec(15, "DSC0003.JPG"), crec(12, "dsc0001.jpg"),
    { id = 16, tags = {}, dir = "/other", filename = "DSC0001.JPG" },
})
check("plan_pairs: one group per frame under its lowest id, stem case ignored, repeats once",
    restore_str(pair_groups), restore_str({ { leader = 11, members = { 11, 12 } }, { leader = 13, members = { 13, 14 } } }))
check("plan_pairs: no records, no groups", #A.plan_pairs({}), 0)

-- subsec_fractions ------------------------------------------------------------------
local function srec(id, dir, filename, epoch) return { id = id, dir = dir, filename = filename, epoch = epoch == nil and 100 or epoch } end
local function near(a, b) return a ~= nil and math.abs(a - b) < 1e-6 end
local sf, smiss = A.subsec_fractions({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "DSC1.JPG") },
    { [1] = "", [2] = "1780308000.897" })
check("subsec_fractions: RAW with a blank row borrows its JPEG's fraction", near(sf[1], 0.897) and near(sf[2], 0.897), true)
check("subsec_fractions: pair leaves nothing missing", smiss, nil)
sf, smiss = A.subsec_fractions({ srec(1, "/s", "DSC1.ARW") }, { [1] = "" })
check("subsec_fractions: RAW with no sibling has no fraction", sf[1], nil)
check("subsec_fractions: RAW with no sibling is reported missing", smiss, 1)
sf, smiss = A.subsec_fractions({ srec(1, "/s", "DSC1.ARW") }, {})
check("subsec_fractions: absent row with no sibling is reported missing", smiss, 1)
sf, smiss = A.subsec_fractions({ srec(2, "/s", "DSC2.JPG") }, { [2] = "1780308000.25" })
check("subsec_fractions: JPEG alone keeps its own fraction", near(sf[2], 0.25) and smiss == nil, true)
sf, smiss = A.subsec_fractions({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "dsc1.jpg") },
    { [1] = "", [2] = "1780308000.5" })
check("subsec_fractions: stem case differs → same frame (as darktable's import grouping), borrows",
    near(sf[1], 0.5) and smiss == nil, true)
check("collapse: DSC1.ARW + dsc1.jpg are one frame", #A.collapse({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "dsc1.jpg") }), 1)
sf = A.subsec_fractions({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "DSC1.jpg") }, { [1] = "", [2] = "1780308000.5" })
check("subsec_fractions: extension case is ignored, borrows", near(sf[1], 0.5), true)
sf, smiss = A.subsec_fractions({ srec(1, "/a", "DSC1.ARW"), srec(2, "/b", "DSC1.JPG") },
    { [1] = "", [2] = "1780308000.5" })
check("subsec_fractions: same stem in another folder does not lend", tostring(sf[1]) .. " / " .. tostring(smiss), "nil / 1")
sf, smiss = A.subsec_fractions({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "DSC1.JPG") },
    { [1] = "1780308000", [2] = "1780308000.5" })
check("subsec_fractions: a whole-second (non-blank) row does not borrow", tostring(sf[1]) .. " / " .. tostring(smiss), "nil / 1")
sf, smiss = A.subsec_fractions({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "DSC1.JPG"), srec(3, "/s", "X.JPG", false) },
    { [1] = "", [2] = "" })
check("subsec_fractions: blank pair has no fraction; untimed records are ignored",
    tostring(sf[1]) .. tostring(sf[2]) .. tostring(sf[3]) .. " / " .. tostring(smiss), "nilnilnil / 1")

-- ledger on Windows: text mode writes CRLF ----------------------------------------
local crlf = A.ledger_parse((ledger_text:gsub("\n", "\r\n")))
check("ledger_parse of CRLF text matches LF", A.ledger_format(crlf), ledger_text)

-- wanted_tags: Refine alone writes no Burst --------------------------------------
local refine_units = A.collapse({
    { id = 1, dir = "/r", filename = "A.JPG", epoch = 0, tags = { [newer] = true } },
    { id = 2, dir = "/r", filename = "B.JPG", epoch = 100, tags = {} },
})
local refine_opts = { gap = 2, trace = true, base_of = A.base_of_from_tags(refine_units) }
local refine_wanted = A.wanted_tags(refine_units, A.run_layers(refine_units, refine_opts), STAMP, refine_opts)
check("wanted_tags: Refine alone writes Group only", keys(refine_wanted[2]),
    "Assisted Grouping|2026-11-08 22:45:10|Group|0002")

-- darktable glue helpers ------------------------------------------------------------

check("needs_tags: defaults minus tag writer read no tags", A.needs_tags({ timing = true, native_groups = true }), false)
check("needs_tags: tag writer reads tags", A.needs_tags({ write_tags = true }), true)
check("needs_tags: Refine reads tags", A.needs_tags({ refine = true }), true)

local function arec(id, filename, epoch, tags)
    return { id = id, dir = "/a", filename = filename, file = "/a/" .. filename, epoch = epoch, tags = tags or {} }
end
local a_units = A.collapse({
    arec(1, "DSC1.ARW", 100), arec(2, "DSC1.JPG", 100),
    arec(3, "DSC2.ARW", 200),
    arec(4, "DSC3.ARW", 300), arec(5, "DSC3.JPG", nil),
    arec(6, "DSC4.JPG", nil),
})
local function row_ids(rows)
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r[1] end
    return table.concat(out, ",")
end
check("manifest_rows: one row per frame, the JPEG of a pair, a RAW alone, undated JPEG skipped, untimed frame left out",
    row_ids(A.manifest_rows(a_units)), "2,3,4")

check("units_to_time: timing off times nothing", #A.units_to_time(a_units, false, nil), 0)
check("units_to_time: untimed frame left out", #A.units_to_time(a_units, true, nil), 3)
check("units_to_time: frames with a Refine group left out", #A.units_to_time(a_units, true, { [1] = 1, [3] = 1 }), 1)
check("members_of: every member of the units", #A.members_of(a_units), 6)

local sub_units = A.collapse({ arec(1, "DSC1.ARW", 100), arec(2, "DSC1.JPG", 100) })
local sub_members = A.members_of(sub_units)
local prec = A.apply_subsec(sub_units, "2,1780308000.5\r\n#precision,subsecond\r\n")
check("apply_subsec: RAW not sent borrows its JPEG's fraction (CRLF results)",
    prec == "subsecond" and near(sub_members[1].epoch, 100.5) and near(sub_members[2].epoch, 100.5), true)
local whole_units = A.collapse({ arec(1, "DSC1.JPG", 100) })
local whole_members = A.members_of(whole_units)
local wprec, wwhy = A.apply_subsec(whole_units, "1,1780308000\n#precision,whole\n")
check("apply_subsec: whole precision leaves epochs", wprec .. " " .. tostring(whole_members[1].epoch), "whole 100")
check("apply_subsec: whole precision says why", wwhy ~= nil, true)
check("apply_subsec: nothing timed", select(2, A.apply_subsec(A.collapse({ arec(1, "X.JPG", nil) }), "")),
    "no frame has a capture time")

-- per-camera precision: body A has fractions on every frame, body B on none
local function crec(id, filename, epoch, model)
    local r = arec(id, filename, epoch)
    r.maker, r.model = "SONY", model
    return r
end
local function two_bodies()
    return A.collapse({ crec(1, "A1.JPG", 100, "A7"), crec(2, "A2.JPG", 101, "A7"),
        crec(3, "B1.JPG", 100, "ZV"), crec(4, "B2.JPG", 102, "ZV") })
end
local key_a, key_b = A.camera_key({ maker = "SONY", model = "A7" }), A.camera_key({ maker = "SONY", model = "ZV" })
local mixed_text = "1,1780308000.25\n2,1780308001.5\n3,1780308000\n4,1780308002\n" ..
    "#precision,subsecond," .. key_a .. "\n#precision,whole," .. key_b .. "\n#precision,whole\n"
local cam_units = two_bodies()
local cprec, cwhy, cwhole = A.apply_subsec(cam_units, mixed_text, true)
local cam_members = A.members_of(cam_units)
check("apply_subsec Camera on: body with fractions keeps them, the other stays whole",
    cprec .. " " .. tostring(cwhy) .. " " .. tostring(cwhole[key_a]) .. " " .. tostring(cwhole[key_b] ~= nil)
    .. " " .. tostring(near(cam_members[1].epoch, 100.25)) .. " " .. cam_members[3].epoch, "mixed nil nil true true 100")
local off_units = two_bodies()
local oprec = A.apply_subsec(off_units, mixed_text, false)
check("apply_subsec Camera off: one timeline, whole when any frame lacks a fraction",
    oprec .. " " .. A.members_of(off_units)[1].epoch, "whole 100")
check("manifest_rows: Camera on adds the camera_key column", A.manifest_rows(two_bodies(), true)[3][3], key_b)
check("manifest_rows: Camera off keeps two columns", A.manifest_rows(two_bodies(), false)[1][3], nil)

local by_id, hprec, hprec_of = A.parse_helper_results("7,1780308000.25\n8,\n#precision,whole,Cam B\n#precision,subsecond\n")
check("parse_helper_results: rows and precision", by_id[7] .. "|" .. by_id[8] .. "|" .. hprec, "1780308000.25||subsecond")
check("parse_helper_results: per-camera precision rows", hprec_of["Cam B"], "whole")

check("count_tagged: frames with the tag", A.count_tagged(A.collapse({ arec(1, "A.JPG", 1, { ["Cars|Red"] = true }),
    arec(2, "B.JPG", 1) }), "Cars|Red"), 1)
check("count_tagged: a spelling with spaces matches nothing", A.count_tagged(A.collapse({ arec(1, "A.JPG", 1, { ["Cars|Red"] = true }) }),
    "Cars | Red"), 0)

local ptc = A.plan_tag_changes({ arec(1, "A.JPG", 1, { ["old"] = true, ["hand"] = true }) },
    { [1] = { ["new"] = true } }, { [1] = { tags = { ["old"] = true, ["gone"] = true } } })
check("plan_tag_changes: detaches own tag, keeps hand-made, attaches new",
    table.concat(ptc[1].remove, ",") .. " / " .. table.concat(ptc[1].add, ","), "old / new")
check("plan_tag_changes: ledger tag removed by hand is dropped", ptc[1].mine["gone"], nil)

local lg = { [1] = { tags = { x = true } } }
A.set_ledger_tags(lg, 1, {})
check("set_ledger_tags: empty entry dropped", lg[1], nil)
A.set_ledger_native(lg, 2, 2)
A.set_ledger_tags(lg, 2, {})
check("set_ledger_tags: entry with a native leader kept", lg[2] and lg[2].native, 2)
A.set_ledger_native(lg, 2, nil)
check("set_ledger_native: cleared entry dropped", lg[2], nil)

local s1, t1 = A.run_stamp(1000, nil)
local s2, t2 = A.run_stamp(1000, t1)
check("run_stamp: same second steps forward", t2 == t1 + 1 and s2 > s1, true)
check("run_stamp: later time used as is", select(2, A.run_stamp(2000, t2)), 2000)
check("run_stamp: written in UTC", A.run_stamp(1780308000, nil), "2026-06-01 10:00:00")

check("pythonw_of: venv python.exe", A.pythonw_of("C:/x/.venv/Scripts/python.exe"), "C:/x/.venv/Scripts/pythonw.exe")
check("pythonw_of: case-insensitive", A.pythonw_of("C:\\Py\\Python.EXE"), "C:\\Py\\pythonw.exe")
check("pythonw_of: bare python on PATH", A.pythonw_of("python"), "pythonw")
check("pythonw_of: other launcher is refused", A.pythonw_of("C:/Windows/py.exe"), nil)

local tmp_path = os.tmpname()
check("write_file_atomic: replaces an existing file", A.write_file_atomic(tmp_path, "one\n") and A.write_file_atomic(tmp_path, "two\n"), true)
check("write_file_atomic: new text read back", A.read_file_or_tmp(tmp_path), "two\n")
check("write_file_atomic: no .tmp left", io.open(tmp_path .. ".tmp", "r"), nil)
os.remove(tmp_path)
local tf = io.open(tmp_path .. ".tmp", "w"); tf:write("saved\n"); tf:close()
check("read_file_or_tmp: falls back to .tmp when the file is missing", A.read_file_or_tmp(tmp_path), "saved\n")
os.remove(tmp_path .. ".tmp")
check("write_file_atomic: unwritable folder fails", A.write_file_atomic("/nonexistent-dir-xyz/ledger.csv", "x"), nil)

require("test_preset_block")(A, check)

local pd = A.preset_defaults(A.PRESET_SCHEMA)
check("preset schema: defaults", string.format("%s %s %s %s [%s] [%s] %s %s %s", pd.start_from, pd.burst_gap_seconds,
    pd.min_burst_size, pd.camera, pd.tag, pd.parent, pd.native_groups, pd.write_tags, pd.session_gap_minutes),
    "time 2 2 false [] [] true false 0")
do
    local round_trip = A.preset_merge(A.PRESET_SCHEMA, A.preset_decode(PC.preset_encode(A.PRESET_SCHEMA,
        { min_burst_size = 4, session_gap_minutes = 2.5 })))
    check("preset schema: min_burst_size and session_gap_minutes survive a save and load",
        string.format("%s %s", round_trip.min_burst_size, round_trip.session_gap_minutes), "4 2.5")
end
check("preset schema: a preset without min_burst_size loads as 2",
    A.preset_merge(A.PRESET_SCHEMA, A.preset_decode('{"burst_gap_seconds": 0.5}')).min_burst_size, 2)
local readme_file = assert(io.open(script_dir .. "/../README.md", "rb"))
local README = readme_file:read("a")
readme_file:close()
local quoted = {}
for _, message in ipairs({ A.ERR_BAD_GAP, A.ERR_BAD_MIN_SIZE, A.ERR_BAD_SESSION_GAP, A.NOTICE_SESSION_TAGS_OFF }) do
    quoted[#quoted + 1] = tostring(README:find(message, 1, true) ~= nil)
end
check("README quotes the bad-gap, bad-minimum and session messages", table.concat(quoted, " "), "true true true true")
local _, start_problems = A.preset_merge(A.PRESET_SCHEMA, A.preset_decode('{"start_from": "yesterday"}'))
check("preset schema: start_from accepts only its choices", table.concat(start_problems, " "):find("start_from", 1, true) ~= nil, true)
check("preset schema: decimal gap kept", A.preset_merge(A.PRESET_SCHEMA, A.preset_decode('{"burst_gap_seconds": 0.5}')).burst_gap_seconds, 0.5)
local page_missing, page_duplicate = PC.page_coverage(A.PANEL_PAGES, A.PANEL_OTHER_KEYS, A.PRESET_SCHEMA)
check("PANEL_PAGES: every preset key is on one page or listed off-stack",
    table.concat(page_missing, " ") .. table.concat(page_duplicate, " "), "")
local page_titles = {}
for _, p in ipairs(A.PANEL_PAGES) do page_titles[#page_titles + 1] = p.title end
check("PANEL_PAGES: titles match the README sections", table.concat(page_titles, ","),
    "Start Groups,Divide Groups,Output,Run,Tools")

-- summary --------------------------------------------------------------------
if failures > 0 then
    print(string.format("%d failure(s)", failures))
    os.exit(1)
end
print("all passed")

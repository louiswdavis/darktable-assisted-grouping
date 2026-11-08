-- Run with: lua lua/test_grouping_core.lua (from the repo) or lua test_grouping_core.lua (from lua/)
-- Exercises grouping_core.lua directly; no darktable needed.

local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = script_dir .. "/?.lua;./?.lua;" .. package.path
local C = require("grouping_core")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %s", name))
    end
end

local function keys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, " + ")
end

-- exif_time_to_epoch -------------------------------------------------------
check("parses a normal timestamp", C.exif_time_to_epoch("2026:06:01 14:30:00") ~= nil, true)
check("returns nil for missing timestamp", C.exif_time_to_epoch(nil), nil)
check("returns nil for garbage input", C.exif_time_to_epoch("not a date"), nil)
check("returns nil for an all-zero date", C.exif_time_to_epoch("0000:00:00 00:00:00"), nil)
check("returns nil for a pre-1970 date", C.exif_time_to_epoch("1965:03:01 12:00:00"), nil)
check("normal date unchanged by the pre-1970 guard",
    C.exif_time_to_epoch("2026:06:01 14:30:00"),
    os.time({ year = 2026, month = 6, day = 1, hour = 14, min = 30, sec = 0, isdst = false }))
do
    local zero_units = C.collapse({
        { id = 1, dir = "d", filename = "a.jpg", epoch = C.exif_time_to_epoch("2026:06:01 14:30:00") },
        { id = 2, dir = "d", filename = "b.jpg", epoch = C.exif_time_to_epoch("0000:00:00 00:00:00") },
        { id = 3, dir = "d", filename = "c.jpg", epoch = C.exif_time_to_epoch("2026:06:01 14:30:01") },
    })
    local zg = C.cluster_by_time(zero_units, 2)
    check("zero-dated frame is kept", zg[2] ~= nil, true)
    check("zero-dated frame is its own group", zg[2] ~= zg[1] and zg[2] ~= zg[3], true)
    check("dated neighbours still share a burst", zg[1], zg[3])
end

-- collapse -----------------------------------------------------------------
local units = C.collapse({
    { id = 5, dir = "/shoot", filename = "A.JPG", epoch = 100, tags = { jpg = true } },
    { id = 3, dir = "/shoot", filename = "A.ARW", epoch = 100, tags = { raw = true } },
    { id = 7, dir = "/shoot", filename = "B.ARW", epoch = 200, tags = {} },
})
check("RAW+JPEG pair and a single give 2 units", #units, 2)
check("pair unit has 2 members", #units[1].members, 2)
check("pair unit id is the lowest member id", units[1].id, 3)
check("pair unit tags are the union", keys(units[1].tags), "jpg + raw")
check("single unit keeps its id", units[2].id, 7)

local case_units = C.collapse({
    { id = 1, dir = "/d", filename = "C.arw", tags = {} },
    { id = 2, dir = "/d", filename = "C.JPG", tags = {} },
    { id = 3, dir = "/other", filename = "C.JPG", tags = {} },
})
check("extension case ignored, other dir kept apart", #case_units, 2)

local dup_units = C.collapse({
    { id = 10, dir = "/d", filename = "X.ARW", epoch = 1, tags = { a = true } },
    { id = 11, dir = "/d", filename = "X.ARW", epoch = 1, tags = { b = true } },
})
check("same path twice gives 1 unit", #dup_units, 1)
check("duplicate unit has 2 members", #dup_units[1].members, 2)

-- cluster_by_time ------------------------------------------------------------
local function u(id, epoch) return { id = id, epoch = epoch } end

local g = C.cluster_by_time({ u(1, 0), u(2, 0.4), u(3, 0.8), u(4, 5) }, 2)
check("sub-second frames share group 1", g[1] .. g[2] .. g[3], "111")
check("frame past the gap is group 2", g[4], 2)

local edge = C.cluster_by_time({ u(1, 0), u(2, 2), u(3, 4.01) }, 2)
check("gap exactly 2 stays in the group", edge[2], edge[1])
check("gap 2.01 splits", edge[3], 2)

local eq = C.cluster_by_time({ u(2, 10), u(1, 10) }, 2)
check("equal epochs share a group", eq[1], eq[2])

local mixed = C.cluster_by_time({ u(1, 0), u(2, nil), u(3, 1), u(4, nil) }, 2)
check("timed units come first", mixed[1] .. mixed[3], "11")
check("untimed units get distinct numbers after the timed ones",
    mixed[2] ~= mixed[4] and mixed[2] > 1 and mixed[4] > 1, true)
check("untimed numbering follows id order", mixed[2] .. mixed[4], "23")

local untimed = C.cluster_by_time({ u(9, nil), u(8, nil), u(7, nil) }, 2)
check("all-untimed input yields one group per unit", untimed[7] .. untimed[8] .. untimed[9], "123")

local single = C.cluster_by_time({ u(42, 100) }, 2)
check("single unit yields group 1", single[42], 1)
check("single unit yields exactly one entry", keys(single), "42")

local float_gap = C.cluster_by_time({ u(1, 0.1), u(2, 2.1) }, 2)
check("0.1 and 2.1 with gap 2 stay together (float tolerance)", float_gap[2], float_gap[1])
local float_split = C.cluster_by_time({ u(1, 0.1), u(2, 2.2) }, 2)
check("0.1 and 2.2 with gap 2 split", float_split[2], 2)
-- 4.4 - 2.4 is 2.0000000000000004 in doubles, so this one needs the tolerance.
local float_round = C.cluster_by_time({ u(1, 2.4), u(2, 4.4) }, 2)
check("2.4 and 4.4 with gap 2 stay together (float tolerance)", float_round[2], float_round[1])
-- At real epoch sizes a double steps by ~2.4e-7, so the tolerance must cover that.
local real_gap = C.cluster_by_time({ u(1, 1780000000.10), u(2, 1780000001.60) }, 1.5)
check("real epochs exactly 1.5 apart with gap 1.5 stay together", real_gap[2], real_gap[1])
local real_split = C.cluster_by_time({ u(1, 1780000000.10), u(2, 1780000001.70) }, 1.5)
check("real epochs 1.6 apart with gap 1.5 split", real_split[2], 2)
-- 1.5 is exact in binary; 0.1 is not, and this pair's delta is 0.100000143.
local real_tenth = C.cluster_by_time({ u(1, 1780000000.03), u(2, 1780000000.13) }, 0.1)
check("real epochs exactly 0.1 apart with gap 0.1 stay together", real_tenth[2], real_tenth[1])

local jpeg_only = C.collapse({
    { id = 20, dir = "/shoot", filename = "P.JPG", epoch = 50, tags = {} },
    { id = 21, dir = "/shoot", filename = "Q.ARW", epoch = 51, tags = {} },
})
check("JPEG-only half of a pair gives a 1-member unit", #jpeg_only[1].members, 1)
local jpeg_only_g = C.cluster_by_time(jpeg_only, 2)
check("JPEG-only half of a pair still clusters", jpeg_only_g[20] .. jpeg_only_g[21], "11")

-- sanitize / camera_key ------------------------------------------------------
check("sanitize collapses and trims", C.sanitize('  a|b;c,d"e\tf\n  g  '), "a b c d e f g")

check("camera_key joins maker model lens",
    C.camera_key({ maker = "SONY", model = "ZV-E10", lens = "E 18-105mm F4 G OSS" }),
    "SONY ZV-E10 E 18-105mm F4 G OSS")
local dirty = C.camera_key({ maker = "SONY", model = "ZV-E10", lens = 'A|B,C;"D"' })
check("camera_key strips | ; , and \"", dirty:find('[|;,"]'), nil)
check("camera_key keeps the rest of a dirty lens", dirty, "SONY ZV-E10 A B C D")
check("camera_key with missing fields has no stray spaces", C.camera_key({ model = "X100" }), "X100")

-- divide ---------------------------------------------------------------------
local function cu(id, extra)
    local unit = { id = id, tags = {} }
    for k, v in pairs(extra or {}) do unit[k] = v end
    return unit
end

local cam_units = { cu(1, { model = "a" }), cu(2, { model = "b" }), cu(3, { model = "a" }) }
local by_cam = C.divide({ [1] = 1, [2] = 1, [3] = 1 }, C.camera_key, cam_units)
check("divide by camera: units 1 and 3 together", by_cam[1], by_cam[3])
check("divide by camera: unit 2 apart", by_cam[2] ~= by_cam[1], true)
check("divide by camera: dense numbering", by_cam[1] .. by_cam[2], "12")

local multi = C.divide({ [1] = 1, [2] = 2, [3] = 2 },
    function(unit) return unit.k end,
    { cu(1, { k = "x" }), cu(2, { k = "x" }), cu(3, { k = "y" }) })
check("divide numbers by old group then first appearance", multi[1] .. multi[2] .. multi[3], "123")

-- tag_key --------------------------------------------------------------------
local red = C.tag_key("Cars|Red")
check("tag_key matches an exact tag", red(cu(1, { tags = { ["Cars|Red"] = true } })), "1")
check("tag_key: untagged is 0", red(cu(2)), "0")
check("tag_key: child tag does not match its parent", red(cu(3, { tags = { ["Cars|Red|X"] = true } })), "0")
local tag_split = C.divide({ [1] = 1, [2] = 1 }, red,
    { cu(1, { tags = { ["Cars|Red"] = true } }), cu(2) })
check("tag_key splits tagged from untagged", tag_split[1] ~= tag_split[2], true)

-- parent_key -----------------------------------------------------------------
local num = C.parent_key("Cars|Number")
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
local by_par = C.divide({ [1] = 1, [2] = 1, [3] = 1 }, num, par_units)
check("parent divide: two children split", by_par[1] ~= by_par[3], true)
check("parent divide: nil-key unit stays with the group's first part", by_par[2], by_par[1])
check("parent divide: nil key forms no extra group", by_par[3], 2)

local all_nil = C.divide({ [1] = 1, [2] = 1 }, num, { cu(1), cu(2) })
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

local off = C.run_layers(run_units, { gap = 2 })
check("all layers off: final_of is burst_of", off.final_of, off.burst_of)
check("all layers off: other layers are nil", off.camera_of == nil and off.tag_of == nil and off.parent_of == nil, true)
check("burst_of matches cluster_by_time", same_map(off.burst_of, C.cluster_by_time(run_units, 2)), true)

local cam = C.run_layers(run_units, { gap = 2, camera = true })
check("camera on: final_of is camera_of", cam.final_of, cam.camera_of)

local all = C.run_layers(run_units, { gap = 2, camera = true, tag = "Cars|Red", parent = "Cars|Number" })
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

local based = C.run_layers({ cu(1, { epoch = 0 }), cu(2, { epoch = 100 }), cu(3, { epoch = 0 }) },
    { gap = 2, base_of = { [1] = 1, [2] = 2 } })
check("base_of keeps its groups", based.burst_of[1] .. based.burst_of[2], "12")
check("unit outside base_of is numbered after the base groups", based.burst_of[3], 3)

-- group_tag ------------------------------------------------------------------
local STAMP = "2026-11-08 22:45:10"
check("group_tag pads the final group number",
    C.group_tag(STAMP, "Group", 42), "Assisted Grouping|2026-11-08 22:45:10|Group|0042")
check("group_tag pads the burst number",
    C.group_tag(STAMP, "Burst", 7), "Assisted Grouping|2026-11-08 22:45:10|Burst|0007")
check("group_tag uses the label for Camera",
    C.group_tag(STAMP, "Camera", 3, "SONY ZV-E10"), "Assisted Grouping|2026-11-08 22:45:10|Camera|SONY ZV-E10")

-- wanted_tags ----------------------------------------------------------------
local pair = C.collapse({
    { id = 10, dir = "/p", filename = "IMG_1.ARW", epoch = 0, model = "a", tags = { ["Cars|Red"] = true, ["Cars|Number|7"] = true } },
    { id = 11, dir = "/p", filename = "IMG_1.JPG", epoch = 0, model = "a", tags = {} },
    { id = 12, dir = "/p", filename = "IMG_2.JPG", epoch = 50, tags = {} },
})
local pair_opts = { gap = 2, camera = true, tag = "Cars|Red", parent = "Cars|Number" }
local pair_result = C.run_layers(pair, pair_opts)
local wanted = C.wanted_tags(pair, pair_result, STAMP, pair_opts)
check("wanted_tags: both members of a pair get the same set", keys(wanted[10]), keys(wanted[11]))
check("wanted_tags: pair carries every layer's tag", keys(wanted[10]),
    "Assisted Grouping|2026-11-08 22:45:10|Burst|0001 + Assisted Grouping|2026-11-08 22:45:10|Camera|a"
    .. " + Assisted Grouping|2026-11-08 22:45:10|Group|0001 + Assisted Grouping|2026-11-08 22:45:10|Parent|7"
    .. " + Assisted Grouping|2026-11-08 22:45:10|Tag|has Red")
check("wanted_tags: absent tag and child read not/none", wanted[12]["Assisted Grouping|2026-11-08 22:45:10|Tag|not Red"]
    and wanted[12]["Assisted Grouping|2026-11-08 22:45:10|Parent|none"], true)
local plain = C.wanted_tags(pair, C.run_layers(pair, { gap = 2 }), STAMP, { gap = 2 })
check("wanted_tags: layers off add only Group and Burst", keys(plain[12]),
    "Assisted Grouping|2026-11-08 22:45:10|Burst|0002 + Assisted Grouping|2026-11-08 22:45:10|Group|0002")

-- latest_group_tag -----------------------------------------------------------
local older = "Assisted Grouping|2026-01-01 10:00:00|Group|0003"
local newer = "Assisted Grouping|2026-11-08 22:45:10|Group|0001"
check("latest_group_tag picks the later stamp",
    C.latest_group_tag({ [older] = true, [newer] = true, ["Assisted Grouping|2026-12-01 00:00:00|Burst|0001"] = true }), newer)
check("latest_group_tag returns nil with none", C.latest_group_tag({ ["Cars|Red"] = true }), nil)
check("latest_group_tag ignores another prefix",
    C.latest_group_tag({ [older] = true, ["Other|2027-01-01 00:00:00|Group|0001"] = true }), older)

local five = "Assisted Grouping|2026-11-09 08:00:00|Group|10000"
check("latest_group_tag accepts a 5-digit group on a later stamp",
    C.latest_group_tag({ [older] = true, [five] = true }), five)
check("latest_group_tag ignores a malformed stamp",
    C.latest_group_tag({ ["Assisted Grouping|zzz|Group|0001"] = true }), nil)
check("latest_group_tag: malformed stamp cannot beat a real one",
    C.latest_group_tag({ [older] = true, ["Assisted Grouping|zzz|Group|0001"] = true }), older)

-- base_of_from_tags ----------------------------------------------------------
local base = C.base_of_from_tags({
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
local ledger_text = C.ledger_format({
    [5] = { tags = { [odd] = true, [newer] = true }, native = 3 },
    [3] = { tags = { [newer] = true } },
})
local parsed = C.ledger_parse(ledger_text)
check("ledger round trip keeps a name with , and \"", parsed[5] and parsed[5].tags[odd], true)
check("ledger round trip keeps the native leader", parsed[5] and parsed[5].native, 3)
check("ledger round trip: no native means nil", parsed[3] and parsed[3].native, nil)
check("ledger round trip keeps tag sets", parsed[5] and keys(parsed[5].tags), keys({ [odd] = true, [newer] = true }))
check("ledger_format is stable", C.ledger_format(parsed), ledger_text)
check("ledger_format quotes every field", ledger_text:match('^"3","tag","') ~= nil, true)
check("ledger_parse of empty text", next(C.ledger_parse("")), nil)

-- plan_replace -----------------------------------------------------------------
local add, remove = C.plan_replace(
    { ["Cars|Red"] = true, [older] = true, [newer] = true },
    { ["Cars|Red_not_in_ledger"] = true, [older] = true, [newer] = true },
    { [newer] = true, ["Assisted Grouping|x|Group|0009"] = true })
check("plan_replace never removes a user tag", table.concat(remove, " + "):find("Cars|Red", 1, true), nil)
check("plan_replace removes an old ledger tag no longer wanted", table.concat(remove, " + "), older)
check("plan_replace does not re-add a present wanted tag", table.concat(add, " + "), "Assisted Grouping|x|Group|0009")

-- summary --------------------------------------------------------------------
if failures > 0 then
    print(string.format("%d failure(s)", failures))
    os.exit(1)
end
print("all passed")

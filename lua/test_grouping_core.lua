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
check("wanted_tags: timing alone writes Group only (Burst would be identical)", keys(plain[12]),
    "Assisted Grouping|2026-11-08 22:45:10|Group|0002")

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
local units = C.collapse({ r3, r1, r4, r2 })
local final = { [1] = 1, [2] = 1, [3] = 1, [4] = 2 }
check("plan_native groups a fresh burst under its lowest id; a single frame stays alone",
    plan_str(C.plan_native(units, final, {}, alone({ r1, r2, r3, r4 }))),
    "detach 1,2,3; groups 1:1,2,3; skipped 0")

local hand = alone({ r1, r2, r3, r4 })
hand[2] = { r2, rec(9, "z.cr2") }
check("plan_native skips an image in a hand-made group and counts it",
    plan_str(C.plan_native(units, final, {}, hand)), "detach 1,3; groups 1:1,3; skipped 1")

local ledger = { [2] = { tags = {}, native = 1 }, [9] = { tags = {}, native = 1 } }
check("plan_native regroups an image whose group the plugin made",
    plan_str(C.plan_native(units, final, ledger, hand)), "detach 1,2,3; groups 1:1,2,3; skipped 0")

check("plan_native dissolves a ledger group for an image now alone",
    plan_str(C.plan_native(units, final, { [4] = { tags = {}, native = 3 } }, alone({ r1, r2, r3, r4 }))),
    "detach 1,2,3,4; groups 1:1,2,3; skipped 0")

local hand_two = alone({ r1, r2 })
hand_two[2] = { r2, rec(9, "z.cr2") }
local two = C.collapse({ r1, r2 })
check("plan_native forms no group when skipping leaves one image",
    plan_str(C.plan_native(two, { [1] = 1, [2] = 1 }, {}, hand_two)), "detach ; groups ; skipped 1")

check("plan_native leaves a lone image in a hand-made group uncounted",
    plan_str(C.plan_native(C.collapse({ r2 }), { [2] = 1 }, {}, hand_two)), "detach ; groups ; skipped 0")

local raw, jpg, r7 = rec(5, "e.cr2"), rec(6, "e.jpg"), rec(7, "f.cr2")
local pair_units = C.collapse({ raw, jpg, r7 })
local paired = { [5] = { raw, jpg }, [6] = { raw, jpg }, [7] = { r7 } }
check("plan_native takes a RAW+JPEG pair darktable grouped on import into the burst",
    plan_str(C.plan_native(pair_units, { [5] = 1, [7] = 1 }, {}, paired)),
    "detach 5,6,7; groups 5:5,6,7; skipped 0")
check("plan_native groups a pair that is its own final group",
    plan_str(C.plan_native(pair_units, { [5] = 1, [7] = 2 }, {}, paired)),
    "detach 5,6; groups 5:5,6; skipped 0")
check("plan_native treats an unselected JPEG in the RAW's group as the same frame",
    plan_str(C.plan_native(C.collapse({ raw, r7 }), { [5] = 1, [7] = 1 }, {}, paired)),
    "detach 5,7; groups 5:5,7; skipped 0")

local mixed = { [5] = { raw, jpg }, [6] = { jpg, rec(9, "z.cr2") }, [7] = { r7 } }
check("plan_native skips the whole frame when one of its images is in a hand-made group",
    plan_str(C.plan_native(pair_units, { [5] = 1, [7] = 1 }, {}, mixed)), "detach ; groups ; skipped 2")

-- run_layers with timing off ----------------------------------------------------
local untimed_off = C.run_layers(run_units, { gap = 2, timing = false })
check("timing off: every unit, timed or not, shares group 1", keys(untimed_off.burst_of) .. " / "
    .. untimed_off.burst_of[1] .. untimed_off.burst_of[4] .. untimed_off.burst_of[6], "1 + 2 + 3 + 4 + 5 + 6 / 111")
check("timing off: result.timing is false", untimed_off.timing, false)
check("timing default: result.timing is true", C.run_layers(run_units, { gap = 2 }).timing, true)
local cam_only = C.run_layers(run_units, { timing = false, camera = true })
check("timing off + camera: splits by camera only", cam_only.final_of[1] == cam_only.final_of[4]
    and cam_only.final_of[1] ~= cam_only.final_of[2], true)
local based_off = C.run_layers({ cu(1, { epoch = 0 }), cu(2, { epoch = 100 }), cu(3, { epoch = 0 }), cu(4, { epoch = 500 }) },
    { timing = false, base_of = { [1] = 1, [2] = 2 } })
check("timing off + base_of: the rest share one group after the base groups",
    based_off.burst_of[1] .. based_off.burst_of[2] .. based_off.burst_of[3] .. based_off.burst_of[4], "1233")
local no_burst = C.wanted_tags(pair, C.run_layers(pair, { timing = false }), STAMP, {})
check("wanted_tags: timing off writes no Burst tag", keys(no_burst[12]),
    "Assisted Grouping|2026-11-08 22:45:10|Group|0001")

-- parse_gap --------------------------------------------------------------------
check("parse_gap: integer text", C.parse_gap("2"), 2)
check("parse_gap: decimal point", C.parse_gap("0.5"), 0.5)
check("parse_gap: decimal comma", C.parse_gap("1,5"), 1.5)
check("parse_gap: surrounding spaces", C.parse_gap("  3 "), 3)
check("parse_gap: leading dot", C.parse_gap(".25"), 0.25)
check("parse_gap: number input", C.parse_gap(2), 2)
check("parse_gap: zero is rejected", C.parse_gap("0"), nil)
check("parse_gap: negative is rejected", C.parse_gap("-1"), nil)
check("parse_gap: hex is rejected", C.parse_gap("0x10"), nil)
check("parse_gap: exponent is rejected", C.parse_gap("1e3"), nil)
check("parse_gap: blank is rejected", C.parse_gap(""), nil)
check("parse_gap: lone dot is rejected", C.parse_gap("."), nil)
check("parse_gap: nil is rejected", C.parse_gap(nil), nil)
check("parse_gap: two dots are rejected", C.parse_gap("1.2.3"), nil)

-- panel_options ------------------------------------------------------------------
local function panel(over)
    local p = { timing = true, gap_text = "2", camera = false, tag = "", parent = "",
        refine = false, write_tags = true, native_groups = false }
    for k, v in pairs(over or {}) do p[k] = v end
    return p
end
local o, why = C.panel_options(panel({ write_tags = false, native_groups = false }))
check("panel_options: both outputs off refuses", tostring(o) .. " / " .. tostring(why), "nil / " .. C.ERR_NO_OUTPUT)
o, why = C.panel_options(panel({ gap_text = "abc" }))
check("panel_options: bad gap with timing on refuses", why, C.ERR_BAD_GAP)
o = C.panel_options(panel({ gap_text = "abc", timing = false, camera = true }))
check("panel_options: bad gap ignored with timing off", o and o.gap, nil)
check("panel_options: timing off passes timing = false", o and o.timing, false)
o, why = C.panel_options(panel({ timing = false }))
check("panel_options: no layer and no refine refuses", why, C.ERR_NO_LAYER)
o = C.panel_options(panel({ timing = false, refine = true, native_groups = true, write_tags = false }))
check("panel_options: refine alone is enough", o ~= nil and o.refine and o.native_groups and not o.write_tags, true)
o = C.panel_options(panel({ gap_text = "0,5", tag = "  Cars|Red ", parent = " Cars|Number| " }))
check("panel_options: gap parsed, tag trimmed, trailing | dropped from parent",
    o.gap .. " / " .. o.tag .. " / " .. o.parent, "0.5 / Cars|Red / Cars|Number")
o = C.panel_options(panel({ tag = "   ", parent = "|" }))
check("panel_options: blank tag and parent become nil", o.tag == nil and o.parent == nil, true)

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
local cplans = C.plan_clear(clear_records, clear_ledger, clear_members)
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
local stale = C.plan_clear({ { id = 2, tags = {} } }, { [2] = { tags = {}, native = 1 }, [6] = { tags = {}, native = 1 } },
    { [2] = { { id = 2 }, { id = 6 } } })
check("plan_clear: group still ours after its leader left (another member shares the leader id)",
    stale[1].ungroup, true)
local _, no_name_restore = C.plan_clear(clear_records, clear_ledger, clear_members)
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
local pplans, prestore = C.plan_clear(
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

-- subsec_fractions ------------------------------------------------------------------
local function srec(id, dir, filename, epoch) return { id = id, dir = dir, filename = filename, epoch = epoch == nil and 100 or epoch } end
local function near(a, b) return a ~= nil and math.abs(a - b) < 1e-6 end
local sf, smiss = C.subsec_fractions({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "DSC1.JPG") },
    { [1] = "", [2] = "1780308000.897" })
check("subsec_fractions: RAW with a blank row borrows its JPEG's fraction", near(sf[1], 0.897) and near(sf[2], 0.897), true)
check("subsec_fractions: pair leaves nothing missing", smiss, nil)
sf, smiss = C.subsec_fractions({ srec(1, "/s", "DSC1.ARW") }, { [1] = "" })
check("subsec_fractions: RAW with no sibling has no fraction", sf[1], nil)
check("subsec_fractions: RAW with no sibling is reported missing", smiss, 1)
sf, smiss = C.subsec_fractions({ srec(1, "/s", "DSC1.ARW") }, {})
check("subsec_fractions: absent row with no sibling is reported missing", smiss, 1)
sf, smiss = C.subsec_fractions({ srec(2, "/s", "DSC2.JPG") }, { [2] = "1780308000.25" })
check("subsec_fractions: JPEG alone keeps its own fraction", near(sf[2], 0.25) and smiss == nil, true)
sf, smiss = C.subsec_fractions({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "dsc1.jpg") },
    { [1] = "", [2] = "1780308000.5" })
check("subsec_fractions: stem case differs → same frame (as darktable's import grouping), borrows",
    near(sf[1], 0.5) and smiss == nil, true)
check("collapse: DSC1.ARW + dsc1.jpg are one frame", #C.collapse({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "dsc1.jpg") }), 1)
sf = C.subsec_fractions({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "DSC1.jpg") }, { [1] = "", [2] = "1780308000.5" })
check("subsec_fractions: extension case is ignored, borrows", near(sf[1], 0.5), true)
sf, smiss = C.subsec_fractions({ srec(1, "/a", "DSC1.ARW"), srec(2, "/b", "DSC1.JPG") },
    { [1] = "", [2] = "1780308000.5" })
check("subsec_fractions: same stem in another folder does not lend", tostring(sf[1]) .. " / " .. tostring(smiss), "nil / 1")
sf, smiss = C.subsec_fractions({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "DSC1.JPG") },
    { [1] = "1780308000", [2] = "1780308000.5" })
check("subsec_fractions: a whole-second (non-blank) row does not borrow", tostring(sf[1]) .. " / " .. tostring(smiss), "nil / 1")
sf, smiss = C.subsec_fractions({ srec(1, "/s", "DSC1.ARW"), srec(2, "/s", "DSC1.JPG"), srec(3, "/s", "X.JPG", false) },
    { [1] = "", [2] = "" })
check("subsec_fractions: blank pair has no fraction; untimed records are ignored",
    tostring(sf[1]) .. tostring(sf[2]) .. tostring(sf[3]) .. " / " .. tostring(smiss), "nilnilnil / 1")

-- ledger on Windows: text mode writes CRLF ----------------------------------------
local crlf = C.ledger_parse((ledger_text:gsub("\n", "\r\n")))
check("ledger_parse of CRLF text matches LF", C.ledger_format(crlf), ledger_text)

-- wanted_tags: Refine alone writes no Burst --------------------------------------
local refine_units = C.collapse({
    { id = 1, dir = "/r", filename = "A.JPG", epoch = 0, tags = { [newer] = true } },
    { id = 2, dir = "/r", filename = "B.JPG", epoch = 100, tags = {} },
})
local refine_opts = { gap = 2, base_of = C.base_of_from_tags(refine_units) }
local refine_wanted = C.wanted_tags(refine_units, C.run_layers(refine_units, refine_opts), STAMP, refine_opts)
check("wanted_tags: Refine alone writes Group only", keys(refine_wanted[2]),
    "Assisted Grouping|2026-11-08 22:45:10|Group|0002")

-- assisted_grouping.lua pure helpers (loads without darktable) ---------------------
local A = require("assisted_grouping")

check("needs_tags: defaults minus tag writer read no tags", A.needs_tags({ timing = true, native_groups = true }), false)
check("needs_tags: tag writer reads tags", A.needs_tags({ write_tags = true }), true)
check("needs_tags: Refine reads tags", A.needs_tags({ refine = true }), true)

local function arec(id, filename, epoch, tags)
    return { id = id, dir = "/a", filename = filename, file = "/a/" .. filename, epoch = epoch, tags = tags or {} }
end
local a_units = C.collapse({
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

local sub_units = C.collapse({ arec(1, "DSC1.ARW", 100), arec(2, "DSC1.JPG", 100) })
local sub_members = A.members_of(sub_units)
local prec = A.apply_subsec(sub_members, "2,1780308000.5\r\n#precision,subsecond\r\n")
check("apply_subsec: RAW not sent borrows its JPEG's fraction (CRLF results)",
    prec == "subsecond" and near(sub_members[1].epoch, 100.5) and near(sub_members[2].epoch, 100.5), true)
local whole_members = A.members_of(C.collapse({ arec(1, "DSC1.JPG", 100) }))
local wprec, wwhy = A.apply_subsec(whole_members, "1,1780308000\n#precision,whole\n")
check("apply_subsec: whole precision leaves epochs", wprec .. " " .. tostring(whole_members[1].epoch), "whole 100")
check("apply_subsec: whole precision says why", wwhy ~= nil, true)
check("apply_subsec: nothing timed", select(2, A.apply_subsec({ arec(1, "X.JPG", nil) }, "")), "no frame has a capture time")

local by_id, hprec = A.parse_helper_results("7,1780308000.25\n8,\n#precision,subsecond\n")
check("parse_helper_results: rows and precision", by_id[7] .. "|" .. by_id[8] .. "|" .. hprec, "1780308000.25||subsecond")

check("count_tagged: frames with the tag", A.count_tagged(C.collapse({ arec(1, "A.JPG", 1, { ["Cars|Red"] = true }),
    arec(2, "B.JPG", 1) }), "Cars|Red"), 1)
check("count_tagged: a spelling with spaces matches nothing", A.count_tagged(C.collapse({ arec(1, "A.JPG", 1, { ["Cars|Red"] = true }) }),
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

check("utf16le: ASCII", A.utf16le("A"), "A\0")
check("utf16le: two-byte char", A.utf16le("é"), "\xE9\0")
check("utf16le: astral char is a surrogate pair", A.utf16le("😀"), "\x3D\xD8\x00\xDE")

local tmp_path = os.tmpname()
check("write_file_atomic: replaces an existing file", A.write_file_atomic(tmp_path, "one\n") and A.write_file_atomic(tmp_path, "two\n"), true)
check("write_file_atomic: new text read back", A.read_file_or_tmp(tmp_path), "two\n")
check("write_file_atomic: no .tmp left", io.open(tmp_path .. ".tmp", "r"), nil)
os.remove(tmp_path)
local tf = io.open(tmp_path .. ".tmp", "w"); tf:write("saved\n"); tf:close()
check("read_file_or_tmp: falls back to .tmp when the file is missing", A.read_file_or_tmp(tmp_path), "saved\n")
os.remove(tmp_path .. ".tmp")
check("write_file_atomic: unwritable folder fails", A.write_file_atomic("/nonexistent-dir-xyz/ledger.csv", "x"), nil)

-- summary --------------------------------------------------------------------
if failures > 0 then
    print(string.format("%d failure(s)", failures))
    os.exit(1)
end
print("all passed")

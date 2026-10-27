-- @name: Grenade Helper
-- @author: claude
-- Saved grenade lineups per map: where to stand, where to aim, how to throw. Auto throw does the whole throw:
-- walks onto the spot, aims, pulls the pin, runs up, jumps and lets go.

local spots_file = "C:/spectral/scripts/grenade_spots.bin"
local legacy_file = "C:/spectral/scripts/grenade_spots.txt"

-- how to throw: any mix of these (none = standing, left click)
local state_names = { "Jump", "Crouch", "Run", "Walk", "Left click", "Right click", "Both clicks" }
-- the movement before the throw: hold these keys for the move time
local key_names = { "Forward", "Back", "Left", "Right" }
local grenade_names = { "Smoke", "Flash", "HE", "Molotov", "Decoy" }

-- ---- settings ---------------------------------------------------------------------------------
-- Four boxes: how it looks, the keys that do the work, making lineups, and the lineup you aim at.

local display = ui.group("Display", 1)
local enabled = display:switch("Enabled", true)
local filter = display:combo("Show", { "Held grenade", "All grenades" }, "Held grenade")
local draw_distance = display:slider_int("Draw distance", 200, 3000, 1200, "%d units")
local smoothing = display:slider_int("Smoothing", 0, 100, 40, "%d")
smoothing:tooltip("0 = instant. The higher, the slower and softer.")
local spot_color = display:color("Spot", color(140, 120, 255))
local ready_color = display:color("Lined up", color(90, 230, 120))

local keys_group = ui.group("Keys", 1)
local throw_key = keys_group:hotkey("Auto throw")
throw_key:tooltip("Press it with a grenade out: walks onto the nearest lineup, aims, pulls the pin, runs up, jumps and throws by itself. Letting go before the pin is out cancels.")
local walk_key = keys_group:hotkey("Walk to lineup")
walk_key:tooltip("Hold it: walks onto the nearest lineup and aims at it. Throwing stays yours.")
local walk_distance = keys_group:slider_int("Reach", 100, 2000, 600, "%d units")
walk_distance:tooltip("How far away a lineup can be for the keys above.")

local selected = nil -- the lineup you stand on and aim at; the Lineup box edits it
local load_edit_fields -- (below)
local aimed_here = {} -- every lineup on the spot you stand on that your aim is on (several when they overlap)

local draft = nil -- the last throw you made while recording, shown on the map until you add or dismiss it
local rethrow = false -- "Throw again" was clicked: the next tick starts an auto throw of the draft

local recorder = ui.group("Record", 2)
local record = recorder:switch("Record my throws", false)
record:tooltip("Every grenade you throw becomes a draft: where you started, where you aimed, the keys you ran with and for how long, jump, crouch, walk and which click. It's drawn where you threw it; Add saves it, Dismiss drops it.")
local new_name = recorder:input("Name", "")
new_name:tooltip("For the next lineup you add. Empty = automatic.")
local function has_draft() return draft ~= nil end
recorder:text("Throw recorded: it's drawn where you threw it. Throw it again to check it, then add or dismiss it.")
    :visible(has_draft)
local add_draft, dismiss_draft, goto_draft, save_here
recorder:button("Add", function() add_draft() end):visible(has_draft)
recorder:button("Throw again", function() rethrow = draft ~= nil end):visible(has_draft)
    :tooltip("Auto throws it once more, the same way: walks onto it, aims, runs up and throws. Hold its grenade.")
recorder:button("Goto", function() goto_draft() end):visible(has_draft)
    :tooltip("Teleports you onto it, aimed (setpos / setang: needs sv_cheats 1).")
recorder:button("Dismiss", function() dismiss_draft() end):visible(has_draft)
recorder:text("Throw a grenade: it shows up here to add.")
    :visible(function() return record:get() and draft == nil end)
recorder:button("Save standing throw here", function() save_here() end)
    :visible(function() return draft == nil end)

local lineups = ui.group("Selected lineup", 2)
local function when_selected() return selected ~= nil end
lineups:text("Close the menu, stand on a lineup and aim at it: it shows up here to edit. Changes save by themselves.")
    :visible(function() return selected == nil end)
local edit_name = lineups:input("Lineup name", ""):visible(when_selected)
local edit_grenade = lineups:combo("Grenade", grenade_names, "Smoke"):visible(when_selected)
local edit_states = lineups:multi_combo("Throw", state_names, {}):visible(when_selected)
local edit_keys = lineups:multi_combo("Run-up keys", key_names, {}):visible(when_selected)
local edit_time = lineups:slider_float("Run-up time", 0, 5, 0, "%.2f s"):visible(when_selected)
local delete_selected
lineups:button("Delete lineup", function() delete_selected() end):visible(when_selected)
-- lineups with the same spot and aim sit on top of each other: this steps through them (in the world, the one
-- picked here is the one shown while the menu is open)
lineups:button("Next lineup on this spot", function()
    for i, s in ipairs(aimed_here) do
        if s == selected then
            selected = aimed_here[i % #aimed_here + 1]
            load_edit_fields()
            return
        end
    end
end):visible(function() return selected ~= nil and #aimed_here > 1 end)

-- ---- spots ------------------------------------------------------------------------------------

local grenades = {
    weapon_smokegrenade = "Smoke",
    weapon_flashbang = "Flash",
    weapon_hegrenade = "HE",
    weapon_molotov = "Molotov",
    weapon_incgrenade = "Molotov",
    weapon_decoy = "Decoy",
}

local function tint_of(s)
    if s.grenade == "Smoke" then
        return ui.accent()
    end
    local custom_colors = {
        Flash = color(255, 240, 150),
        HE = color(255, 110, 90),
        Molotov = color(255, 160, 60),
        Decoy = color(150, 200, 255),
    }
    return custom_colors[s.grenade] or ui.accent()
end

-- A lineup keeps how to throw as text: the states joined with " + " ("Run + Jump", empty = standing). The
-- old combo values ("Run + jump", "Jump + right click", "Stand") read as the same thing.
local state_lookup = {}
for _, name in ipairs(state_names) do state_lookup[name:lower()] = name end

local function parse_states(text)
    local set = {}
    for token in (text or ""):gmatch("[^+,]+") do
        local name = state_lookup[token:match("^%s*(.-)%s*$"):lower()]
        if name then set[name] = true end
    end
    return set
end

local function states_list(set) -- in the menu's order
    local list = {}
    for _, name in ipairs(state_names) do
        if set[name] then list[#list + 1] = name end
    end
    return list
end

local function menu_list(value) -- what a multi combo returns: the selected names
    return type(value) == "table" and value or {}
end

local function states_text(value)
    local set = {}
    for _, name in ipairs(menu_list(value)) do set[name] = true end
    return table.concat(states_list(set), " + ")
end

local function states_label(text)
    local list = states_list(parse_states(text))
    return #list == 0 and "STAND" or table.concat(list, " + "):upper()
end

-- the move keys of a lineup, as bits: 1 forward, 2 back, 4 left, 8 right
local KEY_BITS = { Forward = 1, Back = 2, Left = 4, Right = 8 }
local KEY_LETTERS = { { 1, "W" }, { 4, "A" }, { 2, "S" }, { 8, "D" } }

local function keys_mask(value)
    local mask = 0
    for _, name in ipairs(menu_list(value)) do
        local bits = KEY_BITS[name]
        if bits and bit.band(mask, bits) == 0 then mask = mask + bits end
    end
    return mask
end

local function keys_list(mask)
    local list = {}
    for _, name in ipairs(key_names) do
        if bit.band(mask or 0, KEY_BITS[name]) ~= 0 then list[#list + 1] = name end
    end
    return list
end

local function has_move(s)
    return (s.keys or 0) ~= 0 and (s.move_time or 0) > 0
end

local function move_label(s) -- "W 1.0S", nil when the lineup doesn't move
    if not has_move(s) then return nil end
    local letters = ""
    for _, k in ipairs(KEY_LETTERS) do
        if bit.band(s.keys, k[1]) ~= 0 then letters = letters .. k[2] end
    end
    return string.format("%s %.1fS", letters, s.move_time)
end

-- { map, grenade, throw (states text), name, position, keys, move_time, pos, angles }
local spots = {}
local spots_version = 0

-- ---- storage ----------------------------------------------------------------------------------
-- Binary file, little endian: "GHSP" | version u8 | string count u16 | spot count u32 | the strings
-- ({ length u16 | bytes }: maps, grenades, states, positions, each once) | the spots:
--   map u16 | grenade u16 | throw u16 | position u16 | keys u8 | move time u16 (ms) | x y z i32 (units * 100)
--   | pitch yaw i32 (degrees * 1000) | name length u16 | name bytes          (33 bytes + the name)
-- Versions 1 and 2 (no move keys / time, and for 1 no position) are still read and written back as 3.

-- >>> storage core
local FORMAT_MAGIC, FORMAT_VERSION = "GHSP", 3
local byte, char, sub, floor, concat = string.byte, string.char, string.sub, math.floor, table.concat
local unpack = table.unpack or unpack
local buf = {}

local function put_i32(at, value, scale)
    if value ~= value then value = 0 end
    local n = floor(value * scale + 0.5)
    if n > 2147483647 then n = 2147483647 elseif n < -2147483648 then n = -2147483648 end
    if n < 0 then n = n + 4294967296 end
    buf[at], buf[at + 1], buf[at + 2], buf[at + 3] = n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216)
end

local function s32(a, b, c, d)
    local n = a + b * 256 + c * 65536 + d * 16777216
    return d >= 128 and n - 4294967296 or n
end

local function encode_spots(list)
    local ids, names = {}, {}
    local function intern(text)
        local id = ids[text]
        if not id then
            names[#names + 1] = text
            id = #names - 1
            ids[text] = id
        end
        return id
    end

    local records = {}
    for i, s in ipairs(list) do
        local map, grenade, throw, position = intern(s.map), intern(s.grenade), intern(s.throw), intern(s.position or "")
        local name = sub(s.name, 1, 65535)
        local name_length = #name
        local ms = floor((s.move_time or 0) * 1000 + 0.5)
        if ms < 0 then ms = 0 elseif ms > 65535 then ms = 65535 end
        buf[1], buf[2], buf[3], buf[4] = map % 256, floor(map / 256), grenade % 256, floor(grenade / 256)
        buf[5], buf[6], buf[7], buf[8] = throw % 256, floor(throw / 256), position % 256, floor(position / 256)
        buf[9], buf[10], buf[11] = (s.keys or 0) % 256, ms % 256, floor(ms / 256)
        put_i32(12, s.pos.x, 100)
        put_i32(16, s.pos.y, 100)
        put_i32(20, s.pos.z, 100)
        put_i32(24, s.angles.x, 1000)
        put_i32(28, s.angles.y, 1000)
        buf[32], buf[33] = name_length % 256, floor(name_length / 256)
        records[i] = char(unpack(buf, 1, 33)) .. name
    end

    local head = { FORMAT_MAGIC, char(FORMAT_VERSION), char(#names % 256, floor(#names / 256)) }
    local count = #records
    head[#head + 1] = char(count % 256, floor(count / 256) % 256, floor(count / 65536) % 256, floor(count / 16777216))
    for _, text in ipairs(names) do
        head[#head + 1] = char(#text % 256, floor(#text / 256)) .. text
    end
    return concat(head) .. concat(records)
end

local function decode_spots(data)
    local size = #data
    if size < 11 or sub(data, 1, 4) ~= FORMAT_MAGIC then return nil, "not a grenade spots file" end
    local version = byte(data, 5)
    if version < 1 or version > FORMAT_VERSION then return nil, "unsupported version " .. version end

    local string_count = byte(data, 6) + byte(data, 7) * 256
    local c0, c1, c2, c3 = byte(data, 8, 11)
    local count = c0 + c1 * 256 + c2 * 65536 + c3 * 16777216

    local pos, strings = 12, {}
    for i = 1, string_count do
        if pos + 1 > size then return nil, "cut off in the name table" end
        local length = byte(data, pos) + byte(data, pos + 1) * 256
        if pos + 1 + length > size then return nil, "cut off in the name table" end
        strings[i] = sub(data, pos + 2, pos + 1 + length)
        pos = pos + 2 + length
    end

    local fixed = version >= 3 and 33 or version >= 2 and 30 or 28
    local list = {}
    for i = 1, count do
        if pos + fixed - 1 > size then return nil, "cut off at spot " .. i end
        local m0, m1, g0, g1, t0, t1 = byte(data, pos, pos + 5)
        local at, position, keys, move_ms = pos + 6, "", 0, 0
        if version >= 2 then
            local q0, q1 = byte(data, at, at + 1)
            position = strings[q0 + q1 * 256 + 1]
            at = at + 2
        end
        if version >= 3 then
            local k, ms0, ms1 = byte(data, at, at + 2)
            keys, move_ms = k, ms0 + ms1 * 256
            at = at + 3
        end
        local x0, x1, x2, x3, y0, y1, y2, y3, z0, z1, z2, z3,
        p0, p1, p2, p3, w0, w1, w2, w3, n0, n1 = byte(data, at, at + 21)
        local name_end = at + 21 + n0 + n1 * 256
        if name_end > size then return nil, "cut off at spot " .. i end
        local map, grenade, throw = strings[m0 + m1 * 256 + 1], strings[g0 + g1 * 256 + 1], strings[t0 + t1 * 256 + 1]
        if not (map and grenade and throw and position) then return nil, "bad name index at spot " .. i end
        list[i] = {
            map = map,
            grenade = grenade,
            throw = throw,
            position = position,
            keys = keys,
            move_time = move_ms / 1000,
            name = sub(data, at + 22, name_end),
            pos = vector(s32(x0, x1, x2, x3) / 100, s32(y0, y1, y2, y3) / 100, s32(z0, z1, z2, z3) / 100),
            angles = vector(s32(p0, p1, p2, p3) / 1000, s32(w0, w1, w2, w3) / 1000, 0),
        }
        pos = name_end + 1
    end
    return list
end

local function decode_text(data)
    local list = {}
    for line in data:gmatch("[^\r\n]+") do
        local map, grenade, x, y, z, pitch, yaw, throw, name =
            line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        if map and tonumber(x) then
            list[#list + 1] = {
                map = map,
                grenade = grenade,
                throw = throw,
                name = name,
                position = "",
                keys = 0,
                move_time = 0,
                pos = vector(tonumber(x), tonumber(y), tonumber(z)),
                angles = vector(tonumber(pitch), tonumber(yaw), 0),
            }
        end
    end
    return list
end
-- <<< storage core

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function save_spots()
    spots_version = spots_version + 1
    local file = io.open(spots_file, "wb")
    if not file or not file:write(encode_spots(spots)) then
        if file then file:close() end
        client.notify("Grenade helper", "Couldn't write " .. spots_file, "error")
        return
    end
    file:close()
end

local function load_spots()
    spots = {}
    spots_version = spots_version + 1
    local data = read_file(spots_file)
    if data then
        local list, reason = decode_spots(data)
        if list then
            spots = list
            return
        end
        local backup = spots_file .. ".corrupt"
        local copy = io.open(backup, "wb")
        if copy then
            copy:write(data)
            copy:close()
        end
        print("Grenade helper: can't read " .. spots_file .. " (" .. reason .. ")")
        return
    end

    local legacy = read_file(legacy_file)
    if legacy then
        spots = decode_text(legacy)
        if #spots > 0 then
            save_spots()
        end
    end
end

load_spots()


-- ---- player state -----------------------------------------------------------------------------

local view_angles = nil

events.create_move:set(function(cmd)
    view_angles = cmd:get_viewangles()
end)

local function held_grenade(me)
    local weapon = me:get_active_weapon()
    return weapon and grenades[weapon:class_name()]
end

local function eye_angles(me)
    return view_angles or me.m_angEyeAngles or vector()
end

local function eye_height(me)
    local flags = me.m_fFlags or 0
    return bit.band(flags, 2) ~= 0 and 46.04 or 64.06
end

local function wrap_angle(a)
    return (a + 180) % 360 - 180
end

local function angle_delta(a, b)
    local pitch = a.x - b.x
    local yaw = wrap_angle(a.y - b.y)
    return math.sqrt(pitch * pitch + yaw * yaw)
end

-- ---- groups -----------------------------------------------------------------------------------

local GROUP_RADIUS = 8
local groups_by_map, groups_version = {}, -1
local NO_GROUPS = {}

local function rebuild_groups()
    groups_by_map, groups_version = {}, spots_version
    local cells = {}
    for _, s in ipairs(spots) do
        local list = groups_by_map[s.map]
        if not list then
            list = {}
            groups_by_map[s.map] = list
            cells[s.map] = {}
        end
        local grid = cells[s.map]
        local cx, cy = math.floor(s.pos.x / 16), math.floor(s.pos.y / 16)

        local found
        for dx = -1, 1 do
            for dy = -1, 1 do
                local bucket = not found and grid[(cx + dx) .. ":" .. (cy + dy)]
                if bucket then
                    for _, g in ipairs(bucket) do
                        if g.pos:dist(s.pos) <= GROUP_RADIUS then
                            found = g
                            break
                        end
                    end
                end
            end
        end

        if found then
            found.spots[#found.spots + 1] = s
        else
            local g = { map = s.map, pos = s.pos, spots = { s } }
            list[#list + 1] = g
            local key = cx .. ":" .. cy
            grid[key] = grid[key] or {}
            grid[key][#grid[key] + 1] = g
        end
    end
end

local function get_groups(map)
    if groups_version ~= spots_version then rebuild_groups() end
    return groups_by_map[map] or NO_GROUPS
end

local function matching_spots(g, holding, all)
    local list = {}
    for _, s in ipairs(g.spots) do
        if all or s.grenade == holding then list[#list + 1] = s end
    end
    return list
end

local function best_lineup(list, holding, view)
    local best, best_key
    for _, s in ipairs(list) do
        local key = (s.grenade == holding and 0 or 1000) + angle_delta(view, s.angles)
        if not best_key or key < best_key then best, best_key = s, key end
    end
    return best
end

local function position_name(list)
    for _, s in ipairs(list) do
        if s.position and s.position ~= "" then return s.position end
    end
    return ""
end


-- ---- editing ----------------------------------------------------------------------------------

-- fills in map, name and position from the Lineups box, stores and saves
local function add_spot(s)
    local name = new_name:get()
    s.name = name ~= "" and name or string.format("%s %d", s.grenade, #spots + 1)
    s.map = engine.get_level_name_short()
    s.position = s.position or ""
    spots[#spots + 1] = s
    save_spots()
    new_name:set("")
    local how = { states_label(s.throw), move_label(s) }
    client.notify("Grenade helper", "Saved " .. s.name .. " (" .. table.concat(how, ", ") .. ").", "success")
end

function save_here()
    local me = entities.local_player()
    if not engine.is_in_game() or not me or not me:alive() then return end
    local grenade = held_grenade(me)
    if not grenade then
        client.notify("Grenade helper", "Take out the grenade first.", "warning")
        return
    end
    local angles = eye_angles(me)
    add_spot({
        grenade = grenade,
        throw = "",
        keys = 0,
        move_time = 0,
        pos = me:origin(),
        angles = vector(angles.x, angles.y, 0),
    })
end

-- The fields follow the selected lineup; editing one writes it back. Filling them in fires their on_change,
-- so that's ignored while loading. Saving waits for typing to stop.
local loading_fields, save_at = false, nil

function load_edit_fields()
    if not selected then return end
    loading_fields = true
    edit_name:set(selected.name)
    edit_grenade:set(selected.grenade)
    edit_states:set(states_list(parse_states(selected.throw)))
    edit_keys:set(keys_list(selected.keys))
    edit_time:set(selected.move_time or 0)
    loading_fields = false
end

local function edited(apply)
    return function(self)
        if loading_fields or not selected then return end
        apply(selected, self:get())
        spots_version = spots_version + 1
        save_at = globals.realtime() + 0.6
    end
end

edit_name:on_change(edited(function(s, v) if v ~= "" then s.name = v end end))
edit_grenade:on_change(edited(function(s, v) s.grenade = v end))
edit_states:on_change(edited(function(s, v) s.throw = states_text(v) end))
edit_keys:on_change(edited(function(s, v) s.keys = keys_mask(v) end))
edit_time:on_change(edited(function(s, v) s.move_time = v end))

events.render:set(function()
    if save_at and globals.realtime() >= save_at then
        save_at = nil
        save_spots()
    end
end)

function delete_selected()
    if not selected then return end
    for i, s in ipairs(spots) do
        if s == selected then
            table.remove(spots, i)
            break
        end
    end
    local name = selected.name
    selected = nil
    save_spots()
    client.notify("Grenade helper", "Deleted " .. name .. ".", "info")
end

-- ---- rendering & fonts (Pixel Font configuration) -------------------------------------------

local pixel_font = "small"
local font = pixel_font
local big_font = render.font("C:\\Windows\\Fonts\\trebuc.ttf", 12, "mono")
local small_font = pixel_font

local STAND_ENTER, STAND_EXIT = 18, 26
local READY_ENTER, READY_EXIT = 0.35, 0.6
local AIM_EDIT = 4

local function smooth_speed(fast, slow)
    local s = smoothing:get()
    if s <= 0 then return nil end
    return fast * (slow / fast) ^ ((s - 1) / 99)
end

local function approach(current, target, speed)
    if not speed then return target end
    return current + (target - current) * (1 - math.exp(-speed * globals.frametime()))
end

local function text_width(text, f)
    return render.measure_text(text, f).x
end

local function ground_ring(center, radius, col, thickness, fill)
    local points = {}
    for i = 0, 31 do
        local angle = i / 32 * math.pi * 2
        local screen = (center + vector(math.cos(angle) * radius, math.sin(angle) * radius, 0)):to_screen()
        if not screen then return false end
        points[#points + 1] = screen
    end
    if fill and fill > 0 then render.poly_filled(points, col:alpha(fill)) end
    render.poly(points, col, true, thickness)
    return true
end

local function panel(x, y, w, h, accent, a)
    render.rect_filled(vec2(x, y), vec2(x + w, y + h), color(12, 14, 20, 215 * a), 4)
    render.rect(vec2(x, y), vec2(x + w, y + h), color(255, 255, 255, 30 * a), 4, 1)
    render.rect_filled(vec2(x + 3, y + 4), vec2(x + 5, y + h - 4), accent:alpha(255 * a), 1.5)
end

local function overlaps(a, b, margin)
    return a.x < b.x + b.w + margin and b.x < a.x + a.w + margin
        and a.y < b.y + b.h + margin and b.y < a.y + a.h + margin
end

-- ---- the card over a position ----

-- where the card goes and how big it is; one lineup, or a row each
local function label_layout(at, list, distance)
    local meters = math.floor(distance / 52.5)
    local position = position_name(list)
    if #list == 1 then
        local s = list[1]
        local sub_text = s.grenade:upper() .. (position ~= "" and (" | " .. position:upper()) or "") .. " | " .. meters .. "M"
        local w = math.max(text_width(s.name, font), text_width(sub_text, font)) + 16
        return { x = at.x - w / 2, y = at.y - 28, w = w, h = 28, sub_text = sub_text }
    end

    local shown = math.min(#list, 4)
    local footer = (position ~= "" and (position:upper() .. " | ") or "") .. #list .. " LINEUPS | " .. meters .. "M"
    local w = text_width(footer, font)
    for i = 1, shown do
        w = math.max(w, text_width(list[i].name, font) + text_width(list[i].grenade:upper(), font) + 18)
    end
    w = w + 16
    local h = 8 + shown * 14 + 14
    return { x = at.x - w / 2, y = at.y - h - 2, w = w, h = h, shown = shown, footer = footer }
end

local function draw_label(L, list, fade, tint)
    local white = color(255, 255, 255, 235 * fade)
    if #list == 1 then
        local s = list[1]
        panel(L.x, L.y, L.w, L.h, tint_of(s), fade)
        render.text(vec2(L.x + 8, L.y + 4), white, s.name, { font = font, style = "shadow" })
        render.text(vec2(L.x + 8, L.y + 15), tint:alpha(255 * fade), L.sub_text, { font = font, style = "outline" })
        return
    end

    panel(L.x, L.y, L.w, L.h, tint, fade)
    for i = 1, L.shown do
        local s = list[i]
        local row = L.y + 5 + (i - 1) * 14
        local col = tint_of(s)
        render.circle_filled(vec2(L.x + 12, row + 5), 2.5, col:alpha(255 * fade))
        render.text(vec2(L.x + 18, row), white, s.name, { font = font, style = "shadow" })
        render.text(vec2(L.x + L.w - 6, row + 1), col:alpha(255 * fade), s.grenade:upper(), { font = font, style = "outline", align = "right" })
    end
    render.text(vec2(L.x + 8, L.y + L.h - 12), tint:alpha(255 * fade), L.footer, { font = font, style = "outline" })
end

-- ---- the aim point ----

local function draw_reticle(target, col, amt, st, is_active, off, is_selected)
    local r = 7 - 2 * st.amt
    local a = (is_active and 255 or 150) * amt
    render.circle(target, r, col:alpha(a), 0, 1.5)
    render.circle_filled(target, 1.5, col:alpha(a))
    if is_active then
        local progress = 1 - math.min(off, 12) / 12
        if progress > 0.01 and progress < 0.995 then
            render.arc(target, r + 9, -math.pi / 2, -math.pi / 2 + progress * math.pi * 2, col:alpha(amt), 1.5)
        end
    end
end

-- ---- the strip under the crosshair ----
-- One line: the lineup's name, how to throw it, and how close you are; a thin bar along its bottom edge
-- fills as you line up. The status column keeps its width so the strip doesn't breathe.

local sep_width
local GRAY = color(190, 195, 210)

local function hud_layout(active, all, center)
    sep_width = sep_width or text_width(" | ", font)
    local tags = {}
    if all then tags[#tags + 1] = { active.grenade:upper(), tint_of(active) } end
    tags[#tags + 1] = { states_label(active.throw), GRAY }
    local move = move_label(active)
    if move then tags[#tags + 1] = { move, spot_color:get() } end
    if active.position and active.position ~= "" then
        tags[#tags + 1] = { active.position:upper(), GRAY }
    end

    local tags_width = 0
    for i, t in ipairs(tags) do tags_width = tags_width + text_width(t[1], font) + (i > 1 and sep_width or 0) end
    local name_width = text_width(active.name, big_font)
    local status_width = math.max(text_width("THROW", font), text_width("00.0* off", font), text_width("0.00", font))

    local w = 8 + name_width + 10 + tags_width + 10 + status_width + 8
    return { x = center.x - w / 2, y = center.y + 28, w = w, h = 19, tags = tags, name_width = name_width }
end

local function draw_bar(L, col, amt, progress)
    local x0, x1, y0 = L.x + 8, L.x + L.w - 4, L.y + L.h - 4
    render.rect_filled(vec2(x0, y0), vec2(x1, y0 + 2), color(255, 255, 255, 28 * amt), 1)
    if progress > 0.01 then
        render.rect_filled(vec2(x0, y0), vec2(x0 + (x1 - x0) * math.min(progress, 1), y0 + 2), col:alpha(255 * amt), 1)
    end
end

local function draw_hud(L, active, st, amt)
    local col = tint_of(active):lerp(ready_color:get(), st.amt)
    panel(L.x, L.y, L.w, L.h, col, amt)
    local row = L.y + (L.h - 3) / 2

    render.text(vec2(L.x + 9, row), color(255, 255, 255, 240 * amt), active.name,
        { font = big_font, style = "shadow", center_y = true })

    local tx = L.x + 9 + L.name_width + 10
    for i, t in ipairs(L.tags) do
        if i > 1 then
            render.text(vec2(tx, row), color(120, 125, 140, 200 * amt), " | ", { font = font, style = "outline", center_y = true })
            tx = tx + sep_width
        end
        render.text(vec2(tx, row), t[2]:alpha(255 * amt), t[1], { font = font, style = "outline", center_y = true })
        tx = tx + text_width(t[1], font)
    end

    local status = st.ready and "THROW" or string.format("%.1f* off", st.off)
    render.text(vec2(L.x + L.w - 8, row), st.ready and col:alpha(255 * amt) or color(200, 200, 205, 225 * amt), status,
        { font = font, align = "right", style = "shadow", center_y = true })

    draw_bar(L, col, amt, 1 - math.min(st.off, 15) / 15)
end

local aim_state = setmetatable({}, { __mode = "k" })

-- the numbers behind standing on a position: per lineup how far off you are and whether you're lined up
-- (with a gap between getting in and out), the one you're closest to first. Draws nothing.
local function aim_update(g, list, angles, updating, speed)
    local active, active_raw
    for _, s in ipairs(list) do
        local raw = angle_delta(angles, s.angles)
        local st = aim_state[s]
        if not st then
            st = { off = raw, ready = false, amt = 0 }
            aim_state[s] = st
        end
        if updating then
            st.ready = (st.ready and raw < READY_EXIT) or raw < READY_ENTER
            st.off = approach(st.off, raw, speed)
            st.amt = approach(st.amt, st.ready and 1 or 0, speed)
        end
        if not active or raw < active_raw then active, active_raw = s, raw end
    end
    return { g = g, list = list, active = active, raw = active_raw }
end

local function aim_draw(aim, eye, amt, all, center, screen)
    for _, s in ipairs(aim.list) do
        local st = aim_state[s]
        local col = tint_of(s):lerp(ready_color:get(), st.amt)
        local is_active = s == aim.active
        local target = (eye + s.angles:forward() * 2000):to_screen()
        local on_screen = target and target.x > 0 and target.x < screen.x and target.y > 0 and target.y < screen.y
        if on_screen then
            draw_reticle(target, col, amt, st, is_active, st.off, s == selected)
            if #aim.list > 1 then
                render.text(target + vec2(0, 18), col:alpha((is_active and 255 or 150) * amt), s.name,
                    { font = small_font, align = "center", style = "outline" })
            end
        end
    end
    draw_hud(aim.hud, aim.active, aim_state[aim.active], amt)
end

-- ---- the auto throw cue ----
-- While auto throw runs, the strip under the crosshair says what it's doing; a bar fills over the run-up.

local PIN_MIN = 0.25  -- the click is held at least this long (the throw strength settles)

local function draw_run_cue(r, eye, center)
    local s = r.spot
    local throwing = r.phase == "throw" or r.phase == "tail"
    local col = throwing and ready_color:get() or tint_of(s)

    local target = (eye + s.angles:forward() * 2000):to_screen()
    if target then draw_reticle(target, col, 1, { amt = throwing and 1 or 0 }, true, 0, false) end

    local text, progress
    if r.phase == "walk" then
        text, progress = "WALKING", 0
    elseif r.phase == "aim" then
        text, progress = "AIMING", 0
    elseif r.phase == "pin" then
        text, progress = "PIN", math.min(r.t / PIN_MIN, 1)
    elseif r.phase == "move" then
        text, progress = string.format("RUN %.2f", math.max(s.move_time - r.t, 0)), math.min(r.t / s.move_time, 1)
    else
        text, progress = r.states.Jump and "JUMP + THROW" or "THROW", 1
    end

    local head = s.name
    local w = 8 + text_width(head, big_font) + 14 + math.max(text_width(text, font), text_width("JUMP + THROW", font)) + 8
    local L = { x = center.x - w / 2, y = center.y + 28, w = w, h = 19 }
    panel(L.x, L.y, L.w, L.h, col, 1)
    local row = L.y + (L.h - 3) / 2
    render.text(vec2(L.x + 9, row), color(255, 255, 255, 240), head, { font = big_font, style = "shadow", center_y = true })
    render.text(vec2(L.x + L.w - 8, row), throwing and col or color(200, 200, 205, 230), text,
        { font = font, align = "right", style = "outline", center_y = true })
    draw_bar(L, col, 1, progress)
end

-- ---- the frame ----

local stand_now, stand_group, stand_amt, last_stand = nil, nil, 0, nil
local seen_version, eye_h = -1, nil

local run = nil -- the auto throw in progress (see below)

-- Draws in layers, so what matters most is on top: the rings on the ground, then the cards over positions
-- (far to near, and a card that would sit on a nearer card or on the strip fades back), then the aim
-- points and the strip under the crosshair last. Returns the lineup you're aiming at, if any.
local function frame()
    if not enabled:get() or not engine.is_in_game() then return end
    local me = entities.local_player()
    if not me or not me:alive() then return end

    local map = engine.get_level_name_short()
    local origin = me:origin()
    local holding = held_grenade(me)
    local all = filter:get() == "All grenades"
    if not all and not holding then
        stand_now, stand_group, stand_amt, last_stand = nil, nil, 0, nil
        if not run then return end
    end

    local speed, range = smooth_speed(40, 4), draw_distance:get()
    local angles = eye_angles(me)
    local groups = get_groups(map)
    if seen_version ~= spots_version then
        stand_now, stand_group, stand_amt, last_stand, seen_version = nil, nil, 0, nil, spots_version
    end

    if stand_now and (stand_now.map ~= map or stand_now.pos:dist(origin) > STAND_EXIT
            or #matching_spots(stand_now, holding, all) == 0) then
        stand_now = nil
    end
    if not stand_now then
        local best_distance = STAND_ENTER
        for _, g in ipairs(groups) do
            local distance = g.pos:dist(origin)
            if distance < best_distance and #matching_spots(g, holding, all) > 0 then
                stand_now, best_distance = g, distance
            end
        end
    end
    if stand_now ~= last_stand then
        if stand_now then
            for _, s in ipairs(stand_now.spots) do aim_state[s] = nil end
        end
        last_stand = stand_now
    end
    if stand_now then stand_group = stand_now end
    stand_amt = approach(stand_amt, stand_now and 1 or 0, speed)
    if not stand_now and stand_amt < 0.02 then stand_group, stand_amt = nil, 0 end
    eye_h = approach(eye_h or eye_height(me), eye_height(me), speed)
    local eye = origin + vector(0, 0, eye_h)

    local screen = render.screen_size()
    local center = vec2(screen.x / 2, screen.y / 2)

    -- what is in range, far to near
    local entries = {}
    for _, g in ipairs(groups) do
        local distance = g.pos:dist(origin)
        if distance < range then
            local list = matching_spots(g, holding, all)
            if #list > 0 then
                entries[#entries + 1] = {
                    g = g,
                    list = list,
                    distance = distance,
                    fade = 1 - math.max(0, (distance - range * 0.7) / (range * 0.3)),
                    standing = g == stand_group and stand_amt > 0.5,
                    tint = #list == 1 and tint_of(list[1]) or spot_color:get(),
                }
            end
        end
    end
    table.sort(entries, function(a, b) return a.distance > b.distance end)

    -- 1. the rings on the ground
    for _, e in ipairs(entries) do
        ground_ring(e.g.pos, e.standing and 8 or 10, e.tint:alpha(200 * e.fade), 1.2, (e.standing and 30 * e.fade) or 0)
        local center_dot = e.g.pos:to_screen()
        if center_dot then render.circle_filled(center_dot, 1.5, e.tint:alpha(200 * e.fade)) end
    end

    -- the position you stand on (not during an auto throw: the strip is its cue then)
    local aim, aimed
    if not run then
        for _, e in ipairs(entries) do
            if e.standing then
                aim = aim_update(e.g, e.list, angles, e.g == stand_now, speed)
                if e.g == stand_now then
                    aimed_here = {}
                    for _, s in ipairs(e.list) do
                        if angle_delta(angles, s.angles) < AIM_EDIT then aimed_here[#aimed_here + 1] = s end
                    end
                    if aim.raw < AIM_EDIT then aimed = aim.active end
                    if ui.is_open() and selected then
                        for _, s in ipairs(aimed_here) do
                            if s == selected then aim.active = selected end
                        end
                    end
                end
                aim.hud = hud_layout(aim.active, all, center)
            end
        end
    end

    -- 2. the cards over positions: the nearest claims its room first, a card on top of a claimed one fades
    -- back; they're drawn far to near so the nearer ones lie on top
    local placed = {}
    if aim then placed[1] = aim.hud end
    local cards = {}
    for i = #entries, 1, -1 do
        local e = entries[i]
        if not e.standing then
            local at = (e.g.pos + vector(0, 0, 20)):to_screen()
            if at then
                local L = label_layout(at, e.list, e.distance)
                local fade_back = 1
                for _, r in ipairs(placed) do
                    if overlaps(L, r, 3) then
                        fade_back = 0.2
                        break
                    end
                end
                if fade_back == 1 then placed[#placed + 1] = L end
                cards[#cards + 1] = { L = L, e = e, fade_back = fade_back }
            end
        end
    end
    for i = #cards, 1, -1 do
        local c = cards[i]
        draw_label(c.L, c.e.list, c.e.fade * c.fade_back, c.e.tint)
    end

    -- 3. the aim points and the strip, on top of everything
    if aim then aim_draw(aim, eye, stand_amt, all, center, screen) end
    if run then draw_run_cue(run, eye, center) end
    return aimed
end

events.render:set(function()
    aimed_here = {}
    local aimed = frame()
    if not ui.is_open() and aimed ~= selected then
        selected = aimed
        load_edit_fields()
    end
end)

-- ---- walking ----------------------------------------------------------------------------------

local walk_target = nil
local last_aim_time = nil
local MIN_AIM_SPEED = 20

local function tick_dt()
    local now = globals.realtime()
    local dt = last_aim_time and now - last_aim_time
    last_aim_time = now
    if not dt or dt <= 0 or dt > 0.2 then dt = globals.frametime() end
    return math.min(math.max(dt, 0.001), 0.05)
end

local function ease_aim(cmd, target, dt)
    local current = cmd:get_viewangles()
    local d_pitch, d_yaw = target.x - current.x, wrap_angle(target.y - current.y)
    local distance = math.sqrt(d_pitch * d_pitch + d_yaw * d_yaw)
    local speed = smooth_speed(30, 1.5)

    local share = 1
    if speed and distance >= 0.15 then
        local step = math.max(distance * (1 - math.exp(-speed * dt)), math.min(distance, MIN_AIM_SPEED * dt))
        share = step / distance
    end
    cmd:set_viewangles(vector(current.x + d_pitch * share, wrap_angle(current.y + d_yaw * share), 0))
end

-- the closest lineup within reach, and on its position the one nearest your aim
local function nearest_lineup(me, map, origin, view, all)
    local holding, best, best_distance = held_grenade(me), nil, walk_distance:get()
    for _, g in ipairs(get_groups(map)) do
        local distance = g.pos:dist(origin)
        if distance < best_distance then
            local pick = best_lineup(matching_spots(g, holding, all), holding, view)
            if pick then best, best_distance = pick, distance end
        end
    end
    return best
end

-- one tick of walking onto pos; true once you're standing on it
local function walk_toward(cmd, me, origin, pos)
    local ahead = pos - (origin + me:velocity() * 0.1)
    local distance = (pos - origin):length2d()
    if distance < 1.5 and ahead:length2d() < 3 then
        cmd:walk(0, 0)
        return true
    end
    local yaw = math.rad(math.deg(math.atan2(ahead.y, ahead.x)) - cmd:get_viewangles().y)
    local forward, side = math.cos(yaw), math.sin(yaw)
    forward = forward > 0.38 and 1 or forward < -0.38 and -1 or 0
    side = side > 0.38 and 1 or side < -0.38 and -1 or 0
    cmd:walk(forward, side, distance < 48)
    return false
end

events.create_move:set(function(cmd)
    if run then return end
    if not enabled:get() or not walk_key:get() or not engine.is_in_game() then
        walk_target = nil
        return
    end
    local me = entities.local_player()
    if not me or not me:alive() then return end

    local map, origin = engine.get_level_name_short(), me:origin()
    if not walk_target or walk_target.map ~= map then
        local pick = nearest_lineup(me, map, origin, cmd:get_viewangles(), filter:get() == "All grenades")
        walk_target = pick and { map = map, pos = pick.pos, angles = pick.angles }
        if not walk_target then return end
    end

    if walk_toward(cmd, me, origin, walk_target.pos) then
        ease_aim(cmd, walk_target.angles, tick_dt())
    end
end)

-- ---- auto throw -------------------------------------------------------------------------------
-- Hold the key with a grenade out. Once per press, let go to cancel:
--   walk   onto the nearest lineup's spot
--   aim    ease the aim onto it and stand still
--   pin    hold the click(s) (and crouch) until the pin is out
--   move   hold the run-up keys for the run-up time (walk key too when the lineup walks)
--   throw  jump if the lineup jumps, and let go of the click(s) in the same tick
--   tail   keep the keys a moment so the throw leaves with the speed it was lined up with, then hand back

local PIN_MAX = 3     -- the pin never came out (no grenade drawn?): give up
local TAIL = 0.3      -- seconds the run-up keys stay held after the throw
local JUMP_HOLD = 0.1 -- seconds jump stays held

local function clicks_of(states)
    if states["Both clicks"] then return true, true end
    if states["Right click"] then return false, true end
    return true, false
end

local function run_keys(spot)
    local keys = spot.keys or 0
    local forward = (bit.band(keys, 1) ~= 0 and 1 or 0) - (bit.band(keys, 2) ~= 0 and 1 or 0)
    local side = (bit.band(keys, 4) ~= 0 and 1 or 0) - (bit.band(keys, 8) ~= 0 and 1 or 0) -- left is positive
    return forward, side
end

local function pin_out(me)
    local weapon = me:get_active_weapon()
    return weapon ~= nil and weapon.m_bPinPulled == true
end

local function stop_run(reason)
    if reason then client.notify("Grenade helper", reason, "warning") end
    run = nil
end

local run_was_down = false

events.create_move:set(function(cmd)
    local key = enabled:get() and throw_key:get() and engine.is_in_game()
    local pressed = key and not run_was_down -- starts on the press, never mid-hold
    run_was_down = key

    -- letting go cancels while walking and aiming; once the pin is out the throw finishes (letting go of the
    -- click would throw it anyway)
    if run and not run.from_menu and not key and (run.phase == "walk" or run.phase == "aim") then run = nil end
    local me = entities.local_player()
    if not me or not me:alive() or not engine.is_in_game() then
        run = nil
        return
    end

    if not run then
        local spot, from_menu = nil, rethrow
        local holding = held_grenade(me)
        if rethrow then -- the draft, once more ("Throw again")
            rethrow, spot = false, draft
            if not spot then return end
            if holding ~= spot.grenade then
                client.notify("Grenade helper", "Take out the " .. spot.grenade .. " to throw it again.", "warning")
                return
            end
        else
            if not pressed then return end
            if not holding then
                client.notify("Grenade helper", "Take out a grenade first.", "warning")
                return
            end
            spot = nearest_lineup(me, engine.get_level_name_short(), me:origin(), cmd:get_viewangles(), false)
            if not spot then
                client.notify("Grenade helper", "No " .. holding .. " lineup within reach.", "warning")
                return
            end
        end
        run = { spot = spot, states = parse_states(spot.throw), phase = "walk", t = 0, from_menu = from_menu }
        last_aim_time = nil
    end

    local spot, states = run.spot, run.states
    local dt = tick_dt()
    local exact = vector(spot.angles.x, spot.angles.y, 0)
    local left, right = clicks_of(states)
    local forward, side = run_keys(spot)
    local moves = has_move(spot)
    run.t = run.t + dt

    if run.phase == "tail" then
        if run.t >= TAIL then
            run = nil
            return
        end
        cmd:set_viewangles(exact)
        if moves then cmd:walk(forward, side, states.Walk == true) end
        cmd:set_button("jump", states.Jump == true and run.t < JUMP_HOLD)
        if states.Crouch then cmd:set_button("duck", true) end
        return
    end

    if run.phase ~= "walk" and held_grenade(me) ~= spot.grenade then
        stop_run("Grenade changed, auto throw stopped.")
        return
    end

    local origin = me:origin()
    if run.phase == "walk" then
        if walk_toward(cmd, me, origin, spot.pos) then run.phase, run.t = "aim", 0 end
        return
    end

    if run.phase == "aim" then
        if (spot.pos - origin):length2d() > 3 then
            run.phase = "walk"
            return
        end
        cmd:walk(0, 0)
        ease_aim(cmd, exact, dt)
        if angle_delta(cmd:get_viewangles(), exact) < 0.1 and me:velocity():length2d() < 1 then
            run.phase, run.t = "pin", 0
        end
        return
    end

    cmd:set_viewangles(exact)
    cmd:set_button("attack", left)
    cmd:set_button("attack2", right)
    if states.Crouch then cmd:set_button("duck", true) end

    if run.phase == "pin" then
        cmd:walk(0, 0)
        local crouched = not states.Crouch or bit.band(me.m_fFlags or 0, 2) ~= 0
        local ready = run.t >= PIN_MIN and pin_out(me) and crouched
        if ready then
            run.phase, run.t = moves and "move" or "throw", 0
        elseif run.t > PIN_MAX then
            stop_run("The pin didn't come out, auto throw stopped.")
        end
        return
    end

    if run.phase == "move" then
        cmd:walk(forward, side, states.Walk == true)
        if run.t >= spot.move_time then run.phase, run.t = "throw", 0 end
        return
    end

    -- the throw: jump (pressed before the release, in the same tick) and let go of the click(s)
    if moves then cmd:walk(forward, side, states.Walk == true) else cmd:walk(0, 0) end
    cmd:set_button("jump", states.Jump == true)
    cmd:set_button("attack", false)
    cmd:set_button("attack2", false)
    run.phase, run.t = "tail", 0
end)

-- ---- recording throws -------------------------------------------------------------------------
-- With "Record my throws" on, each grenade you throw yourself becomes the draft (Add / Dismiss): the spot is where you were when
-- you pressed the move keys you threw with (or where you threw, standing), the move time how long they were held.
-- Jump can come a tick after the click, so the save waits a moment for it.

local REC_JUMP_WINDOW = 0.25
local REC_BUTTONS = { { "forward", 1 }, { "back", 2 }, { "move_left", 4 }, { "move_right", 8 } }
local rec = { start_pos = nil, move_start = nil, clicks = nil, pending = nil }

local function rec_finish(p)
    local states = p.states
    if p.jump then states[#states + 1] = "Jump" end
    p.spot.throw = states_text(states)
    p.spot.map = engine.get_level_name_short()
    local first = draft == nil
    draft = p.spot
    if first then
        client.notify("Grenade helper", "Throw recorded: Add or Dismiss it in the menu.", "info")
    end
end

function add_draft()
    if not draft then return end
    local spot = draft
    draft = nil
    add_spot(spot)
end

function dismiss_draft()
    draft, rethrow = nil, false
end

function goto_draft()
    if not draft or not engine.is_in_game() then return end
    local pos, angles = draft.pos, draft.angles
    local command = string.format("setpos %.3f %.3f %.3f; setang %.3f %.3f 0", pos.x, pos.y, pos.z, angles.x, angles.y)
    if not engine.execute(command) then
        client.notify("Grenade helper", "Couldn't run setpos (game update?).", "error")
    end
end

-- the draft on the map: a ring where the throw started, a card over it and the point it aimed at
events.render:set(function()
    if not draft or not enabled:get() or not engine.is_in_game() then return end
    if draft.map ~= engine.get_level_name_short() then
        draft = nil
        return
    end
    local col = color(255, 255, 255, 220)
    ground_ring(draft.pos, 10, col, 1.5, 25)

    local at = (draft.pos + vector(0, 0, 20)):to_screen()
    if at then
        local title = "UNSAVED " .. draft.grenade:upper()
        local how = states_label(draft.throw) .. (move_label(draft) and (" | " .. move_label(draft)) or "")
        local w = math.max(text_width(title, font), text_width(how, font)) + 16
        local x, y = at.x - w / 2, at.y - 28
        panel(x, y, w, 28, col, 1)
        render.text(vec2(x + 8, y + 4), col, title, { font = font, style = "shadow" })
        render.text(vec2(x + 8, y + 15), tint_of(draft), how, { font = font, style = "outline" })
    end

    local target = (draft.pos + vector(0, 0, 64.06) + draft.angles:forward() * 2000):to_screen()
    if target then
        render.circle(target, 5, col, 0, 1.5)
        render.circle_filled(target, 1.5, col)
    end
end)

events.create_move:set(function(cmd)
    if not enabled:get() or not record:get() or run or not engine.is_in_game() then
        rec.clicks, rec.pending = nil, nil
        return
    end
    local me = entities.local_player()
    if not me or not me:alive() then
        rec.clicks, rec.pending, rec.move_start = nil, nil, nil
        return
    end

    local now, origin = globals.realtime(), me:origin()
    local jump = cmd:has_button("jump")

    local p = rec.pending
    if p then
        p.jump = p.jump or jump
        if now >= p.save_at then
            rec.pending = nil
            rec_finish(p)
        end
    end

    local keys = 0
    for _, b in ipairs(REC_BUTTONS) do
        if cmd:has_button(b[1]) then keys = keys + b[2] end
    end
    if keys == 0 then
        rec.start_pos, rec.move_start = origin, nil
    elseif not rec.move_start then
        rec.move_start = now
    end

    local grenade = held_grenade(me)
    local a1, a2 = cmd:has_button("attack"), cmd:has_button("attack2")
    if grenade and (a1 or a2) then
        rec.clicks = rec.clicks or {}
        rec.clicks.a1, rec.clicks.a2 = rec.clicks.a1 or a1, rec.clicks.a2 or a2
        return
    end
    local clicks = rec.clicks
    rec.clicks = nil
    if not clicks or not grenade or rec.pending then return end

    -- let go of the click with a grenade out: that's the throw
    local angles = cmd:get_viewangles()
    local move_time = rec.move_start and now - rec.move_start or 0
    if move_time > 5 or not rec.start_pos then keys = 0 end -- a long run isn't a lineup: save it as thrown here

    local states = {}
    if cmd:has_button("duck") then states[#states + 1] = "Crouch" end
    if cmd:has_button("speed") then states[#states + 1] = "Walk"
    elseif keys ~= 0 then states[#states + 1] = "Run" end
    if clicks.a1 and clicks.a2 then states[#states + 1] = "Both clicks"
    elseif clicks.a2 then states[#states + 1] = "Right click" end

    rec.pending = {
        save_at = now + REC_JUMP_WINDOW,
        jump = jump,
        states = states,
        spot = {
            grenade = grenade,
            keys = keys,
            move_time = keys ~= 0 and move_time or 0,
            pos = keys ~= 0 and rec.start_pos or origin,
            angles = vector(angles.x, angles.y, 0),
        },
    }
end)

events.render:set(function()
    if not walk_target or not engine.is_in_game() then return end
    local me = entities.local_player()
    if not me then return end
    local from, to = me:origin():to_screen(), walk_target.pos:to_screen()
    if from and to then
        render.line(from, to, ready_color:get():alpha(160), 2)
        render.circle_filled(to, 2.5, ready_color:get():alpha(220))
    end
end)

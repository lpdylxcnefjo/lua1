local pui = require("neverlose/pui")
local gradient = require("neverlose/gradient")
local clipboard = require("neverlose/clipboard")

local VERSION = "1.0"
local FOLDER = ".\\metasoon"
local DB_FILE = FOLDER .. "\\db.dat"
local stats = {kills = 0, misses = 0}
local session_start = globals.realtime

local logo = gradient.text_animate("M E T A S O O N", -2, {
    color(0, 150, 255),
    color(0, 50, 120),
    color(0, 0, 0)
})

local function geticon(name)
    local ok, g = pcall(ui.get_icon, name)
    return (ok and g) or ""
end

local function ico(name, text)
    local g = geticon(name)
    if g == "" then return text end
    return g .. "  " .. text
end

local IC = {
    user = geticon("circle-user"),
    code = geticon("code"),
    total = geticon("hourglass"),
    session = geticon("clock"),
    kills = geticon("skull"),
    misses = geticon("crosshairs"),
}

local T_MAIN = ico("house", "Main")
local T_AA = ico("person-falling", "Anti-Aim")
local T_MISC = ico("layer-group", "Misc")

local function fmt_time(sec)
    sec = math.floor(sec)
    return string.format("%dh %dm %ds", math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60)
end

local function read_db()
    local raw = files.read(DB_FILE)
    if not raw then return {total = 0, configs = {}} end
    local ok, data = pcall(json.parse, raw)
    if not ok or type(data) ~= "table" then return {total = 0, configs = {}} end
    data.configs = data.configs or {}
    data.total = data.total or 0
    return data
end

local function write_db(data)
    files.create_folder(FOLDER)
    files.write(DB_FILE, json.stringify(data))
end

local store = read_db()

local function config_names()
    local t = {}
    for name in pairs(store.configs) do t[#t + 1] = name end
    table.sort(t)
    return t
end

local function set_vis(items, vis)
    for _, item in ipairs(items) do item:visibility(vis) end
end

-- Main
local main_nav = pui.create(T_MAIN, "\nmain_nav", 1)
local main_list = main_nav:list("\n", {ico("house", "Home"), ico("gear", "Config")})

-- Home (3 boxes without titles)
local home_info = pui.create(T_MAIN, "\nhome_info", 2)
local lbl_user = home_info:label("Username")
local lbl_ver = home_info:label("Version")

local home_time = pui.create(T_MAIN, "\nhome_time", 2)
local lbl_total = home_time:label("Total")
local lbl_session = home_time:label("Session")

local home_combat = pui.create(T_MAIN, "\nhome_combat", 2)
local lbl_kills = home_combat:label("Kills")
local lbl_misses = home_combat:label("Misses")

local home_page = {lbl_user, lbl_ver, lbl_total, lbl_session, lbl_kills, lbl_misses}

-- Config
local cfg_box = pui.create(T_MAIN, "\nconfig", 2)
local cfg_name = cfg_box:input(ico("pen", "Config Name"), "Type Here")
local cfg_list = cfg_box:list("Configs", {"empty"})
local cfg_save = cfg_box:button(ico("floppy-disk", "Save"), function() end)
local cfg_load = cfg_box:button(ico("download", "Load"), function() end)
local cfg_delete = cfg_box:button(ico("trash", "Delete"), function() end)
local cfg_export = cfg_box:button(ico("copy", "Export to clipboard"), function() end)
local cfg_import = cfg_box:button(ico("paste", "Import from clipboard"), function() end)
local config_page = {cfg_name, cfg_list, cfg_save, cfg_load, cfg_delete, cfg_export, cfg_import}

local function refresh_list()
    local n = config_names()
    if #n == 0 then n = {"empty"} end
    cfg_list:update(n)
end

cfg_save:set_callback(function()
    local name = cfg_name:get()
    if not name or name == "" then return end
    store.configs[name] = pui.save()
    write_db(store)
    refresh_list()
end)

cfg_load:set_callback(function()
    local name = config_names()[cfg_list:get()]
    if name and store.configs[name] then pui.load(store.configs[name]) end
end)

cfg_delete:set_callback(function()
    local name = config_names()[cfg_list:get()]
    if name and store.configs[name] then
        store.configs[name] = nil
        write_db(store)
        refresh_list()
    end
end)

cfg_export:set_callback(function()
    clipboard.set(json.stringify(pui.save()))
end)

cfg_import:set_callback(function()
    local raw = clipboard.get()
    if not raw or raw == "" then return end
    local ok, data = pcall(json.parse, raw)
    if ok then pui.load(data) end
end)

refresh_list()

-- Anti-Aim (own sidebar tab, between Main and Misc; left listbox like Misc)
local aa_nav = pui.create(T_AA, "\naa_nav", 1)
local aa_list = aa_nav:list("\n", {ico("gears", "Setup"), ico("helmet-safety", "Builder"), ico("bolt", "Exploit")})

-- Anti-Aim > Builder: left = team + conditions (below listbox), right = builder
local aa_left = pui.create(T_AA, "\naa_left", 1)
local aa_team = aa_left:combo(ico("people-group", "Choose Team"), {"T", "CT"})
local aa_state = aa_left:combo(ico("person-running", "Anti-Aim State"), {"Standing", "Moving", "Walking", "Crouching", "In Air"})

local aa_right = pui.create(T_AA, "\naa_right", 2)

-- The builder drives the cheat's OWN Anti-Aim references.
-- These option lists MUST match the strings in your Neverlose menu, because
-- combos are pushed into the native items via :set(<string>). Tweak them if a
-- future NL build renames an option.
local YAW_OPTS   = {"Off", "Forward", "Backward", "Right", "Left"}
local BASE_OPTS  = {"Local View", "At Target", "Freestanding"}
local MOD_OPTS   = {"Disabled", "Center", "Offset", "Sway", "Spin", "Random", "3-Way"}
local BODY_OPTS  = {"Disabled", "Static", "Jitter", "Opposite"}
local PITCH_OPTS = {"Off", "Down", "Up", "Minimal", "Custom"}

-- Master enable -> Aimbot/Anti Aim/Angles/Enabled
local aa_enable = aa_right:switch(ico("power-off", "Enabled"), false)

local aa_yaw    = aa_right:combo(ico("pen", "Yaw"), YAW_OPTS)
local aa_base   = aa_right:combo(ico("compass", "Yaw Base"), BASE_OPTS)
local aa_offset = aa_right:slider(ico("ruler-horizontal", "Yaw Offset"), -180, 180, 0)

-- Yaw Modifier with its own gear: Degrees (-180..180) -> Yaw Modifier/Offset
local mod_degrees
local aa_modifier = aa_right:combo(ico("ruler", "Yaw Modifier"), MOD_OPTS, function(s)
    mod_degrees = s:slider("Degrees", -180, 180, 0)
end)

-- Body Yaw with gear: Left / Right limits
local body_left, body_right
local aa_body = aa_right:combo(ico("infinity", "Body Yaw"), BODY_OPTS, function(s)
    body_left  = s:slider("Left Limit", -180, 180, -60)
    body_right = s:slider("Right Limit", -180, 180, 60)
end)

local aa_pitch = aa_right:combo(ico("compass-drafting", "Pitch"), PITCH_OPTS)

local aa_builder_page = {aa_enable, aa_team, aa_state, aa_yaw, aa_base, aa_offset, aa_modifier, aa_body, aa_pitch}

-- Misc (listbox: Ragebot / Visuals / Misc)
local misc_nav = pui.create(T_MISC, "\nmisc_nav", 1)
local misc_list = misc_nav:list("\n", {ico("bullseye", "Ragebot"), ico("paintbrush", "Visuals"), ico("bars", "Misc")})

-- Misc
local misc_box = pui.create(T_MISC, "\nmisc_box", 2)
local misc_page = {misc_box:switch(ico("gear", "Enabled"), false)}

-- Visuals (3 boxes)
local vis_left = pui.create(T_MISC, "\nvis_left", 1)
local vis_rtop = pui.create(T_MISC, "\nvis_rtop", 2)
local vis_rbot = pui.create(T_MISC, "\nvis_rbot", 2)
local visual_page = {
    vis_left:switch(ico("crosshairs", "Custom Scope"), false),
    vis_left:switch(ico("expand", "Aspect Ratio"), false),
    vis_left:switch(ico("hand", "Viewmodel"), false),
    vis_left:switch(ico("dollar-sign", "500$ Indicators"), false),
    vis_left:switch(ico("star", "Hitmarker"), false),
    vis_rtop:switch(ico("bookmark", "Watermark"), false),
    vis_rtop:switch(ico("keyboard", "Keybinds"), false),
    vis_rtop:switch(ico("eye", "Spectators"), false),
    vis_rbot:switch(ico("tag", "Clantag"), false),
    vis_rbot:switch(ico("wand-magic-sparkles", "Screen Indicator"), false),
    vis_rbot:switch(ico("left-right", "Manual Arrows"), false),
    vis_rbot:switch(ico("list-ol", "Damage Indicator"), false),
    vis_rbot:switch(ico("triangle-exclamation", "Velocity Warning"), false),
}

-- Events
events.player_death:set(function(e)
    local me = entity.get_local_player()
    local attacker = entity.get(e.attacker, true)
    if me and attacker == me then stats.kills = stats.kills + 1 end
end)

events.aim_ack:set(function(e)
    if e.state then stats.misses = stats.misses + 1 end
end)

-- Native Neverlose Anti-Aim references (Aimbot > Anti Aim > Angles)
local function nl(...)
    local ok, ref = pcall(ui.find, ...)
    return ok and ref or nil
end

local refs = {
    enabled    = nl("Aimbot", "Anti Aim", "Angles", "Enabled"),
    yaw        = nl("Aimbot", "Anti Aim", "Angles", "Yaw"),
    base       = nl("Aimbot", "Anti Aim", "Angles", "Yaw", "Base"),
    offset     = nl("Aimbot", "Anti Aim", "Angles", "Yaw", "Offset"),
    modifier   = nl("Aimbot", "Anti Aim", "Angles", "Yaw Modifier"),
    mod_offset = nl("Aimbot", "Anti Aim", "Angles", "Yaw Modifier", "Offset"),
    body       = nl("Aimbot", "Anti Aim", "Angles", "Body Yaw"),
    body_left  = nl("Aimbot", "Anti Aim", "Angles", "Body Yaw", "Left Limit"),
    body_right = nl("Aimbot", "Anti Aim", "Angles", "Body Yaw", "Right Limit"),
    pitch      = nl("Aimbot", "Anti Aim", "Angles", "Pitch"),
}

-- Read a sub-item value (gear sliders may be nil until their gear is built)
local function ref_get(ref, default)
    if not ref then return default end
    return ref:get()
end

-- Write a value into a native menu item; ignore missing items / bad strings
local function set_ref(ref, value)
    if not ref or value == nil then return end
    pcall(function() ref:set(value) end)
end

-- Push the builder's settings into the cheat's own Anti-Aim menu
local function apply_aa()
    set_ref(refs.enabled, aa_enable:get())
    if not aa_enable:get() then return end

    set_ref(refs.yaw, YAW_OPTS[aa_yaw:get()])
    set_ref(refs.base, BASE_OPTS[aa_base:get()])
    set_ref(refs.offset, aa_offset:get())

    set_ref(refs.modifier, MOD_OPTS[aa_modifier:get()])
    set_ref(refs.mod_offset, ref_get(mod_degrees, 0)) -- the Degrees gear (-180..180)

    set_ref(refs.body, BODY_OPTS[aa_body:get()])
    set_ref(refs.body_left, ref_get(body_left, -60))
    set_ref(refs.body_right, ref_get(body_right, 60))

    set_ref(refs.pitch, PITCH_OPTS[aa_pitch:get()])
end

events.createmove:set(apply_aa)

events.shutdown:set(function()
    store.total = store.total + (globals.realtime - session_start)
    write_db(store)
end)

events.render:set(function()
    logo:animate()
    pui.sidebar(logo:get_animated_text(), "fire-flame-curved")
    if ui.get_alpha() <= 0 then return end

    local session = globals.realtime - session_start
    lbl_user:name(IC.user .. "  Username: " .. common.get_username())
    lbl_ver:name(IC.code .. "  Version: " .. VERSION)
    lbl_total:name(IC.total .. "  Total: " .. fmt_time(store.total + session))
    lbl_session:name(IC.session .. "  Session: " .. fmt_time(session))
    lbl_kills:name(IC.kills .. "  Kills: " .. stats.kills)
    lbl_misses:name(IC.misses .. "  Misses: " .. stats.misses)

    set_vis(home_page, main_list:get() == 1)
    set_vis(config_page, main_list:get() == 2)

    set_vis(aa_builder_page, aa_list:get() == 2)

    local m = misc_list:get()
    set_vis(visual_page, m == 2)
    set_vis(misc_page, m == 3)
end)

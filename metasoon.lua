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
local main_nav = pui.create("Main", "\nmain_nav", 1)
local main_list = main_nav:list("\n", {"Home", "Config"})

-- Home (3 boxes without titles)
local home_info = pui.create("Main", "\nhome_info", 2)
local lbl_user = home_info:label("Username")
local lbl_ver = home_info:label("Version")

local home_time = pui.create("Main", "\nhome_time", 2)
local lbl_total = home_time:label("Total")
local lbl_session = home_time:label("Session")

local home_combat = pui.create("Main", "\nhome_combat", 2)
local lbl_kills = home_combat:label("Kills")
local lbl_misses = home_combat:label("Misses")

local home_page = {lbl_user, lbl_ver, lbl_total, lbl_session, lbl_kills, lbl_misses}

-- Config
local cfg_box = pui.create("Main", "\nconfig", 2)
local cfg_name = cfg_box:input("Config Name", "Type Here")
local cfg_list = cfg_box:list("Configs", {"empty"})
local cfg_save = cfg_box:button("Save", function() end)
local cfg_load = cfg_box:button("Load", function() end)
local cfg_delete = cfg_box:button("Delete", function() end)
local cfg_export = cfg_box:button("Export to clipboard", function() end)
local cfg_import = cfg_box:button("Import from clipboard", function() end)
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

-- Anti Aim
local aa_nav = pui.create("Anti Aim", "\naa_nav", 1)
local aa_list = aa_nav:list("\n", {"Setup", "Builder", "Exploit"})
local aa_box = pui.create("Anti Aim", "\naa_box", 2)
local aa_pages = {
    {aa_box:switch("Setup", false)},
    {aa_box:switch("Builder", false)},
    {aa_box:switch("Exploit", false)},
}

-- Misc (listbox: Misc / Visual)
local misc_nav = pui.create("Misc", "\nmisc_nav", 1)
local misc_list = misc_nav:list("\n", {"Misc", "Visual"})

local misc_box = pui.create("Misc", "\nmisc_box", 2)
local misc_page = {misc_box:switch("Enabled", false)}

local vis_left = pui.create("Misc", "\nvis_left", 1)
local vis_rtop = pui.create("Misc", "\nvis_rtop", 2)
local vis_rbot = pui.create("Misc", "\nvis_rbot", 2)
local visual_page = {
    vis_left:switch("Custom Scope", false),
    vis_left:switch("Aspect Ratio", false),
    vis_left:switch("Viewmodel", false),
    vis_left:switch("500$ Indicators", false),
    vis_left:switch("Hitmarker", false),
    vis_rtop:switch("Watermark", false),
    vis_rtop:switch("Keybinds", false),
    vis_rtop:switch("Spectators", false),
    vis_rbot:switch("Clantag", false),
    vis_rbot:switch("Screen Indicator", false),
    vis_rbot:switch("Manual Arrows", false),
    vis_rbot:switch("Damage Indicator", false),
    vis_rbot:switch("Velocity Warning", false),
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

events.shutdown:set(function()
    store.total = store.total + (globals.realtime - session_start)
    write_db(store)
end)

events.render:set(function()
    logo:animate()
    pui.sidebar(logo:get_animated_text(), "fire-flame-curved")
    if ui.get_alpha() <= 0 then return end

    local session = globals.realtime - session_start
    lbl_user:name("Username: " .. common.get_username())
    lbl_ver:name("Version: " .. VERSION)
    lbl_total:name("Total: " .. fmt_time(store.total + session))
    lbl_session:name("Session: " .. fmt_time(session))
    lbl_kills:name("Kills: " .. stats.kills)
    lbl_misses:name("Misses: " .. stats.misses)

    set_vis(home_page, main_list:get() == 1)
    set_vis(config_page, main_list:get() == 2)

    for i, page in ipairs(aa_pages) do set_vis(page, aa_list:get() == i) end

    set_vis(misc_page, misc_list:get() == 1)
    set_vis(visual_page, misc_list:get() == 2)
end)

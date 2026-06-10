local pui = require("neverlose/pui")
local gradient = require("neverlose/gradient")
local clipboard = require("neverlose/clipboard")

local logo = gradient.text_animate("M E T A S O O N", -2, {
    color(0, 150, 255),
    color(0, 50, 120),
    color(0, 0, 0)
})

local FOLDER = ".\\metasoon"
local DB_FILE = FOLDER .. "\\db.dat"
local stats = {kills = 0, misses = 0}
local session_start = globals.realtime

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

-- Main
local main_nav = pui.create("Main", "Pages", 1)
local main_list = main_nav:list("Select", {"Home", "Config"})
local main_box = pui.create("Main", "Settings", 2)

-- Home
local lbl_user = main_box:label("Username")
local lbl_total = main_box:label("Total")
local lbl_session = main_box:label("Session")
local lbl_kills = main_box:label("Kills")
local lbl_misses = main_box:label("Misses")
local home = {lbl_user, lbl_total, lbl_session, lbl_kills, lbl_misses}

-- Config
local cfg_name = main_box:input("Config Name", "Type Here")
local cfg_list = main_box:list("Configs", {"empty"})
local cfg_save = main_box:button("Save", function() end)
local cfg_load = main_box:button("Load", function() end)
local cfg_delete = main_box:button("Delete", function() end)
local cfg_export = main_box:button("Export to clipboard", function() end)
local cfg_import = main_box:button("Import from clipboard", function() end)
local config = {cfg_name, cfg_list, cfg_save, cfg_load, cfg_delete, cfg_export, cfg_import}

local main_pages = {home, config}

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
local aa_nav = pui.create("Anti Aim", "AA", 1)
local aa_list = aa_nav:list("Select", {"Setup", "Builder", "Exploit"})
local aa_box = pui.create("Anti Aim", "AA Settings", 2)
local aa_pages = {
    {aa_box:switch("Setup", false)},
    {aa_box:switch("Builder", false)},
    {aa_box:switch("Exploit", false)},
}

-- Misc
local misc_box = pui.create("Misc", "Misc", 2)
misc_box:switch("Enabled", false)
misc_box:switch("Watermark", false)
misc_box:switch("Keybinds", false)
misc_box:switch("Spectators", false)
misc_box:switch("Custom Scope", false)
misc_box:switch("Aspect Ratio", false)
misc_box:switch("Viewmodel", false)
misc_box:switch("Hitmarker", false)
misc_box:switch("Clantag", false)
misc_box:switch("Screen Indicator", false)
misc_box:switch("Manual Arrows", false)
misc_box:switch("Damage Indicator", false)
misc_box:switch("Velocity Warning", false)

local function show_pages(pages, idx)
    for i, page in ipairs(pages) do
        for _, item in ipairs(page) do
            item:visibility(i == idx)
        end
    end
end

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

    if ui.get_alpha() > 0 then
        local session = globals.realtime - session_start
        lbl_user:name("Username: " .. common.get_username())
        lbl_total:name("Total: " .. fmt_time(store.total + session))
        lbl_session:name("Session: " .. fmt_time(session))
        lbl_kills:name("Kills: " .. stats.kills)
        lbl_misses:name("Misses: " .. stats.misses)
        show_pages(main_pages, main_list:get())
        show_pages(aa_pages, aa_list:get())
    end
end)

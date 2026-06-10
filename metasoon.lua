local pui = require("neverlose/pui")
local gradient = require("neverlose/gradient")
local clipboard = require("neverlose/clipboard")

local logo = gradient.text_animate("M E T A S O O N", -2, {
    color(0, 150, 255),
    color(0, 50, 120),
    color(0, 0, 0)
})

local stats = {kills = 0, misses = 0, start = globals.realtime}

local function fmt_time(sec)
    sec = math.floor(sec)
    return string.format("%dh %dm %ds", math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60)
end

-- Main
local main_nav = pui.create("Main", "Pages", 1)
local main_list = main_nav:list("Select", {"Home", "Config"})
local main_box = pui.create("Main", "Settings", 2)

-- Home (statistics)
local lbl_user = main_box:label("Username")
local lbl_session = main_box:label("Session")
local lbl_kills = main_box:label("Kills")
local lbl_misses = main_box:label("Misses")
local home = {lbl_user, lbl_session, lbl_kills, lbl_misses}

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

-- Config logic
local DB_KEY = "metasoon_configs"

local function config_names()
    local names = {}
    for name in pairs(db[DB_KEY] or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

local function refresh_list()
    local names = config_names()
    if #names == 0 then names = {"empty"} end
    cfg_list:update(names)
end

cfg_save:set_callback(function()
    local name = cfg_name:get()
    if not name or name == "" then return end
    local cfgs = db[DB_KEY] or {}
    cfgs[name] = pui.save()
    db[DB_KEY] = cfgs
    refresh_list()
end)

cfg_load:set_callback(function()
    local cfgs = db[DB_KEY] or {}
    local name = config_names()[cfg_list:get()]
    if name and cfgs[name] then pui.load(cfgs[name]) end
end)

cfg_delete:set_callback(function()
    local cfgs = db[DB_KEY] or {}
    local name = config_names()[cfg_list:get()]
    if name and cfgs[name] then
        cfgs[name] = nil
        db[DB_KEY] = cfgs
        refresh_list()
    end
end)

cfg_export:set_callback(function()
    clipboard.set(json.stringify(pui.save()))
end)

cfg_import:set_callback(function()
    local data = clipboard.get()
    if data and data ~= "" then pui.load(json.parse(data)) end
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

events.render:set(function()
    logo:animate()
    pui.sidebar(logo:get_animated_text(), "fire-flame-curved")

    if ui.get_alpha() > 0 then
        lbl_user:name("Username: " .. common.get_username())
        lbl_session:name("Session: " .. fmt_time(globals.realtime - stats.start))
        lbl_kills:name("Kills: " .. stats.kills)
        lbl_misses:name("Misses: " .. stats.misses)
        show_pages(main_pages, main_list:get())
        show_pages(aa_pages, aa_list:get())
    end
end)

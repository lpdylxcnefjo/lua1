local pui = require("neverlose/pui")
local gradient = require("neverlose/gradient")

local logo = gradient.text_animate("M E T A S O O N", -2, {
    color(0, 150, 255),
    color(0, 50, 120),
    color(0, 0, 0)
})

-- Main
local main_nav = pui.create("Main", "
main_nav", 1)
local main_list = main_nav:list("
", {"Home", "Rage", "Visual", "Extra", "Config"})
local main_box = pui.create("Main", "
main_box", 2)

local home = {
    main_box:label("we wish you a good experience"),
    main_box:label("wake up the demon and kill your opponents"),
    main_box:button("Discord", function() panorama.SteamOverlayAPI.OpenExternalBrowserURL("https://discord.gg/") end),
    main_box:button("YouTube", function() panorama.SteamOverlayAPI.OpenExternalBrowserURL("https://youtube.com/") end),
}
local rage = {
    main_box:switch("Enabled", false),
}
local visual = {
    main_box:switch("Watermark", false),
    main_box:switch("Keybinds", false),
    main_box:switch("Spectators", false),
    main_box:switch("Custom Scope", false),
    main_box:switch("Aspect Ratio", false),
    main_box:switch("Viewmodel", false),
    main_box:switch("Hitmarker", false),
    main_box:switch("Clantag", false),
    main_box:switch("Screen Indicator", false),
    main_box:switch("Manual Arrows", false),
    main_box:switch("Damage Indicator", false),
    main_box:switch("Velocity Warning", false),
}
local extra = {
    main_box:switch("Example", false),
}
local config = {
    main_box:input("Config Name", "Type Here"),
    main_box:list("Presets", {"Defensive", "Snappy", "Aggressive"}),
    main_box:button("Load", function() end),
    main_box:button("Save", function() end),
    main_box:button("Delete", function() end),
}
local main_pages = {home, rage, visual, extra, config}

-- Anti Aim
local aa_nav = pui.create("Anti Aim", "
aa_nav", 1)
local aa_list = aa_nav:list("
", {"Setup", "Builder", "Exploit"})
local aa_box = pui.create("Anti Aim", "
aa_box", 2)
local aa_pages = {
    { aa_box:switch("Setup", false) },
    { aa_box:switch("Builder", false) },
    { aa_box:switch("Exploit", false) },
}

-- Misc
local tab_misc = pui.create("Misc", "
misc", 2)

local function show_pages(pages, idx)
    for i, page in ipairs(pages) do
        for _, item in ipairs(page) do
            item:visibility(i == idx)
        end
    end
end

events.render:set(function()
    logo:animate()
    pui.sidebar(logo:get_animated_text(), "fire-flame-curved")
    show_pages(main_pages, main_list:get())
    show_pages(aa_pages, aa_list:get())
end)

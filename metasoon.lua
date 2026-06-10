local pui = require("neverlose/pui")
local gradient = require("neverlose/gradient")

local logo = gradient.text_animate("M E T A S O O N", -2, {
    color(0, 150, 255),
    color(0, 50, 120),
    color(0, 0, 0)
})

-- Main
local main_nav = pui.create("Main", "\nmain_nav", 1)
local main_list = main_nav:list("\n", {"Home", "Rage", "Visual", "Extra", "Config"})
local main_box = pui.create("Main", "\nmain_box", 2)
local main_pages = {
    main_box:switch("Home", false),
    main_box:switch("Rage", false),
    main_box:switch("Visual", false),
    main_box:switch("Extra", false),
    main_box:switch("Config", false),
}

-- Anti Aim
local aa_nav = pui.create("Anti Aim", "\naa_nav", 1)
local aa_list = aa_nav:list("\n", {"Setup", "Builder", "Exploit"})
local aa_box = pui.create("Anti Aim", "\naa_box", 2)
local aa_pages = {
    aa_box:switch("Setup", false),
    aa_box:switch("Builder", false),
    aa_box:switch("Exploit", false),
}

-- Misc
local tab_misc = pui.create("Misc", "\nmisc", 2)

local function show_page(pages, idx)
    for i, item in ipairs(pages) do
        item:visibility(i == idx)
    end
end

events.render:set(function()
    logo:animate()
    pui.sidebar(logo:get_animated_text(), "fire-flame-curved")
    show_page(main_pages, main_list:get())
    show_page(aa_pages, aa_list:get())
end)

local pui = require("neverlose/pui")
local gradient = require("neverlose/gradient")

local logo = gradient.text_animate("M E T A S O O N", -2, {
    color(0, 150, 255),
    color(0, 50, 120),
    color(0, 0, 0)
})

local tab_main = pui.create("METASOON", "Main", 2)
local tab_aa = pui.create("METASOON", "Anti Aim", 2)
local tab_misc = pui.create("METASOON", "Misc", 2)

local enabled_ref = tab_main:switch("Enabled", true)
local aa_enabled_ref = tab_aa:switch("Anti Aim", false)
local misc_enabled_ref = tab_misc:switch("Misc Feature", false)

events.render:set(function()
    logo:animate()
    pui.sidebar(logo:get_animated_text(), "fire-flame-curved")
end)

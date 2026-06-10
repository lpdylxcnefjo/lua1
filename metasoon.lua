-- METASOON
local pui = require("neverlose/pui")
local gradient = require("neverlose/gradient")

local logo = gradient.text_animate("M E T A S O O N", -2, {
    color(255, 50, 50),
    color(255, 150, 200),
    color(255, 255, 255)
})

-- UI
local tab = pui.create("METASOON", "Main", 2)
local enabled_ref = tab:switch("Enabled", true)

-- Render
events.render:set(function()
    logo:animate()
    pui.sidebar(logo:get_animated_text(), "fire-flame-curved")
end)

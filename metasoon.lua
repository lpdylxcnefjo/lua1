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
ui.sidebar("METASOON", "fire-flame-curved")

local enabled_ref = tab:switch("Enabled", true)
local pos_x_ref = tab:slider("Logo X (%)", 0, 100, 50)
local pos_y_ref = tab:slider("Logo Y (%)", 0, 100, 4)

-- Render
events.render:set(function()
    if not enabled_ref:get() then return end
    logo:animate()
    local screen = render.screen_size()
    local x = screen.x * (pos_x_ref:get() / 100)
    local y = screen.y * (pos_y_ref:get() / 100)
    render.text(4, vector(x, y), color(255, 255, 255), "cs", logo:get_animated_text())
end)

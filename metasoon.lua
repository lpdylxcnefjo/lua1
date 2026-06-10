-- METASOON
-- Имена элементов меню не парсят цветовые коды, поэтому радугу рисуем через render.text

local TAB_NAME = "METASOON"
local TAB_ICON = "fire-flame-curved"

local hsv_color = color()

local function rainbow_text(text, speed, spread)
    speed  = speed  or 1.0
    spread = spread or 0.05

    local time  = globals.realtime * speed
    local parts = {}

    for i = 1, #text do
        local char = text:sub(i, i)
        local hue  = (time + i * spread) % 1
        local hex  = hsv_color:as_hsv(hue, 1, 1, 1):to_hex():sub(1, 6)
        parts[#parts + 1] = "\a" .. hex .. char
    end

    return table.concat(parts)
end

-- UI
local group = ui.create(TAB_NAME, "Main")
ui.sidebar(TAB_NAME, TAB_ICON)

local logo_ref  = group:switch("Rainbow logo", true)
local speed_ref = group:slider("Animation speed", 1, 50, 12, 0.1)
local pos_x_ref = group:slider("Logo X (%)", 0, 100, 50)
local pos_y_ref = group:slider("Logo Y (%)", 0, 100, 4)

-- Render
events.render:set(function()
    if not logo_ref:get() then return end

    local speed  = speed_ref:get() * 0.1
    local screen = render.screen_size()
    local x = screen.x * (pos_x_ref:get() / 100)
    local y = screen.y * (pos_y_ref:get() / 100)

    render.text(4, vector(x, y), color(255, 255, 255, 255), "cs", rainbow_text(TAB_NAME, speed))
end)

events.shutdown:set(function()
    ui.sidebar(TAB_NAME, TAB_ICON)
end)

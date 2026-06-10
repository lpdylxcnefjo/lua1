-- METASOON
local pui = require("neverlose/pui")
local gradient = require("neverlose/gradient")

-- Переливающийся текст "METASOON" (белый -> красный -> розовый)
local logo_gradient = gradient.text_animate("M E T A S O O N", -2, {
    color(255, 50, 50),
    color(255, 150, 200),
    color(255, 255, 255)
})

-- Вкладка
local tab_main = pui.create("METASOON", "Main", 2)

-- UI
ui.sidebar("METASOON", "fire-flame-curved")

local label = tab_main:label(logo_gradient)

-- Настройки (заглушки, потом заполнишь)
local enabled_ref = tab_main:switch("Enabled", true)

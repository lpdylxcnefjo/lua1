--[[
    METASOON - анимированная (переливающаяся) вкладка для Neverlose
    --------------------------------------------------------------
    Что делает скрипт:
      * Создаёт вкладку "METASOON" в Lua-меню
      * Имя вкладки в сайдбаре переливается радугой (как в pui)
      * Внутри вкладки есть переливающийся заголовок + базовые настройки
        (вкл/выкл анимации и скорость), чтобы было от чего отталкиваться дальше.

    Цветовые коды текста Neverlose (как в pui):
      \aRRGGBB        - задать сплошной цвет для текста после кода
      \bRRGGBB\bRRGGBB[текст] - градиент
    Здесь радуга собирается посимвольно через \aRRGGBB, чтобы она плавно
    "ехала" по тексту каждый кадр.
--]]

-- Текст, который будет переливаться
local TAB_NAME   = "METASOON"
-- Иконка вкладки в сайдбаре (имена из FontAwesome v6, brand-иконки не поддерживаются)
local TAB_ICON   = "fire-flame-curved"

-- Один переиспользуемый объект цвета, чтобы не плодить мусор каждый кадр
local hsv_color = color()

--- Собирает строку с посимвольной радугой.
-- @param text string  исходный текст
-- @param speed number  скорость движения радуги
-- @param spread number  насколько сильно отличается оттенок между символами
-- @return string  текст с цветовыми кодами \aRRGGBB
local function rainbow_text(text, speed, spread)
    speed  = speed  or 1.0
    spread = spread or 0.03

    local time  = globals.realtime * speed
    local parts = {}

    for i = 1, #text do
        local char = text:sub(i, i)

        -- hue в диапазоне [0,1], сдвигается по времени и по позиции символа
        local hue = (time + i * spread) % 1

        -- HSV -> RGBA, берём первые 6 hex-символов (RRGGBB) для кода \a
        local hex = hsv_color:as_hsv(hue, 1, 1, 1):to_hex():sub(1, 6)

        parts[#parts + 1] = "\a" .. hex .. char
    end

    return table.concat(parts)
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------

-- Создаём вкладку "METASOON" с группой "Main" внутри Lua-меню
local group = ui.create(TAB_NAME, "Main")

-- Переливающийся заголовок-лейбл внутри вкладки
local title_label = group:label(TAB_NAME)

-- Переключатель анимации
local enabled_ref = group:switch("Rainbow animation", true)

-- Скорость переливания (отображается как 0.1 - 5.0)
local speed_ref = group:slider("Animation speed", 1, 50, 10, 0.1)
speed_ref:tooltip("Скорость движения радуги по тексту")

------------------------------------------------------------------------
-- Логика анимации
------------------------------------------------------------------------

events.render:set(function()
    local enabled = enabled_ref:get()
    local speed   = speed_ref:get() * 0.1 -- 1..50 -> 0.1..5.0

    if enabled then
        -- Имя вкладки в сайдбаре переливается радугой
        ui.sidebar(rainbow_text(TAB_NAME, speed), TAB_ICON)
        -- Заголовок внутри вкладки тоже переливается
        title_label:name(rainbow_text(TAB_NAME, speed))
    else
        -- Статичное имя, если анимация выключена
        ui.sidebar(TAB_NAME, TAB_ICON)
        title_label:name(TAB_NAME)
    end
end)

-- Вернём имя вкладки в обычный вид при выгрузке скрипта
events.shutdown:set(function()
    ui.sidebar(TAB_NAME, TAB_ICON)
end)

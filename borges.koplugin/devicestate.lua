-- Condiciones de lectura: bateria, carga, luz, modo nocturno, orientacion,
-- Wi-Fi y tipografia, tomadas SOLO en momentos en que el plugin ya corre
-- (abrir, cerrar, dormir, despertar, guardar ajustes y los avisos de
-- KOReader de luz, carga, re-render, rotacion y modo nocturno). Sin
-- temporizadores y nunca en el camino caliente de pasar pagina.
--
-- Ninguna muestra lleva texto del libro: solo numeros, banderas y el nombre
-- de la fuente tipografica.
local DeviceState = {}
DeviceState.__index = DeviceState

DeviceState.TRIGGERS = {
    "open", "close", "sleep", "wake", "save", "frontlight", "charging",
    "not_charging", "rerender", "rotation", "night_mode",
}
local KNOWN = {}
for _, t in ipairs(DeviceState.TRIGGERS) do KNOWN[t] = true end

-- Siempre se guardan: delimitan la bateria de un tramo de lectura.
local BRACKET = {
    open = true, close = true, sleep = true, wake = true, charging = true, not_charging = true,
}

DeviceState.MAX_SAMPLES = 200

-- Lista blanca: lo unico que puede salir del lector en una muestra.
DeviceState.FIELDS = {
    "at_ms", "trigger", "battery_pct", "charging", "frontlight_on", "frontlight_level",
    "frontlight_warmth", "night_mode", "rotation", "wifi_on", "font_face", "font_size",
    "line_spacing", "margins", "view_mode", "tz_offset_min",
}
-- Los que cuentan para decidir si una muestra repite la anterior.
local COMPARED = {
    "battery_pct", "charging", "frontlight_on", "frontlight_level", "frontlight_warmth",
    "night_mode", "rotation", "wifi_on", "font_face", "font_size", "line_spacing",
    "margins", "view_mode", "tz_offset_min",
}

function DeviceState.isTrigger(value)
    return KNOWN[value] == true
end

function DeviceState.new(deps)
    return setmetatable({ deps = deps or {}, samples = {}, last = nil }, DeviceState)
end

local function try(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function num(value)
    value = tonumber(value)
    if value == nil or value ~= value then return nil end
    return value
end

local function bool(value)
    if value == nil then return nil end
    return value == true
end

local function round(value)
    if value == nil then return nil end
    return math.floor(value + 0.5)
end

local function sameMargins(a, b)
    if a == nil or b == nil then return a == b end
    for i = 1, 4 do if a[i] ~= b[i] then return false end end
    return true
end

local function same(a, b)
    if not a or not b then return false end
    for _, key in ipairs(COMPARED) do
        if key == "margins" then
            if not sameMargins(a.margins, b.margins) then return false end
        elseif a[key] ~= b[key] then
            return false
        end
    end
    return true
end

function DeviceState:_read(trigger, ui)
    local deps = self.deps
    local Device, powerd = deps.Device, deps.powerd
    local settings, Screen, NetworkMgr = deps.G_reader_settings, deps.Screen, deps.NetworkMgr
    local clock = deps.os or os
    local s = { trigger = trigger }
    s.at_ms = try(function() return clock.time() * 1000 end)
    if powerd then
        s.battery_pct = num(try(function() return powerd:getCapacity() end))
        if BRACKET[trigger] then
            -- isCharging lee el hardware cada vez (generic/powerd.lua:270).
            s.charging = bool(try(function() return powerd:isCharging() end))
        end
        s.frontlight_on = bool(try(function() return powerd:isFrontlightOn() end))
        s.frontlight_level = num(try(function() return powerd:frontlightIntensity() end))
        if Device and try(function() return Device:hasNaturalLight() end) == true then
            s.frontlight_warmth = num(try(function() return powerd:frontlightWarmth() end))
        end
    end
    if s.charging == nil and not BRACKET[trigger] and self.last then
        -- Cada cambio de carga genera su propia muestra: lo ultimo medido vale.
        s.charging = self.last.charging
    end
    if settings then
        s.night_mode = bool(try(function() return settings:isTrue("night_mode") end))
    end
    if Screen then s.rotation = num(try(function() return Screen:getRotationMode() end)) end
    -- Ajustar la luz avisa en cada paso (generic/powerd.lua:222, :248): ahi no
    -- se pregunta por la red (en Kobo y Kindle lee sysfs y getifaddrs), vale lo
    -- ultimo medido.
    if trigger == "frontlight" and self.last then
        s.wifi_on = self.last.wifi_on
    elseif NetworkMgr then
        s.wifi_on = bool(try(function() return NetworkMgr:isConnected() end))
    end
    if ui then
        local conf = try(function() return ui.document.configurable end)
        if type(conf) == "table" then
            s.font_size = num(try(function() return conf.font_size end))
            s.line_spacing = num(try(function() return conf.line_spacing end))
            local margins = try(function()
                local h = conf.h_page_margins
                return { num(h[1]), num(conf.t_page_margin), num(h[2]), num(conf.b_page_margin) }
            end)
            if margins and (margins[1] or margins[2] or margins[3] or margins[4]) then
                s.margins = margins
            end
        end
        local face = try(function() return ui.font.font_face end)
        if type(face) == "string" then s.font_face = face:sub(1, 120) end
        local mode = try(function() return ui.view.view_mode end)
        if type(mode) == "string" then s.view_mode = mode:sub(1, 16) end
    end
    s.tz_offset_min = round(num(try(function()
        local now = clock.time()
        -- La hora UTC leida como local, con el horario de verano de AHORA: sin
        -- isdst, en verano daba el desfase estandar.
        local utc = clock.date("!*t", now)
        utc.isdst = clock.date("*t", now).isdst
        return clock.difftime(now, clock.time(utc)) / 60
    end)))
    return s
end

function DeviceState:_trim()
    local samples = self.samples
    while #samples > DeviceState.MAX_SAMPLES do
        local victim
        for i, s in ipairs(samples) do
            if s.trigger == "save" then victim = i; break end
        end
        if not victim then
            for i, s in ipairs(samples) do
                if not BRACKET[s.trigger] then victim = i; break end
            end
        end
        table.remove(samples, victim or 1)
    end
end

-- `book`: el libro abierto al tomar la muestra (no viaja en la muestra: con el
-- se arma el evento). Las claves que empiezan con "_" nunca salen del lector.
function DeviceState:sample(trigger, ui, book)
    if not KNOWN[trigger] then return nil end
    local s = self:_read(trigger, ui)
    if not BRACKET[trigger] and same(s, self.last) then return nil end
    -- Pasos seguidos de un mismo ajuste de luz son UNA muestra: queda el valor
    -- en el que se asento, con la hora del ultimo paso. Sin temporizador.
    local tail = self.samples[#self.samples]
    if trigger == "frontlight" and tail and tail == self.last and tail.trigger == "frontlight"
        and tail._book == book then
        for key in pairs(tail) do tail[key] = nil end
        for key, value in pairs(s) do tail[key] = value end
        tail._book = book
        return nil
    end
    s._book = book
    self.last = s
    table.insert(self.samples, s)
    self:_trim()
    return nil
end

function DeviceState:count()
    return #self.samples
end

--- La muestra como viaja: solo la lista blanca, sin las claves internas.
function DeviceState.wire(sample)
    local out = {}
    for _, key in ipairs(DeviceState.FIELDS) do
        if sample[key] ~= nil then out[key] = sample[key] end
    end
    return out
end

function DeviceState:drain()
    local out = self.samples
    self.samples = {}
    return out
end

return DeviceState

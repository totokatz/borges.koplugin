-- Reloj del ultimo toque y por que se durmio el lector, para cada tramo.
--
-- active_ms (Desvio 5 del plan F2): milisegundos desde que el tramo aparecio
-- hasta el ultimo evento de entrada observado antes de cerrarlo (toque,
-- tecla, boton, tapa). Si lo cerro un evento de entrada, es el tramo entero.
-- Es una cota inferior de presencia, NO atencion: lo plausible lo decide el
-- servidor. Todo se mide con el MISMO reloj que los tramos de F1 (main.lua
-- _readingClockMs): time.now() leido en el momento mas el standby del Kobo
-- (el standby entre paginas es tiempo real de lectura). No UIManager:getTime():
-- ese `_now` se fija ANTES de esperar la entrada, asi que dentro de un toque es
-- la hora del evento anterior. Un salto del reloj de pared no cambia nada.
--
-- Camino caliente: el gancho de entrada lee un reloj (clock_gettime por FFI,
-- sin E/S) y escribe tres numeros en memoria; nada de disco, red ni
-- temporizadores.
local Hooks = require("hooks")

local Attention = {}
Attention.__index = Attention

Attention.ENDED_BY = { "screen", "sleep_button", "sleep_cover", "sleep_idle", "sleep", "close", "unknown" }
local KNOWN = {}
for _, value in ipairs(Attention.ENDED_BY) do KNOWN[value] = true end

-- Cierres que son, ellos mismos, un evento de entrada de la persona.
local INPUT_ENDED = { screen = true, sleep_button = true, sleep_cover = true }

-- Kindle: POWERD_EVENT_SOURCES (kindle/device.lua:745-750).
local KINDLE_SOURCE = { [2] = "sleep_button", [4] = "sleep_cover" }

local SOURCE_FRESH_S = 5   -- el origen del sueno vale si llego hace <= 5 s
-- Un origen fresco que no es boton ni tapa lo decidio el sistema (powerd o
-- AutoSuspend por inactividad).
local BUTTON_TOUCH_S = 3   -- un toque <= 3 s antes de dormir es el boton
local IDLE_SLACK_S = 5     -- margen del temporizador de AutoSuspend

function Attention.isEndedBy(value)
    return KNOWN[value] == true
end

local function defaultTime()
    local ok, time = pcall(require, "ui/time")
    if ok then return time end
    return nil
end

local function toMs(deps, fts)
    local time = deps.time or defaultTime()
    if time and time.to_ms then return time.to_ms(fts) end
    return math.floor(fts / 1000 + 0.5)
end

local function toS(deps, fts)
    return toMs(deps, fts) / 1000
end

--- El reloj de atencion, en fts: el mismo que el de los tramos de F1.
-- `deps.clock` lo reemplaza en las pruebas.
function Attention.clock(deps)
    deps = deps or {}
    if deps.clock then return deps.clock() end
    local now
    local time = deps.time or defaultTime()
    if time and type(time.now) == "function" then
        local ok, value = pcall(time.now)
        if ok and type(value) == "number" then now = value end
    end
    if now == nil and deps.UIManager and deps.UIManager.getTime then now = deps.UIManager:getTime() end
    local standby = deps.Device and deps.Device.total_standby_time
    if type(standby) ~= "number" then standby = 0 end
    return (now or 0) + standby
end

-- La vuelta del bucle de UIManager: `_now` es fijo durante una vuelta, asi que
-- dice si dos cosas pasaron en el mismo despacho de entrada.
local function tickOf(deps)
    local UIManager = deps and deps.UIManager
    if UIManager and UIManager.getTime then return UIManager:getTime() end
    return nil
end

--- KOReader corre el gancho InputEvent antes de despachar CUALQUIER tanda de
-- entrada, tambien los eventos de sistema que llegan como entrada falsa
-- (`IntoSS` del Kindle, `Charging`, `NotCharging`: device/input.lua, event_map
-- 100xx). Quien sabe que lo de esta vuelta fue del sistema llama aca: si el
-- ultimo "toque" es de esta misma vuelta, vale el anterior.
function Attention.forgetSystemInput(shared, deps)
    if type(shared) ~= "table" or shared.last_input_tick == nil then return end
    if shared.last_input_tick == tickOf(deps) then
        shared.last_input_fts = shared.prev_input_fts
        shared.last_input_tick = nil
    end
end

-- Una vez por proceso: KOReader no destruye instancias viejas del plugin y
-- una funcion registrada dos veces contaria dos veces.
function Attention.installProcessHooks(shared, deps)
    if type(shared) ~= "table" or shared.attention_hooks then return end
    deps = deps or {}
    local UIManager = deps.UIManager
    if not (UIManager and UIManager.event_hook) then return end
    shared.attention_hooks = true
    -- Una funcion, no un widget: registerWidget pisa onCloseWidget.
    UIManager.event_hook:register("InputEvent", function()
        shared.prev_input_fts = shared.last_input_fts
        shared.last_input_fts = Attention.clock(deps)
        shared.last_input_tick = tickOf(deps)
    end)
    local Device = deps.Device
    if type(Device) == "table" and Device.intoScreenSaver ~= nil then
        Hooks.wrapModuleOnce(Device, "intoScreenSaver", function(_, source)
            -- En Kindle el aviso de sueno ES una entrada falsa (IntoSS,
            -- kindle/device.lua:871-874): no es un toque de la persona.
            Attention.forgetSystemInput(shared, deps)
            shared.sleep_source = { source = source, at_fts = Attention.clock(deps) }
        end)
    end
end

function Attention.new(shared, deps)
    return setmetatable({ shared = shared or {}, deps = deps or {}, t0 = nil }, Attention)
end

function Attention:openSpan(now_fts)
    self.t0 = now_fts
end

function Attention:isOpen()
    return self.t0 ~= nil
end

-- Lo mismo que closeSpan pero sin cerrar: para quien todavia no sabe si la
-- pantalla de verdad cambio (ReadingLog:onScreen puede decir que no).
function Attention:measure(now_fts, ended_by)
    if not KNOWN[ended_by] then ended_by = "unknown" end
    local t0 = self.t0 or now_fts
    local dwell = math.max(0, toMs(self.deps, now_fts - t0))
    local active
    if INPUT_ENDED[ended_by] then
        active = dwell
    else
        local last = self.shared.last_input_fts
        if type(last) ~= "number" then
            active = 0
        else
            active = math.max(0, math.min(dwell, toMs(self.deps, last - t0)))
        end
    end
    return { active_ms = active, dwell_ms = dwell, ended_by = ended_by }
end

function Attention:closeSpan(now_fts, ended_by)
    local result = self:measure(now_fts, ended_by)
    self.t0 = nil
    return result
end

-- Por que se va a dormir. Consume el origen que dejo el Kindle.
function Attention:sleepReason(now_fts, idle_timeout_s)
    local shared, deps = self.shared, self.deps
    local source = shared.sleep_source
    shared.sleep_source = nil
    if type(source) == "table" and type(source.at_fts) == "number"
        and toS(deps, now_fts - source.at_fts) <= SOURCE_FRESH_S then
        -- Boton o tapa; cualquier otro origen lo pidio el sistema por inactividad.
        return KINDLE_SOURCE[source.source] or "sleep_idle"
    end
    if deps.Device and deps.Device.is_cover_closed == true then
        return "sleep_cover"
    end
    local last = shared.last_input_fts
    local since = type(last) == "number" and toS(deps, now_fts - last) or nil
    if tonumber(idle_timeout_s) and idle_timeout_s > 0
        and (since == nil or since >= idle_timeout_s - IDLE_SLACK_S) then
        return "sleep_idle"
    end
    if since and since >= 0 and since <= BUTTON_TOUCH_S then
        return "sleep_button"
    end
    return "sleep"
end

return Attention

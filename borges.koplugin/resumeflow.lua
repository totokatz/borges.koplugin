-- ============================================================
-- C17 · Retomar la lectura donde la dejaste
--
-- Dos cosas que el lector vive como una sola: prender el Wi-Fi y que el libro
-- te diga dónde quedaste en el otro aparato.
--
-- Lo que fallaba. `onNetworkConnected` sólo vaciaba la cola: la reconexión
-- manual subía lo viejo y nunca preguntaba nada. El popup, cuando salía,
-- hablaba en técnico ("Precision: estimada por porcentaje") y se olvidaba de
-- todo al reiniciar, así que un "quedarme" se volvía a preguntar a la
-- siguiente reconexión. Dos eventos del mismo libro apilaban dos diálogos.
--
-- Acá viven las tres decisiones, sin widgets ni red, para poder probarlas:
--   · `planConnect` — al conectar se consulta primero y se sube después. La
--     cola vieja no puede ganarle a la posición que el otro lector ya dejó.
--   · `shouldOffer` — un diálogo visible a la vez, del libro abierto y de la
--     cuenta actual; lo ya resuelto no se vuelve a preguntar, pero una
--     posición nueva sí.
--   · `describe` — dos renglones legibles y el aviso de que el salto va para
--     atrás o es aproximado. Lo técnico queda en el detalle, no en la cara.
--
-- La fecha de lectura se compara sólo con relojes confiables. Un porcentaje
-- más alto o un envío posterior no indican una lectura más reciente. Cuando
-- la hora es incierta, se ofrecen las dos posiciones y decide la persona.
-- ============================================================

local _ = require("i18n")
local T = require("ffi/util").template

local ResumeFlow = {}
ResumeFlow.__index = ResumeFlow

-- PostgreSQL bigint sequences must be compared as decimal strings; tonumber
-- loses ordering above 2^53 on LuaJIT.
function ResumeFlow.sequenceBefore(left, right)
    left, right = tostring(left or ""), tostring(right or "")
    if not left:match("^%d+$") or not right:match("^%d+$") then return false end
    left, right = left:gsub("^0+", ""), right:gsub("^0+", "")
    if #left ~= #right then return #left < #right end
    return left < right
end

-- Motivos por los que NO se ofrece una posición. Son parte del contrato: los
-- usan los tests y el log, así que cambian de nombre sólo con la prueba.
ResumeFlow.NO_BOOK = "no_book"
ResumeFlow.OTHER_BOOK = "other_book"
ResumeFlow.OTHER_ACCOUNT = "other_account"
ResumeFlow.ALREADY_VISIBLE = "already_visible"
ResumeFlow.SAME_POSITION = "same_position"
ResumeFlow.ALREADY_RESOLVED = "already_resolved"
ResumeFlow.NO_LOCATOR = "no_locator"
ResumeFlow.OLDER_READING = "older_reading"

-- Pasos del flujo de conexión, en el único orden que sirve.
ResumeFlow.STEP_PULL = "pull"
ResumeFlow.STEP_DRAIN = "drain"

ResumeFlow.SKIP_OFFLINE = "offline"
ResumeFlow.SKIP_NO_SESSION = "no_session"
ResumeFlow.SKIP_DEBOUNCED = "debounced"
ResumeFlow.SKIP_RUNNING = "running"

-- Cuántos libros recuerdan su última decisión. El lector con cientos de
-- libros no tiene que arrastrar cientos de respuestas muertas.
ResumeFlow.MAX_BOOKS = 40

-- Umbral descriptivo para el texto del aviso; no suprime lecturas posteriores.
ResumeFlow.EQUIVALENT_PCT = 0.5

-- Debajo de esta distancia el salto es "una diferencia chica" y se dice así,
-- en vez de anunciar un viaje que no existe.
ResumeFlow.SMALL_JUMP_PCT = 2

-- Sólo estas precisiones de reloj habilitan mostrar una fecha. Con
-- `approximate` o `unknown` el lector vería una hora inventada.
local TRUSTED_TIME = { exact = true, anchored = true }

local function numberOrNil(value)
    local number = tonumber(value)
    if not number or number ~= number then return nil end
    return number
end

local function trim(value)
    if type(value) ~= "string" then return nil end
    local text = value:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text
end

-- Compare protocol UTC timestamps without device timezone/DST conversions.
function ResumeFlow.readingTime(position)
    if type(position) ~= "table" or not TRUSTED_TIME[position.time_precision] then return nil end
    local iso = trim(position.occurred_at or position.created_at)
    if not iso then return nil end
    local base, suffix = iso:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)(.*)$")
    if not base then return nil end
    local fraction = suffix:match("^%.(%d+)Z$") or suffix:match("^%.(%d+)%+00:00$")
    if not fraction and suffix ~= "Z" and suffix ~= "+00:00" then return nil end
    return base .. "." .. ((fraction or "") .. "000000000"):sub(1, 9)
end

function ResumeFlow.samePosition(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    local a, b = trim(left.xpointer), trim(right.xpointer)
    if a and b then return a == b end
    a, b = numberOrNil(left.percentage), numberOrNil(right.percentage)
    return a ~= nil and b ~= nil and math.abs(a - b) < 0.000001
end

--- Identidad estable de una posición propuesta.
--
-- Primero lo que el servidor numera —`event_id`, `server_sequence`—, que es lo
-- único que distingue dos escrituras sin depender de relojes. Recién si no
-- viene nada de eso se cae al localizador, redondeado: un porcentaje con
-- catorce decimales generaría una "posición nueva" en cada pull.
function ResumeFlow.fingerprint(position)
    if type(position) ~= "table" then return nil end
    local event_id = trim(position.event_id)
    if event_id then return "event:" .. event_id end
    local sequence = trim(position.server_sequence)
        or (numberOrNil(position.server_sequence) and tostring(position.server_sequence))
    if sequence then return "seq:" .. sequence end

    local parts = {}
    local stamp = trim(position.occurred_at or position.created_at)
    if stamp then table.insert(parts, "at=" .. stamp) end
    if position.device_id then table.insert(parts, "device=" .. tostring(position.device_id)) end
    local xpointer = trim(position.xpointer)
    if xpointer then table.insert(parts, "xp=" .. xpointer) end
    local page = numberOrNil(position.current_page or position.page)
    if page then table.insert(parts, "pg=" .. string.format("%d", page)) end
    local pct = numberOrNil(position.percentage)
    if pct then table.insert(parts, "pct=" .. string.format("%.2f", pct)) end
    if #parts == 0 then return nil end
    return "pos:" .. table.concat(parts, "&")
end

--- ¿Esta posición sirve para navegar? Sin ancla ni página ni porcentaje no hay
-- a dónde ir, y ofrecerla sería prometer un salto que después falla.
function ResumeFlow.hasLocator(position)
    if type(position) ~= "table" then return false end
    if trim(position.xpointer) then return true end
    if numberOrNil(position.current_page or position.page) then return true end
    local pct = numberOrNil(position.percentage)
    return pct ~= nil and pct >= 0
end

--- Porcentaje comparable de una posición, calculado con las páginas locales
-- cuando el porcentaje no vino. Sólo se usa para comparar, nunca para navegar.
local function comparablePercentage(position, total_pages)
    if type(position) ~= "table" then return nil end
    local pct = numberOrNil(position.percentage)
    if pct then return pct end
    local page = numberOrNil(position.current_page or position.page)
    local total = numberOrNil(total_pages or position.total_pages)
    if page and total and total > 0 then
        return (page / total) * 100
    end
    return nil
end

ResumeFlow.comparablePercentage = comparablePercentage

--- El plan de una conexión: qué correr y en qué orden.
--
-- Consultar antes de subir no es una preferencia de estilo. Si primero se
-- vacía la cola, el servidor recibe la posición vieja de este lector, la marca
-- como la última escritura y la posición del otro aparato deja de ofrecerse.
-- Por eso `pull` va primero y `drain` después, y por eso un pull que falla
-- cancela el drain en vez de "aprovechar que hay red".
--
-- @param state table {connected, session, book_open, running,
--   last_sync_at, now, min_interval, force}
-- @return table {steps = {...}, reason = string|nil}
function ResumeFlow.planConnect(state)
    state = state or {}
    if state.running == true then
        return { steps = {}, reason = ResumeFlow.SKIP_RUNNING }
    end
    if not state.connected then
        return { steps = {}, reason = ResumeFlow.SKIP_OFFLINE }
    end
    if not state.session then
        return { steps = {}, reason = ResumeFlow.SKIP_NO_SESSION }
    end

    local min_interval = numberOrNil(state.min_interval) or 0
    local last = numberOrNil(state.last_sync_at)
    local now = numberOrNil(state.now) or 0
    if state.force ~= true and last and min_interval > 0
        and (now - last) < min_interval then
        return { steps = {}, reason = ResumeFlow.SKIP_DEBOUNCED }
    end

    local steps = {}
    -- Sin libro abierto no hay posición que preguntar, pero la cola igual se
    -- vacía: es lo que el lector espera al prender el Wi-Fi en la biblioteca.
    -- Retomar una lectura es una decisión del lector, independiente del ajuste
    -- de sincronización automática. Omitirla deja el progreso retenido sin aviso.
    if state.book_open then
        table.insert(steps, ResumeFlow.STEP_PULL)
    end
    table.insert(steps, ResumeFlow.STEP_DRAIN)
    return { steps = steps, reason = nil }
end

-- ------------------------------------------------------------
-- La memoria de lo ya respondido
-- ------------------------------------------------------------

--- @param options table {decisions, on_change, now}
function ResumeFlow:new(options)
    options = options or {}
    return setmetatable({
        decisions = type(options.decisions) == "table" and options.decisions or {},
        on_change = options.on_change,
        now = options.now or os.time,
        visible = nil,
    }, self)
end

function ResumeFlow:getDecisions()
    return self.decisions
end

local function countKeys(map)
    local total = 0
    for _ in pairs(map) do total = total + 1 end
    return total
end

local function dropOldest(map)
    local oldest_key, oldest_at
    for key, entry in pairs(map) do
        local at = numberOrNil(entry and entry.at) or 0
        if oldest_at == nil or at < oldest_at then
            oldest_key, oldest_at = key, at
        end
    end
    if oldest_key then map[oldest_key] = nil end
end

function ResumeFlow:_changed()
    if self.on_change then self.on_change(self.decisions) end
end

--- Anotar qué se respondió a una posición concreta.
-- @param action string "accept" | "dismiss"
function ResumeFlow:remember(book_hash, position, action, local_device_id, local_reading_at)
    if type(book_hash) ~= "string" or book_hash == "" then return nil end
    local fingerprint = ResumeFlow.fingerprint(position)
    if not fingerprint then return nil end
    local entry = {
        fingerprint = fingerprint,
        action = action == "accept" and "accept" or "dismiss",
        percentage = comparablePercentage(position),
        at = self.now(),
        local_device_id = local_device_id,
        local_reading_at = local_reading_at,
    }
    if self.decisions[book_hash] == nil
        and countKeys(self.decisions) >= ResumeFlow.MAX_BOOKS then
        dropOldest(self.decisions)
    end
    self.decisions[book_hash] = entry
    self:_changed()
    return entry
end

function ResumeFlow:hasLocalChoice(book_hash, position, device_id)
    local decision = self:getDecision(book_hash)
    return decision ~= nil and decision.local_device_id == device_id
        and decision.local_reading_at ~= nil
        and decision.fingerprint == ResumeFlow.fingerprint(position)
end

function ResumeFlow:getDecision(book_hash)
    if type(book_hash) ~= "string" then return nil end
    return self.decisions[book_hash]
end

function ResumeFlow:forget(book_hash)
    if book_hash == nil then
        self.decisions = {}
        self:_changed()
        return
    end
    if self.decisions[book_hash] == nil then return end
    self.decisions[book_hash] = nil
    self:_changed()
end

--- ¿Ya se respondió por esta misma posición?
--
-- La respuesta pertenece a una actualización exacta. Una lectura posterior
-- puede volver al mismo lugar; no se suprime por tener el mismo porcentaje.
function ResumeFlow:isResolved(book_hash, position)
    local decision = self:getDecision(book_hash)
    if not decision then return false end
    local fingerprint = ResumeFlow.fingerprint(position)
    if fingerprint and decision.fingerprint == fingerprint then return true end

    return false -- A different event can revisit the same location later.
end

-- ------------------------------------------------------------
-- La compuerta: un diálogo por vez
-- ------------------------------------------------------------

function ResumeFlow:isVisible()
    return self.visible ~= nil
end

function ResumeFlow:getVisible()
    return self.visible
end

--- Marcar que hay un diálogo en pantalla. Devuelve false si ya había otro.
function ResumeFlow:markVisible(book_hash, position)
    if self.visible ~= nil then return false end
    self.visible = {
        book_hash = book_hash,
        fingerprint = ResumeFlow.fingerprint(position),
    }
    return true
end

function ResumeFlow:clearVisible()
    self.visible = nil
end

--- ¿Corresponde ofrecer esta posición ahora mismo?
--
-- @param context table {book_hash, open_book_hash, account_scope,
--   current_account, remote, local_position, total_pages}
-- @return boolean, string|nil motivo cuando la respuesta es no
function ResumeFlow:shouldOffer(context)
    context = context or {}
    local book_hash = context.book_hash
    if type(book_hash) ~= "string" or book_hash == "" then
        return false, ResumeFlow.NO_BOOK
    end
    -- El libro pudo cambiar entre que el evento llegó y que se va a mostrar.
    -- Un popup de otro libro es peor que no avisar nada.
    if type(context.open_book_hash) ~= "string" or context.open_book_hash == "" then
        return false, ResumeFlow.NO_BOOK
    end
    if context.open_book_hash ~= book_hash then
        return false, ResumeFlow.OTHER_BOOK
    end
    -- Lo mismo con la cuenta: una sugerencia emitida para el dueño anterior no
    -- se le muestra a quien entró después.
    if context.account_scope ~= nil and context.current_account ~= nil
        and context.account_scope ~= context.current_account then
        return false, ResumeFlow.OTHER_ACCOUNT
    end
    if not ResumeFlow.hasLocator(context.remote) then
        return false, ResumeFlow.NO_LOCATOR
    end
    if self:isVisible() then
        return false, ResumeFlow.ALREADY_VISIBLE
    end

    if not context.last_reading_elsewhere and ResumeFlow.samePosition(context.remote, context.local_position) then
        return false, ResumeFlow.SAME_POSITION
    end

    local remote_time = ResumeFlow.readingTime(context.remote)
    local local_time = ResumeFlow.readingTime(context.local_position)
    -- A checked last reading on another device always asks, even at the
    -- same position or behind a local timestamp recorded while connecting.
    if not context.last_reading_elsewhere and remote_time and local_time and remote_time <= local_time then
        return false, ResumeFlow.OLDER_READING
    end

    if not context.last_reading_elsewhere and self:isResolved(book_hash, context.remote) then
        return false, ResumeFlow.ALREADY_RESOLVED
    end
    return true
end

-- ------------------------------------------------------------
-- Lo que se lee en pantalla
-- ------------------------------------------------------------

local function formatPercentage(pct)
    if pct == nil then return nil end
    local clamped = math.max(0, math.min(100, pct))
    return T(_("%1%"), string.format("%.0f", clamped))
end

--- Un renglón legible: capítulo si lo hay, si no página, si no porcentaje.
-- Nunca el xpointer, nunca el id del evento: eso vive en el detalle.
local function positionLine(position, total_pages)
    if type(position) ~= "table" then return _("unknown position") end
    local parts = {}
    local chapter = trim(position.chapter_title or position.chapter)
    if chapter then table.insert(parts, chapter) end

    local page = numberOrNil(position.current_page or position.page)
    local total = numberOrNil(total_pages or position.total_pages)
    if page then
        if total and total > 0 then
            table.insert(parts, T(_("p. %1 of %2"),
                string.format("%d", page), string.format("%d", total)))
        else
            table.insert(parts, T(_("p. %1"), string.format("%d", page)))
        end
    end

    if #parts == 0 then
        local pct = formatPercentage(comparablePercentage(position, total_pages))
        if pct then return pct end
        return _("unknown position")
    end
    local pct = formatPercentage(comparablePercentage(position, total_pages))
    if pct and page then table.insert(parts, pct) end
    return table.concat(parts, " · ")
end

ResumeFlow.positionLine = positionLine

--- La fecha sólo se muestra cuando el reloj de origen es confiable. Un lector
-- que estuvo un mes sin batería informa una hora que no pasó.
function ResumeFlow.trustedTimestamp(position, format_time)
    if type(position) ~= "table" then return nil end
    local precision = position.time_precision or position.precision
    if type(precision) ~= "string" or not TRUSTED_TIME[precision:lower()] then
        return nil
    end
    local iso = trim(position.occurred_at or position.created_at)
    if not iso then return nil end
    if type(format_time) ~= "function" then return nil end
    return trim(format_time(iso))
end

--- Nombre presentable del otro lector. Un id técnico no es un nombre: si no
-- hay nada legible, se dice "otro dispositivo" y listo.
function ResumeFlow.sourceName(source)
    if type(source) == "string" then
        local name = trim(source)
        if name == "web" or (name and name:match("^web:")) then return _("the web") end
        if name and not name:match("^[0-9a-fA-F%-]+$") then return name end
        return _("another device")
    end
    if type(source) ~= "table" then return _("another device") end
    if source.platform == "web" then return _("the web") end
    local name = trim(source.name)
    if name then return name end
    local platform = trim(source.platform)
    if platform then return platform end
    return _("another device")
end

--- El texto completo del diálogo.
--
-- @param context table {book_title, remote, local_position, total_pages,
--   source, format_time, approximate}
-- @return table {title, text, detail, ok_text, cancel_text, warning}
function ResumeFlow.describe(context)
    context = context or {}
    local total = numberOrNil(context.total_pages)
    if total and total <= 0 then total = nil end
    local source_name = ResumeFlow.sourceName(context.source)

    local lines = {}
    local title = trim(context.book_title)
    if title then table.insert(lines, title) end
    table.insert(lines, "")
    table.insert(lines, T(_("On this reader: %1"),
        positionLine(context.local_position, total)))

    local remote_line = positionLine(context.remote, total)
    local stamp = ResumeFlow.trustedTimestamp(context.remote, context.format_time)
    if stamp then
        remote_line = remote_line .. " · " .. stamp
    end
    table.insert(lines, T(_("On %1: %2"), source_name, remote_line))

    -- Los dos avisos que cambian la decisión: que el salto va para atrás y que
    -- la ubicación es aproximada. Van juntos y antes de los botones.
    local warnings = {}
    local remote_pct = comparablePercentage(context.remote, total)
    local local_pct = comparablePercentage(context.local_position, total)
    local backwards = false
    if remote_pct ~= nil and local_pct ~= nil then
        local delta = remote_pct - local_pct
        if delta < -ResumeFlow.EQUIVALENT_PCT then
            backwards = true
            table.insert(warnings, _("Going there takes you backwards in the book."))
        elseif math.abs(delta) <= ResumeFlow.SMALL_JUMP_PCT then
            table.insert(warnings, _("The two positions are close to each other."))
        end
    end

    local approximate = context.approximate
    if approximate == nil then
        approximate = not trim(type(context.remote) == "table" and context.remote.xpointer or nil)
    end
    if approximate then
        table.insert(warnings, _("The location is approximate: it may land a few lines earlier or later."))
    end

    if #warnings > 0 then
        table.insert(lines, "")
        for _index, warning in ipairs(warnings) do
            table.insert(lines, warning)
        end
    end

    return {
        title = _("Where do you want to keep reading?"),
        text = table.concat(lines, "\n"),
        detail = ResumeFlow.describeDetail(context),
        ok_text = _("Go to that position"),
        cancel_text = _("Stay here"),
        backwards = backwards,
        approximate = approximate == true,
        source_name = source_name,
    }
end

--- El detalle técnico, sólo para quien lo abre a propósito. Acá sí van los
-- números, pero tampoco el xpointer ni el JSON: "hay un ancla exacta" le dice
-- al lector lo mismo sin pedirle que lea un DOM.
function ResumeFlow.describeDetail(context)
    context = context or {}
    local total = numberOrNil(context.total_pages)
    if total and total <= 0 then total = nil end
    local lines = {}

    table.insert(lines, T(_("This reader: %1"),
        positionLine(context.local_position, total)))
    table.insert(lines, T(_("%1: %2"),
        ResumeFlow.sourceName(context.source),
        positionLine(context.remote, total)))

    local remote = type(context.remote) == "table" and context.remote or {}
    if trim(remote.xpointer) then
        table.insert(lines, _("Book anchor: exact"))
    else
        table.insert(lines, _("Book anchor: missing, estimated from the percentage"))
    end

    local stamp = ResumeFlow.trustedTimestamp(remote, context.format_time)
    if stamp then
        table.insert(lines, T(_("Saved: %1"), stamp))
    else
        table.insert(lines, _("Saved: no reliable time"))
    end

    local others = context.others
    if type(others) == "table" and #others > 0 then
        table.insert(lines, "")
        table.insert(lines, _("Other saved positions:"))
        for _index, other in ipairs(others) do
            table.insert(lines, "· " .. T(_("%1: %2"),
                ResumeFlow.sourceName(other.source or other),
                positionLine(other, total)))
        end
    end
    return table.concat(lines, "\n")
end

return ResumeFlow

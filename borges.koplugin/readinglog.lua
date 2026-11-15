-- ReadingLog: el registro en memoria de lo que estuvo a la vista.
--
-- Un "tramo" es una pantalla: desde que aparece hasta que la reemplaza otra
-- (o se cierra el libro, o el lector se suspende). Guarda donde empieza
-- (XPointer), cuando aparecio y cuantos milisegundos reales estuvo. El fin, las
-- palabras y el porcentaje los completa main.lua DESPUES del pintado (resolve),
-- nunca en el camino caliente.
--
-- Todo vive en tablas Lua: este modulo no toca disco, red ni temporizadores.
-- Los tramos cerrados salen a la cola solo en las escrituras que el plugin ya
-- hace (drain + chunk, ver main.lua _enqueueReadingSpans).

local ReadingLog = {}
ReadingLog.__index = ReadingLog

-- Regla de "lectura plausible" para el ritmo local del pie de pagina.
-- DUPLICADA a proposito de shared/readingSpanRules.js (la fuente de verdad del
-- servidor): si cambia alla, cambia aca.
ReadingLog.PACE = {
    min_wpm = 50,
    max_wpm = 1500,
    min_words = 20,
    max_dwell_ms = 10 * 60 * 1000,
}

-- Con menos que esto leido de forma plausible, la velocidad de un libro todavia
-- no es suya (MIN_BOOK_PACE_WORDS de shared/readingSpanRules.js).
ReadingLog.MIN_BOOK_PACE_WORDS = 1500

-- En vista continua, más palabras que esto entre dos posiciones de reposo es
-- un salto (índice, búsqueda), no lectura.
ReadingLog.SCROLL_JUMP_WORDS = 2500

-- Campos propios de F1: annotate() y close() no los pisan.
local OWN = {
    xp_start = true, xp_end = true, page = true, page_count = true,
    visible_pages = true, view_mode = true, started_mono_ms = true,
    started_wall_ms = true, dwell_ms = true, words = true, chars = true,
    percent_start = true, percent_end = true, toc_index = true, resolved = true,
}

-- Lo que viaja por tramo, en este orden de interes.
local WIRE = {
    "xp_start", "xp_end", "dwell_ms", "words", "chars", "percent_start",
    "percent_end", "page", "visible_pages", "toc_index",
}

-- Topes del servidor (server/lib/readingSpanReplication.js): un valor fuera de
-- rango haria rechazar el evento entero, asi que se recorta o se omite aca.
ReadingLog.LIMITS = {
    max_dwell_ms = 6 * 60 * 60 * 1000,
    max_offset_ms = 6 * 24 * 60 * 60 * 1000, -- el servidor acepta 7 dias por evento
    max_xpointer = 1024,
    max_words = 20000,
    max_chars = 200000,
}

local function isScalar(value)
    local t = type(value)
    return t == "string" or t == "number" or t == "boolean"
end

function ReadingLog:new(opts)
    opts = opts or {}
    local log = setmetatable({}, self)
    log.clock_ms = opts.clock_ms or function() return 0 end
    log.wall_ms = opts.wall_ms or function() return 0 end
    log.max_spans = opts.max_spans or 600
    log.cache_size = opts.cache_size or 512
    log.scroll_settle_ms = opts.scroll_settle_ms or 400
    log.closed = {}
    log.open = nil
    log.dropped = 0
    log.cache = {}
    log.cache_keys = {}
    log.cache_head = 1
    log.totals = { words = 0, ms = 0, screens = 0 }
    return log
end

local function screenKey(info)
    if info.xp_start ~= nil then return "x:" .. tostring(info.xp_start) end
    return "p:" .. tostring(info.page)
end

local function isPlausible(words, ms)
    local rule = ReadingLog.PACE
    if type(words) ~= "number" or type(ms) ~= "number" then return false end
    if words < rule.min_words or ms <= 0 or ms > rule.max_dwell_ms then return false end
    local wpm = words * 60000 / ms
    return wpm >= rule.min_wpm and wpm <= rule.max_wpm
end

-- Suma el tramo al ritmo local una sola vez, cuando ya se sabe su duracion
-- (cerrado) y sus palabras (resuelto).
function ReadingLog:_account(span)
    if span._paced or not span.resolved or span.dwell_ms == nil then return end
    span._paced = true
    if isPlausible(span.words, span.dwell_ms) then
        self.totals.words = self.totals.words + span.words
        self.totals.ms = self.totals.ms + span.dwell_ms
        self.totals.screens = self.totals.screens + 1
    end
end

local function mergeScalars(span, fields)
    if type(fields) ~= "table" then return end
    for key, value in pairs(fields) do
        if type(key) == "string" and not OWN[key] and key:sub(1, 1) ~= "_" and isScalar(value) then
            span[key] = value
        end
    end
end

function ReadingLog:close(fields, now_ms)
    local span = self.open
    if not span then return nil end
    self.open = nil
    local elapsed = (now_ms or self.clock_ms()) - span.started_mono_ms
    if elapsed < 0 then elapsed = 0 end
    if elapsed > ReadingLog.LIMITS.max_dwell_ms then elapsed = ReadingLog.LIMITS.max_dwell_ms end
    span.dwell_ms = math.floor(elapsed + 0.5)
    mergeScalars(span, fields)
    if #self.closed >= self.max_spans then
        -- Red de seguridad de memoria: lo viejo ya esta contado, lo nuevo se pierde
        -- y se avisa en el proximo evento como `dropped`.
        self.dropped = self.dropped + 1
        return span
    end
    table.insert(self.closed, span)
    self:_account(span)
    return span
end

-- opts.now_ms / opts.wall_ms: el instante en que la pantalla aparecio, si
-- quien llama lo tomo antes (en el aviso de KOReader) y registra despues.
function ReadingLog:onScreen(info, opts)
    if type(info) ~= "table" then return nil end
    opts = opts or {}
    local open = self.open
    local view_mode = info.view_mode or "page"
    local now_ms = opts.now_ms or self.clock_ms()
    if open and not opts.force then
        if open.view_mode == view_mode and open._key == screenKey(info) then
            return nil
        end
        -- Vista continua: un paso de desplazamiento recien empezado no es una
        -- pantalla nueva; el tramo se corre y conserva su comienzo.
        if view_mode == "scroll" and open.view_mode == "scroll"
            and (now_ms - open.started_mono_ms) < self.scroll_settle_ms then
            open.xp_start = info.xp_start
            open.page = info.page
            open.page_count = info.page_count
            open.visible_pages = info.visible_pages
            open._key = screenKey(info)
            open.resolved = nil
            open.xp_end, open.words, open.chars = nil, nil, nil
            open.percent_start, open.percent_end, open.toc_index = nil, nil, nil
            return open
        end
    end
    if open then self:close(opts.close_fields, now_ms) end
    local span = {
        xp_start = info.xp_start,
        page = info.page,
        page_count = info.page_count,
        visible_pages = info.visible_pages,
        view_mode = view_mode,
        started_mono_ms = now_ms,
        started_wall_ms = opts.wall_ms or self.wall_ms(),
        _key = screenKey(info),
    }
    self.open = span
    return span
end

function ReadingLog:annotate(fields)
    local span = self.open
    if not span or type(fields) ~= "table" then return false end
    for _, value in pairs(fields) do
        if not isScalar(value) then return false end
    end
    mergeScalars(span, fields)
    return true
end

function ReadingLog:unresolved(limit)
    limit = limit or math.huge
    local out = {}
    for _, span in ipairs(self.closed) do
        if #out >= limit then return out end
        if not span.resolved then out[#out + 1] = span end
    end
    if self.open and not self.open.resolved and #out < limit then
        out[#out + 1] = self.open
    end
    return out
end

function ReadingLog:resolve(span, fields)
    if type(span) ~= "table" then return end
    fields = fields or {}
    span.xp_end = fields.xp_end
    span.words = fields.words
    span.chars = fields.chars
    span.percent_start = fields.percent_start
    span.percent_end = fields.percent_end
    span.toc_index = fields.toc_index
    span.resolved = true
    self:_account(span)
    self:_cover(span)
end

-- Cobertura del libro: tramos de [0, 1] ya contados, sin solapes, y las
-- palabras que corresponden a lo cubierto. Con eso sale la densidad del libro
-- (palabras por fraccion) cuando el servidor no mando el total del EPUB.
function ReadingLog:_cover(span)
    local from, to, words = span.percent_start, span.percent_end, span.words
    if type(from) ~= "number" or type(to) ~= "number" or type(words) ~= "number" then return end
    if to <= from or words <= 0 then return end
    self.coverage = self.coverage or {}
    local added = to - from
    local merged = { from, to }
    local rest = {}
    for _, range in ipairs(self.coverage) do
        if range[2] < merged[1] or range[1] > merged[2] then
            table.insert(rest, range)
        else
            local overlap = math.min(range[2], to) - math.max(range[1], from)
            if overlap > 0 then added = added - overlap end
            merged[1] = math.min(merged[1], range[1])
            merged[2] = math.max(merged[2], range[2])
        end
    end
    table.insert(rest, merged)
    table.sort(rest, function(a, b) return a[1] < b[1] end)
    self.coverage = rest
    if added > 0 then
        self.covered = (self.covered or 0) + added
        self.covered_words = (self.covered_words or 0) + words * (added / (to - from))
    end
end

--- Palabras por fraccion del libro segun lo ya contado, y cuanto se cubrio.
function ReadingLog:density()
    local covered = self.covered or 0
    if covered <= 0 then return nil, 0 end
    return (self.covered_words or 0) / covered, covered
end

local function cacheKey(xp0, xp1)
    return tostring(xp0) .. "\0" .. tostring(xp1)
end

function ReadingLog:cachedCount(xp0, xp1)
    local hit = self.cache[cacheKey(xp0, xp1)]
    if not hit then return nil, nil end
    return hit[1], hit[2]
end

function ReadingLog:rememberCount(xp0, xp1, words, chars)
    local key = cacheKey(xp0, xp1)
    if self.cache[key] then
        self.cache[key] = { words, chars }
        return
    end
    self.cache[key] = { words, chars }
    table.insert(self.cache_keys, key)
    while (#self.cache_keys - self.cache_head + 1) > self.cache_size do
        local old = self.cache_keys[self.cache_head]
        self.cache_keys[self.cache_head] = nil
        self.cache_head = self.cache_head + 1
        self.cache[old] = nil
    end
    -- Compactar la cola FIFO de vez en cuando para que no crezca el indice.
    if self.cache_head > 1024 then
        local keys = {}
        for i = self.cache_head, #self.cache_keys do keys[#keys + 1] = self.cache_keys[i] end
        self.cache_keys, self.cache_head = keys, 1
    end
end

function ReadingLog:drain()
    local rows = self.closed
    self.closed = {}
    return rows
end

function ReadingLog:count()
    return #self.closed
end

function ReadingLog:pace()
    return { words = self.totals.words, ms = self.totals.ms, screens = self.totals.screens }
end

-- Un tramo como viaja en el evento. `started_at_ms` es relativo a base_wall_ms
-- (ver "Desvios del contrato" del plan: un epoch en ms no viaja bien como
-- numero de Lua). xp_end se omite cuando el tramo siguiente empieza ahi.
function ReadingLog.wireSpan(row, base_wall_ms, next_row)
    local wire = {}
    for _, key in ipairs(WIRE) do
        if row[key] ~= nil then wire[key] = row[key] end
    end
    local limits = ReadingLog.LIMITS
    if type(wire.xp_start) == "string" and #wire.xp_start > limits.max_xpointer then wire.xp_start = nil end
    if type(wire.xp_end) == "string" and #wire.xp_end > limits.max_xpointer then wire.xp_end = nil end
    if type(wire.words) == "number" and (wire.words < 0 or wire.words > limits.max_words) then wire.words = nil end
    if type(wire.chars) == "number" and (wire.chars < 0 or wire.chars > limits.max_chars) then wire.chars = nil end
    if type(wire.percent_start) == "number" and type(wire.percent_end) == "number"
        and wire.percent_end < wire.percent_start then
        wire.percent_end = wire.percent_start
    end
    local started = (row.started_wall_ms or base_wall_ms or 0) - (base_wall_ms or 0)
    if started < 0 then started = 0 end
    wire.started_at_ms = math.floor(started + 0.5)
    if type(wire.dwell_ms) == "number" then wire.dwell_ms = math.floor(wire.dwell_ms + 0.5) end
    if next_row and row.xp_end ~= nil and next_row.xp_start == row.xp_end then
        wire.xp_end = nil
    end
    for key, value in pairs(row) do
        if type(key) == "string" and not OWN[key] and key:sub(1, 1) ~= "_" and isScalar(value) then
            wire[key] = value
        end
    end
    return wire
end

-- Parte los tramos en tandas de a lo sumo max_rows y max_bytes (medido como
-- {"spans":[...]} con `encode`). Cada tanda es un evento que se reconstruye
-- solo: su base es el primer tramo y el encadenado de xp_end no cruza tandas.
-- Devuelve las tandas y, en paralelo, la base (wall ms) de cada una.
function ReadingLog.chunk(rows, base_wall_ms, max_rows, max_bytes, encode)
    max_rows = max_rows or 100
    max_bytes = max_bytes or 28 * 1024
    local chunks, bases, skipped = {}, {}, 0
    local wrapper = #encode({ spans = { 0 } }) - 1 -- {"spans":[]} sin el elemento
    local current, sizes, base, total
    local current_rows

    local function start(row)
        current, sizes, current_rows = {}, {}, {}
        base = row.started_wall_ms or base_wall_ms or 0
        total = wrapper
    end
    local function finish()
        if current and #current > 0 then
            chunks[#chunks + 1] = current
            bases[#bases + 1] = base
        end
        current = nil
    end

    for _, row in ipairs(rows) do
        if not current then start(row) end
        local n = #current
        local wire = ReadingLog.wireSpan(row, base, nil)
        local size = #encode(wire)
        local prev_wire, prev_size
        if n > 0 then
            prev_wire = ReadingLog.wireSpan(current_rows[n], base, row)
            prev_size = #encode(prev_wire)
        end
        local new_total = total + size + (n > 0 and 1 or 0) - (n > 0 and (sizes[n] - prev_size) or 0)
        local too_late = ((row.started_wall_ms or base) - base) > ReadingLog.LIMITS.max_offset_ms
        if n > 0 and (n + 1 > max_rows or new_total > max_bytes or too_late) then
            finish()
            start(row)
            wire = ReadingLog.wireSpan(row, base, nil)
            size = #encode(wire)
            n = 0
            new_total = total + size
        end
        if n == 0 and new_total > max_bytes then
            -- Un tramo que solo no entra (XPointer absurdo): no se manda, pero
            -- se cuenta (viaja como `dropped`), nunca se pierde en silencio.
            current = nil
            skipped = skipped + 1
        else
            if n > 0 then
                current[n] = prev_wire
                sizes[n] = prev_size
            end
            current[n + 1] = wire
            sizes[n + 1] = size
            current_rows[n + 1] = row
            total = new_total
        end
    end
    finish()
    return chunks, bases, skipped
end

-- Lo que puede ocupar el encabezado de capítulos de una tanda. Con muchos
-- capítulos distintos (una antología hojeada) los títulos se recortan y, si ni
-- así entran, se mandan sin títulos: los tramos nunca se descartan por esto.
ReadingLog.CHAPTERS_BYTES = 4096

function ReadingLog.fitChapters(chapters, max_bytes, encode)
    if type(chapters) ~= "table" or next(chapters) == nil then return nil end
    max_bytes = max_bytes or ReadingLog.CHAPTERS_BYTES
    if #encode(chapters) <= max_bytes then return chapters end
    local clipped = {}
    for key, chapter in pairs(chapters) do
        clipped[key] = { title = ReadingLog.utf8Clip(chapter.title, 40), depth = chapter.depth }
    end
    if #encode(clipped) <= max_bytes then return clipped end
    return nil
end

-- Tope de cada evento de tramos: el servidor rechaza mas de 32 KiB por
-- payload y la cola usa 28 KiB, como statsync.lua (enmienda 3.3).
ReadingLog.EVENT_BYTES = 28 * 1024
ReadingLog.EVENT_ROWS = 100

--- Recorta a `max_bytes` sin partir un caracter UTF-8. nil si no hay texto.
function ReadingLog.utf8Clip(text, max_bytes)
    if type(text) ~= "string" or text == "" then return nil end
    if #text <= max_bytes then return text end
    local stop = max_bytes
    while stop > 0 do
        local byte = text:byte(stop + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then break end
        stop = stop - 1
    end
    return text:sub(1, stop)
end

--- RFC 3339 con milisegundos, en UTC.
function ReadingLog.isoMs(wall_ms)
    -- Sin multiplicar enteros grandes: en Lua 5.3 de 32 bits desbordarian.
    local seconds = math.floor(wall_ms / 1000)
    local ms = math.floor(wall_ms % 1000)
    return os.date("!%Y-%m-%dT%H:%M:%S", seconds) .. string.format(".%03dZ", ms)
end

--- Minutos al este de UTC del reloj del lector, con horario de verano.
function ReadingLog.tzOffsetMinutes()
    local now = os.time()
    local utc = os.date("!*t", now)
    local here = os.date("*t", now)
    utc.isdst = here.isdst
    local offset = math.floor(os.difftime(now, os.time(utc)) / 60 + 0.5)
    if offset < -840 or offset > 840 then return nil end
    return offset
end

return ReadingLog

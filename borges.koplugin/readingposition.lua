-- ============================================================
-- C07 · El punto de retorno
--
-- Saltar a la posición que dejó otro dispositivo es útil justo cuando da
-- miedo: si la otra punta estaba desactualizada, el salto te tira lejos de
-- donde estabas y KOReader no tiene "atrás" para eso. "Jump to latest server
-- progress" saltaba sin preguntar y sin dejar rastro; el lector perdía su
-- lugar y no tenía cómo recuperarlo.
--
-- Acá el salto guarda primero dónde estabas. Dos reglas:
--   · rechazar el salto no toca nada — ni navega ni pisa un punto anterior;
--   · el punto se guarda ANTES de mover el libro, así que si el salto falla a
--     mitad de camino igual queda por dónde volver.
--
-- El historial se guarda por libro y acotado: un lector con cientos de libros
-- no tiene que arrastrar cientos de posiciones muertas en su configuración.
-- ============================================================

local ReadingPosition = {}
ReadingPosition.__index = ReadingPosition

ReadingPosition.MAX_BOOKS = 20

function ReadingPosition:new(options)
    options = options or {}
    return setmetatable({
        entries = options.entries or {},
        on_change = options.on_change,
        now = options.now or os.time,
    }, self)
end

function ReadingPosition:getEntries()
    return self.entries
end

local function count(entries)
    local total = 0
    for _ in pairs(entries) do total = total + 1 end
    return total
end

local function dropOldest(entries)
    local oldest_key, oldest_at
    for key, entry in pairs(entries) do
        local at = tonumber(entry and entry.at) or 0
        if oldest_at == nil or at < oldest_at then
            oldest_key, oldest_at = key, at
        end
    end
    if oldest_key then entries[oldest_key] = nil end
end

function ReadingPosition:_changed()
    if self.on_change then self.on_change(self.entries) end
end

--- Guarda dónde estaba el lector antes de moverlo.
-- @param book_hash string identidad del libro abierto
-- @param snapshot table {page, xpointer, percentage, chapter}
-- @return table|nil el punto guardado
function ReadingPosition:remember(book_hash, snapshot)
    if type(book_hash) ~= "string" or book_hash == "" then return nil end
    if type(snapshot) ~= "table" then return nil end
    local page = tonumber(snapshot.page)
    local xpointer = snapshot.xpointer
    if xpointer == "" then xpointer = nil end
    -- Sin página ni xpointer no hay a dónde volver: mejor no prometerlo.
    if not page and not xpointer then return nil end

    local entry = {
        page = page,
        xpointer = xpointer,
        percentage = tonumber(snapshot.percentage),
        chapter = snapshot.chapter,
        at = self.now(),
    }
    if self.entries[book_hash] == nil and count(self.entries) >= ReadingPosition.MAX_BOOKS then
        dropOldest(self.entries)
    end
    self.entries[book_hash] = entry
    self:_changed()
    return entry
end

function ReadingPosition:get(book_hash)
    if type(book_hash) ~= "string" then return nil end
    return self.entries[book_hash]
end

function ReadingPosition:has(book_hash)
    return self:get(book_hash) ~= nil
end

--- Devuelve el punto y lo consume: volver una vez, no un ciclo infinito
-- entre dos posiciones.
function ReadingPosition:take(book_hash)
    local entry = self:get(book_hash)
    if not entry then return nil end
    self.entries[book_hash] = nil
    self:_changed()
    return entry
end

function ReadingPosition:clear(book_hash)
    if book_hash == nil then
        self.entries = {}
        self:_changed()
        return
    end
    if self.entries[book_hash] == nil then return end
    self.entries[book_hash] = nil
    self:_changed()
end

return ReadingPosition

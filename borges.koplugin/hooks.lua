-- Envolver metodos de KOReader sin cambiar lo que hacen ni lo que devuelven.
--
--   Hooks.wrapInstance(obj, name, before, after, owner) -> boolean
--   Hooks.wrapModuleOnce(mod, name, before, after)      -> boolean
--
-- before(this, ...) -> ctx|nil         corre antes del original, en pcall
-- after(this, ctx, results, ...)       corre despues, en pcall; results es
--                                      { n = select('#', ...), ... } con lo
--                                      que devolvio el original
-- owner: dos envoltorios de duenos distintos se encadenan; el mismo dueno
--        no se instala dos veces (se reemplazan su before/after).
--
-- Reglas (diseno 4.2): el original SIEMPRE corre, con los mismos argumentos,
-- y su retorno sale intacto (incluidos los nil intercalados). Un error del
-- original se propaga igual que sin envoltorio. Un error propio se loguea una
-- vez y no cambia nada. Si el metodo no existe, la captura se apaga sola y se
-- loguea una vez por nombre.
local logger = require("logger")

local unpack = table.unpack or unpack

local Hooks = {}

-- wrapper -> { orig, owner, before, after, name }. Claves debiles: un
-- envoltorio de una instancia que KOReader tiro no queda vivo por esto.
local records = setmetatable({}, { __mode = "k" })
local missing = {}
local reported = {}

local function callable(value)
    if type(value) == "function" then return true end
    if type(value) ~= "table" then return false end
    local mt = getmetatable(value)
    return type(mt) == "table" and type(mt.__call) == "function"
end

local function noteMissing(name)
    name = tostring(name)
    if missing[name] then return end
    missing[name] = true
    logger.info("Borges: no se encontro el metodo para capturar, se apaga:", name)
end

local function report(rec, phase, err)
    local key = tostring(rec.owner) .. "\0" .. tostring(rec.name) .. "\0" .. phase
    if reported[key] then return end
    reported[key] = true
    logger.warn("Borges: fallo un envoltorio", rec.owner, rec.name, phase, tostring(err))
end

local function pack(...)
    return { n = select("#", ...), ... }
end

local function finish(rec, this, ctx, results, ...)
    local after = rec.after
    if after then
        local ok, err = pcall(after, this, ctx, results, ...)
        if not ok then report(rec, "after", err) end
    end
    return unpack(results, 1, results.n)
end

local function makeWrapper(rec)
    local function wrapper(this, ...)
        local ctx
        local before = rec.before
        if before then
            local ok, value = pcall(before, this, ...)
            if ok then ctx = value else report(rec, "before", value) end
        end
        if not rec.after then
            -- Llamada de cola: sin tabla intermedia y sin tocar el retorno.
            return rec.orig(this, ...)
        end
        return finish(rec, this, ctx, pack(rec.orig(this, ...)), ...)
    end
    records[wrapper] = rec
    return wrapper
end

function Hooks.wrapInstance(obj, name, before, after, owner)
    if type(obj) ~= "table" or type(name) ~= "string" then
        noteMissing(name)
        return false
    end
    local current = obj[name]
    if not callable(current) then
        noteMissing(name)
        return false
    end
    owner = owner or "anonymous"
    -- Si este dueno ya envolvio el metodo (en cualquier punto de la cadena),
    -- se le cambian before/after: nunca se apila.
    local cursor = current
    while records[cursor] do
        local rec = records[cursor]
        if rec.owner == owner then
            rec.before, rec.after = before, after
            return true
        end
        cursor = rec.orig
    end
    rawset(obj, name, makeWrapper({
        orig = current, owner = owner, before = before, after = after, name = name,
    }))
    return true
end

function Hooks.wrapModuleOnce(mod, name, before, after)
    if type(mod) ~= "table" or type(name) ~= "string" then
        noteMissing(name)
        return false
    end
    local marks = rawget(mod, "_borges_wrapped")
    if type(marks) == "table" and marks[name] ~= nil then return false end
    local current = mod[name]
    if not callable(current) then
        noteMissing(name)
        return false
    end
    if type(marks) ~= "table" then
        marks = {}
        rawset(mod, "_borges_wrapped", marks)
    end
    marks[name] = current
    rawset(mod, name, makeWrapper({
        orig = current, owner = "module", before = before, after = after, name = name,
    }))
    return true
end

function Hooks.missing()
    local copy = {}
    for name in pairs(missing) do copy[name] = true end
    return copy
end

return Hooks

--[[
TextLocate: ubicar el parrafo de un localizador ajeno por su texto.

Puro: arma las sondas que se le piden a findAllText de crengine y elige entre
los aciertos. Saltar al parrafo equivocado es PEOR que caer al porcentaje, asi
que ante cualquier duda devuelve nil y un motivo, y quien llama baja de escalon
(capitulo + fraccion, despues porcentaje).

crengine busca por nodo de texto y caracter a caracter (lvtinydom.cpp
::findText): una sonda que cruce una comilla, una raya o un fin de parrafo no
aparece. Por eso una sonda son palabras separadas por UN espacio ASCII crudo.
]]

local LocatorNorm = require("locatornorm")

local normalize, length = LocatorNorm.normalize, LocatorNorm.length
local commonPrefix, commonSuffix = LocatorNorm.commonPrefix, LocatorNorm.commonSuffix

local TextLocate = {
    MIN_SCORE = 40,     -- letras normalizadas de CONTEXTO (sin la sonda) que tienen que coincidir
    MIN_MARGIN = 16,    -- ventaja minima del mejor sobre el segundo
    MAX_HITS = 12,      -- con tantos aciertos (o mas) la sonda no sirve
    CONTEXT_WORDS = 10, -- palabras de contexto que se le piden a findAllText
    NEAR_PCT = 2,       -- desempate por porcentaje: el elegido a <= 2 %...
    FAR_PCT = 10,       -- ...y el siguiente a > 10 %
    MIN_PROBE_WORDS = 3,
    MAX_PROBE_WORDS = 7,
    MIN_PROBE_LETTERS = 16,
}

-- Invisibles que el libro puede tener y crengine saltea al buscar: no van en
-- el patron (guion blando, espacios de ancho cero, unidor de palabras, BOM).
local INVISIBLE = {
    "\194\173", "\226\128\139", "\226\128\140", "\226\128\141", "\226\129\160", "\239\187\191",
}

local function stripInvisible(s)
    for _, seq in ipairs(INVISIBLE) do
        s = s:gsub(seq, "")
    end
    return s
end

local function letters(norm)
    return length((norm:gsub(" ", "")))
end

-- El mejor tramo de palabras consecutivas separadas por un espacio crudo:
-- el de mas palabras (3 a 7) con >= 16 letras; a igualdad, el primero.
-- Devuelve (primera, ultima) indices en `words`, o nil.
local function bestSpan(words)
    local best_first, best_last, best_count = nil, nil, 0
    local run_start = 1
    for i = 1, #words + 1 do
        local breaks = i > #words or (i > 1 and words[i].gap ~= " ")
        if breaks and i > run_start then
            local run_end = i - 1
            for first = run_start, run_end do
                local last_max = math.min(run_end, first + TextLocate.MAX_PROBE_WORDS - 1)
                for last = last_max, first + TextLocate.MIN_PROBE_WORDS - 1, -1 do
                    local count = last - first + 1
                    if count <= best_count then break end
                    local parts = {}
                    for k = first, last do parts[#parts + 1] = words[k].norm end
                    if letters(table.concat(parts, " ")) >= TextLocate.MIN_PROBE_LETTERS then
                        best_first, best_last, best_count = first, last, count
                        break
                    end
                end
            end
        end
        if breaks then run_start = i end
    end
    return best_first, best_last
end

-- Texto crudo de words[1..upto] con sus separadores (y el separador de upto+1).
local function rawPrefix(words, upto)
    local parts = {}
    for k = 1, upto do
        parts[#parts + 1] = words[k].gap
        parts[#parts + 1] = words[k].raw
    end
    if words[upto + 1] then parts[#parts + 1] = words[upto + 1].gap end
    return table.concat(parts)
end

local function probeFrom(words, raw_before, raw_rest_after, words_ahead)
    local first, last = bestSpan(words)
    if not first then return nil end
    local pattern = {}
    for k = first, last do pattern[#pattern + 1] = stripInvisible(words[k].raw) end
    local prefix = rawPrefix(words, first - 1)
    -- Lo que sigue a la sonda dentro de este tramo, mas lo que venga despues.
    local tail = {}
    for k = first, #words do
        if k > first then tail[#tail + 1] = words[k].gap end
        tail[#tail + 1] = words[k].raw
    end
    tail[#tail + 1] = raw_rest_after or ""
    local left = normalize(raw_before .. " " .. prefix)
    return {
        pattern = table.concat(pattern, " "),
        offset = length(left),
        -- Palabras de la pantalla antes de la sonda: para volver al comienzo
        -- de la pantalla después de encontrarla.
        words_before = (words_ahead or 0) + first - 1,
        left = left,
        right = normalize(table.concat(tail)),
    }
end

--- Las sondas de un localizador (a lo sumo dos): la primera dentro de
-- `highlight`, la segunda dentro de `after`.
-- @return { {pattern, offset, left, right}, ... }
function TextLocate.probes(text)
    local probes = {}
    if type(text) ~= "table" then return probes end
    local before = type(text.before) == "string" and text.before or ""
    local highlight = type(text.highlight) == "string" and text.highlight or ""
    local after = type(text.after) == "string" and text.after or ""
    local highlight_words = LocatorNorm.words(highlight)
    local first = probeFrom(highlight_words, before, after, 0)
    if first then probes[#probes + 1] = first end
    local second = probeFrom(LocatorNorm.words(after), before .. " " .. highlight, "", #highlight_words)
    if second then probes[#probes + 1] = second end
    return probes
end

local function score(probe, hit)
    if type(hit) ~= "table" or type(hit.start) ~= "string" or hit.start == "" then return nil end
    -- Un acierto que corta una palabra del libro no es la frase de la sonda.
    if (hit.matched_word_prefix or "") ~= "" or (hit.matched_word_suffix or "") ~= "" then return nil end
    local right = normalize((hit.matched_text or "") .. (hit.next_text or ""))
    local left = normalize(hit.prev_text or "")
    -- Sólo cuenta el CONTEXTO: la sonda misma coincide siempre (es lo que se
    -- buscó), así que se descuenta. Una cita de la frase en otro lado (un
    -- prólogo) no trae el antes ni el después de quien leía.
    local probe_len = length(normalize(probe.pattern or ""))
    local forward = commonPrefix(right, probe.right)
    if forward < probe_len then return 0 end
    return (forward - probe_len) + commonSuffix(left, probe.left)
end

local function byPercent(candidates, locator, ctx)
    local total = type(locator.locations) == "table" and tonumber(locator.locations.totalProgression)
    if not total or type(ctx.percentOf) ~= "function" then return nil end
    local target = total * 100
    local scored = {}
    for _, c in ipairs(candidates) do
        local ok, pct = pcall(ctx.percentOf, c.hit.start)
        pct = ok and tonumber(pct) or nil
        if not pct then return nil end
        scored[#scored + 1] = { c = c, d = math.abs(pct - target) }
    end
    table.sort(scored, function(a, b) return a.d < b.d end)
    if scored[1] and scored[1].d <= TextLocate.NEAR_PCT
        and (not scored[2] or scored[2].d > TextLocate.FAR_PCT) then
        return scored[1].c
    end
    return nil
end

--- Elegir el acierto de `probe` entre `hits` (forma de findAllText).
-- @return { xpointer, score, by } | nil, reason
function TextLocate.choose(locator, probe, hits, ctx)
    ctx = ctx or {}
    if type(probe) ~= "table" or type(hits) ~= "table" or #hits == 0 then return nil, "no_hits" end
    if #hits >= TextLocate.MAX_HITS then return nil, "too_many_hits" end
    local candidates = {}
    for _, hit in ipairs(hits) do
        local s = score(probe, hit)
        if s then candidates[#candidates + 1] = { hit = hit, score = s } end
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    local best = candidates[1]
    if not best or best.score < TextLocate.MIN_SCORE then return nil, "weak_match" end
    local second = candidates[2]
    if not second or best.score - second.score >= TextLocate.MIN_MARGIN then
        return { xpointer = best.hit.start, score = best.score, by = second and "margin" or "unique" }
    end
    -- Empatados: los que quedan dentro del margen del mejor.
    local tied = {}
    for _, c in ipairs(candidates) do
        if c.score >= TextLocate.MIN_SCORE and best.score - c.score < TextLocate.MIN_MARGIN then
            tied[#tied + 1] = c
        end
    end
    local title = type(locator) == "table" and type(locator.title) == "string" and normalize(locator.title) or ""
    if title ~= "" and type(ctx.chapterTitleOf) == "function" then
        local same = {}
        for _, c in ipairs(tied) do
            local ok, t = pcall(ctx.chapterTitleOf, c.hit.start)
            if ok and type(t) == "string" and normalize(t) == title then same[#same + 1] = c end
        end
        if #same == 1 then
            return { xpointer = same[1].hit.start, score = same[1].score, by = "chapter" }
        end
        if #same > 1 then tied = same end
    end
    local near = type(locator) == "table" and byPercent(tied, locator, ctx)
    if near then
        return { xpointer = near.hit.start, score = near.score, by = "progression" }
    end
    return nil, "ambiguous"
end

TextLocate.SEARCH_SECONDS = 8 -- tope de una busqueda en el proceso hijo

--- Lo que corre en el proceso HIJO (Background.request): la busqueda de
-- crengine borra y redibuja la seleccion nativa, asi que nunca se llama en el
-- proceso de KOReader. Devuelve la lista de aciertos (o {}).
function TextLocate.searchJob(document, probe)
    return function()
        local raw = type(document) == "table" and document._document or nil
        if raw == nil or type(probe) ~= "table" or type(probe.pattern) ~= "string" then return {} end
        local hits = raw:findAllText(probe.pattern, true, false, TextLocate.MAX_HITS, true, TextLocate.CONTEXT_WORDS)
        if type(hits) ~= "table" then return {} end
        -- Solo lo que la eleccion usa: la respuesta cruza un pipe en JSON.
        local out = {}
        for i, hit in ipairs(hits) do
            out[i] = {
                start = hit.start, ["end"] = hit["end"], matched_text = hit.matched_text,
                prev_text = hit.prev_text, next_text = hit.next_text,
                matched_word_prefix = hit.matched_word_prefix, matched_word_suffix = hit.matched_word_suffix,
            }
        end
        return out
    end
end

return TextLocate

--[[
PositionLocator: la posicion de lectura en una forma que otro lector, otra
edicion del mismo libro o la web pueden ubicar (nombres del Locator de
Readium, mas la extension `chapter`):

  {
    v = 1,
    title = "Capitulo III",                              -- TOC, nil si no hay
    chapter = { index = 7, depth = 2, occurrence = 1 },  -- indice en el TOC aplanado,
                                                         -- profundidad, n-esima entrada
                                                         -- con ese titulo normalizado
    locations = { progression = 0.4213, totalProgression = 0.3712, position = 123 },
    text = { before = "...", highlight = "...", after = "..." }, -- nil si no es seguro
  }

Se arma SOLO al encolar la posicion (nunca al pasar pagina): lee el texto de
la pantalla con DocText (sin dibujar seleccion, nunca con una seleccion, un
diccionario o una busqueda abiertos). Todo puede fallar sin consecuencias: un
error deja el localizador en nil y la posicion viaja igual.
]]

local DocText = require("doctext")
local LocatorNorm = require("locatornorm")

local PositionLocator = {
    VERSION = 1,
    MIN_TEXT = 16,        -- letras normalizadas minimas para mandar `text`
    HIGHLIGHT_CHARS = 64, -- codepoints crudos; se extiende hasta el fin de palabra...
    AFTER_CHARS = 64,
    BEFORE_CHARS = 32,
    WORD_CAP = 80,        -- ...con este tope
    BEFORE_WORDS = 12,    -- palabras hacia atras que se recorren para `before`
    TITLE_BYTES = 160,
}

local decode = LocatorNorm.decode

-- Lista de codepoints (como cadenas) de s.
local function chars(s)
    local list, i, len = {}, 1, #s
    while i <= len do
        local _, nexti = decode(s, i)
        list[#list + 1] = s:sub(i, nexti - 1)
        i = nexti
    end
    return list
end

local function isSpace(ch) return ch == " " or ch == "\n" end

-- De `from` (1-based) toma `size` codepoints y sigue hasta el fin de palabra,
-- sin pasar de `cap`. Devuelve (texto, indice siguiente).
local function cutForward(list, from, size, cap)
    local stop = math.min(#list, from + size - 1)
    while stop < #list and stop - from + 1 < cap and not isSpace(list[stop + 1]) do stop = stop + 1 end
    return table.concat(list, "", from, stop), stop + 1
end

-- Los `size` codepoints que terminan en `to`, extendidos hasta el comienzo de palabra.
local function cutBackward(list, to, size, cap)
    local start = math.max(1, to - size + 1)
    while start > 1 and to - start + 1 < cap and not isSpace(list[start - 1]) do start = start - 1 end
    if to < start then return "" end
    return table.concat(list, "", start, to)
end

local function collapse(s)
    if type(s) ~= "string" then return nil end
    return (s:gsub("%s+", " "))
end

-- Espacios colapsados, pero un fin de parrafo queda como "\n": una sonda de
-- TextLocate no puede cruzarlo (crengine busca por nodo de texto).
local function collapseLines(s)
    if type(s) ~= "string" then return nil end
    return (s:gsub("[ \t\r\f\v]+", " "):gsub(" ?\n%s*", "\n"))
end

local function trim(s)
    return (s:gsub("^[ \n]+", ""):gsub("[ \n]+$", ""))
end

local function round4(x)
    return math.floor(x * 10000 + 0.5) / 10000
end

local function clamp01(x)
    if x ~= x then return nil end
    if x < 0 then return 0 elseif x > 1 then return 1 end
    return x
end

local function rawDocument(document)
    return type(document) == "table" and document._document or nil
end

-- Recorre `count` palabras desde xp con el metodo de crengine `method`.
local function walkWords(document, xp, method, count)
    local raw = rawDocument(document)
    if raw == nil or type(raw[method]) ~= "function" then return nil end
    local cursor = xp
    for _ = 1, count do
        local ok, nxt = pcall(raw[method], raw, cursor)
        if not ok or type(nxt) ~= "string" or nxt == "" or nxt == cursor then break end
        cursor = nxt
    end
    if cursor == xp then return nil end
    return cursor
end

-- El fin de la pantalla, como DocText.screenBounds pero sin volver a pedir
-- el XPointer del comienzo (quien llama ya lo tiene).
local function screenEnd(ui)
    local document = ui.document
    local ok_page, page = pcall(document.getCurrentPage, document)
    local ok_count, count = pcall(document.getPageCount, document)
    if not ok_page or not ok_count or type(page) ~= "number" or type(count) ~= "number" then return nil end
    local view_mode = type(ui.view) == "table" and ui.view.view_mode or "page"
    local next_page
    if view_mode == "scroll" then
        next_page = page + 1
    else
        local ok_visible, visible = pcall(document.getVisiblePageNumberCount, document)
        if not ok_visible or type(visible) ~= "number" or visible < 1 then visible = 1 end
        next_page = page + visible
    end
    if next_page > count or type(document.getPageXPointer) ~= "function" then return nil end
    local ok_end, xp_end = pcall(document.getPageXPointer, document, next_page)
    if not ok_end or type(xp_end) ~= "string" or xp_end == "" then return nil end
    return xp_end
end

--- El texto de donde quedaste: { before, highlight, after } o nil.
function PositionLocator.screenText(ui, xp_start)
    local document = ui.document
    local xp_end = screenEnd(ui)
    -- Ultima pantalla del libro: unas palabras hacia adelante alcanzan.
    if not xp_end then xp_end = walkWords(document, xp_start, "getNextVisibleWordEnd", 40) end
    if not xp_end then return nil end
    local screen = DocText.between(document, xp_start, xp_end)
    if type(screen) ~= "string" then return nil end
    screen = collapseLines(screen):gsub("^[ \n]+", "")
    if screen == "" then return nil end
    local list = chars(screen)
    local highlight, nexti = cutForward(list, 1, PositionLocator.HIGHLIGHT_CHARS, PositionLocator.WORD_CAP)
    highlight = trim(highlight)
    if LocatorNorm.length(LocatorNorm.normalize(highlight)) < PositionLocator.MIN_TEXT then return nil end
    local after = ""
    if nexti <= #list then
        after = cutForward(list, nexti, PositionLocator.AFTER_CHARS, PositionLocator.WORD_CAP):gsub("[ \n]+$", "")
    end
    local before = ""
    local xp_before = walkWords(document, xp_start, "getPrevVisibleWordStart", PositionLocator.BEFORE_WORDS)
    if xp_before then
        local prev = DocText.between(document, xp_before, xp_start)
        if type(prev) == "string" then
            local prev_list = chars(collapseLines(prev))
            before = trim(cutBackward(prev_list, #prev_list, PositionLocator.BEFORE_CHARS, PositionLocator.WORD_CAP))
        end
    end
    return { before = before, highlight = highlight, after = after }
end

local function cleanTitle(ui, title)
    if type(title) ~= "string" then return nil end
    local toc = ui.toc
    if type(toc) == "table" and type(toc.cleanUpTocTitle) == "function" then
        local ok, clean = pcall(toc.cleanUpTocTitle, toc, title)
        if ok and type(clean) == "string" then title = clean end
    end
    title = trim(collapse(title))
    if title == "" then return nil end
    if #title > PositionLocator.TITLE_BYTES then
        local list = chars(title)
        local out, bytes = {}, 0
        for _, ch in ipairs(list) do
            if bytes + #ch > PositionLocator.TITLE_BYTES then break end
            out[#out + 1] = ch
            bytes = bytes + #ch
        end
        title = table.concat(out)
    end
    return title
end

local function posOf(document, xp)
    if type(xp) ~= "string" then return nil end
    local ok, y
    if type(document.getPosFromXPointer) == "function" then
        ok, y = pcall(document.getPosFromXPointer, document, xp)
    end
    if not ok or type(y) ~= "number" then
        local raw = rawDocument(document)
        if raw and type(raw.getPosFromXPointer) == "function" then
            ok, y = pcall(raw.getPosFromXPointer, raw, xp)
        end
    end
    if ok and type(y) == "number" then return y end
    return nil
end

local function docHeight(document)
    local info = type(document.info) == "table" and document.info or nil
    if info and type(info.doc_height) == "number" and info.doc_height > 0 then return info.doc_height end
    local raw = rawDocument(document)
    if raw and type(raw.getFullHeight) == "function" then
        local ok, h = pcall(raw.getFullHeight, raw)
        if ok and type(h) == "number" and h > 0 then return h end
    end
    return nil
end

--- Capitulo del TOC que contiene la posicion: (chapter, title, progression) o nil.
-- `where` es un XPointer (documentos reflowables) o una pagina (PDF).
function PositionLocator.chapterOf(ui, where, opts)
    local toc = ui.toc
    if type(toc) ~= "table" or type(toc.getTocIndexByPage) ~= "function" then return nil end
    local ok, index = pcall(toc.getTocIndexByPage, toc, where)
    if not ok or type(index) ~= "number" then return nil end
    local list = toc.toc
    if type(list) ~= "table" or type(list[index]) ~= "table" then return nil end
    local entry = list[index]
    local title = cleanTitle(ui, entry.title)
    local norm = LocatorNorm.normalize(title or "")
    local occurrence = 0
    if norm ~= "" then
        for i = 1, index do
            local other = list[i]
            if type(other) == "table" and LocatorNorm.normalize(cleanTitle(ui, other.title) or "") == norm then
                occurrence = occurrence + 1
            end
        end
    end
    local nxt = list[index + 1]
    local progression
    if opts.paged then
        local page, first = tonumber(opts.page), tonumber(entry.page)
        local last = nxt and tonumber(nxt.page) or ((tonumber(opts.total_pages) or 0) + 1)
        if page and first and last and last > first then progression = (page - first) / (last - first) end
    else
        local document = ui.document
        local here, first = posOf(document, where), posOf(document, entry.xpointer)
        local last = nxt and posOf(document, nxt.xpointer) or docHeight(document)
        if here and first and last and last > first then progression = (here - first) / (last - first) end
    end
    progression = progression and clamp01(progression)
    return {
        index = index,
        depth = tonumber(entry.depth) or 1,
        occurrence = occurrence > 0 and occurrence or nil,
    }, title, progression and round4(progression) or nil
end

--- Armar el localizador de la posicion actual.
-- opts = { has_pages, percentage, page, total_pages, capture_text, xpointer }
function PositionLocator.capture(ui, opts)
    opts = opts or {}
    if type(ui) ~= "table" or type(ui.document) ~= "table" then return nil end
    local paged = opts.has_pages == true or ui.paging ~= nil
    local locator = { v = PositionLocator.VERSION, locations = {} }
    local pct = tonumber(opts.percentage)
    if pct and pct == pct then
        locator.locations.totalProgression = round4(clamp01(pct / 100))
    end
    local page = tonumber(opts.page)
    if page then locator.locations.position = math.floor(page) end

    local xp_start
    if not paged then
        xp_start = opts.xpointer
        if type(xp_start) ~= "string" or xp_start == "" then xp_start = DocText.screenBounds(ui) end
        if type(xp_start) ~= "string" or xp_start == "" then return locator end
    end

    local chapter, title, progression = PositionLocator.chapterOf(ui, paged and page or xp_start, {
        paged = paged, page = page, total_pages = opts.total_pages,
    })
    if chapter and title then
        locator.title, locator.chapter = title, chapter
    elseif chapter then
        locator.chapter = chapter
    end
    if progression then locator.locations.progression = progression end

    -- PDF/DjVu: nunca texto (pedirlo cuesta un parseo de pagina).
    if paged or opts.capture_text == false or not DocText.safe(ui) then return locator end
    locator.text = PositionLocator.screenText(ui, xp_start)
    return locator
end

local function tocList(ui)
    local toc = type(ui) == "table" and ui.toc or nil
    if type(toc) ~= "table" then return nil end
    if toc.toc == nil and type(toc.fillToc) == "function" then pcall(toc.fillToc, toc) end
    return type(toc.toc) == "table" and toc.toc or nil
end

--- El capitulo de un localizador ajeno en el TOC de ESTE libro: mismo titulo
-- normalizado y misma ocurrencia; si esa ocurrencia no existe aca y el titulo
-- es unico, ese. Si no, nil (no se adivina).
-- @return { index, page, next_page } | nil
function PositionLocator.localChapter(ui, locator, total_pages)
    if type(locator) ~= "table" or type(locator.title) ~= "string" then return nil end
    local title = LocatorNorm.normalize(locator.title)
    if title == "" then return nil end
    local list = tocList(ui)
    if not list then return nil end
    local matches = {}
    for i, entry in ipairs(list) do
        if type(entry) == "table" and LocatorNorm.normalize(cleanTitle(ui, entry.title) or "") == title then
            matches[#matches + 1] = i
        end
    end
    local occurrence = type(locator.chapter) == "table" and tonumber(locator.chapter.occurrence) or nil
    local index
    if occurrence and matches[occurrence] then
        index = matches[occurrence]
    elseif #matches == 1 then
        index = matches[1]
    end
    if not index then return nil end
    local page = tonumber(list[index].page)
    if not page then return nil end
    local nxt = list[index + 1]
    local next_page = nxt and tonumber(nxt.page) or ((tonumber(total_pages) or page) + 1)
    if next_page < page then next_page = page end
    return { index = index, page = page, next_page = next_page }
end

--- Donde cae el localizador en las paginas de este libro (0-100), por capitulo
-- y fraccion: (page + progression * (next_page - page) - 1) / total_pages * 100.
function PositionLocator.localPercent(ui, locator, total_pages)
    local total = tonumber(total_pages)
    if not total or total <= 0 then return nil end
    local chapter = PositionLocator.localChapter(ui, locator, total)
    if not chapter then return nil end
    local progression = type(locator.locations) == "table" and tonumber(locator.locations.progression) or nil
    progression = progression and clamp01(progression) or 0
    local at = chapter.page + progression * (chapter.next_page - chapter.page) - 1
    local pct = at / total * 100
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return pct, chapter
end

-- ------------------------------------------------------------
-- Navegar a una posicion ajena (pasos sincronos de la cascada)
-- ------------------------------------------------------------

local function skipCodepoints(s, count)
    local i, len = 1, #s
    for _ = 1, count do
        if i > len then break end
        local _cp, nexti = decode(s, i)
        i = nexti
    end
    return s:sub(i)
end

local function firstCodepoints(s, n)
    local i, count, len = 1, 0, #s
    while i <= len and count < n do
        local _cp, nexti = decode(s, i)
        i = nexti
        count = count + 1
    end
    return s:sub(1, i - 1)
end

--- Texto del nodo de `xp` desde su offset `.N` (getTextFromXPointer: sin
-- efectos sobre la seleccion ni la pantalla). nil si no se puede leer.
function PositionLocator.textAt(document, xp)
    if type(document) ~= "table" or type(xp) ~= "string" or xp == "" then return nil end
    local ok, text = false, nil
    if type(document.getTextFromXPointer) == "function" then
        ok, text = pcall(document.getTextFromXPointer, document, xp)
    end
    if not ok or type(text) ~= "string" then
        local raw = rawDocument(document)
        if raw and type(raw.getTextFromXPointer) == "function" then
            ok, text = pcall(raw.getTextFromXPointer, raw, xp)
        end
    end
    if not ok or type(text) ~= "string" then return nil end
    local offset = tonumber(xp:match("%.(%d+)$")) or 0
    if offset > 0 then text = skipCodepoints(text, offset) end
    return text
end

PositionLocator.VERIFY_CHARS = 24
PositionLocator.VERIFY_MIN = 12

--- ¿El XPointer dice lo mismo que el localizador? Sin texto no hay con que
-- contradecirlo (true). Con texto: los primeros min(24, n) codepoints
-- normalizados del nodo y de `highlight` coinciden; un nodo con menos de 12
-- letras no alcanza para confirmar nada (false: se baja de escalon).
PositionLocator.VERIFY_SHORT_MIN = 4
PositionLocator.VERIFY_EXTEND_WORDS = 8

-- Unas palabras desde xp, cruzando nodos (un título, un nodo cortado por una
-- cursiva). Sólo con el documento a salvo (DocText.safe) y sin dibujar nada.
local function textAcrossNodes(ui, document, xp)
    if type(ui) ~= "table" or not DocText.safe(ui) then return nil end
    local stop = walkWords(document, xp, "getNextVisibleWordEnd", PositionLocator.VERIFY_EXTEND_WORDS)
    if not stop then return nil end
    return DocText.between(document, xp, stop)
end

--- ¿El XPointer dice lo mismo que el localizador? Sin texto no hay con que
-- contradecirlo (true). Con texto: los primeros min(24, n) codepoints
-- normalizados del texto en xp y de `highlight` coinciden. Un nodo corto (un
-- título, «y entonces » antes de una cursiva) se completa con las palabras
-- que siguen; si no se puede leer más, el nodo entero tiene que ser el
-- comienzo exacto de `highlight`, en límite de palabra.
function PositionLocator.verified(document, xp, locator, ui)
    local text = type(locator) == "table" and type(locator.text) == "table" and locator.text.highlight or nil
    if type(text) ~= "string" then return true end
    local want = LocatorNorm.normalize(text)
    if want == "" then return true end
    local here = PositionLocator.textAt(document, xp)
    if not here then return false end
    local got = LocatorNorm.normalize(here)
    if LocatorNorm.length(got) < PositionLocator.VERIFY_MIN then
        local longer = textAcrossNodes(ui, document, xp)
        if type(longer) == "string" then
            local normalized = LocatorNorm.normalize(longer)
            if LocatorNorm.length(normalized) > LocatorNorm.length(got) then got = normalized end
        end
    end
    local n = math.min(PositionLocator.VERIFY_CHARS, LocatorNorm.length(got), LocatorNorm.length(want))
    if n < PositionLocator.VERIFY_MIN then
        local short = LocatorNorm.length(got)
        if short < PositionLocator.VERIFY_SHORT_MIN or short > LocatorNorm.length(want) then return false end
        if firstCodepoints(want, short) ~= got then return false end
        local after = want:sub(#got + 1, #got + 1)
        return after == "" or after == " "
    end
    return firstCodepoints(got, n) == firstCodepoints(want, n)
end

local function inDocument(document, xp)
    if type(xp) ~= "string" or xp == "" or type(document) ~= "table"
        or type(document.isXPointerInDocument) ~= "function" then return false end
    local ok, valid = pcall(document.isXPointerInDocument, document, xp)
    return ok and valid == true
end

--- El paso exacto: el XPointer propio, verificado por texto.
-- @return target, method | nil
function PositionLocator.resolveExact(ui, remote, opts)
    opts = opts or {}
    if opts.has_pages or type(remote) ~= "table" then return nil end
    local document = ui and ui.document
    local locator = type(remote.locator) == "table" and remote.locator or nil
    if inDocument(document, remote.xpointer) and PositionLocator.verified(document, remote.xpointer, locator, ui) then
        return { xpointer = remote.xpointer }, "xpointer"
    end
    return nil
end

--- Los pasos aproximados: capitulo + fraccion, despues porcentaje.
function PositionLocator.resolveApprox(ui, remote, opts)
    opts = opts or {}
    local total = tonumber(opts.total_pages)
    if not total or total <= 0 then return nil end
    local locator = type(remote) == "table" and type(remote.locator) == "table" and remote.locator or nil
    if locator then
        local ok, pct = pcall(PositionLocator.localPercent, ui, locator, total)
        if ok and pct then
            local page = math.floor(pct / 100 * total) + 1
            return { page = math.max(1, math.min(page, total)) }, "chapter"
        end
    end
    local pct = tonumber(opts.percentage)
    if pct and pct >= 0 then
        local calc = math.floor(pct / 100 * total + 0.5)
        return { page = math.max(1, math.min(calc, total)) }, "percentage"
    end
    return nil
end

--- La cascada sincronica (sin buscar texto): XPointer, la misma
-- pagina en el mismo archivo, capitulo, porcentaje.
-- @return target ({xpointer} o {page}), method | nil
function PositionLocator.resolveSync(ui, remote, opts)
    opts = opts or {}
    if type(remote) ~= "table" then return nil end
    local target, method = PositionLocator.resolveExact(ui, remote, opts)
    if target then return target, method end
    if opts.has_pages and opts.same_device then
        local page, total = tonumber(remote.current_page), tonumber(opts.total_pages)
        if page and page >= 1 and total and page <= total then return { page = page }, "page" end
    end
    return PositionLocator.resolveApprox(ui, remote, opts)
end

PositionLocator.WALK_BACK_MAX = 30

--- Volver `words` palabras desde xp (comienzo de la sonda -> comienzo de la
-- pantalla del otro lector). Sólo mueve un puntero: no lee texto ni dibuja.
-- @return el XPointer de más atrás, o xp si no se pudo.
function PositionLocator.walkBack(document, xp, words)
    local count = math.min(tonumber(words) or 0, PositionLocator.WALK_BACK_MAX)
    if count <= 0 then return xp end
    return walkWords(document, xp, "getPrevVisibleWordStart", count) or xp
end

--- Copia profunda de un localizador (lo que va a la cola no comparte tablas con la cache).
function PositionLocator.copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = PositionLocator.copy(v) end
    return out
end

return PositionLocator

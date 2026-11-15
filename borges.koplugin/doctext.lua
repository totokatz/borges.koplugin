-- DocText: el UNICO modulo del plugin que le pide texto a crengine.
--
-- Reglas (ver docs/superpowers/plans/2026-11-14-plugin-01-lectura-en-palabras.md):
--   * El texto se pide solo con el binding crudo
--     document._document:getTextFromXPointers(xp0, xp1, false, false): los dos
--     false dicen "no dibujes seleccion". Con true, crengine pinta la seleccion
--     y borra la que la persona tenga abierta.
--   * Nunca con una seleccion, un diccionario o una busqueda abiertos: safe(ui)
--     lo decide y quien llama lo consulta antes, siempre en diferido (nunca en
--     el camino caliente de pasar pagina).
--   * Lo que sale de aca se cuenta (palabras, caracteres) y se tira: el texto
--     de una pantalla no se guarda en ningun lado.

local DocText = {}

-- Ganchos de prueba: si estan puestos, reemplazan la consulta real.
DocText._dictWindows = nil -- function() -> integer
DocText._isShown = nil -- function(widget) -> boolean

local function dictWindowCount()
    if DocText._dictWindows then return DocText._dictWindows() or 0 end
    local ok, DictQuickLookup = pcall(require, "ui/widget/dictquicklookup")
    if not ok or type(DictQuickLookup) ~= "table" then return 0 end
    local list = DictQuickLookup.window_list
    if type(list) ~= "table" then return 0 end
    return #list
end

local function widgetShown(widget)
    if DocText._isShown then return DocText._isShown(widget) and true or false end
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok or type(UIManager) ~= "table" or type(UIManager.isWidgetShown) ~= "function" then
        -- Sin forma de saberlo, un dialogo de busqueda que existe cuenta como abierto.
        return true
    end
    local ok_shown, shown = pcall(UIManager.isWidgetShown, UIManager, widget)
    if not ok_shown then return true end
    return shown and true or false
end

-- true solo si pedir texto ahora no puede tocar nada que la persona tenga
-- abierto: ni seleccion en curso, ni diccionario, ni dialogo de busqueda.
function DocText.safe(ui)
    if type(ui) ~= "table" then return false end
    local highlight = ui.highlight
    if type(highlight) == "table" then
        if highlight.hold_pos or highlight.selected_text or highlight.select_mode then
            return false
        end
    end
    if dictWindowCount() > 0 then return false end
    local search = ui.search
    if type(search) == "table" and search.search_dialog and widgetShown(search.search_dialog) then
        return false
    end
    return true
end

local function rawDocument(document)
    if type(document) ~= "table" then return nil end
    return document._document
end

-- Texto entre dos XPointers, sin dibujar seleccion. nil si algo falla.
function DocText.between(document, xp0, xp1)
    local raw = rawDocument(document)
    if raw == nil or type(xp0) ~= "string" or type(xp1) ~= "string" then return nil end
    local ok, text = pcall(function()
        return raw:getTextFromXPointers(xp0, xp1, false, false)
    end)
    if ok and type(text) == "string" then return text end
    return nil
end

-- ---------------------------------------------------------------------------
-- Regla de palabras. Es la MISMA que shared/wordCount.js y la fija
-- scripts/fixtures/word-count-cases.json (scripts/__tests__/wordCountParity).
--   * Separadores: espacios ASCII (espacio, \t, \n, \r, \f, \v), U+00A0 y U+3000.
--   * Un token cuenta como palabra si, sin la puntuacion ASCII ni
--     — – … « » “ ” ‘ ’ ¿ ¡ ·, le queda algo.
--   * Cada caracter CJK (U+3040..U+9FFF) es una palabra por si mismo y parte
--     el token. La puntuacion CJK (U+3001..U+303F) no cuenta.
--   * chars = puntos de codigo que no son separadores.
-- ---------------------------------------------------------------------------

local EXTRA_PUNCT = {
    [0x2014] = true, -- raya
    [0x2013] = true, -- guion medio
    [0x2026] = true, -- puntos suspensivos
    [0x00AB] = true, [0x00BB] = true, -- comillas latinas
    [0x201C] = true, [0x201D] = true, -- comillas dobles tipograficas
    [0x2018] = true, [0x2019] = true, -- comillas simples tipograficas
    [0x00BF] = true, [0x00A1] = true, -- apertura de pregunta y exclamacion
    [0x00B7] = true, -- punto medio
}

local function isSpace(cp)
    return cp == 0x20 or (cp >= 0x09 and cp <= 0x0D) or cp == 0xA0 or cp == 0x3000
end

local function isAsciiPunct(cp)
    return (cp >= 0x21 and cp <= 0x2F) or (cp >= 0x3A and cp <= 0x40)
        or (cp >= 0x5B and cp <= 0x60) or (cp >= 0x7B and cp <= 0x7E)
end

local function isCjkPunct(cp)
    return cp >= 0x3001 and cp <= 0x303F
end

local function isCjk(cp)
    return cp >= 0x3040 and cp <= 0x9FFF
end

-- Decodifica el punto de codigo que empieza en i. Un byte invalido cuenta
-- como un caracter de un byte (un archivo roto no hace perder texto).
local function codepointAt(text, i)
    local b1 = text:byte(i)
    if b1 < 0x80 then return b1, 1 end
    local len, cp
    if b1 >= 0xF0 and b1 <= 0xF7 then len, cp = 4, b1 - 0xF0
    elseif b1 >= 0xE0 and b1 < 0xF0 then len, cp = 3, b1 - 0xE0
    elseif b1 >= 0xC0 and b1 < 0xE0 then len, cp = 2, b1 - 0xC0
    else return b1, 1 end
    if i + len - 1 > #text then return b1, 1 end
    for k = 1, len - 1 do
        local b = text:byte(i + k)
        if b < 0x80 or b > 0xBF then return b1, 1 end
        cp = cp * 64 + (b - 0x80)
    end
    return cp, len
end

-- Recorrido caracter por caracter: la referencia, y lo que se usa con CJK,
-- espacios no separables o U+3000.
function DocText._countWordsSlow(text)
    if type(text) ~= "string" or text == "" then return 0, 0 end
    local words, chars = 0, 0
    local run_has_content = false
    local i, n = 1, #text
    while i <= n do
        local cp, len = codepointAt(text, i)
        i = i + len
        if isSpace(cp) then
            if run_has_content then words = words + 1 end
            run_has_content = false
        else
            chars = chars + 1
            if isCjk(cp) then
                if run_has_content then words = words + 1 end
                run_has_content = false
                words = words + 1
            elseif not (isAsciiPunct(cp) or EXTRA_PUNCT[cp] or isCjkPunct(cp)) then
                run_has_content = true
            end
        end
    end
    if run_has_content then words = words + 1 end
    return words, chars
end

-- La puntuacion de dos o tres bytes que no hace palabra (las mismas de EXTRA_PUNCT).
local EXTRA_PUNCT_BYTES = {
    "\226\128\148", "\226\128\147", "\226\128\166", "\194\171", "\194\187", "\226\128\156",
    "\226\128\157", "\226\128\152", "\226\128\153", "\194\191", "\194\161", "\194\183",
}

-- Camino rapido (el de casi toda la prosa): los patrones de Lua corren en C y
-- una pantalla se cuenta varias veces mas rapido que caracter por caracter. Da
-- exactamente lo mismo que _countWordsSlow; si el texto trae CJK, U+00A0 o
-- U+3000, se usa el lento.
function DocText.countWords(text)
    if type(text) ~= "string" or text == "" then return 0, 0 end
    if text:find("[\227-\233]") or text:find("\194\160", 1, true) then
        return DocText._countWordsSlow(text)
    end
    local _, continuation = text:gsub("[\128-\191]", "")
    local _, blanks = text:gsub("%s", "")
    local chars = #text - continuation - blanks
    local words = 0
    for token in text:gmatch("%S+") do
        if token:find("%w") then
            words = words + 1
        elseif token:find("[\128-\255]") then
            local rest = token:gsub("%p", "")
            for _, mark in ipairs(EXTRA_PUNCT_BYTES) do
                if rest == "" then break end
                rest = rest:gsub(mark, "")
            end
            if rest ~= "" then words = words + 1 end
        end
    end
    return words, chars
end

-- Inicio y fin de lo que hay en pantalla, en documentos reflowables. Lee
-- valores que crengine ya tiene calculados para la pagina actual: no mueve
-- nada ni pide texto. nil en PDF/DjVu. Si quien llama ya tiene el XPointer de
-- inicio (known_start), no se lo vuelve a pedir a crengine.
function DocText.screenBounds(ui, known_start)
    if type(ui) ~= "table" or ui.paging then return nil end
    local document = ui.document
    if type(document) ~= "table" then return nil end
    local xp_start = known_start
    if type(xp_start) ~= "string" or xp_start == "" then
        if type(document.getXPointer) ~= "function" then return nil end
        local ok, value = pcall(document.getXPointer, document)
        if not ok or type(value) ~= "string" or value == "" then return nil end
        xp_start = value
    end
    local ok_page, page = pcall(document.getCurrentPage, document)
    local ok_count, count = pcall(document.getPageCount, document)
    if not ok_page or not ok_count or type(page) ~= "number" or type(count) ~= "number" then
        return xp_start, nil
    end
    local view_mode = type(ui.view) == "table" and ui.view.view_mode or "page"
    local next_page
    if view_mode == "scroll" then
        -- En vista continua la "pagina" de crengine mide una pantalla: lo que
        -- sigue a la vista es el comienzo de la siguiente.
        next_page = page + 1
    else
        local ok_visible, visible = pcall(document.getVisiblePageNumberCount, document)
        if not ok_visible or type(visible) ~= "number" or visible < 1 then visible = 1 end
        next_page = page + visible
    end
    if next_page > count then return xp_start, nil end
    local ok_end, xp_end = pcall(document.getPageXPointer, document, next_page)
    if not ok_end or type(xp_end) ~= "string" or xp_end == "" then return xp_start, nil end
    return xp_start, xp_end
end

local function clip(text, chars, from_end)
    if type(text) ~= "string" then return nil end
    if #text <= chars then return text end
    if from_end then
        local start = #text - chars + 1
        -- No cortar un caracter UTF-8 por la mitad.
        while start <= #text do
            local b = text:byte(start)
            if b < 0x80 or b >= 0xC0 then break end
            start = start + 1
        end
        return text:sub(start)
    end
    local stop = chars
    while stop > 0 do
        local b = text:byte(stop + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        stop = stop - 1
    end
    return text:sub(1, stop)
end

-- Texto antes de xp0 y despues de xp1, de a lo sumo `chars` bytes cada uno.
-- Lo usan los planes de consultas y subrayados (contexto de una seleccion).
-- Quien llama consulta safe(ui) antes, como con between.
function DocText.around(document, xp0, xp1, chars)
    local raw = rawDocument(document)
    if raw == nil or type(xp0) ~= "string" or type(xp1) ~= "string" then return nil end
    chars = tonumber(chars) or 0
    if chars <= 0 then return nil end
    local has_methods = pcall(function()
        assert(raw.getPrevVisibleWordStart and raw.getNextVisibleWordEnd)
    end)
    if not has_methods then return nil end
    local function walk(from, method, backwards)
        local cursor = from
        for _ = 1, 40 do
            local ok_step, nxt = pcall(function() return raw[method](raw, cursor) end)
            if not ok_step or type(nxt) ~= "string" or nxt == cursor then break end
            cursor = nxt
            local text = backwards and DocText.between(document, cursor, from)
                or DocText.between(document, from, cursor)
            if text and #text >= chars then break end
        end
        return cursor
    end
    local before_xp = walk(xp0, "getPrevVisibleWordStart", true)
    local after_xp = walk(xp1, "getNextVisibleWordEnd", false)
    local prefix = before_xp ~= xp0 and DocText.between(document, before_xp, xp0) or ""
    local suffix = after_xp ~= xp1 and DocText.between(document, xp1, after_xp) or ""
    return clip(prefix, chars, true), clip(suffix, chars, false)
end

-- Fraccion (0..1, seis decimales) de la altura del documento donde cae xp.
function DocText.percentOf(document, xp)
    local raw = rawDocument(document)
    if raw == nil or type(xp) ~= "string" then return nil end
    local ok, value = pcall(function()
        local y = raw:getPosFromXPointer(xp)
        local height = raw:getFullHeight()
        if type(y) ~= "number" or type(height) ~= "number" or height <= 0 then return nil end
        return y / height
    end)
    if not ok or type(value) ~= "number" or value ~= value then return nil end
    if value < 0 then value = 0 elseif value > 1 then value = 1 end
    return math.floor(value * 1e6 + 0.5) / 1e6
end

-- Numero de DocFragment (archivo del EPUB) de un XPointer de crengine.
function DocText.fragmentOf(xp)
    if type(xp) ~= "string" then return nil end
    return tonumber(xp:match("DocFragment%[(%d+)%]"))
end

return DocText

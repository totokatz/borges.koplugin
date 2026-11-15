--[[
LocatorNorm: la unica regla para decidir si dos textos de dos archivos (otro
lector, otra edicion, la web) son el mismo pasaje. La tabla sale de
shared/locatorFold.json (locatorfold.lua es generado) y la copia JS
(shared/locatorText.js) pasa los mismos vectores (shared/locatorVectors.json).

Sin `bit` ni `utf8`: aritmetica sobre string.byte, para LuaJIT y fengari.
Puro: no toca el documento ni el disco.
]]

local Fold = require("locatorfold")

local byte, sub, char = string.byte, string.sub, string.char
local concat = table.concat

local DROP, SEPARATORS, FOLD = Fold.drop, Fold.separators, Fold.fold

local LocatorNorm = { VERSION = Fold.version }

-- Decodifica el codepoint que empieza en el byte i. Devuelve (cp, siguiente).
-- Un byte invalido (o una secuencia sobrelarga o un surrogate) da cp = nil y
-- avanza un byte: cuenta como separador.
local function decode(s, i)
    local c = byte(s, i)
    if c < 0x80 then return c, i + 1 end
    local n, cp, min
    if c >= 0xC2 and c <= 0xDF then
        n, cp, min = 1, c - 0xC0, 0x80
    elseif c >= 0xE0 and c <= 0xEF then
        n, cp, min = 2, c - 0xE0, 0x800
    elseif c >= 0xF0 and c <= 0xF4 then
        n, cp, min = 3, c - 0xF0, 0x10000
    else
        return nil, i + 1
    end
    for k = 1, n do
        local cc = byte(s, i + k)
        if not cc or cc < 0x80 or cc > 0xBF then return nil, i + 1 end
        cp = cp * 64 + (cc - 0x80)
    end
    if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
        return nil, i + 1
    end
    return cp, i + n + 1
end

-- -> false (se elimina), true (separador) o la cadena que queda.
local function classify(s, i, cp, nexti)
    if cp == nil then return true end
    if cp < 0x80 then
        if (cp >= 0x61 and cp <= 0x7A) or (cp >= 0x30 and cp <= 0x39) then return char(cp) end
        if cp >= 0x41 and cp <= 0x5A then return char(cp + 32) end
        return true
    end
    if DROP[cp] then return false end
    if SEPARATORS[cp] then return true end
    local folded = FOLD[cp]
    if folded then return folded end
    return sub(s, i, nexti - 1)
end

function LocatorNorm.normalize(text)
    if type(text) ~= "string" or text == "" then return "" end
    local out, n = {}, 0
    local pending = false
    local i, len = 1, #text
    while i <= len do
        local cp, nexti = decode(text, i)
        local piece = classify(text, i, cp, nexti)
        if piece == true then
            pending = true
        elseif piece then
            if pending and n > 0 then
                n = n + 1
                out[n] = " "
            end
            pending = false
            n = n + 1
            out[n] = piece
        end
        i = nexti
    end
    return concat(out)
end

-- Cantidad de codepoints (un byte invalido cuenta como uno).
function LocatorNorm.length(s)
    if type(s) ~= "string" then return 0 end
    local count, i, len = 0, 1, #s
    while i <= len do
        local _, nexti = decode(s, i)
        count = count + 1
        i = nexti
    end
    return count
end

local function codepoints(s)
    local list, n = {}, 0
    local i, len = 1, #s
    while i <= len do
        local _, nexti = decode(s, i)
        n = n + 1
        list[n] = sub(s, i, nexti - 1)
        i = nexti
    end
    return list, n
end

function LocatorNorm.commonPrefix(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return 0 end
    local x, nx = codepoints(a)
    local y, ny = codepoints(b)
    local max = nx < ny and nx or ny
    local i = 0
    while i < max and x[i + 1] == y[i + 1] do i = i + 1 end
    return i
end

function LocatorNorm.commonSuffix(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return 0 end
    local x, nx = codepoints(a)
    local y, ny = codepoints(b)
    local max = nx < ny and nx or ny
    local i = 0
    while i < max and x[nx - i] == y[ny - i] do i = i + 1 end
    return i
end

-- Palabras del texto crudo, cada una con su forma normalizada y el separador
-- crudo que la precede: { {raw=, norm=, gap=}, ... }. Una corrida que sólo
-- tiene caracteres eliminados (un guion blando suelto) se suma al separador.
function LocatorNorm.words(raw)
    local words = {}
    if type(raw) ~= "string" or raw == "" then return words end
    local i, len = 1, #raw
    local gap_start = 1
    local word_start, pieces = nil, nil
    local function close(stop)
        if word_start then
            local norm = concat(pieces)
            if norm ~= "" then
                words[#words + 1] = {
                    raw = sub(raw, word_start, stop),
                    norm = norm,
                    gap = sub(raw, gap_start, word_start - 1),
                }
                gap_start = stop + 1
            end
            word_start, pieces = nil, nil
        end
    end
    while i <= len do
        local cp, nexti = decode(raw, i)
        local piece = classify(raw, i, cp, nexti)
        if piece == true then
            close(i - 1)
        else
            if not word_start then
                word_start, pieces = i, {}
            end
            if piece then pieces[#pieces + 1] = piece end
        end
        i = nexti
    end
    close(len)
    return words
end

-- El decodificador, para quien necesite recorrer UTF-8 con la misma regla.
LocatorNorm.decode = decode

return LocatorNorm

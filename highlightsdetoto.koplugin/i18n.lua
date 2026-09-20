--[[--
Traducción del plugin.

Los `msgid` del código están en inglés y el catálogo castellano vive en
`l10n/es.lua`. Este módulo reemplaza a `require("gettext")` dentro del plugin:
se usa igual (`_("text")`), pero decide el idioma solo.

Regla de idioma: el plugin habla el idioma de la interfaz de KOReader. Si ese
idioma empieza con `es` (es, es_AR, es-ES…) contesta en castellano; cualquier
otro —incluido el `C` con el que arranca KOReader cuando nadie eligió nada—
cae en inglés. No hay tercera opción: un idioma sin catálogo es inglés.

De dónde sale el idioma, en orden:
  1. `I18n.setLanguage(...)`, si alguien lo forzó (tests).
  2. `require("gettext").current_lang`, lo que KOReader está mostrando.
  3. `G_reader_settings:readSetting("language")`, por si gettext no lo expone.
  4. Nada de eso → inglés.

No se leen variables de entorno: en el aparato KOReader siempre sabe su idioma,
y leer `LANG` haría que la misma instalación hablara distinto según la máquina
que corre los tests.
]]

local I18n = {}

local CATALOGS = {
    es = "l10n/es",
}

local forced_language = nil
local loaded = {}

local function normalize(value)
    if type(value) ~= "string" then return nil end
    local lang = value:lower():match("^%s*([a-z][a-z][a-z]?)")
    if not lang then return nil end
    return lang
end

local function koreaderLanguage()
    local ok, gettext = pcall(require, "gettext")
    if ok and type(gettext) == "table" and type(gettext.current_lang) == "string" then
        return gettext.current_lang
    end
    -- G_reader_settings es global en KOReader; fuera de KOReader no existe.
    local settings = rawget(_G, "G_reader_settings")
    if settings and type(settings.readSetting) == "function" then
        local ok_setting, value = pcall(settings.readSetting, settings, "language")
        if ok_setting and type(value) == "string" then return value end
    end
    return nil
end

--- Idioma efectivo del plugin: "es" o "en".
function I18n.language()
    local raw = forced_language or koreaderLanguage()
    local lang = normalize(raw)
    if lang and CATALOGS[lang] then return lang end
    return "en"
end

--- Fuerza un idioma (nil vuelve a la detección automática). Pensado para tests.
function I18n.setLanguage(value)
    forced_language = value
end

local function catalog(lang)
    if loaded[lang] == nil then
        local module_name = CATALOGS[lang]
        local ok, table_or_err = pcall(require, module_name)
        if ok and type(table_or_err) == "table" then
            loaded[lang] = table_or_err
        else
            -- Un catálogo roto nunca rompe el plugin: se queda en inglés.
            loaded[lang] = false
        end
    end
    return loaded[lang] or nil
end

--- Traduce un msgid. Sin traducción devuelve el msgid, que es el inglés.
function I18n.translate(msgid)
    if type(msgid) ~= "string" then return msgid end
    local lang = I18n.language()
    if lang == "en" then return msgid end
    local entries = catalog(lang)
    local translated = entries and entries[msgid]
    if type(translated) == "string" and translated ~= "" then
        return translated
    end
    return msgid
end

setmetatable(I18n, {
    __call = function(_, msgid)
        return I18n.translate(msgid)
    end,
})

return I18n

-- El traductor propio del plugin (i18n.lua) sigue el idioma de KOReader; si
-- todavía no está en el package.path cuando KOReader lee este archivo, se cae
-- al gettext de KOReader, que devuelve el inglés tal cual.
local ok, i18n = pcall(require, "i18n")
local _ = ok and i18n or require("gettext")
return {
    -- `name` es la identidad interna del plugin: la usan las rutas de
    -- instalación, el actualizador y los backups. No cambia.
    name = "highlightsdetoto",
    fullname = _("Borges"),
    description = _("Pairs this reader with Borges Sync and durably synchronizes progress, reading sessions, statistics, highlights, notes, bookmarks, and canonical EPUB downloads. Includes offline replay, exact-edition annotation safety, and reversible verified updates."),
}

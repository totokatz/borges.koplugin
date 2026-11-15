-- Por que cambio la pantalla: el gesto de la persona (o el salto del plugin)
-- que llevo a cada PageUpdate/PosUpdate.
--
-- Cada metodo de navegacion de KOReader se envuelve con un before que deja una
-- marca en memoria y un after que la saca. PageUpdate/PosUpdate se emiten de
-- forma sincronica dentro del original (readerrolling.lua:1159, :1191), asi
-- que el handler de pagina ve la marca mientras existe. Gana la marca mas
-- externa: onGotoNextChapter llama a onGotoPage, y la causa es "chapter".
--
-- Camino caliente: un before/after solo asigna campos de esta tabla. Nada de
-- disco, red, temporizadores ni widgets; el unico llamado a UIManager
-- (isWidgetShown) ocurre en saltos de "goto", nunca al pasar pagina.
local Hooks = require("hooks")

local unpack = table.unpack or unpack
local function pack(...) return { n = select("#", ...), ... } end

local NavCause = {}
NavCause.__index = NavCause

NavCause.CAUSES = {
    "open", "wake", "next", "prev", "scroll", "chapter", "toc", "goto", "skim",
    "search", "bookmark", "link", "back", "forward", "rerender", "sync", "unknown",
}
local KNOWN = {}
for _, cause in ipairs(NavCause.CAUSES) do KNOWN[cause] = true end

function NavCause.isCause(value)
    return KNOWN[value] == true
end

local OWNER = "navcause"

local function byDiff(_, diff)
    diff = tonumber(diff)
    if not diff or diff == 0 then return nil end
    return diff > 0 and "next" or "prev"
end

-- { objeto de self.ui, metodo, causa fija o funcion(this, ...) -> causa }
-- Numeros de linea de KOReader v2026.03.
local TABLE = {
    { "rolling", "onGotoViewRel", byDiff },            -- readerrolling.lua:892
    { "rolling", "onGotoNextChapter", "chapter" },     -- :702
    { "rolling", "onGotoPrevChapter", "chapter" },     -- :723
    { "rolling", "onGotoPage", "goto" },               -- :754
    { "rolling", "onGotoRelativePage", "goto" },       -- :762
    { "rolling", "onGotoPercent", "goto" },            -- :747
    { "rolling", "onGotoXPointer", "goto" },           -- :770
    { "rolling", "onRestoreBookLocation", "back" },    -- :888
    { "rolling", "onUpdatePos", "rerender" },          -- :988
    { "paging", "onGotoViewRel", byDiff },             -- readerpaging.lua:565
    { "paging", "onGotoPageRel", byDiff },             -- :945
    { "paging", "onGotoPosRel", "scroll" },            -- :580
    { "paging", "onGotoPage", "goto" },                -- :1135
    { "paging", "onGotoRelativePage", "goto" },        -- :1154
    { "paging", "onGotoPercent", "goto" },             -- :554
    { "paging", "onGotoPercentage", "goto" },          -- :1170
    { "paging", "onGotoNextChapter", "chapter" },      -- :1179
    { "paging", "onGotoPrevChapter", "chapter" },      -- :1189
    { "paging", "onRestoreBookLocation", "back" },     -- :609
    { "link", "onGotoLink", "link" },                  -- readerlink.lua:836
    { "link", "onGoBackLink", "back" },                -- :984
    { "link", "onGoForwardLink", "forward" },          -- :1016
    { "back", "onBack", "back" },                      -- readerback.lua:117
    { "bookmark", "gotoBookmark", "bookmark" },        -- readerbookmark.lua:511
    { "search", "gotoResultsItem", "search" },         -- readersearch.lua:808
}

-- clock(): UIManager:getTime(), fijo durante una vuelta del bucle de eventos.
-- widgets: lo que responde isWidgetShown (UIManager); inyectable.
function NavCause.new(ui, clock, widgets)
    return setmetatable({
        ui = ui,
        clock = clock,
        widgets = widgets,
        pending = nil,
        pending_tick = nil,
        search_tick = nil,
        closed = false,
    }, NavCause)
end

function NavCause:_now()
    local ok, value = pcall(self.clock)
    if ok then return value end
    return nil
end

function NavCause:_isSkim()
    local gotopage = self.ui and self.ui.gotopage
    local skimto = gotopage and gotopage.skimto
    if not skimto then return false end
    local widgets = self.widgets
    if not widgets then
        local ok, uimanager = pcall(require, "ui/uimanager")
        if not ok then return false end
        widgets = uimanager
        self.widgets = widgets
    end
    return widgets:isWidgetShown(skimto) == true
end

-- Una marca puesta en otra vuelta del bucle es vieja: quedo de un original
-- que tiro error antes de que su after la sacara.
function NavCause:_live(now)
    return self.pending ~= nil and self.pending_tick == now
end

function NavCause:_mark(cause)
    if self.closed or not cause then return nil end
    local now = self:_now()
    if self:_live(now) then return nil end
    if (cause == "link" or cause == "goto") and self.search_tick ~= nil
        and self.search_tick == now then
        cause = "search"
    elseif cause == "goto" and self:_isSkim() then
        cause = "skim"
    end
    self.pending, self.pending_tick = cause, now
    return true
end

function NavCause:_clear(ctx)
    if ctx then self.pending, self.pending_tick = nil, nil end
end

function NavCause:_wrap(obj, method, cause, owner)
    local nav = self
    local before
    if type(cause) == "function" then
        before = function(this, ...) return nav:_mark(cause(this, ...)) end
    else
        before = function() return nav:_mark(cause) end
    end
    local after = function(_, ctx) nav:_clear(ctx) end
    return Hooks.wrapInstance(obj, method, before, after, owner or OWNER)
end

function NavCause:install()
    local ui = self.ui or {}
    local installed, missing = 0, 0
    local function count(ok)
        if ok then installed = installed + 1 else missing = missing + 1 end
    end
    for _, row in ipairs(TABLE) do
        count(self:_wrap(ui[row[1]], row[2], row[3]))
    end
    local nav = self
    -- La busqueda no envuelve el salto: lo hace ui.link:onGotoLink en el mismo
    -- callback (readersearch.lua:361, :425). Solo se anota la vuelta.
    count(Hooks.wrapInstance(ui.search, "search", function()
        if not nav.closed then nav.search_tick = nav:_now() end
    end, nil, OWNER))
    -- El indice crea su menu en cada apertura y lo guarda en self.toc_menu
    -- (readertoc.lua:1026); su onMenuSelect emite el salto (:977).
    count(Hooks.wrapInstance(ui.toc, "onShowToc", nil, function(this)
        if nav.closed then return end
        local menu = this and this.toc_menu
        if menu then nav:_wrap(menu, "onMenuSelect", "toc", "navcause.tocmenu") end
    end, OWNER))
    return installed, missing
end

-- Para los saltos del propio plugin: la marca se pone siempre (es la mas
-- externa por construccion) y se saca al salir, aunque fn tire error.
function NavCause:scoped(cause, fn, ...)
    local prev, prev_tick = self.pending, self.pending_tick
    self.pending, self.pending_tick = cause, self:_now()
    local results = pack(pcall(fn, ...))
    self.pending, self.pending_tick = prev, prev_tick
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
end

-- Lo llama el handler de pagina. No borra la marca: la saca el envoltorio
-- que la puso.
function NavCause:take(view_mode)
    if not self.closed and self:_live(self:_now()) then return self.pending end
    if view_mode == "scroll" then return "scroll" end
    return "unknown"
end

function NavCause:close()
    self.closed = true
    self.pending, self.pending_tick, self.search_tick = nil, nil, nil
end

return NavCause

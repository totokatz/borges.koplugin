-- ============================================================
-- C07 · El menú
--
-- El menú anterior era una lista plana de veinticinco entradas que mezclaba
-- siete maneras de sincronizar, el identificador interno del lector, el
-- cursor del protocolo, tres interruptores de automatismo y exportaciones a
-- Dropbox que no son parte del servicio. Para usarlo había que saber cómo
-- estaba hecho el plugin por dentro.
--
-- Acá el menú tiene cinco entradas y una sola acción principal:
--
--   Cuenta            quién sos
--   Sincronizar ahora la acción
--   Biblioteca        los libros y dónde ibas
--   Estado y ayuda    qué pasó y a quién preguntarle
--   Avanzado          lo que casi nadie necesita, intacto
--
-- Todo lo que había sigue existiendo: nada de lo que protege datos se sacó,
-- se movió a Avanzado o se fusionó dentro de la acción única. El mapa
-- completo, ítem por ítem, está en docs/koreader-plugin-v2.md.
--
-- El árbol se arma acá y no en main.lua para poder revisarlo en las pruebas
-- sin levantar KOReader: entra el plugin, sale una tabla.
--
-- C31 · Ninguna pregunta del menú puede tirar abajo KOReader. Las etiquetas,
-- los habilitados y los tildes se calculan cuando KOReader dibuja el submenú;
-- un error de Lua ahí no se atrapa en ningún lado y, en Android, reinicia la
-- aplicación entera. Por eso cada función que el árbol le entrega a KOReader
-- corre protegida: si falla, devuelve un valor de respaldo (la etiqueta fija,
-- apagado, sin tilde) y le pasa el rastro al plugin para que lo muestre y lo
-- registre. El menú sigue abriéndose y la persona puede llegar a «Reportar un
-- problema».
--
-- Y el separador va como bandera del ítem anterior (`separator = true`), que
-- es lo que KOReader espera: un `{ separator = true }` suelto se dibuja como
-- una fila vacía que se puede tocar.
-- ============================================================

local MenuTree = {}

--- Los cinco grupos, en orden. Las pruebas leen esta lista.
MenuTree.SECTIONS = { "cuenta", "sincronizar", "biblioteca", "estado", "avanzado" }

--- Vocabulario que el recorrido normal no puede usar. Si una de estas palabras
-- aparece fuera de Avanzado es que volvimos a pedirle al lector que entienda
-- el protocolo para poder sincronizar.
MenuTree.INTERNAL_WORDS = {
    "push", "pull", " v2", "sync v", " api", "api ", "endpoint",
    "cursor", "outbox", "inbox", "dropbox",
}

local function identity(value) return value end

local function defaultTemplate(pattern, ...)
    local values = { ... }
    return (tostring(pattern):gsub("%%(%d)", function(index)
        return tostring(values[tonumber(index)])
    end))
end

local function describeError(err)
    if type(err) == "table" then
        local parts = {}
        for key, value in pairs(err) do
            table.insert(parts, tostring(key) .. "=" .. tostring(value))
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(err)
end

--- Envuelve una función del árbol para que un error no salga de ella.
-- @param plugin table quien recibe el reporte (si sabe recibirlo)
-- @param what string nombre estable del punto que falló, para el reporte
-- @param fn function la pregunta al plugin
-- @param fallback lo que se devuelve si la pregunta falla
function MenuTree.guard(plugin, what, fn, fallback)
    return function()
        local ok, value = xpcall(fn, function(err)
            return describeError(err) .. "\n" .. debug.traceback("", 2)
        end)
        if ok then return value end
        if type(plugin.reportMenuError) == "function" then
            pcall(plugin.reportMenuError, plugin, what, value)
        end
        return fallback
    end
end

--- @param plugin table el plugin (o un doble de pruebas con la misma interfaz)
-- @param deps table {gettext, template}
function MenuTree.build(plugin, deps)
    deps = deps or {}
    local _ = deps.gettext or identity
    local T = deps.template or defaultTemplate

    -- Los cuatro tipos de pregunta, cada uno con su respaldo: una etiqueta
    -- fija, apagado, sin tilde, escondido. Un callback roto no devuelve nada.
    local function label(what, fallback, fn)
        return MenuTree.guard(plugin, what .. ".text", fn, fallback)
    end
    local function enabled(what, fn)
        return MenuTree.guard(plugin, what .. ".enabled", function() return fn() == true end, false)
    end
    local function checked(what, fn)
        return MenuTree.guard(plugin, what .. ".checked", function() return fn() == true end, false)
    end
    local function shown(what, fn)
        return MenuTree.guard(plugin, what .. ".show", function() return fn() == true end, false)
    end
    local function action(what, fn)
        return MenuTree.guard(plugin, what .. ".callback", fn, nil)
    end

    local function account()
        return {
            {
                text_func = label("cuenta.pair", _("Pair with a code"), function()
                    return plugin:getPairingLabel()
                end),
                keep_menu_open = true,
                enabled_func = enabled("cuenta.pair", function() return plugin:canPair() end),
                callback = action("cuenta.pair", function() plugin:startOrResumePairing() end),
            },
            {
                text_func = label("cuenta.connection", _("Sign in"), function()
                    return plugin:getConnectionLabel()
                end),
                keep_menu_open = true,
                callback = action("cuenta.connection", function() plugin:promptDeviceLogin() end),
            },
            {
                text = _("Sign out of this reader"),
                keep_menu_open = true,
                enabled_func = enabled("cuenta.signout", function() return plugin:hasCredential() end),
                callback = action("cuenta.signout", function() plugin:confirmSignOut() end),
            },
        }
    end

    local function library()
        return {
            {
                text = _("Download books from my library"),
                keep_menu_open = true,
                enabled_func = enabled("biblioteca.download", function() return plugin:hasAccountAccess() end),
                callback = action("biblioteca.download", function() plugin:showLibraryDownloadDialog() end),
            },
            {
                text_func = label("biblioteca.folder", _("Choose where to save books"), function()
                    return T(_("Save books to: %1"), plugin:getLibraryDownloadDir())
                end),
                keep_menu_open = true,
                callback = action("biblioteca.folder", function() plugin:configureLibraryDownloadDir() end),
                separator = true,
            },
            {
                -- Fusiona "Jump to latest server progress" y "Jump to other
                -- device progress": el lector no tiene por qué elegir entre
                -- dos formas de traer la misma posición.
                text = _("Continue where you left off on another device"),
                keep_menu_open = true,
                enabled_func = enabled("biblioteca.jump", function() return plugin:canJumpToRemotePosition() end),
                callback = action("biblioteca.jump", function() plugin:confirmRemotePositionJump() end),
            },
            {
                text_func = label("biblioteca.undo", _("Go back to where you were"), function()
                    return plugin:getUndoJumpLabel()
                end),
                keep_menu_open = true,
                enabled_func = enabled("biblioteca.undo", function() return plugin:canUndoPositionJump() end),
                callback = action("biblioteca.undo", function() plugin:undoPositionJump() end),
            },
        }
    end

    local function status()
        return {
            {
                text_func = label("estado.summary", _("Status: unavailable"), function()
                    return plugin:getSyncSummaryLabel()
                end),
                keep_menu_open = true,
                callback = action("estado.summary", function() plugin:showSyncStatusDetail() end),
            },
            {
                -- El único ajuste simple que queda. Gobierna los automatismos
                -- que antes eran tres interruptores separados.
                text = _("Sync automatically"),
                checked_func = checked("estado.autosync", function() return plugin:isAutoSyncEnabled() end),
                callback = action("estado.autosync", function() plugin:toggleAutoSync() end),
                separator = true,
            },
            {
                -- C13 · Reportar vive en «Estado y ayuda», al lado de lo que
                -- pasó, y no escondido en Avanzado: quien necesita avisar de un
                -- problema viene de mirar el estado, no de configurar nada.
                text = _("Report a problem"),
                keep_menu_open = true,
                callback = action("estado.report", function() plugin:showSupportHelp() end),
            },
            {
                text = _("Send technical failures automatically (no books or highlights)"),
                checked_func = checked("estado.diagnostics", function()
                    return plugin.diagnostics ~= nil and plugin.diagnostics:isEnabled()
                end),
                callback = action("estado.diagnostics", function() plugin:toggleDiagnostics() end),
            },
            {
                text = _("Help and details of this reader"),
                keep_menu_open = true,
                callback = action("estado.about", function() plugin:showAbout() end),
            },
        }
    end

    local function advanced()
        return {
            {
                text_func = label("avanzado.device", _("Name of this reader"), function()
                    return plugin:getDeviceIdLabel()
                end),
                keep_menu_open = true,
                callback = action("avanzado.device", function() plugin:configureDeviceId() end),
            },
            {
                text_func = label("avanzado.server", _("Server"), function()
                    return plugin:getServerLabel()
                end),
                keep_menu_open = true,
                callback = action("avanzado.server", function() plugin:configureWebUrl() end),
                separator = true,
            },
            {
                text = _("Resend all reading statistics"),
                keep_menu_open = true,
                enabled_func = enabled("avanzado.stats", function() return plugin:hasAccountAccess() end),
                callback = action("avanzado.stats", function() plugin:fullStatsDump() end),
            },
            {
                text_func = label("avanzado.queue", _("Save a copy of pending changes"), function()
                    return plugin:getQueueLabel()
                end),
                keep_menu_open = true,
                enabled_func = enabled("avanzado.queue", function() return plugin:hasQueuedWork() end),
                callback = action("avanzado.queue", function() plugin:exportPendingQueue(true) end),
            },
            {
                text = _("Discard pending changes without sending"),
                keep_menu_open = true,
                enabled_func = enabled("avanzado.discard", function() return plugin:hasQueuedWork() end),
                callback = action("avanzado.discard", function() plugin:confirmClearQueue() end),
                separator = true,
            },
            {
                text = _("Check for updates now"),
                keep_menu_open = true,
                enabled_func = enabled("avanzado.update", function() return plugin:hasAccountAccess() end),
                callback = action("avanzado.update", function() plugin:checkPluginUpdate(true) end),
            },
            {
                text_func = label("avanzado.rollback", _("Go back to the previous version"), function()
                    return plugin:getRollbackLabel()
                end),
                keep_menu_open = true,
                enabled_func = enabled("avanzado.rollback", function() return plugin:canRollbackPlugin() end),
                callback = action("avanzado.rollback", function() plugin:confirmPluginRollback() end),
            },
            {
                text = _("Tell me when a new version is out"),
                checked_func = checked("avanzado.autoupdate", function() return plugin:isAutoUpdateCheckEnabled() end),
                callback = action("avanzado.autoupdate", function() plugin:toggleAutoUpdateCheck() end),
            },
        }
    end

    local items = {
        {
            id = "cuenta",
            text = _("Account"),
            sub_item_table = account(),
        },
        {
            id = "sincronizar",
            -- La acción principal. Es directa: no abre un submenú y no compite
            -- con ninguna otra entrada que también sincronice.
            text_func = label("sincronizar", _("Sync now"), function()
                return plugin:getUnifiedSyncLabel()
            end),
            keep_menu_open = true,
            enabled_func = enabled("sincronizar", function() return not plugin:isSyncRunning() end),
            callback = action("sincronizar", function() plugin:runUnifiedSync() end),
        },
        {
            id = "biblioteca",
            text = _("Library"),
            sub_item_table = library(),
        },
        {
            id = "estado",
            text = _("Status and help"),
            sub_item_table = status(),
        },
        {
            id = "avanzado",
            text = _("Advanced"),
            sub_item_table = advanced(),
        },
        {
            -- C23 · Una versión nueva se ve en el menú de siempre, no escondida
            -- en Avanzado, y sigue ahí hasta que se instale: posponer el
            -- cartel no apaga el indicador. Mientras no haya nada que hacer,
            -- no ocupa lugar. Cuando ya se instaló pero falta reiniciar, la
            -- entrada lo dice: instalada no es lo mismo que cargada.
            id = "actualizacion",
            text_func = label("actualizacion", _("Check for updates now"), function()
                return plugin:getUpdateEntryLabel()
            end),
            keep_menu_open = true,
            show_func = shown("actualizacion", function() return plugin:hasUpdateEntry() end),
            enabled_func = enabled("actualizacion", function() return plugin:hasUpdateEntry() end),
            callback = action("actualizacion", function() plugin:installPendingUpdate() end),
        },
    }

    return {
        text = _("Borges"),
        sorting_hint = "tools",
        sub_item_table = items,
    }
end

--- Recorre las etiquetas visibles de una rama del árbol.
-- Lo usan las pruebas para revisar el vocabulario del recorrido normal.
function MenuTree.labels(items, collected)
    collected = collected or {}
    for _, item in ipairs(items or {}) do
        local text = item.text
        if text == nil and item.text_func then
            local ok, value = pcall(item.text_func)
            if ok then text = value end
        end
        if type(text) == "string" then table.insert(collected, text) end
        if item.sub_item_table then
            MenuTree.labels(item.sub_item_table, collected)
        end
    end
    return collected
end

--- Devuelve la entrada de primer nivel con ese id.
function MenuTree.section(tree, id)
    for _, item in ipairs(tree.sub_item_table or {}) do
        if item.id == id then return item end
    end
    return nil
end

return MenuTree

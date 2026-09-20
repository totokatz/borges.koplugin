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

--- @param plugin table el plugin (o un doble de pruebas con la misma interfaz)
-- @param deps table {gettext, template}
function MenuTree.build(plugin, deps)
    deps = deps or {}
    local _ = deps.gettext or identity
    local T = deps.template or defaultTemplate

    local function account()
        return {
            {
                text_func = function() return plugin:getPairingLabel() end,
                keep_menu_open = true,
                enabled_func = function() return plugin:canPair() end,
                callback = function() plugin:startOrResumePairing() end,
            },
            {
                text_func = function() return plugin:getConnectionLabel() end,
                keep_menu_open = true,
                callback = function() plugin:promptDeviceLogin() end,
            },
            {
                text = _("Sign out of this reader"),
                keep_menu_open = true,
                enabled_func = function() return plugin:hasCredential() end,
                callback = function() plugin:confirmSignOut() end,
            },

        }
    end

    local function library()
        return {
            {
                text = _("Download books from my library"),
                keep_menu_open = true,
                enabled_func = function() return plugin:hasAccountAccess() end,
                callback = function() plugin:showLibraryDownloadDialog() end,
            },
            {
                text_func = function()
                    return T(_("Save books to: %1"), plugin:getLibraryDownloadDir())
                end,
                keep_menu_open = true,
                callback = function() plugin:configureLibraryDownloadDir() end,
            },
            { separator = true },
            {
                -- Fusiona "Jump to latest server progress" y "Jump to other
                -- device progress": el lector no tiene por qué elegir entre
                -- dos formas de traer la misma posición.
                text = _("Continue where you left off on another device"),
                keep_menu_open = true,
                enabled_func = function() return plugin:canJumpToRemotePosition() end,
                callback = function() plugin:confirmRemotePositionJump() end,
            },
            {
                text_func = function() return plugin:getUndoJumpLabel() end,
                keep_menu_open = true,
                enabled_func = function() return plugin:canUndoPositionJump() end,
                callback = function() plugin:undoPositionJump() end,
            },
        }
    end

    local function status()
        return {
            {
                text_func = function() return plugin:getSyncSummaryLabel() end,
                keep_menu_open = true,
                callback = function() plugin:showSyncStatusDetail() end,
            },
            {
                -- El único ajuste simple que queda. Gobierna los automatismos
                -- que antes eran tres interruptores separados.
                text = _("Sync automatically"),
                checked_func = function() return plugin:isAutoSyncEnabled() end,
                callback = function() plugin:toggleAutoSync() end,
            },
            { separator = true },
            {
                -- C13 · Reportar vive en «Estado y ayuda», al lado de lo que
                -- pasó, y no escondido en Avanzado: quien necesita avisar de un
                -- problema viene de mirar el estado, no de configurar nada.
                text = _("Report a problem"),
                keep_menu_open = true,
                callback = function() plugin:showSupportHelp() end,
            },
            {
                text = _("Send technical failures automatically (no books or highlights)"),
                checked_func = function() return plugin.diagnostics and plugin.diagnostics:isEnabled() end,
                callback = function() plugin:toggleDiagnostics() end,
            },
            {
                text = _("Help and details of this reader"),
                keep_menu_open = true,
                callback = function() plugin:showAbout() end,
            },
        }
    end

    local function advanced()
        return {
            {
                text_func = function() return plugin:getDeviceIdLabel() end,
                keep_menu_open = true,
                callback = function() plugin:configureDeviceId() end,
            },
            {
                text_func = function() return plugin:getServerLabel() end,
                keep_menu_open = true,
                callback = function() plugin:configureWebUrl() end,
            },
            { separator = true },
            {
                text = _("Resend all reading statistics"),
                keep_menu_open = true,
                enabled_func = function() return plugin:hasAccountAccess() end,
                callback = function() plugin:fullStatsDump() end,
            },
            {
                text_func = function() return plugin:getQueueLabel() end,
                keep_menu_open = true,
                enabled_func = function() return plugin:hasQueuedWork() end,
                callback = function() plugin:exportPendingQueue(true) end,
            },
            {
                text = _("Discard pending changes without sending"),
                keep_menu_open = true,
                enabled_func = function() return plugin:hasQueuedWork() end,
                callback = function() plugin:confirmClearQueue() end,
            },
            { separator = true },
            {
                text = _("Check for updates now"),
                keep_menu_open = true,
                enabled_func = function() return plugin:hasAccountAccess() end,
                callback = function() plugin:checkPluginUpdate(true) end,
            },
            {
                text_func = function() return plugin:getRollbackLabel() end,
                keep_menu_open = true,
                enabled_func = function() return plugin:canRollbackPlugin() end,
                callback = function() plugin:confirmPluginRollback() end,
            },
            {
                text = _("Tell me when a new version is out"),
                checked_func = function() return plugin:isAutoUpdateCheckEnabled() end,
                callback = function() plugin:toggleAutoUpdateCheck() end,
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
            text_func = function() return plugin:getUnifiedSyncLabel() end,
            keep_menu_open = true,
            enabled_func = function() return not plugin:isSyncRunning() end,
            callback = function() plugin:runUnifiedSync() end,
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
            text_func = function() return plugin:getUpdateEntryLabel() end,
            keep_menu_open = true,
            show_func = function() return plugin:hasUpdateEntry() end,
            enabled_func = function() return plugin:hasUpdateEntry() end,
            callback = function() plugin:installPendingUpdate() end,
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

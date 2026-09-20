-- ============================================================
-- C07 · Una sola sincronización
--
-- Antes el menú ofrecía siete formas de sincronizar: "Run Borges Sync v2 now",
-- "Sync progress now", "Sync all highlights to web", "Sync current book
-- highlights", "Pull current book highlights from web", "Sync current book
-- highlights both ways" y el drenaje escondido dentro de "Sync status". Cada
-- una movía una parte distinta y ninguna decía qué había quedado afuera, así
-- que para estar tranquilo había que tocarlas todas y en el orden correcto.
--
-- Este módulo es la operación única que las reemplaza en el recorrido normal.
-- No inventa un motor de sync nuevo: recibe los pasos ya existentes y se ocupa
-- de lo que faltaba — ordenarlos, contar lo que salió y entró, distinguir
-- "todo al día" de "quedó pendiente" y de "falló una parte", y no permitir dos
-- corridas simultáneas.
--
-- Vive separado de main.lua porque main.lua sólo se puede cargar dentro de
-- KOReader. Acá no hay widgets ni red: entran funciones, sale un informe.
-- ============================================================

local SyncRun = {}
SyncRun.__index = SyncRun

--- Todo terminó y el servidor confirmó cada cosa.
SyncRun.SYNCED = "synced"
--- Quedó trabajo guardado esperando red. No es un error.
SyncRun.QUEUED = "queued"
--- Hubo red pero al menos un paso falló. NUNCA se muestra como "todo al día".
SyncRun.PARTIAL = "partial"
--- No había red: lo nuevo se guardó y nada se perdió.
SyncRun.OFFLINE = "offline"
--- No hay sesión: sincronizar no significa nada todavía.
SyncRun.DISCONNECTED = "disconnected"
--- Había red y sesión, y no entró nada. El error es lo único que importa.
SyncRun.FAILED = "failed"

local function toCount(value)
    local number = tonumber(value)
    if not number or number ~= number then return 0 end
    if number < 0 then return 0 end
    return math.floor(number)
end

local function errorMessage(err)
    if err == nil then return nil end
    if type(err) == "table" then
        return err.message or err.code or "error"
    end
    return tostring(err)
end

function SyncRun:new(options)
    options = options or {}
    return setmetatable({
        running = false,
        now = options.now or os.time,
        last_report = nil,
    }, self)
end

--- ¿Hay una corrida en curso? Lo consulta el menú para no arrancar otra.
function SyncRun:isRunning()
    return self.running == true
end

function SyncRun:getLastReport()
    return self.last_report
end

--- Corre el plan completo.
--
-- @param plan table {connected=bool, online=bool, steps={...}, pending=fn}
--   Cada paso es {id, label, run, offline=bool}. `run` devuelve `result, err`;
--   `result` puede traer sent/received/pending/deferred. Un paso marcado
--   `offline = true` es el que sólo guarda en la cola y por eso también corre
--   sin red: es lo que hace que lo de hoy no se pierda hasta la reconexión.
-- @param options table {on_progress = fn({index, total, label})}
-- @return table informe, o nil + "already_running" si ya había una corrida.
function SyncRun:run(plan, options)
    if self.running then return nil, "already_running" end
    self.running = true
    local ok, report = pcall(self._execute, self, plan or {}, options or {})
    self.running = false
    if not ok then
        report = {
            status = SyncRun.FAILED,
            sent = 0,
            received = 0,
            pending = 0,
            deferred = 0,
            failed = {},
            error = { code = "plugin_error", message = errorMessage(report) },
            at = self.now(),
        }
    end
    self.last_report = report
    return report
end

function SyncRun:_execute(plan, options)
    local progress = options.on_progress
    local steps = plan.steps or {}
    local report = {
        sent = 0,
        received = 0,
        pending = 0,
        deferred = 0,
        failed = {},
        succeeded = 0,
        ran = 0,
        at = self.now(),
    }

    if not plan.connected then
        report.status = SyncRun.DISCONNECTED
        report.pending = toCount(plan.pending and plan.pending())
        return report
    end

    local offline = plan.online == false
    -- Sin red igual corren los pasos que sólo escriben en la cola. Es la
    -- diferencia entre "no se pudo" y "quedó anotado para cuando vuelva".
    local eligible = {}
    for _, step in ipairs(steps) do
        if not offline or step.offline then table.insert(eligible, step) end
    end

    for index, step in ipairs(eligible) do
        if progress then
            progress({ index = index, total = #eligible, label = step.label, id = step.id })
        end
        local result, err = step.run()
        report.ran = report.ran + 1
        if result == nil then
            table.insert(report.failed, {
                id = step.id,
                label = step.label,
                code = type(err) == "table" and err.code or nil,
                http_status = type(err) == "table" and err.http_status or nil,
                message = errorMessage(err),
                request_id = type(err) == "table" and err.request_id or nil,
                retryable = type(err) == "table" and err.retryable == true or false,
            })
        else
            report.succeeded = report.succeeded + 1
            if type(result) == "table" then
                report.sent = report.sent + toCount(result.sent)
                report.received = report.received + toCount(result.received)
                report.deferred = report.deferred + toCount(result.deferred)
            end
        end
    end

    report.pending = toCount(plan.pending and plan.pending())

    if offline then
        report.status = SyncRun.OFFLINE
        return report
    end
    if #report.failed > 0 then
        report.error = report.failed[1]
        -- "Sincronicé una parte" sólo si algo se movió de verdad. Guardar en
        -- disco salió bien casi siempre y no es sincronizar: contarlo como
        -- éxito parcial le diría al lector que llegó algo al servidor cuando
        -- no llegó nada.
        local moved = report.sent > 0 or report.received > 0
        report.status = moved and SyncRun.PARTIAL or SyncRun.FAILED
        return report
    end
    report.status = report.pending > 0 and SyncRun.QUEUED or SyncRun.SYNCED
    return report
end

--- ¿Esta corrida deja al lector al día con el servidor?
-- Sólo entonces se puede tocar la marca de "última sincronización completa".
function SyncRun.isComplete(report)
    return report ~= nil and report.status == SyncRun.SYNCED
end

-- ============================================================
-- El texto final
--
-- Tiene que contestar tres preguntas sin pedirle al lector que interprete
-- números sueltos: qué pasó recién, qué se movió, y qué falta. El "qué falta"
-- nunca desaparece cuando hubo una falla: ese era justo el modo en que el menú
-- viejo mentía — decía "Synced!" aunque el batch hubiera devuelto errores.
-- ============================================================

--- @param report table informe devuelto por `run`
-- @param context table {gettext=fn, template=fn, describe_time=fn, last_success=epoch}
function SyncRun.describe(report, context)
    context = context or {}
    local _ = context.gettext or function(value) return value end
    local T = context.template or function(pattern, ...)
        local values = { ... }
        return (pattern:gsub("%%(%d)", function(index)
            return tostring(values[tonumber(index)])
        end))
    end
    if report == nil then return _("You have not synced on this reader yet.") end

    local lines = {}
    if report.status == SyncRun.DISCONNECTED then
        table.insert(lines, _("Sign in to your account to sync."))
    elseif report.status == SyncRun.OFFLINE then
        table.insert(lines, _("No connection. Today's reading is saved and will be sent when Wi-Fi returns."))
    elseif report.status == SyncRun.PARTIAL then
        table.insert(lines, _("Partly synced. There is still more to finish."))
    elseif report.status == SyncRun.FAILED then
        table.insert(lines, _("Could not sync. Nothing was lost: it is still saved on this reader."))
    elseif report.status == SyncRun.QUEUED then
        table.insert(lines, _("Synced. Something is still on its way."))
    else
        table.insert(lines, _("Everything up to date."))
    end

    if report.status ~= SyncRun.DISCONNECTED then
        table.insert(lines, T(_("Sent: %1 · Received: %2"),
            toCount(report.sent), toCount(report.received)))
    end

    local pending = toCount(report.pending)
    if pending > 0 then
        table.insert(lines, T(_("Pending: %1"), pending))
    end

    if report.error then
        local detail = report.error.message or report.error.code or _("unknown error")
        table.insert(lines, T(_("Details: %1"), detail))
        if report.error.request_id then
            table.insert(lines, T(_("Support reference: %1"), report.error.request_id))
        end
    end

    local last_success = context.last_success
    if last_success and last_success > 0 and context.describe_time then
        table.insert(lines, T(_("Last complete sync: %1"),
            context.describe_time(last_success)))
    elseif not SyncRun.isComplete(report) and not last_success then
        table.insert(lines, _("Last complete sync: none yet"))
    end

    return table.concat(lines, "\n")
end

return SyncRun

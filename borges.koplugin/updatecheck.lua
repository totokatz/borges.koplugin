-- ============================================================
-- C23 · Cuándo se pregunta por una versión nueva, y cuándo se avisa
--
-- El chequeo anterior vivía dentro de `init`: corría una vez por arranque,
-- podía pedir el Wi-Fi, y anotaba la fecha del intento aunque el intento
-- hubiera fallado. Con eso, un lector sin red al abrir KOReader se quedaba
-- veinticuatro horas sin volver a preguntar, y otro con la red intermitente
-- preguntaba en cada rebote.
--
-- Acá vive la decisión y sólo la decisión: entra el estado, sale si
-- corresponde preguntar y por qué no. No hay red, ni widgets, ni reloj
-- propio — el que llama pasa `now`. Así se puede probar sin KOReader.
--
-- Cuatro fechas distintas, que antes eran una sola:
--
--   last_success_at  el último chequeo que efectivamente contestó
--   last_attempt_at  el último intento, haya contestado o no
--   failures         intentos fallidos seguidos desde el último éxito
--   notified_version la versión que el lector ya vio anunciada
--
-- Mezclarlas es lo que hacía que un fallo valiera como respuesta.
-- ============================================================

local UpdateCheck = {}

--- Un chequeo exitoso por día. No hay apuro: una versión nueva del plugin no
-- es urgente y preguntar más seguido sólo gasta batería y datos.
UpdateCheck.CHECK_INTERVAL = 86400

--- Primer reintento tras un fallo. Se duplica con cada fallo seguido.
UpdateCheck.RETRY_BASE = 900

--- Techo del reintento: seis horas. Más allá de eso el espaciado deja de
-- distinguirse de "esperar al próximo día".
UpdateCheck.RETRY_MAX = 21600

--- Después de esta cantidad de fallos seguidos se deja de reintentar solo.
-- El servidor caído, el DNS del hotel o una cuenta revocada no mejoran
-- porque insistamos: queda la búsqueda manual, y el ciclo se reabre cuando
-- pasa un día entero desde el último intento.
UpdateCheck.MAX_FAILURES = 6

UpdateCheck.OK = "ok"
UpdateCheck.FORCED = "forced"
UpdateCheck.DISABLED = "disabled"
UpdateCheck.NOT_CONFIGURED = "not_configured"
UpdateCheck.OFFLINE = "offline"
UpdateCheck.IN_FLIGHT = "in_flight"
UpdateCheck.RECENT_SUCCESS = "recent_success"
UpdateCheck.RETRY_BACKOFF = "retry_backoff"
UpdateCheck.RETRY_EXHAUSTED = "retry_exhausted"

local function toEpoch(value)
    if type(value) ~= "number" then return 0 end
    if value ~= value or value < 0 then return 0 end -- NaN o basura
    return math.floor(value)
end

local function toCount(value)
    if type(value) ~= "number" or value ~= value or value < 0 then return 0 end
    return math.floor(value)
end

--- Devolver las fechas guardadas en términos del reloj de ahora.
--
-- El reloj de un Kobo se corrige solo al conectarse, y puede saltar hacia
-- atrás meses. Una fecha guardada en el futuro no prueba nada: significa que
-- el reloj de entonces o el de ahora está mal. En vez de quedarnos esperando
-- un día que nunca llega, la descartamos y dejamos que el próximo momento
-- oportuno vuelva a preguntar.
-- @return table {last_success_at, last_attempt_at, failures, clock_reset}
function UpdateCheck.normalize(state, now)
    now = toEpoch(now)
    local success = toEpoch(state and state.last_success_at)
    local attempt = toEpoch(state and state.last_attempt_at)
    local failures = toCount(state and state.failures)
    local clock_reset = false

    if success > now then
        success, clock_reset = 0, true
    end
    if attempt > now then
        attempt, clock_reset = 0, true
    end
    -- El intento nunca puede ser anterior al éxito que lo incluyó.
    if success > attempt then attempt = success end
    if failures == 0 then attempt = math.min(attempt, success) end

    return {
        last_success_at = success,
        last_attempt_at = attempt,
        failures = failures,
        clock_reset = clock_reset,
    }
end

--- Cuánto hay que esperar después de `failures` fallos seguidos.
function UpdateCheck.retryDelay(failures)
    failures = toCount(failures)
    if failures <= 0 then return 0 end
    local delay = UpdateCheck.RETRY_BASE
    for _index = 2, failures do
        delay = delay * 2
        if delay >= UpdateCheck.RETRY_MAX then return UpdateCheck.RETRY_MAX end
    end
    return math.min(delay, UpdateCheck.RETRY_MAX)
end

--- ¿Corresponde preguntarle al servidor ahora?
--
-- @param state table {enabled, configured, connected, running, now,
--   last_success_at, last_attempt_at, failures, manual}
-- @return table {allowed=boolean, reason=string, retry_in=number|nil}
function UpdateCheck.plan(state)
    state = state or {}
    local now = toEpoch(state.now)
    local anchors = UpdateCheck.normalize(state, now)

    -- Una corrida en curso gana siempre, incluso contra la acción manual:
    -- dos pedidos encimados son exactamente lo que no queremos.
    if state.running == true then
        return { allowed = false, reason = UpdateCheck.IN_FLIGHT }
    end
    if state.configured ~= true then
        return { allowed = false, reason = UpdateCheck.NOT_CONFIGURED }
    end

    -- La búsqueda manual es una orden: salta el intervalo y el backoff. Lo
    -- único que no saltea es no tener con quién hablar.
    if state.manual == true then
        return { allowed = true, reason = UpdateCheck.FORCED }
    end

    if state.enabled ~= true then
        return { allowed = false, reason = UpdateCheck.DISABLED }
    end
    -- El chequeo automático nunca prende la radio: si no hay red, no hay
    -- pregunta. Leer no puede costar una pantalla de Wi-Fi.
    if state.connected ~= true then
        return { allowed = false, reason = UpdateCheck.OFFLINE }
    end

    if anchors.failures >= UpdateCheck.MAX_FAILURES then
        local since = now - anchors.last_attempt_at
        if since < UpdateCheck.CHECK_INTERVAL then
            return {
                allowed = false,
                reason = UpdateCheck.RETRY_EXHAUSTED,
                retry_in = UpdateCheck.CHECK_INTERVAL - since,
            }
        end
        return { allowed = true, reason = UpdateCheck.OK }
    end

    if anchors.failures > 0 then
        local delay = UpdateCheck.retryDelay(anchors.failures)
        local since = now - anchors.last_attempt_at
        if since < delay then
            return {
                allowed = false,
                reason = UpdateCheck.RETRY_BACKOFF,
                retry_in = delay - since,
            }
        end
        return { allowed = true, reason = UpdateCheck.OK }
    end

    local since = now - anchors.last_success_at
    if anchors.last_success_at > 0 and since < UpdateCheck.CHECK_INTERVAL then
        return {
            allowed = false,
            reason = UpdateCheck.RECENT_SUCCESS,
            retry_in = UpdateCheck.CHECK_INTERVAL - since,
        }
    end
    return { allowed = true, reason = UpdateCheck.OK }
end

--- El estado después de un chequeo que contestó.
function UpdateCheck.recordSuccess(state, now)
    now = toEpoch(now)
    return { last_success_at = now, last_attempt_at = now, failures = 0 }
end

--- El estado después de un chequeo que no contestó.
--
-- Anotar el intento SIN tocar el último éxito es el punto: antes un fallo
-- corría la fecha un día entero hacia adelante y el lector se quedaba sin
-- avisos hasta el día siguiente.
function UpdateCheck.recordFailure(state, now)
    now = toEpoch(now)
    local anchors = UpdateCheck.normalize(state, now)
    return {
        last_success_at = anchors.last_success_at,
        last_attempt_at = now,
        failures = math.min(anchors.failures + 1, UpdateCheck.MAX_FAILURES),
    }
end

--- Comparar dos versiones del plugin. Devuelve <0, 0 o >0.
-- Misma cuenta que hace `updater.lua`: cada tramo numérico por separado.
function UpdateCheck.compareVersions(a, b)
    local left, right = {}, {}
    for part in tostring(a or ""):gmatch("[^%.%-]+") do
        table.insert(left, tonumber(part) or 0)
    end
    for part in tostring(b or ""):gmatch("[^%.%-]+") do
        table.insert(right, tonumber(part) or 0)
    end
    for index = 1, math.max(#left, #right) do
        local delta = (left[index] or 0) - (right[index] or 0)
        if delta ~= 0 then return delta end
    end
    return 0
end

--- ¿Esta versión encontrada es noticia?
--
-- No lo es si no hay ninguna, si es la que ya está instalada, si es más vieja
-- que la instalada —un servidor que retrocedió no es una actualización— o si
-- el lector ya la vio anunciada. Posponer no borra el indicador del menú,
-- pero sí apaga el cartel: la respuesta vale hasta que salga otra versión.
--
-- @param context table {available, current, notified}
function UpdateCheck.shouldAnnounce(context)
    context = context or {}
    local available = context.available
    if type(available) ~= "string" or available == "" then return false end
    local current = context.current
    if type(current) == "string" and current ~= ""
        and UpdateCheck.compareVersions(available, current) <= 0 then
        return false
    end
    if context.notified == available then return false end
    return true
end

--- ¿Es este un momento en el que el cartel no molesta?
--
-- Dos, y sólo dos: el menú abierto y el explorador de archivos. Un aviso
-- disparado por la red en medio de una página tapa lo que el lector está
-- leyendo, y uno encima de la pregunta de posición de otro lector le cambia
-- la respuesta a algo que ya decidió. Cuando no se puede, no se pierde nada:
-- el indicador del menú sigue ahí y el cartel sale la próxima vez.
--
-- @param context table {trigger, book_open, resume_dialog}
function UpdateCheck.isSafeMoment(context)
    context = context or {}
    if context.resume_dialog == true then return false, "resume_dialog" end
    if context.trigger == "menu" then return true end
    if context.book_open == true then return false, "reading" end
    return true
end

-- El filtro de prereleases NO vive acá: vive en `updater.lua`, que se
-- descarga solo durante un arranque en frío y no puede depender de este
-- módulo. Si lo necesitás, pedilo como `Updater.isStableVersion`.

return UpdateCheck

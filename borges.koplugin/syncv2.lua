local SyncV2 = {}
SyncV2.__index = SyncV2

local function resolve(value)
    return type(value) == "function" and value() or value
end

--- `server_time` del servidor (ISO 8601 en UTC) a segundos epoch, sin pasar
-- por `os.time`, que interpretaria la fecha en el huso del aparato.
function SyncV2.parseServerTime(iso)
    if type(iso) ~= "string" then return nil end
    local y, mo, d, h, mi, s = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?%d*Z$")
    if not y then return nil end
    y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
    if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60 then return nil end
    -- Dias desde 1970-01-01 (algoritmo de calendario civil de H. Hinnant).
    local year = mo <= 2 and y - 1 or y
    local era = math.floor(year / 400)
    local yoe = year - era * 400
    local mp = (mo + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + h * 3600 + mi * 60 + s
end

--- Cuanto esta corrido el reloj de este lector respecto del servidor. Se
-- anota diferido: sale con el guardado del mismo intercambio.
function SyncV2:_noteServerTime(response)
    local server = type(response) == "table" and SyncV2.parseServerTime(response.server_time)
    if server and self.queue.setClockSkew then
        self.queue:setClockSkew(server - os.time())
    end
end

function SyncV2:new(options)
    options = options or {}
    assert(options.web_api, "web_api is required")
    assert(options.queue, "queue is required")
    return setmetatable({
        web_api = options.web_api,
        queue = options.queue,
        base_url = options.base_url,
        auth = options.auth,
        client = options.client or function() return {} end,
        apply_event = options.apply_event,
        on_reading_head = options.on_reading_head,
        reading_context = options.reading_context,
        pull_limit = options.pull_limit or 20,
    }, self)
end

function SyncV2:getBaseUrl()
    return tostring(resolve(self.base_url) or ""):gsub("/+$", "")
end

function SyncV2:getAuth()
    return resolve(self.auth)
end

function SyncV2:getCapabilities()
    return self.web_api:getJSON(
        self:getBaseUrl() .. "/api/sync/v2/capabilities",
        self:getAuth(),
        true
    )
end

function SyncV2:actOnSuggestion(suggestion_id, action)
    assert(action == "accept" or action == "dismiss", "invalid suggestion action")
    return self.web_api:postJSON(
        self:getBaseUrl() .. "/api/sync/v2/suggestions/"
            .. tostring(suggestion_id) .. "/" .. action,
        self:getAuth(),
        {},
        true
    )
end

--- C17 · Traer lo del servidor SIN subir nada.
--
-- `sync()` manda el outbox cuando tiene algo, y eso al reconectar es el orden
-- equivocado: la posición vieja de este lector llega primero, queda como la
-- última escritura y la del otro aparato ya no se ofrece. Este pull mira y no
-- toca: si falla, el outbox queda intacto para el drenaje que viene después.
-- Una consulta enfocada a la vez: quien quiere preguntar mientras otra esta en
-- vuelo (por ejemplo un envio periodico durante la consulta del despertar)
-- espera su resultado en vez de cruzarse con ella. `focus_in_flight` lo mira
-- `_resolveHeldProgress`.
function SyncV2:pull(quick, focus_book, focus_only, context)
    if not focus_only then return self:_pull(quick, focus_book, focus_only, context) end
    self.focus_in_flight = (self.focus_in_flight or 0) + 1
    self.focus_started_at = os.time()
    local ok, result, err = pcall(self._pull, self, quick, focus_book, focus_only, context)
    self.focus_in_flight = math.max(0, self.focus_in_flight - 1)
    if not ok then error(result, 0) end
    return result, err
end

function SyncV2:_pull(quick, focus_book, focus_only, context)
    -- `context` lo pasa quien consulta un libro que no es el abierto.
    local reading_context = focus_only and (context or resolve(self.reading_context)) or nil
    -- F5 · El libro que se pregunta (titulo y archivo): con dos libros del
    -- mismo hash, el servidor contesta la cabeza de ESE. Un servidor viejo la
    -- ignora.
    -- Quien pregunta por otro libro (uno cerrado) trae su propio contexto: la
    -- pista del libro abierto no vale para ese.
    local hint_context = focus_book and (context or resolve(self.reading_context)) or nil
    local focus_hint = type(hint_context) == "table" and type(hint_context.hint) == "table"
        and (hint_context.hint.title or hint_context.hint.file) and hint_context.hint or nil
    local response, err = self.web_api:postJSON(
        self:getBaseUrl() .. "/api/sync/v2/pull",
        self:getAuth(),
        {
            protocol_version = 2,
            cursor = self.queue:getCursor(),
            limit = self.pull_limit,
            focus_book = focus_book,
            focus_hint = focus_hint,
            focus_only = focus_only == true or nil,
            client = resolve(self.client) or {},
        },
        -- Tal cual: `"sleep"` pide los plazos del intercambio de dormir.
        quick
    )
    if not response then
        self.queue:setLastError(err)
        return nil, err
    end
    if response.protocol_version ~= 2 then
        local protocol_err = self.web_api.apiError(
            "unsupported_protocol_response",
            "Server did not return Borges v2.",
            nil,
            false,
            response.request_id
        )
        self.queue:setLastError(protocol_err)
        return nil, protocol_err
    end

    self:_noteServerTime(response)
    -- Sin acuses no se descarta ni un evento del outbox: `commitExchange` sólo
    -- agrega al inbox y mueve el cursor.
    response.acknowledgements = {}
    local committed, commit_err = self.queue:commitExchange(response,
        (not focus_only or not self.on_reading_head) and self.apply_event or nil)
    if not committed then
        local local_err = self.web_api.apiError(
            commit_err,
            "Could not durably apply the sync response.",
            nil,
            false
        )
        self.queue:setLastError(local_err)
        return nil, local_err
    end
    if focus_only and self.on_reading_head then
        local ready, reason = self.on_reading_head(response.pull or response, reading_context)
        if not ready then
            local head_err = self.web_api.apiError(reason or "reading_head_invalid",
                "Could not confirm the last reading. Local progress remains saved.", nil, true)
            self.queue:setLastError(head_err)
            return nil, head_err
        end
    end

    if focus_only and self.on_reading_head then
        local event = (response.pull or response).focus_event
        if type(event) == "table" and self.apply_event then
            local action = self.apply_event(event)
            if action == true then self.queue:removeInboxEvent(event.event_id, true) end
            -- Lo que `apply_event` dejo pendiente sale aca, en un guardado.
            self.queue:flush("consume")
        end
    end
    committed.sent = 0
    return committed
end

--- Pull paginado hasta agotar lo pendiente del servidor. Media página no
-- alcanza: la posición que busca el lector puede estar en la siguiente.
function SyncV2:pullAll(max_pages, quick, focus_book)
    max_pages = max_pages or 8
    local summary = { pages = 0, received = 0, deferred = 0, sent = 0 }
    for page = 1, max_pages do
        local result, err = self:pull(quick, page == 1 and focus_book or nil)
        if not result then
            -- Lo ya traído quedó committeado; el error se informa igual para
            -- que quien llama no siga con el drenaje como si nada.
            summary.error = err
            return nil, err, summary
        end
        summary.pages = page
        summary.received = summary.received + (result.received or 0)
        summary.deferred = summary.deferred + (result.deferred or 0)
        summary.cursor = result.cursor
        summary.pending = result.pending
        summary.has_more = result.has_more == true
        if not result.has_more then break end
    end
    return summary
end

function SyncV2:enqueue(event, options)
    return self.queue:enqueueEvent(event, options)
end

--- Un intercambio. `quick` viaja tal cual a la red (`"sleep"` pide los plazos de
-- dormir). `options` acota el lote para quien tiene apuro:
--   max_events, max_bytes  tope del lote (por defecto los de la cola)
--   priority               `event_type` que se eligen primero
--   max_recoveries         recuperaciones en total; sin el, la regla de siempre
--   deadline               epoch: ningun pedido (ni reintento) empieza despues
function SyncV2:sync(force, quick, options)
    options = type(options) == "table" and options or {}
    local batch_options = options.priority and { priority = options.priority } or nil
    local function prepare(force_batch)
        return self.queue:prepareBatch(options.max_events, options.max_bytes, force_batch, batch_options)
    end
    local events = prepare(force)
    local url, payload
    if #events > 0 then
        url = self:getBaseUrl() .. "/api/sync/v2/exchange"
        payload = {
            protocol_version = 2,
            cursor = self.queue:getCursor(),
            events = events,
            client = resolve(self.client) or {},
        }
    else
        url = self:getBaseUrl() .. "/api/sync/v2/pull"
        payload = {
            protocol_version = 2,
            cursor = self.queue:getCursor(),
            limit = self.pull_limit,
            client = resolve(self.client) or {},
        }
    end

    local response, err = self.web_api:postJSON(url, self:getAuth(), payload, quick)
    -- Recuperaciones acotadas: una de secuencias por lote (los aceptados del
    -- lote conservan id/secuencia y reciben un ACK duplicado) y una por cada
    -- evento que el servidor nombre en un idempotency_conflict. Con
    -- `max_recoveries`, ademas, un tope total: al dormir la pantalla espera.
    local max_recoveries = tonumber(options.max_recoveries)
    local sequences_recovered, reissued, recoveries = false, 0, 0
    -- `options.deadline` (epoch): pasado ese momento no empieza ningun pedido
    -- mas, tampoco un reintento. Al dormir la pantalla espera.
    local deadline = tonumber(options.deadline)
    local optional_dropped = false
    while not response and #events > 0 and type(err) == "table" do
        if max_recoveries and recoveries >= max_recoveries then break end
        if deadline and os.time() >= deadline then break end
        local recovered = false
        if err.code == "client_sequence_conflict" and not sequences_recovered then
            sequences_recovered = true
            recovered = self.queue:recoverSequences(err.details, events)
        elseif err.code == "idempotency_conflict" and reissued < #events then
            recovered = self.queue:reissueConflicting(err.details, events)
            if recovered then reissued = reissued + 1 end
        elseif err.code == "validation_failed" and not optional_dropped then
            -- Un servidor viejo que no conoce un evento de captura: se descarta
            -- y el resto del lote sigue (Queue:dropUnsupportedOptional).
            optional_dropped = true
            recovered = self.queue:dropUnsupportedOptional(err.details, events)
        end
        if not recovered then break end
        recoveries = recoveries + 1
        events = prepare(true)
        if #events == 0 then
            -- No quedo nada por subir: lo que sigue es una consulta comun.
            url = self:getBaseUrl() .. "/api/sync/v2/pull"
            payload = {
                protocol_version = 2,
                cursor = self.queue:getCursor(),
                limit = self.pull_limit,
                client = resolve(self.client) or {},
            }
        else
            payload.events = events
        end
        response, err = self.web_api:postJSON(url, self:getAuth(), payload, quick)
    end
    if not response then
        self.queue:setLastError(err)
        return nil, err
    end
    if response.protocol_version ~= 2 then
        local protocol_err = self.web_api.apiError(
            "unsupported_protocol_response",
            "Server did not return Borges v2.",
            nil,
            false,
            response.request_id
        )
        self.queue:setLastError(protocol_err)
        return nil, protocol_err
    end

    self:_noteServerTime(response)
    if response.acknowledgements == nil then response.acknowledgements = {} end
    local committed, commit_err = self.queue:commitExchange(response, self.apply_event)
    if not committed then
        local local_err = self.web_api.apiError(
            commit_err,
            "Could not durably apply the sync response.",
            nil,
            false
        )
        self.queue:setLastError(local_err)
        return nil, local_err
    end
    committed.sent = #events
    return committed
end

function SyncV2:syncAll(force, max_pages, quick)
    max_pages = max_pages or 20
    local summary = {
        pages = 0,
        acknowledged = 0,
        received = 0,
        deferred = 0,
        pending = self.queue:v2Count(),
        cursor = self.queue:getCursor(),
    }
    local more_to_read = false
    for page = 1, max_pages do
        -- Lo que queda en el outbox no puede salir (una posicion retenida, un
        -- reintento que todavia espera) y el servidor no dijo que tuviera mas:
        -- otra vuelta seria un pedido entero para no mover nada.
        if page > 1 and not more_to_read and self.queue.sendableCount
            and self.queue:sendableCount(force) == 0 then
            break
        end
        -- A manual sync retries the entire saved backlog, including later pages
        -- whose backoff was set by earlier failures.
        local result, err = self:sync(force, quick)
        if not result then return nil, err end
        summary.pages = page
        summary.acknowledged = summary.acknowledged + (result.acknowledged or 0)
        summary.received = summary.received + (result.received or 0)
        summary.deferred = summary.deferred + (result.deferred or 0)
        summary.pending = result.pending
        summary.cursor = result.cursor
        more_to_read = result.has_more == true
        if not result.has_more and result.pending == 0 then break end
        if (result.sent or 0) == 0 and result.pending > 0 then break end
    end
    return summary
end

function SyncV2:reportHealth(last_error)
    local error_payload
    if last_error then
        error_payload = {
            code = last_error.code,
            message = last_error.message or tostring(last_error),
            request_id = last_error.request_id,
            retryable = last_error.retryable == true,
        }
    end
    return self.web_api:postJSON(
        self:getBaseUrl() .. "/api/devices/self/health",
        self:getAuth(),
        {
            status = last_error and "degraded" or "ok",
            queue_depth = self.queue:count(),
            last_error = error_payload,
            client = resolve(self.client) or {},
        },
        true
    )
end

return SyncV2

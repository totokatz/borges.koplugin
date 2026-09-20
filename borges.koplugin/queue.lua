--- Durable Borges v2 outbox/inbox plus a lossless legacy compatibility queue.

local QueueStorage = require("queuestorage")
local rapidjson = require("rapidjson")
local random = require("random")
local logger = require("logger")

local Queue = {}
Queue.__index = Queue

local STATE_VERSION = 2
local DEFAULT_MAX_EVENTS = 20
local DEFAULT_MAX_BYTES = 240 * 1024
local MAX_REJECTED = 50
local MAX_INBOX = 500
local MAX_BACKOFF = 6 * 60 * 60

local function progressKey(identifier)
    if type(identifier) ~= "table" or not identifier.kind or not identifier.value then return nil end
    return identifier.kind .. ":" .. identifier.value
end

local function utcNow()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function copyWireEvent(event)
    return {
        client_event_id = event.client_event_id,
        client_sequence = event.client_sequence,
        event_version = event.event_version,
        event_type = event.event_type,
        aggregate_type = event.aggregate_type,
        aggregate_id = event.aggregate_id,
        document_id = event.document_id,
        book_identifier = event.book_identifier,
        occurred_at = event.occurred_at,
        time_precision = event.time_precision,
        monotonic_ms = event.monotonic_ms,
        payload = event.payload,
    }
end

local function boundedAppend(items, item, limit)
    table.insert(items, item)
    while #items > limit do table.remove(items, 1) end
end

local function findById(items, id)
    for index, item in ipairs(items) do
        if item.client_event_id == id or item.event_id == id then
            return index, item
        end
    end
end

local function normalizeState(value)
    local state = type(value) == "table" and value or {}
    state.schema_version = STATE_VERSION
    state.install_id = state.install_id or random.uuid(true):lower()
    -- Cuenta dueña de esta cola. Una cola anterior a C06 no la tiene: queda
    -- nil y la adopta el primer login, sin descartar el trabajo pendiente de
    -- una instalación que se está migrando.
    state.account_scope = type(state.account_scope) == "string"
        and state.account_scope or nil
    state.next_client_sequence = tonumber(state.next_client_sequence) or 1
    state.applied_cursor = tostring(state.applied_cursor or "0")
    state.outbox = type(state.outbox) == "table" and state.outbox or {}
    -- Recover an older settings counter without changing any pending envelope.
    for _, event in ipairs(state.outbox) do
        state.next_client_sequence = math.max(state.next_client_sequence,
            (tonumber(event.client_sequence) or 0) + 1)
    end
    state.inbox = type(state.inbox) == "table" and state.inbox or {}
    state.rejected = type(state.rejected) == "table" and state.rejected or {}
    state.annotation_state = type(state.annotation_state) == "table"
        and state.annotation_state or {}
    -- C17 · Lo que el lector ya respondió sobre la posición de otro aparato.
    -- Vive acá y no en memoria porque un "seguir aquí" tiene que sobrevivir a
    -- una reconexión y a un reinicio; y vive junto al cursor porque pertenece
    -- a la misma cuenta que ese stream, y se corta con ella.
    state.resume_decisions = type(state.resume_decisions) == "table"
        and state.resume_decisions or {}
    state.progress_holds = type(state.progress_holds) == "table" and state.progress_holds or {}
    state.last_error = type(state.last_error) == "table" and state.last_error or nil
    return state
end

function Queue:new(settings_dir, options)
    options = options or {}
    local path = settings_dir .. "/highlightsdetoto_sync_v2.lua"
    local legacy_path = settings_dir .. "/highlightsdetoto_queue.lua"
    local instance = setmetatable({
        path = path,
        store = options.store or QueueStorage.open(path),
        legacy_store = options.legacy_store or QueueStorage.open(legacy_path),
        now = options.now or os.time,
        uuid = options.uuid or function() return random.uuid(true):lower() end,
    }, self)
    instance.state = normalizeState(instance.store:readSetting("state"))
    instance:_save()
    return instance
end

function Queue:_save()
    self.store:saveSetting("state", self.state)
    self.store:flush()
end

function Queue:getInstallId()
    return self.state.install_id
end

function Queue:getCursor()
    return self.state.applied_cursor
end

function Queue:holdProgress(identifier)
    local key = progressKey(identifier)
    if key and not self.state.progress_holds[key] then
        self.state.progress_holds[key] = true
        self:_save()
    end
end

function Queue:releaseProgress(identifier)
    local key = progressKey(identifier)
    if key and self.state.progress_holds[key] then
        self.state.progress_holds[key] = nil
        self:_save()
    end
end

function Queue:isProgressHeld(identifier)
    return self.state.progress_holds[progressKey(identifier) or ""] == true
end

-- Called before startup workers: restored progress must consult the reading
-- head again, including books closed before their previous query completed.
function Queue:holdPendingProgress()
    local changed = false
    local function hold(identifier)
        local key = progressKey(identifier)
        if key and not self.state.progress_holds[key] then
            self.state.progress_holds[key], changed = true, true
        end
    end
    for _, event in ipairs(self.state.outbox) do
        if event.event_type == "progress.changed" then hold(event.book_identifier) end
    end
    for _, item in ipairs(self.legacy_store:readSetting("pending") or {}) do
        if item.type == "progress" then
            hold({ kind = "koreader_partial_md5", value = item.data and item.data.book_hash })
        end
    end
    if changed then self:_save() end
end

function Queue:getLastError()
    return self.state.last_error
end

function Queue:setLastError(err)
    if err then
        self.state.last_error = {
            code = err.code,
            message = err.message or tostring(err),
            request_id = err.request_id,
            retryable = err.retryable == true,
            at = self.now(),
        }
    else
        self.state.last_error = nil
    end
    self:_save()
end

--- Allocate and durably append an immutable v2 event.
-- A producer may coalesce a never-attempted event for the same aggregate. Once
-- an event has been selected for transport, its ID, sequence, and content stay
-- immutable forever so an uncertain response can be retried safely.
function Queue:enqueueEvent(event, options)
    options = options or {}
    assert(type(event) == "table", "event is required")
    assert(type(event.event_type) == "string", "event_type is required")
    assert(type(event.aggregate_type) == "string", "aggregate_type is required")
    assert(type(event.aggregate_id) == "string", "aggregate_id is required")
    assert(type(event.payload) == "table", "payload is required")

    if options.coalesce_unattempted then
        for index = #self.state.outbox, 1, -1 do
            local existing = self.state.outbox[index]
            if existing.event_type == event.event_type
                and existing.aggregate_type == event.aggregate_type
                and existing.aggregate_id == event.aggregate_id
                and (tonumber(existing._attempts) or 0) == 0 then
                existing.document_id = event.document_id
                existing.book_identifier = event.book_identifier
                existing.occurred_at = event.occurred_at or utcNow()
                existing.time_precision = event.time_precision or "exact"
                existing.monotonic_ms = event.monotonic_ms
                    and tostring(event.monotonic_ms) or nil
                existing.payload = event.payload
                self:_save()
                return copyWireEvent(existing), true
            end
        end
    end

    local sequence = tostring(self.state.next_client_sequence)
    self.state.next_client_sequence = self.state.next_client_sequence + 1
    local stored = {
        client_event_id = self.uuid(),
        client_sequence = sequence,
        event_version = event.event_version or 1,
        event_type = event.event_type,
        aggregate_type = event.aggregate_type,
        aggregate_id = event.aggregate_id,
        document_id = event.document_id,
        book_identifier = event.book_identifier,
        occurred_at = event.occurred_at or utcNow(),
        time_precision = event.time_precision or "exact",
        monotonic_ms = event.monotonic_ms and tostring(event.monotonic_ms) or nil,
        payload = event.payload,
        _attempts = 0,
        _next_attempt_at = 0,
        _enqueued_at = self.now(),
    }
    table.insert(self.state.outbox, stored)
    self:_save()
    return copyWireEvent(stored)
end

function Queue:prepareBatch(max_events, max_bytes, force)
    max_events = max_events or DEFAULT_MAX_EVENTS
    max_bytes = max_bytes or DEFAULT_MAX_BYTES
    local now = self.now()
    local selected = {}

    for _, event in ipairs(self.state.outbox) do
        if #selected >= max_events then break end
        local held = event.event_type == "progress.changed" and self:isProgressHeld(event.book_identifier)
        if not held and (force or (tonumber(event._next_attempt_at) or 0) <= now) then
            local candidate = copyWireEvent(event)
            table.insert(selected, candidate)
            local encoded = rapidjson.encode({
                protocol_version = 2,
                cursor = self.state.applied_cursor,
                events = selected,
            })
            if #encoded > max_bytes then
                table.remove(selected)
                break
            end
        end
    end

    if #selected == 0 then return {} end
    for _, wire in ipairs(selected) do
        local _, event = findById(self.state.outbox, wire.client_event_id)
        event._attempts = (tonumber(event._attempts) or 0) + 1
        event._last_attempt_at = now
        local exponent = math.min(event._attempts - 1, 10)
        local base = math.min(15 * (2 ^ exponent), MAX_BACKOFF)
        local jitter = math.floor(base * (math.random() * 0.4 - 0.2))
        event._next_attempt_at = now + math.max(5, base + jitter)
    end
    -- Persist attempt metadata before network I/O; a lost response retries immutable content.
    self:_save()
    return selected
end

--- Renumber only IDs the server explicitly proved it has never recorded.
-- Never clear pending work or change payload/identity. Persist the repair before
-- retrying: a lost reply must retry this same repaired envelope after restart.
function Queue:recoverSequences(details, attempted)
    if type(details) ~= "table" or type(details.unrecorded_events) ~= "table" then return false end
    local floor = tonumber(details.next_client_sequence)
    if not floor or floor < 1 or floor ~= math.floor(floor) or floor > 9007199254740991 then return false end
    local sent, repair, seen = {}, {}, {}
    for _, event in ipairs(attempted or {}) do sent[event.client_event_id] = event end
    for _, proof in ipairs(details.unrecorded_events) do
        if type(proof) ~= "table" then return false end
        local wire = sent[proof.client_event_id]
        local _, stored = findById(self.state.outbox, proof.client_event_id)
        if not wire or not stored or seen[proof.client_event_id]
            or tostring(proof.client_sequence) ~= tostring(wire.client_sequence)
            or tostring(stored.client_sequence) ~= tostring(wire.client_sequence) then return false end
        seen[proof.client_event_id] = true
        table.insert(repair, stored)
    end
    if #repair == 0 then return false end
    local sequence = math.max(floor, self.state.next_client_sequence)
    for _, event in ipairs(self.state.outbox) do
        sequence = math.max(sequence, (tonumber(event.client_sequence) or 0) + 1)
    end
    if sequence + #repair > 9007199254740991 then return false end
    -- Keep local order even if a server returns the proofs in another order.
    for _, event in ipairs(self.state.outbox) do
        if seen[event.client_event_id] then
            event.client_sequence = string.format("%.0f", sequence)
            event._next_attempt_at = 0
            sequence = sequence + 1
        end
    end
    self.state.next_client_sequence = sequence
    self:_save()
    return true
end

local function validateAcknowledgements(outbox, acknowledgements)
    local removals, rejected = {}, {}
    for _, ack in ipairs(acknowledgements or {}) do
        local index, event = findById(outbox, ack.client_event_id)
        if event then
            if tostring(ack.client_sequence) ~= tostring(event.client_sequence) then
                return nil, nil, "ack_sequence_mismatch"
            end
            if ack.status ~= "accepted" and ack.status ~= "rejected" then
                return nil, nil, "ack_status_invalid"
            end
            removals[event.client_event_id] = true
            if ack.status == "rejected" then
                table.insert(rejected, {
                    client_event_id = event.client_event_id,
                    client_sequence = event.client_sequence,
                    event_type = event.event_type,
                    aggregate_id = event.aggregate_id,
                    code = ack.rejection_code,
                    detail = ack.rejection_detail,
                    server_sequence = ack.server_sequence,
                })
            end
        end
    end
    return removals, rejected
end

--- Commit an exchange response in one local settings flush.
-- `apply_event` returns true for applied/no-op, or "defer" for unopened-book work.
function Queue:commitExchange(response, apply_event)
    if type(response) ~= "table" or response.protocol_version ~= 2 then
        return nil, "invalid_protocol_response"
    end
    local pull = response.pull or response
    if type(pull.events) ~= "table" or pull.cursor == nil then
        return nil, "invalid_pull_response"
    end

    local removals, rejected, ack_err = validateAcknowledgements(
        self.state.outbox,
        response.acknowledgements or {}
    )
    if not removals then return nil, ack_err end

    local deferred, seen = {}, {}
    -- Preview the open book before replaying history, without advancing the
    -- cursor to the preview's sequence. Older servers simply omit this field.
    if type(pull.focus_event) == "table" then
        local event = pull.focus_event
        event.focus_preview = true
        local action = apply_event and apply_event(event) or "defer"
        if action == false or action == nil then return nil, "remote_apply_failed" end
        if action == "defer" then table.insert(deferred, event) end
        seen[event.event_id] = true
    end
    for _, event in ipairs(pull.events) do
        if not seen[event.event_id] then
            local action = apply_event and apply_event(event) or "defer"
            if action == false or action == nil then
                return nil, "remote_apply_failed"
            end
            if action == "defer" then table.insert(deferred, event) end
        end
    end

    local kept = {}
    for _, event in ipairs(self.state.outbox) do
        if not removals[event.client_event_id] then table.insert(kept, event) end
    end
    self.state.outbox = kept
    for _, item in ipairs(rejected) do
        item.recorded_at = self.now()
        boundedAppend(self.state.rejected, item, MAX_REJECTED)
    end
    for _, event in ipairs(deferred) do
        local index = findById(self.state.inbox, event.event_id)
        if index and event.focus_preview then
            self.state.inbox[index] = event
        elseif not index then
            boundedAppend(self.state.inbox, event, MAX_INBOX)
        end
    end
    self.state.applied_cursor = tostring(pull.cursor)
    self.state.last_error = nil
    self:_save()
    return {
        acknowledged = #(response.acknowledgements or {}),
        -- C07 · Lo que efectivamente llegó del servidor en este intercambio.
        -- `deferred` es sólo la parte que todavía no se pudo aplicar, así que
        -- no sirve para contestarle al lector "¿cuántas cosas recibí?".
        received = #pull.events,
        deferred = #deferred,
        cursor = self.state.applied_cursor,
        pending = #self.state.outbox,
        has_more = pull.has_more == true,
    }
end

function Queue:getInbox()
    return self.state.inbox
end

function Queue:removeInboxEvent(event_id)
    local index = findById(self.state.inbox, event_id)
    if not index then return false end
    table.remove(self.state.inbox, index)
    self:_save()
    return true
end

--- C17 · Las respuestas al diálogo "continuar desde otro dispositivo".
function Queue:getResumeDecisions()
    return self.state.resume_decisions
end

function Queue:setResumeDecisions(value)
    self.state.resume_decisions = type(value) == "table" and value or {}
    self:_save()
end

function Queue:getAnnotationState(book_hash)
    return self.state.annotation_state[book_hash] or {}
end

function Queue:setAnnotationState(book_hash, value)
    self.state.annotation_state[book_hash] = value or {}
    self:_save()
end

function Queue:v2Count()
    return #self.state.outbox
end

function Queue:inboxCount()
    return #self.state.inbox
end

function Queue:rejectedCount()
    return #self.state.rejected
end

-- -------------------------------------------------------------------------
-- Lossless legacy compatibility queue. Phase 12 producers migrate off this
-- surface, but pre-upgrade pending work remains sendable and is never dropped.
-- -------------------------------------------------------------------------

local function legacyItems(self)
    return self.legacy_store:readSetting("pending") or {}
end

function Queue:enqueue(item_type, data)
    local items = legacyItems(self)
    table.insert(items, {
        type = item_type,
        data = data,
        timestamp = self.now(),
        retries = 0,
    })
    self.legacy_store:saveSetting("pending", items)
    self.legacy_store:flush()
end

local function sendLegacy(item, api, base_url, auth)
    if item.type == "progress" then
        return api:postJSON(base_url .. "/api/progress", auth, item.data, true)
    elseif item.type == "session" then
        return api:postJSON(base_url .. "/api/sessions", auth, item.data, true)
    elseif item.type == "highlights" then
        return api:postJSON(base_url .. "/api/sync", auth, item.data)
    elseif item.type == "page_stats" then
        return api:postJSON(base_url .. "/api/page-stats", auth, item.data)
    end
    return nil, api.apiError("unknown_legacy_item", "Unknown queued item type.", nil, false)
end

function Queue:drainOne(api, base_url, auth)
    local items = legacyItems(self)
    if #items == 0 then return { sent = false, remaining = 0 } end
    local index, item
    for i, candidate in ipairs(items) do
        local held = candidate.type == "progress" and self:isProgressHeld({
            kind = "koreader_partial_md5", value = candidate.data and candidate.data.book_hash })
        if not held then index, item = i, candidate; break end
    end
    if not item then return { sent = false, remaining = #items, reading_choice_pending = true } end
    local result, err = sendLegacy(item, api, base_url, auth)
    if result then
        table.remove(items, index)
    else
        item.retries = (item.retries or 0) + 1
        item.last_error = err and {
            code = err.code,
            message = err.message or tostring(err),
            request_id = err.request_id,
        } or nil
        logger.warn("Borges: legacy queue item retained:", item.type, tostring(err))
    end
    self.legacy_store:saveSetting("pending", items)
    self.legacy_store:flush()
    return {
        sent = result ~= nil,
        remaining = #items,
        error = err,
        item_type = item.type,
    }
end

function Queue:drain(api, base_url, auth)
    local sent, failed = 0, 0
    local initial = #legacyItems(self)
    for _ = 1, initial do
        local result = self:drainOne(api, base_url, auth)
        if result.sent then sent = sent + 1 else failed = failed + 1; break end
    end
    return { sent = sent, failed = failed }
end

function Queue:count()
    return #legacyItems(self) + #self.state.outbox
end

-- -------------------------------------------------------------------------
-- C06 · La cola pertenece a una cuenta, no al aparato.
--
-- El cursor, el outbox y el mapa de anotaciones describen un stream del
-- servidor que existe dentro de UNA cuenta. Si el lector entra con otra, esos
-- datos no son "viejos": son de otra persona. Mandarlos subiría los subrayados
-- de A a la biblioteca de B, y aplicar el inbox de A pisaría el libro de B. Por
-- eso el cambio de cuenta no migra nada: se exporta si hace falta y se corta.
-- -------------------------------------------------------------------------

function Queue:getAccountScope()
    return self.state.account_scope
end

--- ¿Queda trabajo sin confirmar que un corte de cuenta se llevaría puesto?
function Queue:hasPendingWork()
    return #self.state.outbox > 0
        or #self.state.inbox > 0
        or #legacyItems(self) > 0
end

--- Una foto serializable de todo lo pendiente, para poder guardarla antes de
-- descartarla. Es lo único que permite ofrecer "exportar y cambiar" sin
-- prometer una migración entre cuentas que sería incorrecta.
function Queue:exportPending()
    return {
        schema = "highlightsdetoto-pending-v1",
        exported_at = utcNow(),
        account_scope = self.state.account_scope,
        install_id = self.state.install_id,
        cursor = self.state.applied_cursor,
        outbox = self.state.outbox,
        inbox = self.state.inbox,
        rejected = self.state.rejected,
        legacy_pending = legacyItems(self),
    }
end

local function wipeAccountState(self, scope_id)
    local discarded = {
        previous_scope = self.state.account_scope,
        outbox = #self.state.outbox,
        inbox = #self.state.inbox,
        rejected = #self.state.rejected,
        legacy = #legacyItems(self),
        cursor = self.state.applied_cursor,
    }
    self.state.account_scope = scope_id
    self.state.outbox = {}
    self.state.inbox = {}
    self.state.rejected = {}
    self.state.annotation_state = {}
    self.state.resume_decisions = {}
    self.state.progress_holds = {}
    self.state.applied_cursor = "0"
    -- Pairing may reuse this installation's server device. Keep its sequence
    -- high-water mark across logout/account changes; gaps are harmless.
    self.state.last_error = nil
    self:_save()
    self.legacy_store:saveSetting("pending", {})
    self.legacy_store:flush()
    return discarded
end

--- Ponerle dueño a una cola que no lo tenía, sin descartar nada.
--
-- Es el puente para una instalación anterior a C06: su cola ya es de la cuenta
-- con la que está pareada, sólo que nadie lo había anotado. Anotarlo al
-- arrancar es lo que permite que un cambio de cuenta posterior se detecte en
-- vez de heredar en silencio el trabajo del dueño anterior.
function Queue:adoptAccount(scope_id)
    if type(scope_id) ~= "string" or scope_id == "" then return false end
    if self.state.account_scope ~= nil then return false end
    self.state.account_scope = scope_id
    self:_save()
    return true
end

--- Dejar la cola lista para otra cuenta. Devuelve nil si ya estaba en esa
-- cuenta —reentrar con el mismo usuario no descarta nada— y, si hubo corte, el
-- recuento de lo que se descartó.
function Queue:resetForAccount(scope_id)
    if type(scope_id) ~= "string" or scope_id == "" then return nil end
    if self.state.account_scope == scope_id then return nil end
    if self.state.account_scope == nil then
        -- Cola sin dueño anotado: la adopta quien entra. Descartar acá sería
        -- perder el trabajo offline de una instalación que sólo se actualizó.
        self:adoptAccount(scope_id)
        return nil
    end
    return wipeAccountState(self, scope_id)
end

--- Salir de la cuenta: la cola queda vacía y sin dueño. Lo pendiente era de la
-- cuenta que se va, así que no puede quedar esperando a la que entre después.
function Queue:releaseAccount()
    return wipeAccountState(self, nil)
end

function Queue:hasItemForBookHash(item_type, book_hash)
    if not book_hash then return false end
    for _, item in ipairs(legacyItems(self)) do
        if item.type == item_type and item.data and item.data.book_hash == book_hash then
            return true
        end
    end
    local v2_type = ({
        progress = "progress.changed",
        session = "session.ended",
        page_stats = "page_stat.recorded",
        highlights = "annotation.updated",
    })[item_type]
    for _, event in ipairs(self.state.outbox) do
        if (not v2_type or event.event_type == v2_type)
            and event.book_identifier
            and event.book_identifier.kind == "koreader_partial_md5"
            and event.book_identifier.value == book_hash then
            return true
        end
        if event.payload and event.payload.book_hash == book_hash then return true end
    end
    return false
end

function Queue:clear()
    self.state.outbox = {}
    self.state.inbox = {}
    self.state.last_error = nil
    self:_save()
    self.legacy_store:saveSetting("pending", {})
    self.legacy_store:flush()
end

return Queue

--- Durable Borges v2 outbox/inbox plus a lossless legacy compatibility queue.
--
-- El estado vive en tres clases de archivo, separadas por cada cuanto cambian:
--
--   highlightsdetoto_sync_v2.lua            lo que cambia leyendo: outbox, cursor,
--                                           secuencia, decisiones. Unos pocos KB.
--   highlightsdetoto_sync_v2/inbox.lua      lo que llego de otros lectores y espera
--                                           a que se abra su libro. Puede pesar
--                                           cientos de KB y casi nunca cambia.
--   highlightsdetoto_sync_v2/book-<md5>.lua lo ya sincronizado de UN libro.
--
-- Antes todo iba junto y cada guardado reescribia el archivo entero: guardar la
-- posicion de lectura reescribia tambien las anotaciones pendientes de un libro
-- que nadie habia abierto en dos meses. Medido en un lector real: 426 KB por
-- guardado, y un guardado por cada subrayado nuevo.

local QueueStorage = require("queuestorage")
local rapidjson = require("rapidjson")
local random = require("random")
local logger = require("logger")

local Queue = {}
Queue.__index = Queue

local STATE_VERSION = 3
local INBOX_FORMAT = "borges-inbox-1"
local ANNOTATION_FORMAT = "borges-annotations-1"
local SHARD_DIR = "highlightsdetoto_sync_v2"
local DEFAULT_MAX_EVENTS = 20
local DEFAULT_MAX_BYTES = 240 * 1024
local MAX_REJECTED = 50
-- Tope de lo que espera a su libro. Con una sola entrada por anotacion (ver
-- `inboxSlot`) el numero es "anotaciones ajenas distintas en libros sin abrir".
-- Era 500 y al pasarlo se tiraba el evento mas viejo en silencio mientras el
-- cursor avanzaba igual: un libro con 839 subrayados perdia 339.
local MAX_INBOX = 2000
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
    local dropped = 0
    while #items > limit do table.remove(items, 1); dropped = dropped + 1 end
    return dropped
end

--- Una anotacion o un marcador viajan enteros en cada evento: el mas nuevo
-- reemplaza a cualquier otro pendiente de la misma anotacion del mismo libro
-- (un borrado tambien). Guardar los dos era la mitad del inbox de un lector
-- real: 34 anotaciones, 68 eventos.
local function inboxSlot(event)
    local kind = type(event) == "table" and event.event_type
    if type(kind) ~= "string" or type(event.aggregate_id) ~= "string" then return nil end
    if kind:sub(1, 11) ~= "annotation." and kind:sub(1, 9) ~= "bookmark." then return nil end
    -- Una rama que el servidor guardo como conflicto no es el estado vigente:
    -- ni reemplaza a nadie ni se aplica (ver `_applySyncV2Event`).
    if event.directive == "annotation_conflict" then return nil end
    local metadata = event.directive_metadata
    if type(metadata) == "table" and metadata.annotation_conflict == true then return nil end
    local identifier = event.book_identifier
    if type(identifier) ~= "table" or not identifier.kind or not identifier.value then return nil end
    return identifier.kind .. ":" .. identifier.value .. "|" .. event.aggregate_id
end

--- Orden del servidor sin perder precision: las secuencias son enteros que
-- pueden no entrar en un numero de Lua. Sin secuencia en alguno, manda el
-- orden de llegada (lo que llega despues es mas nuevo).
local function arrivedBefore(candidate, existing)
    local a, b = tostring(candidate.server_sequence or ""), tostring(existing.server_sequence or "")
    if not a:match("^%d+$") or not b:match("^%d+$") then return false end
    if #a ~= #b then return #a < #b end
    return a < b
end

--- Agregar al inbox dejando una sola entrada por anotacion. Devuelve cuantos
-- eventos hubo que tirar por el tope (0 casi siempre).
local function appendInbox(inbox, event)
    local slot = inboxSlot(event)
    if slot then
        for index = #inbox, 1, -1 do
            if inboxSlot(inbox[index]) == slot then
                if arrivedBefore(event, inbox[index]) then return 0 end
                table.remove(inbox, index)
            end
        end
    end
    return boundedAppend(inbox, event, MAX_INBOX)
end

--- Lo mismo para un inbox que ya estaba guardado con repetidos.
local function compactInbox(events)
    local newest, removed = {}, 0
    for index, event in ipairs(events) do
        local slot = inboxSlot(event)
        if slot then
            local previous = newest[slot]
            if previous == nil or not arrivedBefore(event, events[previous]) then newest[slot] = index end
        end
    end
    for index = #events, 1, -1 do
        local slot = inboxSlot(events[index])
        if slot and newest[slot] ~= index then
            table.remove(events, index)
            removed = removed + 1
        end
    end
    return removed
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
    -- `inbox` y `annotation_state` ya no viven aca. Si aparecen es un estado
    -- anterior a la separacion (o uno que toco una version vieja del plugin):
    -- se dejan como estan para que `_adoptLegacyLayout` los mude sin perder nada.
    state.rejected = type(state.rejected) == "table" and state.rejected or {}
    -- Generacion de los archivos separados. Cortar la cuenta la incrementa en
    -- el estado principal, y con eso todo archivo de la generacion anterior
    -- deja de valer en un solo guardado atomico, sin recorrer la carpeta.
    state.shard_epoch = math.max(1, math.floor(tonumber(state.shard_epoch) or 1))
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

-- -------------------------------------------------------------------------
-- Archivos separados ("shards")
-- -------------------------------------------------------------------------

--- Un archivo por nombre dentro de la carpeta de la cola, con la misma
-- escritura verificada y atomica que el estado principal.
local function fileShards(settings_dir)
    local dir = settings_dir .. "/" .. SHARD_DIR
    local opened, ready = {}, false
    local function exists()
        return require("libs/libkoreader-lfs").attributes(dir, "mode") ~= nil
    end
    local function open(name)
        opened[name] = opened[name] or QueueStorage.open(dir .. "/" .. name .. ".lua")
        return opened[name]
    end
    return {
        read = function(name)
            -- Leer no crea la carpeta: sin nada que guardar no queda rastro.
            if not opened[name] and not exists() then return nil end
            return open(name):readSetting("state")
        end,
        write = function(name, value)
            if not ready then
                local lfs = require("libs/libkoreader-lfs")
                local mode = lfs.attributes(dir, "mode")
                if mode == nil then
                    assert(lfs.mkdir(dir), "Cannot create queue directory: " .. dir)
                    -- La carpeta nueva tambien tiene que sobrevivir a un corte:
                    -- su entrada vive en la carpeta de ajustes, que es la que
                    -- hay que sincronizar (fsyncDirectory de una carpeta
                    -- sincroniza esa carpeta, no a su padre).
                    require("ffi/util").fsyncDirectory(settings_dir)
                else
                    assert(mode == "directory", "Queue path is not a directory: " .. dir)
                end
                ready = true
            end
            local store = open(name)
            store:saveSetting("state", value)
            store:flush()
        end,
    }
end

--- Cuando quien llama trae su propia store (las pruebas), los archivos
-- separados viven en esa misma store bajo otra clave: mismo recorrido de
-- codigo, sin tocar el disco.
local function embeddedShards(store)
    return {
        read = function(name) return store:readSetting("shard:" .. name) end,
        write = function(name, value)
            store:saveSetting("shard:" .. name, value)
            store:flush()
        end,
    }
end

local function bookShardName(book_hash)
    -- El md5 parcial ya es un nombre de archivo valido. Cualquier otra cosa se
    -- reduce a su md5 para no escribir nunca un nombre que el disco rechace.
    if book_hash:match("^[%w_%-]+$") and #book_hash <= 64 then return "book-" .. book_hash end
    return "book-x" .. require("ffi/sha2").md5(book_hash)
end

--- Una entrada del mapa de anotaciones ocupa seis lineas como tabla y una como
-- texto. Es el archivo que se reescribe en cada subrayado, asi que el tamano
-- importa. Solo se compacta la forma conocida; cualquier otra viaja intacta.
local ENTRY_FIELDS = { fingerprint = true, kind = true, revision = true, present = true }
local function encodeEntry(entry)
    if type(entry) ~= "table" then return entry end
    for key in pairs(entry) do
        if not ENTRY_FIELDS[key] then return entry end
    end
    local fingerprint, kind, revision = entry.fingerprint, entry.kind, entry.revision
    if (fingerprint ~= nil and (type(fingerprint) ~= "string" or fingerprint:find("|", 1, true)))
        or (kind ~= nil and (type(kind) ~= "string" or kind == "" or kind:find("|", 1, true)))
        or (revision ~= nil and (type(revision) ~= "string" or not revision:match("^%d+$")))
        or (entry.present ~= nil and type(entry.present) ~= "boolean") then
        return entry
    end
    local present = entry.present == true and "1" or entry.present == false and "0" or ""
    return table.concat({ "1", kind or "", present, revision or "", fingerprint or "" }, "|")
end

local function decodeEntry(stored)
    if type(stored) ~= "string" then return stored end
    local kind, present, revision, fingerprint = stored:match("^1|([^|]*)|([01]?)|(%d*)|([^|]*)$")
    -- Una huella suelta (formato anterior a las revisiones) no empieza con
    -- "1|": se devuelve tal cual y `AnnotationAdapter:diff` ya sabe leerla.
    if not kind then return stored end
    local entry = {}
    if kind ~= "" then entry.kind = kind end
    if present ~= "" then entry.present = present == "1" end
    if revision ~= "" then entry.revision = revision end
    if fingerprint ~= "" then entry.fingerprint = fingerprint end
    return entry
end

local function sameAnnotationState(left, right)
    for id, a in pairs(left) do
        local b = right[id]
        if type(a) ~= type(b) then return false end
        if type(a) == "table" then
            for key, value in pairs(a) do if b[key] ~= value then return false end end
            for key in pairs(b) do if a[key] == nil then return false end end
        elseif a ~= b then
            return false
        end
    end
    for id in pairs(right) do if left[id] == nil then return false end end
    return true
end

local function inboxIndex(events)
    local books, total = {}, 0
    for _, event in ipairs(events) do
        total = total + 1
        local key = progressKey(event.book_identifier) or "?"
        books[key] = (books[key] or 0) + 1
    end
    return { total = total, books = books }
end

local function sameIndex(left, right)
    if type(left) ~= "table" or type(left.books) ~= "table" or left.total ~= right.total then return false end
    for key, count in pairs(right.books) do if left.books[key] ~= count then return false end end
    for key in pairs(left.books) do if right.books[key] == nil then return false end end
    return true
end

function Queue:new(settings_dir, options)
    options = options or {}
    local path = settings_dir .. "/highlightsdetoto_sync_v2.lua"
    local legacy_path = settings_dir .. "/highlightsdetoto_queue.lua"
    local store = options.store or QueueStorage.open(path)
    local instance = setmetatable({
        path = path,
        store = store,
        legacy_store = options.legacy_store or QueueStorage.open(legacy_path),
        shards = options.shards
            or (options.store and embeddedShards(store) or fileShards(settings_dir)),
        now = options.now or os.time,
        uuid = options.uuid or function() return random.uuid(true):lower() end,
        _books = {},
        _dirty = { main = true, inbox = false, books = {} },
    }, self)
    instance.state = normalizeState(store:readSetting("state"))
    instance:_adoptLegacyLayout(not options.store and function()
        -- El archivo unico de antes queda guardado tal cual, una sola vez.
        QueueStorage.snapshot(path, ".pre-split")
    end or nil)
    if type(instance.state.inbox_index) ~= "table" then instance:_inbox() end
    instance:flush()
    return instance
end

--- ¿Este archivo separado pertenece al estado principal que esta cargado?
-- La generacion corta todo de una vez; la cuenta cubre el caso de un plugin
-- viejo que haya cambiado de cuenta sin saber que la generacion existe. Un
-- archivo sin cuenta anotada es de una cola anterior a C06 y lo adopta quien
-- esta, igual que el resto de esa cola.
function Queue:_shardIsCurrent(stored)
    return type(stored) == "table"
        and stored.epoch == self.state.shard_epoch
        and (stored.account_scope == nil or stored.account_scope == self.state.account_scope)
end

--- El inbox se lee recien cuando alguien lo necesita. Con el indice del estado
-- principal, arrancar KOReader o abrir un libro sin nada pendiente no parsea
-- cientos de KB de anotaciones ajenas.
function Queue:_inbox()
    if self._inbox_events then return self._inbox_events end
    local stored = self.shards.read("inbox")
    local events = {}
    if self:_shardIsCurrent(stored) and type(stored.events) == "table" then
        events = stored.events
    end
    self._inbox_events = events
    -- Sale con el proximo guardado: leer no escribe.
    if compactInbox(events) > 0 then self._dirty.inbox = true end
    self:_reindexInbox()
    return events
end

--- El indice es una pista, nunca la verdad: se recalcula cada vez que el inbox
-- se lee o cambia, asi que una pista vieja se corrige sola.
function Queue:_reindexInbox()
    local index = inboxIndex(self._inbox_events)
    if not sameIndex(self.state.inbox_index, index) then
        self.state.inbox_index = index
        self._dirty.main = true
    end
end

--- Tirar algo recibido nunca es silencioso: queda contado en el estado y en
-- el log, que es lo que se manda con «Reportar un problema».
function Queue:_noteInboxOverflow(dropped)
    if not dropped or dropped <= 0 then return end
    self.state.inbox_dropped = (tonumber(self.state.inbox_dropped) or 0) + dropped
    self._dirty.main = true
    logger.warn("Borges: inbox full, dropped", dropped, "oldest pending events; total", self.state.inbox_dropped)
end

function Queue:inboxDroppedCount()
    return tonumber(self.state.inbox_dropped) or 0
end

function Queue:_inboxChanged()
    self._dirty.inbox = true
    self:_reindexInbox()
end

function Queue:_book(book_hash)
    local cached = self._books[book_hash]
    if cached ~= nil then return cached or nil end
    local stored = self.shards.read(bookShardName(book_hash))
    local items = false
    if self:_shardIsCurrent(stored) and type(stored.items) == "table" then
        items = {}
        for id, entry in pairs(stored.items) do items[id] = decodeEntry(entry) end
    end
    self._books[book_hash] = items
    return items or nil
end

--- Mudar un estado de archivo unico a los archivos separados, sin perder nada.
--
-- Lo separado se escribe y se confirma ANTES de sacarlo del estado principal.
-- Si la corriente se corta en el medio, el principal todavia lo tiene todo y el
-- proximo arranque repite la mudanza desde ahi, con el mismo resultado.
--
-- Tambien cubre el camino de vuelta: una version vieja del plugin que corra
-- sobre este estado vuelve a crear `inbox` y `annotation_state` y sigue
-- trabajando ahi. Al actualizar otra vez eso se suma a lo que ya estaba
-- separado, no lo pisa.
function Queue:_adoptLegacyLayout(preserve)
    local state = self.state
    local legacy_inbox, legacy_books = state.inbox, state.annotation_state
    if legacy_inbox == nil and legacy_books == nil then return false end
    if preserve then preserve() end

    if type(legacy_inbox) == "table" and #legacy_inbox > 0 then
        local events = self:_inbox()
        for _, event in ipairs(legacy_inbox) do
            if event.event_id == nil or not findById(events, event.event_id) then
                self:_noteInboxOverflow(appendInbox(events, event))
            end
        end
        self:_inboxChanged()
    end
    if type(legacy_books) == "table" then
        for book_hash, items in pairs(legacy_books) do
            -- Lo que anoto la version vieja de un libro es mas nuevo que lo
            -- separado antes para ese mismo libro. Un mapa vacio no dice nada.
            if type(book_hash) == "string" and book_hash ~= ""
                and type(items) == "table" and next(items) ~= nil then
                self._books[book_hash] = items
                self._dirty.books[book_hash] = true
            end
        end
    end
    state.inbox, state.annotation_state = nil, nil
    self._dirty.main = true
    self:flush("consume") -- libros, inbox y recien despues el principal sin ellos
    return true
end

--- Escribir lo que cambio, y solo eso.
--
-- El orden importa porque son varios archivos y la corriente se puede cortar
-- entre dos:
--   * "produce" (por defecto): inbox, principal, libros. Un subrayado nuevo
--     entra al outbox ANTES de anotarse como sincronizado. Al reves, un corte
--     lo dejaria anotado y sin mandar: se perderia para siempre.
--   * "consume": libros, inbox, principal. Lo recibido queda aplicado ANTES de
--     mover el cursor. Al reves, un corte dejaria el cursor adelantado sobre
--     algo que nunca se guardo.
-- En los dos casos lo peor que deja un corte es trabajo repetido, que el
-- servidor y el lector ya saben reconocer; nunca trabajo perdido.
function Queue:flush(order)
    local dirty = self._dirty
    if not (dirty.main or dirty.inbox or next(dirty.books)) then return false end
    -- Quien use la cola puede necesitar guardar algo propio antes (el plugin
    -- guarda las anotaciones del libro): si esto falla, la cola no avanza.
    if self.before_flush then self.before_flush() end
    local function books()
        for book_hash in pairs(dirty.books) do
            local items = {}
            for id, entry in pairs(self._books[book_hash] or {}) do items[id] = encodeEntry(entry) end
            self.shards.write(bookShardName(book_hash), {
                format = ANNOTATION_FORMAT,
                epoch = self.state.shard_epoch,
                account_scope = self.state.account_scope,
                book_hash = book_hash,
                items = items,
            })
            dirty.books[book_hash] = nil
        end
    end
    local function inbox()
        if not dirty.inbox then return end
        self.shards.write("inbox", {
            format = INBOX_FORMAT,
            epoch = self.state.shard_epoch,
            account_scope = self.state.account_scope,
            events = self._inbox_events or {},
        })
        dirty.inbox = false
    end
    local function main()
        if not dirty.main then return end
        self.store:saveSetting("state", self.state)
        self.store:flush()
        dirty.main = false
    end
    if order == "consume" then
        books(); inbox(); main()
    else
        inbox(); main(); books()
    end
    return true
end

--- Marcar el estado principal como cambiado. Con `defer` no se escribe ahora:
-- queda para el proximo `flush`, que es como se agrupan varios cambios en un
-- solo guardado. No hay un "modo diferido" que alguien pueda dejar prendido:
-- lo pendiente sale con el siguiente guardado de cualquier cosa.
function Queue:_save(defer)
    self._dirty.main = true
    if not defer then self:flush() end
end

function Queue:getInstallId()
    return self.state.install_id
end

function Queue:getCursor()
    return self.state.applied_cursor
end

-- Retener y soltar la posicion no escriben por si solos: viajan con el
-- proximo guardado, que es el del propio evento de posicion (mismo archivo,
-- una sola escritura atomica). Un corte antes de eso no pierde nada: al
-- arrancar, `holdPendingProgress` vuelve a retener toda posicion pendiente.
-- Antes eran dos escrituras con fsync en cada despertar y cada apertura.
function Queue:holdProgress(identifier)
    local key = progressKey(identifier)
    if key and not self.state.progress_holds[key] then
        self.state.progress_holds[key] = true
        self:_save(true)
    end
end

function Queue:releaseProgress(identifier)
    local key = progressKey(identifier)
    if key and self.state.progress_holds[key] then
        self.state.progress_holds[key] = nil
        self:_save(true)
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
                self:_save(options.defer)
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
    -- `defer` agrupa varios eventos en un guardado: quien lo pide llama a
    -- `flush()` al terminar. `prepareBatch` guarda siempre antes de la red.
    self:_save(options.defer)
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
    -- Lo que `apply_event` haya aplicado antes de fallar ya esta en memoria
    -- (y en el libro): se guarda igual, aunque el cursor no avance.
    local function failed()
        self:flush("consume")
        return nil, "remote_apply_failed"
    end
    -- Preview the open book before replaying history, without advancing the
    -- cursor to the preview's sequence. Older servers simply omit this field.
    if type(pull.focus_event) == "table" then
        local event = pull.focus_event
        event.focus_preview = true
        local action = apply_event and apply_event(event) or "defer"
        if action == false or action == nil then return failed() end
        if action == "defer" then table.insert(deferred, event) end
        seen[event.event_id] = true
    end
    for _, event in ipairs(pull.events) do
        if not seen[event.event_id] then
            local action = apply_event and apply_event(event) or "defer"
            if action == false or action == nil then return failed() end
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
    if #deferred > 0 then
        -- Solo aca hace falta leer el inbox: un intercambio que no deja nada
        -- en espera no toca ese archivo.
        local inbox = self:_inbox()
        for _, event in ipairs(deferred) do
            local index = findById(inbox, event.event_id)
            if index and event.focus_preview then
                inbox[index] = event
            elseif not index then
                self:_noteInboxOverflow(appendInbox(inbox, event))
            end
        end
        self:_inboxChanged()
    end
    self.state.applied_cursor = tostring(pull.cursor)
    self.state.last_error = nil
    self._dirty.main = true
    -- Un solo guardado para todo el intercambio, incluido lo que `apply_event`
    -- dejo pendiente: primero lo aplicado, al final el cursor.
    self:flush("consume")
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
    return self:_inbox()
end

--- `defer` deja la baja para el proximo `flush("consume")`: aplicar las
-- anotaciones pendientes de un libro es un guardado, no uno por anotacion.
function Queue:removeInboxEvent(event_id, defer)
    local inbox = self:_inbox()
    local index = findById(inbox, event_id)
    if not index then return false end
    table.remove(inbox, index)
    self:_inboxChanged()
    if not defer then self:flush("consume") end
    return true
end

--- Cuantos eventos esperan a ESTE libro, sin leer el inbox del disco.
function Queue:inboxCountForBook(identifier)
    local index = self.state.inbox_index
    if type(index) ~= "table" or type(index.books) ~= "table" then
        self:_inbox()
        index = self.state.inbox_index
    end
    return index.books[progressKey(identifier) or "?"] or 0
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
    if type(book_hash) ~= "string" or book_hash == "" then return {} end
    return self:_book(book_hash) or {}
end

--- Lo ya sincronizado de un libro vive en su propio archivo: anotar un
-- subrayado reescribe ese libro y nada mas. `defer` lo deja para el proximo
-- `flush`.
function Queue:setAnnotationState(book_hash, value, defer)
    assert(type(book_hash) == "string" and book_hash ~= "", "book_hash is required")
    value = value or {}
    local current = self:_book(book_hash)
    if current ~= value and sameAnnotationState(current or {}, value)
        and (current ~= nil or next(value) == nil) then
        -- Nada nuevo que anotar: ni se serializa ni se escribe.
        return false
    end
    self._books[book_hash] = value
    self._dirty.books[book_hash] = true
    if not defer then self:flush() end
    return true
end

function Queue:v2Count()
    return #self.state.outbox
end

--- Cuantos eventos del outbox podrian salir ahora: los que no estan retenidos
-- y, salvo `force`, ya cumplieron su espera de reintento. Con cero, un
-- intercambio no subiria nada: quien llama puede ahorrarse el pedido.
function Queue:sendableCount(force)
    local now, count = self.now(), 0
    for _, event in ipairs(self.state.outbox) do
        local held = event.event_type == "progress.changed" and self:isProgressHeld(event.book_identifier)
        if not held and (force or (tonumber(event._next_attempt_at) or 0) <= now) then
            count = count + 1
        end
    end
    return count
end

function Queue:inboxCount()
    local index = self.state.inbox_index
    if type(index) ~= "table" or type(index.total) ~= "number" then return #self:_inbox() end
    return index.total
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
        or self:inboxCount() > 0
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
        inbox = self:_inbox(),
        rejected = self.state.rejected,
        legacy_pending = legacyItems(self),
    }
end

local function wipeAccountState(self, scope_id)
    local discarded = {
        previous_scope = self.state.account_scope,
        outbox = #self.state.outbox,
        inbox = self:inboxCount(),
        rejected = #self.state.rejected,
        legacy = #legacyItems(self),
        cursor = self.state.applied_cursor,
    }
    self.state.account_scope = scope_id
    self.state.outbox = {}
    self.state.rejected = {}
    self.state.resume_decisions = {}
    self.state.progress_holds = {}
    self.state.applied_cursor = "0"
    -- Pairing may reuse this installation's server device. Keep its sequence
    -- high-water mark across logout/account changes; gaps are harmless.
    self.state.last_error = nil
    self.state.inbox_dropped = nil
    -- El inbox y lo sincronizado de cada libro viven en otros archivos. Subir
    -- la generacion en el estado principal los invalida a todos en ESTE
    -- guardado: si la corriente se corta despues, ningun archivo de la cuenta
    -- anterior vuelve a leerse. Recien entonces se vacia el inbox, para que el
    -- texto de los subrayados del dueno anterior no quede en el disco.
    self.state.shard_epoch = self.state.shard_epoch + 1
    self.state.inbox_index = { total = 0, books = {} }
    self._inbox_events = {}
    self._books = {}
    self._dirty.books = {}
    self._dirty.inbox = false
    self:_save()
    self._dirty.inbox = true
    self:flush()
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
    self._inbox_events = {}
    self:_inboxChanged()
    self.state.last_error = nil
    self:_save()
    self.legacy_store:saveSetting("pending", {})
    self.legacy_store:flush()
end

return Queue

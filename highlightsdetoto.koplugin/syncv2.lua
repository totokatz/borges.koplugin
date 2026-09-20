local SyncV2 = {}
SyncV2.__index = SyncV2

local function resolve(value)
    return type(value) == "function" and value() or value
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
function SyncV2:pull(quick, focus_book, focus_only)
    local reading_context = focus_only and resolve(self.reading_context) or nil
    local response, err = self.web_api:postJSON(
        self:getBaseUrl() .. "/api/sync/v2/pull",
        self:getAuth(),
        {
            protocol_version = 2,
            cursor = self.queue:getCursor(),
            limit = self.pull_limit,
            focus_book = focus_book,
            focus_only = focus_only == true or nil,
            client = resolve(self.client) or {},
        },
        quick == true
    )
    if not response then
        self.queue:setLastError(err)
        return nil, err
    end
    if response.protocol_version ~= 2 then
        local protocol_err = self.web_api.apiError(
            "unsupported_protocol_response",
            "Server did not return Borges Sync v2.",
            nil,
            false,
            response.request_id
        )
        self.queue:setLastError(protocol_err)
        return nil, protocol_err
    end

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
            if action == true then self.queue:removeInboxEvent(event.event_id) end
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

function SyncV2:sync(force, quick)
    local events = self.queue:prepareBatch(nil, nil, force)
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

    local response, err = self.web_api:postJSON(url, self:getAuth(), payload, quick == true)
    if not response and #events > 0 and type(err) == "table"
        and err.code == "client_sequence_conflict"
        and self.queue:recoverSequences(err.details, events) then
        -- One recovery attempt per batch, never recursive. Accepted events in
        -- this batch keep their original ID/sequence and receive a duplicate ACK.
        events = self.queue:prepareBatch(nil, nil, true)
        payload.events = events
        response, err = self.web_api:postJSON(url, self:getAuth(), payload, quick == true)
    end
    if not response then
        self.queue:setLastError(err)
        return nil, err
    end
    if response.protocol_version ~= 2 then
        local protocol_err = self.web_api.apiError(
            "unsupported_protocol_response",
            "Server did not return Borges Sync v2.",
            nil,
            false,
            response.request_id
        )
        self.queue:setLastError(protocol_err)
        return nil, protocol_err
    end

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
    for page = 1, max_pages do
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

local random = require("random")

local Pairing = {}
Pairing.__index = Pairing

local REQUESTED_SCOPES = {
    "device:self",
    "sync:v2",
    "sync:legacy",
    "library:read",
    "plugin:update",
    "kosync",
}

local function required(value, name)
    if value == nil or value == "" then
        error(name .. " is required")
    end
    return value
end

local function absoluteUrl(base_url, value)
    if type(value) ~= "string" then return value end
    if value:match("^https?://") then return value end
    if value:sub(1, 1) == "/" then return base_url .. value end
    return base_url .. "/" .. value
end

function Pairing:new(options)
    options = options or {}
    local instance = {
        web_api = required(options.web_api, "web_api"),
        base_url = tostring(required(options.base_url, "base_url")):gsub("/+$", ""),
        save_pending = options.save_pending or function() end,
        clear_pending = options.clear_pending or function() end,
        commit_credential = options.commit_credential or function() end,
        now = options.now or os.time,
    }
    return setmetatable(instance, self)
end

function Pairing:start(options)
    options = options or {}
    local nonce = random.uuid(false):lower()
    local response, err = self.web_api:postJSON(
        self.base_url .. "/api/devices/pairing/request",
        nil,
        {
            device_nonce = nonce,
            device_name = required(options.device_name, "device_name"),
            platform = options.platform or "koreader",
            external_id = options.install_id,
            firmware_version = options.firmware_version,
            client_version = options.client_version,
            protocol_version = 2,
            requested_scopes = options.requested_scopes or REQUESTED_SCOPES,
            capabilities = options.capabilities or {
                progress = true,
                sessions = true,
                page_stats = true,
                annotations = true,
                library_download = true,
                updater = true,
                durable_outbox = true,
            },
        },
        true
    )
    if not response then return nil, err end

    local state = {
        request_id = response.request_id,
        device_nonce = nonce,
        user_code = response.user_code,
        verification_url = absoluteUrl(self.base_url, response.verification_url),
        expires_at = response.expires_at,
        expires_in = response.expires_in,
        interval = response.interval or 5,
        requested_at = self.now(),
        status = "pending",
    }
    self.save_pending(state)

    if options.legacy_api_key and options.legacy_api_key ~= "" then
        local approved, approval_err = self:autoApprove(state, options.legacy_api_key)
        if not approved then return state, approval_err end
        return self:claim(state)
    end
    return state
end

function Pairing:autoApprove(state, legacy_api_key)
    local response, err = self.web_api:postJSON(
        self.base_url .. "/api/devices/pairing/approve",
        { api_key = legacy_api_key },
        { user_code = required(state.user_code, "user_code") },
        true
    )
    if not response then return nil, err end
    state.status = response.status or "approved"
    self.save_pending(state)
    return response
end

function Pairing:status(state)
    local response, err = self.web_api:postJSON(
        self.base_url .. "/api/devices/pairing/status",
        nil,
        {
            request_id = required(state.request_id, "request_id"),
            device_nonce = required(state.device_nonce, "device_nonce"),
        },
        true
    )
    if not response then return nil, err end
    state.status = response.status
    state.expires_at = response.expires_at or state.expires_at
    self.save_pending(state)
    return response
end

function Pairing:claim(state)
    local response, err = self.web_api:postJSON(
        self.base_url .. "/api/devices/pairing/claim",
        nil,
        {
            request_id = required(state.request_id, "request_id"),
            device_nonce = required(state.device_nonce, "device_nonce"),
        },
        true
    )
    if not response then return nil, err end

    local token = response.credential and response.credential.token
    local expected_device_id = response.device and response.device.id
    if not token or not expected_device_id then
        return nil, self.web_api.apiError(
            "invalid_pairing_response",
            "Pairing response did not contain a device credential.",
            nil,
            false
        )
    end

    local self_response, self_err = self.web_api:getJSON(
        self.base_url .. "/api/devices/self",
        { token = token },
        true
    )
    if not self_response then return nil, self_err end
    if not self_response.device or self_response.device.id ~= expected_device_id then
        return nil, self.web_api.apiError(
            "pairing_identity_mismatch",
            "Claimed credential belongs to an unexpected device.",
            nil,
            false
        )
    end

    self.commit_credential(response)
    self.clear_pending()
    return response
end

function Pairing:resume(state)
    if type(state) ~= "table" or not state.request_id or not state.device_nonce then
        return nil, self.web_api.apiError(
            "pairing_not_pending",
            "No pairing request is pending.",
            nil,
            false
        )
    end
    local status, err = self:status(state)
    if not status then return nil, err end
    if status.status == "approved" then
        return self:claim(state)
    end
    if status.status == "pending" then
        return state
    end
    self.clear_pending()
    return nil, self.web_api.apiError(
        "pairing_" .. tostring(status.status or "failed"),
        "Pairing request is no longer claimable.",
        nil,
        false
    )
end

-- One scheduled check at a time. The private nonce never leaves this device
-- except in authenticated proof requests; only the short code is shown.
function Pairing:stopWatching()
    if self.watch_task then self.scheduler:unschedule(self.watch_task) end
    self.watch_task = nil
end

function Pairing:watch(state, scheduler, on_done, is_online)
    self:stopWatching()
    self.scheduler = scheduler
    local deadline = (state.requested_at or self.now()) + (state.expires_in or 300)
    local function tick()
        if self.now() >= deadline then
            self:stopWatching()
            self.clear_pending()
            on_done(nil, { code = "pairing_expired" })
            return
        end
        local result, err
        if not is_online or is_online() then result, err = self:resume(state) end
        if result and result.credential then
            self:stopWatching()
            on_done(result)
            return
        end
        local terminal = err and (err.code == "pairing_expired"
            or err.code == "pairing_rejected" or err.code == "pairing_not_found"
            or err.code == "pairing_already_claimed")
        if terminal then
            self:stopWatching()
            self.clear_pending()
            on_done(nil, err)
            return
        end
        scheduler:scheduleIn(math.max(3, state.interval or 5), self.watch_task)
    end
    self.watch_task = tick
    scheduler:scheduleIn(math.max(3, state.interval or 5), tick)
end

Pairing.REQUESTED_SCOPES = REQUESTED_SCOPES

return Pairing

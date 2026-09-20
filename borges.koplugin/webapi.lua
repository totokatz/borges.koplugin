local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local _ = require("i18n")
local Background = require("backgroundsync")

local WebApi = {}

local QUICK_BLOCK_TIMEOUT = 5
local QUICK_TOTAL_TIMEOUT = 10

local Error = {}
Error.__index = Error
function Error:__tostring()
    return self.message or self.code or _("Unknown error")
end

local function apiError(code, message, http_status, retryable, request_id, details)
    return setmetatable({
        code = code or "request_failed",
        message = message or _("Request failed"),
        http_status = http_status,
        retryable = retryable == true,
        request_id = request_id,
        details = details,
    }, Error)
end

local function authHeaders(auth)
    if type(auth) == "table" then
        if auth.token and auth.token ~= "" then
            return { ["Authorization"] = "Bearer " .. auth.token }
        end
        if auth.api_key and auth.api_key ~= "" then
            return { ["x-api-key"] = auth.api_key }
        end
        return {}
    end
    if type(auth) == "string" and auth ~= "" then
        return { ["x-api-key"] = auth }
    end
    return {}
end

local function mergeHeaders(target, source)
    for key, value in pairs(source or {}) do
        target[key] = value
    end
    return target
end

local function requestFor(url)
    return url:match("^http://") and http.request or https.request
end

local function timeoutValues(quick)
    if quick then return QUICK_BLOCK_TIMEOUT, QUICK_TOTAL_TIMEOUT end
    return socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT
end

local function decodeResponse(body)
    if not body or body == "" then return {} end
    local ok, decoded = pcall(rapidjson.decode, body)
    if ok and type(decoded) == "table" then return decoded end
    return nil
end

local function responseError(code, headers, status, body)
    local decoded = decodeResponse(body)
    local envelope = decoded and decoded.error or decoded
    local request_id = decoded and (decoded.request_id or decoded.requestId)
        or (headers and (headers["x-request-id"] or headers["X-Request-Id"]))
    local error_code = envelope and envelope.code
    local message = envelope and (envelope.message or envelope.error)
    local retryable = envelope and envelope.retryable

    if code == 401 then
        error_code = error_code or "invalid_credentials"
        message = message or _("Invalid device credential.")
    elseif code == 403 then
        error_code = error_code or "insufficient_scope"
        message = message or _("This device credential lacks the required permission.")
    elseif code == 429 then
        error_code = error_code or "rate_limited"
        message = message or _("Too many requests. Please retry later.")
        retryable = true
    elseif code >= 500 then
        error_code = error_code or "server_unavailable"
        message = message or _("Server is temporarily unavailable.")
        retryable = retryable ~= false
    else
        error_code = error_code or "http_error"
        message = message or string.format(_("HTTP error %s"), tostring(code))
    end

    return apiError(
        error_code,
        message,
        code,
        retryable,
        request_id,
        envelope and envelope.details
    )
end

--- Perform an HTTP request and return decoded JSON plus response metadata.
-- `auth` may be `{ token = "..." }`, `{ api_key = "..." }`, a legacy key string, or nil.
function WebApi:requestJSON(method, url, auth, payload, quick, extra_headers)
    if Background.current() then
        local result, err, meta = Background.request(function()
            return self:_requestJSONSync(method, url, auth, payload, quick, extra_headers)
        end)
        if type(err) == "table" then setmetatable(err, Error) end
        return result, err, meta
    end
    return self:_requestJSONSync(method, url, auth, payload, quick, extra_headers)
end

function WebApi:_requestJSONSync(method, url, auth, payload, quick, extra_headers)
    local body = payload ~= nil and rapidjson.encode(payload) or nil
    local response_body = {}
    local headers = mergeHeaders({
        ["Accept"] = "application/json",
    }, authHeaders(auth))
    mergeHeaders(headers, extra_headers)
    if body then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end

    local block_timeout, total_timeout = timeoutValues(quick)
    local ok, code, response_headers, status = pcall(function()
        socketutil:set_timeout(block_timeout, total_timeout)
        local request = {
            url = url,
            method = method,
            headers = headers,
            sink = ltn12.sink.table(response_body),
        }
        if body then request.source = ltn12.source.string(body) end
        local c, h, s = socket.skip(1, requestFor(url)(request))
        socketutil:reset_timeout()
        return c, h, s
    end)

    if not ok then
        socketutil:reset_timeout()
        logger.warn("Borges: HTTP request failed:", method, url, tostring(code))
        return nil, apiError(
            "connection_failed",
            _("Connection failed. Check WiFi and server URL."),
            nil,
            true
        )
    end

    local response = table.concat(response_body)
    if not code then
        return nil, apiError(
            "connection_failed",
            _("Connection failed. Check WiFi and server URL."),
            nil,
            true
        )
    end
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then
        logger.warn("Borges: HTTP error:", method, url, tostring(code), tostring(status))
        return nil, responseError(code or 0, response_headers, status, response)
    end

    local decoded = decodeResponse(response)
    if not decoded then
        return nil, apiError(
            "invalid_response",
            _("Failed to parse server response."),
            code,
            false,
            response_headers and response_headers["x-request-id"]
        )
    end
    return decoded, nil, {
        http_status = code,
        headers = response_headers or {},
        request_id = response_headers and response_headers["x-request-id"],
    }
end

function WebApi:postJSON(url, auth, payload, quick)
    return self:requestJSON("POST", url, auth, payload, quick)
end

function WebApi:getJSON(url, auth, quick)
    return self:requestJSON("GET", url, auth, nil, quick)
end

--- Download a file with paired or legacy authentication.
function WebApi:downloadFile(url, auth, dest_path)
    local file, file_err = io.open(dest_path, "wb")
    if not file then
        return false, apiError(
            "destination_unavailable",
            file_err or _("Could not open destination file"),
            nil,
            false
        )
    end

    local ok, code, response_headers, status = pcall(function()
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local c, h, s = socket.skip(1, requestFor(url)({
            url = url,
            method = "GET",
            headers = authHeaders(auth),
            sink = ltn12.sink.file(file),
        }))
        socketutil:reset_timeout()
        return c, h, s
    end)
    pcall(function() file:close() end)

    if not ok then
        socketutil:reset_timeout()
        pcall(os.remove, dest_path)
        logger.warn("Borges: download failed:", tostring(code))
        return false, apiError(
            "connection_failed",
            _("Download failed. Check WiFi and server URL."),
            nil,
            true
        )
    end
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then
        pcall(os.remove, dest_path)
        return false, responseError(code or 0, response_headers, status, "")
    end
    return true
end

WebApi.Error = Error
WebApi.apiError = apiError

return WebApi

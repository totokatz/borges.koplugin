local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local logger = require("logger")
local _ = require("i18n")

local DropboxApi = {
    APP_KEY = nil,
    APP_SECRET = nil,
    access_token = nil,
    refresh_token = nil,
    token_expiry = 0,

    AUTH_URL = "https://www.dropbox.com/oauth2/authorize",
    TOKEN_URL = "https://api.dropboxapi.com/oauth2/token",
    UPLOAD_URL = "https://content.dropboxapi.com/2/files/upload",
}

--- Initialize with settings table (loaded from plugin config).
-- @param settings table with keys: app_key, app_secret, access_token, refresh_token, token_expiry
function DropboxApi:init(settings)
    settings = settings or {}
    self.APP_KEY = settings.app_key
    self.APP_SECRET = settings.app_secret
    self.access_token = settings.access_token
    self.refresh_token = settings.refresh_token
    self.token_expiry = settings.token_expiry or 0
end

--- Get current token settings for persistence.
-- @return table settings to save
function DropboxApi:getSettings()
    return {
        app_key = self.APP_KEY,
        app_secret = self.APP_SECRET,
        access_token = self.access_token,
        refresh_token = self.refresh_token,
        token_expiry = self.token_expiry,
    }
end

--- Check if we have valid credentials configured.
-- @return boolean
function DropboxApi:isConfigured()
    return self.APP_KEY ~= nil and self.APP_KEY ~= ""
        and self.refresh_token ~= nil and self.refresh_token ~= ""
end

--- Generate the OAuth2 authorization URL for the user to visit.
-- Uses token_access_type=offline to get a refresh_token.
-- @return string URL to open in browser
function DropboxApi:getAuthorizationUrl()
    if not self.APP_KEY or self.APP_KEY == "" then
        return nil, _("App Key not configured")
    end
    local url = self.AUTH_URL
        .. "?client_id=" .. self.APP_KEY
        .. "&response_type=code"
        .. "&token_access_type=offline"
    return url
end

--- Make an HTTP POST request with form-encoded body.
-- Uses socket.skip(1, ...) to correctly handle LuaSocket table-mode return values.
-- @param url string
-- @param params table key-value pairs for POST body
-- @return table|nil decoded JSON response, string|nil error message
function DropboxApi:postForm(url, params)
    local body_parts = {}
    for k, v in pairs(params) do
        table.insert(body_parts, k .. "=" .. v)
    end
    local body = table.concat(body_parts, "&")

    local response_body = {}

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, https.request({
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_body),
    }))
    socketutil:reset_timeout()

    if not code or (type(code) == "number" and code ~= 200) then
        local resp_str = table.concat(response_body)
        logger.warn("Borges: Dropbox POST failed:", code, status, resp_str)
        return nil, string.format(_("HTTP error %s: %s"), tostring(code), resp_str)
    end

    local resp_str = table.concat(response_body)
    local ok, data = pcall(rapidjson.decode, resp_str)
    if not ok then
        return nil, _("Failed to parse Dropbox response")
    end
    return data
end

--- Exchange an authorization code for access + refresh tokens.
-- @param auth_code string the code from the OAuth2 redirect
-- @return boolean success, string|nil error message
function DropboxApi:exchangeAuthCode(auth_code)
    if not auth_code or auth_code == "" then
        return false, _("Authorization code is empty")
    end

    local data, err = self:postForm(self.TOKEN_URL, {
        code = auth_code,
        grant_type = "authorization_code",
        client_id = self.APP_KEY,
        client_secret = self.APP_SECRET,
    })

    if not data then
        return false, err or _("Failed to exchange authorization code")
    end

    if data.error then
        return false, data.error_description or data.error
    end

    self.access_token = data.access_token
    self.refresh_token = data.refresh_token
    -- Dropbox tokens typically expire in 4 hours (14400 seconds)
    self.token_expiry = os.time() + (data.expires_in or 14400) - 300 -- 5 min buffer
    return true
end

--- Refresh the access token using the stored refresh token.
-- @return boolean success, string|nil error message
function DropboxApi:refreshAccessToken()
    if not self.refresh_token or self.refresh_token == "" then
        return false, _("No refresh token available. Please re-authorize.")
    end

    local data, err = self:postForm(self.TOKEN_URL, {
        refresh_token = self.refresh_token,
        grant_type = "refresh_token",
        client_id = self.APP_KEY,
        client_secret = self.APP_SECRET,
    })

    if not data then
        return false, err or _("Failed to refresh access token")
    end

    if data.error then
        return false, data.error_description or data.error
    end

    self.access_token = data.access_token
    self.token_expiry = os.time() + (data.expires_in or 14400) - 300
    -- Note: Dropbox does NOT return a new refresh_token on refresh
    return true
end

--- Ensure we have a valid (non-expired) access token.
-- Refreshes automatically if needed.
-- @return boolean success, string|nil error message
function DropboxApi:ensureValidToken()
    if not self:isConfigured() then
        return false, _("Dropbox not configured. Please set up App Key and authorize.")
    end

    -- Check if token is still valid (with 5-minute buffer already applied)
    if self.access_token and os.time() < self.token_expiry then
        return true
    end

    -- Token expired or missing, try to refresh
    logger.info("Borges: Access token expired, refreshing...")
    return self:refreshAccessToken()
end

--- Upload a file to Dropbox.
-- @param dropbox_path string full path in Dropbox (e.g., "/Apps/Borges/file.json")
-- @param content string file content to upload
-- @return boolean success, string|nil error message
function DropboxApi:uploadFile(dropbox_path, content)
    local ok, err = self:ensureValidToken()
    if not ok then
        return false, err
    end

    local api_arg = rapidjson.encode({
        path = dropbox_path,
        mode = "overwrite",
        autorename = false,
        mute = true, -- Don't notify the user about the upload
    })

    local response_body = {}

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, https.request({
        url = self.UPLOAD_URL,
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. self.access_token,
            ["Dropbox-API-Arg"] = api_arg,
            ["Content-Type"] = "application/octet-stream",
            ["Content-Length"] = tostring(#content),
        },
        source = ltn12.source.string(content),
        sink = ltn12.sink.table(response_body),
    }))
    socketutil:reset_timeout()

    if not code or (type(code) == "number" and code ~= 200) then
        local resp_str = table.concat(response_body)
        logger.warn("Borges: Upload failed:", code, status, resp_str)

        -- If 401, try refreshing token once and retry
        if code == 401 then
            logger.info("Borges: Got 401, attempting token refresh and retry...")
            local refresh_ok, refresh_err = self:refreshAccessToken()
            if not refresh_ok then
                return false, refresh_err
            end
            return self:uploadFile(dropbox_path, content)
        end

        return false, string.format(_("Upload failed (HTTP %s): %s"), tostring(code), resp_str)
    end

    logger.info("Borges: Uploaded successfully to", dropbox_path)
    return true
end

return DropboxApi

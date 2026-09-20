--- C06 · Entrar al servicio desde el lector con usuario y contraseña.
--
-- Hasta C05 un lector sólo entraba de dos formas: el pareo con código —que
-- obliga a tener la web abierta al lado del Kobo— o la clave maestra del
-- servidor, que no puede viajar a un dispositivo. Este módulo usa la tercera:
-- el mismo usuario/contraseña de la web, una sola vez, a cambio de UNA
-- credencial de dispositivo.
--
-- Tres reglas mandan sobre el resto:
--
--  1. La contraseña se usa y se tira. Nunca se guarda, ni en settings ni en
--     `web_config.json`; lo único que persiste es el token del dispositivo.
--  2. El token se verifica contra `/api/devices/self` ANTES de escribirlo,
--     igual que hace el pareo. Un servidor que contesta cualquier cosa no
--     deja al lector con una credencial que no es suya.
--  3. TLS no es opcional. Un `http://` no llega a mandar la contraseña: el
--     servidor la rechazaría igual, pero el lector no puede enterarse recién
--     después de haberla puesto en el cable.

local Pairing = require("pairing")
local _ = require("i18n")

local Login = {}
Login.__index = Login

local LOGIN_PATH = "/api/devices/v1/login"
local SELF_PATH = "/api/devices/self"
local ROTATE_PATH = "/api/devices/self/credentials/rotate"

-- Mismo juego que pide el pareo. El servidor otorga el set completo por
-- defecto; pedirlo explícito deja escrito qué necesita este cliente.
local REQUESTED_SCOPES = Pairing.REQUESTED_SCOPES

local DEFAULT_CAPABILITIES = {
    progress = true,
    sessions = true,
    page_stats = true,
    annotations = true,
    library_download = true,
    updater = true,
    durable_outbox = true,
}

local function required(value, name)
    if value == nil or value == "" then
        error(name .. " is required")
    end
    return value
end

local function trim(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Login:new(options)
    options = options or {}
    return setmetatable({
        web_api = required(options.web_api, "web_api"),
        base_url = options.base_url,
        commit_credential = options.commit_credential or function() end,
        now = options.now or os.time,
    }, self)
end

function Login:getBaseUrl()
    local value = self.base_url
    if type(value) == "function" then value = value() end
    return (tostring(value or ""):gsub("/+$", ""))
end

--- Entrar con usuario y contraseña y quedarse sólo con el token.
--
-- Devuelve la respuesta completa del servidor. El llamador decide qué hacer
-- con ella —un cambio de cuenta necesita confirmar antes de pisar la cola—,
-- así que este módulo no escribe settings por su cuenta salvo que le pasen
-- `commit_credential`.
function Login:signIn(options)
    options = options or {}
    local base_url = self:getBaseUrl()
    if base_url == "" then
        return nil, self.web_api.apiError(
            "server_not_configured",
            _("Configure the server URL first."),
            nil,
            false
        )
    end
    if not base_url:match("^https://") then
        -- La contraseña no sale del lector por un canal sin cifrar.
        return nil, self.web_api.apiError(
            "tls_required",
            _("The server URL must use https:// to sign in."),
            nil,
            false
        )
    end

    local username = trim(options.username)
    if username == "" then
        return nil, self.web_api.apiError(
            "username_required",
            _("Enter your username or email."),
            nil,
            false
        )
    end
    local password = options.password
    if type(password) ~= "string" or password == "" then
        return nil, self.web_api.apiError(
            "password_required",
            _("Enter your password."),
            nil,
            false
        )
    end

    -- `external_id` es lo único que hace que reintentar el login caiga siempre
    -- en la misma fila de `devices`. Sin un id estable el servidor fabricaría
    -- un lector nuevo por cada intento, así que acá es obligatorio.
    local external_id = trim(options.external_id)
    if external_id == "" then
        return nil, self.web_api.apiError(
            "install_id_missing",
            _("This install has no stable device id yet."),
            nil,
            false
        )
    end

    local response, err = self.web_api:postJSON(
        base_url .. LOGIN_PATH,
        nil,
        {
            username = username,
            password = password,
            platform = options.platform or "koreader",
            external_id = external_id,
            device_name = options.device_name,
            firmware_version = options.firmware_version,
            client_version = options.client_version,
            protocol_version = 2,
            scopes = options.requested_scopes or REQUESTED_SCOPES,
            capabilities = options.capabilities or DEFAULT_CAPABILITIES,
        },
        true
    )
    -- La contraseña ya viajó: que no quede viva en este stack más de lo
    -- necesario. El llamador tiene la suya y la descarta al cerrar el diálogo.
    password = nil

    if not response then return nil, err end

    local verified, verify_err = self:verify(response)
    if not verified then return nil, verify_err end

    self.commit_credential(response)
    return response
end

--- Confirmar que el token recién emitido es de ESTE dispositivo.
--
-- Mismo chequeo que hace el pareo antes de commitear: un servidor equivocado
-- —o una respuesta a medias— no deja al lector hablando por una credencial
-- que no le corresponde.
function Login:verify(response)
    local credential = type(response) == "table" and response.credential or nil
    local device = type(response) == "table" and response.device or nil
    local token = credential and credential.token
    local expected_device_id = device and device.id
    if type(token) ~= "string" or token == ""
        or type(expected_device_id) ~= "string" or expected_device_id == "" then
        return nil, self.web_api.apiError(
            "invalid_login_response",
            _("Login response did not contain a device credential."),
            nil,
            false
        )
    end

    local self_response, self_err = self.web_api:getJSON(
        self:getBaseUrl() .. SELF_PATH,
        { token = token },
        true
    )
    if not self_response then return nil, self_err end
    if not self_response.device or self_response.device.id ~= expected_device_id then
        return nil, self.web_api.apiError(
            "login_identity_mismatch",
            _("The issued credential belongs to an unexpected device."),
            nil,
            false
        )
    end
    return self_response
end

--- Renovar el token sin volver a pedir la contraseña.
--
-- Es lo que hace que "reinicio → sync" siga funcionando meses después: el
-- servidor publica `renew_after` y el lector rota antes de llegar al final.
-- Sin plazo pedido, la sucesora hereda la ventana de la anterior.
function Login:rotate(auth)
    if type(auth) ~= "table" or not auth.token or auth.token == "" then
        return nil, self.web_api.apiError(
            "not_connected",
            _("This device is not signed in."),
            nil,
            false
        )
    end
    local response, err = self.web_api:postJSON(
        self:getBaseUrl() .. ROTATE_PATH,
        auth,
        {},
        true
    )
    if not response then return nil, err end
    local credential = response.credential
    if not credential or type(credential.token) ~= "string" or credential.token == "" then
        return nil, self.web_api.apiError(
            "invalid_rotation_response",
            _("Rotation response did not contain a credential."),
            nil,
            false
        )
    end
    return response
end

--- ¿Este error dice que la credencial guardada ya no sirve?
--
-- El servidor contesta 401 `invalid_credentials` tanto para un token vencido
-- como para uno revocado: para el lector las dos cosas significan lo mismo,
-- volver a entrar. Un 403 `device_revoked` es el caso explícito del dueño que
-- desvinculó el lector desde la web.
function Login.isCredentialRejection(err)
    if type(err) ~= "table" then return false end
    if err.http_status == 401 then return true end
    local code = err.code
    return code == "invalid_credentials"
        or code == "device_revoked"
        or code == "credential_revoked"
        or code == "credential_expired"
end

--- Texto que el lector puede leer sin conocer el contrato.
function Login.describeError(err)
    if type(err) ~= "table" then return _("Unknown error") end
    local code = err.code
    if code == "invalid_credentials" then
        return _("Wrong username or password.")
    elseif code == "email_not_verified" then
        return _("Confirm your email on the web before linking this reader.")
    elseif code == "device_revoked" then
        return _("This reader was unlinked. Re-enable it from the web, then sign in again.")
    elseif code == "device_limit_reached" then
        return _("This account reached its reader limit. Unlink one from the web.")
    elseif code == "rate_limited" then
        return _("Too many attempts. Wait a few minutes and try again.")
    elseif code == "tls_required" then
        return _("The server URL must use https:// to sign in.")
    elseif code == "scope_not_granted" then
        return _("This account does not grant one of the permissions this plugin needs.")
    elseif code == "login_unavailable" then
        return _("Sign-in is temporarily unavailable. Try again in a moment.")
    elseif code == "connection_failed" then
        return _("Connection failed. Check WiFi and the server URL.")
    end
    return err.message or tostring(code or _("Unknown error"))
end

Login.REQUESTED_SCOPES = REQUESTED_SCOPES
Login.DEFAULT_CAPABILITIES = DEFAULT_CAPABILITIES

return Login

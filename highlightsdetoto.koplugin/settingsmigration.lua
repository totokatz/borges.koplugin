local random = require("random")

local SettingsMigration = {
    CURRENT_VERSION = 3,
    -- C06 · Servidor oficial por defecto. El paquete se instala genérico: sin
    -- claves, sin URL para tipear y sin nada que el dueño tenga que copiar a
    -- mano. Quien se autohospede la cambia desde el menú.
    DEFAULT_SERVER_BASE_URL = "https://highlights.runadev.com",
}

local CONNECTION_DISCONNECTED = "disconnected"
local CONNECTION_CONNECTED = "connected"
local CONNECTION_EXPIRED = "expired"

local function nonEmpty(value)
    return type(value) == "string" and value ~= "" and value or nil
end

local function normalizeBaseUrl(value)
    local url = nonEmpty(value)
    if not url then return "" end
    url = url:gsub("%s+$", ""):gsub("/+$", "")
    return url:match("^(https?://[^/]+)") or url
end

local function makeInstallId()
    return random.uuid(true):lower()
end

--- Días desde 1970-01-01 para una fecha civil UTC (algoritmo de Hinnant).
--
-- No se usa `os.time` a propósito: interpreta la fecha en hora local —hay que
-- corregirla— y en los Kobo con `time_t` de 32 bits devuelve basura para
-- cualquier fecha posterior a 2038. Un vencimiento de credencial cae
-- justamente en el futuro, así que la cuenta se hace a mano.
local function daysFromCivil(year, month, day)
    if month <= 2 then year = year - 1 end
    local era = math.floor((year >= 0 and year or year - 399) / 400)
    local yoe = year - era * 400
    local doy = math.floor((153 * (month + (month > 2 and -3 or 9)) + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- Epoch de un timestamp ISO-8601 en UTC, o nil si no se entiende.
local function parseIso8601(value)
    if type(value) ~= "string" then return nil end
    local year, month, day, hour, minute, second = value:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)"
    )
    if not year then return nil end
    month, day = tonumber(month), tonumber(day)
    if month < 1 or month > 12 or day < 1 or day > 31 then return nil end
    -- En coma flotante a propósito: un vencimiento de 2098 pasa los 2^31
    -- segundos y la aritmética entera lo daría vuelta a negativo, que es
    -- exactamente el bug de 2038 que este parser existe para esquivar.
    return daysFromCivil(tonumber(year), month, day) * 86400.0
        + tonumber(hour) * 3600.0
        + tonumber(minute) * 60.0
        + tonumber(second)
end

--- Idempotently normalize old KOReader/plugin-file settings into schema v3.
-- The legacy key is intentionally retained until a verified credential lands.
function SettingsMigration.migrate(settings, web_config)
    settings = type(settings) == "table" and settings or {}
    web_config = type(web_config) == "table" and web_config or {}

    local web_url = nonEmpty(web_config.url)
        or nonEmpty(settings.web_url)
        or nonEmpty(settings.server_url)
        or ""
    local base_url = normalizeBaseUrl(
        nonEmpty(web_config.base_url) or nonEmpty(settings.server_base_url) or web_url
    )
    -- Una instalación limpia ya apunta al servicio oficial. Una instalación
    -- previa conserva su URL: migrar no puede mudarle el servidor a nadie.
    if base_url == "" then
        base_url = SettingsMigration.DEFAULT_SERVER_BASE_URL
    end
    if web_url == "" or web_url == base_url then
        web_url = base_url .. "/api/sync"
    end
    settings.web_url = web_url
    settings.server_base_url = base_url

    settings.device_token = nonEmpty(settings.device_token)
        or nonEmpty(web_config.device_token)
    settings.device_credential_id = nonEmpty(settings.device_credential_id)
        or nonEmpty(web_config.device_credential_id)
    settings.paired_device_id = nonEmpty(settings.paired_device_id)
        or nonEmpty(web_config.paired_device_id)
    settings.web_api_key = nonEmpty(settings.web_api_key)
        or nonEmpty(web_config.api_key)
        or ""
    settings.install_id = nonEmpty(settings.install_id)
        or nonEmpty(web_config.install_id)
        or makeInstallId()
    settings.account_username = nonEmpty(settings.account_username)
    settings.credential_expires_at = nonEmpty(settings.credential_expires_at)
    settings.credential_renew_after = nonEmpty(settings.credential_renew_after)
    settings.credential_rejected_at = tonumber(settings.credential_rejected_at)
    settings.pairing = type(settings.pairing) == "table" and settings.pairing or nil
    settings.settings_schema_version = SettingsMigration.CURRENT_VERSION
    return settings
end

function SettingsMigration.getAuth(settings)
    if type(settings) ~= "table" then return nil end
    if nonEmpty(settings.device_token) then
        return { token = settings.device_token }
    end
    if nonEmpty(settings.web_api_key) then
        return { api_key = settings.web_api_key }
    end
    return nil
end

function SettingsMigration.hasPairedCredential(settings)
    return type(settings) == "table"
        and nonEmpty(settings.device_token) ~= nil
        and nonEmpty(settings.paired_device_id) ~= nil
end

--- Estado de conexión que ve el lector: no conectado, conectado o vencido.
--
-- El reloj local NO decide esto. Un Kobo que estuvo meses apagado vuelve con
-- la fecha en cualquier lado, y declarar "sesión vencida" por eso dejaría al
-- lector pidiendo contraseña cuando su token sigue siendo perfectamente
-- válido. Lo único que marca vencimiento es que el servidor haya rechazado la
-- credencial; el vencimiento local se usa para rotar, no para desconectar.
function SettingsMigration.connectionState(settings)
    if not SettingsMigration.hasPairedCredential(settings) then
        return CONNECTION_DISCONNECTED
    end
    if settings.credential_rejected_at then
        return CONNECTION_EXPIRED
    end
    return CONNECTION_CONNECTED
end

--- ¿Conviene rotar el token antes de que venza? Pista, no veredicto.
function SettingsMigration.needsRenewal(settings, now)
    if not SettingsMigration.hasPairedCredential(settings) then return false end
    local renew_after = parseIso8601(settings.credential_renew_after)
    if not renew_after then return false end
    return (now or os.time()) >= renew_after
end

--- El servidor rechazó la credencial guardada: pedir login de nuevo.
-- No se borra el token ni la cola: si el rechazo fue un error transitorio del
-- servidor, un intento posterior lo revierte sin perder nada.
function SettingsMigration.markCredentialRejected(settings, now)
    if type(settings) ~= "table" then return false end
    if not SettingsMigration.hasPairedCredential(settings) then return false end
    if settings.credential_rejected_at then return false end
    settings.credential_rejected_at = now or os.time()
    return true
end

--- El servidor volvió a aceptar la credencial: la sesión nunca estuvo vencida.
function SettingsMigration.markCredentialAccepted(settings)
    if type(settings) ~= "table" then return false end
    if not settings.credential_rejected_at then return false end
    settings.credential_rejected_at = nil
    return true
end

--- ¿Esta respuesta de login corresponde a otra cuenta que la guardada?
--
-- El ancla es el id del dispositivo: la identidad del servidor es
-- (cuenta, plataforma, external_id), así que la misma instalación entrando con
-- otra cuenta recibe SIEMPRE otro id. El username se mira además porque es lo
-- que el lector puede comparar antes de mandar la contraseña.
function SettingsMigration.isAccountSwitch(settings, result)
    if type(settings) ~= "table" or type(result) ~= "table" then return false end
    local previous_device = nonEmpty(settings.paired_device_id)
    if not previous_device then return false end
    local device_id = result.device and nonEmpty(result.device.id)
    if device_id and device_id ~= previous_device then return true end
    local previous_user = nonEmpty(settings.account_username)
    local username = result.account and nonEmpty(result.account.username)
    if previous_user and username and previous_user:lower() ~= username:lower() then
        return true
    end
    return false
end

--- Lo mismo, con el username tipeado y antes de mandar la contraseña.
function SettingsMigration.willSwitchAccount(settings, username)
    if type(settings) ~= "table" then return false end
    if not SettingsMigration.hasPairedCredential(settings) then return false end
    local previous = nonEmpty(settings.account_username)
    local typed = nonEmpty(username)
    if not previous or not typed then return false end
    return previous:lower() ~= typed:lower()
end

--- Borrar todo lo que pertenece a la cuenta anterior.
--
-- Son los mapas que dicen "este libro ya está sincronizado" y "esta anotación
-- ya viajó". Con otra cuenta del otro lado esos apuntes mienten: harían que el
-- lector diera por subido lo que la cuenta nueva no tiene, o que pisara datos
-- ajenos. Los EPUB descargados quedan en el disco —son del lector, no del
-- servicio— pero dejan de contar como sincronizados.
function SettingsMigration.clearAccountScopedState(settings)
    if type(settings) ~= "table" then return settings end
    settings.synced_books = {}
    settings.annotation_v2_bridged = {}
    settings.last_web_sync = 0
    settings.last_progress_sync = 0
    settings.last_stats_sync = 0
    settings.last_stats_enqueued_at = 0
    settings.last_stats_error = nil
    -- C07 · El punto de retorno y la marca de "al día" describen la lectura de
    -- UNA cuenta. Heredarlos haría que el lector ofreciera volver a una página
    -- que la cuenta nueva nunca visitó.
    settings.last_full_sync = 0
    settings.position_undo = {}
    return settings
end

local function clearCredential(settings)
    settings.device_token = nil
    settings.device_credential_id = nil
    settings.paired_device_id = nil
    settings.account_username = nil
    settings.credential_expires_at = nil
    settings.credential_renew_after = nil
    settings.credential_rejected_at = nil
    settings.pairing = nil
end

--- Commit only a token already verified against `/api/devices/self`.
function SettingsMigration.completePairing(settings, claimed)
    if type(settings) ~= "table" or type(claimed) ~= "table" then
        return nil, "invalid_pairing_result"
    end
    local credential = claimed.credential
    local device = claimed.device
    local token = credential and nonEmpty(credential.token)
    local device_id = device and nonEmpty(device.id)
    if not token or not device_id then
        return nil, "incomplete_pairing_result"
    end

    settings.device_token = token
    settings.device_credential_id = nonEmpty(credential.id)
    settings.paired_device_id = device_id
    settings.device_id = device_id
    settings.credential_expires_at = nonEmpty(credential.expires_at)
    settings.credential_renew_after = nonEmpty(credential.renew_after)
    settings.credential_rejected_at = nil
    settings.pairing = nil
    settings.settings_schema_version = SettingsMigration.CURRENT_VERSION
    return settings
end

--- C06 · Guardar la credencial emitida por usuario/contraseña.
--
-- La contraseña NO entra acá. Lo que persiste es el token, su vencimiento y el
-- username —que sólo sirve para mostrar quién está conectado y para detectar
-- un cambio de cuenta en el próximo login.
function SettingsMigration.completeLogin(settings, result)
    if type(settings) ~= "table" or type(result) ~= "table" then
        return nil, "invalid_login_result"
    end
    local credential = result.credential
    local device = result.device
    local token = credential and nonEmpty(credential.token)
    local device_id = device and nonEmpty(device.id)
    if not token or not device_id then
        return nil, "incomplete_login_result"
    end

    settings.device_token = token
    settings.device_credential_id = nonEmpty(credential.id)
    settings.paired_device_id = device_id
    settings.device_id = device_id
    settings.account_username = result.account and nonEmpty(result.account.username)
    settings.credential_expires_at = nonEmpty(credential.expires_at)
    settings.credential_renew_after = nonEmpty(credential.renew_after)
    settings.credential_rejected_at = nil
    settings.pairing = nil
    settings.settings_schema_version = SettingsMigration.CURRENT_VERSION
    return settings
end

--- Guardar la sucesora de una rotación, sin tocar la identidad de la cuenta.
function SettingsMigration.completeRotation(settings, rotated)
    if type(settings) ~= "table" or type(rotated) ~= "table" then
        return nil, "invalid_rotation_result"
    end
    local credential = rotated.credential
    local token = credential and nonEmpty(credential.token)
    if not token then return nil, "incomplete_rotation_result" end
    if credential.device_id and settings.paired_device_id
        and credential.device_id ~= settings.paired_device_id then
        return nil, "rotation_identity_mismatch"
    end

    settings.device_token = token
    settings.device_credential_id = nonEmpty(credential.id)
        or settings.device_credential_id
    settings.credential_expires_at = nonEmpty(credential.expires_at)
        or settings.credential_expires_at
    -- El servidor no republica `renew_after` al rotar: la ventana anterior se
    -- consumió, así que se recalcula recién en el próximo login. Dejarla vieja
    -- haría que el lector rotara en cada arranque.
    settings.credential_renew_after = nil
    settings.credential_rejected_at = nil
    return settings
end

--- Salir de la cuenta en este lector. Local y sin red: el token queda
-- inutilizable acá y el dueño puede revocarlo desde la web cuando quiera.
function SettingsMigration.signOut(settings)
    if type(settings) ~= "table" then return nil, "invalid_settings" end
    clearCredential(settings)
    SettingsMigration.clearAccountScopedState(settings)
    settings.settings_schema_version = SettingsMigration.CURRENT_VERSION
    return settings
end

function SettingsMigration.retireLegacyCredential(settings)
    if not SettingsMigration.hasPairedCredential(settings) then
        return false
    end
    settings.web_api_key = ""
    return true
end

function SettingsMigration.normalizeBaseUrl(value)
    return normalizeBaseUrl(value)
end

function SettingsMigration.parseIso8601(value)
    return parseIso8601(value)
end

SettingsMigration.CONNECTION_DISCONNECTED = CONNECTION_DISCONNECTED
SettingsMigration.CONNECTION_CONNECTED = CONNECTION_CONNECTED
SettingsMigration.CONNECTION_EXPIRED = CONNECTION_EXPIRED

return SettingsMigration

local DataStorage = require("datastorage")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local logger = require("logger")
local rapidjson = require("rapidjson")
local _ = require("i18n")
local T = require("ffi/util").template

local Updater = require("updater")
local main_source = debug.getinfo(1, "S").source
local boot_plugin_dir = main_source and main_source:match("^@(.+)/main%.lua$")
    or (DataStorage:getDataDir() .. "/plugins/borges.koplugin")
Updater.recoverAtLoad(boot_plugin_dir)

local DropboxApi = require("dropboxapi")
local HighlightParser = require("highlightparser")
local WebApi = require("webapi")
local Session = require("session")
local Queue = require("queue")
local StatSync = require("statsync")
local SettingsMigration = require("settingsmigration")
local Pairing = require("pairing")
local Login = require("login")
local SyncV2 = require("syncv2")
local PositionLocator = require("positionlocator")
local TextLocate = require("textlocate")
local Background = require("backgroundsync")
local SleepBudget = require("sleepbudget")
local BookKey = require("bookkey")
local random = require("random")
local ProgressMessage = require("progressmessage")
local ReadingWifi = require("readingwifi")
local UpdateCheck = require("updatecheck")
local SyncRun = require("syncrun")
local Diagnostics = require("diagnostics")
local MenuTree = require("menutree")
local ReadingPosition = require("readingposition")
local ResumeFlow = require("resumeflow")
local AnnotationAdapter = require("annotationadapter")
local DocText = require("doctext")
local ReadingLog = require("readinglog")
local NavCause = require("navcause")
local Attention = require("attention")
local DeviceState = require("devicestate")
local ChapterTime = require("chaptertime")
local ui_time_ok, UITime = pcall(require, "ui/time")
if not ui_time_ok or type(UITime) ~= "table" then UITime = nil end
local datetime_ok, datetime = pcall(require, "datetime")
if not datetime_ok or type(datetime) ~= "table" then datetime = nil end
local Device = require("device")
local util = require("util")
local Screen = Device.screen

local HighlightsDeToto = WidgetContainer:extend{
    name = "borges",
    is_doc_only = false,
}

local SuspendSyncBanner = WidgetContainer:extend{
    text = "",
    face = nil,
}

function SuspendSyncBanner:init()
    self.face = self.face or Font:getFace("infofont")

    local textw = TextWidget:new{
        text = self.text,
        face = self.face,
    }
    if textw:getWidth() > Screen:getWidth() * 0.9 then
        textw = TextBoxWidget:new{
            text = self.text,
            face = self.face,
            width = math.floor(Screen:getWidth() * 0.9),
        }
    end

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.default,
        margin = 0,
        padding = 0,
        padding_left = Size.padding.default,
        padding_right = Size.padding.default,
        textw,
    }

    local screen = Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self[1] = CenterContainer:new{
        dimen = screen,
        BottomContainer:new{
            dimen = Geom:new{
                w = screen.w,
                h = screen.h - Size.margin.default,
            },
            self.frame,
        },
    }
end

function SuspendSyncBanner:onShow()
    UIManager:setDirty(self, function()
        return "ui", Screen:getSize()
    end)
    return true
end

function SuspendSyncBanner:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", Screen:getSize()
    end)
end

local DEFAULT_DROPBOX_PATH = "/Apps/Borges/"
local AUTO_SYNC_INTERVAL = 86400  -- 24 hours in seconds
local BATCH_SIZE = 3
local PROGRESS_DEBOUNCE = 60      -- seconds before auto-pushing progress after page activity
local PROGRESS_COOLDOWN = 180     -- minimum seconds between background progress pushes
local HIGHLIGHT_DEBOUNCE = 300    -- seconds of quiet before checking changed highlights
-- C17 · Dos eventos de red seguidos (asociación + DHCP, o un rebote de la
-- señal) no son dos reconexiones. Sin esta ventana el lector recibe dos
-- corridas encimadas y, con ellas, dos diálogos.
local RECONNECT_SYNC_DEBOUNCE = 25
-- Una posicion retenida se vuelve a consultar a lo sumo una vez por minuto y
-- por libro mientras haya red; al dormir o al cortarse el Wi-Fi, siempre.
local HELD_CHECK_INTERVAL = 60
local HELD_CHECK_MAX_BOOKS = 5
-- Entradas por pedido de la foto historica (ver `_bridgeHistoryInBackground`).
local BRIDGE_CHUNK_ENTRIES = 100
-- Segundos entre la consulta al servidor y la subida de lo pendiente. No es
-- una espera decorativa: le da lugar al aviso de posición para llegar a la
-- pantalla antes de que la cola vieja empiece a viajar.
local RECONNECT_DRAIN_DELAY = 5
-- C23 · Segundos entre el momento oportuno (arranque, reconexión) y la
-- pregunta por una versión nueva. Buscar versiones nunca compite con
-- sincronizar ni con la pregunta de posición: llega después, o no llega.
local PLUGIN_UPDATE_CHECK_DELAY = 30
-- Wi-Fi solo para sincronizar (ver la seccion del mismo nombre mas abajo).
-- Segundos entre conectar y apagar: alcanza para la consulta, el envio de lo
-- pendiente y la pregunta diaria por una version nueva.
local WIFI_OFF_DELAY = 40
local WIFI_OFF_RETRY = 15
local WIFI_OFF_MAX_TRIES = 8
-- Segundos que KOReader espera antes de dormir mientras el plugin conecta y
-- sube la lectura. KOReader da 15 y conectar tarda ~10 en un lector real.
local SLEEP_UPLOAD_WINDOW = 30
-- Segundos que se le dan a la conexion en segundo plano antes de darla por
-- fallida. El script de KOReader se rinde solo a los 15.
-- KOReader cuenta 180 consultas, no segundos: en un lector real se rinde a los
-- 64-67 s. Se sigue su bandera y esto es solo el techo.
local QUIET_CONNECT_TIMEOUT = 90
local QUIET_CONNECT_POLL = 1
-- Sesiones seguidas en las que conectar en silencio fallo y conectar por el
-- camino comun anduvo, antes de apagar la opcion sola.
local QUIET_MISS_LIMIT = 2
local OLD_DEFAULT_LIBRARY_DIR = "/mnt/onboard/HighlightsDeToto"
local DEFAULT_LIBRARY_DIR = "/mnt/onboard/Libros"

-- Postgres devuelve NUMERIC como string ("100.00"); coerce defensivo.
-- Lua arithmetic auto-coerce strings, pero comparisons (>=, <=) tiran error.
local function _safePct(value)
    return tonumber(value) or 0
end

local function normalizeHighlightText(text)
    text = tostring(text or "")
    text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

local function optionalString(value)
    if type(value) == "string" then return value end
    return nil
end

local function stringOrEmpty(value)
    return optionalString(value) or ""
end

-- ============================================================
-- Una instancia viva, una sola cola
--
-- KOReader crea una instancia del plugin por cada pantalla: una para el
-- explorador y otra por cada libro que se abre. Las anteriores no se destruyen
-- solas: sus temporizadores siguen corriendo. Cada una tenia ademas su propia
-- copia de la cola leida del disco, asi que una instancia ya reemplazada
-- seguia sincronizando con numeros de secuencia y marcas viejas. En el log de
-- un lector real: 42 instancias para 22 aperturas de libro, hasta cinco leyendo
-- estadisticas a la vez, filas encoladas dos veces y conflictos 409 de
-- secuencia repetida.
--
-- Este archivo se carga una vez por proceso de KOReader, asi que lo que vive
-- aca lo comparten todas las instancias: la cola (una sola en memoria) y cual
-- es la instancia vigente, que es la que hereda lo que quedo agendado al
-- cerrar un libro.
-- ============================================================
local Shared = { queue = nil, queue_dir = nil, live = nil,
    -- Wi-Fi solo para sincronizar: de quien es el Wi-Fi prendido, si el plugin
    -- lo apago en esta sesion de lectura, y las dos conexiones propias que los
    -- manejadores de red no tienen que tomar por una reconexion de la persona.
    wifi_owned = false, wifi_auto_closed = false, wifi_edge = false, wifi_closing = false,
    -- La conexion silenciosa en curso y si la ultima no llego a conectar.
    wifi_quiet = nil, wifi_quiet_failed = false,
    -- Cuando salio el ultimo intercambio de dormir: el explorador y el libro
    -- reciben el mismo Suspend y el mismo NetworkDisconnecting, y tiene que
    -- salir uno solo (ver `_drainQueueBlocking`). Y si ya salio en esta
    -- suspension: se borra al despertar.
    sleep_exchange_at = nil, sleep_exchange_this_suspension = false }

--- Correr algo que prende el Wi-Fi sin los carteles de KOReader.
--
-- `NetworkMgr:enableWifi` dibuja siempre «Scanning for networks…» y despues
-- «Connected to network X» (tres segundos sobre la pagina) o el error, aunque
-- quien lo llame no sea la persona. Los muestra en el acto, dentro de la misma
-- llamada, asi que alcanza con no dejarlos pasar mientras dura. Solo se frenan
-- los avisos sueltos (InfoMessage): cualquier otra cosa se muestra igual.
local function withoutNetworkNotices(fn)
    local show = UIManager.show
    UIManager.show = function(ui, widget, ...)
        if type(widget) == "table" and getmetatable(widget) == InfoMessage then return end
        return show(ui, widget, ...)
    end
    local results = { pcall(fn) }
    UIManager.show = show
    if not results[1] then error(results[2], 0) end
    return (table.unpack or unpack)(results, 2)
end
HighlightsDeToto._shared = Shared

-- ============================================================
-- Plugin Directory & Config Paths
-- ============================================================

function HighlightsDeToto:getPluginDir()
    return self.path or (DataStorage:getDataDir() .. "/plugins/borges.koplugin")
end

function HighlightsDeToto:getConfigFilePath()
    return self:getPluginDir() .. "/dropbox_config.json"
end

function HighlightsDeToto:getWebConfigFilePath()
    return self:getPluginDir() .. "/web_config.json"
end

-- ============================================================
-- Initialization
-- ============================================================

function HighlightsDeToto:init()
    self.ui.menu:registerToMainMenu(self)
    self:loadSettings()
    if self:isWebConfigured() then
        ReadingWifi.migrateDirectConnection(G_reader_settings, Device)
    end
    -- Persist the idempotent schema migration/install ID before pairing can
    -- start: solo cuando cargar los ajustes les cambio algo. Este arranque
    -- corre cada vez que se abre o se cierra un libro, y guardar siempre
    -- reescribia todos los ajustes de KOReader para no cambiar nada.
    self:saveSyncState(false, true)

    -- Progress sync state
    self.push_timestamp = 0
    self.book_hash = nil
    self.book_title = nil
    self.book_author = nil
    self.total_pages = nil
    self.has_pages = nil  -- true for PDF/DJVU, false for EPUB (set in onReaderReady)
    self.device_id = self.device_id or Device.model or "kobo"
    -- Tracks the last time the user actually changed pages locally (epoch seconds).
    -- Used as defense-in-depth in pullProgress: if local activity is newer than
    -- server's latest, we won't auto-jump (server is stale, e.g. offline reading).
    self.last_progress_change = 0

    -- Session tracking
    self.session = Session:new()
    self._offered_sync_events = {}

    -- C07 · Una sola sincronización, y un punto de retorno antes de cada salto.
    self.sync_run = SyncRun:new()
    self.position_undo = ReadingPosition:new({
        entries = self.position_undo_entries or {},
        on_change = function(entries)
            self.position_undo_entries = entries
            self:saveSyncState()
        end,
    })

    -- Offline queue: una sola por proceso (ver `Shared`).
    Shared.live = self
    local settings_dir = DataStorage:getSettingsDir()
    local restored = Shared.queue == nil or Shared.queue_dir ~= settings_dir
    if restored then
        Shared.queue, Shared.queue_dir = Queue:new(settings_dir), settings_dir
    end
    self.queue = Shared.queue
    -- Antes de que la cola deje asentado algo recibido, el libro tiene que
    -- tener guardadas las anotaciones que el plugin le agrego.
    self.queue.before_flush = function() self:_flushSidecarIfDirty() end
    -- Lo que se leyo del disco al arrancar tiene que volver a consultar la
    -- ultima lectura. Lo que esta misma sesion ya consulto no: es lo que deja
    -- subir la posicion final al cerrar el libro.
    if restored then self.queue:holdPendingProgress() end
    self.diagnostics = Diagnostics:new(DataStorage:getSettingsDir())
    -- Una cola anterior a C06 no tiene dueño anotado, pero sí lo tiene de
    -- hecho: la cuenta con la que este lector ya está vinculado. Anotarlo acá
    -- es lo que hace que el próximo login con otra cuenta se detecte como
    -- cambio en vez de heredar en silencio el trabajo del dueño anterior.
    if self.paired_device_id then
        self.queue:adoptAccount(self.paired_device_id)
    end
    -- C17 · Lo ya respondido sobre la posición de otro aparato. Se guarda en
    -- la cola porque pertenece a la misma cuenta y se corta con ella: quien
    -- entre después no hereda las respuestas del dueño anterior.
    self.resume_flow = ResumeFlow:new({
        decisions = self.queue:getResumeDecisions(),
        on_change = function(decisions)
            self.queue:setResumeDecisions(decisions)
        end,
    })
    self._connect_sync_at = 0
    self._connect_sync_running = false
    self:_initializePairingAndSync()

    -- Plugin self-update. Uses KOReader's portable data/plugin paths, so the
    -- same code works on Kobo and Kindle as long as KOReader is installed.
    self.updater = Updater:new(self, self:getApi())

    -- Periodic push task for debounced progress only. Queue drains may send
    -- larger payloads, so they are intentionally kept out of page-turn timers.
    self.periodic_push_task = function()
        self:_runBackgroundSync("progress", function() self:pushProgress(false) end)
    end

    -- Lo que hace falta despues de mover la pantalla (leer el XPointer, contar
    -- la pagina, re-armar el envio) corre aca, fuera del aviso de KOReader.
    self._screen_move_task = function()
        local move = self._screen_move
        self._screen_move = nil
        if not move or self._closed then return end
        self:_safecall("screenMoved", function()
            local page = move.page
            if page == nil and self.ui and self.ui.getCurrentPage then page = self.ui:getCurrentPage() end
            self:_handlePageChange(page)
        end)
        -- F1 · la pantalla nueva queda registrada y se cuenta aca, despues del
        -- pintado, con el XPointer que _handlePageChange acaba de leer.
        self:_safecall("readingScreen", function() self:_recordReadingScreen(move) end)
    end

    self.highlight_push_task = function()
        self:_runBackgroundSync("highlights", function() self:_syncHighlightsIfSidecarChanged() end)
    end

    -- Only schedule highlights auto-sync timer if applicable
    if self.auto_sync and self:isWebConfigured()
        and (os.time() - self.last_web_sync) >= AUTO_SYNC_INTERVAL then
        UIManager:scheduleIn(5, function()
            self:autoSyncCheck()
        end)
    end

    -- Rotar el token antes de que venza. Va después del arranque para no
    -- competir con la primera pantalla, y sólo si ya hay sesión.
    if self:isConnected() then
        UIManager:scheduleIn(20, function()
            if not NetworkMgr:isConnected() then return end
            self:_runBackgroundSync("credentialRenewal", function()
                self:_renewCredentialIfDue()
            end)
        end)
    end

    -- Si la instancia anterior prendio el Wi-Fi para sincronizar, apagarlo le
    -- toca a esta.
    self:_scheduleWifiOff(WIFI_OFF_DELAY)

    -- C23 · El arranque sólo pregunta si la red YA está prendida. Antes esto
    -- corría igual y terminaba en la pantalla de Wi-Fi de KOReader: abrir un
    -- libro no puede costar una pregunta de conexión.
    UIManager:scheduleIn(PLUGIN_UPDATE_CHECK_DELAY, function()
        self:_safecall("pluginUpdateAutoCheck", function()
            self:_maybeCheckPluginUpdate("startup")
        end)
    end)
end

--- Cliente HTTP del plugin, con la lectura del estado de sesión incorporada.
--
-- Es el mismo `WebApi` de siempre; lo único que agrega es mirar el resultado
-- de cada request que viajó con el token del dispositivo. Un 401 ahí es la
-- única fuente autorizada para decir "sesión vencida": el reloj del lector no
-- alcanza, y preguntarle al servidor en cada pantalla sería peor.
function HighlightsDeToto:getApi()
    if self.api then return self.api end
    local plugin = self
    local function note(auth, result, err)
        if type(auth) ~= "table" or not auth.token or auth.token == "" then
            return
        end
        if result then
            plugin:_noteCredentialAccepted()
        elseif err then
            plugin:_noteCredentialError(err)
        end
    end
    self.api = setmetatable({
        requestJSON = function(_, method, url, auth, payload, quick, extra_headers)
            local decoded, err, meta = WebApi:requestJSON(
                method, url, auth, payload, quick, extra_headers
            )
            note(auth, decoded, err)
            return decoded, err, meta
        end,
        downloadFile = function(_, url, auth, dest_path)
            local ok, err = WebApi:downloadFile(url, auth, dest_path)
            note(auth, ok, err)
            return ok, err
        end,
    }, { __index = WebApi })
    return self.api
end

--- El servidor aceptó la credencial guardada: cualquier "vencida" anterior era
-- un falso positivo (un 401 transitorio, un reloj corrido) y se limpia sola.
function HighlightsDeToto:_noteCredentialAccepted()
    if not self.credential_rejected_at then return end
    local settings = self:_currentSettings()
    if SettingsMigration.markCredentialAccepted(settings) then
        self:_applyMigratedSettings(settings)
        self:saveSyncState()
    end
end

--- El servidor rechazó la credencial: la sesión pasa a vencida. No se borra el
-- token ni la cola; sólo deja de intentar hasta que el lector vuelva a entrar.
function HighlightsDeToto:_noteCredentialError(err)
    if not Login.isCredentialRejection(err) then return end
    local settings = self:_currentSettings()
    if SettingsMigration.markCredentialRejected(settings) then
        self:_applyMigratedSettings(settings)
        self:saveSyncState()
        logger.warn("Borges: device credential rejected:", tostring(err and err.code))
    end
end

function HighlightsDeToto:_initializePairingAndSync()
    self:_cancelBackgroundSync()
    self._progress_focus = nil
    if self._reading_activity_device and self._reading_activity_device ~= (self.paired_device_id or self.device_id) then
        self._reading_activity_at, self._last_enqueued_progress = nil, nil
    end
    if self.pairing then self.pairing:stopWatching() end
    self.pairing = Pairing:new{
        web_api = self:getApi(),
        base_url = self:getBaseUrl(),
        save_pending = function(state)
            self.pairing_state = state
            self:saveSyncState()
        end,
        clear_pending = function()
            self.pairing_state = nil
            self:saveSyncState()
        end,
        commit_credential = function(result)
            self:_commitDeviceLogin(result)
        end,
    }

    self.login = Login:new{
        web_api = self:getApi(),
        base_url = function() return self:getBaseUrl() end,
    }

    self.sync_v2 = SyncV2:new{
        web_api = self:getApi(),
        queue = self.queue,
        base_url = function() return self:getBaseUrl() end,
        auth = function() return self:getWebAuth() end,
        client = function()
            return {
                client_version = self:getPluginVersion(),
                firmware_version = tostring(Device.model or "unknown"),
                protocol_version = 2,
                capabilities = {
                    platform = "koreader",
                    durable_outbox = true,
                    progress = true,
                    sessions = true,
                    page_stats = true,
                    annotations = true,
                },
                queue_depth = self.queue:count(),
            }
        end,
        apply_event = function(event)
            return self:_applySyncV2Event(event)
        end,
        reading_context = function()
            return { book_hash = self.book_hash, token = self.device_token, epoch = self._background_epoch,
                book_key = self.book_key,
                hint = self.book_hash and { title = self.book_title, file = self.book_filename } or nil }
        end,
        on_reading_head = function(response, context)
            -- F1 · la consulta enfocada trae el ritmo de este libro (reading_pace).
            if self._applyReadingPace and (not context or context.book_hash == self.book_hash) then
                local ok_pace, pace_err = pcall(self._applyReadingPace, self, response)
                if not ok_pace then logger.warn("Borges: readingPace error:", pace_err) end
            end
            return self:_handleReadingHead(response, context)
        end,
    }

    if self:getBaseUrl() ~= "" and not self.device_token
        and (self.web_api_key ~= "" or self.pairing_state) then
        UIManager:scheduleIn(8, function()
            if self._closed or not NetworkMgr:isConnected() then return end
            self:_safecall("pairingMigration", function()
                if self.pairing_state then
                    self:resumeDevicePairing(false)
                else
                    self:startDevicePairing(false)
                end
            end)
        end)
    end
end

function HighlightsDeToto:_applySyncV2Event(event)
    if event.event_type == "progress.changed" then
        -- Replay is transport history, not a decision about where to read.
        -- Only the current, checked reading head can open a confirmation.
        local head = self._reading_head
        if not event.focus_preview or not head or not head.ask
            or head.book_hash ~= self.book_hash or head.token ~= self.device_token
            or head.event_id ~= event.event_id then return true end
        local metadata = event.directive_metadata or {}
        self:_scheduleProgressSuggestion(event, metadata.source or event.payload)
        return "defer"
    end
    if event.origin_device and event.origin_device.id == self.paired_device_id then
        if event.event_type ~= "progress.changed" then Background.yieldToUI() end
        self:_recordOwnAnnotationRevision(event)
        return true
    end
    if event.event_type == "session.ended"
        or event.event_type == "page_stat.recorded"
        or event.event_type == "session.started" then
        -- Telemetry is already materialized on the server; other readers do not
        -- need to replay it into KOReader's local statistics database.
        return true
    end
    -- Lo que el servidor guardo como conflicto es la rama que NO quedo
    -- vigente: esta ahi para que una persona decida, no para aplicarse. Antes
    -- se escribia igual sobre el libro y el lector quedaba con el contenido
    -- perdedor bajo la revision del ganador. No espera a ningun libro.
    if event.directive == "annotation_conflict"
        or (type(event.directive_metadata) == "table"
            and event.directive_metadata.annotation_conflict == true) then
        return true
    end
    local identifier = event.book_identifier
    if not identifier or identifier.kind ~= "koreader_partial_md5"
        or identifier.value ~= self.book_hash then
        return "defer"
    end

    Background.yieldToUI()

    if event.event_type == "annotation.created"
        or event.event_type == "annotation.updated"
        or event.event_type == "annotation.deleted"
        or event.event_type == "bookmark.upserted"
        or event.event_type == "bookmark.deleted" then
        return self:_applyAnnotationV2Event(event)
    end
    return "defer"
end

function HighlightsDeToto:_recordOwnAnnotationRevision(event)
    if not event or (event.event_type ~= "annotation.created"
        and event.event_type ~= "annotation.updated"
        and event.event_type ~= "annotation.deleted"
        and event.event_type ~= "bookmark.upserted"
        and event.event_type ~= "bookmark.deleted") then
        return
    end
    local metadata = event.directive_metadata or {}
    if metadata.annotation_conflict == true
        or not tostring(metadata.annotation_revision or ""):match("^%d+$") then
        return
    end
    local identifier = event.book_identifier or {}
    local payload = event.payload or {}
    local sync_id = payload.sync_id or event.aggregate_id
    if identifier.kind ~= "koreader_partial_md5"
        or type(identifier.value) ~= "string"
        or type(sync_id) ~= "string" then
        return
    end
    local revision = tostring(metadata.annotation_revision)
    -- Lo sincronizado vive bajo la clave del libro del evento; un evento en
    -- vuelo de una version anterior todavia esta anotado por hash.
    local book = type(payload.book) == "table" and payload.book or {}
    local state_key = BookKey.fromParts(identifier.value, book.file, book.title)
    local state = state_key and self.queue:getAnnotationState(state_key) or {}
    if state[sync_id] == nil then
        local by_hash = self.queue:getAnnotationState(identifier.value)
        if by_hash[sync_id] ~= nil then state_key, state = identifier.value, by_hash end
    end
    local item_state = state[sync_id]
    -- Aceptado: el rastro de un rechazo anterior ya no aplica.
    local had_rejection = type(item_state) == "table"
        and (item_state.reemit ~= nil or item_state.rejected ~= nil)
    if had_rejection then
        item_state.reemit, item_state.rejected = nil, nil
        item_state.rejected_event, item_state.rejected_action = nil, nil
    end
    if type(item_state) == "table" and (item_state.revision ~= revision or had_rejection) then
        item_state.revision = revision
        -- Diferido: el intercambio que trajo este acuse guarda una sola vez al
        -- terminar. Antes eran un guardado de la cola y uno del sidecar por
        -- cada subrayado confirmado.
        self.queue:setAnnotationState(state_key, state, true)
    end
    if identifier.value ~= self.book_hash then return end
    local annotation_module = self.ui and self.ui.annotation
    if not annotation_module or type(annotation_module.annotations) ~= "table" then
        return
    end
    for _, item in ipairs(annotation_module.annotations) do
        if item.toto_sync_id == sync_id then
            if item.toto_revision ~= revision then
                item.toto_revision = revision
                self:_markSidecarDirty()
            end
            break
        end
    end
end

--- El plugin cambio anotaciones del libro abierto: aplico una de otro lector
-- o anoto la revision que confirmo el servidor. El sidecar no se reescribe por
-- cada una (pesa mas de 100 KB en un libro muy subrayado): queda marcado y
-- sale una sola vez, siempre ANTES de que la cola guarde lo que eso implica.
function HighlightsDeToto:_markSidecarDirty()
    self._sidecar_dirty = true
end

--- KOReader mantiene la lista de anotaciones ordenada y con su numero de
-- pagina. Despues de aplicar anotaciones de otro lector hay que rehacer las dos
-- cosas, una vez, antes de que nadie guarde o dibuje la lista.
--
-- Y hay que avisarle a la pantalla. KOReader dibuja los subrayados de una
-- pagina ya visitada desde una cache por pagina (`view.highlight.page_boxes`)
-- y no vuelve a mirar la lista: un subrayado hecho en la web llegaba al libro
-- abierto, quedaba guardado en el sidecar y no aparecia nunca en la pagina que
-- la persona tenia delante (hasta reabrir el libro). KOReader lo resuelve con
-- el evento AnnotationsModified; aca no se usa porque tambien le pone fecha de
-- edicion a la anotacion y dispara nuestra propia comparacion. La cache se tira
-- entera: insertar o borrar corre el indice de todas las cajas guardadas.
function HighlightsDeToto:_settleAnnotations()
    if not self._annotations_unsettled then return end
    self._annotations_unsettled = false
    local annotation_module = self.ui and self.ui.annotation
    if annotation_module and annotation_module.updateAnnotations then
        annotation_module:updateAnnotations(true, true)
    end
    local view = self.ui and self.ui.view
    if not view then return end
    if type(view.resetHighlightBoxesCache) == "function" then
        local ok, err = pcall(view.resetHighlightBoxesCache, view)
        if not ok then
            logger.warn("Borges: could not refresh the highlights on screen:", tostring(err))
        end
    end
    -- Con la pantalla de reposo puesta no se dibuja nada encima: al despertar
    -- KOReader repinta la pagina solo, ya sin la cache vieja.
    if not self._background_suspended and Device.screen_saver_mode ~= true then
        UIManager:setDirty(self.ui, "ui")
    end
end

function HighlightsDeToto:_flushSidecarIfDirty()
    self:_settleAnnotations()
    if not self._sidecar_dirty then return false end
    self._sidecar_dirty = false
    local annotation_module = self.ui and self.ui.annotation
    if not self.ui or not self.ui.doc_settings or not annotation_module
        or type(annotation_module.annotations) ~= "table" then
        return false
    end
    self.ui.doc_settings:saveSetting("annotations", annotation_module.annotations)
    self.ui.doc_settings:flush()
    self._sidecar_written = true
    return true
end

--- Dejar las anotaciones del libro abierto listas para compararse: ordenadas
-- y con su id estable. NO escribe el sidecar.
--
-- KOReader ya guarda el sidecar por su cuenta justo antes de avisar que cierra
-- el libro y justo antes de avisar que suspende; el plugin lo volvia a
-- escribir entero (147 KB en el libro abierto de un lector real, 895 KB en el
-- mas subrayado) dos o tres veces por suspension, hubiera o no algo nuevo. La
-- escritura queda en _enqueueAnnotationDiff, y solo cuando hay algo que tiene
-- que estar en el disco antes de que su evento entre a la cola.
function HighlightsDeToto:_flushSidecar()
    if not self.ui or not self.ui.doc_settings then return end
    -- Empieza una pasada de guardado: todavia nadie escribio el sidecar en ella.
    self._sidecar_written = false
    self:_settleAnnotations()
    local annotation_module = self.ui.annotation
    if self.book_hash and annotation_module and type(annotation_module.annotations) == "table" then
        -- Si un item raro no se deja normalizar, la comparacion de despues lo
        -- vuelve a intentar; aca lo unico que no puede fallar es el guardado.
        local assigned = 0
        pcall(function()
            local book = self:_annotationBookDescriptor()
            for _, item in ipairs(annotation_module.annotations) do
                if type(item) == "table" and type(item.toto_sync_id) ~= "string" then
                    AnnotationAdapter:normalize(self.book_hash, item, book)
                    assigned = assigned + 1
                end
            end
        end)
        if assigned > 0 then self:_markSidecarDirty() end
    end
end

--- Los horarios de la ultima sincronizacion se guardan una vez por operacion,
-- no una vez por cada anotacion aplicada.
function HighlightsDeToto:_saveSyncStateIfDirty()
    if not self._sync_state_dirty then return end
    self:saveSyncState()
end

--- C17 · Una sugerencia que llegó por sync se ofrece por el mismo camino que
-- todo lo demás. Acá sólo se desarma el evento; quién pregunta, cuándo y con
-- qué texto lo decide `_offerRemotePosition`.
function HighlightsDeToto:_scheduleProgressSuggestion(event, source)
    if not event.event_id or self._offered_sync_events[event.event_id] then return end
    self._offered_sync_events[event.event_id] = true
    local token, book, epoch = self.device_token, self.book_hash, self._background_epoch
    local reading_baseline = event.focus_preview and self._resume_reading_baseline or nil
    local reading_head = self._reading_head
    UIManager:nextTick(function()
        if self.device_token ~= token or self.book_hash ~= book
            or self._background_epoch ~= epoch or self._reading_head ~= reading_head then
            self._offered_sync_events[event.event_id] = nil
            return
        end
        local identifier = event.book_identifier or {}
        local metadata = event.directive_metadata or {}
        local suggestion = metadata.suggestion

        local remote = {}
        for key, value in pairs(source or {}) do remote[key] = value end
        -- La identidad de la posición sale del evento, no del reloj: es lo que
        -- permite no repreguntar lo ya respondido y sí ofrecer lo nuevo.
        remote.event_id = remote.event_id or event.event_id
        remote.server_sequence = remote.server_sequence or event.server_sequence
        remote.occurred_at = remote.occurred_at or event.occurred_at
        remote.time_precision = remote.time_precision or event.time_precision

        local offered, reason = self:_offerRemotePosition({
            book_hash = identifier.value,
            remote = remote,
            source = event.origin_device,
            suggestion_id = suggestion and suggestion.id or nil,
            event_id = event.event_id,
            reading_baseline = reading_baseline,
            reading_head = reading_head,
        })
        if not offered then
            -- El evento sigue en el inbox: si se descartó por "hay otro
            -- diálogo abierto" o "es otro libro", vuelve a intentarse solo.
            self._offered_sync_events[event.event_id] = nil
            if reason == ResumeFlow.ALREADY_RESOLVED or reason == ResumeFlow.SAME_POSITION
                or reason == ResumeFlow.OLDER_READING then
                -- Esto ya tiene respuesta: sacarlo del inbox evita reprocesarlo
                -- en cada apertura por el resto de la vida del libro.
                self:_resolveSuggestion(
                    { event_id = event.event_id, suggestion_id = suggestion and suggestion.id or nil },
                    "dismiss"
                )
            end
        end
    end)
end

function HighlightsDeToto:_applyInboxForCurrentBook()
    if not self.book_hash then return end
    -- Sin nada esperando a este libro no se lee el inbox del disco: abrir un
    -- libro no tiene que parsear lo pendiente de todos los demas.
    if self.queue:inboxCountForBook({ kind = "koreader_partial_md5", value = self.book_hash }) == 0 then
        return
    end
    local pending = {}
    for _, event in ipairs(self.queue:getInbox()) do
        table.insert(pending, event)
    end
    for _, event in ipairs(pending) do
        local identifier = event.book_identifier
        if identifier and identifier.kind == "koreader_partial_md5"
            and identifier.value == self.book_hash then
            local action = self:_applySyncV2Event(event)
            if action == true then self.queue:removeInboxEvent(event.event_id, true) end
        end
    end
    -- Un solo guardado para todo lo aplicado, en orden: el sidecar (lo pide la
    -- cola antes de escribir), lo sincronizado del libro, el inbox sin esos
    -- eventos y recien entonces el estado. Antes eran cuatro escrituras por
    -- cada anotacion recibida.
    self.queue:flush("consume")
    self:_settleAnnotations()
    self:_saveSyncStateIfDirty()
end

-- ============================================================
-- C06 · Conectar la cuenta desde el lector
--
-- El plugin se instala genérico y ya sabe a qué servidor hablar. Lo único que
-- pide es lo mismo que la web: usuario y contraseña, una vez. A cambio guarda
-- un token de ESTE lector y descarta la contraseña; de ahí en más el lector se
-- reinicia, se queda sin batería o vuelve de un viaje y sigue sincronizando
-- sin que nadie vuelva a escribir nada.
-- ============================================================

--- Sólo los campos que describen la credencial. `_currentSettings()` arma una
-- tabla grande y toca Dropbox; esto lo llama el menú en cada dibujado.
function HighlightsDeToto:_credentialSnapshot()
    return {
        device_token = self.device_token,
        paired_device_id = self.paired_device_id,
        account_username = self.account_username,
        credential_expires_at = self.credential_expires_at,
        credential_renew_after = self.credential_renew_after,
        credential_rejected_at = self.credential_rejected_at,
    }
end

function HighlightsDeToto:getConnectionState()
    return SettingsMigration.connectionState(self:_credentialSnapshot())
end

function HighlightsDeToto:isConnected()
    return self:getConnectionState() == SettingsMigration.CONNECTION_CONNECTED
end

function HighlightsDeToto:getConnectionLabel()
    local state = self:getConnectionState()
    if state == SettingsMigration.CONNECTION_CONNECTED then
        if self.account_username and self.account_username ~= "" then
            return T(_("Connected as %1 ✓"), self.account_username)
        end
        return _("Connected ✓")
    elseif state == SettingsMigration.CONNECTION_EXPIRED then
        return _("Session expired — sign in again")
    end
    return _("Sign in")
end

function HighlightsDeToto:promptDeviceLogin()
    self:_keepWifi()
    self:_cancelBackgroundSync()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Sign in to Borges"),
        description = T(_("Server: %1"), self:getBaseUrl()),
        fields = {
            {
                description = _("Username or email"),
                input_type = "string",
                text = self.account_username or "",
            },
            {
                description = _("Password"),
                input_type = "string",
                text_type = "password",
                text = "",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Sign in"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local username = fields and fields[1] or ""
                        local password = fields and fields[2] or ""
                        UIManager:close(dialog)
                        -- La contraseña existe sólo mientras dura esta llamada:
                        -- no se guarda en settings, ni en web_config.json, ni
                        -- se deja escrita en el diálogo para el próximo login.
                        self:_beginDeviceLogin(username, password)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Antes de mandar la contraseña: si el usuario tipeado no es el de la sesión
-- guardada y hay trabajo sin subir, preguntar qué hacer con ese trabajo.
function HighlightsDeToto:_beginDeviceLogin(username, password)
    local switching = SettingsMigration.willSwitchAccount(
        self:_credentialSnapshot(),
        username
    )
    if not switching or not self.queue:hasPendingWork() then
        return self:_runDeviceLogin(username, password)
    end

    UIManager:show(MultiConfirmBox:new{
        text = T(
            _("You are signing in as %1, but %2 still has %3 change(s) waiting to upload.\n\nThose changes belong to %2 and cannot be sent to another account."),
            username,
            self.account_username or _("the current account"),
            self.queue:count()
        ),
        choice1_text = _("Save a copy"),
        choice1_callback = function()
            local path, err = self:_exportPendingQueue()
            if path then
                self:showInfo(T(_("Pending work saved to:\n%1"), path), 7)
                self:_runDeviceLogin(username, password)
            else
                self:showInfo(
                    T(_("Could not save pending work: %1"), tostring(err)),
                    10
                )
            end
        end,
        choice2_text = _("Discard"),
        choice2_callback = function()
            self:_runDeviceLogin(username, password)
        end,
    })
end

function HighlightsDeToto:_runDeviceLogin(username, password)
    self:_cancelBackgroundSync()
    self:ensureNetwork(function()
        UIManager:nextTick(function()
            local progress = self:showInfoPersist(_("Signing in..."))
            local result, err, switched
            -- El diálogo de progreso se cierra pase lo que pase: si el login
            -- explota, dejarlo abierto le tapa la pantalla al lector.
            local ok = self:_safecall("deviceLogin", function()
                result, err = self.login:signIn{
                    username = username,
                    password = password,
                    external_id = self.install_id,
                    device_name = self.device_label or Device.model or "KOReader",
                    client_version = self:getPluginVersion(),
                    firmware_version = tostring(Device.model or "unknown"),
                }
                if result then switched = self:_commitDeviceLogin(result) end
            end)
            UIManager:close(progress)

            if not ok then
                self:showInfo(_("Sign-in failed unexpectedly. See the KOReader log."), 10)
                return
            end
            if not result then
                self:showInfo(
                    T(_("Sign-in failed: %1"), Login.describeError(err)),
                    10
                )
                return
            end
            if switched then
                self:showInfo(
                    T(
                        _("Signed in as %1.\nThis reader starts fresh: the previous account's queue was not carried over."),
                        self.account_username or username
                    ),
                    8
                )
            else
                self:showInfo(
                    T(_("Signed in as %1."), self.account_username or username),
                    5
                )
            end
        end)
    end)
end

--- Guardar la credencial verificada. Devuelve true si esto fue un cambio de
-- cuenta, en cuyo caso la cola y los mapas de la cuenta anterior ya quedaron
-- cortados.
function HighlightsDeToto:_commitDeviceLogin(result)
    self.pairing:stopWatching()
    local settings = self:_currentSettings()
    local switched = SettingsMigration.isAccountSwitch(settings, result)
    local committed, commit_err = SettingsMigration.completeLogin(settings, result)
    if not committed then error(tostring(commit_err)) end
    if switched then
        SettingsMigration.clearAccountScopedState(settings)
    end
    SettingsMigration.retireLegacyCredential(settings)
    self:_applyMigratedSettings(settings)
    self:saveSettings()
    -- La cola es lo último: recién acá el id del nuevo dueño está persistido,
    -- así que un corte de luz en el medio deja la cola vieja con su dueño viejo
    -- en vez de dejarla huérfana y adoptable por cualquiera.
    self.queue:resetForAccount(result.device and result.device.id)
    self:_rebindResumeDecisions()
    return switched
end

function HighlightsDeToto:confirmSignOut()
    local pending = self.queue:count()
    if pending == 0 then
        UIManager:show(ConfirmBox:new{
            text = T(
                _("Sign %1 out of this reader?\n\nDownloaded books stay on the device."),
                self.account_username or _("this account")
            ),
            ok_text = _("Sign out"),
            ok_callback = function() self:signOutDevice() end,
        })
        return
    end
    UIManager:show(MultiConfirmBox:new{
        text = T(
            _("%1 change(s) have not been uploaded yet. Signing out discards them.\n\nDownloaded books stay on the device."),
            pending
        ),
        choice1_text = _("Save a copy"),
        choice1_callback = function()
            local path, err = self:_exportPendingQueue()
            if path then
                self:showInfo(T(_("Pending work saved to:\n%1"), path), 7)
                self:signOutDevice()
            else
                self:showInfo(
                    T(_("Could not save pending work: %1"), tostring(err)),
                    10
                )
            end
        end,
        choice2_text = _("Discard"),
        choice2_callback = function() self:signOutDevice() end,
    })
end

--- Salir de la cuenta en ESTE lector. Es local a propósito: no hay que estar
-- online para dejar de estar conectado. Revocar la credencial del lado del
-- servidor es una acción del dueño desde la web.
function HighlightsDeToto:signOutDevice()
    self:_cancelBackgroundSync()
    self.pairing:stopWatching()
    local settings = self:_currentSettings()
    local signed_out = SettingsMigration.signOut(settings)
    if not signed_out then return end
    self:_applyMigratedSettings(settings)
    self:saveSettings()
    self.queue:releaseAccount()
    self:_rebindResumeDecisions()
    self:showInfo(_("Signed out. This reader no longer syncs."), 5)
end

--- C17 · Después de un corte de cuenta la cola tiene una tabla nueva de
-- decisiones. Sin volver a engancharla, el objeto en memoria seguiría
-- escribiendo sobre la tabla del dueño anterior y el lector que entra se
-- comería las respuestas de otro.
function HighlightsDeToto:_rebindResumeDecisions()
    if not self.resume_flow then return end
    self.resume_flow.decisions = self.queue:getResumeDecisions()
    self.resume_flow:clearVisible()
end

--- Copia de lo pendiente antes de descartarlo. No es una migración entre
-- cuentas: es evidencia recuperable de lo que había, en JSON.
function HighlightsDeToto:_exportPendingQueue()
    local path = string.format(
        "%s/highlightsdetoto_pending_%s.json",
        DataStorage:getSettingsDir(),
        os.date("!%Y%m%dT%H%M%SZ")
    )
    local ok, encoded = pcall(
        rapidjson.encode,
        self.queue:exportPending(),
        { pretty = true }
    )
    if not ok or type(encoded) ~= "string" then
        return nil, _("could not encode pending work")
    end
    local file, file_err = io.open(path, "w")
    if not file then return nil, file_err or _("could not open destination") end
    file:write(encoded)
    file:close()
    return path
end

--- Rotar el token antes de que venza, sin pedir nada al lector.
-- Es lo que sostiene "login una vez": la credencial vive meses, pero se
-- renueva sola mientras el lector siga entrando al servidor.
function HighlightsDeToto:_renewCredentialIfDue()
    if not self:isConnected() then return end
    if not SettingsMigration.needsRenewal(self:_credentialSnapshot()) then return end
    local rotated, err = self.login:rotate(self:getWebAuth())
    if not rotated then
        logger.warn("Borges: credential rotation deferred:", tostring(err and err.code))
        return
    end
    local settings = self:_currentSettings()
    if SettingsMigration.completeRotation(settings, rotated) then
        self:_applyMigratedSettings(settings)
        self:saveSyncState()
    end
end

function HighlightsDeToto:watchDevicePairing(state, interactive)
    if self.pairing_dialog then UIManager:close(self.pairing_dialog) end
    self.pairing_dialog = nil
    if interactive then
        self.pairing_dialog = InfoMessage:new{
            text = T(_("Code: %1\n\nFrom your phone or computer, open:\n%2\n\nSign in to your Borges account and enter this code. The reader links to the account that approves it.\n\nIt expires in 5 minutes. Keep Wi-Fi on: pairing and sync finish on their own."), state.user_code, state.verification_url or (self:getBaseUrl() .. "/devices/pair")),
        }
        UIManager:show(self.pairing_dialog)
    end
    self.pairing:watch(state, UIManager, function(result, err)
        if self.pairing_dialog then UIManager:close(self.pairing_dialog) end
        self.pairing_dialog = nil
        if result then
            self:showInfo(T(_("Reader connected to Borges as %1. The connection was saved."), self.account_username or _("your account")), 5)
            self:runUnifiedSync()
        elseif err and err.code == "pairing_expired" then
            self:showInfo(_("The code expired. Choose Pair with a code to get a new one."), 8)
        else
            self:showInfo(_("Could not pair the reader. Generate a new code to try again."), 8)
        end
    end, function() return NetworkMgr:isConnected() end)
end

function HighlightsDeToto:startDevicePairing(interactive)
    self:_cancelBackgroundSync()
    if self:getBaseUrl() == "" then
        if interactive then self:showInfo(_("Configure the server URL first."), 5) end
        return
    end
    self:ensureNetwork(function()
        UIManager:nextTick(function()
            local result, err = self.pairing:start{
                device_name = self.device_label or Device.model or "KOReader",
                install_id = self.install_id,
                client_version = self:getPluginVersion(),
                firmware_version = tostring(Device.model or "unknown"),
                legacy_api_key = not interactive and self.web_api_key or nil,
            }
            if result and result.credential then
                if interactive then self:showInfo(_("Device paired successfully."), 5) end
                return
            end
            if result and result.user_code then
                self:watchDevicePairing(result, interactive)
                return
            end
            if interactive then
                self:showInfo(
                    string.format(_("Could not generate the code: %s"), tostring(err or _("unknown error"))),
                    10
                )
            end
        end)
    end)
end

function HighlightsDeToto:resumeDevicePairing(interactive)
    self.pairing:stopWatching()
    if not self.pairing_state then
        if interactive then self:showInfo(_("No pairing request is pending."), 4) end
        return
    end
    self:ensureNetwork(function()
        UIManager:nextTick(function()
            local result, err = self.pairing:resume(self.pairing_state)
            if result and result.credential then
                if self.pairing_dialog then UIManager:close(self.pairing_dialog) end
                self.pairing_dialog = nil
                if interactive then self:showInfo(_("Device paired successfully."), 5) end
                self:runUnifiedSync()
            elseif result and result.user_code then
                self:watchDevicePairing(result, interactive)
            elseif interactive then
                self:showInfo(
                    string.format(_("Could not pair the reader: %s"), tostring(err or _("unknown error"))),
                    10
                )
            end
        end)
    end)
end

--- Subir los subrayados nuevos un rato despues de hacerlos, si hay red.
--
-- Antes esto se decidia mirando la fecha del sidecar en CADA vuelta de pagina
-- (una consulta al sistema de archivos por pagina), y como KOReader reescribe
-- el sidecar en cada autoguardado y cada despertar, el temporizador se armaba
-- sin que hubiera ningun subrayado nuevo. Ahora lo arma el aviso de KOReader
-- de que una anotacion cambio. Sin red no se arma: la comparacion corre igual
-- al suspender, al cerrar el libro y al apagar el Wi-Fi.
function HighlightsDeToto:_scheduleHighlightPush()
    if not self.auto_sync or not self._annotations_modified then return end
    if not self.book_hash or not self.book_file_path then return end
    if not self:isWebConfigured() or not NetworkMgr:isConnected() then return end

    UIManager:unschedule(self.highlight_push_task)
    UIManager:scheduleIn(HIGHLIGHT_DEBOUNCE, self.highlight_push_task)
end

function HighlightsDeToto:_syncHighlightsIfSidecarChanged()
    if not self.book_hash or not self.book_file_path then return end
    if not self:isWebConfigured() or not self._annotations_modified then return end
    self._annotations_modified = false
    self:_flushSidecar()
    self:syncHighlightsDelta(not NetworkMgr:isConnected(), true)
end

-- ============================================================
-- Document Lifecycle Hooks
-- ============================================================

--- Protected call with logging. Returns true if fn succeeded.
function HighlightsDeToto:_safecall(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        logger.warn("Borges:", label, "error:", err)
    end
    return ok
end

--- C31 · Una pregunta del menú falló mientras KOReader lo dibujaba.
--
-- MenuTree ya devolvió el respaldo (etiqueta fija, ítem apagado), así que el
-- menú sigue abierto. Acá queda el rastro en el log y, una sola vez por punto
-- y por sesión, un aviso que la persona puede fotografiar y mandar por
-- «Reportar un problema». Se muestra en el tick siguiente para no meter un
-- widget encima del menú a medio armar. Sin T(): si lo que falló es la
-- plantilla, este aviso tiene que salir igual.
function HighlightsDeToto:reportMenuError(what, err)
    local detail = tostring(err)
    logger.err("Borges: menu", tostring(what), "failed:", detail)
    self._menu_errors_shown = self._menu_errors_shown or {}
    if self._menu_errors_shown[what] then return end
    self._menu_errors_shown[what] = true
    if #detail > 700 then detail = detail:sub(1, 700) .. "…" end
    local text = _("Part of the Borges menu could not be drawn (%1).\nThe rest keeps working. Please report this problem and include this text:\n\n%2")
    text = text:gsub("%%1", function() return tostring(what) end)
    text = text:gsub("%%2", function() return detail end)
    UIManager:nextTick(function()
        UIManager:show(InfoMessage:new{ text = text })
    end)
end

--- One automatic operation at a time; pending triggers are coalesced by kind.
-- All settings, queue commits and widget work stay in this parent process.
function HighlightsDeToto:_runBackgroundSync(label, fn)
    if self._closed then return false, "closed" end
    if self._background_suspended then return false, "suspended" end
    if Background.current() == self._background_sync and self._background_sync then
        return fn()
    end
    self._background_sync = self._background_sync or Background:new()
    local epoch = self._background_epoch or 0
    local token, account, book = self.device_token, self.paired_device_id, self.book_hash
    local function valid()
        return (self._background_epoch or 0) == epoch
            and self.device_token == token and self.paired_device_id == account
            and self.book_hash == book
    end
    if self._background_sync:isRunning() then
        self._background_pending = self._background_pending or {}
        if self._background_label ~= label or label ~= "connected" then
            -- Repeated network events belong to the same waiting connection.
            -- Preserve its original reading baseline until it runs or expires.
            local pending = self._background_pending[label]
            if label == "connected" and pending and pending.valid() then return false, "busy" end
            self._background_pending[label] = { valid = valid, run = function()
                if valid() then self:_runBackgroundSync(label, fn) end
            end }
        end
        return false, "busy"
    end
    self._background_label = label
    return self._background_sync:run(fn, function(ok, err)
        self._background_label = nil
        if label == "manual" then
            self:_closeSyncProgress()
            if self.sync_run then self.sync_run.running = false end
            if not ok and err and err.code ~= "background_cancelled" then
                self:showInfo(_("Could not finish syncing. Pending changes are still saved; you can retry."), 8)
            end
        end
        -- A cancelled coroutine never reaches its own final statements.
        if label == "connected" then
            self._connect_sync_running = false
        end
        if label == "update" then self._plugin_update_check_running = false end
        if not ok and err and err.code ~= "background_cancelled" then
            logger.warn("Borges: automatic operation stopped:", label, err.code)
        end
        local pending = self._background_pending or {}
        local next_label = pending.connected and "connected" or next(pending)
        local item = next_label and pending[next_label]
        while item do
            pending[next_label] = nil
            if item.valid() then UIManager:nextTick(item.run); break end
            if next_label == "update" then self._plugin_update_check_running = false end
            next_label, item = next(pending)
        end
    end, valid)
end

function HighlightsDeToto:_cancelBackgroundSync()
    self._background_epoch = (self._background_epoch or 0) + 1
    self:_clearReadingHead()
    if self._reading_wifi then self._reading_wifi:close(); self._reading_wifi = nil end
    self._background_pending = {}
    if self._background_sync then self._background_sync:cancel() end
    -- F6: una busqueda de texto en curso tampoco sobrevive (libro, cuenta, sueño).
    if self._locate_job then self._locate_job:cancel() end
    self:_closeSyncProgress()
    self._connect_sync_running = false
    self._plugin_update_check_running = false
end

function HighlightsDeToto:onExit()
    self._background_suspended = true
    self:_cancelBackgroundSync()
end

--- KOReader cerro la pantalla a la que pertenece esta instancia (el libro o el
-- explorador). Desde aca no hace nada mas: lo que tenia agendado no corre y lo
-- que quedo pendiente lo toma la instancia nueva, con la misma cola.
function HighlightsDeToto:onCloseWidget()
    self._closed = true
    -- F2 · una instancia cerrada no anota tramos ni causas.
    if self._nav then self._nav:close() end
    self._nav, self._attention = nil, nil
    if Shared.live == self then Shared.live = nil end
    self:_cancelBackgroundSync()
    if self.pairing then self.pairing:stopWatching() end
    if self.periodic_push_task then UIManager:unschedule(self.periodic_push_task) end
    if self.highlight_push_task then UIManager:unschedule(self.highlight_push_task) end
    if self._diagnostic_retry then
        UIManager:unschedule(self._diagnostic_retry)
        self._diagnostic_retry = nil
    end
end

--- Get current xpointer for reflowable docs (EPUB). Returns nil for paged docs (PDF).
function HighlightsDeToto:_getXPointer()
    if self.has_pages then return nil end
    local ok, xp = pcall(function() return self.ui.document:getXPointer() end)
    if ok and xp and xp ~= "" then return xp end
    return nil
end

--- Build canonical v2 telemetry envelopes for the current KOReader book.
function HighlightsDeToto:_bookIdentifier(book_hash)
    if not book_hash or book_hash == "" then return nil end
    return {
        kind = "koreader_partial_md5",
        value = tostring(book_hash):lower(),
    }
end

--- Mudar a la clave del libro abierto lo que el plugin guardo por hash (o
-- bajo la clave de antes de un renombre). Solo lo que el sidecar de ESTE
-- libro prueba que es suyo; ver `BookKey.migrate`.
function HighlightsDeToto:_adoptBookKeyState()
    if not self.book_key or not self.book_hash or not self.queue then return 0 end
    local annotation_module = self.ui and self.ui.annotation
    local annotations = annotation_module and type(annotation_module.annotations) == "table"
        and annotation_module.annotations or {}
    local book_hash = self.book_hash
    local adopted = BookKey.migrate(self.queue, self.book_key, book_hash, annotations, function(item)
        return AnnotationAdapter.deriveSyncId(book_hash, item)
    end)
    -- La marca de foto historica se muda como el resto del estado: desde el
    -- hash (versiones anteriores) o desde la clave de un nombre o titulo
    -- anterior de este mismo libro (renombrar no repite la importacion).
    -- Aunque no se haya adoptado nada (otro libro del mismo hash, o uno sin
    -- nada sincronizado), lo de este libro igual viaja entero como eventos v2:
    -- otra foto solo repetiria pedidos.
    if self.annotation_v2_bridged[self.book_key] ~= true then
        for _, source in ipairs(self.queue:annotationKeysForHash(book_hash)) do
            if source ~= self.book_key and self.annotation_v2_bridged[source] == true then
                self.annotation_v2_bridged[self.book_key] = true
                self._sync_state_dirty = true
                break
            end
        end
    end
    if adopted > 0 then
        logger.info("Borges: adopted", adopted, "synchronized annotations under the book key")
    end
    return adopted
end

--- Donde vive lo ya sincronizado del libro abierto: su clave local
-- (bookkey.lua), o el hash si todavia no se calculo.
function HighlightsDeToto:_annotationStateKey()
    return self.book_key or self.book_hash
end

function HighlightsDeToto:_annotationBookDescriptor()
    return {
        title = self.book_title ~= "" and self.book_title
            or self.book_filename
            or _("Unknown book"),
        author = self.book_author,
        file = self.book_filename,
        total_pages = self.total_pages,
        identifiers = self.book_identifiers,
    }
end

function HighlightsDeToto:_annotationMode()
    if self.ui and self.ui.rolling ~= nil then return "rolling" end
    if self.ui and self.ui.paging ~= nil then return "paging" end
end

--- Apply one exact-edition remote annotation to KOReader's live sidecar.
-- Invalid locators stay in the durable inbox until that edition can apply them.
function HighlightsDeToto:_applyAnnotationV2Event(event)
    local annotation_module = self.ui and self.ui.annotation
    if not self.book_hash or not annotation_module
        or type(annotation_module.annotations) ~= "table" then
        return "defer"
    end
    local mode = self:_annotationMode()
    if not mode then return "defer" end

    local result, err = AnnotationAdapter:applyRemote(
        event,
        annotation_module.annotations,
        {
            mode = mode,
            book_hash = self.book_hash,
            book = self:_annotationBookDescriptor(),
            validate_xpointer = function(xpointer)
                return self:_isValidXPointer(xpointer)
            end,
            read_text = event.event_type == "annotation.created"
                and event.origin_device and event.origin_device.platform == "web"
                and function(first, last)
                    if not self.ui.document.getTextFromXPointers then return nil end
                    return self.ui.document:getTextFromXPointers(first, last, false)
                end or nil,
            add = function(item)
                annotation_module:addItem(item)
            end,
            remove = function(index)
                table.remove(annotation_module.annotations, index)
            end,
        }
    )
    if not result then
        logger.warn(
            "Borges: deferred remote annotation:",
            tostring(err),
            tostring(event.event_id)
        )
        return "defer"
    end

    if result.action ~= "noop" then
        -- El respaldo copia el sidecar que esta en el disco, que todavia no
        -- tiene este cambio: alcanza con hacerlo antes del primer guardado.
        -- Antes se copiaba el archivo entero (hasta 900 KB) en cada apertura
        -- aunque despues no se aplicara nada.
        if not self._annotation_pull_backed_up then
            self._annotation_pull_backed_up =
                self:_backupCurrentMetadataBeforePull() == true
        end
        -- Renumerar y reordenar todas las anotaciones del libro (KOReader le
        -- pregunta a crengine por cada una) se hace una vez por tanda, no una
        -- vez por anotacion recibida. Sale siempre antes de guardar.
        self._annotations_unsettled = true
        -- Se guarda una vez por operacion, antes de que la cola asiente el
        -- evento como aplicado (`queue.before_flush`).
        self:_markSidecarDirty()
    end

    local state_key = self:_annotationStateKey()
    local state = self.queue:getAnnotationState(state_key)
    if result.action == "deleted" or result.action == "noop" then
        state[result.sync_id] = {
            kind = result.kind,
            revision = result.revision,
            present = false,
        }
    else
        state[result.sync_id] = {
            fingerprint = result.fingerprint,
            kind = result.kind,
            revision = result.revision,
            present = true,
        }
    end
    self.queue:setAnnotationState(state_key, state, true)
    self.last_web_sync = os.time()
    self._sync_state_dirty = true
    return true
end

--- Diff the current KOReader annotation list against its durable local
-- checkpoint and append immutable create/update/delete events to the v2 outbox.
function HighlightsDeToto:_enqueueAnnotationDiff()
    local annotation_module = self.ui and self.ui.annotation
    if not self.book_hash or not annotation_module
        or type(annotation_module.annotations) ~= "table" then
        return 0, 0
    end

    local state_key = self:_annotationStateKey()
    local previous = self.queue:getAnnotationState(state_key)
    -- Los que el servidor rechazo porque su id ya es de otro subrayado.
    local reidentify = {}
    for sync_id, entry in pairs(previous) do
        if type(entry) == "table" and entry.reidentify == true then reidentify[sync_id] = true end
    end
    local events, next_state, assigned = AnnotationAdapter:diff(
        self.book_hash,
        annotation_module.annotations,
        previous,
        self:_annotationBookDescriptor(),
        -- Un subrayado nuevo recibe un id aleatorio: el derivado de la
        -- ubicacion se repite entre dos libros del mismo hash.
        { new_id = function() return random.uuid(true):lower() end, reidentify = reidentify }
    )
    -- Primero el libro, despues la cola: un subrayado cuyo evento ya salio
    -- tiene que estar en el sidecar, o la proxima comparacion lo daria por
    -- borrado. Sin eventos, sin ids nuevos y sin cambios del plugin no hay
    -- nada que KOReader no vaya a guardar solo.
    -- Si en esta misma pasada ya se escribio (la cola lo pide antes de
    -- guardar), no se escribe otra vez.
    if (assigned > 0 or self._sidecar_dirty or (#events > 0 and not self._sidecar_written))
        and self.ui and self.ui.doc_settings then
        self:_settleAnnotations()
        self.ui.doc_settings:saveSetting(
            "annotations",
            annotation_module.annotations
        )
        self.ui.doc_settings:flush()
        self._sidecar_dirty = false
    end
    self._sidecar_written = false
    for _, event in ipairs(events) do
        event.book_identifier = self:_bookIdentifier(self.book_hash)
        event.occurred_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        event.time_precision = "exact"
        event._book_key = self.book_key
        self.sync_v2:enqueue(event, { defer = true })
    end
    self.queue:setAnnotationState(state_key, next_state, true)
    -- Todos los subrayados nuevos y su anotacion de "ya encolado" salen en un
    -- guardado: primero el outbox, despues el libro. Antes era un guardado de
    -- toda la cola por cada subrayado.
    self.queue:flush()
    return #events, assigned
end

function HighlightsDeToto:_enqueueSessionV2(session_data, defer)
    if not session_data or not session_data.book_hash then return nil end
    local book_hash = tostring(session_data.book_hash):lower()
    return self.sync_v2:enqueue({
        event_type = "session.ended",
        aggregate_type = "reading_session",
        aggregate_id = "session:" .. book_hash .. ":" .. tostring(session_data.started_at),
        book_identifier = self:_bookIdentifier(book_hash),
        occurred_at = session_data.ended_at,
        time_precision = "exact",
        payload = {
            started_at = session_data.started_at,
            ended_at = session_data.ended_at,
            duration_seconds = session_data.duration_seconds,
            pages_read = session_data.pages_read,
            start_page = session_data.start_page,
            end_page = session_data.end_page,
            timezone = session_data.timezone or "UTC",
            explicit_jump = session_data.is_jump == true,
        },
    }, { defer = defer == true })
end

function HighlightsDeToto:_progressPayload(is_jump)
    if not self.book_hash then return nil end
    local current_page = self.ui:getCurrentPage()
    local percentage = self.total_pages and self.total_pages > 0
        and math.floor((current_page / self.total_pages) * 1000000) / 10000
        or 0
    return {
        percentage = percentage,
        current_page = current_page,
        total_pages = self.total_pages,
        xpointer = self:_getXPointer(),
        explicit_jump = is_jump == true,
        title = self.book_title,
        author = self.book_author,
        -- F5 · Con el archivo el servidor distingue dos libros del mismo hash.
        file = self.book_filename,
    }
end

--- F6: el localizador de la posicion que se va a encolar (capitulo, fraccion
-- y, si el ajuste esta prendido, el texto de la pantalla). Se arma solo al
-- encolar, nunca al pasar pagina; con el mismo XPointer se reusa el anterior
-- (dormir despues de un autoguardado no vuelve a leer texto).
-- Devuelve una copia: la cola nunca comparte tablas con la cache.
function HighlightsDeToto:_progressLocator(payload)
    if type(payload) ~= "table" or not self.ui or not self.ui.document then return nil end
    local capture_text = self:isPositionTextCaptureEnabled()
    local key = tostring(payload.xpointer or ("page:" .. tostring(payload.current_page)))
    local cache = self._locator_cache
    local locator
    if cache and cache.key == key and cache.capture_text == capture_text then
        locator = cache.locator
    else
        local ok, result = pcall(PositionLocator.capture, self.ui, {
            has_pages = self.has_pages == true,
            percentage = payload.percentage,
            page = payload.current_page,
            total_pages = payload.total_pages,
            capture_text = capture_text,
            xpointer = payload.xpointer,
        })
        if ok then
            locator = result
        else
            locator = nil
            if not self._locator_error_logged then
                self._locator_error_logged = true
                logger.warn("Borges: position locator failed:", tostring(result))
            end
        end
        self._locator_cache = { key = key, capture_text = capture_text, locator = locator }
    end
    if type(locator) ~= "table" then return nil end
    local copy = PositionLocator.copy(locator)
    -- La fraccion del libro y la pagina se recalculan aunque el XPointer sea
    -- el mismo (otra letra mueve la pagina sin mover el parrafo).
    local pct = tonumber(payload.percentage)
    if pct then copy.locations.totalProgression = math.floor(math.max(0, math.min(1, pct / 100)) * 10000 + 0.5) / 10000 end
    if tonumber(payload.current_page) then copy.locations.position = math.floor(payload.current_page) end
    return copy
end

--- @param defer boolean lo guarda el proximo queue:flush() de quien llama
function HighlightsDeToto:_enqueueProgressV2(is_jump, defer)
    -- Con que metodo se llego (sólo el encolado de ESE salto): se consume
    -- siempre, salga o no el evento, para que no se pegue al próximo salto.
    local arrived_by = self._pending_arrived_by
    self._pending_arrived_by = nil
    if not self.book_hash then return nil end
    if is_jump then self:_recordReadingActivity() end
    -- Opening/reconnecting/closing an untouched book is not a new reading.
    if not self._reading_activity_at then return nil end
    local book_hash = tostring(self.book_hash):lower()
    local payload = self:_progressPayload(is_jump)
    local signature = table.concat({book_hash, self._reading_activity_at,
        tostring(payload.xpointer or payload.current_page), tostring(is_jump == true)}, "|")
    if signature == self._last_enqueued_progress then return nil end
    -- F6: el localizador se arma solo si el evento va a salir; no entra en la firma.
    local ok_locator, locator = pcall(self._progressLocator, self, payload)
    payload.locator = ok_locator and locator or nil
    if is_jump and arrived_by then
        payload.locator = payload.locator or { v = PositionLocator.VERSION, locations = {} }
        payload.locator.arrived_by = arrived_by
    end
    local result, err = self.sync_v2:enqueue({
        event_type = "progress.changed",
        aggregate_type = "reading_progress",
        aggregate_id = "koreader_partial_md5:" .. book_hash,
        book_identifier = self:_bookIdentifier(book_hash),
        occurred_at = self._reading_activity_at,
        time_precision = "exact",
        payload = payload,
        -- Local: la retencion y la coalescencia son por libro, no por hash.
        _book_key = self.book_key,
    }, {
        -- Only never-attempted progress may be replaced. Once transport has
        -- seen an event its content remains immutable across every retry.
        coalesce_unattempted = true,
        defer = defer == true,
    })
    if result then
        self._last_enqueued_progress = signature
        self.ui.doc_settings:saveSetting("toto_reading_activity", {
            device_id = self.paired_device_id or self.device_id,
            occurred_at = self._reading_activity_at, enqueued = signature,
        })
    end
    return result, err
end

function HighlightsDeToto:_recordReadingActivity()
    self.last_progress_change = os.time()
    self._reading_activity_device = self.paired_device_id or self.device_id
    self._reading_activity_at = os.date("!%Y-%m-%dT%H:%M:%SZ", self.last_progress_change)
    if self.ui and self.ui.doc_settings then
        self.ui.doc_settings:saveSetting("toto_reading_activity", {
            device_id = self.paired_device_id or self.device_id, occurred_at = self._reading_activity_at,
        })
    end
end

function HighlightsDeToto:_syncV2Now(quick, max_pages, force)
    if not self.device_token then
        return nil, WebApi.apiError(
            "device_not_paired",
            _("This device must finish pairing before Borges v2 can connect."),
            nil,
            false
        )
    end
    if not NetworkMgr:isConnected() then
        return nil, WebApi.apiError(
            "offline",
            _("No network connection."),
            nil,
            true
        )
    end
    self:_safecall("resolveHeldProgress", function() self:_resolveHeldProgress(false) end)
    local result, err = self.sync_v2:syncAll(force == true, max_pages or 20, quick)
    if result then
        self.last_progress_sync = os.time()
        self:saveSyncState(true)
    end
    return result, err
end

--- Save progress locally first, then make a short opportunistic exchange.
function HighlightsDeToto:_pushProgressOrQueue()
    if not self.book_hash or not self:isWebConfigured() then return end
    self:_enqueueProgressV2(false)
    if NetworkMgr:isConnected() and self.device_token then
        local result = self:_syncV2Now(true, 2)
        if result then self.push_timestamp = os.time() end
    end
end

--- Exchange one v2 page and one pre-v2 compatibility item per UI tick.
--- @param after_pull boolean el servidor se acaba de consultar entero: si no
-- hay nada para subir, otro pedido solo repetiria esa consulta.
function HighlightsDeToto:_drainQueue(after_pull)
    if self._closed then return end
    if not Background.current() then
        return self:_runBackgroundSync("drain", function() self:_drainQueue(after_pull) end)
    end
    if not NetworkMgr:isConnected() then return end
    self:_safecall("resolveHeldProgress", function() self:_resolveHeldProgress(false) end)
    local v2_result, v2_err
    if self.device_token and not (after_pull and self.queue:sendableCount() == 0) then
        v2_result, v2_err = self.sync_v2:sync(false, true)
        if v2_err then
            logger.warn("Borges: Borges v2 drain failed:", tostring(v2_err))
        end
    end

    local result
    if self.queue:count() > self.queue:v2Count() then
        result = self.queue:drainOne(self:getApi(), self:getBaseUrl(), self:getWebAuth())
    end

    if result and result.sent then
        logger.info("Borges: legacy queue item sent,", result.remaining, "remaining")
        -- Update sync timestamps when items drain from queue
        if result.item_type == "highlights" then
            self.last_web_sync = os.time()
            self:saveSyncState()
        elseif result.item_type == "page_stats" then
            self.last_stats_sync = os.time()
            self.last_stats_error = nil
            self:saveSyncState()
        end
    elseif result then
        logger.warn("Borges: legacy queue item failed:", tostring(result.error))
        if result.item_type == "page_stats" then
            self.last_stats_error = result.error
        end
        -- drainOne retains a failed item at the front. Keep it for the next
        -- sync trigger instead of retrying the same blocking HTTP every tick.
    end

    -- More items? Schedule next drain on next UI tick
    local has_more_v2 = v2_result
        and (v2_result.has_more
            or ((v2_result.pending or 0) > 0 and (v2_result.sent or 0) > 0))
    local has_more_legacy = result and result.sent and result.remaining > 0
    if has_more_v2 or has_more_legacy then
        UIManager:nextTick(function()
            self:_safecall("queueDrain", function() self:_drainQueue() end)
        end)
    end
end

--- ¿Esta instancia (sin libro: el explorador) le deja lo de dormir al libro
-- abierto en la instancia viva? Ese libro todavia tiene que encolar su
-- posicion y su sesion, y es el unico que puede mandarlas.
function HighlightsDeToto:_leavesSleepToOpenBook()
    local live = Shared.live
    return not self.book_hash and live ~= nil and live ~= self
        and not live._closed and live.book_hash ~= nil
end

--- El intercambio de antes de dormir (o de cortarse el Wi-Fi), con la
-- pantalla esperando. Acotado por `SleepBudget`: a lo sumo una consulta de la
-- ultima lectura y UN intercambio (mas un reintento solo ante un 409 de
-- secuencia o idempotencia), 40 eventos y 96 KB con la posicion y la sesion
-- primero, plazos de 4 s / 8 s por pedido y nada empieza pasados 8 s.
--
-- Antes era una consulta por cada libro retenido mas hasta 50 paginas de
-- intercambio y la cola legada entera: un libro de 125 subrayados nuevos eran
-- siete intercambios al dormir. Lo que no entra no se pierde: queda en el
-- outbox y sale con el proximo drenaje en segundo plano (lotes de 100). La
-- cola legada tambien queda para `_drainQueue`, que la manda de a un item.
--
-- Devuelve nil sin red, false si la red fallo y true en cualquier otro caso.
function HighlightsDeToto:_drainQueueBlocking(quick)
    if not NetworkMgr:isConnected() then return end
    -- El explorador no drena si hay un libro abierto en la instancia viva: ese
    -- libro todavia tiene que encolar su posicion y su sesion, y el
    -- intercambio de la suspension tiene que llevarlas. Si el explorador
    -- drenara primero, la guarda de abajo dejaria afuera lo del libro.
    if self:_leavesSleepToOpenBook() then return true end
    local started = os.time()
    -- El explorador y el libro reciben el mismo aviso: la segunda instancia
    -- no repite lo que la primera acaba de hacer. Y una suspension es UN
    -- intercambio: el Wi-Fi que KOReader mata al dormir vuelve a avisar
    -- NetworkDisconnecting quince segundos despues, con la pantalla negra.
    local last = Shared.sleep_exchange_at
    local asleep = Device.screen_saver_mode == true
    if (last and started >= last and started - last < SleepBudget.REPEAT_GUARD_SECONDS)
        or (asleep and Shared.sleep_exchange_this_suspension) then
        return true
    end
    Shared.sleep_exchange_at = started
    if asleep then Shared.sleep_exchange_this_suspension = true end
    -- Es la ultima oportunidad con red: una posicion retenida pregunta
    -- siempre, sin esperar el intervalo, pero por UN libro (el abierto primero).
    local held_failed = false
    self:_safecall("resolveHeldProgress", function()
        local _, failed = self:_resolveHeldProgress(true, SleepBudget.FOCUS_CHECKS, "sleep")
        held_failed = failed == true
    end)
    if held_failed then
        -- La red acaba de fallar con la pantalla esperando: otro pedido iba a
        -- tardar lo mismo en fallar. Todo queda guardado para la proxima vez.
        Shared.sleep_exchange_at = os.time()
        return false
    end
    -- Sin nada que pueda salir no se hace ningun pedido.
    if self.device_token and self.queue:sendableCount() > 0
        and os.time() - started < SleepBudget.DEADLINE_SECONDS then
        local sync_result, sync_err = self.sync_v2:sync(false, "sleep", {
            max_events = SleepBudget.MAX_EVENTS,
            max_bytes = SleepBudget.MAX_BYTES,
            priority = SleepBudget.PRIORITY,
            max_recoveries = 1,
            -- El tope de 8 s vale para CADA pedido, tambien para el reintento.
            deadline = started + SleepBudget.DEADLINE_SECONDS,
        })
        Shared.sleep_exchange_at = os.time()
        if not sync_result then
            logger.warn("Borges: sleep exchange failed:", tostring(sync_err))
            return false
        end
        self.push_timestamp = os.time()
        self.last_progress_sync = self.push_timestamp
        self:saveSyncState(true)
    end
    Shared.sleep_exchange_at = os.time()
    return true
end

-- ============================================================
-- C17 · Un solo flujo para retomar la lectura
--
-- Abrir el libro, despertar el lector, prender el Wi-Fi a mano y tocar
-- "Sincronizar" eran cuatro caminos distintos con cuatro resultados posibles.
-- El peor era la reconexión manual: sólo vaciaba la cola, así que subía la
-- posición vieja de este lector y la del otro aparato no llegaba a aparecer.
--
-- Ahora los cuatro pasan por acá y hacen lo mismo, en el mismo orden:
-- consultar el servidor primero, completar la paginación, y recién después
-- subir lo que quedó guardado. Si la consulta falla, la cola queda intacta y
-- el progreso queda retenido incluso al cerrar, suspender o apagar el Wi-Fi.
-- Sólo una consulta válida y, si corresponde, una elección lo habilitan.
-- ============================================================

--- Snapshot the reading we had when a connection cycle began, before Wi-Fi
-- or other background requests can delay the focused progress check.
function HighlightsDeToto:_captureReadingBaseline()
    return { book_hash = self.book_hash, occurred_at = self._reading_activity_at,
        time_precision = self._reading_activity_at and "exact" or "unknown" }
end

function HighlightsDeToto:_clearReadingHead()
    self._reading_head = nil
    self._offered_sync_events = {}
    if self._remote_position_dialog then
        local dialog = self._remote_position_dialog
        self._remote_position_dialog = nil
        UIManager:close(dialog)
    end
    if self.resume_flow then self.resume_flow:clearVisible() end
end

function HighlightsDeToto:_beginReadingHandoff()
    if not self.device_token or not self.book_hash or not self.queue then return end
    self:_clearReadingHead()
    self.queue:holdProgress(self:_bookIdentifier(self.book_hash), self.book_key)
end

--- Lo que dice la cabeza de lectura del servidor para `book_hash`: si hay que
-- preguntar (otro aparato leyo despues y nadie eligio todavia) y el evento.
function HighlightsDeToto:_readReadingHead(response, book_hash)
    if not book_hash or response.reading_head_checked ~= true then
        return nil, "reading_head_unavailable"
    end
    local event = response.focus_event
    if event == nil or event == rapidjson.null then return { ask = false } end
    local identifier = type(event) == "table" and event.book_identifier
    local source = type(event) == "table" and event.origin_device
    if not identifier or identifier.value ~= book_hash or identifier.kind ~= "koreader_partial_md5"
        or not source or not source.id or not event.event_id
        or not event.directive_metadata or event.directive_metadata.reading_head ~= true then
        return nil, "reading_head_invalid"
    end
    local own = source.id == self.paired_device_id or source.id == self.device_id
    local chosen = self.resume_flow:hasLocalChoice(book_hash, event,
        self.paired_device_id or self.device_id)
    return { ask = not own and not chosen, event_id = event.event_id }
end

function HighlightsDeToto:_handleReadingHead(response, context)
    if context and context.closed then
        -- Un libro que ya no esta abierto: nadie puede elegir ahora. Si la
        -- ultima lectura es de este lector, su posicion sale; si es de otro,
        -- sigue retenida y se pregunta al abrir ese libro.
        if context.token ~= self.device_token or context.epoch ~= self._background_epoch then
            return nil, "stale_reading_head"
        end
        local found, reason = self:_readReadingHead(response, context.book_hash)
        if not found then return nil, reason end
        if not found.ask then
            self.queue:releaseProgress(self:_bookIdentifier(context.book_hash), context.book_key)
        end
        logger.info("Borges: last reading checked for a closed book; still held:", found.ask)
        return true
    end
    if context and (context.book_hash ~= self.book_hash or context.token ~= self.device_token
        or context.epoch ~= self._background_epoch) then return nil, "stale_reading_head" end
    local found, reason = self:_readReadingHead(response, self.book_hash)
    if not found then return nil, reason end
    local head = { book_hash = self.book_hash, token = self.device_token,
        ask = found.ask, event_id = found.event_id }
    self._reading_head = head
    logger.info("Borges: last reading checked; choice required:", head.ask)
    if not head.ask then self.queue:releaseProgress(self:_bookIdentifier(self.book_hash), self.book_key) end
    return true
end

function HighlightsDeToto:_finishReadingChoice(book_hash, remote, opts, action)
    if opts.reading_head and (self._reading_head ~= opts.reading_head
        or opts.reading_head.token ~= self.device_token) then return false end
    self:_recordReadingActivity()
    local queued, err = self:_enqueueProgressV2(action == "accept")
    if not queued and err then error(tostring(err)) end
    self.ui.doc_settings:flush()
    self.resume_flow:remember(book_hash, remote, action,
        self.paired_device_id or self.device_id, self._reading_activity_at)
    self.queue:releaseProgress(self:_bookIdentifier(book_hash), book_hash == self.book_hash and self.book_key or nil)
    if self._reading_head then self._reading_head.ask = false end
    self:_resolveSuggestion(opts, action)
    UIManager:nextTick(function() self:_drainQueue() end)
    return true
end

--- Fetch remote state through the background transport, focused on this book.
function HighlightsDeToto:_pullRemoteNow(skip_focus, reading_baseline)
    if self.device_token then
        if not skip_focus then
            if self._reading_head and self._reading_head.ask and self.resume_flow:isVisible() then
                return { reading_choice_pending = true }
            end
            self:_beginReadingHandoff()
            -- Keep the pre-connection time through the worker queue and HTTP.
            -- A page notification while waiting must not hide this suggestion.
            self._resume_reading_baseline = reading_baseline
                and reading_baseline.book_hash == self.book_hash and reading_baseline
                or self:_captureReadingBaseline()
            local preview, preview_err = self.sync_v2:pull(true, self:_bookIdentifier(self.book_hash), true)
            if not preview then return nil, preview_err end
            Background.yieldToUI()
            self:_safecall("sanitizeAnnotations", function() self:_sanitizeLocalAnnotations() end)
        end
        local result, err = self.sync_v2:pullAll(4, true)
        if not result then return nil, err end
        self:_safecall("applySyncInbox", function() self:_applyInboxForCurrentBook() end)
        return result
    end
    -- Sin credencial de dispositivo sigue existiendo el camino anterior.
    local ok = self:_safecall("pullProgressLegacy", function() self:pullProgress() end)
    if not ok then return nil, "pull_failed" end
    return { pages = 1 }
end

--- Correr el flujo completo de una conexión.
-- @param reason string de dónde vino (sólo para el log)
-- @param options table {force=bool} — `force` lo usa la acción manual
function HighlightsDeToto:_runConnectedSync(reason, options)
    options = options or {}
    if not options.reading_baseline then
        options.reading_baseline = self:_captureReadingBaseline()
    end
    if not Background.current() then
        return self:_runBackgroundSync("connected", function() self:_runConnectedSync(reason, options) end)
    end
    local plan = ResumeFlow.planConnect({
        connected = NetworkMgr:isConnected(),
        session = self:isWebConfigured(),
        book_open = self.book_hash ~= nil,
        running = self._connect_sync_running == true,
        last_sync_at = self._connect_sync_at,
        now = os.time(),
        min_interval = RECONNECT_SYNC_DEBOUNCE,
        force = options.force == true,
    })
    if #plan.steps == 0 then
        logger.info("Borges: connected sync skipped -", reason, plan.reason)
        return false, plan.reason
    end

    self._connect_sync_running = true
    self._connect_sync_at = os.time()
    local pull_ok = true
    local pull_err
    for _index, step in ipairs(plan.steps) do
        if step == ResumeFlow.STEP_PULL then
            local result
            result, pull_err = self:_pullRemoteNow(reason == "history_continuation", options.reading_baseline)
            pull_ok = result ~= nil
            if pull_ok and result.has_more then
                -- Keep pulling in bounded turns. Never upload stale local
                -- progress merely because the four-page read budget ran out.
                local epoch = self._background_epoch
                UIManager:nextTick(function()
                    if self._background_epoch == epoch then
                        self:_runConnectedSync("history_continuation", { force = true })
                    end
                end)
                self._connect_sync_running = false
                return true
            end
            if pull_ok and self.auto_pull_highlights then
                self:_safecall("pullHighlights", function() self:pullHighlightsFromWeb(false) end)
            end
        elseif step == ResumeFlow.STEP_DRAIN then
            if not pull_ok then
                -- Conservar la cola es el punto: subirla acá le diría al
                -- servidor que esta posición vieja es la última escritura.
                logger.warn("Borges: drain held back, remote read failed:",
                    tostring(pull_err))
            else
                -- Las paginas leidas desde la ultima vez se encolan aca y
                -- viajan en el mismo envio que el resto. Antes tenian su propio
                -- temporizador a los dos minutos, con su propio pedido, que
                -- ademas seguia vivo en instancias ya cerradas.
                UIManager:scheduleIn(RECONNECT_DRAIN_DELAY, function()
                    self:_runBackgroundSync("drain", function()
                        self:_safecall("statsBeforeDrain", function() self:syncPageStatsDelta(true) end)
                        self:_safecall("queueDrain", function() self:_drainQueue(true) end)
                        -- La foto historica del libro abierto, si todavia no
                        -- salio: aca, en segundo plano y por partes.
                        if self.book_hash and self.annotation_v2_bridged[self:_bridgeKey()] ~= true then
                            self:_safecall("historyBridge", function() self:_bridgeHistoryInBackground() end)
                        end
                    end)
                end)
            end
        end
    end
    self._connect_sync_running = false
    self:_recordOperationOutcome('sync_pull', pull_ok, pull_err)
    return pull_ok, pull_err
end

--- El único lugar donde se ofrece la posición de otro lector.
-- @param opts table {remote, source, others, suggestion_id, event_id,
--   account_scope, force, book_hash, reading_baseline, reading_head}
-- @return boolean, string|nil motivo cuando no se ofrece
function HighlightsDeToto:_offerRemotePosition(opts)
    opts = opts or {}
    if opts.reading_head and (opts.reading_head ~= self._reading_head
        or opts.reading_head.token ~= self.device_token or not opts.reading_head.ask) then
        return false, "stale_reading_head"
    end
    local remote = opts.remote
    local book_hash = opts.book_hash or self.book_hash
    local flow = self.resume_flow
    if not flow then return false, "no_flow" end
    local local_position = self:_currentPositionSnapshot()
    do
        local ok_locator, locator = pcall(self._localLocatorForCompare, self)
        if ok_locator then local_position.locator = locator end
    end
    if opts.reading_baseline and opts.reading_baseline.book_hash == book_hash then
        local_position.occurred_at = opts.reading_baseline.occurred_at
        local_position.time_precision = opts.reading_baseline.time_precision
    end

    local allowed, reason = flow:shouldOffer({
        book_hash = book_hash,
        open_book_hash = self.book_hash,
        account_scope = opts.account_scope,
        current_account = self.queue and self.queue:getAccountScope() or nil,
        remote = remote,
        local_position = local_position,
        total_pages = self.total_pages,
        last_reading_elsewhere = opts.reading_head ~= nil and opts.reading_head == self._reading_head
            and opts.reading_head.ask == true,
    })
    if not allowed then
        -- Pedirlo desde el menú es una orden explícita: una respuesta anterior
        -- o una diferencia mínima no pueden dejar al lector sin respuesta.
        local overridable = reason == ResumeFlow.ALREADY_RESOLVED
            or reason == ResumeFlow.SAME_POSITION
            or reason == ResumeFlow.OLDER_READING
        if not (opts.force == true and overridable) then
            logger.info("Borges: remote position not offered -", reason)
            return false, reason
        end
    end

    if not flow:markVisible(book_hash, remote) then
        return false, ResumeFlow.ALREADY_VISIBLE
    end

    local copy = ResumeFlow.describe({
        book_title = self.book_title,
        remote = self:_describableRemotePosition(remote),
        local_position = self:_currentPositionSnapshot(),
        total_pages = self.total_pages,
        source = opts.source,
        others = self:_describableOtherPositions(opts.others),
        format_time = function(iso) return self:_formatProgressTimestamp(iso) end,
    })

    -- Un `ConfirmBox` se cierra con CUALQUIER botón, el de detalle incluido.
    -- Por eso el detalle no se abre "encima": se abre en lugar de la pregunta
    -- y desde ahí se vuelve. Mirar los números no puede costar la decisión.
    local viewing_detail = false
    local dialog
    dialog = ConfirmBox:new{
        flush_events_on_show = true,
        dismissable = false,
        text = copy.title .. "\n\n" .. copy.text,
        ok_text = copy.ok_text,
        cancel_text = copy.cancel_text,
        other_buttons_first = true,
        other_buttons = {{
            {
                text = _("View details"),
                callback = function()
                    viewing_detail = true
                    self:_showRemotePositionDetail(copy, book_hash, remote, opts)
                end,
            },
        }},
        ok_callback = function()
            self:_acceptRemotePosition(book_hash, remote, opts)
        end,
        cancel_callback = function()
            self:_dismissRemotePosition(book_hash, remote, opts)
        end,
    }
    -- Cerrar con Back o tocando afuera no acepta nada, pero sí tiene que
    -- soltar la compuerta: si no, el próximo aviso no saldría nunca. La
    -- excepción es el detalle, que sigue siendo el mismo aviso: ahí la
    -- compuerta la suelta la pantalla de detalle.
    local previous_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget, ...)
        if self._remote_position_dialog == widget then self._remote_position_dialog = nil end
        if not viewing_detail then self:_releaseRemoteOffer() end
        if previous_close then return previous_close(widget, ...) end
    end
    self._remote_position_dialog = dialog
    UIManager:show(dialog)
    logger.info("Borges: remote position confirmation shown")
    return true
end

--- Soltar la compuerta y darle su turno a lo que quedó esperando.
--
-- Dos sugerencias que llegan juntas no se apilan, pero tampoco se pierden: la
-- segunda sigue en el inbox y al cerrarse la primera se vuelve a evaluar.
function HighlightsDeToto:_releaseRemoteOffer()
    if not self.resume_flow then return end
    self.resume_flow:clearVisible()
    if self._reading_head and self._reading_head.ask then
        self._offered_sync_events[self._reading_head.event_id] = nil
    end
    UIManager:nextTick(function()
        self:_runBackgroundSync("inbox", function() self:_applyInboxForCurrentBook() end)
    end)
end

--- Los números, para quien los quiera. Se sale volviendo a la pregunta, así
-- que consultar el detalle nunca deja al lector sin decidir.
function HighlightsDeToto:_showRemotePositionDetail(copy, book_hash, remote, opts)
    local detail
    detail = ConfirmBox:new{
        flush_events_on_show = true,
        dismissable = false,
        text = copy.detail,
        ok_text = _("Back"),
        cancel_text = copy.cancel_text,
        ok_callback = function()
            UIManager:nextTick(function()
                self:_offerRemotePosition(opts)
            end)
        end,
        cancel_callback = function()
            self:_dismissRemotePosition(book_hash, remote, opts)
        end,
    }
    local previous_close = detail.onCloseWidget
    detail.onCloseWidget = function(widget, ...)
        if self._remote_position_dialog == widget then self._remote_position_dialog = nil end
        self:_releaseRemoteOffer()
        if previous_close then return previous_close(widget, ...) end
    end
    self._remote_position_dialog = detail
    UIManager:show(detail)
end

--- La posición remota, contada en páginas y capítulos de ESTE libro.
--
-- La página que manda el otro aparato es suya: otra fuente, otro margen, otro
-- recuento. Mostrarla tal cual sería decirle al lector "pág. 512" en un libro
-- que acá tiene 300. Lo único comparable es el porcentaje, así que de ahí
-- sale la página local y de la página local sale el capítulo.
--
-- Es una copia: la posición original sigue siendo la que navega y la que
-- identifica la decisión, porque su ancla y su id son los que valen.
function HighlightsDeToto:_describableRemotePosition(remote)
    if type(remote) ~= "table" then return remote end
    local describable = {}
    for key, value in pairs(remote) do describable[key] = value end
    local display_page = self:_calcDisplayPage(remote)
    describable.current_page = display_page
    describable.total_pages = self.total_pages or remote.total_pages
    -- F6: con capitulo mapeable el porcentaje sale de ESTE libro (otra
    -- edicion con otro prologo ya no dice "mas atras" en falso). Se suma una
    -- pagina para hablar como _calcLocalPercentage (pagina actual / total).
    if type(remote.locator) == "table" and self.total_pages and self.total_pages > 0 then
        local ok, pct = pcall(PositionLocator.localPercent, self.ui, remote.locator, self.total_pages)
        if ok and pct then
            describable.comparable_percentage = math.min(100, pct + 100 / self.total_pages)
        end
    end
    local ok_anchor, anchor = pcall(self._remoteAnchor, self, remote)
    describable.anchor = ok_anchor and anchor or nil
    if not describable.chapter_title and display_page then
        describable.chapter_title = self:_getChapterTitleForPage(display_page)
    end
    return describable
end

--- F6: que tan firme es la ubicacion de una posicion ajena en ESTE libro
-- (solo para el texto del aviso; navegar lo decide _navigateToProgress).
function HighlightsDeToto:_remoteAnchor(remote)
    if type(remote) ~= "table" then return "approximate" end
    -- "Exacta" sólo si el XPointer existe Y dice lo mismo que la pantalla del
    -- otro lector (la misma verificación que hace el salto).
    if not self.has_pages and self:_isValidXPointer(remote.xpointer)
        and PositionLocator.verified(self.ui.document, remote.xpointer, remote.locator, self.ui) then
        return "exact"
    end
    local locator = type(remote.locator) == "table" and remote.locator or nil
    if not self.has_pages and locator and type(locator.text) == "table"
        and type(locator.text.highlight) == "string" and locator.text.highlight ~= "" then
        return "text"
    end
    if locator and PositionLocator.localChapter(self.ui, locator, self.total_pages) then return "chapter" end
    return "approximate"
end

--- F6: el localizador de donde esta este lector, para reconocer el mismo
-- parrafo que manda otro. Usa la cache del ultimo encolado; si se movio, lo
-- arma una vez (solo cuando llega una posicion ajena, nunca al pasar pagina).
function HighlightsDeToto:_localLocatorForCompare()
    if self.has_pages or not self.ui or not self.ui.getCurrentPage then return nil end
    local page = self.ui:getCurrentPage()
    return self:_progressLocator({
        xpointer = self:_getXPointer(),
        current_page = page,
        total_pages = self.total_pages,
        percentage = self:_calcLocalPercentage(),
    })
end

--- La lista completa que va al detalle: sin este lector, que ya se muestra
-- arriba, y con todas las posiciones traídas a las páginas de este libro.
function HighlightsDeToto:_describableOtherPositions(others)
    if type(others) ~= "table" then return nil end
    local list = {}
    for _index, row in ipairs(others) do
        if type(row) == "table" and row.device_id ~= self.device_id then
            local entry = self:_describableRemotePosition(row)
            entry.source = { id = row.device_id, name = row.device_name }
            table.insert(list, entry)
        end
    end
    if #list == 0 then return nil end
    return list
end

--- La elección pertenece al punto mostrado, aunque haya llegado otro evento.
function HighlightsDeToto:_remoteOfferStillValid(book_hash, remote, opts)
    if opts and opts.reading_head and (self._reading_head ~= opts.reading_head
        or opts.reading_head.token ~= self.device_token or not opts.reading_head.ask) then return false end
    if self.book_hash ~= book_hash then
        self:showInfo(_("You switched books, so nothing was moved."), 5)
        return false
    end
    if not ResumeFlow.hasLocator(remote) then
        self:showInfo(_("That position has no way to locate itself in this book."), 6)
        return false
    end
    return true
end

--- "Ir a esa posición": primero el punto de retorno, después el salto, y sólo
-- al final se da por resuelta la sugerencia. Si algo falla en el medio quedan
-- las dos posiciones y el lector puede volver a intentar.
function HighlightsDeToto:_acceptRemotePosition(book_hash, remote, opts)
    if not self:_remoteOfferStillValid(book_hash, remote, opts) then return end

    local remembered = self.position_undo:remember(
        book_hash,
        self:_currentPositionSnapshot()
    )
    self:_locateAndNavigate(remote, function(method, reason)
        if not method then
            if remembered then self.position_undo:clear(book_hash) end
            -- Cerro el libro o se durmio mientras se buscaba: no hay a quien avisar.
            if reason == "cancelled" then return end
            -- Ni se descarta la sugerencia ni se anota la decisión: las dos
            -- posiciones siguen vivas y el menú puede reintentar.
            self:showInfo(_("Could not work out that position in this book. You stay where you were and can retry from the menu."), 8)
            return
        end
        self._pending_arrived_by = method
        if not self:_safecall("acceptReadingChoice", function()
            return self:_finishReadingChoice(book_hash, remote, opts, "accept")
        end) then
            self._pending_arrived_by = nil
            return
        end
        self:showInfo(T(HighlightsDeToto.arrivalNotice(method), self.ui:getCurrentPage()), 6)
    end)
end

-- F6: el aviso despues del salto dice con que metodo se llego.
function HighlightsDeToto.arrivalNotice(method)
    if method == "text" then
        return _("Found the same passage by its text: p. %1. You can go back to where you were from the menu.")
    elseif method == "chapter" then
        return _("Placed by chapter, the text was not found: p. %1. You can go back to where you were from the menu.")
    elseif method == "percentage" then
        return _("Placed by percentage, it may be a few pages off: p. %1. You can go back to where you were from the menu.")
    end
    return _("You are on p. %1. You can go back to where you were from the menu.")
end

--- Ir a un destino ya resuelto ({xpointer} o {page}).
function HighlightsDeToto:_gotoTarget(target)
    if type(target) ~= "table" then return false end
    -- F2 · un salto del plugin es "sync", no un gesto de la persona.
    local function jump(event)
        if self._syncJump then return self:_syncJump(event) end
        return self.ui:handleEvent(event)
    end
    if target.xpointer then
        jump(Event:new("GotoXPointer", target.xpointer))
        return true
    end
    if target.page then
        jump(Event:new("GotoPage", target.page))
        return true
    end
    return false
end

--- F6: la cascada completa, para un "Ir a esa posicion" que toco la persona.
-- XPointer propio (verificado por texto) -> el texto, buscado en
-- un proceso HIJO (crengine borra la seleccion al buscar) -> capitulo +
-- fraccion -> porcentaje. done(method|nil, reason).
function HighlightsDeToto:_locateAndNavigate(remote, done)
    done = done or function() end
    if type(remote) ~= "table" then return done(nil, "no_position") end
    local opts = {
        has_pages = self.has_pages == true,
        total_pages = self.total_pages,
        same_device = false,
        percentage = _safePct(remote.percentage),
    }
    local target, method = PositionLocator.resolveExact(self.ui, remote, opts)
    if target then
        self:_gotoTarget(target)
        return done(method)
    end
    if not self.has_pages and type(remote.xpointer) == "string" and remote.xpointer ~= "" then
        logger.warn("Borges: remote xpointer not usable here, locating by text:", remote.xpointer)
    end
    local function approx()
        local fallback, how = PositionLocator.resolveApprox(self.ui, remote, opts)
        if not fallback then return done(nil, "no_position") end
        self:_gotoTarget(fallback)
        return done(how)
    end
    local locator = type(remote.locator) == "table" and remote.locator or nil
    local probes = (not self.has_pages and locator) and TextLocate.probes(locator.text) or {}
    if #probes == 0 then return approx() end

    if self._locate_job then self._locate_job:cancel() end
    local book, token, epoch = self.book_hash, self.device_token, self._background_epoch
    local function valid()
        return self.book_hash == book and self.device_token == token and self._background_epoch == epoch
            and not self._background_suspended and not self._closed
    end
    local document, ui, total = self.ui.document, self.ui, self.total_pages
    local ctx = {
        chapterTitleOf = function(xp)
            return ui.toc and ui.toc.getTocTitleByPage and ui.toc:getTocTitleByPage(xp) or nil
        end,
        percentOf = function(xp)
            local page = document:getPageFromXPointer(xp)
            if type(page) ~= "number" or not total or total <= 0 then return nil end
            return page / total * 100
        end,
    }
    -- Es la respuesta a un toque de la persona: los tres puntos dicen que se
    -- está buscando. Tocar la pantalla lo cierra y CANCELA: no se navega
    -- después. Toda la búsqueda (las dos sondas) tiene un solo plazo.
    local job = Background:new{ timeout = TextLocate.SEARCH_SECONDS }
    local finished = false
    local message = ProgressMessage:new{
        text = _("Finding that passage…"),
        dismissable = true,
        dismiss_callback = function()
            if not finished then job:cancel() end
        end,
    }
    UIManager:show(message)
    self._locate_job = job
    local found
    local deadline = os.time() + TextLocate.SEARCH_SECONDS
    local started = job:run(function()
        for _index, probe in ipairs(probes) do
            local remaining = deadline - os.time()
            if remaining <= 0 then return end
            local hits = Background.request(TextLocate.searchJob(document, probe), { timeout = remaining })
            -- Una sonda que venció (o falló) no lanza la otra: es el mismo libro.
            if type(hits) ~= "table" then return end
            local chosen = TextLocate.choose(locator, probe, hits, ctx)
            if chosen then
                found = chosen
                found.words_before = probe.words_before
                return
            end
        end
    end, function(_ok, err)
        finished = true
        UIManager:close(message)
        if self._locate_job == job then self._locate_job = nil end
        local cancelled = type(err) == "table" and err.code == "background_cancelled"
        if cancelled or not valid() then return done(nil, "cancelled") end
        if found and PositionLocator.resolveExact(ui, { xpointer = found.xpointer }, {}) then
            -- La sonda puede empezar unas palabras (o una pantalla) después de
            -- donde empezaba la pantalla del otro lector: se vuelve hasta ahí.
            local target = PositionLocator.walkBack(document, found.xpointer, found.words_before)
            if not PositionLocator.resolveExact(ui, { xpointer = target }, {}) then target = found.xpointer end
            self:_gotoTarget({ xpointer = target })
            logger.info("Borges: remote position found by its text:", found.by, found.score)
            return done("text")
        end
        return approx()
    end, valid)
    if not started then
        finished = true
        UIManager:close(message)
        self._locate_job = nil
        return approx()
    end
end

--- "Seguir acá" registra una lectura explícita en la posición local,
-- sin navegar ni consumir el punto de retorno anterior.
function HighlightsDeToto:_dismissRemotePosition(book_hash, remote, opts)
    if not self:_remoteOfferStillValid(book_hash, remote, opts) then return end
    self:_safecall("keepReadingChoice", function()
        self:_finishReadingChoice(book_hash, remote, opts, "dismiss")
    end)
end

--- Contarle al servidor qué se respondió. Es el último paso a propósito: si
-- falla, la decisión local ya quedó guardada y el lector no vuelve a ver el
-- mismo aviso.
function HighlightsDeToto:_resolveSuggestion(opts, action)
    opts = opts or {}
    if opts.event_id and self.queue then
        self.queue:removeInboxEvent(opts.event_id)
    end
    if not opts.suggestion_id or not self.sync_v2 then return end
    self:_runBackgroundSync("suggestion:" .. opts.suggestion_id, function()
        local result, err = self.sync_v2:actOnSuggestion(opts.suggestion_id, action)
        if not result then
            logger.warn("Borges: could not resolve suggestion",
                tostring(opts.suggestion_id), tostring(err and (err.code or err.message) or err))
        end
    end)
end

--- Parse ISO8601 UTC timestamp ("2026-05-05T15:30:00.000Z") to epoch seconds.
-- Returns nil if input is malformed. Implementación inline porque
-- `datetime.stringISO8601ToSeconds` solo existe en KOReader nightly post-Feb-2026.
function HighlightsDeToto:_parseISO8601UTC(iso)
    if type(iso) ~= "string" then return nil end
    local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    -- os.time(t) interpreta t como local. Compensar con el offset local↔UTC
    -- para que el resultado sea epoch real, comparable con os.time().
    local local_now = os.time()
    local tz_offset = local_now - os.time(os.date("!*t", local_now))
    local local_epoch = os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
        isdst = false,
    })
    if not local_epoch then return nil end
    return local_epoch - tz_offset
end

-- No DNS preflight: the actual HTTP request resolves Borges off the UI thread.
-- The only blocking dialog is the cancelable wait for the Wi-Fi connection.
function HighlightsDeToto:_ensureReadingConnection(callback)
    if self._reading_wifi then self._reading_wifi:close(); self._reading_wifi = nil end
    local book, token, epoch = self.book_hash, self.device_token, self._background_epoch
    local function valid()
        return self.book_hash == book and self.device_token == token
            and self._background_epoch == epoch and not self._background_suspended
            and not self._reading_wifi_cancelled and not self._closed
    end
    if not valid() then return end
    if NetworkMgr:isConnected() then callback(); return end
    -- Con «Wi-Fi solo para sincronizar» el plugin prende y apaga la radio mas
    -- seguido: no puede hacerlo con un cartel encima de la pagina cada vez.
    if self:_wifiOnlyToSyncActive() and self:_connectSilently(callback, valid) then return end
    local reading_wifi
    reading_wifi = ReadingWifi:new{
        valid = valid,
        -- El cartel propio alcanza: sin los de KOReader encima.
        quiet = withoutNetworkNotices,
        on_connected = function()
            if reading_wifi.enabled_wifi then self:_ownWifi() end
            callback()
        end,
        on_cancel = function()
            self._reading_wifi_cancelled = true
            self.pull_done, self._resume_pull_done = true, true
            self:_cancelBackgroundSync()
        end,
        on_error = function(message) self:showInfo(message, 6) end,
    }
    self._reading_wifi = reading_wifi
    reading_wifi:start()
end

-- ============================================================
-- Wi-Fi solo para sincronizar (opcional)
--
-- Con el Wi-Fi prendido KOReader no deja dormir al procesador entre paginas
-- (autosuspend: "Don't enter standby if wifi is on"). El plugin lo prende en
-- cada despertar para consultar la ultima lectura y nadie lo apagaba: en un
-- lector real, el 83 % del tiempo de lectura (8,3 de 10 horas) fue con Wi-Fi
-- prendido, con una mediana de 16 minutos por sesion para unos 7 pedidos de
-- uno o dos segundos.
--
-- Con este ajuste el plugin apaga el Wi-Fi que EL prendio cuando termina de
-- sincronizar, y al suspender lo vuelve a prender un momento para subir la
-- lectura, que es lo que mantiene el traspaso entre lectores. Es lo que hace
-- KOSync (el plugin de sincronizacion de KOReader) al suspender, y KOReader lo
-- contempla: al dormir mata el Wi-Fi que un manejador de Suspend haya dejado.
--
-- Nunca toca un Wi-Fi que prendio la persona, ni lo prende al dormir si no lo
-- apago el mismo en esa sesion. Solo en Kobo, que es donde se conoce el orden
-- exacto de la suspension. Apagado por defecto hasta validarlo en un lector.
-- ============================================================

function HighlightsDeToto:canCloseWifiAfterSync()
    return Device:isKobo() == true and Device:hasWifiToggle() == true
end

function HighlightsDeToto:isWifiOnlyToSyncEnabled()
    return self.wifi_only_to_sync == true and self:canCloseWifiAfterSync()
end

--- El ajuste esta puesto Y el lector deja que KOReader prenda el Wi-Fi sin
-- preguntar. Con "preguntar" o "ignorar" el plugin no podria volver a prenderlo
-- al dormir sin pasar por encima de esa eleccion, asi que tampoco lo apaga.
function HighlightsDeToto:_wifiOnlyToSyncActive()
    return self:isWifiOnlyToSyncEnabled()
        and G_reader_settings:readSetting("wifi_enable_action") == "turn_on"
end

function HighlightsDeToto:toggleWifiOnlyToSync()
    self.wifi_only_to_sync = not (self.wifi_only_to_sync == true)
    self.wifi_only_to_sync_note, self.wifi_quiet_misses = nil, 0
    if not self.wifi_only_to_sync then
        Shared.wifi_owned, Shared.wifi_auto_closed = false, false
        Shared.wifi_quiet, Shared.wifi_quiet_failed = nil, false
    end
    self:saveSyncState()
end

--- F6: el texto de la pantalla donde quedaste viaja con la posicion para que
-- otro lector, otra edicion o la web abran el mismo parrafo. Prendido por
-- defecto; apagado, la posicion viaja sin texto (capitulo y fraccion siguen).
function HighlightsDeToto:isPositionTextCaptureEnabled()
    return self.position_text_capture ~= false
end

function HighlightsDeToto:togglePositionTextCapture()
    self.position_text_capture = not self:isPositionTextCaptureEnabled()
    self:saveSyncState()
end

function HighlightsDeToto:getWifiOnlyToSyncLabel()
    if self.wifi_only_to_sync_note == "silent_unavailable" then
        return _("Turn Wi-Fi off after syncing (turned off: this reader could not connect on its own)")
    end
    return _("Turn Wi-Fi off after syncing (saves battery)")
end

--- Prender el Wi-Fi sin dibujar nada y sin frenar la lectura.
--
-- Es el camino con el que KOReader restaura el Wi-Fi al despertar: un script
-- que conecta en segundo plano con las redes que el lector ya recuerda, y una
-- consulta periodica que avisa con NetworkConnected cuando hay red. No muestra
-- ningun cartel y, a diferencia de `enableWifi`, no deja la pantalla sin
-- responder mientras busca redes. Si no conecta lo dice una vez, con un aviso
-- que se va solo, y no se pierde nada: lo pendiente sigue en la cola.
-- @return boolean false cuando este lector no tiene ese camino
function HighlightsDeToto:_connectSilently(callback, valid)
    if not Device:hasWifiRestore() or type(NetworkMgr.restoreWifiAsync) ~= "function"
        or type(NetworkMgr.scheduleConnectivityCheck) ~= "function" then
        return false
    end
    -- Otra conexion ya esta en curso (la persona, KOReader): su aviso de red
    -- conectada sigue el camino de siempre.
    if NetworkMgr.pending_connection or NetworkMgr.pending_connectivity_check then return true end
    logger.info("Borges: connecting Wi-Fi in the background to sync")
    local quiet = { owner = self, valid = valid, callback = callback }
    Shared.wifi_quiet, Shared.wifi_quiet_failed = quiet, false
    local ok = pcall(function()
        NetworkMgr:restoreWifiAsync()
        NetworkMgr:scheduleConnectivityCheck()
    end)
    if not ok then
        Shared.wifi_quiet = nil
        return false
    end
    local waited = 0
    local function observe()
        if Shared.wifi_quiet ~= quiet then return end -- conecto, o la persona tomo la red
        waited = waited + QUIET_CONNECT_POLL
        -- KOReader todavia esta intentando: no se da por perdida antes que el.
        if (NetworkMgr.pending_connectivity_check or NetworkMgr.pending_connection)
            and waited < QUIET_CONNECT_TIMEOUT then
            UIManager:scheduleIn(QUIET_CONNECT_POLL, observe)
            return
        end
        Shared.wifi_quiet = nil
        if NetworkMgr:isConnected() then return end
        Shared.wifi_quiet_failed = true
        logger.info("Borges: background Wi-Fi connection did not complete; pending work stays queued")
        -- Conectar sin carteles no es fallar sin avisar: es el unico aviso de
        -- este camino, y solo si la persona sigue leyendo el mismo libro.
        if quiet.valid() then
            self:showInfo(_("Could not connect to Wi-Fi. You can keep reading and sync from the menu."), 6)
        end
    end
    UIManager:scheduleIn(QUIET_CONNECT_POLL, observe)
    return true
end

--- Conectar en silencio fallo al despertar y el camino comun anduvo al dormir,
-- en el mismo lugar: este lector no recuerda esa red por su cuenta (esta
-- guardada solo en KOReader). Despues de dos sesiones asi la opcion se apaga
-- sola, y el menu dice por que: seguir en silencio seria dejar de consultar la
-- ultima lectura sin que nadie se entere.
function HighlightsDeToto:_noteQuietMiss()
    self.wifi_quiet_misses = (self.wifi_quiet_misses or 0) + 1
    if self.wifi_quiet_misses >= QUIET_MISS_LIMIT then
        logger.warn("Borges: this reader cannot connect on its own; turning off Wi-Fi only to sync")
        self.wifi_only_to_sync = false
        self.wifi_only_to_sync_note = "silent_unavailable"
        Shared.wifi_owned, Shared.wifi_auto_closed = false, false
    end
    self:saveSyncState(true)
end

--- El Wi-Fi que esta prendido lo prendio el plugin para sincronizar.
function HighlightsDeToto:_ownWifi()
    Shared.wifi_owned, Shared.wifi_auto_closed = true, false
    self:_scheduleWifiOff(WIFI_OFF_DELAY)
end

--- La persona esta usando la red para algo que pidio: el Wi-Fi ya no es del
-- plugin y no lo va a apagar.
function HighlightsDeToto:_keepWifi()
    Shared.wifi_owned, Shared.wifi_quiet = false, nil
    if self._wifi_off_task then
        UIManager:unschedule(self._wifi_off_task)
        self._wifi_off_task = nil
    end
end

function HighlightsDeToto:_scheduleWifiOff(delay, tries)
    if not Shared.wifi_owned or not self:_wifiOnlyToSyncActive() then return end
    if self._wifi_off_task then UIManager:unschedule(self._wifi_off_task) end
    self._wifi_off_task = function()
        self._wifi_off_task = nil
        self:_closeOwnedWifi(tries or 0)
    end
    UIManager:scheduleIn(delay, self._wifi_off_task)
end

--- Mientras algo de esto siga en curso, el Wi-Fi hace falta.
function HighlightsDeToto:_wifiStillNeeded()
    if self._background_sync and self._background_sync:isRunning() then return true end
    if self._background_pending and next(self._background_pending) then return true end
    if self._connect_sync_running or self._plugin_update_check_running then return true end
    if self.sync_run and self.sync_run.running then return true end
    if self.pairing_state or (self._reading_wifi and self._reading_wifi.active) then return true end
    if self.resume_flow and self.resume_flow:isVisible() then return true end
    if self._reading_head and self._reading_head.ask then return true end
    if self.device_token and self.queue:sendableCount() > 0 then return true end
    return false
end

function HighlightsDeToto:_closeOwnedWifi(tries)
    if self._closed or self._background_suspended then return end
    if not Shared.wifi_owned or not self:_wifiOnlyToSyncActive() then return end
    if not NetworkMgr:isWifiOn() then
        Shared.wifi_owned = false
        return
    end
    if self:_wifiStillNeeded() then
        if tries < WIFI_OFF_MAX_TRIES then
            return self:_scheduleWifiOff(WIFI_OFF_RETRY, tries + 1)
        end
        -- Algo sigue esperando (una pregunta sin responder, un envio que no
        -- sale): por esta vez el Wi-Fi queda como esta.
        logger.info("Borges: Wi-Fi left on, sync still has work pending")
        Shared.wifi_owned = false
        return
    end
    logger.info("Borges: sync finished, turning off the Wi-Fi it had turned on")
    Shared.wifi_owned = false
    Shared.wifi_closing = true
    local ok = pcall(NetworkMgr.disableWifi, NetworkMgr)
    Shared.wifi_closing = false
    Shared.wifi_auto_closed = ok
end

--- Al suspender con el Wi-Fi que el plugin apago: prenderlo para UN envio.
-- Si conectar no llega a tiempo KOReader lo mata al dormir y todo queda en la
-- cola, igual que hoy cuando no hay red al suspender. El envio es el mismo
-- intercambio acotado de dormir (`_drainQueueBlocking`, `SleepBudget`): su
-- tope de 8 s queda por debajo de la ventana de SLEEP_UPLOAD_WINDOW.
function HighlightsDeToto:_uploadBeforeSleep()
    -- El explorador detras de un libro abierto no toca las marcas compartidas:
    -- si las consumiera, prenderia el Wi-Fi para un drenaje que le deja el
    -- intercambio al libro, y el libro ya no las encontraria (0 pedidos).
    if self:_leavesSleepToOpenBook() then return end
    -- Tambien cuando la conexion silenciosa del despertar no llego a conectar:
    -- lo leido en esta sesion sube igual, por el camino que prueba todas las
    -- redes guardadas.
    local closed_here = Shared.wifi_auto_closed
    local quiet_failed = Shared.wifi_quiet_failed
    Shared.wifi_auto_closed, Shared.wifi_quiet_failed, Shared.wifi_quiet = false, false, nil
    if not (closed_here or quiet_failed) or not self:_wifiOnlyToSyncActive() or not self.device_token then return end
    if NetworkMgr:isWifiOn() then return end
    -- Una posicion retenida cuenta: es justo lo que este envio tiene que
    -- poder soltar (ver `_resolveHeldProgress`, que corre en el drenaje).
    -- Tambien la de un libro ya cerrado.
    local held = #self.queue:heldProgressIdentifiers() > 0
    if self.queue:sendableCount() == 0 and not held then return end

    logger.info("Borges: turning Wi-Fi on to upload this reading before sleep")
    Shared.wifi_edge = true
    -- El protector de pantalla ya esta puesto: los carteles de KOReader al
    -- conectar quedarian dibujados sobre el.
    local ok, status = pcall(withoutNetworkNotices, function()
      return NetworkMgr:enableWifi(function()
        if not Shared.wifi_edge then return end -- la persona desperto el lector, o KOReader ya corto
        Shared.wifi_edge = false
        if not self._background_suspended or self._closed then return end
        if quiet_failed then self:_noteQuietMiss() end
        self:_safecall("sleepUpload", function() self:_drainQueueBlocking(true) end)
        Shared.wifi_closing = true
        pcall(NetworkMgr.disableWifi, NetworkMgr)
        Shared.wifi_closing = false
        -- Listo: no hace falta esperar el resto de la ventana para dormir.
        if self._background_suspended and Device.screen_saver_mode == true then
            pcall(Device.rescheduleSuspend, Device, 2)
        end
      end)
    end)
    if not ok or status == false then
        Shared.wifi_edge = false
        return
    end
    -- Este manejador corre ANTES de que KOReader agende su espera de 15 s, asi
    -- que la ventana se alarga en el tick siguiente.
    UIManager:nextTick(function()
        if Shared.wifi_edge and self._background_suspended and Device.screen_saver_mode == true then
            pcall(Device.rescheduleSuspend, Device, SLEEP_UPLOAD_WINDOW)
        end
    end)
end

--- Red de seguridad general (12 nov 2026). Una posicion retenida solo se
-- suelta con la consulta de la ultima lectura, y esa consulta dependia de que
-- un despertar, una apertura o una conexion la hiciera justo bien: una falla
-- transitoria, una reconexion dentro del debounce, una conexion que llego
-- despues del timeout, un libro cerrado o el Wi-Fi prendido a mano al dormir
-- la dejaban retenida para siempre. Ahora todo envio pregunta antes por cada
-- libro retenido, el abierto o uno cerrado. La regla no cambia: la consulta
-- decide, y una lectura mas nueva en otro aparato la mantiene retenida.
-- `force` saltea el intervalo: al dormir o al cortarse el Wi-Fi es la ultima
-- oportunidad.
-- `max_books` acota las consultas (al dormir, una: `SleepBudget.FOCUS_CHECKS`)
-- y el libro abierto va primero. `quick` viaja a la red (`"sleep"` pide los
-- plazos de dormir). Devuelve cuantas se hicieron y si alguna fallo por red.
function HighlightsDeToto:_resolveHeldProgress(force, max_books, quick)
    if not self.device_token or not self.sync_v2 or not self.queue then return 0, false end
    if not NetworkMgr:isConnected() then return 0, false end
    -- Otra consulta de la ultima lectura esta en vuelo: su resultado decide.
    -- Con vencimiento: una corrutina cancelada a mitad de pedido no baja el
    -- contador, y eso no puede apagar esta red de seguridad para siempre.
    if (self.sync_v2.focus_in_flight or 0) > 0
        and os.time() - (self.sync_v2.focus_started_at or 0) < HELD_CHECK_INTERVAL * 2 then
        return 0, false
    end
    local held = self.queue:heldProgressIdentifiers()
    if #held == 0 then return 0, false end
    max_books = tonumber(max_books) or HELD_CHECK_MAX_BOOKS
    if quick == nil then quick = true end
    -- El libro abierto primero: es el que la persona va a retomar.
    -- Abierto es el MISMO libro: con clave, la clave; una retencion de antes
    -- de la clave (sin ella) se reconoce por el hash, como siempre.
    local function isOpen(identifier)
        if identifier.value ~= self.book_hash then return false end
        return identifier.book_key == nil or self.book_key == nil or identifier.book_key == self.book_key
    end
    local ordered = {}
    for _, identifier in ipairs(held) do
        if isOpen(identifier) then table.insert(ordered, 1, identifier)
        else table.insert(ordered, identifier) end
    end
    held = ordered
    local now = os.time()
    self._held_checked_at = self._held_checked_at or {}
    local checked, failed = 0, false
    for _, identifier in ipairs(held) do
        -- Sin red la proxima consulta tambien va a fallar: no se la espera.
        if checked >= max_books or failed then break end
        local key = identifier.book_key or (identifier.kind .. ":" .. tostring(identifier.value))
        local last = self._held_checked_at[key]
        local open = isOpen(identifier)
        -- Con una eleccion en pantalla, o la consulta de conexion en curso, el
        -- libro abierto ya esta preguntando: otra consulta la invalidaria.
        local busy = open and ((self._reading_head and self._reading_head.ask) or self._connect_sync_running)
        if not busy and (force or not last or now - last >= HELD_CHECK_INTERVAL) then
            self._held_checked_at[key] = now
            checked = checked + 1
            local context = not open and { book_hash = identifier.value, token = self.device_token,
                epoch = self._background_epoch, closed = true,
                book_key = identifier.book_key, hint = identifier.hint } or nil
            -- Al servidor viaja el identificador de siempre, sin lo local.
            local focus = { kind = identifier.kind, value = identifier.value }
            local ok, err = self.sync_v2:pull(quick, focus, true, context)
            if not ok then
                logger.warn("Borges: last reading not confirmed, position stays held:", tostring(err))
                if type(err) == "table" and err.code == "connection_failed" then failed = true end
            end
        end
    end
    -- Dormido no se pregunta nada: la eleccion pendiente espera al despertar.
    if checked > 0 and self._background_suspended then self:_clearReadingHead() end
    return checked, failed
end

--- Called when a book is opened and ready to read.
function HighlightsDeToto:onReaderReady()
    if not self:isWebConfigured() then return end

    UIManager:nextTick(function()
        local ok, err = pcall(function()
            -- Read book identity
            self.book_hash = self.ui.doc_settings:readSetting("partial_md5_checksum")
            if not self.book_hash then
                logger.warn("Borges: No partial_md5_checksum, progress sync disabled for this book")
                return
            end
            self.book_hash = tostring(self.book_hash):lower()

            -- Read book metadata
            local props = self.ui.document:getProps()
            self.book_title = props.title or ""
            self.book_author = props.authors or props.author or ""
            -- ISBN / UUID que trae el archivo: una vez por apertura.
            self.book_identifiers = type(props.identifiers) == "string" and props.identifiers or nil
            self._book_language = props.language
            self.total_pages = self.ui.document:getPageCount()
            -- ReaderAnnotation decides compatibility with ui.paging/ui.rolling.
            -- Keep has_pages aligned with that, falling back to document.info for older builds.
            if self.ui.paging ~= nil then
                self.has_pages = true
            elseif self.ui.rolling ~= nil then
                self.has_pages = false
            else
                self.has_pages = self.ui.document.info.has_pages
            end

            -- Save full file path for highlight sync (HighlightParser needs it)
            self.book_file_path = self.ui.document.file or ""
            -- Extract book filename for display/fallback
            self.book_filename = self.book_file_path:match("([^/\\]+)$") or ""
            -- F5 · La clave local del libro (hash + archivo + titulo) y la
            -- mudanza de lo guardado por hash: una vez por apertura, en memoria;
            -- sale con el proximo guardado de la cola.
            self.book_key = BookKey.forDocument(self.ui)
            self:_safecall("bookKeyMigrate", function() self:_adoptBookKeyState() end)
            -- F2 · antes del primer tramo: el que abre F1 sale con causa "open".
            if self._attentionInstall then
                local installed, install_err = pcall(self._attentionInstall, self)
                if not installed then logger.warn("Borges: attentionInstall error:", install_err) end
            end
            -- La posicion de partida se lee UNA vez y la usa tambien el primer
            -- tramo de F1 (antes eran dos lecturas de crengine al abrir).
            self._last_handled_page = self.ui:getCurrentPage()
            self._last_handled_xpointer = self._getXPointer and self:_getXPointer()
            self._last_handled_page_at = os.time()
            if self._startReadingLog then
                local started, start_err = pcall(self._startReadingLog, self, self._last_handled_xpointer)
                if not started then logger.warn("Borges: readingLogStart error:", start_err) end
            end
            self._annotation_pull_backed_up = false
            self._locator_cache, self._locator_error_logged = nil, nil
            local activity = self.ui.doc_settings:readSetting("toto_reading_activity")
            self._reading_activity_at = type(activity) == "table"
                and activity.device_id == (self.paired_device_id or self.device_id) and activity.occurred_at or nil
            self._reading_activity_device = self.paired_device_id or self.device_id
            self.last_progress_change = 0
            self._last_enqueued_progress = self._reading_activity_at and activity.enqueued or nil
            local reading_baseline = self:_captureReadingBaseline()
            self:_beginReadingHandoff()

            -- Start reading session
            self._reading_wifi_cancelled = false
            self.session:start(self.book_hash, self.device_id, self.ui:getCurrentPage())
            if not NetworkMgr:isConnected() then
                self:_safecall("sanitizeAnnotations", function() self:_sanitizeLocalAnnotations() end)
                self:_runBackgroundSync("inbox", function() self:_applyInboxForCurrentBook() end)
            end

            -- Ask for the connection only when needed. Once connected, fetch
            -- progress in the background with no overlay on the reading page.
            self.pull_done = false
            UIManager:nextTick(function()
                local function doSync()
                    self.pull_done = true
                    self:_runConnectedSync("book_open", { force = true, reading_baseline = reading_baseline })
                end
                self:_ensureReadingConnection(doSync)
            end)
        end)
        if not ok then
            logger.warn("Borges: onReaderReady error:", err)
        end
    end)
end

--- Called when the book is being closed.
-- Persist before the reader is destroyed; the existing background drain sends
-- it afterwards. Opening another book must not wait on three HTTP exchanges.
function HighlightsDeToto:onCloseDocument()
    self:_cancelBackgroundSync()
    UIManager:unschedule(self.periodic_push_task)
    UIManager:unschedule(self.highlight_push_task)

    if not self.book_hash then return end

    -- 0. F1 · el ultimo tramo termina mientras el documento sigue disponible.
    if self._sampleDeviceState then self:_sampleDeviceState("close") end
    if self.reading_log then
        local close_fields = self._attention and self:_attentionCloseFields(nil, "close") or nil
        self:_safecall("readingClose", function() self.reading_log:close(close_fields) end)
    end

    -- 1. Capture final progress while this document is still available.
    -- Posicion, sesion, estadisticas y subrayados se guardan juntos al final,
    -- en una escritura de la cola.
    self:_safecall("pushProgress", function() self:_enqueueProgressV2(false, true) end)
    -- F6: el texto de la pantalla no sobrevive al libro cerrado.
    self._locator_cache = nil

    -- 2. Finish session and ENQUEUE (payload is tiny ~200B, drain will send it)
    self:_safecall("session", function()
        for _, session_data in ipairs(self.session:finishAll()) do
            self:_enqueueSessionV2(session_data, true)
        end
    end)

    -- 3. KOReader acaba de guardar el sidecar (lo hace antes de avisar que
    -- cierra): aca solo se dejan las anotaciones listas para comparar.
    self:_safecall("prepareAnnotations", function() self:_flushSidecar() end)

    -- F1 · los tramos entran antes de las estadisticas: syncPageStatsDelta guarda la
    -- cola si encolo filas, y asi ese mismo guardado los lleva (ninguna escritura nueva).
    if self.reading_log then self:_safecall("readingSpans", function() self:_enqueueReadingSpans(true) end) end
    -- F2 · las condiciones del libro que se cierra, en esta misma escritura.
    if self._enqueueDeviceStates then self:_safecall("deviceStates", function() self:_enqueueDeviceStates() end) end
    -- El indice del libro, si cambio desde la ultima vez (tiempo por capitulo).
    if self._enqueueChapterToc then self:_safecall("chapterToc", function() self:_enqueueChapterToc() end) end
    -- 4. Persist the statistics delta for the same background drain.
    self:_safecall("statsSync", function()
        self:syncPageStatsDelta(true)
    end)

    -- 5. Persist the annotation delta without waiting on the network.
    self:_safecall("highlightSync", function()
        self:syncHighlightsDelta(true)
    end)
    self:_safecall("closeSave", function() self.queue:flush() end)

    -- Clean up
    -- C17 · Un diálogo que se cierra junto con el libro no puede dejar la
    -- compuerta trabada: el próximo libro no mostraría nada.
    if self.resume_flow then self.resume_flow:clearVisible() end
    self.book_hash = nil
    self.book_key = nil
    self.book_file_path = nil
    self.has_pages = nil
    self._annotation_pull_backed_up = nil
    self._sidecar_dirty = nil
    self._annotations_modified = nil
    self._last_handled_page = nil
    self._last_handled_xpointer = nil
    self._last_handled_page_at = nil
    self.reading_log = nil
    if self._unregisterFooterTimeLeft then pcall(self._unregisterFooterTimeLeft, self) end
    self._server_pace = nil

    -- 6. Send the durable work after returning control to the reader. Para
    -- entonces esta instancia ya no existe: lo manda la que la reemplazo, que
    -- comparte la cola.
    UIManager:scheduleIn(2, function()
        local plugin = Shared.live
        if plugin then plugin:_safecall("queueDrain", function() plugin:_drainQueue() end) end
    end)

    -- C23 · Cerrar el libro devuelve al explorador: ahí el aviso de versión
    -- nueva no tapa nada. Es el momento que reemplaza al cartel que antes
    -- podía salir en medio de una página.
    UIManager:scheduleIn(3, function()
        local plugin = Shared.live
        if not plugin then return end
        plugin:_safecall("updateNoticeOnClose", function()
            plugin:_announcePluginUpdate("close_document")
        end)
    end)
end

--- Called when user navigates to a new page (paged view, and page turns in
-- crengine's page mode).
function HighlightsDeToto:onPageUpdate(pageno)
    self:_noteScreenMoved("page", nil, pageno)
end

--- Vista continua: KOReader avisa `PosUpdate(pos, page)` al desplazarse, no
-- `PageUpdate`. Sin esto, leer en vista continua no movia la posicion.
function HighlightsDeToto:onPosUpdate(pos, page)
    self:_noteScreenMoved("pos", pos, page)
end

--- CAMINO CALIENTE: corre en cada paso de pagina o desplazamiento. Solo anota
-- en memoria y difiere el trabajo con `tickAfterNext` (una tarea pendiente a
-- la vez, sin reloj). Prohibido aca: disco, red, temporizadores, widgets y
-- crengine. Otros registros de lectura en memoria se cuelgan de esta funcion.
function HighlightsDeToto:_noteScreenMoved(kind, pos, page)
    if not self.book_hash or self._closed then return end
    local pending = self._screen_move ~= nil
    self._screen_move = { kind = kind, pos = pos, page = page }
    if not pending and self._screen_move_task then
        UIManager:tickAfterNext(self._screen_move_task)
    end
    -- F1 · lectura en palabras: solo el instante (reloj ya leido en este tick).
    if self.reading_log then
        local ok, at = pcall(self._readingClockMs, self)
        if ok then self._reading_move_at = at end
    end
    -- F2 · la marca del gesto existe solo mientras corre la llamada que movio la
    -- pantalla (este aviso es sincronico): se lee aca, en memoria. Ni disco ni
    -- reloj nuevo: getTime y el standby ya estan leidos en este tick.
    if self._nav or self._attention then pcall(self._attentionNoteMove, self, self._screen_move) end
end

-- ============================================================
-- F1 · Lectura medida en palabras
-- ============================================================
-- Cada pantalla a la vista es un tramo del registro en memoria (readinglog.lua):
-- donde empieza, cuando aparecio y cuanto estuvo. El aviso de pagina solo toma
-- el instante; el XPointer, el fin, el porcentaje y las palabras se resuelven
-- en la tarea diferida (tickAfterNext, despues del pintado). Nada de esto
-- escribe en disco: los tramos salen a la cola en las escrituras de siempre.

--- Reloj de lectura en ms: el monotonico de UIManager (ya leido en este tick)
-- mas el tiempo en standby. En Kobo CLOCK_MONOTONIC no avanza en standby y
-- una pagina de tres minutos con el procesador dormido mediria segundos. La
-- suspension no entra: suspender cierra el tramo.
function HighlightsDeToto:_readingClockMs()
    -- `time.now()` (CLOCK_MONOTONIC_COARSE) y no `UIManager:getTime()`: ese es
    -- `_now`, que UIManager refresca ANTES de esperar la entrada, así que dentro
    -- de un toque es la hora del evento anterior y el tiempo de cada pantalla
    -- caía en la siguiente. Es una lectura de reloj por FFI, sin E/S. Como
    -- getTime, no avanza con el aparato suspendido (Linux) ni en el standby del
    -- Kobo; el standby se suma aparte y la suspensión cierra el tramo.
    local now
    if UITime and type(UITime.now) == "function" then
        local ok, value = pcall(UITime.now)
        if ok then now = value end
    end
    if type(now) ~= "number" then now = UIManager.getTime and UIManager:getTime() end
    local standby = Device.total_standby_time
    if type(standby) ~= "number" then standby = 0 end
    if UITime and type(UITime.to_ms) == "function" and type(now) == "number" then
        return UITime.to_ms(now + standby)
    end
    return os.time() * 1000
end

--- Hora de pared en ms, anclada al reloj de lectura: sin llamadas al sistema.
function HighlightsDeToto:_readingWallMs(mono_ms)
    mono_ms = mono_ms or self:_readingClockMs()
    if not self._wall_anchor_ms or not self._mono_anchor_ms then self:_anchorReadingClock() end
    return self._wall_anchor_ms + (mono_ms - self._mono_anchor_ms)
end

function HighlightsDeToto:_anchorReadingClock()
    self._mono_anchor_ms = self:_readingClockMs()
    local wall
    if UITime and type(UITime.realtime) == "function" and type(UITime.to_ms) == "function" then
        local ok, value = pcall(UITime.realtime)
        if ok and type(value) == "number" then wall = UITime.to_ms(value) end
    end
    self._wall_anchor_ms = wall or os.time() * 1000
end

function HighlightsDeToto:isReadingSpansEnabled()
    return self.reading_spans_enabled ~= false
end

function HighlightsDeToto:_readingViewMode()
    if self.has_pages then return "paging" end
    local view = self.ui and self.ui.view
    if type(view) == "table" and view.view_mode == "scroll" then return "scroll" end
    return "page"
end

function HighlightsDeToto:_readVisiblePages()
    local document = self.ui and self.ui.document
    if type(document) == "table" and type(document.getVisiblePageNumberCount) == "function" then
        local ok, value = pcall(document.getVisiblePageNumberCount, document)
        if ok and type(value) == "number" and value >= 1 then return value end
    end
    return 1
end

--- Un registro por libro abierto, en la instancia (la cola sigue en Shared).
-- `xpointer`: la posicion que la apertura acaba de leer (si la hay), para no
-- volver a preguntarle a crengine.
function HighlightsDeToto:_startReadingLog(xpointer)
    self.reading_log = nil
    if not self.book_hash then return end
    -- El ritmo que mando el servidor la ultima vez sirve sin red.
    local saved = self.ui and self.ui.doc_settings and self.ui.doc_settings:readSetting("borges_reading_pace")
    if type(saved) == "table" then self._server_pace = { book = saved.book, account = saved.account } end
    self:_registerFooterTimeLeft()
    if not self:isReadingSpansEnabled() then return end
    self:_anchorReadingClock()
    self.reading_log = ReadingLog:new{
        clock_ms = function() return self:_readingClockMs() end,
        wall_ms = function() return self:_readingWallMs() end,
    }
    self._visible_pages = self:_readVisiblePages()
    self:_recordReadingScreen(nil, { force = true, defer_resolve = true, xpointer = xpointer })
end

--- Registrar la pantalla actual. `move` es lo que anoto el aviso de pagina
-- (nil al abrir, despertar o re-renderizar, que van con `force`).
function HighlightsDeToto:_recordReadingScreen(move, opts)
    opts = opts or {}
    local log = self.reading_log
    if not log or not self.book_hash or self._closed or not self:isReadingSpansEnabled() then return end
    local previous = log.open
    local view_mode = self:_readingViewMode()
    -- En vista paginada _gotoPercent tambien emite PosUpdate: PageUpdate ya lo cubre.
    if move and move.kind == "pos" and view_mode == "page" then return end
    local at = self._reading_move_at or self:_readingClockMs()
    self._reading_move_at = nil
    local xp_start
    if view_mode ~= "paging" then
        if move then xp_start = self._last_handled_xpointer end
        xp_start = xp_start or opts.xpointer or self:_getXPointer()
    end
    local page = move and move.page
    if page == nil and self.ui and self.ui.getCurrentPage then page = self.ui:getCurrentPage() end
    local span = log:onScreen({
        xp_start = xp_start, page = page, page_count = self.total_pages,
        visible_pages = self._visible_pages or 1, view_mode = view_mode,
    }, { force = opts.force, now_ms = at, wall_ms = self:_readingWallMs(at),
        close_fields = self._attention and self._attentionCloseFields and self:_attentionCloseFields(move, "screen") or nil })
    if not span then return end
    -- F2 · solo si de verdad aparecio una pantalla nueva.
    if span ~= previous and self._attentionOpened then self:_attentionOpened(move, view_mode) end
    if opts.defer_resolve then
        self:_scheduleReadingResolve()
    else
        self:_resolveReadingSpans(2)
    end
end

--- Una sola resolucion pendiente a la vez, despues del pintado. tickAfterNext
-- no deja ningun temporizador vivo.
function HighlightsDeToto:_scheduleReadingResolve()
    if self._reading_resolve_pending then return end
    self._reading_resolve_pending = true
    local log = self.reading_log
    UIManager:tickAfterNext(function()
        self._reading_resolve_pending = nil
        if self._closed or self.reading_log ~= log then return end
        self:_safecall("readingResolve", function() self:_resolveReadingSpans(2) end)
    end)
end

function HighlightsDeToto:_readingTocIndex(page)
    local toc = self.ui and self.ui.toc
    if not page or type(toc) ~= "table" or type(toc.getTocIndexByPage) ~= "function" then return nil end
    local ok, index = pcall(toc.getTocIndexByPage, toc, page)
    if ok and type(index) == "number" and index > 0 then return index end
    return nil
end

--- El XPointer del tramo que siguio a `span`, si la lectura fue seguida.
function HighlightsDeToto:_readingSequentialEnd(log, span)
    for index, candidate in ipairs(log.closed) do
        if candidate == span then
            local nxt = log.closed[index + 1] or log.open
            if nxt and span.view_mode == "page" and nxt.view_mode == "page" and span.page and nxt.page
                and nxt.page == span.page + (span.visible_pages or 1) then
                return nxt.xp_start
            end
            -- Vista continua: lo leído en una posición de reposo es lo que se
            -- desplazó hasta la siguiente (el texto nuevo que entró), no hasta el
            -- corte de página de crengine, que no tiene que ver con el borde de
            -- la pantalla. Sólo hacia adelante; un salto lo frena el tope.
            if nxt and span.view_mode == "scroll" and nxt.view_mode == "scroll" then
                return nxt.xp_start, true
            end
            if not nxt and span.view_mode == "scroll" and index == #log.closed then
                -- La última antes de dormir o cerrar: la pantalla sigue a la vista.
                return nil, false, true
            end
            return nil
        end
    end
    return nil
end

--- Completar fin, porcentaje, capitulo y palabras de los tramos pendientes.
-- Solo se le pide texto a crengine si es seguro (DocText.safe) y solo una vez
-- por par de XPointers (relectura = acierto de cache). Devuelve cuantos conto.
function HighlightsDeToto:_resolveReadingSpans(limit)
    local log = self.reading_log
    if not log or self._closed or not self.ui then return 0 end
    local counted = 0
    local document = self.ui.document
    for _, span in ipairs(log:unresolved(limit or 2)) do
        -- Vista continua: el tramo abierto se resuelve al cerrarse, con la
        -- posicion siguiente (ver _readingSequentialEnd).
        if not (span == log.open and span.view_mode == "scroll") then
            local fields = { toc_index = self:_readingTocIndex(span.page) }
            local ready = true
            if span.view_mode == "paging" then
                local count = span.page_count or self.total_pages
                if span.page and count and count > 0 then
                    fields.percent_start = math.max(0, math.min(1, (span.page - 1) / count))
                    fields.percent_end = math.max(0, math.min(1, (span.page + (span.visible_pages or 1) - 1) / count))
                end
            else
                local xp_end, scrolled, last_in_view
                if span == log.open then
                    local _, bound = DocText.screenBounds(self.ui, span.xp_start)
                    xp_end = bound
                elseif span.xp_end then
                    xp_end = span.xp_end
                else
                    xp_end, scrolled, last_in_view = self:_readingSequentialEnd(log, span)
                    if last_in_view then
                        local _, bound = DocText.screenBounds(self.ui, span.xp_start)
                        xp_end = bound
                    end
                end
                fields.percent_start = DocText.percentOf(document, span.xp_start)
                fields.percent_end = xp_end and DocText.percentOf(document, xp_end) or nil
                if scrolled and not (fields.percent_end and fields.percent_start
                    and fields.percent_end > fields.percent_start) then
                    -- Desplazarse hacia atrás no muestra texto nuevo.
                    xp_end, fields.percent_end = nil, nil
                end
                fields.xp_end = xp_end
                if span.xp_start and xp_end then
                    local words, chars = log:cachedCount(span.xp_start, xp_end)
                    if words == nil then
                        if DocText.safe(self.ui) then
                            local text = DocText.between(document, span.xp_start, xp_end)
                            if text then
                                words, chars = DocText.countWords(text)
                                log:rememberCount(span.xp_start, xp_end, words, chars)
                                counted = counted + 1
                            end
                        else
                            -- Seleccion, diccionario o busqueda abiertos: se cuenta despues.
                            ready = false
                        end
                    end
                    if scrolled and words and words > ReadingLog.SCROLL_JUMP_WORDS then
                        -- Más de lo que entra en unas pantallas: fue un salto, no lectura.
                        fields.xp_end, fields.percent_end, words, chars = nil, nil, nil, nil
                    end
                    fields.words, fields.chars = words, chars
                end
            end
            if ready then log:resolve(span, fields) end
        end
    end
    return counted
end

-- ============================================================
-- F2 · Causa de cada pantalla, pausas y condiciones de lectura
-- ============================================================
-- Cada tramo de F1 lleva por que aparecio (`cause`: pasar pagina, indice,
-- busqueda, volver...), hasta el ultimo toque (`active_ms`) y como termino
-- (`ended_by`). Es una cota de presencia, NO atencion: lo plausible lo decide
-- el servidor. Ademas, cada tanto, las condiciones de lectura (bateria, luz,
-- letra) en `device_state.recorded`.
--
-- Camino caliente: los envoltorios de navcause.lua solo asignan campos; el
-- aviso de pagina copia la marca y un numero que UIManager ya tiene. Nada de
-- disco, red, temporizadores ni crengine. Lo capturado sale en las mismas
-- escrituras de la cola que F1 (guardar ajustes, dormir, cerrar el libro).

local DEVICE_STATE_EVENT_BYTES = 28 * 1024
local DEVICE_STATE_EVENT_ROWS = 100

function HighlightsDeToto:isNavCauseEnabled() return self.capture_nav_cause ~= false end
function HighlightsDeToto:isAttentionEnabled() return self.capture_attention ~= false end
function HighlightsDeToto:isDeviceStateEnabled() return self.capture_device_state ~= false end

function HighlightsDeToto:_attentionDeps()
    return { UIManager = UIManager, Device = Device, time = UITime }
end

--- El mismo reloj que los tramos (_readingClockMs): time.now() en el momento
-- mas el standby, en fts. Asi active_ms nunca puede pasar a dwell_ms.
function HighlightsDeToto:_attentionNow()
    return Attention.clock(self:_attentionDeps())
end

--- En onReaderReady, ANTES de que F1 abra el primer tramo.
function HighlightsDeToto:_attentionInstall()
    if self._nav then self._nav:close() end
    self._nav, self._attention, self._pending_cause = nil, nil, nil
    if not self.book_hash or not self.ui then return end
    if self:isNavCauseEnabled() then
        local nav = NavCause.new(self.ui, function() return UIManager:getTime() end, UIManager)
        local installed, missing = nav:install()
        if missing > 0 then logger.info("Borges: navcause installed", installed, "missing", missing) end
        self._nav = nav
        self._pending_cause = "open"
    end
    if self:isAttentionEnabled() then
        Attention.installProcessHooks(Shared, self:_attentionDeps())
        self._attention = Attention.new(Shared, self:_attentionDeps())
    end
    self:_sampleDeviceState("open")
end

--- CAMINO CALIENTE (desde _noteScreenMoved): la marca del gesto existe solo
-- mientras corre la llamada que movio la pantalla.
function HighlightsDeToto:_attentionNoteMove(move)
    if type(move) ~= "table" then return end
    if self._nav then
        local view = self.ui and self.ui.view
        move.cause = self._nav:take(view and view.view_mode)
    end
    if self._attention then move.att_fts = self:_attentionNow() end
end

--- Lo que se le anota al tramo que cierra (lo usa ReadingLog:onScreen/close).
function HighlightsDeToto:_attentionCloseFields(move, ended_by)
    local att = self._attention
    if not att or not att:isOpen() then return nil end
    local now = move and move.att_fts or self:_attentionNow()
    local ok, measured = pcall(att.measure, att, now, ended_by)
    if not ok or not measured then return nil end
    return { active_ms = measured.active_ms, ended_by = measured.ended_by }
end

--- Al dormir: el motivo (boton, tapa, inactividad) y hasta el ultimo toque.
function HighlightsDeToto:_attentionSleepFields()
    local att = self._attention
    local log = self.reading_log
    if not att or not att:isOpen() or not log or not log.open then return nil end
    local now = self:_attentionNow()
    local autosuspend = self.ui and self.ui.autosuspend
    local timeout = type(autosuspend) == "table" and tonumber(autosuspend.auto_suspend_timeout_seconds) or nil
    local ok, result = pcall(function()
        return att:closeSpan(now, att:sleepReason(now, timeout))
    end)
    if not ok or not result then return nil end
    return { active_ms = result.active_ms, ended_by = result.ended_by }
end

--- Una pantalla nueva: su causa y el comienzo del reloj de toques.
function HighlightsDeToto:_attentionOpened(move, view_mode)
    local cause = self._pending_cause
    self._pending_cause = nil
    if self._nav and self.reading_log then
        if not cause then cause = move and move.cause or self._nav:take(view_mode) end
        self.reading_log:annotate({ cause = cause })
    end
    if self._attention then
        self._attention:openSpan(move and move.att_fts or self:_attentionNow())
    end
end

--- Los saltos del propio plugin (otra lectura, otro lector) son "sync", no un
-- gesto de la persona: F6/F7 los distinguen asi.
function HighlightsDeToto:_syncJump(event)
    if self._nav and self.ui then
        return self._nav:scoped("sync", function() return self.ui:handleEvent(event) end)
    end
    return self.ui:handleEvent(event)
end

function HighlightsDeToto:_deviceStateStore()
    if not Shared.device_state then
        Shared.device_state = DeviceState.new({
            Device = Device, powerd = Device.powerd, G_reader_settings = G_reader_settings,
            Screen = Device.screen, NetworkMgr = NetworkMgr, os = os,
        })
    end
    return Shared.device_state
end

--- Una muestra de condiciones. Solo desde avisos de KOReader y de los momentos
-- en que el plugin ya escribe: nunca al pasar pagina.
function HighlightsDeToto:_sampleDeviceState(trigger)
    if self._closed or not self:isDeviceStateEnabled() then return end
    local ok, err = pcall(function()
        local store = self:_deviceStateStore()
        -- Dormir puede avisarse dos veces (al cortar la red y al suspender).
        local last = store.last
        if trigger == "sleep" and last and last.trigger == "sleep" and last.at_ms
            and os.time() * 1000 - last.at_ms < 60000 then
            return
        end
        local reading = self.book_hash and self.ui and self.ui.document and self.ui or nil
        store:sample(trigger, reading, self.book_hash)
    end)
    if not ok then logger.warn("Borges: deviceState error:", err) end
end

--- Las muestras viajan con los tramos. Si se juntan muchas sin tramos (medir
-- en palabras apagado, un lector que solo duerme y despierta), salen solas en
-- la proxima escritura que ya ocurre, antes de que el tope de 200 las recorte.
local DEVICE_STATE_PILE = 150
function HighlightsDeToto:_deviceStatesPiledUp()
    local store = Shared.device_state
    return store ~= nil and store:count() >= DEVICE_STATE_PILE
end

--- Las muestras a la cola, en grupos de a lo sumo 100 y 28 KB, un evento por
-- libro. Lo llaman los mismos lugares que encolan los tramos de F1: no agrega
-- ninguna escritura. Devuelve cuantos eventos encolo.
function HighlightsDeToto:_enqueueDeviceStates()
    local store = Shared.device_state
    if not store or store:count() == 0 or not self.sync_v2 then return 0 end
    local samples = store:drain()
    if not self:isDeviceStateEnabled() then return 0 end
    local device_id = tostring(self.paired_device_id or self.device_id or "reader")
    local enqueued = 0
    local group, group_book, size = {}, nil, 0
    local function emit()
        if #group == 0 then return end
        local first, last = group[1], group[#group]
        enqueued = enqueued + 1
        self.sync_v2:enqueue({
            event_type = "device_state.recorded",
            aggregate_type = "device_state",
            aggregate_id = "device_state:" .. device_id .. ":" .. string.format("%.0f", first.at_ms or 0)
                .. ":" .. enqueued,
            book_identifier = group_book and self:_bookIdentifier(group_book) or nil,
            occurred_at = os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor((last.at_ms or 0) / 1000)),
            time_precision = "exact",
            payload = { v = 1, samples = group },
        }, { defer = true })
        group, size = {}, 0
    end
    for _, raw in ipairs(samples) do
        local wire = DeviceState.wire(raw)
        local bytes = #rapidjson.encode(wire) + 1
        if raw._book ~= group_book or #group >= DEVICE_STATE_EVENT_ROWS
            or size + bytes > DEVICE_STATE_EVENT_BYTES - 256 then
            emit()
            group_book = raw._book
        end
        table.insert(group, wire)
        size = size + bytes
    end
    emit()
    return enqueued
end

-- Avisos de KOReader que cambian una condicion. Ninguno devuelve true: el
-- aviso sigue su camino.
function HighlightsDeToto:onFrontlightStateChanged() self:_sampleDeviceState("frontlight") end
-- Enchufar llega como entrada falsa: el gancho de toques ya corrio, y no fue
-- la persona tocando la pantalla.
function HighlightsDeToto:onCharging()
    Attention.forgetSystemInput(Shared, self:_attentionDeps())
    self:_sampleDeviceState("charging")
end
function HighlightsDeToto:onNotCharging()
    Attention.forgetSystemInput(Shared, self:_attentionDeps())
    self:_sampleDeviceState("not_charging")
end
function HighlightsDeToto:onSetRotationMode() self:_sampleDeviceState("rotation") end
function HighlightsDeToto:onToggleNightMode() self:_sampleDeviceState("night_mode") end
function HighlightsDeToto:onSetNightMode() self:_sampleDeviceState("night_mode") end

function HighlightsDeToto:toggleNavCause()
    self.capture_nav_cause = not self:isNavCauseEnabled()
    if not self.capture_nav_cause then
        if self._nav then self._nav:close() end
        self._nav = nil
    elseif self.book_hash and not self._nav and self.ui then
        self._nav = NavCause.new(self.ui, function() return UIManager:getTime() end, UIManager)
        self._nav:install()
    end
    self:saveSyncState()
end

function HighlightsDeToto:toggleAttentionCapture()
    self.capture_attention = not self:isAttentionEnabled()
    if not self.capture_attention then
        self._attention = nil
    elseif self.book_hash and not self._attention then
        Attention.installProcessHooks(Shared, self:_attentionDeps())
        self._attention = Attention.new(Shared, self:_attentionDeps())
    end
    self:saveSyncState()
end

function HighlightsDeToto:toggleDeviceStateCapture()
    self.capture_device_state = not self:isDeviceStateEnabled()
    -- Apagar no manda nada mas: lo que estaba en memoria se descarta.
    if not self.capture_device_state and Shared.device_state then Shared.device_state:drain() end
    self:saveSyncState()
end

function HighlightsDeToto:toggleReadingSpans()
    self.reading_spans_enabled = not self:isReadingSpansEnabled()
    if self.reading_spans_enabled then
        if self.book_hash and not self.reading_log then self:_startReadingLog() end
    else
        -- Apagar no manda nada mas: lo que estaba en memoria se descarta.
        self.reading_log = nil
    end
    self:saveSyncState()
end

-- ------------------------------------------------------------
-- F1 · Tiempo restante en la barra de estado de KOReader
-- ------------------------------------------------------------
-- Es un item de «Contenido externo» (ReaderFooter:addAdditionalFooterContent):
-- KOReader lo llama en cada refresco del pie, o sea en cada pagina. Por eso
-- es solo aritmetica sobre numeros ya en memoria, mas getChapterPagesLeft, que
-- es lo mismo que KOReader pide para su propio tiempo del capitulo.

function HighlightsDeToto:isFooterTimeLeftEnabled()
    return self.footer_time_left ~= false
end

--- Velocidad para estimar: la del servidor para este libro si ya tiene
-- suficiente; si no, la de esta lectura; si no, la de toda la cuenta.
function HighlightsDeToto:_readingPaceWpm()
    local server = type(self._server_pace) == "table" and self._server_pace or {}
    local book = type(server.book) == "table" and server.book or nil
    if book and tonumber(book.wpm) and (tonumber(book.words) or 0) >= ReadingLog.MIN_BOOK_PACE_WORDS then
        return tonumber(book.wpm)
    end
    local log = self.reading_log
    if log then
        local pace = log:pace()
        if pace.words >= ReadingLog.MIN_BOOK_PACE_WORDS and pace.ms > 0 then
            return pace.words * 60000 / pace.ms
        end
    end
    local account = type(server.account) == "table" and server.account or nil
    if account and tonumber(account.wpm) and tonumber(account.wpm) > 0 then return tonumber(account.wpm) end
    return nil
end

--- Donde esta la persona (0..1), sin pedirle nada a crengine.
function HighlightsDeToto:_readingPosition(page)
    local open = self.reading_log and self.reading_log.open
    if open and type(open.percent_start) == "number" and (open.page == nil or open.page == page) then
        return open.percent_start
    end
    if page and self.total_pages and self.total_pages > 0 then
        return math.max(0, math.min(1, (page - 1) / self.total_pages))
    end
    return nil
end

--- Palabras que faltan: con el total del EPUB si el servidor lo tiene; si no,
-- con la densidad de lo ya leido en este libro (al menos el 5 % cubierto).
function HighlightsDeToto:_readingWordsLeft(position)
    local server = type(self._server_pace) == "table" and self._server_pace or {}
    local total = type(server.book) == "table" and tonumber(server.book.words_total) or nil
    if total and total > 0 then return total * (1 - position) end
    local log = self.reading_log
    if not log then return nil end
    local density, covered = log:density()
    if density and covered >= 0.05 then return density * (1 - position) end
    return nil
end

local function clockDuration(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    local format = G_reader_settings and G_reader_settings.readSetting
        and G_reader_settings:readSetting("duration_format", "classic") or "classic"
    if datetime and type(datetime.secondsToClockDuration) == "function" then
        return datetime.secondsToClockDuration(format, seconds, true)
    end
    local minutes = math.floor(seconds / 60 + 0.5)
    return string.format("%d:%02d", math.floor(minutes / 60), minutes % 60)
end
HighlightsDeToto._clockDuration = clockDuration

--- «3:00 left · chapter 0:02», o solo el libro si no hay capitulo. nil si
-- todavia no hay con que estimar.
function HighlightsDeToto:_readingTimeLeftText()
    if not self.book_hash or self._closed or not self:isFooterTimeLeftEnabled() then return nil end
    local wpm = self:_readingPaceWpm()
    if not wpm or wpm <= 0 then return nil end
    local page = self.ui and self.ui.getCurrentPage and self.ui:getCurrentPage() or nil
    local position = self:_readingPosition(page)
    if not position then return nil end
    local words_left = self:_readingWordsLeft(position)
    if not words_left then return nil end
    local format = HighlightsDeToto._clockDuration
    local book = format(words_left / wpm * 60)
    local chapter_seconds
    local log = self.reading_log
    local pace = log and log:pace()
    local toc = self.ui and self.ui.toc
    if pace and pace.screens > 0 and page and type(toc) == "table" and type(toc.getChapterPagesLeft) == "function" then
        local ok, pages = pcall(toc.getChapterPagesLeft, toc, page, true)
        if ok and type(pages) == "number" and pages >= 0 then
            -- getChapterPagesLeft cuenta páginas y el ritmo es por pantalla: con
            -- dos páginas a la vista, cada pantalla son dos.
            local per_page = (pace.words / pace.screens) / math.max(1, self._visible_pages or 1)
            chapter_seconds = pages * per_page / wpm * 60
        end
    end
    if chapter_seconds then
        return T(_("%1 left · chapter %2"), book, format(chapter_seconds))
    end
    return T(_("%1 left"), book)
end

--- El ritmo que el servidor mando en la consulta enfocada. Se guarda en los
-- ajustes del libro: viaja con el guardado del sidecar que hace KOReader, el
-- plugin no escribe nada por esto.
function HighlightsDeToto:_applyReadingPace(response)
    local pace = type(response) == "table" and response.reading_pace or nil
    if type(pace) ~= "table" then return end
    self._server_pace = { book = type(pace.book) == "table" and pace.book or nil,
        account = type(pace.account) == "table" and pace.account or nil }
    if self.ui and self.ui.doc_settings then
        self.ui.doc_settings:saveSetting("borges_reading_pace", {
            book = self._server_pace.book, account = self._server_pace.account, at = os.time(),
        })
    end
end

function HighlightsDeToto:_registerFooterTimeLeft()
    if self._footer_time_left_fn or not self:isFooterTimeLeftEnabled() then return end
    local footer = self.ui and self.ui.view and self.ui.view.footer
    if type(footer) ~= "table" or type(footer.addAdditionalFooterContent) ~= "function" then
        if not Shared.footer_api_missing_logged then
            Shared.footer_api_missing_logged = true
            logger.info("Borges: this KOReader has no external footer content; time left stays off")
        end
        return
    end
    self._footer_time_left_fn = function()
        local ok, text = pcall(self._readingTimeLeftText, self)
        if ok then return text end
        return nil
    end
    footer:addAdditionalFooterContent(self._footer_time_left_fn)
end

function HighlightsDeToto:_unregisterFooterTimeLeft()
    local fn = self._footer_time_left_fn
    if not fn then return end
    self._footer_time_left_fn = nil
    local footer = self.ui and self.ui.view and self.ui.view.footer
    if type(footer) == "table" and type(footer.removeAdditionalFooterContent) == "function" then
        pcall(footer.removeAdditionalFooterContent, footer, fn)
    end
end

function HighlightsDeToto:toggleFooterTimeLeft()
    self.footer_time_left = not self:isFooterTimeLeftEnabled()
    if self.footer_time_left then
        if self.book_hash then self:_registerFooterTimeLeft() end
    else
        self:_unregisterFooterTimeLeft()
    end
    local footer = self.ui and self.ui.view and self.ui.view.footer
    if type(footer) == "table" and type(footer.onUpdateFooter) == "function" then
        pcall(footer.onUpdateFooter, footer, true)
    end
    self:saveSyncState()
end

-- ------------------------------------------------------------
-- Tiempo por capitulo, con los numeros de KOReader
-- ------------------------------------------------------------
-- Cuanto te llevo cada capitulo sale de page_stat_data (las estadisticas de
-- KOReader, no de Borges), repartido con el indice del libro en la paginacion
-- actual. Al lado, lo que el pie de KOReader («⤻») te decia al entrar al
-- capitulo. La cuenta vive en chaptertime.lua, igual a shared/chapterTime.js.
-- Nada de esto corre al pasar pagina: solo al abrir la pantalla y al cerrar el
-- libro (el indice viaja para que la web haga la misma cuenta).

local CHAPTER_TOC_MAX_BYTES = 28 * 1024
local CHAPTER_TOC_MAX_ENTRIES = 1500

function HighlightsDeToto:hasOpenBook()
    return self.book_hash ~= nil and not self._closed and self.ui ~= nil and self.ui.document ~= nil
end

--- El indice como lo navega KOReader: si los capitulos estan atados a las
-- marcas y hay niveles ignorados, esos niveles no cuentan como capitulo.
function HighlightsDeToto:_chapterTocEntries()
    local toc = self.ui and self.ui.toc
    if type(toc) ~= "table" then return nil end
    if type(toc.fillToc) == "function" then pcall(toc.fillToc, toc) end
    if type(toc.toc) ~= "table" or #toc.toc == 0 then return nil end
    local ignored = toc.toc_chapter_navigation_bind_to_ticks and type(toc.toc_ticks_ignored_levels) == "table"
        and toc.toc_ticks_ignored_levels or nil
    local entries = {}
    for index, item in ipairs(toc.toc) do
        local page = tonumber(item.page)
        if page and not (ignored and ignored[item.depth]) then
            entries[#entries + 1] = { toc_index = index, page = page, depth = tonumber(item.depth) or 1,
                title = type(item.title) == "string" and item.title or "" }
        end
        if #entries >= CHAPTER_TOC_MAX_ENTRIES then break end
    end
    return #entries > 0 and entries or nil
end

function HighlightsDeToto:_statisticsMaxSec()
    local stats = self.ui and self.ui.statistics
    local settings = type(stats) == "table" and stats.settings or nil
    local max_sec = type(settings) == "table" and tonumber(settings.max_sec) or nil
    return max_sec or ChapterTime.DEFAULT_MAX_SEC
end

--- Las filas de page_stat_data de este libro. Antes vuelca lo que KOReader
-- tiene en memoria de esta lectura (lo mismo que hace su propia pantalla de
-- estadisticas), asi la sesion en curso cuenta.
function HighlightsDeToto:_chapterPageRows()
    local stats = self.ui and self.ui.statistics
    if type(stats) == "table" and type(stats.insertDB) == "function"
        and type(stats.settings) == "table" and stats.settings.is_enabled then
        local ok, err = pcall(stats.insertDB, stats)
        if not ok then logger.warn("Borges: statistics insertDB error:", err) end
    end
    local conn, err = StatSync:openDB()
    if not conn then return nil, err end
    local rows = {}
    local ok, query_err = pcall(function()
        local id_book = type(stats) == "table" and tonumber(stats.id_curr_book) or nil
        local where
        if id_book then
            where = string.format("id_book = %d", id_book)
        else
            local md5 = tostring(self.book_hash or ""):lower()
            if not md5:match("^%x+$") then return end
            where = string.format("id_book IN (SELECT id FROM book WHERE md5 = '%s')", md5)
        end
        local stmt = conn:prepare("SELECT page, start_time, duration, total_pages FROM page_stat_data WHERE " .. where)
        local row = stmt:step({})
        while row do
            rows[#rows + 1] = { page = tonumber(row[1]), start_time = tonumber(row[2]),
                duration = tonumber(row[3]), total_pages = tonumber(row[4]) }
            row = stmt:step(row)
        end
        stmt:close()
    end)
    pcall(function() conn:close() end)
    if not ok then
        logger.warn("Borges: chapter time query error:", query_err)
        return nil, "query"
    end
    return rows
end

function HighlightsDeToto:_chapterTimeReport()
    local entries = self:_chapterTocEntries()
    if not entries then return nil, "no_toc" end
    local page_count = self.ui.document and self.ui.document.getPageCount and self.ui.document:getPageCount()
    local rows, err = self:_chapterPageRows()
    if not rows then return nil, err == "statistics.sqlite3 not found" and "no_stats" or "query" end
    return ChapterTime.compute({ entries = entries, page_count = page_count, rows = rows,
        max_sec = self:_statisticsMaxSec() })
end

local function chapterPercent(ratio)
    return math.floor(math.abs(ratio - 1) * 100 + 0.5)
end

--- Las filas del pie de la lista: que tanto la pego KOReader. Cortas, porque
-- la columna de la izquierda de KeyValuePage corta lo que no entra.
function HighlightsDeToto:_chapterSummaryRows(summary)
    if type(summary) ~= "table" or not summary.median_ratio then
        return { { _("Compared with KOReader"), _("not yet") } }
    end
    local ratio = summary.median_ratio
    local diff
    if ratio >= 0.95 and ratio <= 1.05 then
        diff = "="
    else
        diff = T(_("%1%"), (ratio > 1 and "+" or "-") .. chapterPercent(ratio))
    end
    return {
        { _("Your time vs. KOReader"), diff },
        { _("Chapters within 20%"), T(_("%1 of %2"), summary.within_20_percent, summary.chapters) },
        { _("⤻ KOReader's estimate"), _("when you started") },
    }
end

function HighlightsDeToto:_chapterDetailText(chapter)
    local format = HighlightsDeToto._clockDuration
    local lines = {
        chapter.title ~= "" and chapter.title or _("Untitled chapter"),
        T(_("Pages %1 to %2 · %3 of %4 read"), chapter.first_page, chapter.last_page, chapter.pages_read, chapter.pages),
        T(_("Time in this chapter: %1"), format(chapter.seconds)),
    }
    local ko = chapter.koreader
    if ko then
        table.insert(lines, "")
        table.insert(lines, T(_("When you reached page %1, KOReader estimated %2 for the rest of the chapter: %3 pages at %4 seconds each."),
            ko.entry_page, format(ko.estimate_seconds), ko.pages_left, math.floor(ko.avg_page_seconds + 0.5)))
        if ko.comparable then
            table.insert(lines, T(_("The rest took you %1."), format(ko.actual_seconds)))
        else
            table.insert(lines, _("Not compared: you did not read this chapter from its start to its end."))
        end
    end
    return table.concat(lines, "\n")
end

function HighlightsDeToto:_chapterTimesKv(report)
    local format = HighlightsDeToto._clockDuration
    local kv, unread, total = {}, 0, 0
    for _, chapter in ipairs(report.chapters) do
        if chapter.seconds > 0 then
            total = total + chapter.seconds
            local title = chapter.title ~= "" and chapter.title or _("Untitled chapter")
            if (chapter.depth or 1) > 1 then title = string.rep("  ", chapter.depth - 1) .. title end
            local value = format(chapter.seconds)
            if chapter.koreader and chapter.koreader.comparable then
                value = value .. " · ⤻ " .. format(chapter.koreader.estimate_seconds)
            end
            local detail = self:_chapterDetailText(chapter)
            table.insert(kv, { title, value, callback = function()
                UIManager:show(InfoMessage:new{ text = detail })
            end })
        else
            unread = unread + 1
        end
    end
    if #kv == 0 then return nil end
    table.insert(kv, "----")
    table.insert(kv, { _("Total"), format(total) })
    if unread > 0 then table.insert(kv, { _("Chapters not started"), tostring(unread) }) end
    for _, row in ipairs(self:_chapterSummaryRows(report.summary)) do table.insert(kv, row) end
    return kv
end

function HighlightsDeToto:showChapterTimes()
    if not self:hasOpenBook() then return end
    local report, err = self:_chapterTimeReport()
    if not report then
        if err == "no_toc" then
            self:showInfo(_("This book has no table of contents, so there are no chapters to measure."), 6)
        elseif err == "no_stats" then
            self:showInfo(_("KOReader has no reading statistics yet. Turn on Reading statistics in KOReader's tools menu."), 8)
        else
            self:showInfo(_("Could not read KOReader's reading statistics."), 6)
        end
        return
    end
    local kv = self:_chapterTimesKv(report)
    if not kv then
        self:showInfo(_("KOReader has not timed any page of this book yet."), 6)
        return
    end
    local KeyValuePage = require("ui/widget/keyvaluepage")
    UIManager:show(KeyValuePage:new{
        title = _("Time per chapter"),
        value_overflow_align = "right",
        kv_pairs = kv,
    })
end

--- El indice viaja una vez por cambio (otro tamano de letra cambia las
-- paginas): asi la web reparte las mismas filas de page_stat_data en los
-- mismos capitulos. Sale con la escritura de cola que el cierre ya hace.
function HighlightsDeToto:_enqueueChapterToc()
    if not self.sync_v2 or not self.book_hash or not self.ui or not self.ui.doc_settings then return false end
    local entries = self:_chapterTocEntries()
    if not entries then return false end
    local page_count = self.ui.document and self.ui.document.getPageCount and self.ui.document:getPageCount()
    if not page_count then return false end
    local max_sec = self:_statisticsMaxSec()
    local sum = 0
    for i, entry in ipairs(entries) do sum = (sum + entry.page * i + entry.toc_index * 7) % 1000000007 end
    local fingerprint = table.concat({ page_count, #entries, sum, max_sec }, ":")
    if self.ui.doc_settings:readSetting("borges_toc_sent") == fingerprint then return false end
    local clip, wire = 120, nil
    while true do
        wire = {}
        for _, entry in ipairs(entries) do
            wire[#wire + 1] = { i = entry.toc_index, p = entry.page, d = entry.depth,
                t = ReadingLog.utf8Clip(entry.title, clip) or "" }
        end
        if #rapidjson.encode(wire) <= CHAPTER_TOC_MAX_BYTES then break end
        if clip <= 8 then return false end
        clip = math.floor(clip / 2)
    end
    local book_hash = tostring(self.book_hash):lower()
    self.sync_v2:enqueue({
        event_type = "book_toc.recorded",
        aggregate_type = "book_toc",
        aggregate_id = "book_toc:" .. book_hash .. ":" .. fingerprint,
        book_identifier = self:_bookIdentifier(book_hash),
        occurred_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        time_precision = "exact",
        payload = { v = 1, page_count = page_count, max_sec = max_sec, entries = wire },
    }, { defer = true })
    self.ui.doc_settings:saveSetting("borges_toc_sent", fingerprint)
    return true
end

--- Titulo y nivel de los capitulos que usa una tanda (solo esos).
function HighlightsDeToto:_readingChapters(spans)
    local toc = self.ui and self.ui.toc and self.ui.toc.toc
    if type(toc) ~= "table" then return nil end
    local chapters, any = {}, false
    for _, span in ipairs(spans) do
        local index = span.toc_index
        if index and not chapters[tostring(index)] and type(toc[index]) == "table" then
            chapters[tostring(index)] = {
                title = ReadingLog.utf8Clip(toc[index].title, 200),
                depth = tonumber(toc[index].depth),
            }
            any = true
        end
    end
    return any and chapters or nil
end

--- Los tramos cerrados salen a la cola como `reading_span.recorded`, en tandas
-- de a lo sumo 100 tramos y 28 KiB. Solo en las escrituras que el plugin ya
-- hace: todo va con `defer` y lo guarda el flush de quien llama (con `defer`
-- falso lo guarda esta funcion; solo lo usan las pruebas).
function HighlightsDeToto:_enqueueReadingSpans(defer)
    local log = self.reading_log
    if not log or not self.book_hash or not self:isReadingSpansEnabled() or not self.sync_v2 then return 0 end
    if log:count() == 0 then return 0 end
    -- Lo que no se pudo contar antes (habia una seleccion abierta) se cuenta
    -- ahora si es seguro; mas de 20 sin contar salen sin palabras.
    self:_resolveReadingSpans(20)
    local rows = log:drain()
    if #rows == 0 then return 0 end
    local book_hash = tostring(self.book_hash):lower()
    local groups = {}
    for _, row in ipairs(rows) do
        local last = groups[#groups]
        if last and last.view_mode == row.view_mode then
            table.insert(last.rows, row)
        else
            table.insert(groups, { view_mode = row.view_mode or "page", rows = { row } })
        end
    end
    local book = {
        title = ReadingLog.utf8Clip(self.book_title, 500),
        author = ReadingLog.utf8Clip(self.book_author, 500),
        file = ReadingLog.utf8Clip(self.book_filename, 1000),
        language = ReadingLog.utf8Clip(self._book_language, 64),
    }
    -- Una tabla vacia puede salir como lista en JSON y el servidor pide objeto.
    if not next(book) then book = nil end
    local tz = ReadingLog.tzOffsetMinutes()
    local dropped = log.dropped or 0
    local enqueued = 0
    for _, group in ipairs(groups) do
        local last_row = group.rows[#group.rows]
        local page_count = tonumber(last_row.page_count or self.total_pages)
        local header = {
            v = 1, base_at = ReadingLog.isoMs(group.rows[1].started_wall_ms or 0), view_mode = group.view_mode,
            page_count = page_count, tz_offset_min = tz, book = book, dropped = 999999, spans = {},
        }
        -- Lo que no son tramos cuenta contra el tope: el libro, y un lugar fijo
        -- para los capítulos (fitChapters los hace entrar ahí).
        local budget = ReadingLog.EVENT_BYTES - #rapidjson.encode(header) - ReadingLog.CHAPTERS_BYTES - 64
        local chunks, bases, skipped = ReadingLog.chunk(group.rows, group.rows[1].started_wall_ms,
            ReadingLog.EVENT_ROWS, budget, rapidjson.encode)
        if skipped > 0 then
            logger.warn("Borges: reading spans too large to send:", skipped)
            dropped = dropped + skipped
        end
        for index, spans in ipairs(chunks) do
            local base = bases[index]
            local last_span = spans[#spans]
            local ended_ms = base + (last_span.started_at_ms or 0) + (last_span.dwell_ms or 0)
            enqueued = enqueued + 1
            self.sync_v2:enqueue({
                event_type = "reading_span.recorded",
                aggregate_type = "reading_spans",
                aggregate_id = "spans:" .. book_hash .. ":" .. string.format("%.0f", base) .. ":" .. enqueued,
                book_identifier = self:_bookIdentifier(book_hash),
                occurred_at = os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(ended_ms / 1000)),
                time_precision = "exact",
                payload = {
                    v = 1, base_at = ReadingLog.isoMs(base), view_mode = group.view_mode, page_count = page_count,
                    tz_offset_min = tz, book = book,
                    chapters = ReadingLog.fitChapters(self:_readingChapters(spans), ReadingLog.CHAPTERS_BYTES,
                        rapidjson.encode),
                    dropped = dropped, spans = spans,
                },
            }, { defer = true })
            dropped = 0
        end
    end
    if log.dropped and log.dropped > 0 then
        logger.warn("Borges: reading spans dropped by the memory cap:", log.dropped)
        log.dropped = 0
    end
    self:_anchorReadingClock()
    if not defer and enqueued > 0 then self.queue:flush() end
    return enqueued
end

--- KOReader re-renderizo (letra, margenes): misma pantalla, otro texto.
-- El PageUpdate del re-render llega antes y es la misma por XPointer: force.
function HighlightsDeToto:onDocumentRerendered()
    if self._closed or not self.book_hash then return end
    if self._sampleDeviceState then self:_sampleDeviceState("rerender") end
    if not self.reading_log then return end
    self._pending_cause = "rerender"
    self:_safecall("readingRerender", function()
        self._visible_pages = self:_readVisiblePages()
        local document = self.ui and self.ui.document
        if type(document) == "table" and type(document.getPageCount) == "function" then
            local ok, count = pcall(document.getPageCount, document)
            if ok and type(count) == "number" then self.total_pages = count end
        end
        self:_recordReadingScreen(nil, { force = true, defer_resolve = true })
    end)
end

--- Called when position changes (reflowable documents like EPUB/MOBI/AZW3).
function HighlightsDeToto:onUpdatePos()
    if not self.book_hash then return end
    self:_handlePageChange(self.ui:getCurrentPage())
end

--- Internal: shared handler for page/position changes.
function HighlightsDeToto:_handlePageChange(pageno)
    if not self.book_hash then return end

    local now = os.time()
    local xpointer = self._getXPointer and self:_getXPointer()
    -- Reflow or wake may report a new page number for the same exact location.
    local unchanged = xpointer and self._last_handled_xpointer == xpointer
        or (not xpointer and self._last_handled_page == pageno)
    if pageno == nil or unchanged then
        return
    end
    self._last_handled_page = pageno
    self._last_handled_xpointer = xpointer
    self._last_handled_page_at = now

    -- Track local activity timestamp (used as anti-regression guard in pullProgress)
    self:_recordReadingActivity()

    -- Update session page tracking
    self.session:updatePage(pageno)

    -- If initial pullProgress didn't run (no WiFi at book open), try now
    if not self.pull_done and NetworkMgr:isConnected() then
        self.pull_done = true
        UIManager:scheduleIn(1, function()
            self:_safecall("progressSyncDeferred", function()
                self:_runConnectedSync("page_change")
            end)
        end)
    end

    -- Debounced auto-push of progress. Sin red no se arma: no hay a quien
    -- subirle nada, y cada temporizador pendiente es una alarma que saca al
    -- lector del standby (en un lector real la pausa mediana por pagina es de
    -- 84 s: este disparaba en dos de cada tres paginas). La posicion se encola
    -- igual al guardar KOReader, al suspender y al cerrar.
    UIManager:unschedule(self.periodic_push_task)
    if NetworkMgr:isConnected() then
        UIManager:scheduleIn(PROGRESS_DEBOUNCE, self.periodic_push_task)
    end
end

--- KOReader guarda los ajustes del libro (autoguardado cada 15 minutos, al
-- suspender, al cerrar). Leyendo sin red es el momento de dejar la posicion en
-- la cola: una escritura chica cada tanto en vez de una por pausa de lectura.
function HighlightsDeToto:onSaveSettings()
    if not self.book_hash or self._closed then return end
    if not self:isWebConfigured() then return end
    -- F1 (enmienda 3.7) · los tramos pendientes salen aca haya o no red: asi
    -- una caida de KOReader pierde a lo sumo 15 minutos. Todo en UNA escritura
    -- de la cola, y solo si hubo algo que guardar.
    local spans = 0
    if self.reading_log then
        self:_safecall("saveSettingsSpans", function() spans = self:_enqueueReadingSpans(true) end)
    end
    -- F2 · las condiciones viajan en la misma escritura, y solo si la hay por
    -- los tramos (enmienda 3.7): una muestra sola nunca arma una escritura ni
    -- un intercambio al despertar.
    if self._sampleDeviceState then self:_sampleDeviceState("save") end
    if self._enqueueDeviceStates and (spans > 0 or self:_deviceStatesPiledUp()) then self:_safecall("saveSettingsStates", function() self:_enqueueDeviceStates() end) end
    local progress
    if not NetworkMgr:isConnected() then
        self:_safecall("saveSettingsProgress", function() progress = self:_enqueueProgressV2(false, true) end)
    end
    -- El indice (tiempo por capitulo) solo viaja en una escritura que ya
    -- ocurre, y aca KOReader guarda despues el sidecar con la marca de enviado.
    if spans > 0 or progress then
        if self._enqueueChapterToc then self:_safecall("saveSettingsToc", function() self:_enqueueChapterToc() end) end
        self:_safecall("saveSettingsSave", function() self.queue:flush() end)
    end
end

--- KOReader avisa cada vez que se crea, edita o borra una anotacion.
function HighlightsDeToto:onAnnotationsModified()
    self._annotations_modified = true
    self:_scheduleHighlightPush()
end

--- Called when device goes to standby/suspend.
-- Finishes the current session and enqueues everything for the next connection.
-- Each operation has its own _safecall so a failure in one doesn't skip the rest.
-- Kobo disables WiFi before broadcasting Suspend, so this must not try to
-- reconnect. The online last-chance flush happens in onNetworkDisconnecting.
function HighlightsDeToto:onSuspend()
    -- F2 · el motivo del sueno se decide antes de cerrar el tramo.
    if self._sampleDeviceState then self:_sampleDeviceState("sleep") end
    local sleep_fields = self._attention and self:_attentionSleepFields() or nil
    -- F1 · la pantalla deja de estar a la vista: el tramo termina aca.
    if self.reading_log then
        self:_safecall("readingSuspend", function() self.reading_log:close(sleep_fields) end)
    end
    self._background_suspended = true
    self:_cancelBackgroundSync()
    self.pairing:stopWatching()
    -- Dormido no hay nada que subir: un temporizador pendiente solo serviria
    -- para despertar al lector.
    UIManager:unschedule(self.periodic_push_task)
    UIManager:unschedule(self.highlight_push_task)
    if self._wifi_off_task then
        UIManager:unschedule(self._wifi_off_task)
        self._wifi_off_task = nil
    end
    if not self.book_hash then
        self:_safecall("sleepUploadWithoutBook", function() self:_uploadBeforeSleep() end)
        return
    end

    local flushed_before_suspend = self._disconnect_flush_book_hash == self.book_hash
        and self._disconnect_flush_at
        and (os.time() - self._disconnect_flush_at) <= 30
    self._disconnect_flush_book_hash = nil
    self._disconnect_flush_at = nil

    -- Donde el Wi-Fi sigue prendido al suspender (no es el caso del Kobo, que
    -- lo apaga antes), todo sale en un intercambio al final.
    local connected = NetworkMgr:isConnected()
    local upload_now = self.force_sync_before_sleep and connected

    -- Todo lo de esta lectura se guarda en UNA escritura de la cola, al final:
    -- antes eran una por la posicion, una por la sesion y una por cada tanda de
    -- estadisticas.
    if not flushed_before_suspend then
        self:_safecall("suspendProgress", function() self:_enqueueProgressV2(false, true) end)
    end

    -- Finish session and always enqueue (no HTTP during suspend — keeps sleep fast)
    self:_safecall("suspendSession", function()
        for _, session_data in ipairs(self.session:finishAll()) do
            self:_enqueueSessionV2(session_data, true)
        end
    end)

    self:_safecall("suspendFlush", function() self:_flushSidecar() end)

    if upload_now then
        -- F1 · los tramos entran antes de las estadisticas: syncPageStatsDelta guarda la
        -- cola si encolo filas, y asi ese mismo guardado los lleva (ninguna escritura nueva).
        -- F2 · las condiciones viajan con los tramos: solo si esta escritura los lleva.
        local f2_spans = 0
        if self.reading_log then self:_safecall("readingSpans", function() f2_spans = self:_enqueueReadingSpans(true) or 0 end) end
        if self._enqueueDeviceStates and (f2_spans > 0 or self:_deviceStatesPiledUp()) then self:_safecall("deviceStates", function() self:_enqueueDeviceStates() end) end
        self:_safecall("forceSleepStats", function() self:syncPageStatsDelta(true) end)
        self:_safecall("forceSleepHighlights", function() self:syncHighlightsDelta(true) end)
        self:_safecall("forceSleepSave", function() self.queue:flush() end)
        self:_safecall("forceSleepQueueDrain", function() self:_drainQueueBlocking(true) end)
        return
    end

    -- F1 · los tramos entran antes de las estadisticas: syncPageStatsDelta guarda la
    -- cola si encolo filas, y asi ese mismo guardado los lleva (ninguna escritura nueva).
    -- F2 · las condiciones viajan con los tramos: solo si esta escritura los lleva.
    local f2_spans = 0
    if self.reading_log then self:_safecall("readingSpans", function() f2_spans = self:_enqueueReadingSpans(true) or 0 end) end
    if self._enqueueDeviceStates and (f2_spans > 0 or self:_deviceStatesPiledUp()) then self:_safecall("deviceStates", function() self:_enqueueDeviceStates() end) end
    if not flushed_before_suspend then
        -- Enqueue stats delta and highlights for sync on next resume
        self:_safecall("suspendStats", function() self:syncPageStatsDelta(true) end)
        self:_safecall("suspendHighlights", function() self:syncHighlightsDelta(true) end)
    end
    self:_safecall("suspendSave", function() self.queue:flush() end)
    -- Con red y sin «sincronizar antes de dormir»: el mismo intercambio acotado
    -- (antes `_pushProgressOrQueue`: hasta dos intercambios y cinco consultas).
    if connected and not flushed_before_suspend then
        self:_safecall("suspendQueueDrain", function() self:_drainQueueBlocking(true) end)
    end
    self:_safecall("sleepUploadWithBook", function() self:_uploadBeforeSleep() end)
end

--- Called when device wakes from standby.
-- Starts a fresh session and requests progress as soon as Wi-Fi is connected.
-- Guard _resume_pull_done prevents duplicate pulls from overlapping triggers.
function HighlightsDeToto:onResume()
    self._background_suspended = false
    self._reading_wifi_cancelled = false
    Shared.wifi_edge, Shared.wifi_auto_closed = false, false
    Shared.sleep_exchange_this_suspension = false
    if self.pairing_state then self:watchDevicePairing(self.pairing_state, false) end
    self:_safecall("onResume", function()
        self:_closeSuspendSyncBanner()

        -- Start a fresh session
        if self.book_hash then
            self.session:start(self.book_hash, self.device_id, self.ui:getCurrentPage())
        end
        -- F2 · el tramo que abre despertar sale con causa "wake".
        if self._sampleDeviceState then self:_sampleDeviceState("wake") end
        if self.book_hash then self._pending_cause = "wake" end
        -- F1 · despertar abre un tramo nuevo con el reloj re-anclado.
        if self.book_hash and self.reading_log then
            self:_safecall("readingResume", function()
                self:_anchorReadingClock()
                self:_recordReadingScreen(nil, { force = true, defer_resolve = true })
            end)
        end

        if not self.book_hash then return end

        self._resume_pull_done = false
        local book, token, epoch = self.book_hash, self.device_token, self._background_epoch
        local reading_baseline = self:_captureReadingBaseline()
        self:_beginReadingHandoff()

        local function doSync()
            if self._resume_pull_done or self._reading_wifi_cancelled
                or self.book_hash ~= book or self.device_token ~= token
                or self._background_epoch ~= epoch then return end
            self._resume_pull_done = true
            logger.info("Borges: resume sync triggered")
            -- Despertar es el mismo flujo: consultar entero y después subir.
            self:_runConnectedSync("resume", { force = true, reading_baseline = reading_baseline })
        end

        -- Do not add a fixed second when the connection is already available.
        UIManager:nextTick(function()
            if self._resume_pull_done then return end
            self:_ensureReadingConnection(doSync)
        end)

        -- Backup at 15s in case the connection callback didn't fire.
        UIManager:scheduleIn(15, function()
            if self._resume_pull_done then return end
            if NetworkMgr:isConnected() then
                doSync()
            end
        end)
    end)
end

--- C17 · Prender el Wi-Fi a mano tiene que consultar, no sólo subir.
--
-- Antes acá sólo se vaciaba la cola, confiando en que `willRerunWhenOnline`
-- hubiera dejado agendada la consulta. No alcanzaba: ese callback es uno solo
-- y se dispara —o se descarta— en el momento de abrir el libro. Quien leía
-- una hora sin red y recién después prendía el Wi-Fi subía su posición vieja
-- y nunca veía la del otro lector.
--
-- Ahora la reconexión corre el flujo completo, con la ventana de
-- `RECONNECT_SYNC_DEBOUNCE` para que dos eventos de red seguidos no sean dos
-- corridas. Si la consulta de apertura o de resume está por correr, gana la
-- primera y la otra queda absorbida por esa misma ventana.
function HighlightsDeToto:onNetworkConnecting()
    -- La conexion de antes de dormir es del plugin y no empieza una lectura:
    -- no hay nada que volver a consultar ni que retener.
    if Shared.wifi_edge then return end
    self._reading_wifi_cancelled = false
    self:_beginReadingHandoff()
end

function HighlightsDeToto:onNetworkConnected()
    if Shared.wifi_edge then return end
    if self._reading_wifi_cancelled then return end
    -- Todas las instancias reciben este aviso. La conexion silenciosa la toma
    -- solo la instancia que la pidio (o cualquiera si esa ya se cerro), y solo
    -- la instancia viva decide que el Wi-Fi es de la persona: antes el
    -- explorador abierto detras del libro tomaba la conexion del libro, o la
    -- declaraba ajena, y el plugin nunca apagaba el Wi-Fi que prendio.
    local quiet = Shared.wifi_quiet
    if quiet and quiet.owner ~= self and not quiet.owner._closed then
        quiet = nil
    else
        Shared.wifi_quiet = nil
    end
    local decides = Shared.live == nil or Shared.live == self or Shared.live._closed
    if quiet then
        -- La conexion silenciosa que pidio el plugin: el Wi-Fi es suyo.
        if (self.wifi_quiet_misses or 0) > 0 then
            self.wifi_quiet_misses = 0
            self:saveSyncState(true)
        end
        self:_ownWifi()
    elseif decides and not Shared.wifi_quiet
        and not (self._reading_wifi and self._reading_wifi.active and self._reading_wifi.enabled_wifi) then
        -- Una conexion que no abrio el plugin es de la persona: no se apaga sola.
        Shared.wifi_owned, Shared.wifi_auto_closed = false, false
    end
    if not self._reading_head then self:_beginReadingHandoff() end
    UIManager:scheduleIn(5, function() self:_flushDiagnostics() end)
    if not self:isWebConfigured() then return end
    self:_scheduleHighlightPush()
    self:_safecall("networkConnectedSync", function()
        if quiet and quiet.owner == self and quiet.valid() then
            quiet.callback()
            return
        end
        local resumed = self._reading_wifi and self._reading_wifi:connected()
        if not resumed then self:_runConnectedSync("network") end
    end)
    -- C23 · Recién conectado es el momento natural para preguntar por una
    -- versión nueva, pero después de sincronizar: la posición del otro lector
    -- es lo que el lector está esperando, y la versión puede esperar treinta
    -- segundos. La política de `UpdateCheck` absorbe los rebotes de señal, así
    -- que dos eventos seguidos no son dos pedidos.
    UIManager:scheduleIn(PLUGIN_UPDATE_CHECK_DELAY, function()
        self:_safecall("networkConnectedUpdateCheck", function()
            self:_maybeCheckPluginUpdate("network")
        end)
    end)
end

--- Called RIGHT BEFORE WiFi is turned off (user toggled WiFi off, auto-disable,
-- suspend path, etc). This is the last chance to use the existing connection:
-- on Kobo, KOReader disables WiFi before broadcasting Suspend.
function HighlightsDeToto:onNetworkDisconnecting()
    -- El plugin apaga el Wi-Fi que el mismo prendio, con todo ya enviado: no
    -- hay "ultima oportunidad" que aprovechar ni cartel que mostrar.
    if Shared.wifi_closing then return end
    if Shared.wifi_edge then
        -- KOReader corta la conexion de antes de dormir: se acabo la ventana.
        Shared.wifi_edge = false
        return
    end
    Shared.wifi_owned = false
    self:_cancelBackgroundSync()
    -- Canceling a connection must not trigger synchronous "last chance"
    -- uploads: the reader explicitly chose to continue without syncing.
    if self._reading_wifi_cancelled then return end
    if not self:isWebConfigured() then return end

    if self.book_hash then
        logger.info("Borges: onNetworkDisconnecting - flushing current book")
        -- Todo se guarda primero y viaja despues en UN intercambio. Antes eran
        -- hasta cuatro pedidos seguidos con la pantalla esperando (posicion,
        -- subrayados, estadisticas y cola), cada uno con su saludo TLS. La
        -- posicion entra primera a la cola, asi que sale en la primera tanda.
        self:_safecall("disconnectingProgress", function() self:_enqueueProgressV2(false, true) end)
        -- Si el Wi-Fi se apaga porque el lector se va a dormir (KOReader ya
        -- mostro el protector de pantalla), la sesion de lectura termina aca y
        -- sube en este mismo intercambio. Antes se cerraba un instante despues,
        -- ya sin red, y obligaba a un pedido mas en el proximo despertar.
        if Device.screen_saver_mode == true then
            self:_safecall("disconnectingSession", function()
                for _, session_data in ipairs(self.session:finishAll()) do
                    self:_enqueueSessionV2(session_data, true)
                end
            end)
        end
        self:_safecall("disconnectingFlush", function() self:_flushSidecar() end)
        -- F1 · como la sesion: si el lector se va a dormir, la pantalla deja de
        -- estar a la vista aca y su tramo viaja en este mismo intercambio.
        if Device.screen_saver_mode == true and self.reading_log then
            if self._sampleDeviceState then self:_sampleDeviceState("sleep") end
            local sleep_fields = self._attention and self:_attentionSleepFields() or nil
            self:_safecall("readingSleepClose", function() self.reading_log:close(sleep_fields) end)
        end
        -- F1 · los tramos entran antes de las estadisticas: syncPageStatsDelta guarda la
        -- cola si encolo filas, y asi ese mismo guardado los lleva (ninguna escritura nueva).
        -- F2 · las condiciones viajan con los tramos: solo si esta escritura los lleva.
        local f2_spans = 0
        if self.reading_log then self:_safecall("readingSpans", function() f2_spans = self:_enqueueReadingSpans(true) or 0 end) end
        if self._enqueueDeviceStates and (f2_spans > 0 or self:_deviceStatesPiledUp()) then self:_safecall("deviceStates", function() self:_enqueueDeviceStates() end) end
        self:_safecall("disconnectingStats", function() self:syncPageStatsDelta(true) end)
        -- Solo comparar y encolar: la foto historica nunca sale al cortarse la red.
        self:_safecall("disconnectingHighlights", function() self:syncHighlightsDelta(true) end)
        self:_safecall("disconnectingSave", function() self.queue:flush() end)
        self._disconnect_flush_book_hash = self.book_hash
        self._disconnect_flush_at = os.time()
    end

    if self.queue:count() > 0 then
        logger.info("Borges: onNetworkDisconnecting - flushing queue")
        self:_safecall("disconnectingDrain", function() self:_drainQueueBlocking(true) end)
    end

    self:_showSuspendSyncStatus()
end

-- ============================================================
-- Progress Sync
-- ============================================================

--- Pull progress from server and sync position.
-- Uses xpointer for EPUB (device-independent), page numbers for PDF.
-- Same device: auto-jump if server is ahead.
-- Different device: always ask.
function HighlightsDeToto:pullProgress()
    local url = self:getBaseUrl()
        .. "/api/progress?book_hash=" .. util.urlEncode(self.book_hash)
        .. "&light=1&devices=1"
    local result, err = self:getApi():getJSON(url, self:getWebAuth(), true)

    if not result or not result.latest then
        if err then
            logger.warn("Borges: pullProgress failed:", err)
        end
        return
    end

    local server_device = result.latest.device_id or "unknown"
    local same_device = (server_device == self.device_id)
    local local_page = self.ui:getCurrentPage()
    local local_pct = self:_calcLocalPercentage()
    local server_pct = _safePct(result.latest.percentage)
    local has_xpointer = (not self.has_pages
        and result.latest.xpointer ~= nil
        and result.latest.xpointer ~= "")
    local display_page = self:_calcDisplayPage(result.latest)
    local recent_other = self:_findRecentOtherDeviceProgress(result.devices)

    logger.info("Borges: pullProgress -",
        "server_device:", server_device, "local_device:", self.device_id,
        "same_device:", same_device, "server_pct:", server_pct,
        "has_xpointer:", has_xpointer, "local_page:", local_page)

    -- C17 · El camino legacy también pregunta por la única puerta: misma
    -- compuerta de un diálogo por vez, misma memoria de lo ya respondido.
    local function askToJump(server_data, device_id)
        -- Legacy arrival time cannot prove when the other device was read.
        server_data.time_precision = server_data.time_precision or "unknown"
        self:_offerRemotePosition({
            remote = server_data,
            source = { id = device_id, name = server_data.device_name },
            others = result.devices,
        })
    end

    if recent_other then
        askToJump(recent_other, recent_other.device_id)
        return
    end

    -- Anti-regression guard (Bug #1): if local activity is newer than server's
    -- latest, the server is stale (offline reading not yet pushed) and auto-jumping
    -- would tug the user backwards. Two independent signals must align before we
    -- skip the jump:
    --   (a) local timestamp is newer than server's created_at (with 5s grace), OR
    --   (b) the offline queue still has a progress item for this book (drain failed).
    -- We only suppress same-device auto-jumps; cross-device always asks the user.
    if same_device then
        local server_ts = self:_parseISO8601UTC(result.latest.created_at)
        local local_newer = server_ts and self.last_progress_change > 0
            and server_ts < (self.last_progress_change - 5)
        local queue_pending = self.queue
            and self.queue:hasItemForBookHash("progress", self.book_hash)
        if local_newer or queue_pending then
            logger.info("Borges: pullProgress skipping auto-jump -",
                "local_newer:", local_newer, "queue_pending:", queue_pending)
            -- Schedule a push so the server catches up to our local position.
            UIManager:scheduleIn(2, function()
                self:_safecall("pushProgress", function() self:pushProgress(false) end)
            end)
            return
        end
    end

    -- For same device with xpointer: auto-jump (reliable position)
    -- For same device PDF: compare page numbers
    -- For different device: always ask
    if same_device then
        if has_xpointer then
            -- EPUB same device: only auto-jump when the server is actually ahead.
            if server_pct > (local_pct + 0.25) then
                self:_navigateToProgress(result.latest, true)
                logger.info("Borges: Auto-jumped via xpointer, same device")
                UIManager:scheduleIn(2, function()
                    self:_safecall("pushProgress", function() self:pushProgress(false, true) end)
                end)
            else
                UIManager:scheduleIn(2, function()
                    self:_safecall("pushProgress", function() self:pushProgress(false) end)
                end)
            end
        elseif self.has_pages then
            -- PDF same device: page numbers are valid
            local server_page = result.latest.current_page
            if not server_page or server_page == local_page then
                return
            end
            if server_page > local_page then
                if self._syncJump then self:_syncJump(Event:new("GotoPage", server_page)) else self.ui:handleEvent(Event:new("GotoPage", server_page)) end
                logger.info("Borges: Auto-jumped to page", server_page,
                    "(was", local_page, ") same device PDF")
                UIManager:scheduleIn(2, function()
                    self:_safecall("pushProgress", function() self:pushProgress(false, true) end)
                end)
            else
                UIManager:scheduleIn(2, function()
                    self:_safecall("pushProgress", function() self:pushProgress(false) end)
                end)
            end
        else
            -- EPUB same device but no xpointer from server (old data): use percentage fallback
            if not display_page or display_page == local_page then
                return
            end
            if display_page > local_page then
                self:_navigateToProgress(result.latest, true)
                UIManager:scheduleIn(2, function()
                    self:_safecall("pushProgress", function() self:pushProgress(false, true) end)
                end)
            else
                UIManager:scheduleIn(2, function()
                    self:_safecall("pushProgress", function() self:pushProgress(false) end)
                end)
            end
        end
    else
        -- Different device — always ask user
        askToJump(result.latest, server_device)
    end
end

--- Navigate to a server progress position.
-- For reflowable docs (EPUB): uses xpointer (device-independent DOM position).
-- For paged docs (PDF) or fallback: uses page numbers / percentage.
-- @param server_data table the result.latest from GET /api/progress
-- @param same_device boolean true if server_data came from this same device_id
-- @return boolean true if navigation was performed
--- Camino sincronico (sin buscar texto; lo usa pullProgress y el "deshacer"):
-- XPointer propio verificado, la misma pagina del mismo archivo,
-- capitulo + fraccion, porcentaje. Devuelve true, method.
function HighlightsDeToto:_navigateToProgress(server_data, same_device)
    if type(server_data) ~= "table" then return false end
    -- onGotoXPointer does not check it: one not in this DOM would move nowhere and still be saved.
    local target, method = PositionLocator.resolveSync(self.ui, server_data, {
        has_pages = self.has_pages == true,
        total_pages = self.total_pages,
        same_device = same_device == true,
        percentage = _safePct(server_data.percentage),
    })
    if not self.has_pages and server_data.xpointer and server_data.xpointer ~= ""
        and method ~= "xpointer" then
        logger.warn("Borges: xpointer not in this document, using", tostring(method), server_data.xpointer)
    end
    if not target then return false end
    self:_gotoTarget(target)
    logger.info("Borges: Navigated via", method)
    return true, method
end

--- Calculate display page for server progress (for UI messages only, not navigation).
-- @param server_data table the result.latest from GET /api/progress
-- @return number|nil approximate local page number
function HighlightsDeToto:_calcDisplayPage(server_data)
    -- F6: por capitulo y fraccion cuando el capitulo existe en este libro.
    if type(server_data.locator) == "table" and self.total_pages and self.total_pages > 0 then
        local ok, mapped = pcall(PositionLocator.localPercent, self.ui, server_data.locator, self.total_pages)
        if ok and mapped then
            local page = math.floor(mapped / 100 * self.total_pages) + 1
            return math.max(1, math.min(page, self.total_pages))
        end
    end
    local pct = _safePct(server_data.percentage)
    if pct >= 0 and self.total_pages and self.total_pages > 0 then
        local calc = math.floor(pct / 100 * self.total_pages + 0.5)
        return math.max(1, math.min(calc, self.total_pages))
    end
    return tonumber(server_data.current_page)
end

--- Calculate current local percentage using KOReader's current page/page count.
-- Used only for "is another device ahead?" decisions.
-- @return number percentage in 0..100
function HighlightsDeToto:_calcLocalPercentage()
    local current_page = self.ui and self.ui.getCurrentPage and self.ui:getCurrentPage() or 0
    if self.total_pages and self.total_pages > 0 then
        return (current_page / self.total_pages) * 100
    end
    return 0
end

--- Find the most recent reading on another device, in either book direction.
-- @param devices table|nil latest progress rows by device
-- @return table|nil progress row to offer
function HighlightsDeToto:_findRecentOtherDeviceProgress(devices)
    if type(devices) ~= "table" then return nil end

    local local_position = self:_currentPositionSnapshot()
    local local_time = ResumeFlow.readingTime(local_position)
    local best = nil
    local best_time = nil

    for _, dev in ipairs(devices) do
        if dev.device_id and dev.device_id ~= self.device_id and dev.device_id ~= self.paired_device_id then
            dev.time_precision = dev.time_precision or "unknown"
            local stamp = ResumeFlow.readingTime(dev)
            if not ResumeFlow.samePosition(dev, local_position)
                and (not stamp or not local_time or stamp > local_time)
                and (not best or (stamp and (not best_time or stamp > best_time))) then
                best = dev
                best_time = stamp
            end
        end
    end

    return best
end

--- Best-effort chapter lookup for a local page number.
-- KOReader exposes TOC data differently across document engines/builds, so
-- this tries the direct helpers first and falls back to walking common TOC
-- shapes. It is only used for user-facing preview text.
function HighlightsDeToto:_getChapterTitleForPage(page)
    page = tonumber(page)
    if not page or page < 1 then return nil end

    local direct_calls = {
        function()
            return self.ui and self.ui.document
                and self.ui.document.getTocTitleByPage
                and self.ui.document:getTocTitleByPage(page)
        end,
        function()
            return self.ui and self.ui.document
                and self.ui.document.getTocTitle
                and self.ui.document:getTocTitle(page)
        end,
        function()
            return self.ui and self.ui.toc
                and self.ui.toc.getTocTitleByPage
                and self.ui.toc:getTocTitleByPage(page)
        end,
    }
    for _, call in ipairs(direct_calls) do
        local ok, title = pcall(call)
        if ok and type(title) == "string" and title ~= "" then
            return title
        end
    end

    local ok, toc = pcall(function()
        if self.ui and self.ui.document and self.ui.document.getToc then
            return self.ui.document:getToc()
        end
        return nil
    end)
    if not ok or type(toc) ~= "table" then return nil end

    local best_title, best_page = nil, -1
    local function visit(items)
        if type(items) ~= "table" then return end
        for _, item in pairs(items) do
            if type(item) == "table" then
                local item_page = tonumber(item.page or item.page_num or item.pageno or item.pagenum or item.number)
                local title = item.title or item.text or item.name
                if item_page and item_page <= page and item_page >= best_page
                    and type(title) == "string" and title ~= "" then
                    best_page = item_page
                    best_title = title
                end
                visit(item.children or item.child or item.subitems or item.items)
            end
        end
    end
    visit(toc)
    return best_title
end

function HighlightsDeToto:_formatProgressTimestamp(iso)
    local ts = self:_parseISO8601UTC(iso)
    if not ts then return nil end
    local delta = math.max(0, os.time() - ts)
    if delta < 60 then
        return _("less than 1 min ago")
    elseif delta < 3600 then
        return T(_("%1 min ago"), math.floor(delta / 60))
    elseif delta < 86400 then
        return T(_("%1 h ago"), math.floor(delta / 3600))
    end
    return os.date("%Y-%m-%d %H:%M", ts)
end

--- Force-pull the latest progress from server and jump, regardless of device_id.
-- Manual menu action: always shows feedback, bypasses all guards.
function HighlightsDeToto:forcePullAndJump()
    if not self.book_hash then return end

    self:ensureNetwork(function()
        local url = self:getBaseUrl() .. "/api/progress?book_hash=" .. self.book_hash .. "&light=1"
        local result, err = self:getApi():getJSON(url, self:getWebAuth(), true)

        if not result or not result.latest then
            self:showInfo(err or _("No progress found on server for this book."), 5)
            return
        end

        local server_pct = _safePct(result.latest.percentage)
        local server_device = result.latest.device_id or "unknown"
        local same_device = (server_device == self.device_id)

        local navigated = self:_navigateToProgress(result.latest, same_device)
        if not navigated then
            self:showInfo(T(_("Server: %1%% (device: %2)\nNo valid position to jump to."),
                math.floor(server_pct), server_device), 5)
            return
        end

        local new_page = self.ui:getCurrentPage()
        self:showInfo(T(_("Jumped to %1%% (pag. %2)\nFrom device: %3"),
            math.floor(server_pct), new_page, server_device), 5)

        -- Push back so server knows this device caught up
        UIManager:scheduleIn(2, function()
            self:_safecall("pushProgress", function() self:pushProgress(false, true) end)
        end)
    end)
end

--- Jump to the latest progress from a DIFFERENT device.
-- Uses the full (non-light) API response which includes per-device progress.
-- Filters out the current device and jumps to the most recent other device's position.
function HighlightsDeToto:jumpToOtherDevice()
    if not self.book_hash then return end

    self:ensureNetwork(function()
        local url = self:getBaseUrl() .. "/api/progress?book_hash=" .. self.book_hash
        local result, err = self:getApi():getJSON(url, self:getWebAuth())

        if not result or not result.devices then
            self:showInfo(err or _("No progress found on server for this book."), 5)
            return
        end

        -- Filter out current device
        local other_devices = {}
        for _, dev in ipairs(result.devices) do
            if dev.device_id ~= self.device_id then
                table.insert(other_devices, dev)
            end
        end

        if #other_devices == 0 then
            self:showInfo(T(_("No progress from other devices.\n\nOnly found: %1 (this device)"),
                self.device_id), 5)
            return
        end

        -- La primera de la lista es la que el servidor devuelve arriba; el
        -- resto viaja igual al detalle, para que el lector vea todas.
        local other = other_devices[1]
        other.time_precision = other.time_precision or "anchored"
        local offered, reason = self:_offerRemotePosition({
            remote = other,
            source = { id = other.device_id, name = other.device_name },
            others = other_devices,
            force = true,
        })
        if not offered and reason == ResumeFlow.ALREADY_VISIBLE then
            self:showInfo(_("A position notice is already open."), 4)
        end
    end)
end

--- Push current reading progress to server.
-- @param interactive boolean if true, show errors to user; if false, silent
-- @param is_jump boolean (optional) true if this push is from a sync jump
function HighlightsDeToto:pushProgress(interactive, is_jump)
    if not self.book_hash then return end
    if not self:isWebConfigured() then return end

    -- Cooldown check for non-interactive pushes (skip cooldown for jumps)
    if not interactive and not is_jump then
        local now = os.time()
        if now - self.push_timestamp < PROGRESS_COOLDOWN then
            return
        end
    end

    self:_enqueueProgressV2(is_jump)
    if not interactive and not Background.current() and not self._background_suspended then
        -- Persist the exact position now, including explicit jumps; only the
        -- exchange is deferred. A later page turn cannot replace this snapshot.
        return self:_runBackgroundSync("progress", function()
            if NetworkMgr:isConnected() and self.device_token then
                local result = self:_syncV2Now(true, 2)
                if result then self.push_timestamp = os.time() end
            end
        end)
    end
    if not NetworkMgr:isConnected() or not self.device_token then
        if interactive then
            local message = NetworkMgr:isConnected()
                and _("Progress saved locally. Finish device pairing to upload it.")
                or _("Progress saved locally and will sync when WiFi returns.")
            self:showInfo(message, 4)
        end
        return
    end

    local result, err = self:_syncV2Now(not interactive, interactive and 20 or 2)
    if result then
        local now = os.time()
        self.push_timestamp = now
        self.last_progress_sync = now
        if interactive then
            self:showInfo(_("Progress synced!"), 2)
        end
    else
        if interactive then
            self:showInfo(T(
                _("Progress is safe locally; sync failed: %1"),
                tostring(err or _("Unknown"))
            ), 5)
        end
    end
end

-- ============================================================
-- Highlights Delta Sync
-- ============================================================

function HighlightsDeToto:_highlightKey(item)
    local text = normalizeHighlightText(item and item.text)
    if text == "" then return "" end
    -- Para rolling/EPUB: start_xp viene como `xpointer` (entry del server)
    -- o como `page`/`pos0` string (annotation local). end_xp viene como
    -- `pos1` string (local) o esta empaquetado dentro de `sort` JSON
    -- ({"pos0":"...","pos1":"..."}, server). Normalizamos para que items
    -- del server y locales generen la MISMA key — sin esto, cada pull
    -- duplica los highlights porque la dedup falla.
    local start_xp = nil
    if item.xpointer and item.xpointer ~= "" then
        start_xp = tostring(item.xpointer)
    elseif type(item.page) == "string" then
        start_xp = item.page
    elseif type(item.pos0) == "string" then
        start_xp = item.pos0
    end
    if start_xp then
        local end_xp = nil
        if type(item.pos1) == "string" and item.pos1 ~= "" then
            end_xp = item.pos1
        elseif type(item.sort) == "string" and item.sort:sub(1, 1) == "{" then
            local ok, decoded = pcall(rapidjson.decode, item.sort)
            if ok and type(decoded) == "table" and decoded.pos1 then
                end_xp = tostring(decoded.pos1)
            end
        end
        return text .. "|xp:" .. start_xp .. "|end:" .. tostring(end_xp or "")
    end
    if type(item.pos0) == "table" and type(item.pos1) == "table" then
        return text
            .. "|p:" .. tostring(item.page or item.pos0.page or "")
            .. "|x:" .. tostring(item.pos0.x or "") .. "," .. tostring(item.pos0.y or "")
            .. "-" .. tostring(item.pos1.x or "") .. "," .. tostring(item.pos1.y or "")
    end
    return text .. "|legacy"
end

function HighlightsDeToto:_highlightStartKey(item)
    local text = normalizeHighlightText(item and item.text)
    if text == "" then return "" end
    if item.xpointer and item.xpointer ~= "" then
        return text .. "|start:" .. tostring(item.xpointer)
    end
    if type(item.page) == "string" and item.page ~= "" then
        return text .. "|start:" .. item.page
    end
    if type(item.pos0) == "string" and item.pos0 ~= "" then
        return text .. "|start:" .. item.pos0
    end
    if type(item.pos0) == "table" then
        return text
            .. "|startp:" .. tostring(item.page or item.pos0.page or "")
            .. "|x:" .. tostring(item.pos0.x or "") .. "," .. tostring(item.pos0.y or "")
    end
    return ""
end

function HighlightsDeToto:_epochMsToDateTime(ms)
    local n = tonumber(ms)
    if not n then return nil end
    return os.date("%Y-%m-%d %H:%M:%S", math.floor(n / 1000))
end

function HighlightsDeToto:_decodePositionMeta(meta)
    if type(meta) ~= "string" or meta == "" then return nil end
    if meta:sub(1, 1) == "{" then
        local ok, decoded = pcall(rapidjson.decode, meta)
        if ok and type(decoded) == "table" then
            return decoded
        end
        return nil
    end
    return { pos1 = meta }
end

function HighlightsDeToto:_getCurrentMetadataPath()
    local file_path = self.book_file_path
        or (self.ui and self.ui.document and self.ui.document.file)
    if not file_path then return nil end
    local base = file_path:match("(.+)%.[^.]+$")
    local ext = file_path:match("%.([^.]+)$")
    if not base or not ext then return nil end
    return base .. ".sdr/metadata." .. ext .. ".lua"
end

function HighlightsDeToto:_backupCurrentMetadataBeforePull()
    local metadata_path = self:_getCurrentMetadataPath()
    if not metadata_path then return false end

    local src = io.open(metadata_path, "rb")
    if not src then return false end
    local content = src:read("*a")
    src:close()
    if not content then return false end

    local backup_path = metadata_path .. ".highlightsdetoto-autopull.bak"
    local dst = io.open(backup_path, "wb")
    if not dst then return false end
    dst:write(content)
    dst:close()
    logger.info("Borges: metadata backup written:", backup_path)
    return true
end

function HighlightsDeToto:_isValidXPointer(xp)
    if type(xp) ~= "string" or xp == "" then return false end
    if not self.ui or not self.ui.document then return false end
    local ok, valid = pcall(function()
        return self.ui.document:isXPointerInDocument(xp)
    end)
    return ok and valid
end

function HighlightsDeToto:_sanitizeLocalAnnotations()
    local annotation_module = self.ui and self.ui.annotation
    if not annotation_module or not annotation_module.annotations then return 0 end

    local changed = 0
    for _, item in ipairs(annotation_module.annotations) do
        if item.note ~= nil then
            if type(item.note) ~= "string" then
                item.note = nil
                changed = changed + 1
            elseif item.note:gsub("%s+", "") == "" then
                item.note = nil
                changed = changed + 1
            end
        end
        if item.chapter ~= nil and type(item.chapter) ~= "string" then
            item.chapter = ""
            changed = changed + 1
        end
        if item.color ~= nil and type(item.color) ~= "string" then
            item.color = ""
            changed = changed + 1
        end
        if item.drawer ~= nil and type(item.drawer) ~= "string" then
            item.drawer = "lighten"
            changed = changed + 1
        end
    end

    if changed > 0 then
        self:_backupCurrentMetadataBeforePull()
        if annotation_module.updateAnnotations then
            annotation_module:updateAnnotations(true, true)
        end
        self.ui.doc_settings:saveSetting("annotations", annotation_module.annotations)
        self.ui.doc_settings:flush()
        logger.warn("Borges: sanitized", changed, "annotation fields")
    end

    return changed
end

function HighlightsDeToto:_serverEntryToAnnotation(entry)
    if not entry or not entry.text or entry.text == "" then
        return nil, "empty_text"
    end

    local meta = self:_decodePositionMeta(entry.sort)
    local created_at = self:_epochMsToDateTime(entry.time) or os.date("%Y-%m-%d %H:%M:%S")
    local annotation = {
        datetime = created_at,
        drawer = optionalString(entry.drawer) or "lighten",
        color = stringOrEmpty(entry.color),
        text = stringOrEmpty(entry.text),
        chapter = stringOrEmpty(entry.chapter),
        pageno = tonumber(entry.page) or 0,
    }
    local note = optionalString(entry.note)
    if note and note ~= "" then
        annotation.note = note
    end

    local is_rolling = self.ui and self.ui.rolling ~= nil
    local is_paging = self.ui and self.ui.paging ~= nil

    if is_rolling then
        if not self:_isValidXPointer(entry.xpointer) then
            return nil, "missing_start_xpointer"
        end
        local pos1 = meta and meta.pos1 or nil
        if not self:_isValidXPointer(pos1) then
            return nil, "missing_end_xpointer"
        end
        annotation.page = entry.xpointer
        annotation.pos0 = entry.xpointer
        annotation.pos1 = pos1
        return annotation
    end

    if not is_paging then
        return nil, "unknown_document_mode"
    end

    if not meta or type(meta.pos0) ~= "table" or type(meta.pos1) ~= "table" then
        return nil, "missing_page_positions"
    end
    if not meta.pos0.page then meta.pos0.page = tonumber(entry.page) end
    if not meta.pos1.page then meta.pos1.page = tonumber(entry.page) end
    if not meta.pos0.x or not meta.pos0.y or not meta.pos1.x or not meta.pos1.y then
        return nil, "invalid_page_positions"
    end
    annotation.page = tonumber(entry.page) or meta.pos0.page or 0
    annotation.pos0 = meta.pos0
    annotation.pos1 = meta.pos1
    return annotation
end

--- Pull server-side highlights for the current book and merge them into the
-- loaded KOReader annotations. This is intentionally current-book only:
-- KOReader can safely redraw and persist the sidecar for the open document.
function HighlightsDeToto:pullHighlightsFromWeb(interactive)
    if not self.book_hash then return 0, 0, 0 end
    if not self:isWebConfigured() then return 0, 0, 0 end

    if not NetworkMgr:isConnected() then
        if interactive then self:showInfo(_("No network connection."), 3) end
        return 0, 0, 0
    end

    local annotation_module = self.ui and self.ui.annotation
    if not annotation_module or not annotation_module.annotations then
        if interactive then self:showInfo(_("Annotations are not available for this book."), 4) end
        return 0, 0, 0
    end

    local url = self:getSyncBookUrl()
    local result, err = self:getApi():getJSON(url, self:getWebAuth(), true)
    if not result then
        logger.warn("Borges: pullHighlights failed:", err)
        if interactive then self:showInfo(T(_("Highlight pull failed: %1"), err or _("Unknown")), 5) end
        return 0, 0, 0
    end

    local entries = result.entries or {}
    if #entries == 0 then
        if interactive then self:showInfo(_("No server highlights for this book."), 3) end
        return 0, 0, 0
    end

    local existing = {}
    local existing_by_start = {}
    for _, item in ipairs(annotation_module.annotations) do
        local key = self:_highlightKey(item)
        if key ~= "" then existing[key] = item end
        local start_key = self:_highlightStartKey(item)
        if start_key ~= "" and not existing_by_start[start_key] then
            existing_by_start[start_key] = item
        end
    end

    local added, updated, skipped = 0, 0, 0
    for index, entry in ipairs(entries) do
        if index % 20 == 0 then Background.yieldToUI() end
        local key = self:_highlightKey(entry)
        local start_key = self:_highlightStartKey(entry)
        local existing_item = existing[key]
        if not existing_item and start_key ~= "" then
            existing_item = existing_by_start[start_key]
        end
        if key ~= "" and not existing_item then
            local annotation, skip_reason = self:_serverEntryToAnnotation(entry)
            if annotation then
                local ok, add_err = pcall(function()
                    annotation_module:addItem(annotation)
                end)
                if ok then
                    existing[key] = annotation
                    if start_key ~= "" then existing_by_start[start_key] = annotation end
                    added = added + 1
                else
                    skipped = skipped + 1
                    logger.warn("Borges: add server highlight failed:", add_err)
                end
            else
                skipped = skipped + 1
                logger.info("Borges: skipped server highlight:", skip_reason, key:sub(1, 60))
            end
        elseif key ~= "" and existing_item then
            local local_item = existing_item
            local note = optionalString(entry.note)
            if note and note ~= "" and (not local_item.note or local_item.note == "") then
                local_item.note = note
                updated = updated + 1
            end
        end
    end

    if added > 0 or updated > 0 then
        self:_backupCurrentMetadataBeforePull()
        if annotation_module.updateAnnotations then
            annotation_module:updateAnnotations(true, true)
        end
        self.ui.doc_settings:saveSetting("annotations", annotation_module.annotations)
        self.ui.doc_settings:flush()
        self.last_web_sync = os.time()
        self:saveSyncState()
    end

    if interactive then
        self:showInfo(T(_("Pulled %1 new, updated %2 notes, skipped %3."), added, updated, skipped), 6)
    end

    return added, updated, skipped
end

function HighlightsDeToto:_attachCurrentBookHash(payload)
    if not payload or not payload.documents or not self.book_hash then return end
    for _, doc in ipairs(payload.documents) do
        doc.book_hash = doc.book_hash or self.book_hash
    end
end

function HighlightsDeToto:syncCurrentBookBothWays()
    if not self.book_hash then return end
    if not self:isWebConfigured() then
        self:showInfo(_("Please configure Web Sync first (URL and API key)."))
        return
    end
    self:ensureNetwork(function()
        local added, updated = self:pullHighlightsFromWeb(false)
        self:syncHighlightsDelta(false, true)
        self:showInfo(T(_("Two-way sync done. Pulled %1 new, updated %2 notes."), added or 0, updated or 0), 5)
    end)
end

--- La clave con la que se marca que un libro ya mando su foto historica.
function HighlightsDeToto:_bridgeKey()
    return self.book_key or self.book_hash
end

--- La foto historica de un libro (la importacion de lo subrayado antes de
-- Borges v2), en segundo plano y por partes. Antes salia de una vez dentro de
-- `syncHighlightsDelta`, incluso al dormir: un libro de 800 subrayados era un
-- pedido de cientos de KB con la pantalla esperando.
--
-- Solo corre dentro de una corrutina de `Background`. Arma la foto del sidecar
-- en disco y la manda en tandas de BRIDGE_CHUNK_ENTRIES entradas con el mismo
-- encabezado de documento, cediendo la pantalla entre una y otra. El libro
-- queda marcado recien cuando salieron todas: una tanda que falla deja el
-- libro sin marcar y la proxima vez se manda entera otra vez (el servidor
-- deduplica por texto).
-- @return number|nil entradas enviadas, o nil y el motivo
function HighlightsDeToto:_bridgeHistoryInBackground()
    if not Background.current() then return nil, "not_background" end
    if self._closed or self._background_suspended then return nil, "not_now" end
    local key = self:_bridgeKey()
    if not key or not self:isWebConfigured() then return nil, "no_book" end
    if self.annotation_v2_bridged[key] == true then return 0 end
    if not NetworkMgr:isConnected() then return nil, "offline" end
    local file_path = self.book_file_path or (self.ui and self.ui.document and self.ui.document.file)
    if not file_path then return nil, "no_file" end
    -- Un libro sin ninguna anotacion no tiene historia que importar.
    local annotation_module = self.ui and self.ui.annotation
    if annotation_module and type(annotation_module.annotations) == "table"
        and #annotation_module.annotations == 0 then
        return 0
    end
    local payload, count = HighlightParser:generateApiPayloadForBook(file_path)
    if not payload or (count or 0) == 0 then return 0 end
    self:_attachCurrentBookHash(payload)
    local document = payload.documents and payload.documents[1]
    if type(document) ~= "table" or type(document.entries) ~= "table" then return 0 end

    -- La foto sale del sidecar en DISCO. Un subrayado que ya se sabe borrado
    -- (la cola lo anoto `present = false`, o hay un borrado recibido esperando
    -- su libro en el inbox) no puede viajar: `/api/sync` lo volveria a crear.
    local removed = {}
    for sync_id, entry in pairs(self.queue:getAnnotationState(self:_annotationStateKey())) do
        if type(entry) == "table" and entry.present == false then removed[sync_id] = true end
    end
    if self.queue:inboxCountForBook(self:_bookIdentifier(self.book_hash)) > 0 then
        for _, event in ipairs(self.queue:getInbox()) do
            if (event.event_type == "annotation.deleted" or event.event_type == "bookmark.deleted")
                and type(event.aggregate_id) == "string" then
                removed[event.aggregate_id:lower()] = true
            end
        end
    end
    local entries, sent = {}, 0
    for _, entry in ipairs(document.entries) do
        if not (type(entry.sync_id) == "string" and removed[entry.sync_id:lower()]) then
            table.insert(entries, entry)
        end
    end
    for first = 1, #entries, BRIDGE_CHUNK_ENTRIES do
        if self._closed or self._background_suspended or not NetworkMgr:isConnected() then
            return nil, "interrupted"
        end
        local chunk = {}
        for index = first, math.min(#entries, first + BRIDGE_CHUNK_ENTRIES - 1) do
            table.insert(chunk, entries[index])
        end
        local part = {}
        for field, value in pairs(document) do part[field] = value end
        part.entries = chunk
        local part_payload = {}
        for field, value in pairs(payload) do part_payload[field] = value end
        part_payload.documents = { part }
        local result, err = self:getApi():postJSON(self.web_url, self:getWebAuth(), part_payload, true)
        if not result then
            logger.warn("Borges: historical annotation bridge deferred:", tostring(err))
            return nil, err
        end
        sent = sent + #chunk
        Background.yieldToUI()
    end
    self.annotation_v2_bridged[key] = true
    self:saveSyncState(true)
    logger.info("Borges: historical annotation bridge imported", sent, "entries")
    return sent
end

--- Sync current-book annotations through the durable v2 outbox.
-- Compara el sidecar con lo ya sincronizado y encola los cambios. La foto
-- historica del libro ya no sale de aca: la manda `_bridgeHistoryInBackground`
-- en segundo plano y por partes, nunca al dormir.
-- @param enqueue_only boolean (optional) if true, never exchange (for suspend)
-- @param quick boolean (optional) use shorter HTTP timeout (5/10s) — for close/disconnect paths
function HighlightsDeToto:syncHighlightsDelta(enqueue_only, quick, defer_exchange)
    if not self.book_hash then return end
    if not self:isWebConfigured() then return end

    local file_path = self.book_file_path
        or (self.ui.document and self.ui.document.file)
    if not file_path then
        logger.warn("Borges: syncHighlightsDelta - no file_path available")
        return
    end

    local bridged = self.annotation_v2_bridged[self:_bridgeKey()] == true
    -- Dormido no sale ningun pedido de aca, aunque se lo pidan.
    if self._background_suspended then enqueue_only = true end

    -- El tiempo queda en el log a proposito: es la unica medicion que se
    -- puede hacer en el lector mismo, y permite comparar versiones leyendo el
    -- crash.log en vez de suponer.
    local ok_socket, socket = pcall(require, "socket")
    local started = ok_socket and socket.gettime and socket.gettime() or os.clock()
    local event_count, assigned = self:_enqueueAnnotationDiff()
    local finished = ok_socket and socket.gettime and socket.gettime() or os.clock()
    logger.info(
        "Borges: annotation delta enqueued",
        event_count,
        "events;",
        assigned,
        "stable IDs assigned;",
        math.floor((finished - started) * 1000 + 0.5),
        "ms"
    )

    -- defer_exchange: quien llama manda todo junto despues, en un solo
    -- intercambio (un pedido es un saludo TLS completo en el lector).
    local sync_result
    if event_count > 0 and not enqueue_only and not defer_exchange
        and NetworkMgr:isConnected() and self.device_token then
        sync_result = self:_syncV2Now(quick, math.max(4, event_count + 2))
    end

    if bridged or (sync_result and (sync_result.pending or 0) == 0) then
        self.last_web_sync = os.time()
        local mtime = HighlightParser:getSidecarMtime(file_path)
        if mtime then self.synced_books[file_path] = mtime end
    end
    self:saveSyncState(true)
end

--- Force sync highlights now (for manual menu action). Same path as delta.
function HighlightsDeToto:syncHighlightsNow()
    if not self.book_hash then return end
    self:syncHighlightsDelta()
end

-- ============================================================
-- Stats Sync
-- ============================================================

local function isMissingStatsDbError(err)
    return err == "statistics.sqlite3 not found"
end

function HighlightsDeToto:_enqueueStatsV2(data)
    local chunks = StatSync:getV2Chunks(data.page_stats, data.books)
    for index, chunk in ipairs(chunks) do
        local first = chunk.rows[1]
        local last = chunk.rows[#chunk.rows]
        local same_book = true
        for _, row in ipairs(chunk.rows) do
            if row.book_md5 ~= first.book_md5 then same_book = false; break end
        end
        local aggregate_id = table.concat({
            "page-stats",
            tostring(first.book_md5),
            tostring(first.start_time),
            tostring(last.start_time),
            tostring(index),
        }, ":")
        self.sync_v2:enqueue({
            event_type = "page_stat.recorded",
            aggregate_type = "reading_statistics",
            aggregate_id = aggregate_id,
            book_identifier = same_book and self:_bookIdentifier(first.book_md5) or nil,
            occurred_at = os.date(
                "!%Y-%m-%dT%H:%M:%SZ",
                tonumber(last.start_time) or os.time()
            ),
            time_precision = "exact",
            payload = chunk,
        }, {
            coalesce_unattempted = true,
            -- Todas las tandas en un guardado: lo hace quien llama.
            defer = true,
        })
        Background.yieldToUI()
    end
    return #chunks, StatSync:getMaxStartTime(data.page_stats)
end

--- Persist page-stat delta as bounded v2 events, then exchange when possible.
-- @param enqueue_only boolean (optional) if true, skip HTTP and just enqueue (for suspend)
-- @param quick boolean (optional) use shorter HTTP timeout (5/10s) — for close/disconnect paths
--- @param force boolean el lector pidió sincronizar a mano. El interruptor de
-- automatismo decide si el plugin trabaja solo, no si obedece una orden
-- explícita: apagarlo no puede dejar las estadísticas fuera de la acción única.
function HighlightsDeToto:syncPageStatsDelta(enqueue_only, quick, force)
    if not self:isWebConfigured() then return end
    if not self.auto_sync and not force then return end  -- comparte toggle con highlights

    local data, err = StatSync:getDelta(self.last_stats_enqueued_at)
    if not data then
        if err then
            logger.warn("Borges: stats delta read failed:", err)
            self.last_stats_error = err
            self:saveSyncState(true)
        end
        return
    end

    if self.last_stats_error then
        self.last_stats_error = nil
        self:saveSyncState(true)
    end

    if data.total_rows == 0 then
        logger.info("Borges: stats delta - no new rows since last sync")
        return
    end

    logger.info("Borges: stats delta -", data.total_rows, "rows to sync")

    local chunk_count, watermark = self:_enqueueStatsV2(data)
    -- Primero las filas a la cola (un guardado para todas las tandas) y recien
    -- despues la marca de hasta donde se leyo. La marca no fuerza una escritura
    -- de los ajustes de KOReader (24 KB): sale con el proximo guardado que haga
    -- KOReader. Si se pierde, las mismas filas se vuelven a encolar y el
    -- servidor las reconoce (ON CONFLICT DO NOTHING).
    self.queue:flush()
    if watermark then
        self.last_stats_enqueued_at = math.max(
            tonumber(self.last_stats_enqueued_at) or 0,
            watermark
        )
    end
    self:saveSyncState(true)
    logger.info(
        "Borges: stats durably enqueued,",
        data.total_rows,
        "rows in",
        chunk_count,
        "events"
    )

    if not enqueue_only and NetworkMgr:isConnected() and self.device_token then
        local result, post_err = self:_syncV2Now(quick == true, chunk_count + 4)
        if result and result.pending == 0 then
            self.last_stats_sync = os.time()
            self.last_stats_error = nil
            logger.info("Borges: stats v2 acknowledged,", data.total_rows, "rows")
        elseif not result then
            self.last_stats_error = post_err
            logger.warn(
                "Borges: stats remain safe in outbox:",
                tostring(post_err)
            )
        end
        self:saveSyncState(true)
    end
end

--- Full dump: send ALL statistics.sqlite3 data to server.
-- Menu action with confirmation. Sends in chunks with progress.
function HighlightsDeToto:fullStatsDump()
    if not self:isWebConfigured() then
        self:showInfo(_("Please configure Web Sync first (URL and API key)."))
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("This will send ALL reading statistics to the server. It may take a few minutes.\n\nContinue?"),
        ok_callback = function()
            self:ensureNetwork(function()
                local progress = self:showInfoPersist(_("Reading statistics database..."))

                local all_data, err = StatSync:getAllData()
                if not all_data then
                    self.last_stats_error = err
                    self:saveSyncState()
                    UIManager:close(progress)
                    self:showInfo(err or _("Error reading statistics database"), 5)
                    return
                end

                if self.last_stats_error then
                    self.last_stats_error = nil
                    self:saveSyncState()
                end

                if all_data.total_rows == 0 then
                    UIManager:close(progress)
                    self:showInfo(_("No statistics data found."), 5)
                    return
                end

                local total_rows = all_data.total_rows
                local chunk_count, watermark = self:_enqueueStatsV2(all_data)
                if watermark then
                    self.last_stats_enqueued_at = math.max(
                        tonumber(self.last_stats_enqueued_at) or 0,
                        watermark
                    )
                end
                self:saveSyncState()
                UIManager:close(progress)
                progress = self:showInfoPersist(
                    T(_("Uploading %1 rows in %2 durable events..."),
                        total_rows, chunk_count)
                )
                UIManager:forceRePaint()
                local result, sync_err = self:_syncV2Now(
                    false,
                    math.max(20, chunk_count + 20)
                )
                UIManager:close(progress)

                if not result or result.pending > 0 then
                    self.last_stats_error = sync_err
                        or _("The upload is still pending in the durable outbox.")
                    self:saveSyncState()
                    self:showInfo(
                        T(_("All %1 rows are safe locally.\nPending upload: %2"),
                            total_rows, tostring(self.last_stats_error)),
                        15
                    )
                else
                    self.last_stats_sync = os.time()
                    self.last_stats_error = nil
                    self:saveSyncState()
                    self:showInfo(
                        T(_("Complete! %1 rows sent (%2 books)."),
                            total_rows, #all_data.books),
                        10
                    )
                end
            end)
        end,
    })
end

--- Get a human-readable stats sync status text for the menu.
function HighlightsDeToto:getStatsSyncStatusText()
    if self.last_stats_error then
        return _("Failed: ") .. tostring(self.last_stats_error)
    end
    if self.last_stats_sync and self.last_stats_sync > 0 then
        local ago = os.time() - self.last_stats_sync
        if ago < 60 then
            return _("OK (just now)")
        elseif ago < 3600 then
            return T(_("OK (%1 min ago)"), math.floor(ago / 60))
        else
            return T(_("OK (%1 h ago)"), math.floor(ago / 3600))
        end
    end
    return _("Never synced")
end

-- ============================================================
-- Settings Management
-- ============================================================

--- Un archivo de configuracion editable por USB, leido una vez.
--
-- Estos dos archivos se abrian, se leian y se interpretaban en cada arranque
-- del plugin -cada vez que se abre o se cierra un libro- aunque nadie los
-- hubiera tocado (el de Dropbox, 102 veces en el log de un lector que no usa
-- Dropbox). Ahora se vuelven a leer solo si cambiaron de fecha o de tamano.
local function readConfigFile(config_path)
    Shared.config_files = Shared.config_files or {}
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local attributes = ok_lfs and lfs.attributes(config_path) or nil
    local stamp = type(attributes) == "table"
        and (tostring(attributes.modification) .. ":" .. tostring(attributes.size)) or nil
    local cached = Shared.config_files[config_path]
    if ok_lfs and cached and cached.stamp == stamp then return cached.data end
    local data
    local f = io.open(config_path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content and content ~= "" then
            local ok, decoded = pcall(rapidjson.decode, content)
            if ok and type(decoded) == "table" then
                data = decoded
            else
                logger.warn("Borges: Failed to parse", config_path)
            end
        end
    end
    Shared.config_files[config_path] = { stamp = stamp, data = data }
    return data
end

function HighlightsDeToto:loadConfigFile()
    return readConfigFile(self:getConfigFilePath())
end

function HighlightsDeToto:saveConfigFile()
    local config_path = self:getConfigFilePath()
    local data = {
        app_key = DropboxApi.APP_KEY or "",
        app_secret = DropboxApi.APP_SECRET or "",
        refresh_token = DropboxApi.refresh_token or "",
        dropbox_path = self.dropbox_path,
    }
    local json_str = rapidjson.encode(data, { pretty = true })
    local f = io.open(config_path, "w")
    if f then
        f:write(json_str)
        f:close()
        logger.info("Borges: Saved config to", config_path)
    end
end

function HighlightsDeToto:loadWebConfigFile()
    return readConfigFile(self:getWebConfigFilePath())
end

function HighlightsDeToto:saveWebConfigFile()
    local config_path = self:getWebConfigFilePath()
    local data = {
        url = self.web_url or "",
        base_url = self.server_base_url or self:getBaseUrl(),
        install_id = self.install_id or "",
        -- Kept only during controlled migration. Paired installs authenticate
        -- from KOReader settings and write no master key here.
        api_key = self.device_token and "" or (self.web_api_key or ""),
    }
    local json_str = rapidjson.encode(data, { pretty = true })
    local f = io.open(config_path, "w")
    if f then
        f:write(json_str)
        f:close()
    end
end

function HighlightsDeToto:loadSettings()
    local raw_settings = G_reader_settings:readSetting("highlightsdetoto") or {}
    -- Lo que hay guardado, antes de migrar nada. La primera vez del proceso es
    -- ademas lo que hay en el disco.
    self._loaded_settings_digest = AnnotationAdapter.stableEncode(raw_settings)
    if Shared.settings_flushed == nil then
        Shared.settings_flushed = self._loaded_settings_digest
        Shared.settings_saved = self._loaded_settings_digest
    end
    local web_config = self:loadWebConfigFile()
    local settings = SettingsMigration.migrate(raw_settings, web_config)
    self:_applyMigratedSettings(settings)
    self.dropbox_path = settings.dropbox_path or DEFAULT_DROPBOX_PATH
    DropboxApi:init(settings.dropbox or {})

    -- Web sync config
    self.web_url = settings.web_url or ""
    self.server_base_url = settings.server_base_url or ""
    self.web_api_key = settings.web_api_key or ""
    self.device_token = settings.device_token
    self.device_credential_id = settings.device_credential_id
    self.paired_device_id = settings.paired_device_id
    self.account_username = settings.account_username
    self.credential_expires_at = settings.credential_expires_at
    self.credential_renew_after = settings.credential_renew_after
    self.credential_rejected_at = settings.credential_rejected_at
    self.install_id = settings.install_id
    self.pairing_state = settings.pairing
    self.settings_schema_version = settings.settings_schema_version
    self.auto_sync = settings.auto_sync ~= false
    -- Pulls: guardas activas en pullHighlightsFromWeb (solo agrega + backup
    -- previo del .sdr) y pullProgress (anti-regression + dialog cross-device).
    self.auto_pull_highlights = settings.auto_pull_highlights ~= false
    self.auto_pull_progress = settings.auto_pull_progress ~= false
    self.force_sync_before_sleep = settings.force_sync_before_sleep ~= false
    self.wifi_only_to_sync = settings.wifi_only_to_sync == true
    self.wifi_only_to_sync_note = settings.wifi_only_to_sync_note
    -- F1 · medir la lectura en palabras: prendido salvo que se apague a mano.
    self.reading_spans_enabled = settings.reading_spans ~= false
    -- F2 · las tres capturas, prendidas salvo que se apaguen a mano.
    self.capture_nav_cause = settings.capture_nav_cause ~= false
    self.capture_attention = settings.capture_attention ~= false
    self.capture_device_state = settings.capture_device_state ~= false
    self.footer_time_left = settings.footer_time_left ~= false
    -- F6: guardar el texto de donde quedaste viene prendido.
    self.position_text_capture = settings.position_text_capture ~= false
    self.wifi_quiet_misses = tonumber(settings.wifi_quiet_misses) or 0
    self.last_web_sync = settings.last_web_sync or 0
    self.synced_books = settings.synced_books or {}
    self.annotation_v2_bridged = settings.annotation_v2_bridged or {}

    -- Progress sync config: auto-detect device type, migrate old "kobo" default
    local saved_id = settings.device_id
    if not saved_id or saved_id == "kobo" then
        self.device_id = Device.model or "kobo"
    else
        self.device_id = saved_id
    end
    self.last_progress_sync = settings.last_progress_sync or 0

    -- Stats sync state
    self.last_stats_sync = settings.last_stats_sync or 0
    self.last_stats_enqueued_at = settings.last_stats_enqueued_at
        or settings.last_stats_sync
        or 0
    self.last_stats_error = settings.last_stats_error or nil
    self.library_download_dir = settings.library_download_dir or DEFAULT_LIBRARY_DIR
    if self.library_download_dir == OLD_DEFAULT_LIBRARY_DIR then
        self.library_download_dir = DEFAULT_LIBRARY_DIR
    end
    self.auto_check_plugin_updates = settings.auto_check_plugin_updates ~= false
    -- C23 · Cuatro cosas distintas que antes eran una sola fecha. El último
    -- éxito decide cuándo toca volver a preguntar; el último intento y los
    -- fallos seguidos espacian los reintentos. Antes un fallo corría la fecha
    -- un día entero y dejaba al lector sin avisos hasta el día siguiente.
    self.last_plugin_update_check = settings.last_plugin_update_check or 0
    self.plugin_update_attempt_at = settings.plugin_update_attempt_at
        or self.last_plugin_update_check
    self.plugin_update_failures = settings.plugin_update_failures or 0
    -- C23 · Una versión nueva detectada sobrevive al reinicio: si no, el aviso
    -- sólo existía durante el segundo en que el chequeo automático corría.
    self.pending_update = settings.pending_update
    -- La versión que el lector ya vio anunciada. Posponer apaga el cartel
    -- hasta que salga otra versión, pero no borra el indicador del menú.
    self.pending_update_notified = settings.pending_update_notified
    -- Instalada no es lo mismo que cargada: hasta reiniciar, KOReader sigue
    -- corriendo la versión vieja aunque los archivos nuevos ya estén en disco.
    self.installed_update = settings.installed_update
    -- C07 · Última sincronización que dejó al lector realmente al día. Es
    -- distinta de last_progress_sync, que avanza también cuando quedó cola.
    self.last_full_sync = settings.last_full_sync or 0
    self.position_undo_entries = settings.position_undo or {}
    if self.position_undo then
        self.position_undo.entries = self.position_undo_entries
    end

    -- Load dropbox config file (takes priority over internal settings)
    local file_config = self:loadConfigFile()
    if file_config then
        if file_config.app_key and file_config.app_key ~= "" then
            DropboxApi.APP_KEY = file_config.app_key
        end
        if file_config.app_secret and file_config.app_secret ~= "" then
            DropboxApi.APP_SECRET = file_config.app_secret
        end
        if file_config.refresh_token and file_config.refresh_token ~= "" then
            DropboxApi.refresh_token = file_config.refresh_token
        end
        if file_config.dropbox_path and file_config.dropbox_path ~= "" then
            self.dropbox_path = file_config.dropbox_path
        end
    end
end

function HighlightsDeToto:_applyMigratedSettings(settings)
    if type(settings) ~= "table" then return end
    self.web_url = settings.web_url or self.web_url or ""
    self.server_base_url = settings.server_base_url or self.server_base_url or ""
    self.web_api_key = settings.web_api_key or self.web_api_key or ""
    self.device_token = settings.device_token
    self.device_credential_id = settings.device_credential_id
    self.paired_device_id = settings.paired_device_id
    self.account_username = settings.account_username
    self.credential_expires_at = settings.credential_expires_at
    self.credential_renew_after = settings.credential_renew_after
    self.credential_rejected_at = settings.credential_rejected_at
    self.install_id = settings.install_id or self.install_id
    self.pairing_state = settings.pairing
    self.settings_schema_version = settings.settings_schema_version
    -- Lo que sigue es estado de una cuenta concreta. Se refleja acá para que
    -- un logout o un cambio de cuenta lo borren de memoria y no sólo del
    -- archivo: si no, el primer sync posterior lo volvería a escribir.
    if settings.synced_books then self.synced_books = settings.synced_books end
    if settings.annotation_v2_bridged then
        self.annotation_v2_bridged = settings.annotation_v2_bridged
    end
    if settings.last_web_sync then self.last_web_sync = settings.last_web_sync end
    if settings.last_progress_sync then
        self.last_progress_sync = settings.last_progress_sync
    end
    if settings.last_stats_sync then self.last_stats_sync = settings.last_stats_sync end
    if settings.last_stats_enqueued_at then
        self.last_stats_enqueued_at = settings.last_stats_enqueued_at
    end
    self.last_stats_error = settings.last_stats_error
    if settings.device_id then self.device_id = settings.device_id end
    if settings.last_full_sync then self.last_full_sync = settings.last_full_sync end
    if settings.position_undo then
        self.position_undo_entries = settings.position_undo
        if self.position_undo then
            self.position_undo.entries = self.position_undo_entries
        end
    end
end

function HighlightsDeToto:_currentSettings()
    return {
        dropbox_path = self.dropbox_path,
        dropbox = DropboxApi:getSettings(),
        web_url = self.web_url,
        server_base_url = self.server_base_url,
        web_api_key = self.web_api_key,
        device_token = self.device_token,
        device_credential_id = self.device_credential_id,
        paired_device_id = self.paired_device_id,
        account_username = self.account_username,
        credential_expires_at = self.credential_expires_at,
        credential_renew_after = self.credential_renew_after,
        credential_rejected_at = self.credential_rejected_at,
        install_id = self.install_id,
        pairing = self.pairing_state,
        settings_schema_version = self.settings_schema_version,
        auto_sync = self.auto_sync,
        auto_pull_highlights = self.auto_pull_highlights,
        auto_pull_progress = self.auto_pull_progress,
        force_sync_before_sleep = self.force_sync_before_sleep,
        wifi_only_to_sync = self.wifi_only_to_sync == true or nil,
        wifi_only_to_sync_note = self.wifi_only_to_sync_note,
        reading_spans = self.reading_spans_enabled == false and false or nil,
        capture_nav_cause = self.capture_nav_cause == false and false or nil,
        capture_attention = self.capture_attention == false and false or nil,
        capture_device_state = self.capture_device_state == false and false or nil,
        footer_time_left = self.footer_time_left == false and false or nil,
        position_text_capture = self.position_text_capture == false and false or nil,
        wifi_quiet_misses = (self.wifi_quiet_misses or 0) > 0 and self.wifi_quiet_misses or nil,
        last_web_sync = self.last_web_sync,
        synced_books = self.synced_books,
        annotation_v2_bridged = self.annotation_v2_bridged,
        device_id = self.device_id,
        last_progress_sync = self.last_progress_sync,
        last_stats_sync = self.last_stats_sync,
        last_stats_enqueued_at = self.last_stats_enqueued_at,
        last_stats_error = self.last_stats_error,
        library_download_dir = self.library_download_dir,
        auto_check_plugin_updates = self.auto_check_plugin_updates,
        last_plugin_update_check = self.last_plugin_update_check,
        plugin_update_attempt_at = self.plugin_update_attempt_at,
        plugin_update_failures = self.plugin_update_failures,
        pending_update = self.pending_update,
        pending_update_notified = self.pending_update_notified,
        installed_update = self.installed_update,
        last_full_sync = self.last_full_sync,
        position_undo = self.position_undo_entries,
    }
end

--- Save only sync state (fast, no config file writes).
-- Con `lazy` el cambio queda en memoria y lo escribe el proximo guardado de
-- ajustes de KOReader (al suspender, al cerrar el libro o en su autoguardado).
-- Es para lo que solo son horarios de "ultima sincronizacion": perderlos en un
-- corte cuesta, como mucho, repetir una comparacion. Credenciales, cuenta y
-- configuracion siguen escribiendose en el momento.
--
-- Guardar algo que no cambio no escribe nada. `G_reader_settings:flush()`
-- reescribe TODOS los ajustes de KOReader (24 KB en un lector real) y se
-- llamaba en cada arranque del plugin -o sea, cada vez que se abre o cierra un
-- libro- aunque no hubiera nada nuevo. La comparacion es por contenido: varias
-- de estas tablas se modifican en el lugar, asi que comparar referencias diria
-- "igual" de algo que si cambio.
-- @param only_if_migrated boolean (el arranque) guardar solo si cargar los
-- ajustes les cambio algo; lo que otra instancia dejo sin forzar sigue asi.
function HighlightsDeToto:saveSyncState(lazy, only_if_migrated)
    self._sync_state_dirty = false
    local settings = self:_currentSettings()
    local digest = AnnotationAdapter.stableEncode(settings)
    if only_if_migrated and digest == self._loaded_settings_digest then return end
    if digest ~= Shared.settings_saved then
        G_reader_settings:saveSetting("highlightsdetoto", settings)
        Shared.settings_saved = digest
    end
    if not lazy and digest ~= Shared.settings_flushed then
        G_reader_settings:flush()
        Shared.settings_flushed = digest
    end
end

--- Save settings + config files (use when config values changed).
function HighlightsDeToto:saveSettings()
    self:saveSyncState()
    self:saveConfigFile()
    self:saveWebConfigFile()
end

function HighlightsDeToto:isWebConfigured()
    return self:getBaseUrl() ~= "" and self:getWebAuth() ~= nil
end

function HighlightsDeToto:_flushDiagnostics()
    pcall(function()
        if self._closed or not self.diagnostics then return end
        self.diagnostics:scope(self.paired_device_id)
        if NetworkMgr:isConnected() and self.device_token then
            local api, base_url, auth = self:getApi(), self:getBaseUrl(), self:getWebAuth()
            self.diagnostics:flush(function(payload, done)
                require('diagnosticstransport').send(function()
                    local result = api:postJSON(base_url .. '/api/health/outcomes', auth, payload, true)
                    return result and result.accepted == true
                end, done)
            end)
            if #self.diagnostics.state.pending > 0 and not self._diagnostic_retry then
                self._diagnostic_retry = function()
                    self._diagnostic_retry = nil
                    self:_flushDiagnostics()
                end
                UIManager:scheduleIn(math.max(60, self.diagnostics.retry_at - os.time()), self._diagnostic_retry)
            end
        end
    end)
end

function HighlightsDeToto:_recordOperationOutcome(operation, success, err)
    pcall(function()
        if not self.diagnostics then return end
        self.diagnostics:scope(self.paired_device_id)
        if not NetworkMgr:isConnected() then return end
        self.diagnostics:record(operation, success, err, require('plugin_version'))
        UIManager:scheduleIn(2, function() self:_flushDiagnostics() end)
    end)
end

function HighlightsDeToto:toggleDiagnostics()
    if self.diagnostics then self.diagnostics:setEnabled(not self.diagnostics:isEnabled()) end
end

function HighlightsDeToto:getWebAuth()
    if self.device_token and self.device_token ~= "" then
        return { token = self.device_token }
    end
    if self.web_api_key and self.web_api_key ~= "" then
        return { api_key = self.web_api_key }
    end
    return nil
end

--- Derive the base URL from the sync URL.
-- e.g., "https://borges.runadev.com/api/sync" -> "https://borges.runadev.com"
function HighlightsDeToto:getBaseUrl()
    if self.server_base_url and self.server_base_url ~= "" then
        return self.server_base_url:gsub("/+$", "")
    end
    if self.web_url and self.web_url ~= "" then
        return SettingsMigration.normalizeBaseUrl(self.web_url)
    end
    return ""
end

function HighlightsDeToto:getSyncBookUrl()
    local sync_base = self.web_url and self.web_url:match("^(.-/api/sync)") or nil
    sync_base = sync_base or (self:getBaseUrl() .. "/api/sync")
    return sync_base .. "/book?book_hash=" .. util.urlEncode(self.book_hash)
end

function HighlightsDeToto:getLibraryBooksUrl()
    return self:getBaseUrl() .. "/api/library/plugin/books"
end

function HighlightsDeToto:getLibraryDownloadDir()
    return self.library_download_dir or DEFAULT_LIBRARY_DIR
end

-- ============================================================
-- Plugin Updates
-- ============================================================

function HighlightsDeToto:getPluginVersion()
    if self.updater then
        return tostring(self.updater:getCurrentVersion())
    end
    return "0.0.0"
end

--- Búsqueda manual. Es una orden del lector: puede pedir el Wi-Fi, saltea el
-- intervalo y el backoff, y siempre contesta algo.
function HighlightsDeToto:checkPluginUpdate(show_no_update)
    self:_keepWifi()
    self:_cancelBackgroundSync()
    if not self:isWebConfigured() then
        if show_no_update then
            self:showInfo(_("Sign in to your account first."), 5)
        end
        return
    end
    self:ensureNetwork(function()
        self:_runPluginUpdateCheck({ manual = true, report = show_no_update ~= false })
    end)
end

--- Chequeo automático. Nunca prende la radio, nunca bloquea nada y nunca
-- pregunta dos veces seguidas: si `UpdateCheck` dice que no, no pasa nada.
-- @param reason string de dónde vino, sólo para el log
function HighlightsDeToto:_maybeCheckPluginUpdate(reason)
    if self._closed then return false, "closed" end
    local plan = UpdateCheck.plan(self:_pluginUpdateCheckState(false))
    if not plan.allowed then
        logger.dbg("Borges: plugin update check skipped -",
            tostring(reason), plan.reason)
        return false, plan.reason
    end
    self:_runPluginUpdateCheck({ manual = false, reason = reason })
    return true
end

--- El estado que mira la política, armado en un solo lugar.
function HighlightsDeToto:_pluginUpdateCheckState(manual)
    return {
        enabled = self:isAutoUpdateCheckEnabled(),
        configured = self:isWebConfigured() and self.updater ~= nil,
        connected = NetworkMgr:isConnected(),
        running = self._plugin_update_check_running == true,
        manual = manual == true,
        now = os.time(),
        last_success_at = self.last_plugin_update_check,
        last_attempt_at = self.plugin_update_attempt_at,
        failures = self.plugin_update_failures,
    }
end

--- Preguntarle al servidor, una sola vez, sin quedarse esperando.
-- @param opts table {manual=bool, report=bool, reason=string}
function HighlightsDeToto:_runPluginUpdateCheck(opts)
    opts = opts or {}
    local plan = UpdateCheck.plan(self:_pluginUpdateCheckState(opts.manual))
    if not plan.allowed then
        if opts.report then
            self:showInfo(self:_describeUpdateCheckSkip(plan), 6)
        end
        return false, plan.reason
    end

    local progress = nil
    if opts.report then
        progress = self:showInfoPersist(_("Looking for a new version…"))
    end
    self._plugin_update_check_running = true

    local function run_check()
        local ok = self:_safecall("pluginUpdateCheck", function()
            local manifest, err = self.updater:fetchManifest()
            if progress then UIManager:close(progress) end
            self:_recordPluginUpdateCheck(manifest ~= nil)

            if not manifest then
                if opts.report then
                    self:showInfo(T(
                        _("Could not check for a new version: %1\nTry again when you have Wi-Fi."),
                        tostring(err or _("unknown error"))
                    ), 8)
                end
                return
            end

            -- C23 · Lo encontrado queda anotado antes de mostrar nada: el aviso
            -- tiene que seguir estando cuando el lector vuelva al menú, no sólo
            -- en el instante en que el chequeo automático corrió.
            self:_rememberPendingUpdate(manifest)

            if not self:hasPendingUpdate() then
                if opts.report then
                    self:showInfo(T(_("You already have the latest version (%1)."),
                        self:getPluginVersion()), 5)
                end
                return
            end

            if opts.manual then
                -- Pedirlo a mano es pedir la respuesta ahora, aunque esta
                -- versión ya se haya anunciado antes.
                self:_showPluginUpdateNotice(true)
            else
                -- El motivo viaja hasta acá: un chequeo disparado desde el
                -- menú puede avisar con el libro abierto, uno disparado por
                -- la red no.
                self:_announcePluginUpdate(opts.reason or "check")
            end
        end)
        -- La bandera se suelta pase lo que pase: un error acá no puede dejar
        -- el chequeo trabado hasta el próximo reinicio.
        self._plugin_update_check_running = false
        if not ok then
            if progress then UIManager:close(progress) end
            if opts.report then
                self:showInfo(_("Could not check for a new version. Try again from the menu."), 8)
            end
            self:_safecall("pluginUpdateCheckFailure", function()
                self:_recordPluginUpdateCheck(false)
            end)
        end
    end
    UIManager:nextTick(function()
        if opts.manual then run_check()
        else self:_runBackgroundSync("update", run_check) end
    end)
    return true
end

function HighlightsDeToto:_describeUpdateCheckSkip(plan)
    if plan.reason == UpdateCheck.NOT_CONFIGURED then
        return _("Sign in to your account first.")
    end
    if plan.reason == UpdateCheck.IN_FLIGHT then
        return _("Already looking for a new version.")
    end
    if plan.reason == UpdateCheck.OFFLINE then
        return _("Wi-Fi is needed to look for a new version.")
    end
    return _("It is not time to check again yet.")
end

--- Anotar cómo salió el intento. Un fallo mueve el reintento, nunca el día.
function HighlightsDeToto:_recordPluginUpdateCheck(succeeded)
    local anchors
    if succeeded then
        anchors = UpdateCheck.recordSuccess(nil, os.time())
    else
        anchors = UpdateCheck.recordFailure({
            last_success_at = self.last_plugin_update_check,
            last_attempt_at = self.plugin_update_attempt_at,
            failures = self.plugin_update_failures,
        }, os.time())
    end
    self.last_plugin_update_check = anchors.last_success_at
    self.plugin_update_attempt_at = anchors.last_attempt_at
    self.plugin_update_failures = anchors.failures
    self:saveSyncState()
end

--- El cartel informativo, una vez por versión y sólo en un momento seguro.
--
-- Seguro quiere decir: no encima de la lectura y no encima de la pregunta de
-- posición de C17. Si no se puede ahora, no se pierde nada: el indicador
-- «Actualización disponible» sigue en el menú y el cartel sale la próxima vez
-- que el lector entre al menú o cierre el libro.
function HighlightsDeToto:_announcePluginUpdate(reason)
    if self._closed then return false, "closed" end
    local allowed, why = self:_canAnnouncePluginUpdate(reason)
    if not allowed then
        logger.dbg("Borges: update notice held -", tostring(reason), why)
        return false, why
    end
    self:_showPluginUpdateNotice(false)
    return true
end

--- Los dos únicos momentos en que un cartel de versión no molesta: el menú
-- abierto y el explorador. Cualquier otro —una reconexión en medio de una
-- página, el resume después de suspender— deja el aviso para después: el
-- indicador del menú no se pierde y el lector lo encuentra cuando mira.
function HighlightsDeToto:_canAnnouncePluginUpdate(reason)
    if not self:hasPendingUpdate() then return false, "no_update" end
    if not UpdateCheck.shouldAnnounce({
        available = self:getPendingUpdateVersion(),
        current = self:getPluginVersion(),
        notified = self.pending_update_notified,
    }) then
        return false, "already_notified"
    end
    local menu = self.ui and self.ui.menu and self.ui.menu.menu_container
    local menu_visible = menu ~= nil and menu[1] ~= nil and not menu[1].not_shown
    return UpdateCheck.isSafeMoment({
        trigger = menu_visible and "menu" or (reason == "menu" and "check" or reason),
        book_open = self.book_hash ~= nil,
        resume_dialog = self.resume_flow ~= nil and self.resume_flow:isVisible(),
    })
end

--- Ver novedades · Actualizar · Más tarde.
-- @param forced boolean lo pidió el lector a mano
function HighlightsDeToto:_showPluginUpdateNotice(forced)
    local version = self:getPendingUpdateVersion()
    if not version then return end
    local text = T(
        _("There is a new version of Borges.\n\nYou have %1 and %2 is available.\n\nIt is downloaded and installed only if you ask for it."),
        self:getPluginVersion(),
        version
    )
    UIManager:show(MultiConfirmBox:new{
        text = text,
        choice1_text = _("What's new"),
        choice1_callback = function()
            self:_showPluginUpdateNotes(version)
        end,
        choice2_text = _("Update"),
        choice2_callback = function()
            self:installPendingUpdate()
        end,
        cancel_text = forced and _("Close") or _("Later"),
    })
    -- Persist only after the widget was shown; rendering errors must allow retry.
    self.pending_update_notified = version
    self:saveSyncState()
end

--- Las novedades, y desde ahí la misma decisión.
--
-- MultiConfirmBox se cierra con cualquier botón, así que mostrar el detalle y
-- volver a preguntar es un segundo diálogo, no uno encima del otro.
function HighlightsDeToto:_showPluginUpdateNotes(version)
    local pending = self.pending_update
    local notes = type(pending) == "table" and optionalString(pending.notes) or nil
    local body = notes or _("This version has no release notes.")
    UIManager:show(MultiConfirmBox:new{
        text = T(_("What's new in version %1\n\n%2"), version, body),
        choice1_text = _("Update"),
        choice1_callback = function()
            self:installPendingUpdate()
        end,
        choice2_text = _("Later"),
        cancel_text = _("Close"),
    })
end

function HighlightsDeToto:confirmPluginUpdate(manifest)
    local current = self:getPluginVersion()
    local target = manifest.version or _("unknown")
    UIManager:show(MultiConfirmBox:new{
        text = T(_("Download and install version %2?\n\nYou currently have %1."),
            current,
            target
        ),
        choice1_text = _("Install"),
        choice1_callback = function()
            self:installPluginUpdate(manifest)
        end,
        choice2_text = _("Later"),
    })
end

function HighlightsDeToto:installPluginUpdate(manifest)
    local progress = self:showInfoPersist(
        T(_("Downloading and preparing version %1…"),
            manifest.version or _("new"))
    )
    UIManager:nextTick(function()
        self:_safecall("pluginUpdateInstall", function()
        local ok, err = self.updater:install(manifest)
        UIManager:close(progress)

        if not ok then
            self:showInfo(T(
                _("Could not install version %1: %2\n\nThe plugin kept working with the previous version. You can try again from the menu."),
                manifest.version or _("new"),
                err or _("unknown error")
            ), 12)
            return
        end

        -- Instalada: deja de ser una versión pendiente aunque el reinicio
        -- todavía no haya ocurrido. Hasta reiniciar, KOReader sigue corriendo
        -- la de antes, y el menú lo dice con esas palabras.
        self.pending_update = nil
        self.pending_update_notified = nil
        self.installed_update = {
            version = manifest.version,
            installed_at = os.time(),
        }
        self:saveSyncState()

        local message = T(
            _("Version %1 was installed.\nRestart KOReader to start using it."),
            manifest.version or _("new")
        )
        if UIManager.askForRestart then
            UIManager:askForRestart(message)
        else
            self:showInfo(message, 12)
        end
        end)
    end)
end

function HighlightsDeToto:confirmPluginRollback()
    if not self.updater or not self.updater:hasRollback() then
        self:showInfo(_("No plugin rollback is available."), 5)
        return
    end
    local target = self.updater:getRollbackVersion() or _("previous version")
    UIManager:show(MultiConfirmBox:new{
        text = T(
            _("Restore plugin version %1 and restart KOReader?"),
            target
        ),
        choice1_text = _("Restore"),
        choice1_callback = function()
            self:rollbackPluginUpdate()
        end,
        choice2_text = _("Cancel"),
    })
end

function HighlightsDeToto:rollbackPluginUpdate()
    local progress = self:showInfoPersist(_("Restoring previous plugin version..."))
    UIManager:nextTick(function()
        self:_safecall("pluginUpdateRollback", function()
            local ok, err = self.updater:rollback()
            UIManager:close(progress)
            if not ok then
                self:showInfo(
                    T(_("Plugin rollback failed: %1"), err or _("unknown error")),
                    10
                )
                return
            end
            local message = _("Previous plugin version restored. Restart KOReader to load it.")
            if UIManager.askForRestart then
                UIManager:askForRestart(message)
            else
                self:showInfo(message, 12)
            end
        end)
    end)
end

-- ============================================================
-- UI Helpers
-- ============================================================

function HighlightsDeToto:showInfo(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 3,
    })
end

function HighlightsDeToto:_closeSyncProgress()
    if self._sync_progress then
        UIManager:close(self._sync_progress)
        self._sync_progress = nil
    end
end

function HighlightsDeToto:_showSyncProgress(text)
    self:_closeSyncProgress()
    self._sync_progress = ProgressMessage:new{ text = text }
    UIManager:show(self._sync_progress)
end

function HighlightsDeToto:showInfoPersist(text)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    return msg
end

function HighlightsDeToto:_closeSuspendSyncBanner()
    if self.suspend_sync_banner then
        UIManager:close(self.suspend_sync_banner)
        self.suspend_sync_banner = nil
    end
end

function HighlightsDeToto:_showSuspendSyncBanner(text)
    self:_closeSuspendSyncBanner()
    self.suspend_sync_banner = SuspendSyncBanner:new{
        text = text,
    }
    UIManager:show(self.suspend_sync_banner)
    UIManager:forceRePaint()
end

function HighlightsDeToto:_showSuspendSyncStatus()
    if not self:isWebConfigured() then return end
    -- El cartel es para el protector de pantalla y nada mas: ocupa toda la
    -- pantalla y solo lo saca onResume. Con el libro abierto (la persona apago
    -- el Wi-Fi desde el menu) quedaba arriba de la pila de widgets y se tragaba
    -- cada toque hasta el proximo despertar: el lector parecia colgado.
    if Device.screen_saver_mode ~= true then return end

    local pending = self.queue:count()
    if pending == 0 then
        self:_showSuspendSyncBanner(_("Everything synced."))
    else
        self:_showSuspendSyncBanner(T(_("Not everything was synced. %1 pending."), pending))
    end
end

function HighlightsDeToto:ensureNetwork(callback)
    self:_keepWifi()
    if NetworkMgr:isConnected() then
        callback()
    else
        NetworkMgr:promptWifiOn(function()
            callback()
        end)
    end
end

--- Get a human-readable sync status text for the menu.
function HighlightsDeToto:getSyncStatusText()
    local pending = self.queue:count()
    if pending > 0 then
        return T(_("%1 pending"), pending)
    end
    if self.last_progress_sync and self.last_progress_sync > 0 then
        local ago = os.time() - self.last_progress_sync
        if ago < 60 then
            return _("OK (just now)")
        elseif ago < 3600 then
            return T(_("OK (%1 min ago)"), math.floor(ago / 60))
        else
            return T(_("OK (%1 h ago)"), math.floor(ago / 3600))
        end
    end
    return _("Not synced yet")
end

-- ============================================================
-- Menu
-- ============================================================

--- KOReader caches the menu tree; dynamic labels run when entries are displayed.
function HighlightsDeToto:addToMainMenu(menu_items)
    local entry = MenuTree.build(self, { gettext = _, template = T })
    local label = entry.text
    entry.text = nil
    entry.text_func = function()
        if not self._update_menu_tick_pending then
            self._update_menu_tick_pending = true
            UIManager:nextTick(function()
                self._update_menu_tick_pending = nil
                -- Labels are also evaluated by menu search and hidden builds.
                local menu = self.ui and self.ui.menu and self.ui.menu.menu_container
                if not menu or not menu[1] or menu[1].not_shown then return end
                self:_safecall("menuUpdateCheck", function()
                    self:_announcePluginUpdate("menu")
                    self:_maybeCheckPluginUpdate("menu")
                end)
            end)
        end
        return label
    end
    menu_items.highlightsdetoto = entry
end

-- ============================================================
-- C07 · Lo que el menú necesita saber del plugin
--
-- MenuTree arma el árbol pero no sabe nada del estado: pregunta. Todo lo que
-- sigue son respuestas cortas, pensadas para que la etiqueta diga algo cierto
-- incluso cuando no hay red, no hay sesión o hay una corrida en curso.
-- ============================================================

function HighlightsDeToto:hasCredential()
    return self.device_token ~= nil
end

function HighlightsDeToto:hasAccountAccess()
    return self:isWebConfigured()
end

function HighlightsDeToto:getPairingLabel()
    if self.pairing_state then
        return T(_("Continue with code %1"), self.pairing_state.user_code or "")
    end
    return _("Pair with a code")
end

function HighlightsDeToto:canPair()
    return self.device_token == nil or self.pairing_state ~= nil
end

function HighlightsDeToto:startOrResumePairing()
    self:_keepWifi()
    if self.pairing_state and os.time() >= (self.pairing_state.requested_at or 0)
        + (self.pairing_state.expires_in or 300) then
        self.pairing:stopWatching()
        self.pairing_state = nil
        self:saveSyncState()
    end
    if self.pairing_state then
        self:resumeDevicePairing(true)
    else
        self:startDevicePairing(true)
    end
end

function HighlightsDeToto:isSyncRunning()
    if self._background_sync and self._background_sync:isRunning() then return true end
    return self.sync_run ~= nil and self.sync_run:isRunning()
end

function HighlightsDeToto:getUnifiedSyncLabel()
    if self:isSyncRunning() then return _("Syncing…") end
    local pending = self.queue:count()
    if pending > 0 then
        return T(_("Sync now (%1 not sent)"), pending)
    end
    return _("Sync now")
end

--- Los pasos de la operación única, en el orden en que importan.
--
-- Primero se guarda en disco todo lo que se generó leyendo — anotaciones,
-- posición, estadísticas —, porque eso funciona sin red y es lo que hace que
-- un corte no borre el día. Recién después se habla con el servidor. El
-- intercambio va último para que arrastre lo que acaban de dejar los pasos
-- anteriores.
function HighlightsDeToto:_buildSyncPlan()
    local plugin = self
    return {
        connected = self:isWebConfigured(),
        online = NetworkMgr:isConnected(),
        pending = function() return plugin.queue:count() end,
        steps = {
            {
                id = "annotations",
                label = _("Saving your highlights and notes"),
                offline = true,
                run = function()
                    if not plugin.book_hash then return {} end
                    plugin:syncHighlightsDelta(true)
                    return {}
                end,
            },
            {
                id = "position",
                label = _("Saving where you are"),
                offline = true,
                run = function()
                    if not plugin.book_hash then return {} end
                    plugin:_enqueueProgressV2(false)
                    return {}
                end,
            },
            {
                id = "stats",
                label = _("Saving your reading statistics"),
                offline = true,
                run = function()
                    plugin:syncPageStatsDelta(true, false, true)
                    return {}
                end,
            },
            {
                id = "reading_head",
                label = _("Checking where you last read"),
                run = function()
                    if not plugin.book_hash or not plugin.device_token then return {} end
                    return plugin:_pullRemoteNow()
                end,
            },
            {
                id = "library",
                label = _("Checking the other books"),
                run = function()
                    return plugin:_sweepChangedBooks()
                end,
            },
            {
                id = "legacy",
                label = _("Sending what was left from before"),
                run = function()
                    if plugin.queue:count() <= plugin.queue:v2Count() then
                        return {}
                    end
                    local result = plugin.queue:drain(
                        plugin:getApi(),
                        plugin:getBaseUrl(),
                        plugin:getWebAuth()
                    )
                    if result.sent > 0 then
                        local now = os.time()
                        plugin.last_web_sync = now
                        plugin.last_stats_sync = now
                        plugin.last_stats_error = nil
                        plugin:saveSyncState()
                    end
                    if result.failed > 0 and result.sent == 0 then
                        return nil, WebApi.apiError(
                            "legacy_queue_retained",
                            _("Could not send what was left from before."),
                            nil,
                            true
                        )
                    end
                    return { sent = result.sent }
                end,
            },
            {
                id = "exchange",
                label = _("Bringing this reader up to date"),
                run = function()
                    local result, err = plugin:_syncV2Now(false, 50, true)
                    if not result then return nil, err end
                    return {
                        sent = result.acknowledged,
                        received = result.received,
                        deferred = result.deferred,
                    }
                end,
            },
        },
    }
end

--- Barrido incremental de los libros que cambiaron desde la última vez.
-- Es el viejo "Sync all highlights to web" sin su cartel propio: acá informa
-- hacia arriba y el resumen único decide qué mostrar.
function HighlightsDeToto:_sweepChangedBooks()
    local payload, changed_count, _unused, new_synced, _skipped =
        HighlightParser:generateApiPayloadIncremental(self.synced_books)
    if not payload or (changed_count or 0) == 0 then return {} end

    local errors, _total_docs, total_entries = self:syncBatches(payload.documents)
    if #errors > 0 then
        return nil, WebApi.apiError(
            "books_partially_uploaded",
            T(_("Could not upload some books: %1"), errors[1]),
            nil,
            true
        )
    end
    self.synced_books = new_synced
    self.last_web_sync = os.time()
    self:saveSyncState()
    return { sent = total_entries or 0 }
end

--- La acción principal. Un solo toque hace todo; el segundo, mientras corre,
-- no hace nada — ni encola otra corrida ni la duplica.
function HighlightsDeToto:runUnifiedSync()
    self:_keepWifi()
    if self:isSyncRunning() then
        self:showInfo(_("Already syncing. Wait for it to finish."), 3)
        return
    end
    if not self:isWebConfigured() then
        self:showInfo(_("Sign in to your account to sync."), 5)
        return
    end

    local function execute()
        if self:isSyncRunning() then return end
        self:_runBackgroundSync("manual", function()
            self:_showSyncProgress(_("Syncing…"))
            Background.yieldToUI()
            local report = self.sync_run:run(self:_buildSyncPlan(), {
                on_progress = function(step)
                    self:_showSyncProgress(T(
                        _("%1\n(%2 of %3)"),
                        step.label, step.index, step.total
                    ))
                    Background.yieldToUI()
                end,
            })
            self:_closeSyncProgress()
            if report == nil then return end
            if report.status == SyncRun.SYNCED or report.status == SyncRun.FAILED
                or report.status == SyncRun.PARTIAL then
                self:_recordOperationOutcome('sync', report.status == SyncRun.SYNCED, report.error)
            end
            if SyncRun.isComplete(report) then
                self.last_full_sync = report.at
                self:saveSyncState()
            end
            self:showInfo(self:describeSyncReport(report), 10)
        end)
    end

    if NetworkMgr:isConnected() then
        execute()
        return
    end

    -- Sin red igual hay trabajo que hacer, y es instantáneo: guardar lo de hoy.
    -- Va primero y solo; recién con su respuesta en pantalla ofrecemos prender
    -- el Wi-Fi, para no encimar dos diálogos en tinta electrónica. Rechazar el
    -- Wi-Fi deja al lector con una respuesta cierta, no con silencio.
    execute()
    UIManager:scheduleIn(1, function()
        if NetworkMgr:isConnected() then return end
        NetworkMgr:promptWifiOn(function()
            self:_safecall("unifiedSyncOnline", execute)
        end)
    end)
end

function HighlightsDeToto:describeSyncReport(report)
    local plugin = self
    return SyncRun.describe(report, {
        gettext = _,
        template = T,
        last_success = self.last_full_sync,
        describe_time = function(epoch) return plugin:_describeTimeAgo(epoch) end,
    })
end

function HighlightsDeToto:_describeTimeAgo(epoch)
    local seconds = os.time() - (tonumber(epoch) or 0)
    if seconds < 60 then return _("just now") end
    if seconds < 3600 then
        return T(_("%1 min ago"), math.floor(seconds / 60))
    end
    if seconds < 86400 then
        return T(_("%1 h ago"), math.floor(seconds / 3600))
    end
    return os.date("%d/%m %H:%M", epoch)
end

-- ============================================================
-- C07 · Estado, en una línea y en detalle
-- ============================================================

function HighlightsDeToto:getSyncSummaryLabel()
    local state = self:getConnectionState()
    if state ~= SettingsMigration.CONNECTION_CONNECTED then
        return _("Status: no account connected")
    end
    local pending = self.queue:count()
    if pending > 0 then
        return T(_("Status: %1 not sent"), pending)
    end
    if self.last_full_sync and self.last_full_sync > 0 then
        return T(_("Status: up to date (%1)"), self:_describeTimeAgo(self.last_full_sync))
    end
    return _("Status: not synced yet")
end

function HighlightsDeToto:showSyncStatusDetail()
    local lines = {}
    table.insert(lines, self:getConnectionLabel())

    local pending = self.queue:count()
    if pending > 0 then
        table.insert(lines, T(_("Not sent: %1"), pending))
    else
        table.insert(lines, _("Not sent: nothing"))
    end
    if self.queue:inboxCount() > 0 then
        table.insert(lines, T(_("Waiting for the open book: %1"), self.queue:inboxCount()))
    end
    if self.queue:rejectedCount() > 0 then
        table.insert(lines, T(_("Rejected by the server: %1"), self.queue:rejectedCount()))
    end
    -- F5 · Que paso con los rechazos y con lo recibido que no entro.
    local rejections = self.queue.rejectionSummary and self.queue:rejectionSummary() or {}
    if rejections.last_code then
        table.insert(lines, T(_("Last rejection: %1"), rejections.last_code))
    end
    if (rejections.pending_reemit or 0) > 0 then
        table.insert(lines, T(_("Will be sent again: %1"), rejections.pending_reemit))
    end
    local dropped = self.queue.inboxDroppedCount and self.queue:inboxDroppedCount() or 0
    if dropped > 0 then
        table.insert(lines, T(_("Received changes dropped (inbox full): %1"), dropped))
    end
    local skew = self.queue.getClockSkew and self.queue:getClockSkew()
    if skew and math.abs(skew) >= 300 then
        table.insert(lines, T(_("This reader's clock is off by %1 minutes."), math.floor(math.abs(skew) / 60 + 0.5)))
    end
    if self.last_full_sync and self.last_full_sync > 0 then
        table.insert(lines, T(_("Last complete sync: %1"),
            self:_describeTimeAgo(self.last_full_sync)))
    else
        table.insert(lines, _("Last complete sync: none yet"))
    end
    if self.last_stats_error then
        table.insert(lines, T(_("Statistics: %1"), self.last_stats_error))
    end
    local last_error = self.queue:getLastError()
    if last_error then
        table.insert(lines, T(_("Last problem: %1"), last_error.message or last_error.code))
        if last_error.request_id then
            table.insert(lines, T(_("Support reference: %1"), last_error.request_id))
        end
    end
    for _index, line in ipairs(self:_updateStatusLines()) do
        table.insert(lines, line)
    end
    self:showInfo(table.concat(lines, "\n"), 12)
end

--- Qué decir sobre la versión, en Estado y en Ayuda. Tres situaciones
-- distintas, tres frases distintas: hay una nueva, ya se instaló y falta
-- reiniciar, o estás al día.
function HighlightsDeToto:_updateStatusLines()
    local lines = {}
    if self:hasPendingUpdate() then
        table.insert(lines, T(_("New version available: %1"), self:getPendingUpdateVersion()))
        table.insert(lines, _("Install it from the Borges menu."))
    elseif self:hasUpdatePendingRestart() then
        table.insert(lines, T(_("Version %1 was installed."), self:getInstalledUpdateVersion()))
        table.insert(lines, T(_("Version %1 is still running: restart KOReader."),
            self:getPluginVersion()))
    else
        table.insert(lines, _("The plugin is up to date."))
    end
    if (self.plugin_update_failures or 0) > 0 then
        table.insert(lines, T(_("The last update check failed %1 time(s) in a row."),
            self.plugin_update_failures))
    end
    return lines
end

--- Ayuda y datos de este lector. C23 le suma la búsqueda manual: es el lugar
-- donde alguien mira cuando quiere saber si está al día, y no tiene por qué
-- conocer Avanzado para preguntarlo.
-- ============================================================
-- C13 - Reportar un problema desde el lector
--
-- Un Kobo no es donde se escribe un reporte: el teclado en tinta electronica
-- tarda un segundo por letra y el refresco de pantalla castiga cada correccion.
-- Asi que el lector NO pide que se redacte nada aca. Muestra tres cosas y se
-- corre: la direccion del formulario, para abrirla en el telefono; el codigo de
-- soporte, para que quien lea el reporte sepa de que aparato vino; y la version
-- instalada, que es lo primero que hay que saber de un problema.
--
-- El codigo sale del install_id, que ya existe y ya identifica a esta
-- instalacion. No es una credencial: no abre nada y no sirve para entrar.
-- ============================================================

function HighlightsDeToto:getSupportUrl()
    local base = self:getBaseUrl()
    if base == "" then return "https://borges.runadev.com/ayuda" end
    return base .. "/ayuda"
end

function HighlightsDeToto:getSupportCode()
    local id = tostring(self.install_id or "")
    local clean = id:gsub("[^0-9a-fA-F]", "")
    if clean == "" then return _("no code yet") end
    return "KO-" .. clean:sub(-6):upper()
end

function HighlightsDeToto:showSupportHelp()
    local lines = {
        _("Something not working? Tell us from your phone."),
        "",
        self:getSupportUrl(),
        "",
        T(_("Support code: %1"), self:getSupportCode()),
        T(_("Plugin version: %1"), self:getPluginVersion()),
        _("Copy those two details into the form; that is all it takes."),
    }
    self:showInfo(table.concat(lines, "\n"), 20)
end

function HighlightsDeToto:showAbout()
    local lines = {
        T(_("Borges for KOReader %1"), self:getPluginVersion()),
        self:getConnectionLabel(),
        T(_("Server: %1"), self:getBaseUrl()),
        T(_("Name of this reader: %1"), self.device_id),
        T(_("Support code: %1"), self:getSupportCode()),
        "",
    }
    for _index, line in ipairs(self:_updateStatusLines()) do
        table.insert(lines, line)
    end
    table.insert(lines, "")
    table.insert(lines, T(_("To report a problem: %1"), self:getSupportUrl()))
    table.insert(lines, _("Open it on your phone: typing here is awkward and unnecessary."))
    table.insert(lines, _("Never share your password or the contents of web_config.json."))
    UIManager:show(ConfirmBox:new{
        text = table.concat(lines, "\n"),
        ok_text = _("Check for updates"),
        ok_callback = function()
            self:checkPluginUpdate(true)
        end,
        cancel_text = _("Close"),
    })
end

-- ============================================================
-- C07 · El único ajuste simple
--
-- Antes había tres interruptores — "Auto-sync highlights (daily)",
-- "Auto-pull highlights for open book" y "Force sync before sleep" — que
-- describían partes internas del mismo comportamiento. El lector no elige
-- entre ellas: elige si el plugin trabaja solo o no. Los tres campos siguen
-- existiendo y siguen gobernando sus guardas; lo que cambió es quién los mueve.
-- ============================================================

function HighlightsDeToto:isAutoSyncEnabled()
    return self.auto_sync == true
end

function HighlightsDeToto:toggleAutoSync()
    local enabled = not self:isAutoSyncEnabled()
    self.auto_sync = enabled
    self.auto_pull_highlights = enabled
    self.auto_pull_progress = enabled
    self.force_sync_before_sleep = enabled
    self:saveSyncState()
end

-- ============================================================
-- C07 · Volver a donde estabas
-- ============================================================

function HighlightsDeToto:canJumpToRemotePosition()
    return self.book_hash ~= nil and self:isWebConfigured()
end

function HighlightsDeToto:_currentPositionSnapshot()
    local page = self.ui and self.ui.getCurrentPage and self.ui:getCurrentPage()
    return {
        page = page,
        xpointer = self:_getXPointer(),
        percentage = self:_calcLocalPercentage(),
        chapter = page and self:_getChapterTitleForPage(page) or nil,
        occurred_at = self._reading_activity_at,
        time_precision = self._reading_activity_at and "exact" or "unknown",
    }
end

--- Traer la posición de otro dispositivo. Siempre pregunta, y el "sí" guarda
-- primero el punto de retorno: sin eso, un salto a una posición vieja te deja
-- sin forma de volver.
function HighlightsDeToto:confirmRemotePositionJump()
    if not self.book_hash then return end

    self:ensureNetwork(function()
        local url = self:getBaseUrl() .. "/api/progress?book_hash=" .. self.book_hash
        local result, err = self:getApi():getJSON(url, self:getWebAuth())
        if not result then
            self:showInfo(
                (err and (err.message or err.code))
                    or _("Could not read the position saved in the cloud."),
                6
            )
            return
        end

        local candidate, source
        for _, device in ipairs(result.devices or {}) do
            if device.device_id ~= self.device_id then
                candidate, source = device, device.device_id
                break
            end
        end
        if not candidate and result.latest then
            candidate = result.latest
            source = result.latest.device_id
        end
        if not candidate then
            self:showInfo(_("There is no saved position from another device yet."), 5)
            return
        end

        -- Pedirlo desde el menú es explícito: una respuesta anterior no puede
        -- dejar al lector sin nada en pantalla, así que va con `force`.
        candidate.time_precision = candidate.time_precision or "anchored"
        local offered, reason = self:_offerRemotePosition({
            remote = candidate,
            source = { id = source, name = candidate.device_name },
            others = result.devices,
            force = true,
        })
        if not offered then
            if reason == ResumeFlow.ALREADY_VISIBLE then
                self:showInfo(_("A position notice is already open."), 4)
            elseif reason == ResumeFlow.NO_LOCATOR then
                self:showInfo(_("The saved position does not say where it falls in this book."), 6)
            else
                self:showInfo(_("There is no different position to offer."), 5)
            end
        end
    end)
end

function HighlightsDeToto:canUndoPositionJump()
    return self.book_hash ~= nil
        and self.position_undo ~= nil
        and self.position_undo:has(self.book_hash)
end

function HighlightsDeToto:getUndoJumpLabel()
    local entry = self.book_hash and self.position_undo
        and self.position_undo:get(self.book_hash)
    if entry and entry.page then
        return T(_("Go back to p. %1"), entry.page)
    end
    return _("Go back to where you were")
end

function HighlightsDeToto:undoPositionJump()
    local entry = self.position_undo and self.position_undo:take(self.book_hash)
    if not entry then
        self:showInfo(_("There is nowhere to go back to."), 4)
        return
    end
    local navigated = self:_navigateToProgress({
        xpointer = entry.xpointer,
        current_page = entry.page,
        percentage = entry.percentage,
    }, true)
    if not navigated then
        self:showInfo(_("Could not go back to that position."), 6)
        return
    end
    self:showInfo(T(_("You are back on p. %1."), self.ui:getCurrentPage()), 4)
    UIManager:scheduleIn(2, function()
        self:_safecall("pushProgress", function() self:pushProgress(false, true) end)
    end)
end

-- ============================================================
-- C07 · Avanzado
-- ============================================================

function HighlightsDeToto:getDeviceIdLabel()
    return T(_("Name of this reader: %1"), self.device_id)
end

function HighlightsDeToto:getServerLabel()
    local base = self:getBaseUrl()
    if base == "" then return _("Server: not configured") end
    return T(_("Server: %1"), base)
end

function HighlightsDeToto:hasQueuedWork()
    return self.queue:count() > 0
end

function HighlightsDeToto:getQueueLabel()
    local pending = self.queue:count()
    if pending > 0 then
        return T(_("Save a copy of pending changes (%1)"), pending)
    end
    return _("Save a copy of pending changes")
end

function HighlightsDeToto:exportPendingQueue(interactive)
    local path, err = self:_exportPendingQueue()
    if not interactive then return path, err end
    if path then
        self:showInfo(T(_("Copy saved to:\n%1"), path), 8)
    else
        self:showInfo(T(_("Could not save the copy: %1"), tostring(err)), 8)
    end
    return path, err
end

--- Vaciar la cola destruye trabajo sin enviar. Sigue existiendo porque a veces
-- es la única salida, pero ahora ofrece la copia antes y no vive en el
-- recorrido normal.
function HighlightsDeToto:confirmClearQueue()
    local pending = self.queue:count()
    if pending == 0 then return end
    UIManager:show(MultiConfirmBox:new{
        text = T(
            _("There are %1 unsent change(s). Discarding them cannot be undone."),
            pending
        ),
        choice1_text = _("Save a copy"),
        choice1_callback = function()
            local path = self:exportPendingQueue(true)
            if path then self.queue:clear() end
        end,
        choice2_text = _("Discard"),
        choice2_callback = function()
            self.queue:clear()
            self:showInfo(_("Done. The queue is empty."), 4)
        end,
    })
end

function HighlightsDeToto:canRollbackPlugin()
    return self.updater ~= nil and self.updater:hasRollback()
end

function HighlightsDeToto:getRollbackLabel()
    local version = self.updater and self.updater:getRollbackVersion()
    if version then
        return T(_("Go back to version %1"), version)
    end
    return _("Go back to the previous version")
end

function HighlightsDeToto:isAutoUpdateCheckEnabled()
    return self.auto_check_plugin_updates == true
end

function HighlightsDeToto:toggleAutoUpdateCheck()
    self.auto_check_plugin_updates = not self:isAutoUpdateCheckEnabled()
    self:saveSyncState()
end

-- ============================================================
-- C23 · La versión nueva se ve donde el lector ya mira
--
-- El chequeo automático corría en silencio y, si el lector no estaba mirando
-- la pantalla en ese segundo, el aviso se perdía hasta el próximo intervalo.
-- Ahora la versión encontrada queda anotada y se ve en el menú de siempre y en
-- Ayuda. En Avanzado queda sólo lo que es diagnóstico: buscar a mano y volver
-- atrás.
-- ============================================================

function HighlightsDeToto:hasPendingUpdate()
    return self:getPendingUpdateVersion() ~= nil
end

function HighlightsDeToto:getPendingUpdateVersion()
    local pending = self.pending_update
    if type(pending) ~= "table" then return nil end
    local version = optionalString(pending.version)
    if version == nil or version == "" then return nil end
    -- Una actualización ya instalada, o una versión que no supera a la que
    -- corre, deja de ser noticia.
    if UpdateCheck.compareVersions(version, self:getPluginVersion()) <= 0 then
        return nil
    end
    return version
end

--- Una versión ya instalada en disco pero todavía no cargada por KOReader.
-- Mientras esto sea verdad, `getPluginVersion()` sigue diciendo la vieja: es
-- la que está corriendo, y decir la otra sería mentirle al lector.
function HighlightsDeToto:hasUpdatePendingRestart()
    local installed = self.installed_update
    if type(installed) ~= "table" then return false end
    local version = optionalString(installed.version)
    if version == nil or version == "" then return false end
    if version == self:getPluginVersion() then
        -- Ya reinició: la instalada y la cargada son la misma.
        self.installed_update = nil
        self:saveSyncState()
        return false
    end
    return true
end

function HighlightsDeToto:getInstalledUpdateVersion()
    if not self:hasUpdatePendingRestart() then return nil end
    return self.installed_update.version
end

--- Lo que dice la entrada de actualización del menú Borges.
function HighlightsDeToto:getUpdateEntryLabel()
    local pending = self:getPendingUpdateVersion()
    if pending then
        return T(_("Update available: %1"), pending)
    end
    local installed = self:getInstalledUpdateVersion()
    if installed then
        return T(_("Restart KOReader to use version %1"), installed)
    end
    return T(_("Installed version: %1"), self:getPluginVersion())
end

function HighlightsDeToto:hasUpdateEntry()
    return self:hasPendingUpdate() or self:hasUpdatePendingRestart()
end

--- Anotar lo que contestó el servidor.
--
-- Se guarda lo justo para poder mostrar el aviso y las novedades sin red: el
-- manifiesto completo no se conserva porque se vuelve a pedir al instalar, y
-- uno viejo apuntaría a hashes que el servidor ya no sirve.
function HighlightsDeToto:_rememberPendingUpdate(manifest)
    local previous = self:getPendingUpdateVersion()
    if type(manifest) ~= "table" or not manifest.update_available
        or not Updater.isStableVersion(manifest.version) then
        self.pending_update = nil
    else
        self.pending_update = {
            version = manifest.version,
            release_id = optionalString(manifest.release_id),
            notes = optionalString(manifest.release_notes),
            found_at = os.time(),
        }
    end
    local current = self:getPendingUpdateVersion()
    if current ~= previous then
        -- Otra versión es otra noticia: la respuesta anterior no la cubre.
        self.pending_update_notified = nil
    end
    self:saveSyncState()
end

--- Instalar es siempre una acción explícita, y siempre contra un manifiesto
-- fresco: el que se guardó al detectar la versión puede apuntar a hashes que
-- el servidor ya reemplazó, y esa descarga fallaría sin explicación.
function HighlightsDeToto:installPendingUpdate()
    self:_keepWifi()
    if not self:hasPendingUpdate() then
        if self:hasUpdatePendingRestart() then
            self:showInfo(T(
                _("Version %1 is already installed. Restart KOReader to start using it."),
                self:getInstalledUpdateVersion()
            ), 8)
        else
            self:showInfo(_("There is no new version to install."), 5)
        end
        return
    end

    local announced = self:getPendingUpdateVersion()
    self:ensureNetwork(function()
        local progress = self:showInfoPersist(_("Verifying the new version…"))
        UIManager:nextTick(function()
            self:_safecall("pluginUpdateFetch", function()
                local manifest, err = self.updater:fetchManifest()
                UIManager:close(progress)
                self:_recordPluginUpdateCheck(manifest ~= nil)
                if not manifest then
                    self:showInfo(T(
                        _("Could not download the new version: %1\nTry again when you have Wi-Fi."),
                        err or _("unknown error")
                    ), 10)
                    return
                end
                self:_rememberPendingUpdate(manifest)
                if not self:hasPendingUpdate() then
                    self:showInfo(T(_("You already have the latest version (%1)."),
                        self:getPluginVersion()), 5)
                    return
                end
                if manifest.version ~= announced then
                    -- Salió otra mientras tanto: se pregunta de nuevo en vez
                    -- de instalar algo distinto de lo que el lector aceptó.
                    self:_showPluginUpdateNotice(true)
                    return
                end
                self:confirmPluginUpdate(manifest)
            end)
        end)
    end)
end

-- ============================================================
-- Device ID Configuration
-- ============================================================

function HighlightsDeToto:configureDeviceId()
    local dialog
    dialog = InputDialog:new{
        title = _("Device ID"),
        description = _("Enter a unique ID for this device (e.g., 'kobo', 'kindle')."),
        input = self.device_id,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_id = dialog:getInputText()
                        UIManager:close(dialog)
                        if new_id and new_id ~= "" then
                            self.device_id = new_id
                            self:saveSyncState()
                            self:showInfo(T(_("Device ID set to: %1"), new_id))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- ============================================================
-- Personal Library
-- ============================================================

-- La biblioteca se pide de a LIBRARY_PAGE_SIZE libros, lo último agregado
-- primero (así lo ordena el servidor). Menu pagina en pantalla lo que ya bajó;
-- si el servidor tiene más, la última fila de la lista pide la página siguiente.
local LIBRARY_PAGE_SIZE = 100

local function formatBookSize(bytes)
    bytes = tonumber(bytes)
    if not bytes or bytes <= 0 then return nil end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
    return string.format("%d KB", math.max(1, math.floor(bytes / 1024 + 0.5)))
end

function HighlightsDeToto:fetchLibraryPage(page)
    local url = string.format("%s?page=%d&limit=%d", self:getLibraryBooksUrl(), page, LIBRARY_PAGE_SIZE)
    return self:getApi():getJSON(url, self:getWebAuth())
end

function HighlightsDeToto:showLibraryDownloadDialog()
    self:ensureNetwork(function()
        local progress = self:showInfoPersist(_("Loading Borges library..."))
        UIManager:nextTick(function()
            local result, err = self:fetchLibraryPage(1)
            UIManager:close(progress)
            if not result then
                self:showInfo(T(_("Library error: %1"), err or _("unknown error")), 8)
                return
            end

            local books = result.books or {}
            if #books == 0 then
                self:showInfo(_("No books available on the server."), 5)
                return
            end
            self:showLibraryMenu(books, 1, result.has_next == true)
        end)
    end)
end

function HighlightsDeToto:showLibraryMenu(books, page, has_next)
    local Menu = require("ui/widget/menu")
    local Screen = Device.screen
    local menu

    local function buildItems()
        local items = {}
        for _i, book in ipairs(books) do
            local label = book.title or book.original_filename or _("Untitled")
            if book.author and book.author ~= "" then
                label = label .. " - " .. book.author
            end
            table.insert(items, {
                text = label,
                mandatory = formatBookSize(book.file_size),
                callback = function() self:confirmLibraryBookDownload(book) end,
            })
        end
        if has_next then
            table.insert(items, {
                text = _("Load more books..."),
                callback = function()
                    local progress = self:showInfoPersist(_("Loading Borges library..."))
                    UIManager:nextTick(function()
                        local result, err = self:fetchLibraryPage(page + 1)
                        UIManager:close(progress)
                        if not result then
                            self:showInfo(T(_("Library error: %1"), err or _("unknown error")), 8)
                            return
                        end
                        local first_new = #books + 1
                        for _i, book in ipairs(result.books or {}) do
                            table.insert(books, book)
                        end
                        page = page + 1
                        has_next = result.has_next == true and #(result.books or {}) > 0
                        menu:switchItemTable(nil, buildItems(), first_new)
                    end)
                end,
            })
        end
        return items
    end

    menu = Menu:new{
        title = _("Download from Borges library"),
        item_table = buildItems(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        -- Sin close_callback a proposito: Menu lo llama despues de cada toque y
        -- la lista tiene que quedar abierta para bajar otro libro. La X y el
        -- gesto de cerrar ya la cierran solos (onCloseAllMenus).
    }
    UIManager:show(menu)
end

function HighlightsDeToto:confirmLibraryBookDownload(book)
    local lines = { book.title or book.original_filename or _("Untitled") }
    if book.author and book.author ~= "" then
        table.insert(lines, book.author)
    end
    local size = formatBookSize(book.file_size)
    if size then
        table.insert(lines, T(_("Size: %1"), size))
    end
    UIManager:show(ConfirmBox:new{
        text = table.concat(lines, "\n"),
        ok_text = _("Download"),
        ok_callback = function() self:downloadLibraryBook(book) end,
    })
end

function HighlightsDeToto:downloadLibraryBook(book)
    local dir = self:getLibraryDownloadDir()
    os.execute("mkdir -p " .. shellQuote(dir))

    local filename = book.original_filename or ((book.title or "book") .. ".epub")
    filename = self:_safeFilename(filename)
    if not filename:match("%.epub$") and book.canonical_format == "epub" then
        filename = filename .. ".epub"
    end

    local dest = dir .. "/" .. filename
    local url = book.download_url or ("/api/library/plugin/books/" .. tostring(book.id) .. "/download")
    if url:match("^/") then
        url = self:getBaseUrl() .. url
    end

    local progress = self:showInfoPersist(T(_("Downloading %1..."), filename))
    UIManager:nextTick(function()
        local ok, err = self:getApi():downloadFile(url, self:getWebAuth(), dest)
        self:_recordOperationOutcome('download', ok, err)
        UIManager:close(progress)
        if ok then
            self:showInfo(T(_("Downloaded to %1"), dest), 8)
        else
            self:showInfo(T(_("Download failed: %1"), err or _("unknown error")), 8)
        end
    end)
end

function HighlightsDeToto:configureLibraryDownloadDir()
    local dialog
    dialog = InputDialog:new{
        title = _("Borges library folder"),
        description = _("Folder where downloaded books will be saved."),
        input = self:getLibraryDownloadDir(),
        input_hint = DEFAULT_LIBRARY_DIR,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local dir = dialog:getInputText()
                        UIManager:close(dialog)
                        if dir and dir ~= "" then
                            self.library_download_dir = dir
                            self:saveSyncState()
                            self:showInfo(T(_("Library folder set to: %1"), dir), 5)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function HighlightsDeToto:_safeFilename(value)
    local filename = tostring(value or "book.epub")
    filename = filename:gsub("[/\\:*?\"<>|]", "_")
    filename = filename:gsub("^%s+", ""):gsub("%s+$", "")
    if filename == "" then filename = "book.epub" end
    return filename
end

function shellQuote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

-- ============================================================
-- Dropbox Configuration
-- ============================================================

function HighlightsDeToto:configureDropbox()
    if DropboxApi:isConfigured() then
        UIManager:show(MultiConfirmBox:new{
            text = _("Dropbox is already configured. What would you like to do?"),
            choice1_text = _("Reconfigure"),
            choice1_callback = function()
                self:inputAppKey()
            end,
            choice2_text = _("Keep current"),
        })
    else
        self:inputAppKey()
    end
end

function HighlightsDeToto:inputAppKey()
    local dialog
    dialog = InputDialog:new{
        title = _("Dropbox App Key"),
        description = _("Enter your Dropbox App Key.\n\nCreate one at: https://www.dropbox.com/developers/apps\n(Choose 'Scoped access' → 'App folder')"),
        input_hint = "xxxxxxxxxxxxxxxxx",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Next"),
                    is_enter_default = true,
                    callback = function()
                        local app_key = dialog:getInputText()
                        UIManager:close(dialog)
                        if app_key and app_key ~= "" then
                            DropboxApi.APP_KEY = app_key
                            self:startOAuthFlow()
                        else
                            self:showInfo(_("App Key cannot be empty."))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function HighlightsDeToto:startOAuthFlow()
    local auth_url, err = DropboxApi:getAuthorizationUrl()
    if not auth_url then
        self:showInfo(err)
        return
    end

    local dialog
    dialog = InputDialog:new{
        title = _("Authorize Dropbox"),
        description = T(_("Open this URL in a browser and authorize the app:\n\n%1\n\nThen paste the authorization code below:"), auth_url),
        input_hint = _("Paste authorization code here"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Authorize"),
                    is_enter_default = true,
                    callback = function()
                        local auth_code = dialog:getInputText()
                        UIManager:close(dialog)
                        if auth_code and auth_code ~= "" then
                            self:exchangeCode(auth_code)
                        else
                            self:showInfo(_("Authorization code cannot be empty."))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function HighlightsDeToto:exchangeCode(auth_code)
    self:ensureNetwork(function()
        local progress = self:showInfoPersist(_("Connecting to Dropbox..."))
        local ok, err = DropboxApi:exchangeAuthCode(auth_code)
        UIManager:close(progress)

        if ok then
            self:saveSettings()
            self:showInfo(_("Dropbox authorized successfully!"), 5)
        else
            self:showInfo(T(_("Authorization failed: %1"), err or _("Unknown error")), 10)
        end
    end)
end

function HighlightsDeToto:showConfigFileInfo()
    local config_path = self:getConfigFilePath()
    self:saveConfigFile()
    self:showInfo(
        T(_("You can edit Dropbox settings from your PC!\n\nConnect your reader via USB and edit:\n\n%1\n\nThe file contains:\n- app_key\n- refresh_token\n- dropbox_path\n\nThe plugin will read it on next startup."), config_path),
        30
    )
end

function HighlightsDeToto:configureDropboxPath()
    local dialog
    dialog = InputDialog:new{
        title = _("Dropbox upload path"),
        description = _("Enter the folder path in Dropbox where highlights will be uploaded.\nMust start and end with /"),
        input = self.dropbox_path,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local path = dialog:getInputText()
                        UIManager:close(dialog)
                        if path and path ~= "" then
                            if not path:match("^/") then path = "/" .. path end
                            if not path:match("/$") then path = path .. "/" end
                            self.dropbox_path = path
                            self:saveSettings()
                            self:showInfo(T(_("Upload path set to: %1"), path))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- ============================================================
-- Dropbox Export & Upload
-- ============================================================

function HighlightsDeToto:exportAndUploadAll()
    if not DropboxApi:isConfigured() then
        self:showInfo(_("Please configure Dropbox first."))
        return
    end

    self:ensureNetwork(function()
        local progress = self:showInfoPersist(_("Parsing highlights from all books..."))
        local consolidated_json, total_books, total_highlights = HighlightParser:generateConsolidatedJSON()

        if total_books == 0 then
            UIManager:close(progress)
            self:showInfo(_("No highlights found in any book."))
            return
        end

        local per_book = HighlightParser:generatePerBookJSONs()

        UIManager:close(progress)
        progress = self:showInfoPersist(
            T(_("Uploading %1 highlights from %2 books to Dropbox..."), total_highlights, total_books)
        )

        local ok, err = DropboxApi:uploadFile(
            self.dropbox_path .. "highlights_all.json",
            consolidated_json
        )

        if not ok then
            UIManager:close(progress)
            self:showInfo(T(_("Failed to upload consolidated file: %1"), err), 10)
            return
        end

        local upload_errors = {}
        for _, book in ipairs(per_book) do
            local book_ok, book_err = DropboxApi:uploadFile(
                self.dropbox_path .. "books/" .. book.filename,
                book.json
            )
            if not book_ok then
                table.insert(upload_errors, book.title .. ": " .. (book_err or "unknown"))
            end
        end

        UIManager:close(progress)
        self:saveSettings()

        if #upload_errors > 0 then
            self:showInfo(
                T(_("Uploaded with %1 errors:\n%2"),
                    #upload_errors,
                    table.concat(upload_errors, "\n")),
                15
            )
        else
            self:showInfo(
                T(_("Done! Uploaded %1 highlights from %2 books.\n\nConsolidated: %3highlights_all.json\nPer book: %4books/"),
                    total_highlights, total_books, self.dropbox_path, self.dropbox_path),
                10
            )
        end
    end)
end

function HighlightsDeToto:exportAndUploadConsolidated()
    if not DropboxApi:isConfigured() then
        self:showInfo(_("Please configure Dropbox first."))
        return
    end

    self:ensureNetwork(function()
        local progress = self:showInfoPersist(_("Parsing highlights from all books..."))
        local json, total_books, total_highlights = HighlightParser:generateConsolidatedJSON()

        if total_books == 0 then
            UIManager:close(progress)
            self:showInfo(_("No highlights found in any book."))
            return
        end

        UIManager:close(progress)
        progress = self:showInfoPersist(
            T(_("Uploading %1 highlights from %2 books..."), total_highlights, total_books)
        )

        local ok, err = DropboxApi:uploadFile(
            self.dropbox_path .. "highlights_all.json",
            json
        )

        UIManager:close(progress)
        self:saveSettings()

        if ok then
            self:showInfo(
                T(_("Done! Uploaded %1 highlights from %2 books to:\n%3highlights_all.json"),
                    total_highlights, total_books, self.dropbox_path),
                10
            )
        else
            self:showInfo(T(_("Upload failed: %1"), err), 10)
        end
    end)
end

function HighlightsDeToto:exportAndUploadPerBook()
    if not DropboxApi:isConfigured() then
        self:showInfo(_("Please configure Dropbox first."))
        return
    end

    self:ensureNetwork(function()
        local progress = self:showInfoPersist(_("Parsing highlights from all books..."))
        local per_book = HighlightParser:generatePerBookJSONs()

        if #per_book == 0 then
            UIManager:close(progress)
            self:showInfo(_("No highlights found in any book."))
            return
        end

        UIManager:close(progress)
        progress = self:showInfoPersist(
            T(_("Uploading highlights for %1 books..."), #per_book)
        )

        local upload_errors = {}
        local total_uploaded = 0
        for _, book in ipairs(per_book) do
            local ok, err = DropboxApi:uploadFile(
                self.dropbox_path .. "books/" .. book.filename,
                book.json
            )
            if ok then
                total_uploaded = total_uploaded + 1
            else
                table.insert(upload_errors, book.title .. ": " .. (err or "unknown"))
            end
        end

        UIManager:close(progress)
        self:saveSettings()

        if #upload_errors > 0 then
            self:showInfo(
                T(_("Uploaded %1/%2 books. Errors:\n%3"),
                    total_uploaded, #per_book,
                    table.concat(upload_errors, "\n")),
                15
            )
        else
            self:showInfo(
                T(_("Done! Uploaded highlights for %1 books to:\n%2books/"),
                    total_uploaded, self.dropbox_path),
                10
            )
        end
    end)
end

-- ============================================================
-- Auto Sync (silent, battery-friendly)
-- ============================================================

function HighlightsDeToto:autoSyncCheck()
    if not Background.current() then
        return self:_runBackgroundSync("library", function() self:autoSyncCheck() end)
    end
    if not self.auto_sync then return end
    if not self:isWebConfigured() then return end
    if (os.time() - self.last_web_sync) < AUTO_SYNC_INTERVAL then return end
    if not NetworkMgr:isConnected() then return end
    logger.info("Borges: Auto-sync starting (last sync:", self.last_web_sync, ")")
    self:silentSyncAllToWeb()
end

function HighlightsDeToto:syncBatches(documents, on_progress)
    local errors = {}
    local total_docs = 0
    local total_entries = 0

    for i = 1, #documents, BATCH_SIZE do
        local batch = {}
        for j = i, math.min(i + BATCH_SIZE - 1, #documents) do
            table.insert(batch, documents[j])
        end

        if on_progress then
            on_progress(math.ceil(i / BATCH_SIZE), math.ceil(#documents / BATCH_SIZE), #batch)
        end

        local result, err = self:getApi():postJSON(self.web_url, self:getWebAuth(), { documents = batch })
        if result then
            total_docs = total_docs + (result.docsUpserted or #batch)
            total_entries = total_entries + (result.entriesInserted or 0)
        else
            table.insert(errors, tostring(err or "Unknown"))
        end
    end

    return errors, total_docs, total_entries
end

function HighlightsDeToto:silentSyncAllToWeb()
    local payload, changed_count, _hl, new_synced, skipped =
        HighlightParser:generateApiPayloadIncremental(self.synced_books, Background.yieldToUI)

    if changed_count == 0 then
        self.last_web_sync = os.time()
        self:saveSyncState()
        logger.info("Borges: Auto-sync skipped, nothing changed (" .. skipped .. " books up to date)")
        return
    end

    local errors = self:syncBatches(payload.documents)

    if #errors > 0 then
        logger.warn("Borges: Auto-sync errors:", table.concat(errors, "; "))
        self:showInfo(T(_("Auto-sync error: %1"), errors[1]), 5)
    else
        self.synced_books = new_synced
        self.last_web_sync = os.time()
        self:saveSyncState()
        logger.info("Borges: Auto-sync OK, " .. changed_count .. " books synced, " .. skipped .. " skipped")
    end
end

-- ============================================================
-- Web Sync Operations
-- ============================================================

function HighlightsDeToto:syncAllToWeb()
    if not self:isWebConfigured() then
        self:showInfo(_("Please configure Web Sync first (URL and API key)."))
        return
    end

    self:ensureNetwork(function()
        local progress = self:showInfoPersist(_("Checking for changes..."))

        local payload, changed_count, _hl, new_synced, skipped =
            HighlightParser:generateApiPayloadIncremental(self.synced_books)

        if changed_count == 0 then
            UIManager:close(progress)
            self:showInfo(T(_("Everything up to date! (%1 books already synced)"), skipped), 5)
            return
        end

        local errors, total_docs, total_entries = self:syncBatches(payload.documents,
            function(batch_num, total_batches, batch_size)
                UIManager:close(progress)
                progress = self:showInfoPersist(
                    T(_("Syncing batch %1/%2 (%3 books)..."), batch_num, total_batches, batch_size)
                )
            end)

        UIManager:close(progress)

        if #errors > 0 then
            self:showInfo(
                T(_("Synced %1 docs, %2 entries.\n%3 batch errors:\n%4"),
                    total_docs, total_entries,
                    #errors, table.concat(errors, "\n")),
                15
            )
        else
            self.synced_books = new_synced
            self.last_web_sync = os.time()
            self:saveSyncState()
            self:showInfo(
                T(_("Synced! %1 docs, %2 entries uploaded.\n(%3 books unchanged, skipped)"),
                    total_docs, total_entries, skipped),
                10
            )
        end
    end)
end

function HighlightsDeToto:syncCurrentBookToWeb()
    if not self:isWebConfigured() then
        self:showInfo(_("Please configure Web Sync first (URL and API key)."))
        return
    end

    local file_path = self.ui and self.ui.document and self.ui.document.file
    if not file_path then
        self:showInfo(_("No book is currently open."))
        return
    end

    self:ensureNetwork(function()
        local progress = self:showInfoPersist(_("Parsing highlights from current book..."))

        local payload, highlights_count = HighlightParser:generateApiPayloadForBook(file_path)

        if not payload then
            UIManager:close(progress)
            self:showInfo(_("No highlights found in this book."))
            return
        end
        self:_attachCurrentBookHash(payload)

        UIManager:close(progress)
        progress = self:showInfoPersist(
            T(_("Syncing %1 highlights to web..."), highlights_count)
        )

        local result, err = self:getApi():postJSON(self.web_url, self:getWebAuth(), payload)
        UIManager:close(progress)

        if result then
            local mtime = HighlightParser:getSidecarMtime(file_path)
            if mtime then
                self.synced_books[file_path] = mtime
                self:saveSyncState()
            end
            self:showInfo(
                T(_("Synced! %1 highlights uploaded."), result.entriesInserted or highlights_count),
                10
            )
        else
            self:showInfo(T(_("Sync failed: %1"), err or _("Unknown error")), 10)
        end
    end)
end

-- ============================================================
-- Web Sync Configuration
-- ============================================================

function HighlightsDeToto:configureWebUrl()
    local dialog
    dialog = InputDialog:new{
        title = _("Highlights server"),
        description = _("The official server is already set. Change it only if you run your own.\nExample: https://borges.runadev.com"),
        input = self:getBaseUrl(),
        input_hint = "https://borges.runadev.com",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Next"),
                    is_enter_default = true,
                    callback = function()
                        local url = dialog:getInputText()
                        UIManager:close(dialog)
                        if url and url ~= "" then
                            self.server_base_url = SettingsMigration.normalizeBaseUrl(url)
                            self.web_url = self.server_base_url .. "/api/sync"
                            self:saveSettings()
                            self:_initializePairingAndSync()
                            self:promptDeviceLogin()
                        else
                            self:showInfo(_("URL cannot be empty."))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function HighlightsDeToto:configureWebApiKey()
    local dialog
    dialog = InputDialog:new{
        title = _("Legacy migration key"),
        description = _("Optional one-time key for migrating an existing install. It is retired after this device claims its own credential."),
        input = self.web_api_key,
        input_hint = "your-secret-key",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local key = dialog:getInputText()
                        UIManager:close(dialog)
                        if key and key ~= "" then
                            self.web_api_key = key
                            self:saveSettings()
                            self:_initializePairingAndSync()
                            self:startDevicePairing(true)
                        else
                            self:showInfo(_("API key cannot be empty."))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

return HighlightsDeToto

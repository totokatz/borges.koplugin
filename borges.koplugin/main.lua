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
local Background = require("backgroundsync")
local ProgressMessage = require("progressmessage")
local ReadingWifi = require("readingwifi")
local UpdateCheck = require("updatecheck")
local SyncRun = require("syncrun")
local Diagnostics = require("diagnostics")
local MenuTree = require("menutree")
local ReadingPosition = require("readingposition")
local ResumeFlow = require("resumeflow")
local AnnotationAdapter = require("annotationadapter")
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
local STATS_SYNC_DEBOUNCE = 120   -- stats SQLite reads are useful, but never urgent
-- C17 · Dos eventos de red seguidos (asociación + DHCP, o un rebote de la
-- señal) no son dos reconexiones. Sin esta ventana el lector recibe dos
-- corridas encimadas y, con ellas, dos diálogos.
local RECONNECT_SYNC_DEBOUNCE = 25
-- Segundos entre la consulta al servidor y la subida de lo pendiente. No es
-- una espera decorativa: le da lugar al aviso de posición para llegar a la
-- pantalla antes de que la cola vieja empiece a viajar.
local RECONNECT_DRAIN_DELAY = 5
-- C23 · Segundos entre el momento oportuno (arranque, reconexión) y la
-- pregunta por una versión nueva. Buscar versiones nunca compite con
-- sincronizar ni con la pregunta de posición: llega después, o no llega.
local PLUGIN_UPDATE_CHECK_DELAY = 30
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
    -- Persist the idempotent schema migration/install ID before pairing can start.
    self:saveSyncState()

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

    -- Offline queue
    self.queue = Queue:new(DataStorage:getSettingsDir())
    self.queue:holdPendingProgress()
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
            return { book_hash = self.book_hash, token = self.device_token, epoch = self._background_epoch }
        end,
        on_reading_head = function(response, context)
            return self:_handleReadingHead(response, context)
        end,
    }

    if self:getBaseUrl() ~= "" and not self.device_token
        and (self.web_api_key ~= "" or self.pairing_state) then
        UIManager:scheduleIn(8, function()
            if not NetworkMgr:isConnected() then return end
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
    local state = self.queue:getAnnotationState(identifier.value)
    local item_state = state[sync_id]
    if type(item_state) == "table" then
        item_state.revision = tostring(metadata.annotation_revision)
        self.queue:setAnnotationState(identifier.value, state)
    end
    if identifier.value ~= self.book_hash then return end
    local annotation_module = self.ui and self.ui.annotation
    if not annotation_module or type(annotation_module.annotations) ~= "table" then
        return
    end
    for _, item in ipairs(annotation_module.annotations) do
        if item.toto_sync_id == sync_id then
            item.toto_revision = tostring(metadata.annotation_revision)
            self.ui.doc_settings:saveSetting(
                "annotations",
                annotation_module.annotations
            )
            self.ui.doc_settings:flush()
            break
        end
    end
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
    local pending = {}
    for _, event in ipairs(self.queue:getInbox()) do
        table.insert(pending, event)
    end
    for _, event in ipairs(pending) do
        local identifier = event.book_identifier
        if identifier and identifier.kind == "koreader_partial_md5"
            and identifier.value == self.book_hash then
            local action = self:_applySyncV2Event(event)
            if action == true then self.queue:removeInboxEvent(event.event_id) end
        end
    end
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

function HighlightsDeToto:_scheduleHighlightPush()
    if not self.auto_sync then return end
    if not self.book_hash or not self.book_file_path then return end
    if not self:isWebConfigured() then return end

    local mtime = HighlightParser:getSidecarMtime(self.book_file_path)
    if not mtime then return end
    if self.last_seen_sidecar_mtime and mtime <= self.last_seen_sidecar_mtime then
        return
    end

    UIManager:unschedule(self.highlight_push_task)
    UIManager:scheduleIn(HIGHLIGHT_DEBOUNCE, self.highlight_push_task)
end

function HighlightsDeToto:_syncHighlightsIfSidecarChanged()
    if not self.book_hash or not self.book_file_path then return end
    if not self:isWebConfigured() then return end

    local mtime = HighlightParser:getSidecarMtime(self.book_file_path)
    if not mtime then return end
    if self.last_seen_sidecar_mtime and mtime <= self.last_seen_sidecar_mtime then
        return
    end
    if self.synced_books and self.synced_books[self.book_file_path] == mtime then
        self.last_seen_sidecar_mtime = mtime
        return
    end

    self:syncHighlightsDelta(not NetworkMgr:isConnected(), true)
    self.last_seen_sidecar_mtime = mtime
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

--- One automatic operation at a time; pending triggers are coalesced by kind.
-- All settings, queue commits and widget work stay in this parent process.
function HighlightsDeToto:_runBackgroundSync(label, fn)
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
    self:_closeSyncProgress()
    self._connect_sync_running = false
    self._plugin_update_check_running = false
end

function HighlightsDeToto:onExit()
    self._background_suspended = true
    self:_cancelBackgroundSync()
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

function HighlightsDeToto:_annotationBookDescriptor()
    return {
        title = self.book_title ~= "" and self.book_title
            or self.book_filename
            or _("Unknown book"),
        author = self.book_author,
        file = self.book_filename,
        total_pages = self.total_pages,
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

    if not self._annotation_pull_backed_up then
        self._annotation_pull_backed_up =
            self:_backupCurrentMetadataBeforePull() == true
    end
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
        if annotation_module.updateAnnotations then
            annotation_module:updateAnnotations(true, true)
        end
        self.ui.doc_settings:saveSetting(
            "annotations",
            annotation_module.annotations
        )
        self.ui.doc_settings:flush()
    end

    local state = self.queue:getAnnotationState(self.book_hash)
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
    self.queue:setAnnotationState(self.book_hash, state)
    self.last_web_sync = os.time()
    self:saveSyncState()
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

    local previous = self.queue:getAnnotationState(self.book_hash)
    local events, next_state, assigned = AnnotationAdapter:diff(
        self.book_hash,
        annotation_module.annotations,
        previous,
        self:_annotationBookDescriptor()
    )
    if assigned > 0 and self.ui and self.ui.doc_settings then
        self.ui.doc_settings:saveSetting(
            "annotations",
            annotation_module.annotations
        )
        self.ui.doc_settings:flush()
    end
    for _, event in ipairs(events) do
        event.book_identifier = self:_bookIdentifier(self.book_hash)
        event.occurred_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        event.time_precision = "exact"
        self.sync_v2:enqueue(event)
    end
    self.queue:setAnnotationState(self.book_hash, next_state)
    return #events, assigned
end

function HighlightsDeToto:_enqueueSessionV2(session_data)
    if not session_data or not session_data.book_hash then return nil end
    local book_hash = tostring(session_data.book_hash):lower()
    return self.sync_v2:enqueue{
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
    }
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
    }
end

function HighlightsDeToto:_enqueueProgressV2(is_jump)
    if not self.book_hash then return nil end
    if is_jump then self:_recordReadingActivity() end
    -- Opening/reconnecting/closing an untouched book is not a new reading.
    if not self._reading_activity_at then return nil end
    local book_hash = tostring(self.book_hash):lower()
    local payload = self:_progressPayload(is_jump)
    local signature = table.concat({book_hash, self._reading_activity_at,
        tostring(payload.xpointer or payload.current_page), tostring(is_jump == true)}, "|")
    if signature == self._last_enqueued_progress then return nil end
    local result, err = self.sync_v2:enqueue({
        event_type = "progress.changed",
        aggregate_type = "reading_progress",
        aggregate_id = "koreader_partial_md5:" .. book_hash,
        book_identifier = self:_bookIdentifier(book_hash),
        occurred_at = self._reading_activity_at,
        time_precision = "exact",
        payload = payload,
    }, {
        -- Only never-attempted progress may be replaced. Once transport has
        -- seen an event its content remains immutable across every retry.
        coalesce_unattempted = true,
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
    local result, err = self.sync_v2:syncAll(force == true, max_pages or 20, quick)
    if result then
        self.last_progress_sync = os.time()
        self:saveSyncState()
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
function HighlightsDeToto:_drainQueue()
    if not Background.current() then
        return self:_runBackgroundSync("drain", function() self:_drainQueue() end)
    end
    if not NetworkMgr:isConnected() then return end
    local v2_result, v2_err
    if self.device_token then
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

--- Synchronous full drain of the offline queue.
-- Used in onReaderReady/onResume to ensure the server has our offline progress
-- BEFORE we pullProgress. Without this, pull would auto-jump to a stale server
-- position (Bug #1 — progress regression after offline reading).
-- Also used in onNetworkDisconnecting as last-chance flush before WiFi turns off.
-- Bounded by Queue:drain's per-item LARGE timeout — typically returns in <10s
-- when items succeed, faster when offline (skips immediately).
function HighlightsDeToto:_drainQueueBlocking()
    if not NetworkMgr:isConnected() then return end
    if self.device_token then
        local sync_result, sync_err = self:_syncV2Now(false, 50)
        if not sync_result then
            logger.warn("Borges: blocking v2 drain failed:", tostring(sync_err))
        end
    end
    if self.queue:count() == self.queue:v2Count() then return end
    local r = self.queue:drain(self:getApi(), self:getBaseUrl(), self:getWebAuth())
    if r and r.sent and r.sent > 0 then
        -- Update sync timestamps for sent items (we don't know per-type from drain,
        -- so be conservative and refresh both — drain only succeeds if server accepted).
        local now = os.time()
        self.last_web_sync = now
        self.last_stats_sync = now
        self.last_stats_error = nil
        self:saveSyncState()
        logger.info("Borges: legacy queue drain sent", r.sent, "items, failed", r.failed)
    end
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
    self.queue:holdProgress(self:_bookIdentifier(self.book_hash))
end

function HighlightsDeToto:_handleReadingHead(response, context)
    if context and (context.book_hash ~= self.book_hash or context.token ~= self.device_token
        or context.epoch ~= self._background_epoch) then return nil, "stale_reading_head" end
    if not self.book_hash or response.reading_head_checked ~= true then
        return nil, "reading_head_unavailable"
    end
    local event = response.focus_event
    local head = { book_hash = self.book_hash, token = self.device_token, ask = false }
    if event ~= nil and event ~= rapidjson.null then
        local identifier = type(event) == "table" and event.book_identifier
        local source = type(event) == "table" and event.origin_device
        if not identifier or identifier.value ~= self.book_hash or identifier.kind ~= "koreader_partial_md5"
            or not source or not source.id or not event.event_id
            or not event.directive_metadata or event.directive_metadata.reading_head ~= true then
            return nil, "reading_head_invalid"
        end
        head.event_id = event.event_id
        local own = source.id == self.paired_device_id or source.id == self.device_id
        local chosen = self.resume_flow:hasLocalChoice(self.book_hash, event,
            self.paired_device_id or self.device_id)
        head.ask = not own and not chosen
    end
    self._reading_head = head
    logger.info("Borges: last reading checked; choice required:", head.ask)
    if not head.ask then self.queue:releaseProgress(self:_bookIdentifier(self.book_hash)) end
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
    self.queue:releaseProgress(self:_bookIdentifier(book_hash))
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
                UIManager:scheduleIn(RECONNECT_DRAIN_DELAY, function()
                    self:_safecall("queueDrain", function() self:_drainQueue() end)
                end)
                UIManager:scheduleIn(STATS_SYNC_DEBOUNCE, function()
                    self:_runBackgroundSync("stats", function() self:syncPageStatsDelta() end)
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
    if not describable.chapter_title and display_page then
        describable.chapter_title = self:_getChapterTitleForPage(display_page)
    end
    return describable
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
    local navigated = self:_navigateToProgress(remote, false)
    if not navigated then
        if remembered then self.position_undo:clear(book_hash) end
        -- Ni se descarta la sugerencia ni se anota la decisión: las dos
        -- posiciones siguen vivas y el menú puede reintentar.
        self:showInfo(_("Could not work out that position in this book. You stay where you were and can retry from the menu."), 8)
        return
    end

    if not self:_safecall("acceptReadingChoice", function()
        return self:_finishReadingChoice(book_hash, remote, opts, "accept")
    end) then return end
    self:showInfo(T(_("You are on p. %1. You can go back to where you were from the menu."),
        self.ui:getCurrentPage()), 6)
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
            and not self._reading_wifi_cancelled
    end
    if not valid() then return end
    if NetworkMgr:isConnected() then callback(); return end
    self._reading_wifi = ReadingWifi:new{
        valid = valid,
        on_connected = callback,
        on_cancel = function()
            self._reading_wifi_cancelled = true
            self.pull_done, self._resume_pull_done = true, true
            self:_cancelBackgroundSync()
        end,
        on_error = function(message) self:showInfo(message, 6) end,
    }
    self._reading_wifi:start()
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
            self.last_seen_sidecar_mtime = HighlightParser:getSidecarMtime(self.book_file_path)
            self._annotation_pull_backed_up = false
            self._last_handled_page = self.ui:getCurrentPage()
            self._last_handled_xpointer = self._getXPointer and self:_getXPointer()
            self._last_handled_page_at = os.time()
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

    -- 1. Capture final progress while this document is still available.
    self:_safecall("pushProgress", function() self:_enqueueProgressV2(false) end)

    -- 2. Finish session and ENQUEUE (payload is tiny ~200B, drain will send it)
    self:_safecall("session", function()
        for _, session_data in ipairs(self.session:finishAll()) do
            self:_enqueueSessionV2(session_data)
        end
    end)

    -- 3. Flush doc settings so sidecar has the very latest annotations
    if self.ui and self.ui.doc_settings then
        self.ui.doc_settings:flush()
    end

    -- 4. Persist the annotation delta without waiting on the network.
    self:_safecall("highlightSync", function()
        self:syncHighlightsDelta(true)
    end)

    -- 5. Persist the statistics delta for the same background drain.
    self:_safecall("statsSync", function()
        self:syncPageStatsDelta(true)
    end)

    -- Clean up
    -- C17 · Un diálogo que se cierra junto con el libro no puede dejar la
    -- compuerta trabada: el próximo libro no mostraría nada.
    if self.resume_flow then self.resume_flow:clearVisible() end
    self.book_hash = nil
    self.book_file_path = nil
    self.has_pages = nil
    self._annotation_pull_backed_up = nil
    self.last_seen_sidecar_mtime = nil
    self._last_handled_page = nil
    self._last_handled_xpointer = nil
    self._last_handled_page_at = nil

    -- 6. Send the durable work after returning control to the reader.
    UIManager:scheduleIn(2, function()
        self:_safecall("queueDrain", function() self:_drainQueue() end)
    end)

    -- C23 · Cerrar el libro devuelve al explorador: ahí el aviso de versión
    -- nueva no tapa nada. Es el momento que reemplaza al cartel que antes
    -- podía salir en medio de una página.
    UIManager:scheduleIn(3, function()
        self:_safecall("updateNoticeOnClose", function()
            self:_announcePluginUpdate("close_document")
        end)
    end)
end

--- Called when user navigates to a new page (paged documents like PDF).
function HighlightsDeToto:onPageUpdate(pageno)
    self:_handlePageChange(pageno)
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

    -- Debounced auto-push of progress
    UIManager:unschedule(self.periodic_push_task)
    UIManager:scheduleIn(PROGRESS_DEBOUNCE, self.periodic_push_task)
    self:_scheduleHighlightPush()
end

--- Called when device goes to standby/suspend.
-- Finishes the current session and enqueues everything for the next connection.
-- Each operation has its own _safecall so a failure in one doesn't skip the rest.
-- Kobo disables WiFi before broadcasting Suspend, so this must not try to
-- reconnect. The online last-chance flush happens in onNetworkDisconnecting.
function HighlightsDeToto:onSuspend()
    self._background_suspended = true
    self:_cancelBackgroundSync()
    self.pairing:stopWatching()
    if not self.book_hash then return end

    local flushed_before_suspend = self._disconnect_flush_book_hash == self.book_hash
        and self._disconnect_flush_at
        and (os.time() - self._disconnect_flush_at) <= 30
    self._disconnect_flush_book_hash = nil
    self._disconnect_flush_at = nil

    -- Push progress (quick HTTP if still connected on non-Kobo paths, enqueue otherwise)
    if not flushed_before_suspend then
        self:_safecall("suspendProgress", function() self:_pushProgressOrQueue() end)
    end

    -- Finish session and always enqueue (no HTTP during suspend — keeps sleep fast)
    self:_safecall("suspendSession", function()
        for _, session_data in ipairs(self.session:finishAll()) do
            self:_enqueueSessionV2(session_data)
        end
    end)

    -- Flush doc settings to disk so sidecar has the very latest annotations
    self:_safecall("suspendFlush", function()
        if self.ui and self.ui.doc_settings then
            self.ui.doc_settings:flush()
        end
    end)

    if self.force_sync_before_sleep and NetworkMgr:isConnected() then
        self:_safecall("forceSleepHighlights", function() self:syncHighlightsDelta(false, true) end)
        self:_safecall("forceSleepStats", function() self:syncPageStatsDelta(false, true) end)
        self:_safecall("forceSleepQueueDrain", function() self:_drainQueueBlocking() end)
        return
    end

    if flushed_before_suspend then
        return
    end

    -- Enqueue highlights for sync on next resume
    self:_safecall("suspendHighlights", function() self:syncHighlightsDelta(true) end)

    -- Enqueue stats delta for sync on next resume
    self:_safecall("suspendStats", function() self:syncPageStatsDelta(true) end)
end

--- Called when device wakes from standby.
-- Starts a fresh session and requests progress as soon as Wi-Fi is connected.
-- Guard _resume_pull_done prevents duplicate pulls from overlapping triggers.
function HighlightsDeToto:onResume()
    self._background_suspended = false
    self._reading_wifi_cancelled = false
    if self.pairing_state then self:watchDevicePairing(self.pairing_state, false) end
    self:_safecall("onResume", function()
        self:_closeSuspendSyncBanner()

        -- Start a fresh session
        if self.book_hash then
            self.session:start(self.book_hash, self.device_id, self.ui:getCurrentPage())
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
    self._reading_wifi_cancelled = false
    self:_beginReadingHandoff()
end

function HighlightsDeToto:onNetworkConnected()
    if self._reading_wifi_cancelled then return end
    if not self._reading_head then self:_beginReadingHandoff() end
    UIManager:scheduleIn(5, function() self:_flushDiagnostics() end)
    if not self:isWebConfigured() then return end
    self:_safecall("networkConnectedSync", function()
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
    self:_cancelBackgroundSync()
    -- Canceling a connection must not trigger synchronous "last chance"
    -- uploads: the reader explicitly chose to continue without syncing.
    if self._reading_wifi_cancelled then return end
    if not self:isWebConfigured() then return end

    if self.book_hash then
        logger.info("Borges: onNetworkDisconnecting - flushing current book")
        self:_safecall("disconnectingProgress", function() self:_pushProgressOrQueue() end)
        self:_safecall("disconnectingFlush", function()
            if self.ui and self.ui.doc_settings then
                self.ui.doc_settings:flush()
            end
        end)
        self:_safecall("disconnectingHighlights", function() self:syncHighlightsDelta(false, true) end)
        self:_safecall("disconnectingStats", function() self:syncPageStatsDelta(false, true) end)
        self._disconnect_flush_book_hash = self.book_hash
        self._disconnect_flush_at = os.time()
    end

    if self.queue:count() > 0 then
        logger.info("Borges: onNetworkDisconnecting - flushing queue")
        self:_safecall("disconnectingDrain", function() self:_drainQueueBlocking() end)
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
                self.ui:handleEvent(Event:new("GotoPage", server_page))
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
function HighlightsDeToto:_navigateToProgress(server_data, same_device)
    local local_page = self.ui:getCurrentPage()

    -- For reflowable docs (EPUB): prefer xpointer (device-independent)
    if not self.has_pages and server_data.xpointer and server_data.xpointer ~= "" then
        self.ui:handleEvent(Event:new("GotoXPointer", server_data.xpointer))
        logger.info("Borges: Navigated via xpointer")
        return true
    end

    -- For paged docs (PDF/DJVU) on same device: use page number directly
    if self.has_pages and same_device then
        local page = server_data.current_page
        if page and page >= 1 and self.total_pages and page <= self.total_pages then
            self.ui:handleEvent(Event:new("GotoPage", page))
            return true
        end
    end

    -- Fallback: percentage (for paged docs cross-device, or when xpointer is missing)
    local pct = _safePct(server_data.percentage)
    if pct >= 0 and self.total_pages and self.total_pages > 0 then
        local calc = math.floor(pct / 100 * self.total_pages + 0.5)
        local target = math.max(1, math.min(calc, self.total_pages))
        self.ui:handleEvent(Event:new("GotoPage", target))
        return true
    end

    return false
end

--- Calculate display page for server progress (for UI messages only, not navigation).
-- @param server_data table the result.latest from GET /api/progress
-- @return number|nil approximate local page number
function HighlightsDeToto:_calcDisplayPage(server_data)
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

--- Sync current-book annotations through the durable v2 outbox.
-- The first successful sync per edition also sends the historical snapshot to
-- the legacy endpoint. That imports old rows and registers the partial-MD5
-- identifier before incremental create/update/delete takes over.
-- @param enqueue_only boolean (optional) if true, always enqueue instead of POSTing (for suspend)
-- @param quick boolean (optional) use shorter HTTP timeout (5/10s) — for close/disconnect paths
function HighlightsDeToto:syncHighlightsDelta(enqueue_only, quick)
    if not self.book_hash then return end
    if not self:isWebConfigured() then return end

    local file_path = self.book_file_path
        or (self.ui.document and self.ui.document.file)
    if not file_path then
        logger.warn("Borges: syncHighlightsDelta - no file_path available")
        return
    end

    local payload, count = HighlightParser:generateApiPayloadForBook(file_path)
    if payload then self:_attachCurrentBookHash(payload) end
    count = count or 0

    local bridged = self.annotation_v2_bridged[self.book_hash] == true
    if not bridged and payload and count > 0
        and not enqueue_only and NetworkMgr:isConnected() then
        local result, err = self:getApi():postJSON(
            self.web_url,
            self:getWebAuth(),
            payload,
            quick
        )
        if result then
            self.annotation_v2_bridged[self.book_hash] = true
            bridged = true
            logger.info(
                "Borges: historical annotation bridge imported",
                count,
                "entries"
            )
        else
            logger.warn(
                "Borges: historical annotation bridge deferred:",
                tostring(err)
            )
        end
    end

    local event_count, assigned = self:_enqueueAnnotationDiff()
    logger.info(
        "Borges: annotation delta enqueued",
        event_count,
        "events;",
        assigned,
        "stable IDs assigned"
    )

    local sync_result
    if event_count > 0 and not enqueue_only
        and NetworkMgr:isConnected() and self.device_token then
        sync_result = self:_syncV2Now(quick, math.max(4, event_count + 2))
    end

    if bridged or (sync_result and (sync_result.pending or 0) == 0) then
        self.last_web_sync = os.time()
        local mtime = HighlightParser:getSidecarMtime(file_path)
        if mtime then self.synced_books[file_path] = mtime end
    end
    self:saveSyncState()
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
            self:saveSyncState()
        end
        return
    end

    if self.last_stats_error then
        self.last_stats_error = nil
        self:saveSyncState()
    end

    if data.total_rows == 0 then
        logger.info("Borges: stats delta - no new rows since last sync")
        return
    end

    logger.info("Borges: stats delta -", data.total_rows, "rows to sync")

    local chunk_count, watermark = self:_enqueueStatsV2(data)
    if watermark then
        self.last_stats_enqueued_at = math.max(
            tonumber(self.last_stats_enqueued_at) or 0,
            watermark
        )
    end
    self:saveSyncState()
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
        self:saveSyncState()
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

function HighlightsDeToto:loadConfigFile()
    local config_path = self:getConfigFilePath()
    local f = io.open(config_path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    local ok, data = pcall(rapidjson.decode, content)
    if not ok or type(data) ~= "table" then
        logger.warn("Borges: Failed to parse", config_path)
        return nil
    end
    logger.info("Borges: Loaded config from", config_path)
    return data
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
    local config_path = self:getWebConfigFilePath()
    local f = io.open(config_path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    local ok, data = pcall(rapidjson.decode, content)
    if not ok or type(data) ~= "table" then
        logger.warn("Borges: Failed to parse", config_path)
        return nil
    end
    return data
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
function HighlightsDeToto:saveSyncState()
    G_reader_settings:saveSetting("highlightsdetoto", self:_currentSettings())
    G_reader_settings:flush()
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
        if not self.diagnostics then return end
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

    local pending = self.queue:count()
    if pending == 0 then
        self:_showSuspendSyncBanner(_("Everything synced."))
    else
        self:_showSuspendSyncBanner(T(_("Not everything was synced. %1 pending."), pending))
    end
end

function HighlightsDeToto:ensureNetwork(callback)
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

function HighlightsDeToto:showLibraryDownloadDialog()
    self:ensureNetwork(function()
        local progress = self:showInfoPersist(_("Loading Borges library..."))
        UIManager:nextTick(function()
            local result, err = self:getApi():getJSON(self:getLibraryBooksUrl(), self:getWebAuth())
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

            local lines = {}
            for i, book in ipairs(books) do
                if i > 20 then break end
                local label = book.title or book.original_filename or _("Untitled")
                if book.author and book.author ~= "" then
                    label = label .. " - " .. book.author
                end
                table.insert(lines, string.format("%d. %s", i, label))
            end

            local dialog
            dialog = InputDialog:new{
                title = _("Download from Borges library"),
                description = table.concat(lines, "\n") .. "\n\n" .. _("Enter the book number to download."),
                input_hint = "1",
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
                            text = _("Download"),
                            is_enter_default = true,
                            callback = function()
                                local choice = tonumber(dialog:getInputText())
                                UIManager:close(dialog)
                                if not choice or not books[choice] then
                                    self:showInfo(_("Invalid selection."), 4)
                                    return
                                end
                                self:downloadLibraryBook(books[choice])
                            end,
                        },
                    },
                },
            }
            UIManager:show(dialog)
        end)
    end)
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
        T(_("You can edit Dropbox settings from your PC!\n\nConnect your Kobo via USB and edit:\n\n%1\n\nThe file contains:\n- app_key\n- refresh_token\n- dropbox_path\n\nThe plugin will read it on next startup."), config_path),
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

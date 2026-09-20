-- A cancelable wait for Wi-Fi only. HTTP sync starts after this dialog closes.
local _ = require("i18n")
local logger = require("logger")

local CONNECTION_TIMEOUT = 45
local RESTORE_TIMEOUT = 90
local RESTORE_POLL_INTERVAL = 1

local ReadingWifi = {}
ReadingWifi.__index = ReadingWifi

function ReadingWifi.migrateDirectConnection(settings, device)
    if not (device:isKindle() or device:isKobo())
        or settings:isTrue("highlightsdetoto_direct_wifi_migrated") then
        return false
    end
    -- The system restore can time out before our normal saved-network path
    -- even starts. Apply the setting verified on a physical Kindle once;
    -- a later explicit user choice to restore Wi-Fi must remain effective.
    settings:saveSetting("highlightsdetoto_previous_auto_restore_wifi",
        settings:readSetting("auto_restore_wifi"))
    settings:makeFalse("auto_restore_wifi")
    settings:saveSetting("highlightsdetoto_direct_wifi_migrated", true)
    settings:flush()
    logger.info("Borges: configured direct Wi-Fi connection for reading")
    return true
end

function ReadingWifi:new(options)
    return setmetatable({
        network = options.network or require("ui/network/manager"),
        ui = options.ui or require("ui/uimanager"),
        confirm = options.confirm or require("ui/widget/confirmbox"),
        settings = options.settings or G_reader_settings,
        on_connected = options.on_connected,
        on_cancel = options.on_cancel,
        on_error = options.on_error,
        valid = options.valid,
    }, self)
end

function ReadingWifi:close()
    self.active = false
    if self.timeout then self.ui:unschedule(self.timeout); self.timeout = nil end
    if self.start_task then self.ui:unschedule(self.start_task); self.start_task = nil end
    if self.restore_task then self.ui:unschedule(self.restore_task); self.restore_task = nil end
    if self.dialog then
        local dialog = self.dialog
        self.dialog = nil
        self.ui:close(dialog)
    end
end

function ReadingWifi:_isActive()
    if not self.active then return false end
    if self.valid and not self.valid() then self:close(); return false end
    return true
end

function ReadingWifi:connected()
    if not self:_isActive() or not self.network:isConnected() then return false end
    self:close()
    self.on_connected()
    return true
end

function ReadingWifi:cancel(turn_off)
    if not self:_isActive() then return end
    self:close()
    -- Invalidate plugin callbacks before KOReader broadcasts disconnect events.
    if self.on_cancel then self.on_cancel() end
    if turn_off then self.network:disableWifi(nil, true) end
end

function ReadingWifi:_failed()
    if not self:_isActive() then return end
    self:close()
    if self.on_cancel then self.on_cancel() end
    if self.on_error then
        self.on_error(_("Could not connect to Wi-Fi. You can keep reading and sync from the menu."))
    end
end

function ReadingWifi:_setTimeout(seconds)
    if self.timeout then self.ui:unschedule(self.timeout) end
    local timeout
    timeout = function()
        if self.timeout ~= timeout then return end
        if not self:connected() then self:_failed() end
    end
    self.timeout = timeout
    self.ui:scheduleIn(seconds, timeout)
end

function ReadingWifi:_observeRestore()
    -- KOReader's background restore uses the system's saved networks; its
    -- enableWifi path also tries KOReader's own saved networks. Wait until
    -- native cleanup has cleared BOTH flags before using that second path.
    -- Its "45s" counter is 180 scheduled polls, not a wall-clock deadline:
    -- device logs show cleanup after 64-67s. Keep a bounded safety ceiling,
    -- but recover as soon as the flags clear, without waiting for that ceiling.
    self:_setTimeout(RESTORE_TIMEOUT)
    local function observe()
        self.restore_task = nil
        if not self:_isActive() or self:connected() or self.recovery_attempted then return end
        -- Another foreground request took over: it owns the outcome now.
        if self.network.pending_connection then return end
        if self.network.pending_connectivity_check then
            self.restore_task = observe
            self.ui:scheduleIn(RESTORE_POLL_INTERVAL, observe)
            return
        end
        self.recovery_attempted = true
        logger.info("Borges: background Wi-Fi restoration ended offline; checking saved-network recovery")
        self:close()
        -- Re-read turn_on/prompt/ignore before a single native enableWifi call.
        -- A failed foreground attempt is never observed/retried by this helper.
        self:start()
    end
    self.restore_task = observe
    self.ui:scheduleIn(RESTORE_POLL_INTERVAL, observe)
end

function ReadingWifi:_begin()
    if not self:_isActive() or self:connected() then return end
    self.dialog = self.confirm:new{
        text = _("Connecting to Wi-Fi to sync…"),
        no_ok_button = true,
        dismissable = false,
        flush_events_on_show = true,
        cancel_text = _("Cancel and keep reading"),
        cancel_callback = function()
            self.dialog = nil -- ConfirmBox closes itself after this callback.
            self:cancel(true)
        end,
    }
    self.ui:show(self.dialog)
    self:_setTimeout(CONNECTION_TIMEOUT)
    -- Let the dialog paint before the device starts its Wi-Fi backend.
    self.start_task = function()
        self.start_task = nil
        if not self:_isActive() or self:connected() then return end
        -- Resume may already be restoring Wi-Fi. Its NetworkConnected event
        -- completes this wait; do not launch a second connection attempt.
        if self.network.pending_connection then return end
        if self.network.pending_connectivity_check then
            if not self.recovery_attempted then self:_observeRestore() end
            return
        end
        if self.recovery_attempted then
            logger.info("Borges: connecting saved Wi-Fi networks after background restore failure (once)")
        end
        local ok, status = pcall(self.network.enableWifi, self.network, function() self:connected() end)
        if not ok or status == false then self:_failed() end
    end
    self.ui:nextTick(self.start_task)
end

function ReadingWifi:start()
    self.active = true
    if not self:_isActive() or self:connected() then return end
    local action = self.settings:readSetting("wifi_enable_action")
    if self.network.pending_connection or self.network.pending_connectivity_check
        or action == "turn_on" then
        self:_begin()
    elseif action == "ignore" then
        self:close()
    else
        self.dialog = self.confirm:new{
            text = _("Turn on Wi-Fi to sync?"),
            ok_text = _("Turn on Wi-Fi"),
            cancel_text = _("Continue without syncing"),
            dismissable = false,
            flush_events_on_show = true,
            ok_callback = function()
                self.dialog = nil
                self.start_task = function() self.start_task = nil; self:_begin() end
                self.ui:nextTick(self.start_task)
            end,
            cancel_callback = function()
                self.dialog = nil
                self:cancel(false)
            end,
        }
        self.ui:show(self.dialog)
    end
end

return ReadingWifi

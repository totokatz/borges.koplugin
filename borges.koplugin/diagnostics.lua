-- Bounded technical outcomes. Never store messages, URLs, credentials or book data.
local LuaSettings = require('luasettings')
local Diagnostics = {}
Diagnostics.__index = Diagnostics

function Diagnostics:new(dir, options)
    options = options or {}
    local store = options.store or LuaSettings:open(dir .. '/highlightsdetoto_diagnostics.lua')
    local state = store:readSetting('state') or {}
    state.pending = type(state.pending) == 'table' and state.pending or {}
    state.sequence = tonumber(state.sequence) or 0
    local now = options.now or os.time
    -- La espera entre reintentos se guarda. KOReader crea el plugin de nuevo
    -- cada vez que se abre o se cierra un libro, y con la espera solo en
    -- memoria cada apertura volvia a intentar desde cero: un servidor que no
    -- acepta diagnosticos recibia un pedido por libro abierto, para siempre.
    -- Nunca se confia en una espera mayor al tope (un reloj que salto).
    local backoff = math.min(math.max(tonumber(state.backoff) or 60, 60), 3600)
    local retry_at = math.min(tonumber(state.retry_at) or 0, now() + 3600)
    return setmetatable({ store = store, state = state, now = now,
        retry_at = retry_at, backoff = backoff }, self)
end
function Diagnostics:save()
    self.store:saveSetting('state', self.state)
    self.store:flush()
end
function Diagnostics:isEnabled() return self.state.enabled ~= false end
function Diagnostics:setEnabled(enabled)
    self.state.enabled = enabled
    if not enabled then self.state.pending = {} end
    self:save()
end
function Diagnostics:scope(account)
    if account ~= self.state.account then
        self.state.pending = {}
        self.state.last = nil
        self.state.account = account
        self.backoff, self.retry_at = 60, 0
        self.state.backoff, self.state.retry_at = nil, nil
        self:save()
    end
end
function Diagnostics:record(operation, success, err, version)
    if not self:isEnabled() or not self.state.account then return end
    local code = type(err) == 'table' and err.code or nil
    local status = type(err) == 'table' and tonumber(err.http_status) or nil
    if not success and (code == 'connection_failed' or code == 'network_unavailable'
        or code == 'offline' or code == 'cancelled' or code == 'already_running'
        or (status and status >= 400 and status < 500)) then return end
    if status and status >= 500 then code = 'server_error'
    elseif code ~= 'invalid_response' and code ~= 'plugin_error' then
        code = operation == 'download' and 'download_failed' or 'sync_rejected'
    end
    -- El servidor solo cambia el estado de una operacion con un fallo o con el
    -- primer exito despues de uno. Un "salio bien" igual al anterior no le dice
    -- nada, y costaba una escritura de este archivo y un pedido HTTPS propio
    -- por cada sincronizacion. Se anota uno por dia para que se vea que el
    -- lector sigue vivo, y siempre que cambie el resultado o la version.
    local now = self.now()
    self.state.last = type(self.state.last) == 'table' and self.state.last or {}
    local last = self.state.last[operation]
    if success and type(last) == 'table' and last.outcome == 'success' and last.version == version
        and now >= (tonumber(last.at) or 0) and now - (tonumber(last.at) or 0) < 86400 then
        return
    end
    self.state.last[operation] = { outcome = success and 'success' or 'failure', version = version, at = now }
    self.state.sequence = self.state.sequence + 1
    table.insert(self.state.pending, {
        operation = operation, outcome = success and 'success' or 'failure',
        code = code, sequence = self.state.sequence,
        at = os.date('!%Y-%m-%dT%H:%M:%SZ', self.now()), version = version,
        requestId = type(err) == 'table' and err.request_id or nil,
    })
    while #self.state.pending > 20 do table.remove(self.state.pending, 1) end
    self:save()
end
function Diagnostics:flush(send)
    if not self:isEnabled() or #self.state.pending == 0 or self.sending or not send
        or self.now() < self.retry_at then return end
    self.retry_at = self.now() + self.backoff
    self.backoff = math.min(self.backoff * 2, 3600)
    self.state.retry_at, self.state.backoff = self.retry_at, self.backoff
    local fresh = {}
    local cutoff = os.date('!%Y-%m-%dT%H:%M:%SZ', self.now() - 29 * 86400)
    for _, event in ipairs(self.state.pending) do
        if event.at >= cutoff then table.insert(fresh, event) end
    end
    self.state.pending = fresh
    if #fresh == 0 then self:save(); return end
    self:save()
    local account, sequence = self.state.account, fresh[#fresh].sequence
    self.sending = true
    local ok = pcall(send, { outcomes = fresh }, function(accepted)
        self.sending = false
        if accepted and self.state.account == account then
            self.backoff, self.retry_at = 60, 0
            self.state.backoff, self.state.retry_at = nil, nil
            local remaining = {}
            for _, event in ipairs(self.state.pending) do
                if event.sequence > sequence then table.insert(remaining, event) end
            end
            self.state.pending = remaining
            pcall(function() self:save() end)
        end
    end)
    if not ok then self.sending = false end
end
return Diagnostics

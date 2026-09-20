local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local util = require("util")
local sha256 = require("ffi/sha2").sha256
-- Traduce con el i18n del plugin si está en disco. En un arranque en frío
-- (bootstrap_only) este archivo llega SOLO, así que el require va protegido y
-- cae al gettext de KOReader, que devuelve el inglés tal cual.
local has_i18n, I18n = pcall(require, "i18n")
local _ = has_i18n and I18n or require("gettext")

-- OJO: este módulo no puede depender de ningún otro archivo del plugin más
-- que `plugin_version`. El arranque en frío de un actualizador viejo lo
-- descarga SOLO (`bootstrap_only`), así que un `require` a un módulo que
-- todavía no está en disco dejaría el plugin sin cargar. Por eso la cuenta de
-- versiones y el filtro de prereleases viven acá adentro, duplicados a
-- propósito con `updatecheck.lua`, y hay una prueba que los compara.
local Version = require("plugin_version")

local Updater = {}
Updater.__index = Updater
Updater.VERSION = Version
Updater.PROTOCOL_VERSION = 2

-- C23 · Qué forma de manifiesto entiende este actualizador. Va aparte de
-- PROTOCOL_VERSION: el protocolo describe al cliente, el esquema al
-- documento. Un manifiesto con un esquema mayor viene de un servidor que
-- sabe más que nosotros y no se instala a ciegas.
Updater.MANIFEST_SCHEMA = 1
Updater.STABLE_CHANNEL = "stable"

local MAX_FILES = 100
local MAX_FILE_BYTES = 2 * 1024 * 1024
local MAX_RELEASE_BYTES = 8 * 1024 * 1024
local REQUIRED_FILES = {
    ["_meta.lua"] = true,
    ["main.lua"] = true,
    ["plugin_version.lua"] = true,
    ["updater.lua"] = true,
}
local PROTECTED_BASENAMES = {
    ["dropbox_config.json"] = true,
    ["web_config.json"] = true,
}

local function shellQuote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function runCommand(command)
    local result = os.execute(command)
    return result == true or result == 0
end

local function fileExists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function fileSize(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function dirname(path)
    return path:match("(.+)/[^/]+$") or "."
end

local function basename(path)
    return path:match("([^/]+)$") or path
end

local function isSafeRelativePath(path)
    if type(path) ~= "string" or path == "" then return false end
    if path:match("^/") or path:find("\\", 1, true) then return false end
    if path:find("%z") then return false end
    for part in path:gmatch("[^/]+") do
        if part == ".." or part == "." or part == "" then return false end
    end
    return true
end

--- Una versión publicable es sólo números y puntos. `2026.07.24-rc1`, `main`
-- o un SHA no lo son: `compareVersions` es numérica y trataría `-rc1` como
-- igual a la estable, así que sin este filtro un build de prueba del servidor
-- viajaría a los lectores.
local function isStableVersion(version)
    if type(version) ~= "string" or version == "" then return false end
    if not version:match("^%d[%d%.]*$") then return false end
    if version:match("%.%.") or version:match("%.$") then return false end
    return true
end

local function compareVersions(a, b)
    local left, right = {}, {}
    for part in tostring(a or ""):gmatch("[^%.%-]+") do
        table.insert(left, tonumber(part) or 0)
    end
    for part in tostring(b or ""):gmatch("[^%.%-]+") do
        table.insert(right, tonumber(part) or 0)
    end

    local count = math.max(#left, #right)
    for index = 1, count do
        local delta = (left[index] or 0) - (right[index] or 0)
        if delta ~= 0 then return delta end
    end
    return 0
end

local function makeDefaultFilesystem()
    return {
        exists = fileExists,
        size = fileSize,
        read = readFile,
        mkdir = function(path)
            return runCommand("mkdir -p " .. shellQuote(path))
        end,
        remove_tree = function(path)
            return runCommand("rm -rf " .. shellQuote(path))
        end,
        remove_file = function(path)
            if not fileExists(path) then return true end
            return os.remove(path) == true
        end,
        copy = function(source, destination)
            return runCommand(
                "cp -f " .. shellQuote(source) .. " " .. shellQuote(destination)
            )
        end,
        replace = function(source, destination)
            local temporary = destination .. ".toto-update-tmp"
            runCommand("rm -f " .. shellQuote(temporary))
            local copied = runCommand(
                "cp -f " .. shellQuote(source) .. " " .. shellQuote(temporary)
            )
            if not copied then return false end
            local replaced = runCommand(
                "mv -f " .. shellQuote(temporary) .. " " .. shellQuote(destination)
            )
            if not replaced then runCommand("rm -f " .. shellQuote(temporary)) end
            return replaced
        end,
    }
end

local function defaultSha256File(path)
    local content = readFile(path)
    if content == nil then return nil end
    return sha256(content):lower()
end

local function defaultSyntaxCheck(path)
    local compiled, err = loadfile(path)
    if not compiled then return false, err end
    return true
end

function Updater:new(plugin, web_api, options)
    options = options or {}
    local settings_dir = options.settings_dir or DataStorage:getSettingsDir()
    local instance = setmetatable({
        plugin = plugin,
        web_api = web_api,
        settings_dir = settings_dir,
        filesystem = options.filesystem or makeDefaultFilesystem(),
        sha256_file = options.sha256_file or defaultSha256File,
        syntax_check = options.syntax_check or defaultSyntaxCheck,
        now = options.now or os.time,
        journal_store = options.journal_store
            or LuaSettings:open(settings_dir .. "/highlightsdetoto_update_journal.lua"),
    }, self)
    instance.journal = instance.journal_store:readSetting("state")
    local recovered, recovery_err = instance:recoverInterruptedInstall()
    if recovered then
        logger.warn("Borges: recovered an interrupted plugin update")
    elseif recovery_err then
        logger.warn(
            "Borges: plugin update recovery remains pending:",
            tostring(recovery_err)
        )
    end
    return instance
end

--- Recover before main.lua imports other plugin modules. This prevents a
-- power loss between atomic file replacements from leaving mixed-version
-- dependencies loaded before normal plugin initialization can run.
function Updater.recoverAtLoad(plugin_dir)
    if type(plugin_dir) ~= "string" or plugin_dir == "" then return false end
    local instance = Updater:new({
        getPluginDir = function() return plugin_dir end,
    }, {})
    return instance.journal == nil
end

function Updater:getCurrentVersion()
    return tostring(self.VERSION or "0.0.0")
end

function Updater:getManifestUrl()
    return self.plugin:getBaseUrl()
        .. "/api/plugin/highlightsdetoto/manifest?current_version="
        .. util.urlEncode(self:getCurrentVersion())
        .. "&integrity=1&updater_protocol="
        .. tostring(self.PROTOCOL_VERSION)
end

function Updater:fetchManifest()
    if not self.plugin:isWebConfigured() then
        return nil, _("Web sync is not configured.")
    end

    local manifest, err = self.web_api:getJSON(
        self:getManifestUrl(),
        self.plugin:getWebAuth(),
        true
    )
    if not manifest then return nil, err end

    local valid, validation_err = self:_validateManifest(manifest, true)
    if not valid then return nil, validation_err end
    manifest.update_available = manifest.update_available
        or compareVersions(self:getCurrentVersion(), manifest.version) < 0
    return manifest
end

function Updater:install(manifest)
    local ok, err = self:_validateManifest(manifest, false)
    if not ok then return false, err end

    local recovered, recovery_err = self:recoverInterruptedInstall()
    if not recovered and recovery_err then return false, recovery_err end

    local stage_dir = self.settings_dir .. "/highlightsdetoto_update_stage"
    local plugin_dir = self.plugin:getPluginDir()
    local previous_journal = self.journal
    local backup_a = self.settings_dir .. "/highlightsdetoto_update_backup_a"
    local backup_b = self.settings_dir .. "/highlightsdetoto_update_backup_b"
    local active_backup = previous_journal
        and previous_journal.status == "ready_rollback"
        and previous_journal.backup_dir
        or nil
    local backup_dir = active_backup == backup_a and backup_b or backup_a

    self.filesystem.remove_tree(stage_dir)
    if not self.filesystem.mkdir(stage_dir) then
        return false, _("Could not create update staging folder.")
    end

    ok, err = self:_downloadFiles(manifest.files, stage_dir)
    if ok then ok, err = self:_syntaxCheckFiles(manifest.files, stage_dir) end
    if ok then ok, err = self:_verifyReleaseVersion(manifest, stage_dir) end
    if not ok then
        self.filesystem.remove_tree(stage_dir)
        return false, err
    end

    self.filesystem.remove_tree(backup_dir)
    if not self.filesystem.mkdir(backup_dir) then
        self.filesystem.remove_tree(stage_dir)
        return false, _("Could not create update backup folder.")
    end

    local rollback_files
    rollback_files, err = self:_prepareBackup(
        manifest.files,
        plugin_dir,
        backup_dir
    )
    if not rollback_files then
        self.filesystem.remove_tree(stage_dir)
        self.filesystem.remove_tree(backup_dir)
        return false, err
    end

    self:_saveJournal({
        status = "installing",
        target_version = manifest.version,
        previous_version = self:getCurrentVersion(),
        plugin_dir = plugin_dir,
        stage_dir = stage_dir,
        backup_dir = backup_dir,
        files = rollback_files,
        started_at = self.now(),
    })
    if active_backup and active_backup ~= backup_dir then
        self.filesystem.remove_tree(active_backup)
    end

    ok, err = self:_installFiles(manifest.files, stage_dir, plugin_dir)
    self.filesystem.remove_tree(stage_dir)
    if not ok then
        local restored, restore_err = self:_restoreBackup(
            rollback_files,
            backup_dir,
            plugin_dir
        )
        if restored then
            self.filesystem.remove_tree(backup_dir)
            self:_saveJournal(nil)
            return false, err
        end
        return false, tostring(err) .. "; " .. tostring(restore_err)
    end

    self:_saveJournal({
        status = "ready_rollback",
        target_version = manifest.version,
        previous_version = self:getCurrentVersion(),
        plugin_dir = plugin_dir,
        backup_dir = backup_dir,
        files = rollback_files,
        installed_at = self.now(),
    })
    logger.info("Borges: plugin updated to", manifest.version)
    return true
end

function Updater:hasRollback()
    return type(self.journal) == "table"
        and self.journal.status == "ready_rollback"
        and type(self.journal.files) == "table"
        and type(self.journal.backup_dir) == "string"
end

function Updater:getRollbackVersion()
    return self:hasRollback() and self.journal.previous_version or nil
end

function Updater:rollback()
    if not self:hasRollback() then
        return false, _("No plugin rollback is available.")
    end
    local state = self.journal
    state.status = "restoring"
    self:_saveJournal(state)
    local ok, err = self:_restoreBackup(
        state.files,
        state.backup_dir,
        state.plugin_dir or self.plugin:getPluginDir()
    )
    if not ok then return false, err end
    self.filesystem.remove_tree(state.backup_dir)
    self:_saveJournal(nil)
    logger.warn(
        "Borges: plugin rolled back to",
        tostring(state.previous_version)
    )
    return true
end

function Updater:recoverInterruptedInstall()
    local state = self.journal
    if type(state) ~= "table"
        or (state.status ~= "installing" and state.status ~= "restoring") then
        return false
    end
    local ok, err = self:_restoreBackup(
        state.files or {},
        state.backup_dir,
        state.plugin_dir or self.plugin:getPluginDir()
    )
    if not ok then return false, err end
    if state.stage_dir then self.filesystem.remove_tree(state.stage_dir) end
    if state.backup_dir then self.filesystem.remove_tree(state.backup_dir) end
    self:_saveJournal(nil)
    return true
end

function Updater:_saveJournal(state)
    self.journal = state
    self.journal_store:saveSetting("state", state)
    self.journal_store:flush()
end

function Updater:_validateManifest(manifest, allow_current)
    if type(manifest) ~= "table" or manifest.plugin ~= "highlightsdetoto" then
        return false, _("Invalid update manifest.")
    end
    if manifest.install_mode ~= "overlay" then
        return false, _("Update manifest has an unsupported install mode.")
    end
    if type(manifest.version) ~= "string" or manifest.version == "" then
        return false, _("Update manifest has no version.")
    end

    -- C23 · Contrato de release. Un servidor viejo no manda estos campos y
    -- se sigue aceptando; lo que no se acepta es un servidor que SÍ los manda
    -- y declara algo que este actualizador no puede instalar.
    if manifest.manifest_schema ~= nil
        and (type(manifest.manifest_schema) ~= "number"
            or manifest.manifest_schema > self.MANIFEST_SCHEMA) then
        return false, _("Update manifest uses a newer format than this plugin understands.")
    end
    if manifest.channel ~= nil and manifest.channel ~= self.STABLE_CHANNEL then
        return false, _("Update manifest is not from the stable channel.")
    end
    if manifest.prerelease == true
        or not isStableVersion(manifest.version) then
        return false, _("Update manifest describes a pre-release build.")
    end
    if type(manifest.requires) == "table"
        and type(manifest.requires.updater_protocol) == "number"
        and manifest.requires.updater_protocol > self.PROTOCOL_VERSION then
        return false, _("This release needs a newer updater.")
    end

    if not allow_current
        and compareVersions(self:getCurrentVersion(), manifest.version) >= 0 then
        return false, _("Update version is not newer than the installed version.")
    end
    if type(manifest.files) ~= "table"
        or #manifest.files == 0
        or #manifest.files > MAX_FILES then
        return false, _("Update manifest has an invalid file count.")
    end

    local seen, required, total_size = {}, {}, 0
    for file_index, file in ipairs(manifest.files) do
        if type(file) ~= "table" or not isSafeRelativePath(file.path) then
            return false, _("Update manifest contains an unsafe file path.")
        end
        if PROTECTED_BASENAMES[basename(file.path)] then
            return false, _("Update manifest attempts to replace local configuration.")
        end
        if seen[file.path] then
            return false, _("Update manifest contains a duplicate file path.")
        end
        seen[file.path] = true
        required[file.path] = true
        if type(file.download_url) ~= "string"
            or not file.download_url:match(
                "^/api/plugin/highlightsdetoto/file%?path="
            ) then
            return false, _("Update manifest contains an unsafe download URL.")
        end
        if type(file.size) ~= "number"
            or file.size < 0
            or file.size ~= math.floor(file.size)
            or file.size > MAX_FILE_BYTES then
            return false, _("Update manifest contains an invalid file size.")
        end
        if type(file.sha256) ~= "string"
            or not file.sha256:match("^[0-9a-fA-F]+$")
            or #file.sha256 ~= 64 then
            return false, _("Update manifest contains an invalid SHA-256 checksum.")
        end
        total_size = total_size + file.size
        if total_size > MAX_RELEASE_BYTES then
            return false, _("Update manifest exceeds the release size limit.")
        end
    end
    for path in pairs(REQUIRED_FILES) do
        if not required[path] then
            return false, _("Update manifest is missing a required plugin file.")
        end
    end
    return true
end

function Updater:_downloadFiles(files, stage_dir)
    for file_index, file in ipairs(files) do
        local destination = stage_dir .. "/" .. file.path
        if not self.filesystem.mkdir(dirname(destination)) then
            return false, _("Could not create update file folder.")
        end
        local ok, err = self.web_api:downloadFile(
            self.plugin:getBaseUrl() .. file.download_url,
            self.plugin:getWebAuth(),
            destination
        )
        if not ok then return false, err end
        ok, err = self:_verifyFile(destination, file)
        if not ok then return false, err end
    end
    return true
end

function Updater:_verifyFile(path, file)
    if self.filesystem.size(path) ~= file.size then
        return false, _("Downloaded plugin file size did not match manifest.")
    end
    local actual = self.sha256_file(path)
    if type(actual) ~= "string" or #actual ~= 64 then
        return false, _("Downloaded plugin file could not be SHA-256 verified.")
    end
    if actual:lower() ~= file.sha256:lower() then
        return false, _("Downloaded plugin file checksum did not match manifest.")
    end
    return true
end

function Updater:_syntaxCheckFiles(files, stage_dir)
    for file_index, file in ipairs(files) do
        if file.path:match("%.lua$") then
            local ok, err = self.syntax_check(stage_dir .. "/" .. file.path)
            if not ok then
                return false, _("Downloaded plugin contains invalid Lua: ")
                    .. tostring(err or file.path)
            end
        end
    end
    return true
end

function Updater:_verifyReleaseVersion(manifest, stage_dir)
    local content = self.filesystem.read(stage_dir .. "/plugin_version.lua")
    local staged_version = content
        and content:match("return%s+[\"']([^\"']+)[\"']")
        or nil
    if staged_version ~= manifest.version then
        return false, _("Downloaded plugin version does not match manifest.")
    end
    return true
end

function Updater:_prepareBackup(files, plugin_dir, backup_dir)
    local rollback_files = {}
    for file_index, file in ipairs(files) do
        local destination = plugin_dir .. "/" .. file.path
        local backup = backup_dir .. "/" .. file.path
        local existed = self.filesystem.exists(destination)
        table.insert(rollback_files, {
            path = file.path,
            existed = existed,
        })
        if existed then
            if not self.filesystem.mkdir(dirname(backup))
                or not self.filesystem.copy(destination, backup) then
                return nil, _("Could not create plugin update backup.")
            end
        end
    end
    return rollback_files
end

function Updater:_installFiles(files, stage_dir, plugin_dir)
    for file_index, file in ipairs(files) do
        local source = stage_dir .. "/" .. file.path
        local destination = plugin_dir .. "/" .. file.path
        if not self.filesystem.mkdir(dirname(destination))
            or not self.filesystem.replace(source, destination) then
            return false, _("Could not atomically install downloaded plugin file.")
        end
    end
    return true
end

function Updater:_restoreBackup(files, backup_dir, plugin_dir)
    if type(backup_dir) ~= "string" or type(plugin_dir) ~= "string" then
        return false, _("Plugin update recovery metadata is incomplete.")
    end
    for index = #files, 1, -1 do
        local file = files[index]
        if not isSafeRelativePath(file.path) then
            return false, _("Plugin update recovery path is unsafe.")
        end
        local destination = plugin_dir .. "/" .. file.path
        if file.existed then
            local backup = backup_dir .. "/" .. file.path
            if not self.filesystem.exists(backup)
                or not self.filesystem.mkdir(dirname(destination))
                or not self.filesystem.replace(backup, destination) then
                return false, _("Could not restore plugin update backup.")
            end
        elseif not self.filesystem.remove_file(destination) then
            return false, _("Could not remove a partially installed plugin file.")
        end
    end
    return true
end

Updater.compareVersions = compareVersions
Updater.isSafeRelativePath = isSafeRelativePath
Updater.isStableVersion = isStableVersion

return Updater

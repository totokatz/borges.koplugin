-- Data-only persistence boundary for LuaSettings (Lua 5.1 / LuaJIT).
-- Never give dump a rapidjson userdata, and never execute a settings file.
local json = require("rapidjson")
local Storage = {}
local FORMAT = "borges-queue-null-paths-1"
local MAX_FILE_BYTES = 32 * 1024 * 1024
local nullable = { documentId = true, document_id = true, ["local"] = true,
    revision = true, monotonic_ms = true, total_pages = true }

function Storage.pack(value)
    local nulls, containers, active = {}, {}, {}
    local function copy(item, path, depth)
        -- Reserve one level for the storage envelope's data field.
        assert(depth < 127, "Queue state nesting limit exceeded")
        if json.null ~= nil and item == json.null then
            nulls[#nulls + 1] = path
            return false -- path metadata distinguishes null from false, absent and {}.
        end
        local kind = type(item)
        if kind == "table" then
            assert(not active[item], "Cyclic queue state")
            active[item] = true
            local mt = getmetatable(item)
            if mt and mt.__jsontype then
                assert(mt.__jsontype == "array" or mt.__jsontype == "object", "Invalid JSON container")
                containers[#containers + 1] = { path = path, kind = mt.__jsontype }
            end
            local result = {}
            for key, child in pairs(item) do
                assert(type(key) == "string" or (type(key) == "number" and key == key
                    and math.abs(key) < math.huge), "Unsupported queue key")
                local child_path = {}
                for i, part in ipairs(path) do child_path[i] = part end
                child_path[#child_path + 1] = key
                result[key] = copy(child, child_path, depth + 1)
            end
            active[item] = nil
            return result
        end
        assert(kind == "string" or kind == "boolean" or kind == "nil"
            or (kind == "number" and item == item and math.abs(item) < math.huge),
            "Unsupported queue value: " .. kind)
        return item
    end
    local data = copy(value, {}, 0)
    return { format = FORMAT, data = data, nulls = nulls, containers = containers }
end

function Storage.unpack(stored)
    if stored.format ~= FORMAT then
        assert(stored.format == nil, "Unknown queue storage format")
        return stored
    end
    assert(type(stored.data) == "table" and type(stored.nulls) == "table"
        and type(stored.containers) == "table", "Invalid queue storage envelope")
    local function locate(path)
        assert(type(path) == "table", "Invalid queue path")
        local parent = stored.data
        for i = 1, #path - 1 do
            parent = parent[path[i]]
            assert(type(parent) == "table", "Invalid queue path")
        end
        return parent, path[#path]
    end
    for _, path in ipairs(stored.nulls) do
        local parent, key = locate(path)
        assert(key ~= nil and parent[key] == false and json.null ~= nil, "Invalid null path")
        parent[key] = json.null
    end
    for _, container in ipairs(stored.containers) do
        local parent, key = locate(container.path)
        local value = key ~= nil and parent[key] or parent
        assert(type(value) == "table" and (container.kind == "array" or container.kind == "object"),
            "Invalid container path")
        setmetatable(value, { __jsontype = container.kind })
    end
    return stored.data
end

-- Only the literal grammar emitted by KOReader dump. No load/loadstring/dofile,
-- expressions, calls, identifiers, bytecode or global environment are accepted.
function Storage.parse(source)
    assert(type(source) == "string" and #source <= MAX_FILE_BYTES, "Queue file too large")
    local pos, repairs = 1, 0
    local function skip()
        while true do
            local _, last = source:find("^%s+", pos)
            if last then pos = last + 1 end
            if source:sub(pos, pos + 1) ~= "--" then return end
            assert(source:sub(pos + 2, pos + 2) ~= "[", "Block comments are not queue data")
            pos = (source:find("\n", pos, true) or #source) + 1
        end
    end
    local function take(token)
        skip()
        assert(source:sub(pos, pos + #token - 1) == token, "Invalid queue literal at byte " .. pos)
        pos = pos + #token
    end
    local function quoted()
        local quote, parts = source:sub(pos, pos), {}
        pos = pos + 1
        while pos <= #source do
            local char = source:sub(pos, pos)
            pos = pos + 1
            if char == quote then return table.concat(parts) end
            if char == "\\" then
                char = source:sub(pos, pos)
                pos = pos + 1
                local escapes = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
                    v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n" }
                if char:match("%d") then
                    local digits = char .. (source:match("^%d?%d?", pos) or "")
                    pos = pos + #digits - 1
                    assert(tonumber(digits) <= 255, "Invalid byte escape")
                    char = string.char(tonumber(digits))
                elseif char == "\r" then
                    if source:sub(pos, pos) == "\n" then pos = pos + 1 end
                    char = "\n"
                else
                    assert(escapes[char], "Invalid string escape")
                    char = escapes[char]
                end
            else
                assert(char ~= "\n" and char ~= "\r", "Unescaped newline")
            end
            parts[#parts + 1] = char
        end
        error("Unterminated queue string")
    end
    local value
    value = function(depth)
        assert(depth < 128, "Queue nesting limit exceeded")
        skip()
        local char = source:sub(pos, pos)
        if char == '"' or char == "'" then return quoted() end
        if char == "{" then
            pos = pos + 1
            local result, seen = {}, {}
            skip()
            while source:sub(pos, pos) ~= "}" do
                take("[")
                local key = value(depth + 1)
                assert(type(key) == "string" or type(key) == "number", "Invalid queue key")
                assert(not seen[key], "Duplicate queue key")
                seen[key] = true
                take("]")
                take("=")
                skip()
                if source:sub(pos, pos) == "," then
                    assert(nullable[key] and json.null ~= nil, "Unknown empty queue assignment")
                    result[key] = json.null
                    repairs = repairs + 1
                else
                    result[key] = value(depth + 1)
                end
                take(",")
                skip()
            end
            pos = pos + 1
            return result
        end
        for _, word in ipairs({ "true", "false", "nil" }) do
            if source:sub(pos, pos + #word - 1) == word then
                pos = pos + #word
                if word == "true" then return true end
                if word == "false" then return false end
                return nil
            end
        end
        local number = source:match("^[+-]?%d+%.?%d*[eE][+-]?%d+", pos)
            or source:match("^[+-]?%d+%.?%d*", pos)
        assert(number, "Unsupported queue literal at byte " .. pos)
        pos = pos + #number
        local parsed = tonumber(number)
        assert(parsed and math.abs(parsed) < math.huge, "Invalid queue number")
        return parsed
    end
    take("return")
    local result = value(0)
    skip()
    assert(pos > #source and type(result) == "table", "Trailing or invalid queue data")
    return result, repairs
end

local function read(path)
    local lfs = require("libs/libkoreader-lfs")
    local mode = lfs.attributes(path, "mode")
    if mode == nil then return nil end
    assert(mode == "file", "Queue path is not a file: " .. path)
    local file = assert(io.open(path, "rb"))
    local content = file:read(MAX_FILE_BYTES + 1)
    file:close()
    assert(content and #content <= MAX_FILE_BYTES, "Queue file too large")
    return content
end

local function write(path, content, temporary)
    assert(require("util").writeToFile(content, path, true, false, not temporary), "Cannot write queue file: " .. path)
    assert(read(path) == content, "Queue write verification failed: " .. path)
end

local function preserve(path, content)
    if not content then return end
    local backup, index = path .. ".pre-null-repair", 0
    while read(backup) do
        if read(backup) == content then return end
        index = index + 1
        backup = path .. ".pre-null-repair." .. index
    end
    write(backup, content)
end

function Storage.open(path)
    local LuaSettings = require("luasettings")
    local primary, previous = read(path), read(path .. ".old")
    local raw = primary or previous
    local data, repairs, format = {}, 0, nil
    if raw then
        local parsed
        parsed, repairs = Storage.parse(raw) -- fail closed; never silently reset existing data.
        format = parsed.format
        data = Storage.unpack(parsed)
        local empty_legacy = path:match("/highlightsdetoto_queue%.lua$") and next(data) == nil
        assert(type(data.state) == "table" or type(data.pending) == "table" or empty_legacy,
            "Missing queue state")
    end
    if raw and (repairs > 0 or format ~= FORMAT or not primary) then
        -- Preserve BOTH generations before LuaSettings can rotate either one.
        preserve(path, primary)
        preserve(path .. ".old", previous)
        if previous then
            local ok, old = pcall(function() return Storage.unpack(Storage.parse(previous)) end)
            if ok then
                local recovered = "return " .. require("dump")(Storage.pack(old), nil, true) .. "\n"
                write(path .. ".old.recovered", recovered)
            end
        end
        require("logger").warn("Borges: preserved queue originals; recovered null assignments:", repairs)
    end
    local store = LuaSettings:wrap(data)
    store.file = path
    -- The primary was parsed and validated above. Every later primary is the
    -- exact content we encoded, read back and published ourselves. Reparsing
    -- either generation on *every* save stalls the UI on slower readers.
    local backup_primary = primary
    local primary_is_packed = primary ~= nil and format == FORMAT and repairs == 0
    if primary and not primary_is_packed then
        -- Unchanged saves may now skip rotation forever. Give a migrated
        -- primary a readable predecessor too; its raw original was preserved.
        backup_primary = "return " .. require("dump")(Storage.pack(data), nil, true) .. "\n"
    end
    -- LuaSettings' stock flush ignores write errors and truncates the destination.
    -- Keep its settings API, but publish a verified, fsynced temporary atomically.
    store.flush = function(self)
        local content = "return " .. require("dump")(Storage.pack(self.data), nil, true) .. "\n"
        -- pack validates types/cycles/limits before KOReader's literal encoder.
        -- Keep the safe parser at the untrusted disk boundary, not in this hot
        -- path. Round-trip tests exercise the actual KOReader dump and LuaJIT.
        assert(#content <= MAX_FILE_BYTES, "Queue file too large")
        if content == primary then return self end
        write(path .. ".tmp", content, true)
        local moved_primary = false
        if backup_primary then
            if primary_is_packed then
                -- Like LuaSettings:backup, rotate the existing durable file
                -- instead of rewriting/fsyncing its entire contents again.
                assert(os.rename(path, path .. ".old"))
                moved_primary = true
            else
                -- The migration's raw originals stay immutable; rotate a
                -- readable version of the recovered primary instead.
                write(path .. ".old.tmp", backup_primary, true)
                assert(os.rename(path .. ".old.tmp", path .. ".old"))
            end
            require("ffi/util").fsyncDirectory(path)
        end
        local published, err = os.rename(path .. ".tmp", path)
        if not published and moved_primary then
            -- A failed publish restores the current path when possible. If
            -- interrupted here, open() recovers the exact same state from .old.
            os.rename(path .. ".old", path)
            require("ffi/util").fsyncDirectory(path)
        end
        assert(published, err)
        require("ffi/util").fsyncDirectory(path)
        primary = content
        backup_primary = content
        primary_is_packed = true
        return self
    end
    return store
end

return Storage

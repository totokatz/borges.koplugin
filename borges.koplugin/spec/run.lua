package.path = "highlightsdetoto.koplugin/?.lua;" .. package.path

local stores = {}
local uuid_counter = 0

package.preload["gettext"] = function()
    -- Misma forma que el gettext real de KOReader: tabla llamable con current_lang.
    return setmetatable({ current_lang = "C" }, { __call = function(_, value) return value end })
end

package.preload["logger"] = function()
    return {
        warn = function() end,
        info = function() end,
        dbg = function() end,
    }
end

package.preload["random"] = function()
    return {
        uuid = function(with_dash)
            uuid_counter = uuid_counter + 1
            local tail = string.format("%012x", uuid_counter)
            if with_dash then return "00000000-0000-4000-8000-" .. tail end
            return "00000000000040008000" .. tail
        end,
    }
end

local function newStore(name)
    stores[name] = stores[name] or {}
    local data = stores[name]
    return {
        readSetting = function(_, key) return data[key] end,
        saveSetting = function(_, key, value) data[key] = value; return value end,
        flush = function(self) return self end,
    }
end

package.preload["luasettings"] = function()
    return { open = function(_, path) return newStore(path) end }
end

local function encode(value)
    local value_type = type(value)
    if value_type == "nil" then return "null" end
    if value_type == "boolean" or value_type == "number" then return tostring(value) end
    if value_type == "string" then return string.format("%q", value) end
    if value_type ~= "table" then error("unsupported JSON value") end
    local array = #value > 0
    local parts = {}
    if array then
        for _, item in ipairs(value) do table.insert(parts, encode(item)) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for key, item in pairs(value) do
        table.insert(parts, encode(tostring(key)) .. ":" .. encode(item))
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

package.preload["rapidjson"] = function()
    return { encode = encode }
end
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp" end }
end
package.preload["util"] = function()
    return {
        urlEncode = function(value)
            return tostring(value):gsub("([^%w%-_%.~])", function(char)
                return string.format("%%%02X", char:byte())
            end)
        end,
    }
end
package.preload["ffi/util"] = function()
    return {
        template = function(pattern, ...)
            local params = {...}
            if #params == 0 then return pattern end
            return (pattern:gsub("%%([1-9])", function(index)
                local value = params[tonumber(index)]
                if value == nil then return "%" .. index end
                return tostring(value)
            end))
        end,
    }
end
package.preload["lua-ljsqlite3/init"] = function()
    return {}
end
package.preload["ffi/sha2"] = function()
    local function digest(value)
        local a, b, c, d = 5381, 52711, 104729, 130363
        for index = 1, #value do
            local byte = value:byte(index)
            a = (a * 33 + byte) % 2147483647
            b = (b * 37 + byte + index) % 2147483647
            c = (c * 39 + byte * 3) % 2147483647
            d = (d * 41 + byte * 7) % 2147483647
        end
        return string.format("%08x%08x%08x%08x", a, b, c, d)
    end
    return {
        md5 = digest,
        sha256 = function(value)
            return digest(value) .. digest("sha256:" .. value)
        end,
    }
end

local passed = 0
local function test(name, callback)
    local ok, err = pcall(callback)
    if not ok then
        io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n")
        os.exit(1)
    end
    passed = passed + 1
    io.write("ok - " .. name .. "\n")
end

local function equal(expected, actual)
    assert(expected == actual, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local SettingsMigration = require("settingsmigration")
local Pairing = require("pairing")
local Login = require("login")
local Queue = require("queue")
local SyncV2 = require("syncv2")
local StatSync = require("statsync")
local Session = require("session")
local AnnotationAdapter = require("annotationadapter")
local Updater = require("updater")
local SyncRun = require("syncrun")
local MenuTree = require("menutree")
local ReadingPosition = require("readingposition")
local ResumeFlow = require("resumeflow")
local UpdateCheck = require("updatecheck")

test("settings migration preserves fallback and prefers paired auth", function()
    local settings = SettingsMigration.migrate(
        { web_url = "https://example.test/api/sync", web_api_key = "legacy" },
        {}
    )
    equal("https://example.test", settings.server_base_url)
    equal("legacy", SettingsMigration.getAuth(settings).api_key)
    settings.device_token = "toto_device_token"
    settings.paired_device_id = "device-id"
    equal("toto_device_token", SettingsMigration.getAuth(settings).token)
    assert(SettingsMigration.retireLegacyCredential(settings))
    equal("", settings.web_api_key)
end)

test("legacy migration autoapproves, claims, verifies, and commits", function()
    local calls, pending, committed = {}, nil, nil
    local fake_api = {
        apiError = function(_, code, message)
            return { code = code, message = message }
        end,
        postJSON = function(_, url, auth, payload)
            table.insert(calls, { url = url, auth = auth, payload = payload })
            if url:match("/request$") then
                return {
                    request_id = "request-id",
                    user_code = "ABCD-2345",
                    verification_url = "/devices/pair",
                    interval = 5,
                }
            elseif url:match("/approve$") then
                equal("legacy-key", auth.api_key)
                return { status = "approved" }
            elseif url:match("/claim$") then
                return {
                    device = { id = "paired-id" },
                    credential = { token = "toto_claimed", id = "credential-id" },
                }
            end
        end,
        getJSON = function(_, url, auth)
            assert(url:match("/devices/self$"))
            equal("toto_claimed", auth.token)
            return { device = { id = "paired-id" } }
        end,
    }
    local pairing = Pairing:new{
        web_api = fake_api,
        base_url = "https://example.test",
        save_pending = function(value) pending = value end,
        clear_pending = function() pending = nil end,
        commit_credential = function(value) committed = value end,
        now = function() return 100 end,
    }
    local result, err = pairing:start{
        device_name = "Kobo",
        install_id = "install-id",
        legacy_api_key = "legacy-key",
    }
    assert(not err)
    equal("toto_claimed", result.credential.token)
    equal("toto_claimed", committed.credential.token)
    equal(nil, pending)
    equal(3, #calls)
end)

test("outbox survives restart and retries immutable content", function()
    local store = newStore("v2-restart")
    local legacy = newStore("legacy-restart")
    local queue = Queue:new("unused", {
        store = store,
        legacy_store = legacy,
        now = function() return 100 end,
    })
    local event = queue:enqueueEvent{
        event_type = "progress.changed",
        aggregate_type = "book",
        aggregate_id = "book:abc",
        book_identifier = { kind = "koreader_partial_md5", value = "abc" },
        payload = { percentage = 20 },
    }
    local first = queue:prepareBatch(20, 10000, true)
    equal(event.client_event_id, first[1].client_event_id)
    local restarted = Queue:new("unused", {
        store = store,
        legacy_store = legacy,
        now = function() return 101 end,
    })
    local retry = restarted:prepareBatch(20, 10000, true)
    equal(first[1].client_event_id, retry[1].client_event_id)
    equal(first[1].client_sequence, retry[1].client_sequence)
    equal(1, restarted:v2Count())
end)

test("progress coalesces only before its first transport attempt", function()
    local queue = Queue:new("coalesce-test", {
        store = newStore("v2-coalesce"),
        legacy_store = newStore("legacy-coalesce"),
    })
    local first = queue:enqueueEvent({
        event_type = "progress.changed",
        aggregate_type = "reading_progress",
        aggregate_id = "book:coalesce",
        payload = { percentage = 10 },
    }, { coalesce_unattempted = true })
    local second, coalesced = queue:enqueueEvent({
        event_type = "progress.changed",
        aggregate_type = "reading_progress",
        aggregate_id = "book:coalesce",
        payload = { percentage = 20 },
    }, { coalesce_unattempted = true })
    assert(coalesced)
    equal(first.client_event_id, second.client_event_id)
    equal(1, queue:v2Count())
    equal(20, queue:prepareBatch(20, 10000, true)[1].payload.percentage)

    local third, attempted_coalesce = queue:enqueueEvent({
        event_type = "progress.changed",
        aggregate_type = "reading_progress",
        aggregate_id = "book:coalesce",
        payload = { percentage = 30 },
    }, { coalesce_unattempted = true })
    equal(nil, attempted_coalesce)
    assert(third.client_event_id ~= first.client_event_id)
    equal(2, queue:v2Count())
end)

test("ACK and deferred pull commit in one durable state change", function()
    local queue = Queue:new("ack-test", {
        store = newStore("v2-ack"),
        legacy_store = newStore("legacy-ack"),
        now = function() return 200 end,
    })
    local event = queue:enqueueEvent{
        event_type = "session.ended",
        aggregate_type = "session",
        aggregate_id = "session:1",
        payload = { duration_seconds = 120 },
    }
    local result = assert(queue:commitExchange({
        protocol_version = 2,
        acknowledgements = {{
            client_event_id = event.client_event_id,
            client_sequence = event.client_sequence,
            status = "accepted",
            server_sequence = "8",
        }},
        pull = {
            cursor = "9",
            events = {{ event_id = "remote-1", server_sequence = "9" }},
            has_more = false,
        },
    }, function() return "defer" end))
    equal("9", result.cursor)
    equal(0, queue:v2Count())
    equal(1, queue:inboxCount())
end)

test("mismatched acknowledgement retains outbox", function()
    local queue = Queue:new("bad-ack-test", {
        store = newStore("v2-bad-ack"),
        legacy_store = newStore("legacy-bad-ack"),
    })
    local event = queue:enqueueEvent{
        event_type = "session.ended",
        aggregate_type = "session",
        aggregate_id = "session:2",
        payload = { duration_seconds = 120 },
    }
    local result, err = queue:commitExchange({
        protocol_version = 2,
        acknowledgements = {{
            client_event_id = event.client_event_id,
            client_sequence = "999",
            status = "accepted",
        }},
        pull = { cursor = "0", events = {}, has_more = false },
    }, function() return true end)
    equal(nil, result)
    equal("ack_sequence_mismatch", err)
    equal(1, queue:v2Count())
end)

test("legacy failures are retained beyond three attempts", function()
    local queue = Queue:new("legacy-retain-test", {
        store = newStore("v2-legacy-retain"),
        legacy_store = newStore("legacy-retain"),
    })
    queue:enqueue("session", { book_hash = "abc" })
    local fake_api = {
        postJSON = function() return nil, { code = "offline", message = "offline" } end,
        apiError = function(_, code, message) return { code = code, message = message } end,
    }
    for _ = 1, 5 do queue:drainOne(fake_api, "https://example.test", {}) end
    equal(1, queue:count())
end)

test("sync client sends exchange then commits acknowledgements", function()
    local queue = Queue:new("sync-client-test", {
        store = newStore("v2-sync-client"),
        legacy_store = newStore("legacy-sync-client"),
    })
    local event = queue:enqueueEvent{
        event_type = "progress.changed",
        aggregate_type = "book",
        aggregate_id = "book:sync",
        payload = { percentage = 50 },
    }
    local fake_api = {
        apiError = function(_, code, message) return { code = code, message = message } end,
        postJSON = function(_, url, auth, payload)
            assert(url:match("/exchange$"))
            equal("device-token", auth.token)
            equal(event.client_event_id, payload.events[1].client_event_id)
            return {
                protocol_version = 2,
                acknowledgements = {{
                    client_event_id = event.client_event_id,
                    client_sequence = event.client_sequence,
                    status = "accepted",
                    server_sequence = "3",
                }},
                pull = { cursor = "3", events = {}, has_more = false },
            }
        end,
    }
    local client = SyncV2:new{
        web_api = fake_api,
        queue = queue,
        base_url = "https://example.test",
        auth = { token = "device-token" },
        apply_event = function() return true end,
    }
    local result = assert(client:sync(true))
    equal("3", result.cursor)
    equal(0, queue:v2Count())
end)

test("syncAll continues while acknowledged outbox pages remain", function()
    local queue = Queue:new("sync-all-test", {
        store = newStore("v2-sync-all"),
        legacy_store = newStore("legacy-sync-all"),
    })
    for index = 1, 21 do
        queue:enqueueEvent{
            event_type = "session.ended",
            aggregate_type = "reading_session",
            aggregate_id = "session:" .. tostring(index),
            payload = { duration_seconds = 120 },
        }
    end
    local calls = 0
    local fake_api = {
        apiError = function(_, code, message) return { code = code, message = message } end,
        postJSON = function(_, _, _, payload)
            calls = calls + 1
            local acknowledgements = {}
            for _, event in ipairs(payload.events) do
                table.insert(acknowledgements, {
                    client_event_id = event.client_event_id,
                    client_sequence = event.client_sequence,
                    status = "accepted",
                    server_sequence = tostring(calls),
                })
            end
            return {
                protocol_version = 2,
                acknowledgements = acknowledgements,
                pull = { cursor = tostring(calls), events = {}, has_more = false },
            }
        end,
    }
    local client = SyncV2:new{
        web_api = fake_api,
        queue = queue,
        base_url = "https://example.test",
        auth = { token = "device-token" },
    }
    local result = assert(client:syncAll(true, 5, true))
    equal(2, calls)
    equal(0, result.pending)
    equal(21, result.acknowledged)
end)

test("page statistics v2 chunks are self-contained, row-bounded, and byte-bounded", function()
    local hash_a = string.rep("a", 32)
    local hash_b = string.rep("b", 32)
    local rows = {}
    for index = 1, 205 do
        table.insert(rows, {
            book_md5 = index % 2 == 0 and hash_a or hash_b,
            page = index,
            start_time = 1000 + index,
            duration = 10,
            total_pages = 300,
        })
    end
    local chunks = StatSync:getV2Chunks(rows, {
        { md5 = hash_a, title = "A", authors = "Author A", pages = 300 },
        { md5 = hash_b, title = "B", authors = "Author B", pages = 300 },
    })
    equal(3, #chunks)
    local counted = 0
    for _, chunk in ipairs(chunks) do
        assert(#chunk.rows <= 100)
        assert(#encode(chunk) <= 28 * 1024)
        assert(#chunk.books >= 1)
        counted = counted + #chunk.rows
    end
    equal(205, counted)
    equal(1205, StatSync:getMaxStartTime(rows))
end)

test("long reading sessions split into server-valid segments", function()
    local original_time = os.time
    local now = 100000
    os.time = function(value)
        if value then return original_time(value) end
        return now
    end
    local session = Session:new()
    session:start(string.rep("c", 32), "kobo", 10)
    now = now + (4 * 60 * 60) + 120
    session:updatePage(11)
    local segments = session:finishAll()
    os.time = original_time

    equal(2, #segments)
    equal(4 * 60 * 60, segments[1].duration_seconds)
    equal(120, segments[2].duration_seconds)
    assert(segments[1].duration_seconds <= 4 * 60 * 60)
    assert(segments[2].duration_seconds <= 4 * 60 * 60)
end)

test("annotation identities are deterministic and survive content edits", function()
    local book_hash = string.rep("d", 32)
    local first = {
        page = "/body/DocFragment[2]/body/p[4]",
        pos0 = "/body/DocFragment[2]/body/p[4]",
        pos1 = "/body/DocFragment[2]/body/p[5]",
        pageno = 12,
        drawer = "lighten",
        text = "A durable quote",
        note = "first note",
    }
    local same_locator = {
        page = first.page,
        pos0 = first.pos0,
        pos1 = first.pos1,
        pageno = 12,
        drawer = "lighten",
        text = "A durable quote",
        note = "edited elsewhere",
    }
    local a = AnnotationAdapter:normalize(book_hash, first)
    local b = AnnotationAdapter:normalize(book_hash, same_locator)
    equal(a.sync_id, b.sync_id)
    assert(a.sync_id:match(
        "^[0-9a-f]+%-[0-9a-f]+%-3[0-9a-f]+%-8[0-9a-f]+%-[0-9a-f]+$"
    ))
    assert(a.fingerprint ~= b.fingerprint)
end)

test("annotation diff emits create update and tombstone transitions", function()
    local book_hash = string.rep("e", 32)
    local annotation = {
        page = "/body/DocFragment[1]/body/p[1]",
        pos0 = "/body/DocFragment[1]/body/p[1]",
        pos1 = "/body/DocFragment[1]/body/p[2]",
        pageno = 2,
        drawer = "lighten",
        text = "First",
    }
    local book = { title = "Book", file = "book.epub", total_pages = 100 }
    local created, state, assigned = AnnotationAdapter:diff(
        book_hash,
        { annotation },
        {},
        book
    )
    equal(1, #created)
    equal("annotation.created", created[1].event_type)
    equal("0", created[1].payload.base_revision)
    equal("0", state[created[1].aggregate_id].revision)
    equal(true, state[created[1].aggregate_id].present)
    equal(1, assigned)

    local unchanged = AnnotationAdapter:diff(
        book_hash,
        { annotation },
        state,
        book
    )
    equal(0, #unchanged)

    state[created[1].aggregate_id].revision = "3"
    annotation.toto_revision = "3"
    annotation.note = "new note"
    local updated, updated_state = AnnotationAdapter:diff(
        book_hash,
        { annotation },
        state,
        book
    )
    equal(1, #updated)
    equal("annotation.updated", updated[1].event_type)
    equal(created[1].aggregate_id, updated[1].aggregate_id)
    equal("3", updated[1].payload.base_revision)

    updated_state[created[1].aggregate_id].revision = "4"
    local deleted, tombstone_state = AnnotationAdapter:diff(
        book_hash,
        {},
        updated_state,
        book
    )
    equal(1, #deleted)
    equal("annotation.deleted", deleted[1].event_type)
    equal(created[1].aggregate_id, deleted[1].aggregate_id)
    equal("4", deleted[1].payload.base_revision)
    equal(false, tombstone_state[created[1].aggregate_id].present)
    equal("4", tombstone_state[created[1].aggregate_id].revision)
    local no_duplicate_delete = AnnotationAdapter:diff(
        book_hash,
        {},
        tombstone_state,
        book
    )
    equal(0, #no_duplicate_delete)
end)

test("page bookmarks get stable non-empty wire text", function()
    local events = AnnotationAdapter:diff(
        string.rep("b", 32),
        {{ page = 12, pageno = 12 }},
        {},
        { title = "Book" }
    )
    equal(1, #events)
    equal("bookmark.upserted", events[1].event_type)
    equal("bookmark", events[1].payload.kind)
    equal("Bookmark - page 12", events[1].payload.text)
end)

test("remote rolling annotations apply exact create update and delete", function()
    local book_hash = string.rep("f", 32)
    local sync_id = "12345678-1234-3123-8123-123456789abc"
    local annotations = {}
    local payload = {
        sync_id = sync_id,
        kind = "highlight",
        text = "Remote",
        note = "note",
        chapter = "One",
        color = "yellow",
        drawer = "lighten",
        page = 4,
        xpointer = "/body/p[1]",
        position = { pos0 = "/body/p[1]", pos1 = "/body/p[2]" },
    }
    local created = assert(AnnotationAdapter:applyRemote({
        event_type = "annotation.created",
        aggregate_id = sync_id,
        payload = payload,
        directive_metadata = { annotation_revision = "7" },
    }, annotations, {
        mode = "rolling",
        book_hash = book_hash,
        validate_xpointer = function(value) return value:match("^/body/") ~= nil end,
    }))
    equal("created", created.action)
    equal(1, #annotations)
    equal(sync_id, annotations[1].toto_sync_id)
    equal("7", annotations[1].toto_revision)
    equal("7", created.revision)
    equal(true, created.present)

    local updated = assert(AnnotationAdapter:applyRemote({
        event_type = "annotation.updated",
        aggregate_id = sync_id,
        payload = {
            sync_id = sync_id,
            kind = "highlight",
            text = "Remote edited",
            page = 4,
            xpointer = "/body/p[1]",
            position = { pos0 = "/body/p[1]", pos1 = "/body/p[2]" },
        },
        directive_metadata = { annotation_revision = "8" },
    }, annotations, {
        mode = "rolling",
        book_hash = book_hash,
        validate_xpointer = function() return true end,
    }))
    equal("updated", updated.action)
    equal("Remote edited", annotations[1].text)
    equal(nil, annotations[1].note)
    equal(nil, annotations[1].color)
    equal(nil, annotations[1].chapter)
    equal("8", annotations[1].toto_revision)
    equal("8", updated.revision)

    local deleted = assert(AnnotationAdapter:applyRemote({
        event_type = "annotation.deleted",
        aggregate_id = sync_id,
        payload = { sync_id = sync_id },
        directive_metadata = { annotation_revision = "9" },
    }, annotations, {
        mode = "rolling",
        book_hash = book_hash,
    }))
    equal("deleted", deleted.action)
    equal(0, #annotations)
    equal("9", deleted.revision)
    equal(false, deleted.present)
end)

test("web annotations refuse a valid locator containing another passage", function()
    local annotations = {}
    local event = {
        event_type = "annotation.created",
        aggregate_id = "87654321-4321-3432-8432-cba987654321",
        payload = {
            sync_id = "87654321-4321-3432-8432-cba987654321",
            kind = "highlight", text = "Expected passage", color = "purple", drawer = "lighten",
            xpointer = "/body/DocFragment[1]/body/p[1]/text()[1].0",
            position = { pos1 = "/body/DocFragment[1]/body/p[1]/text()[1].16" },
        },
    }
    local options = {
        mode = "rolling", book_hash = string.rep("a", 32),
        validate_xpointer = function() return true end,
        read_text = function() return "Different words!" end,
    }
    local result, err = AnnotationAdapter:applyRemote(event, annotations, options)
    equal(nil, result); equal("remote_text_mismatch", err); equal(0, #annotations)
    options.read_text = function() return "Expected\npassage" end
    result = assert(AnnotationAdapter:applyRemote(event, annotations, options))
    equal("created", result.action); equal("purple", annotations[1].color)
    options.read_text = function() error("invalid native range") end
    result, err = AnnotationAdapter:applyRemote(event, annotations, options)
    equal(nil, result); equal("remote_text_mismatch", err); equal(1, #annotations)
end)

test("remote paging annotations reject unsafe locators", function()
    local result, err = AnnotationAdapter:applyRemote({
        event_type = "annotation.created",
        aggregate_id = "87654321-4321-3432-8432-cba987654321",
        payload = {
            sync_id = "87654321-4321-3432-8432-cba987654321",
            kind = "highlight",
            text = "Broken locator",
            page = 3,
            position = { pos0 = { page = 3 }, pos1 = { page = 3 } },
        },
    }, {}, {
        mode = "paging",
        book_hash = string.rep("a", 32),
    })
    equal(nil, result)
    equal("invalid_paging_locator", err)
end)

local function newMemoryFilesystem(initial)
    local files = {}
    for path, content in pairs(initial or {}) do files[path] = content end
    return {
        files = files,
        exists = function(path) return files[path] ~= nil end,
        size = function(path)
            return files[path] and #files[path] or nil
        end,
        read = function(path) return files[path] end,
        mkdir = function() return true end,
        remove_tree = function(path)
            local prefix = path .. "/"
            for candidate in pairs(files) do
                if candidate == path or candidate:sub(1, #prefix) == prefix then
                    files[candidate] = nil
                end
            end
            return true
        end,
        remove_file = function(path)
            files[path] = nil
            return true
        end,
        copy = function(source, destination)
            if files[source] == nil then return false end
            files[destination] = files[source]
            return true
        end,
        replace = function(source, destination)
            if files[source] == nil then return false end
            files[destination] = files[source]
            return true
        end,
    }
end

local function updaterRelease(version, overrides)
    local release = {
        ["_meta.lua"] = "return {}",
        ["main.lua"] = "return true",
        ["plugin_version.lua"] = "return \"" .. version .. "\"",
        ["updater.lua"] = "return true",
        ["newmodule.lua"] = "return { enabled = true }",
    }
    for path, content in pairs(overrides or {}) do release[path] = content end
    return release
end

local function updaterManifest(version, release)
    local files = {}
    local hash = require("ffi/sha2").sha256
    for path, content in pairs(release) do
        table.insert(files, {
            path = path,
            size = #content,
            sha256 = hash(content),
            download_url =
                "/api/plugin/highlightsdetoto/file?path=" .. path,
        })
    end
    table.sort(files, function(a, b) return a.path < b.path end)
    return {
        plugin = "highlightsdetoto",
        version = version,
        install_mode = "overlay",
        restart_required = true,
        update_available = true,
        files = files,
    }
end

local function newUpdaterFixture(name, initial, release, syntax_check)
    local fs = newMemoryFilesystem(initial)
    local journal = newStore("updater-journal-" .. name)
    local plugin_dir = "/plugins/highlightsdetoto.koplugin"
    local plugin = {
        getBaseUrl = function() return "https://example.test" end,
        getPluginDir = function() return plugin_dir end,
        getWebAuth = function() return { token = "test-token" } end,
        isWebConfigured = function() return true end,
    }
    local api = {
        downloadFile = function(_, _, _, destination)
            for path, content in pairs(release) do
                if destination:sub(-#path) == path then
                    fs.files[destination] = content
                    return true
                end
            end
            return false, "missing_fixture"
        end,
    }
    local hash = require("ffi/sha2").sha256
    local updater = Updater:new(plugin, api, {
        settings_dir = "/settings",
        filesystem = fs,
        journal_store = journal,
        sha256_file = function(path)
            local content = fs.read(path)
            return content and hash(content) or nil
        end,
        syntax_check = syntax_check or function(path)
            local content = fs.read(path)
            if content and content:match("INVALID") then
                return false, "syntax error"
            end
            return true
        end,
        now = function() return 1234 end,
    })
    return updater, fs, journal, plugin_dir
end

test("updater rejects unverifiable protected and external manifest entries", function()
    local version = "9999.1"
    local release = updaterRelease(version)
    local updater = newUpdaterFixture("manifest", {}, release)

    local missing_hash = updaterManifest(version, release)
    missing_hash.files[1].sha256 = nil
    assert(not updater:_validateManifest(missing_hash, false))

    local protected = updaterManifest(version, release)
    table.insert(protected.files, {
        path = "web_config.json",
        size = 2,
        sha256 = string.rep("a", 64),
        download_url =
            "/api/plugin/highlightsdetoto/file?path=web_config.json",
    })
    assert(not updater:_validateManifest(protected, false))

    local external = updaterManifest(version, release)
    external.files[1].download_url = "https://evil.test/plugin.lua"
    assert(not updater:_validateManifest(external, false))
end)

test("updater rejects bad hash and staged Lua before touching plugin", function()
    local plugin_dir = "/plugins/highlightsdetoto.koplugin"
    local initial = {
        [plugin_dir .. "/main.lua"] = "return 'old'",
    }
    local version = "9999.2"
    local release = updaterRelease(version, { ["main.lua"] = "INVALID LUA" })
    local manifest = updaterManifest(version, release)
    local updater, fs, journal = newUpdaterFixture(
        "invalid-lua",
        initial,
        release
    )
    local ok = updater:install(manifest)
    assert(not ok)
    equal("return 'old'", fs.read(plugin_dir .. "/main.lua"))
    equal(nil, journal:readSetting("state"))

    local clean_release = updaterRelease(version)
    local bad_hash = updaterManifest(version, clean_release)
    bad_hash.files[1].sha256 = string.rep("0", 64)
    local hash_updater, hash_fs = newUpdaterFixture(
        "bad-hash",
        initial,
        clean_release
    )
    assert(not hash_updater:install(bad_hash))
    equal("return 'old'", hash_fs.read(plugin_dir .. "/main.lua"))
end)

test("successful overlay retains backup and manual rollback is exact", function()
    local plugin_dir = "/plugins/highlightsdetoto.koplugin"
    local initial = {
        [plugin_dir .. "/_meta.lua"] = "return { old = true }",
        [plugin_dir .. "/main.lua"] = "return 'old-main'",
        [plugin_dir .. "/plugin_version.lua"] = "return '1.0.0'",
        [plugin_dir .. "/updater.lua"] = "return 'old-updater'",
    }
    local version = "9999.3"
    local release = updaterRelease(version)
    local updater, fs, journal = newUpdaterFixture(
        "rollback",
        initial,
        release
    )
    assert(updater:install(updaterManifest(version, release)))
    equal("return true", fs.read(plugin_dir .. "/main.lua"))
    assert(fs.read(plugin_dir .. "/newmodule.lua"))
    assert(updater:hasRollback())
    equal("ready_rollback", journal:readSetting("state").status)

    assert(updater:rollback())
    equal("return 'old-main'", fs.read(plugin_dir .. "/main.lua"))
    equal(nil, fs.read(plugin_dir .. "/newmodule.lua"))
    equal(nil, journal:readSetting("state"))
end)

test("startup recovery restores interrupted overlays before use", function()
    local plugin_dir = "/plugins/highlightsdetoto.koplugin"
    local backup_dir = "/settings/highlightsdetoto_update_backup_a"
    local fs = newMemoryFilesystem({
        [plugin_dir .. "/main.lua"] = "return 'partial-new'",
        [plugin_dir .. "/newmodule.lua"] = "return 'partial-new'",
        [backup_dir .. "/main.lua"] = "return 'known-good'",
    })
    local journal = newStore("updater-journal-recovery")
    journal:saveSetting("state", {
        status = "installing",
        plugin_dir = plugin_dir,
        stage_dir = "/settings/highlightsdetoto_update_stage",
        backup_dir = backup_dir,
        files = {
            { path = "main.lua", existed = true },
            { path = "newmodule.lua", existed = false },
        },
    })
    local plugin = {
        getPluginDir = function() return plugin_dir end,
        getBaseUrl = function() return "https://example.test" end,
    }
    Updater:new(plugin, {}, {
        settings_dir = "/settings",
        filesystem = fs,
        journal_store = journal,
        sha256_file = function() return string.rep("a", 64) end,
        syntax_check = function() return true end,
    })
    equal("return 'known-good'", fs.read(plugin_dir .. "/main.lua"))
    equal(nil, fs.read(plugin_dir .. "/newmodule.lua"))
    equal(nil, journal:readSetting("state"))
end)

-- -------------------------------------------------------------------------
-- C06 · Conectar KOReader con usuario y contraseña
-- -------------------------------------------------------------------------

local LOGIN_TOKEN = "toto_aaaaaaaa_" .. string.rep("b", 43)

local function newLoginApi(overrides)
    overrides = overrides or {}
    local calls = {}
    local api = {
        apiError = function(code, message, status, retryable)
            return {
                code = code,
                message = message,
                http_status = status,
                retryable = retryable == true,
            }
        end,
        postJSON = function(_, url, auth, payload, quick)
            table.insert(calls, { url = url, auth = auth, payload = payload, quick = quick })
            if url:match("/api/devices/v1/login$") then
                if overrides.login_error then return nil, overrides.login_error end
                return overrides.login or {
                    protocol_version = 1,
                    account = { username = "toto", email_verified = true },
                    device = { id = "device-a", name = "Kobo", platform = "koreader" },
                    credential = {
                        id = "credential-a",
                        token = LOGIN_TOKEN,
                        expires_at = "2027-01-01T00:00:00Z",
                        renew_after = "2026-12-01T00:00:00Z",
                    },
                }
            end
            if url:match("/credentials/rotate$") then
                return overrides.rotate
            end
        end,
        getJSON = function(_, url, auth)
            table.insert(calls, { url = url, auth = auth })
            if overrides.self_error then return nil, overrides.self_error end
            return overrides.self_response or { device = { id = "device-a" } }
        end,
    }
    return api, calls
end

test("login exchanges a password for a device credential and keeps only the token", function()
    local api, calls = newLoginApi()
    local committed
    local login = Login:new{
        web_api = api,
        base_url = "https://example.test",
        commit_credential = function(value) committed = value end,
    }
    local result, err = login:signIn{
        username = "  toto ",
        password = "correcto",
        external_id = "install-id",
        device_name = "Kobo",
    }
    assert(not err, tostring(err and err.code))

    -- El lector manda identidad de instalación, nunca identidad de cuenta.
    equal("https://example.test/api/devices/v1/login", calls[1].url)
    equal("toto", calls[1].payload.username)
    equal("install-id", calls[1].payload.external_id)
    equal("koreader", calls[1].payload.platform)
    equal(nil, calls[1].payload.user_id)
    equal(nil, calls[1].payload.account_id)
    equal(nil, calls[1].auth)

    -- El token se verifica contra /devices/self ANTES de commitear.
    equal("https://example.test/api/devices/self", calls[2].url)
    equal(LOGIN_TOKEN, calls[2].auth.token)
    equal(LOGIN_TOKEN, committed.credential.token)

    local settings = SettingsMigration.migrate({}, {})
    assert(SettingsMigration.completeLogin(settings, result))
    equal(LOGIN_TOKEN, settings.device_token)
    equal("credential-a", settings.device_credential_id)
    equal("device-a", settings.paired_device_id)
    equal("toto", settings.account_username)
    equal("2027-01-01T00:00:00Z", settings.credential_expires_at)
    equal(3, settings.settings_schema_version)
    equal("connected", SettingsMigration.connectionState(settings))
    for key, value in pairs(settings) do
        assert(value ~= "correcto", "password persisted as settings." .. tostring(key))
    end
end)

test("login refuses a plaintext server before the password leaves the device", function()
    local api, calls = newLoginApi()
    local login = Login:new{ web_api = api, base_url = "http://example.test" }
    local result, err = login:signIn{
        username = "toto",
        password = "correcto",
        external_id = "install-id",
    }
    equal(nil, result)
    equal("tls_required", err.code)
    equal(0, #calls)
end)

test("login rejects a credential issued for another device", function()
    local api = newLoginApi({ self_response = { device = { id = "someone-else" } } })
    local committed = false
    local login = Login:new{
        web_api = api,
        base_url = "https://example.test",
        commit_credential = function() committed = true end,
    }
    local result, err = login:signIn{
        username = "toto",
        password = "correcto",
        external_id = "install-id",
    }
    equal(nil, result)
    equal("login_identity_mismatch", err.code)
    equal(false, committed)
end)

test("only the server expires a session, never the reader clock", function()
    local settings = SettingsMigration.migrate({}, {})
    settings.device_token = LOGIN_TOKEN
    settings.paired_device_id = "device-a"

    -- Un Kobo que estuvo meses apagado vuelve con la fecha en cualquier lado.
    -- Un vencimiento local ya pasado pide rotar; no desconecta.
    settings.credential_expires_at = "2020-01-01T00:00:00Z"
    settings.credential_renew_after = "2019-12-01T00:00:00Z"
    equal("connected", SettingsMigration.connectionState(settings))
    assert(SettingsMigration.needsRenewal(settings, os.time()))

    settings.credential_expires_at = "2099-01-01T00:00:00Z"
    settings.credential_renew_after = "2098-01-01T00:00:00Z"
    equal("connected", SettingsMigration.connectionState(settings))
    equal(false, SettingsMigration.needsRenewal(settings, os.time()))

    -- Sólo el rechazo del servidor marca la sesión vencida, y es reversible.
    assert(SettingsMigration.markCredentialRejected(settings, 1000))
    equal("expired", SettingsMigration.connectionState(settings))
    equal(false, SettingsMigration.markCredentialRejected(settings, 2000))
    equal(1000, settings.credential_rejected_at)
    assert(SettingsMigration.markCredentialAccepted(settings))
    equal("connected", SettingsMigration.connectionState(settings))

    -- Estar sin red no es estar sin sesión.
    assert(Login.isCredentialRejection({ http_status = 401, code = "invalid_credentials" }))
    assert(Login.isCredentialRejection({ http_status = 403, code = "device_revoked" }))
    equal(false, Login.isCredentialRejection({ code = "connection_failed", retryable = true }))
    equal(false, Login.isCredentialRejection({ code = "server_unavailable", http_status = 503 }))
end)

test("rotation renews the token without touching the account identity", function()
    local api = newLoginApi({
        rotate = {
            credential = {
                id = "credential-b",
                device_id = "device-a",
                token = "toto_cccccccc_" .. string.rep("d", 43),
                expires_at = "2028-01-01T00:00:00Z",
            },
        },
    })
    local login = Login:new{ web_api = api, base_url = "https://example.test" }
    local rotated, err = login:rotate({ token = LOGIN_TOKEN })
    assert(not err, tostring(err and err.code))

    local settings = SettingsMigration.migrate({}, {})
    settings.device_token = LOGIN_TOKEN
    settings.paired_device_id = "device-a"
    settings.account_username = "toto"
    settings.credential_renew_after = "2019-12-01T00:00:00Z"
    assert(SettingsMigration.completeRotation(settings, rotated))
    equal(rotated.credential.token, settings.device_token)
    equal("credential-b", settings.device_credential_id)
    equal("2028-01-01T00:00:00Z", settings.credential_expires_at)
    equal("toto", settings.account_username)
    equal("device-a", settings.paired_device_id)
    -- La ventana anterior ya se consumió: sin esto el lector rotaría en cada
    -- arranque hasta el próximo login.
    equal(false, SettingsMigration.needsRenewal(settings, os.time()))

    -- Una sucesora de otro dispositivo no se guarda.
    local foreign = { credential = { device_id = "device-z", token = "toto_x" } }
    equal(nil, SettingsMigration.completeRotation(settings, foreign))
    equal(rotated.credential.token, settings.device_token)
end)

test("sign out clears the credential and the account bookkeeping", function()
    local settings = SettingsMigration.migrate({}, {})
    settings.device_token = LOGIN_TOKEN
    settings.paired_device_id = "device-a"
    settings.account_username = "toto"
    settings.credential_expires_at = "2027-01-01T00:00:00Z"
    settings.synced_books = { hash = true }
    settings.annotation_v2_bridged = { hash = true }
    settings.last_web_sync = 123

    assert(SettingsMigration.signOut(settings))
    equal(nil, settings.device_token)
    equal(nil, settings.paired_device_id)
    equal(nil, settings.account_username)
    equal(nil, settings.credential_expires_at)
    equal(nil, next(settings.synced_books))
    equal(nil, next(settings.annotation_v2_bridged))
    equal(0, settings.last_web_sync)
    equal("disconnected", SettingsMigration.connectionState(settings))
end)

test("an account switch is detected before and after the password is sent", function()
    local settings = SettingsMigration.migrate({}, {})
    settings.device_token = LOGIN_TOKEN
    settings.paired_device_id = "device-a"
    settings.account_username = "toto"

    -- Antes de mandar nada: alcanza con el usuario tipeado.
    equal(false, SettingsMigration.willSwitchAccount(settings, "TOTO"))
    assert(SettingsMigration.willSwitchAccount(settings, "otro"))

    -- Después: manda el id del dispositivo, que el servidor asigna por cuenta.
    equal(false, SettingsMigration.isAccountSwitch(settings, {
        device = { id = "device-a" },
        account = { username = "toto" },
    }))
    assert(SettingsMigration.isAccountSwitch(settings, {
        device = { id = "device-b" },
        account = { username = "toto" },
    }))
    -- Una instalación sin credencial previa nunca es un cambio de cuenta.
    equal(false, SettingsMigration.isAccountSwitch(
        SettingsMigration.migrate({}, {}),
        { device = { id = "device-b" }, account = { username = "otro" } }
    ))
end)

test("switching accounts discards the previous queue, cursor and inbox", function()
    local store = newStore("v2-switch")
    local legacy = newStore("legacy-switch")
    local queue = Queue:new("switch-test", { store = store, legacy_store = legacy })

    local event = queue:enqueueEvent{
        event_type = "annotation.upserted",
        aggregate_type = "annotation",
        aggregate_id = "annotation:1",
        payload = { text = "de la cuenta A" },
    }
    queue:enqueue("progress", { book_hash = "hash-a" })
    queue:setAnnotationState("hash-a", { revision = 3 })
    assert(queue:commitExchange({
        protocol_version = 2,
        acknowledgements = {{
            client_event_id = event.client_event_id,
            client_sequence = event.client_sequence,
            status = "accepted",
            server_sequence = "8",
        }},
        pull = {
            cursor = "9",
            events = {{ event_id = "remote-a", server_sequence = "9" }},
            has_more = false,
        },
    }, function() return "defer" end))
    queue:enqueueEvent{
        event_type = "progress.changed",
        aggregate_type = "reading_progress",
        aggregate_id = "book:hash-a",
        payload = { percentage = 42 },
    }
    equal("9", queue:getCursor())
    assert(queue:hasPendingWork())

    -- Una cola sin dueño anotado la adopta quien entra: una instalación que
    -- sólo se actualizó no pierde su trabajo offline.
    equal(nil, queue:resetForAccount("device-a"))
    equal("device-a", queue:getAccountScope())
    equal("9", queue:getCursor())
    equal(1, queue:v2Count())
    equal(2, queue:count())

    -- Exportar es lo que permite ofrecer "guardar una copia" sin prometer una
    -- migración entre cuentas que sería incorrecta.
    local exported = queue:exportPending()
    equal("9", exported.cursor)
    equal(1, #exported.outbox)
    equal(1, #exported.inbox)
    equal(1, #exported.legacy_pending)

    -- Volver a entrar con la misma cuenta no descarta nada.
    equal(nil, queue:resetForAccount("device-a"))
    equal(1, queue:v2Count())

    local discarded = queue:resetForAccount("device-b")
    equal("device-a", discarded.previous_scope)
    equal(1, discarded.outbox)
    equal(1, discarded.inbox)
    equal(1, discarded.legacy)
    equal("device-b", queue:getAccountScope())
    equal("0", queue:getCursor())
    equal(0, queue:v2Count())
    equal(0, queue:inboxCount())
    equal(0, queue:count())
    equal(nil, next(queue:getAnnotationState("hash-a")))
    equal(false, queue:hasPendingWork())
    -- La copia exportada antes del corte sigue siendo la de la cuenta anterior.
    equal(1, #exported.outbox)

    -- Y el corte sobrevive al reinicio.
    local restarted = Queue:new("switch-test", { store = store, legacy_store = legacy })
    equal("device-b", restarted:getAccountScope())
    equal(0, restarted:count())

    -- Salir de la cuenta deja la cola vacía y sin dueño.
    restarted:enqueue("progress", { book_hash = "hash-b" })
    local released = restarted:releaseAccount()
    equal("device-b", released.previous_scope)
    equal(nil, restarted:getAccountScope())
    equal(0, restarted:count())
end)

test("an upgraded install keeps its server, install id and pending queue", function()
    local store = newStore("v2-upgrade")
    local legacy = newStore("legacy-upgrade")
    local queue = Queue:new("upgrade-test", { store = store, legacy_store = legacy })
    queue:enqueue("highlights", { documents = {} })
    local install_id = queue:getInstallId()

    local settings = SettingsMigration.migrate({
        settings_schema_version = 2,
        web_url = "https://mi-servidor.test/api/sync",
        install_id = "install-anterior",
        device_token = "toto_viejo",
        paired_device_id = "device-a",
        web_api_key = "legacy",
        synced_books = { hash = true },
    }, {})
    -- Migrar no le muda el servidor a nadie ni le cambia la identidad.
    equal("https://mi-servidor.test", settings.server_base_url)
    equal("install-anterior", settings.install_id)
    equal(3, settings.settings_schema_version)
    equal("connected", SettingsMigration.connectionState(settings))
    equal("toto_viejo", SettingsMigration.getAuth(settings).token)
    assert(SettingsMigration.retireLegacyCredential(settings))
    equal("", settings.web_api_key)
    equal(true, settings.synced_books.hash)

    -- Y la cola pendiente sobrevive: la adopta la cuenta ya vinculada.
    assert(queue:adoptAccount(settings.paired_device_id))
    equal(false, queue:adoptAccount("device-z"))
    equal("device-a", queue:getAccountScope())
    equal(1, queue:count())
    equal(install_id, queue:getInstallId())
end)

test("a clean install already points at the official server", function()
    local settings = SettingsMigration.migrate({}, {})
    equal("https://borges.runadev.com", settings.server_base_url)
    equal("https://borges.runadev.com/api/sync", settings.web_url)
    equal("", settings.web_api_key)
    equal(nil, settings.device_token)
    equal("disconnected", SettingsMigration.connectionState(settings))
    assert(settings.install_id and settings.install_id ~= "")
end)

-- ============================================================
-- C07 · Unificar acciones y lenguaje del plugin
-- ============================================================

--- Doble del plugin: sólo contesta lo que MenuTree pregunta y anota qué se
-- invocó. Alcanza porque el árbol no toca estado, lo consulta.
local function fakePlugin(overrides)
    local plugin = {
        calls = {},
        pending_update_version = nil,
        sync_running = false,
        queue_count = 0,
    }
    local function record(name)
        return function(self, ...)
            table.insert(self.calls, name)
            return nil
        end
    end
    plugin.getConnectionLabel = function() return "Connected as ana" end
    plugin.promptDeviceLogin = record("login")
    plugin.hasCredential = function() return true end
    plugin.confirmSignOut = record("signout")
    plugin.getPairingLabel = function() return "Pair with a code" end
    plugin.canPair = function() return false end
    plugin.startOrResumePairing = record("pair")
    plugin.hasAccountAccess = function() return true end
    plugin.getUnifiedSyncLabel = function(self)
        if self.sync_running then return "Syncing…" end
        return "Sync now"
    end
    plugin.isSyncRunning = function(self) return self.sync_running end
    plugin.runUnifiedSync = record("sync")
    plugin.showLibraryDownloadDialog = record("library")
    plugin.getLibraryDownloadDir = function() return "/mnt/onboard/Borges" end
    plugin.configureLibraryDownloadDir = record("librarydir")
    plugin.canJumpToRemotePosition = function() return true end
    plugin.confirmRemotePositionJump = record("jump")
    plugin.getUndoJumpLabel = function() return "Go back to p. 12" end
    plugin.canUndoPositionJump = function() return true end
    plugin.undoPositionJump = record("undo")
    plugin.getSyncSummaryLabel = function() return "Status: up to date (just now)" end
    plugin.showSyncStatusDetail = record("status")
    plugin.isAutoSyncEnabled = function() return true end
    plugin.toggleAutoSync = record("autosync")
    plugin.showAbout = record("about")
    plugin.showSupportHelp = record("support")
    plugin.getDeviceIdLabel = function() return "Name of this reader: Kobo Clara" end
    plugin.configureDeviceId = record("deviceid")
    plugin.getServerLabel = function() return "Server: https://borges.runadev.com" end
    plugin.configureWebUrl = record("server")
    plugin.fullStatsDump = record("stats")
    plugin.getQueueLabel = function() return "Save a copy of pending changes" end
    plugin.hasQueuedWork = function(self) return self.queue_count > 0 end
    plugin.exportPendingQueue = record("export")
    plugin.confirmClearQueue = record("clear")
    plugin.checkPluginUpdate = record("checkupdate")
    plugin.getRollbackLabel = function() return "Go back to the previous version" end
    plugin.canRollbackPlugin = function() return false end
    plugin.isAutoUpdateCheckEnabled = function() return true end
    plugin.toggleAutoUpdateCheck = record("autoupdate")
    plugin.hasPendingUpdate = function(self) return self.pending_update_version ~= nil end
    plugin.getPendingUpdateVersion = function(self) return self.pending_update_version end
    plugin.getPluginVersion = function() return "1.2.0" end
    plugin.installPendingUpdate = record("install")
    -- C23 · La entrada del menú cubre dos situaciones: hay algo para instalar,
    -- o ya se instaló y falta reiniciar.
    plugin.installed_update_version = nil
    plugin.hasUpdatePendingRestart = function(self)
        return self.installed_update_version ~= nil
    end
    plugin.getInstalledUpdateVersion = function(self)
        return self.installed_update_version
    end
    plugin.hasUpdateEntry = function(self)
        return self:hasPendingUpdate() or self:hasUpdatePendingRestart()
    end
    plugin.getUpdateEntryLabel = function(self)
        if self:hasPendingUpdate() then
            return "Update available: " .. self:getPendingUpdateVersion()
        end
        if self:hasUpdatePendingRestart() then
            return "Restart KOReader to use version "
                .. self:getInstalledUpdateVersion()
        end
        return "Installed version: " .. self:getPluginVersion()
    end
    for key, value in pairs(overrides or {}) do plugin[key] = value end
    return plugin
end

test("el menú ofrece cinco entradas y una sola acción principal", function()
    local plugin = fakePlugin()
    local tree = MenuTree.build(plugin)
    equal("Borges", tree.text)

    local visible = {}
    for _, item in ipairs(tree.sub_item_table) do
        if not item.show_func or item.show_func() then
            table.insert(visible, item.id)
        end
    end
    equal(5, #visible)
    for index, id in ipairs(MenuTree.SECTIONS) do
        equal(id, visible[index])
    end

    -- Una sola entrada actúa directamente; las otras cuatro son grupos.
    local direct = {}
    for _, item in ipairs(tree.sub_item_table) do
        if item.callback and not item.sub_item_table
            and (not item.show_func or item.show_func()) then
            table.insert(direct, item.id)
        end
    end
    equal(1, #direct)
    equal("sincronizar", direct[1])

    -- Y esa acción efectivamente sincroniza.
    MenuTree.section(tree, "sincronizar").callback()
    equal("sync", plugin.calls[1])
end)

test("el recorrido normal no le pide al lector que entienda el protocolo", function()
    local plugin = fakePlugin()
    local tree = MenuTree.build(plugin)
    local normal = {}
    for _, id in ipairs({ "cuenta", "sincronizar", "biblioteca", "estado" }) do
        local section = MenuTree.section(tree, id)
        MenuTree.labels({ section }, normal)
    end
    assert(#normal > 5, "el recorrido normal quedó vacío")
    for _, label in ipairs(normal) do
        local lowered = label:lower()
        for _, word in ipairs(MenuTree.INTERNAL_WORDS) do
            assert(
                not lowered:find(word, 1, true),
                "la etiqueta '" .. label .. "' usa vocabulario interno: " .. word
            )
        end
    end
end)

test("la acción principal se apaga sola mientras una corrida está en curso", function()
    local plugin = fakePlugin()
    local tree = MenuTree.build(plugin)
    local action = MenuTree.section(tree, "sincronizar")
    equal(true, action.enabled_func())
    equal("Sync now", action.text_func())
    plugin.sync_running = true
    equal(false, action.enabled_func())
    equal("Syncing…", action.text_func())
end)

test("una versión nueva se ve en el menú de siempre y no en Avanzado", function()
    local plugin = fakePlugin()
    local tree = MenuTree.build(plugin)
    local entry = MenuTree.section(tree, "actualizacion")
    assert(entry, "falta la entrada de actualización")
    equal(false, entry.show_func())

    plugin.pending_update_version = "1.3.0"
    equal(true, entry.show_func())
    assert(entry.text_func():find("1.3.0", 1, true), entry.text_func())
    assert(
        entry.text_func():find("Update available", 1, true),
        entry.text_func()
    )
    entry.callback()
    equal("install", plugin.calls[1])

    -- En Avanzado queda sólo el diagnóstico: buscar a mano y volver atrás.
    local advanced = table.concat(
        MenuTree.labels(MenuTree.section(tree, "avanzado").sub_item_table), "|"
    )
    assert(advanced:find("Check for updates now", 1, true), advanced)
    assert(advanced:find("Go back to the previous version", 1, true), advanced)
    assert(not advanced:find("1.3.0", 1, true), "la instalación no va en Avanzado")
end)

--- Plan de sincronización de juguete: pasos nombrados que devuelven lo que la
-- prueba les diga, para poder mirar el informe y no el motor real.
local function plan(options)
    local state = options.state or {}
    return {
        connected = options.connected ~= false,
        online = options.online ~= false,
        pending = function() return state.pending or 0 end,
        steps = {
            {
                id = "guardar",
                label = "Saving today's reading",
                offline = true,
                run = function()
                    state.saved = (state.saved or 0) + 1
                    return {}
                end,
            },
            {
                id = "subir",
                label = "Checking the other books",
                run = function()
                    if options.upload_error then return nil, options.upload_error end
                    return { sent = 2 }
                end,
            },
            {
                id = "intercambio",
                label = "Bringing this reader up to date",
                run = function()
                    if options.exchange_error then return nil, options.exchange_error end
                    state.pending = 0
                    return { sent = 3, received = 4 }
                end,
            },
        },
    }
end

test("el segundo toque no arranca una segunda sincronización", function()
    local runner = SyncRun:new()
    local started = 0
    local nested
    local result = runner:run({
        connected = true,
        online = true,
        pending = function() return 0 end,
        steps = {{
            id = "uno",
            label = "uno",
            run = function()
                started = started + 1
                -- El lector vuelve a tocar el botón mientras el primero corre.
                nested = { runner:run(plan({})) }
                return {}
            end,
        }},
    })
    equal(1, started)
    equal(SyncRun.SYNCED, result.status)
    equal(nil, nested[1])
    equal("already_running", nested[2])
    -- Y cuando terminó, vuelve a estar disponible.
    equal(false, runner:isRunning())
    assert(runner:run(plan({})))
end)

test("sin red lo de hoy queda guardado y el resumen no dice que está todo al día", function()
    local state = { pending = 4 }
    local runner = SyncRun:new()
    local report = runner:run(plan({ online = false, state = state }))
    equal(SyncRun.OFFLINE, report.status)
    equal(1, state.saved)          -- el paso local corrió igual
    equal(1, report.ran)           -- y los que necesitan red, no
    equal(4, report.pending)
    local text = SyncRun.describe(report)
    assert(text:find("No connection", 1, true), text)
    assert(text:find("Pending: 4", 1, true), text)
    assert(not text:find("Everything up to date", 1, true), text)
end)

test("al volver la red la misma operación termina y cuenta enviados y recibidos", function()
    local state = { pending = 4 }
    local runner = SyncRun:new()
    runner:run(plan({ online = false, state = state }))
    local report = runner:run(plan({ online = true, state = state }))
    equal(SyncRun.SYNCED, report.status)
    equal(0, report.pending)
    equal(5, report.sent)
    equal(4, report.received)
    equal(true, SyncRun.isComplete(report))
    local text = SyncRun.describe(report, { last_success = 1000, describe_time = function() return "just now" end })
    assert(text:find("Everything up to date", 1, true), text)
    assert(text:find("Sent: 5 · Received: 4", 1, true), text)
end)

test("un error parcial nunca se muestra como todo sincronizado", function()
    local state = { pending = 2 }
    local runner = SyncRun:new()
    local report = runner:run(plan({
        state = state,
        exchange_error = { code = "http_502", message = "El servidor no respondió.", request_id = "req-9" },
    }))
    equal(SyncRun.PARTIAL, report.status)
    equal(false, SyncRun.isComplete(report))
    equal(2, report.sent)          -- lo que sí entró se informa
    equal(2, report.pending)
    local text = SyncRun.describe(report)
    assert(text:find("Partly synced", 1, true), text)
    assert(text:find("Pending: 2", 1, true), text)
    assert(text:find("El servidor no respondió.", 1, true), text)
    assert(text:find("req-9", 1, true), text)
    assert(not text:find("Everything up to date", 1, true), text)
end)

test("sin un solo paso bueno el informe no habla de sincronización parcial", function()
    local runner = SyncRun:new()
    local report = runner:run(plan({
        state = { pending = 7 },
        upload_error = { code = "offline", message = "Sin red." },
        exchange_error = { code = "offline", message = "Sin red." },
    }))
    equal(SyncRun.FAILED, report.status)
    equal(7, report.pending)
    local text = SyncRun.describe(report)
    assert(text:find("Could not sync", 1, true), text)
    assert(text:find("Nothing was lost", 1, true), text)
end)

test("sin sesión no corre ningún paso y el texto dice qué hacer", function()
    local state = { pending = 3 }
    local runner = SyncRun:new()
    local report = runner:run(plan({ connected = false, state = state }))
    equal(SyncRun.DISCONNECTED, report.status)
    equal(nil, state.saved)
    equal(3, report.pending)
    local text = SyncRun.describe(report)
    assert(text:find("Sign in to your account", 1, true), text)
    assert(not text:find("Sent:", 1, true), text)
end)

test("un paso que revienta deja el informe en rojo y libera el botón", function()
    local runner = SyncRun:new()
    local report = runner:run({
        connected = true,
        online = true,
        pending = function() return 0 end,
        steps = {{ id = "roto", label = "roto", run = function() error("boom") end }},
    })
    equal(SyncRun.FAILED, report.status)
    equal(false, runner:isRunning())
    assert(SyncRun.describe(report):find("Could not sync", 1, true))
end)

test("el intercambio informa cuántos eventos llegaron del servidor", function()
    local queue = Queue:new("received-test", {
        store = newStore("v2-received"),
        legacy_store = newStore("legacy-received"),
    })
    local fake_api = {
        apiError = function(_, code, message) return { code = code, message = message } end,
        postJSON = function()
            return {
                protocol_version = 2,
                acknowledgements = {},
                pull = {
                    cursor = "9",
                    has_more = false,
                    events = {
                        { event_id = "a", event_type = "progress.changed" },
                        { event_id = "b", event_type = "progress.changed" },
                    },
                },
            }
        end,
    }
    local client = SyncV2:new{
        web_api = fake_api,
        queue = queue,
        base_url = "https://example.test",
        auth = { token = "device-token" },
        apply_event = function() return true end,
    }
    local result = assert(client:syncAll(false, 1))
    equal(2, result.received)
    equal(0, result.deferred)
end)

test("rechazar la posición remota no deja punto de retorno ni toca el libro", function()
    local saved
    local undo = ReadingPosition:new({
        on_change = function(entries) saved = entries end,
        now = function() return 1000 end,
    })
    -- "Quedarme" no llama a remember: el estado queda exactamente igual.
    equal(false, undo:has("book-1"))
    equal(nil, undo:get("book-1"))
    equal(nil, saved)
end)

test("confirmar guarda dónde estabas y volver lo consume una sola vez", function()
    local persisted
    local undo = ReadingPosition:new({
        on_change = function(entries) persisted = entries end,
        now = function() return 1000 end,
    })
    local entry = undo:remember("book-1", { page = 12, xpointer = "/body/1", percentage = 30 })
    equal(12, entry.page)
    equal(1000, entry.at)
    equal(true, undo:has("book-1"))
    assert(persisted["book-1"], "el punto de retorno tiene que persistir")

    local taken = undo:take("book-1")
    equal(12, taken.page)
    equal("/body/1", taken.xpointer)
    -- Volver una vez, no rebotar entre dos posiciones para siempre.
    equal(false, undo:has("book-1"))
    equal(nil, undo:take("book-1"))
end)

test("una posición sin página ni ancla no se promete como recuperable", function()
    local undo = ReadingPosition:new({ now = function() return 1 end })
    equal(nil, undo:remember("book-1", { percentage = 40 }))
    equal(false, undo:has("book-1"))
    equal(nil, undo:remember("", { page = 3 }))
end)

test("el punto de retorno no crece con la biblioteca", function()
    local undo = ReadingPosition:new({ now = function() return 1 end })
    for index = 1, ReadingPosition.MAX_BOOKS + 5 do
        undo.now = function() return index end
        undo:remember("book-" .. index, { page = index })
    end
    local total = 0
    for _ in pairs(undo:getEntries()) do total = total + 1 end
    equal(ReadingPosition.MAX_BOOKS, total)
    -- Se cae el más viejo, no el que el lector acaba de usar.
    equal(nil, undo:get("book-1"))
    assert(undo:get("book-" .. (ReadingPosition.MAX_BOOKS + 5)))
end)

test("cambiar de cuenta no hereda el punto de retorno ni la marca de al día", function()
    local settings = {
        position_undo = { ["book-1"] = { page = 12, at = 1 } },
        last_full_sync = 1234,
        synced_books = { ["/a.epub"] = 10 },
    }
    SettingsMigration.clearAccountScopedState(settings)
    equal(0, settings.last_full_sync)
    equal(nil, settings.position_undo["book-1"])
end)


-- ============================================================
-- C17 · Reconexión y aviso de posición
-- ============================================================

-- Lua no distingue "no pasé la clave" de "la pasé en nil", así que para
-- construir una posición SIN ancla hace falta un centinela explícito.
local NONE = setmetatable({}, { __tostring = function() return "<none>" end })

local function remotePosition(overrides)
    local position = {
        event_id = "evt-1",
        percentage = 60,
        current_page = 120,
        total_pages = 200,
        xpointer = "/body/DocFragment[7]/body/p[3]/text()[1].0",
        occurred_at = "2026-09-15T12:00:00.000Z",
        time_precision = "exact",
    }
    for key, value in pairs(overrides or {}) do
        if value == NONE then value = nil end
        position[key] = value
    end
    return position
end

local function localPosition(page, total)
    return { current_page = page, total_pages = total or 200,
             percentage = (page / (total or 200)) * 100 }
end

local function newFlow(options)
    options = options or {}
    return ResumeFlow:new({
        decisions = options.decisions,
        on_change = options.on_change,
        now = options.now or function() return 1000 end,
    })
end

local function offerContext(flow, overrides)
    local context = {
        book_hash = "book-a",
        open_book_hash = "book-a",
        remote = remotePosition(),
        local_position = localPosition(40),
        total_pages = 200,
    }
    for key, value in pairs(overrides or {}) do context[key] = value end
    return flow:shouldOffer(context)
end

test("al conectar se consulta el servidor antes de subir lo guardado", function()
    local plan = ResumeFlow.planConnect({
        connected = true, session = true, book_open = true,
        now = 100, last_sync_at = 0, min_interval = 25,
    })
    equal(2, #plan.steps)
    -- El orden es el arreglo: si el drenaje fuera primero, el servidor
    -- tomaría la posición vieja de este lector como la última escritura.
    equal(ResumeFlow.STEP_PULL, plan.steps[1])
    equal(ResumeFlow.STEP_DRAIN, plan.steps[2])
end)

test("sin libro abierto la reconexión igual vacía la cola", function()
    local plan = ResumeFlow.planConnect({
        connected = true, session = true, book_open = false,
        now = 100, last_sync_at = 0, min_interval = 25,
    })
    equal(1, #plan.steps)
    equal(ResumeFlow.STEP_DRAIN, plan.steps[1])
end)

test("sin red ni sesión no corre ningún paso", function()
    equal(ResumeFlow.SKIP_OFFLINE,
        ResumeFlow.planConnect({ connected = false, session = true }).reason)
    equal(ResumeFlow.SKIP_NO_SESSION,
        ResumeFlow.planConnect({ connected = true, session = false }).reason)
    equal(0, #ResumeFlow.planConnect({ connected = false }).steps)
end)

test("dos eventos de red seguidos no son dos corridas", function()
    local state = {
        connected = true, session = true, book_open = true,
        now = 110, last_sync_at = 100, min_interval = 25,
    }
    equal(ResumeFlow.SKIP_DEBOUNCED, ResumeFlow.planConnect(state).reason)
    -- Una acción del lector sí atraviesa la ventana: la pidió él.
    state.force = true
    equal(2, #ResumeFlow.planConnect(state).steps)
    state.force = nil
    state.now = 130
    equal(2, #ResumeFlow.planConnect(state).steps)
end)

test("una corrida en curso no se encima con otra", function()
    equal(ResumeFlow.SKIP_RUNNING, ResumeFlow.planConnect({
        connected = true, session = true, book_open = true, running = true,
    }).reason)
end)

test("la misma posición no interrumpe la lectura", function()
    local flow = newFlow()
    local allowed, reason = offerContext(flow, {
        remote = remotePosition({ percentage = 60, current_page = 120 }),
        local_position = localPosition(120),
    })
    equal(false, allowed)
    equal(ResumeFlow.SAME_POSITION, reason)
end)

test("un aviso por vez: la segunda sugerencia no apila otro diálogo", function()
    local flow = newFlow()
    assert(offerContext(flow))
    assert(flow:markVisible("book-a", remotePosition()))
    local allowed, reason = offerContext(flow, {
        remote = remotePosition({ event_id = "evt-2", percentage = 70 }),
    })
    equal(false, allowed)
    equal(ResumeFlow.ALREADY_VISIBLE, reason)
    -- La elección abierta conserva su destino aunque llegue otro evento.
    equal(ResumeFlow.fingerprint(remotePosition()), flow:getVisible().fingerprint)
    flow:remember("book-a", remotePosition(), "accept")
    flow:clearVisible()
    equal(true, flow:isResolved("book-a", remotePosition()))
    assert(offerContext(flow, {
        remote = remotePosition({ event_id = "evt-3", percentage = 80 }),
    }))
end)

test("no se ofrece la posición de otro libro ni de la cuenta anterior", function()
    local flow = newFlow()
    local _allowed, other_book = offerContext(flow, { open_book_hash = "book-b" })
    equal(ResumeFlow.OTHER_BOOK, other_book)
    local _ignored, other_account = offerContext(flow, {
        account_scope = "device-vieja", current_account = "device-nueva",
    })
    equal(ResumeFlow.OTHER_ACCOUNT, other_account)
    -- Sin libro abierto (el lector está en la biblioteca) no hay nada que ofrecer.
    local _closed, no_book = flow:shouldOffer({
        book_hash = "book-a",
        remote = remotePosition(),
        local_position = localPosition(40),
        total_pages = 200,
    })
    equal(ResumeFlow.NO_BOOK, no_book)
end)

test("una posición sin dónde ubicarse no se ofrece", function()
    local flow = newFlow()
    local allowed, reason = offerContext(flow, {
        remote = { event_id = "evt-9", percentage = nil, current_page = nil },
    })
    equal(false, allowed)
    equal(ResumeFlow.NO_LOCATOR, reason)
end)

test("un seguir acá sobrevive la reconexión y el reinicio", function()
    local saved
    local flow = newFlow({ on_change = function(decisions) saved = decisions end })
    flow:remember("book-a", remotePosition(), "dismiss")
    assert(saved, "la decisión tiene que salir del objeto para poder guardarse")

    -- Reconectar: la misma posición no se vuelve a preguntar.
    local allowed, reason = offerContext(flow)
    equal(false, allowed)
    equal(ResumeFlow.ALREADY_RESOLVED, reason)

    -- Reiniciar: otro objeto, levantado de lo guardado, decide igual.
    local restarted = newFlow({ decisions = saved })
    local after_restart, restart_reason = offerContext(restarted)
    equal(false, after_restart)
    equal(ResumeFlow.ALREADY_RESOLVED, restart_reason)
end)

test("una posición nueva se ofrece aunque la anterior se haya rechazado", function()
    local flow = newFlow()
    flow:remember("book-a", remotePosition({ percentage = 60 }), "dismiss")
    assert(offerContext(flow, {
        remote = remotePosition({ event_id = "evt-2", percentage = 80, current_page = 160 }),
    }))
end)

test("aceptar tampoco deja el aviso repitiéndose al reconectar", function()
    local flow = newFlow()
    flow:remember("book-a", remotePosition(), "accept")
    -- El lector saltó, siguió leyendo y volvió atrás a mano: la posición que
    -- ya aceptó no vuelve a ofrecerse por reconectar.
    local allowed, reason = offerContext(flow, { local_position = localPosition(40) })
    equal(false, allowed)
    equal(ResumeFlow.ALREADY_RESOLVED, reason)
end)

test("la memoria de decisiones no crece con la biblioteca", function()
    local ticks = 0
    local flow = newFlow({ now = function() ticks = ticks + 1; return ticks end })
    for index = 1, ResumeFlow.MAX_BOOKS + 5 do
        flow:remember("book-" .. index, remotePosition({ event_id = "evt-" .. index }), "dismiss")
    end
    local total = 0
    for _ in pairs(flow:getDecisions()) do total = total + 1 end
    equal(ResumeFlow.MAX_BOOKS, total)
    equal(nil, flow:getDecision("book-1"))
    assert(flow:getDecision("book-" .. (ResumeFlow.MAX_BOOKS + 5)))
end)

test("cambiar de cuenta descarta las respuestas del dueño anterior", function()
    local queue = Queue:new("resume-account-test", {
        store = newStore("v2-resume-account"),
        legacy_store = newStore("legacy-resume-account"),
    })
    queue:adoptAccount("device-vieja")
    queue:setResumeDecisions({ ["book-a"] = { fingerprint = "event:evt-1", action = "dismiss", at = 5 } })
    assert(queue:getResumeDecisions()["book-a"])
    assert(queue:resetForAccount("device-nueva"))
    equal(nil, queue:getResumeDecisions()["book-a"])
end)

test("el diálogo dice las dos posiciones y avisa que va para atrás", function()
    local copy = ResumeFlow.describe({
        book_title = "El hombre que fue Jueves",
        remote = remotePosition({ percentage = 20, current_page = 40,
                                  chapter_title = "Capítulo 3" }),
        local_position = localPosition(150),
        total_pages = 200,
        source = { id = "3f2a1c", name = "Kobo Clara" },
    })
    equal("Where do you want to keep reading?", copy.title)
    equal("Go to that position", copy.ok_text)
    equal("Stay here", copy.cancel_text)
    assert(copy.text:find("El hombre que fue Jueves", 1, true))
    assert(copy.text:find("On this reader:", 1, true))
    assert(copy.text:find("On Kobo Clara:", 1, true))
    assert(copy.text:find("Capítulo 3", 1, true))
    equal(true, copy.backwards)
    assert(copy.text:find("backwards", 1, true))
end)

test("el destino se cuenta en páginas de este libro, no del otro aparato", function()
    -- El otro aparato manda "pág. 512 de 512": su recuento, su margen, su
    -- fuente. Acá el libro tiene 200 páginas y eso es lo que el lector ve.
    local copy = ResumeFlow.describe({
        remote = remotePosition({ percentage = 50, current_page = 90, total_pages = 512 }),
        local_position = localPosition(20),
        total_pages = 200,
        source = { name = "Kobo Clara" },
    })
    assert(copy.text:find("of 200", 1, true))
    assert(not copy.text:find("512", 1, true))
    assert(not copy.detail:find("512", 1, true))
end)

test("otras posiciones guardadas se listan sin id técnico y sin apretujar el aviso", function()
    local copy = ResumeFlow.describe({
        remote = remotePosition(),
        local_position = localPosition(40),
        total_pages = 200,
        source = { name = "Kobo Clara" },
        others = {
            { current_page = 120, percentage = 60, source = { name = "Kobo Clara" } },
            { current_page = 30, percentage = 15,
              source = { id = "8ba7b810-9dad-11d1-80b4-00c04fd430c8" } },
        },
    })
    -- La lista completa vive en el detalle, no en la pregunta.
    assert(not copy.text:find("Other saved positions", 1, true))
    assert(copy.detail:find("Other saved positions:", 1, true))
    assert(copy.detail:find("another device", 1, true))
    assert(not copy.detail:find("8ba7b810", 1, true))
end)

test("un id técnico no se muestra como si fuera el nombre del lector", function()
    local copy = ResumeFlow.describe({
        remote = remotePosition(),
        local_position = localPosition(40),
        total_pages = 200,
        source = { id = "8ba7b810-9dad-11d1-80b4-00c04fd430c8" },
    })
    equal("another device", copy.source_name)
    assert(not copy.text:find("8ba7b810", 1, true))
end)

test("no se muestra una hora que el reloj no puede probar", function()
    local function format_time() return "5 min ago" end
    equal("5 min ago", ResumeFlow.trustedTimestamp(
        remotePosition({ time_precision = "exact" }), format_time))
    equal("5 min ago", ResumeFlow.trustedTimestamp(
        remotePosition({ time_precision = "anchored" }), format_time))
    equal(nil, ResumeFlow.trustedTimestamp(
        remotePosition({ time_precision = "approximate" }), format_time))
    equal(nil, ResumeFlow.trustedTimestamp(
        remotePosition({ time_precision = "unknown" }), format_time))
end)

test("ni el diálogo ni el detalle muestran el ancla cruda ni el id del evento", function()
    local context = {
        book_title = "Rayuela",
        remote = remotePosition(),
        local_position = localPosition(40),
        total_pages = 200,
        source = { name = "Kobo Clara" },
        format_time = function() return "5 min ago" end,
    }
    local copy = ResumeFlow.describe(context)
    for _, text in ipairs({ copy.text, copy.detail }) do
        assert(not text:find("DocFragment", 1, true), "el xpointer no va a la pantalla")
        assert(not text:find("evt-1", 1, true), "el id del evento tampoco")
    end
    -- El detalle sí dice, en criollo, qué tan firme es la ubicación.
    assert(copy.detail:find("Book anchor: exact", 1, true))
    assert(copy.detail:find("5 min ago", 1, true))
end)

test("sin ancla el aviso dice que la ubicación es aproximada", function()
    local copy = ResumeFlow.describe({
        remote = remotePosition({ xpointer = NONE }),
        local_position = localPosition(40),
        total_pages = 200,
        source = { name = "Kobo Clara" },
    })
    equal(true, copy.approximate)
    assert(copy.text:find("approximate", 1, true))
    assert(copy.detail:find("estimated from the percentage", 1, true))
end)

test("un pull no toca el outbox, ni cuando el servidor falla", function()
    local queue = Queue:new("resume-pull-test", {
        store = newStore("v2-resume-pull"),
        legacy_store = newStore("legacy-resume-pull"),
    })
    queue:enqueueEvent{
        event_type = "progress.changed",
        aggregate_type = "book",
        aggregate_id = "book:pull",
        payload = { percentage = 41 },
    }
    local urls = {}
    local fail = false
    local fake_api = {
        apiError = function(_, code, message) return { code = code, message = message } end,
        postJSON = function(_, url, _, payload)
            table.insert(urls, url)
            if fail then return nil, { code = "network" } end
            -- Un pull nunca manda el outbox: es mirar, no subir.
            equal(nil, payload.events)
            return {
                protocol_version = 2,
                cursor = "9",
                events = {},
                has_more = false,
            }
        end,
    }
    local client = SyncV2:new{
        web_api = fake_api,
        queue = queue,
        base_url = "https://example.test",
        auth = { token = "device-token" },
        apply_event = function() return true end,
    }
    local result = assert(client:pull(true))
    equal("9", result.cursor)
    equal(0, result.sent)
    equal(1, queue:v2Count())
    assert(urls[1]:match("/api/sync/v2/pull$"))

    fail = true
    equal(nil, client:pull(true))
    equal(1, queue:v2Count())
end)

test("el pull completa la paginación antes de dar por leído el servidor", function()
    local queue = Queue:new("resume-pullall-test", {
        store = newStore("v2-resume-pullall"),
        legacy_store = newStore("legacy-resume-pullall"),
    })
    local calls = 0
    local fake_api = {
        apiError = function(_, code, message) return { code = code, message = message } end,
        postJSON = function()
            calls = calls + 1
            return {
                protocol_version = 2,
                cursor = tostring(calls),
                events = {{ event_id = "evt-" .. calls, event_type = "progress.changed" }},
                has_more = calls < 3,
            }
        end,
    }
    local client = SyncV2:new{
        web_api = fake_api,
        queue = queue,
        base_url = "https://example.test",
        auth = { token = "device-token" },
        apply_event = function() return "defer" end,
    }
    local summary = assert(client:pullAll(8, true))
    equal(3, calls)
    equal(3, summary.received)
    equal("3", summary.cursor)
    equal(3, queue:inboxCount())
end)

-- ============================================================
-- C23 · Detectar y comunicar actualizaciones del plugin
-- ============================================================

--- Estado base de la política: todo en verde, nunca chequeado.
local function checkState(overrides)
    local state = {
        enabled = true,
        configured = true,
        connected = true,
        running = false,
        manual = false,
        now = 1000000,
        last_success_at = 0,
        last_attempt_at = 0,
        failures = 0,
    }
    for key, value in pairs(overrides or {}) do state[key] = value end
    return state
end

test("el chequeo automático no prende la radio ni corre sin cuenta", function()
    equal(UpdateCheck.OK, UpdateCheck.plan(checkState()).reason)

    local offline = UpdateCheck.plan(checkState{ connected = false })
    equal(false, offline.allowed)
    equal(UpdateCheck.OFFLINE, offline.reason)

    local logged_out = UpdateCheck.plan(checkState{ configured = false })
    equal(false, logged_out.allowed)
    equal(UpdateCheck.NOT_CONFIGURED, logged_out.reason)

    local off = UpdateCheck.plan(checkState{ enabled = false })
    equal(false, off.allowed)
    equal(UpdateCheck.DISABLED, off.reason)

    -- La búsqueda manual sí puede pedir el Wi-Fi, así que la política la deja
    -- pasar aunque la radio esté apagada: quien la prende es `ensureNetwork`.
    equal(true, UpdateCheck.plan(checkState{
        connected = false, enabled = false, manual = true,
    }).allowed)
end)

test("un chequeo exitoso vale por un día y una corrida no se duplica", function()
    local success = UpdateCheck.recordSuccess(nil, 1000000)
    equal(1000000, success.last_success_at)
    equal(0, success.failures)

    local same_day = UpdateCheck.plan(checkState{
        now = 1000000 + 3600,
        last_success_at = success.last_success_at,
        last_attempt_at = success.last_attempt_at,
    })
    equal(false, same_day.allowed)
    equal(UpdateCheck.RECENT_SUCCESS, same_day.reason)
    equal(UpdateCheck.CHECK_INTERVAL - 3600, same_day.retry_in)

    local next_day = UpdateCheck.plan(checkState{
        now = 1000000 + UpdateCheck.CHECK_INTERVAL,
        last_success_at = success.last_success_at,
        last_attempt_at = success.last_attempt_at,
    })
    equal(true, next_day.allowed)

    -- Dos eventos de red encimados no son dos pedidos.
    local busy = UpdateCheck.plan(checkState{ running = true, manual = true })
    equal(false, busy.allowed)
    equal(UpdateCheck.IN_FLIGHT, busy.reason)
end)

test("un fallo no cuenta como respuesta: mueve el reintento, no el día", function()
    local state = { last_success_at = 0, last_attempt_at = 0, failures = 0 }
    local first = UpdateCheck.recordFailure(state, 2000)
    equal(0, first.last_success_at)
    equal(2000, first.last_attempt_at)
    equal(1, first.failures)

    -- Recién fallado: todavía no toca.
    local waiting = UpdateCheck.plan(checkState{
        now = 2000 + 60,
        last_success_at = first.last_success_at,
        last_attempt_at = first.last_attempt_at,
        failures = first.failures,
    })
    equal(false, waiting.allowed)
    equal(UpdateCheck.RETRY_BACKOFF, waiting.reason)

    -- Pasado el espaciado, sí: y no hubo que esperar veinticuatro horas.
    equal(true, UpdateCheck.plan(checkState{
        now = 2000 + UpdateCheck.RETRY_BASE,
        last_success_at = first.last_success_at,
        last_attempt_at = first.last_attempt_at,
        failures = first.failures,
    }).allowed)

    -- Cada fallo seguido espacia más, con techo.
    equal(UpdateCheck.RETRY_BASE, UpdateCheck.retryDelay(1))
    equal(UpdateCheck.RETRY_BASE * 2, UpdateCheck.retryDelay(2))
    equal(UpdateCheck.RETRY_MAX, UpdateCheck.retryDelay(99))
end)

test("los reintentos tienen límite y se reabren al día siguiente", function()
    local state = { last_success_at = 0, last_attempt_at = 0, failures = 0 }
    for index = 1, UpdateCheck.MAX_FAILURES do
        state = UpdateCheck.recordFailure(state, 5000 + index)
    end
    equal(UpdateCheck.MAX_FAILURES, state.failures)

    local exhausted = UpdateCheck.plan(checkState{
        now = state.last_attempt_at + UpdateCheck.RETRY_MAX,
        last_success_at = state.last_success_at,
        last_attempt_at = state.last_attempt_at,
        failures = state.failures,
    })
    equal(false, exhausted.allowed)
    equal(UpdateCheck.RETRY_EXHAUSTED, exhausted.reason)

    -- Buscar a mano sigue disponible mientras tanto.
    equal(true, UpdateCheck.plan(checkState{
        now = state.last_attempt_at + 1,
        last_attempt_at = state.last_attempt_at,
        failures = state.failures,
        manual = true,
    }).allowed)

    -- Y un día entero después el ciclo se reabre solo.
    equal(true, UpdateCheck.plan(checkState{
        now = state.last_attempt_at + UpdateCheck.CHECK_INTERVAL,
        last_success_at = state.last_success_at,
        last_attempt_at = state.last_attempt_at,
        failures = state.failures,
    }).allowed)
end)

test("un reloj que retrocede no deja al lector sin avisos", function()
    -- El Kobo se conecta y corrige la hora: lo guardado queda en el futuro.
    -- Esa fecha no prueba nada, así que se descarta en vez de esperarla.
    local anchors = UpdateCheck.normalize({
        last_success_at = 9000000,
        last_attempt_at = 9000000,
        failures = 0,
    }, 1000)
    equal(0, anchors.last_success_at)
    equal(0, anchors.last_attempt_at)
    equal(true, anchors.clock_reset)

    equal(true, UpdateCheck.plan(checkState{
        now = 1000,
        last_success_at = 9000000,
        last_attempt_at = 9000000,
    }).allowed)

    -- Basura guardada por una versión vieja tampoco rompe nada.
    local garbage = UpdateCheck.normalize({
        last_success_at = "ayer",
        last_attempt_at = -5,
        failures = "muchos",
    }, 1000)
    equal(0, garbage.last_success_at)
    equal(0, garbage.failures)
end)

test("una versión se anuncia una sola vez, y otra versión vuelve a anunciarse", function()
    equal(true, UpdateCheck.shouldAnnounce{ available = "1.3.0", current = "1.2.0" })
    -- Posponer no repite el cartel en cada reconexión.
    equal(false, UpdateCheck.shouldAnnounce{
        available = "1.3.0", current = "1.2.0", notified = "1.3.0",
    })
    -- Pero la siguiente versión sí es noticia nueva.
    equal(true, UpdateCheck.shouldAnnounce{
        available = "1.4.0", current = "1.2.0", notified = "1.3.0",
    })
    -- Igual o más vieja que la instalada no se anuncia nunca.
    equal(false, UpdateCheck.shouldAnnounce{ available = "1.2.0", current = "1.2.0" })
    equal(false, UpdateCheck.shouldAnnounce{ available = "1.1.0", current = "1.2.0" })
    equal(false, UpdateCheck.shouldAnnounce{ available = nil, current = "1.2.0" })
end)

test("el aviso nunca sale encima de la lectura ni de la pregunta de posición", function()
    -- En el explorador, con el libro cerrado: sale.
    equal(true, UpdateCheck.isSafeMoment{ trigger = "close_document" })

    -- Una reconexión en medio de una página no interrumpe la lectura.
    local reading = { UpdateCheck.isSafeMoment{ trigger = "network", book_open = true } }
    equal(false, reading[1])
    equal("reading", reading[2])

    -- Abrir el menú sí es un momento del lector, aunque el libro esté abierto.
    equal(true, UpdateCheck.isSafeMoment{ trigger = "menu", book_open = true })

    -- La pregunta de posición de C17 gana siempre, incluso desde el menú:
    -- taparla sería cambiarle una respuesta que el lector todavía no dio.
    local resume = {
        UpdateCheck.isSafeMoment{ trigger = "menu", resume_dialog = true },
    }
    equal(false, resume[1])
    equal("resume_dialog", resume[2])
end)

test("un build de prueba no se ofrece como actualización", function()
    equal(true, Updater.isStableVersion("2026.07.24.1"))
    equal(false, Updater.isStableVersion("2026.07.24-rc1"))
    equal(false, Updater.isStableVersion("main"))
    equal(false, Updater.isStableVersion("2026.07.24."))
    equal(false, Updater.isStableVersion(""))

    -- Y el actualizador lo rechaza aunque el manifiesto diga que hay update:
    -- la comparación numérica trataría `-rc1` como igual a la estable.
    local release = updaterRelease("9999.2")
    local updater = newUpdaterFixture("prerelease", {}, release)
    local manifest = updaterManifest("9999.2", release)
    manifest.version = "9999.2-rc1"
    local ok, err = updater:_validateManifest(manifest, true)
    equal(false, ok)
    assert(tostring(err):find("pre%-release"))

    local flagged = updaterManifest("9999.2", release)
    flagged.prerelease = true
    equal(false, flagged and updater:_validateManifest(flagged, true))
end)

test("el actualizador sólo instala el canal estable y un contrato que entiende", function()
    local release = updaterRelease("9999.3")
    local updater = newUpdaterFixture("contract", {}, release)

    local stable = updaterManifest("9999.3", release)
    stable.manifest_schema = 1
    stable.channel = "stable"
    stable.requires = { updater_protocol = 2 }
    assert(updater:_validateManifest(stable, true))

    local beta = updaterManifest("9999.3", release)
    beta.channel = "beta"
    equal(false, updater:_validateManifest(beta, true))

    local newer_schema = updaterManifest("9999.3", release)
    newer_schema.manifest_schema = 2
    equal(false, updater:_validateManifest(newer_schema, true))

    local needs_newer = updaterManifest("9999.3", release)
    needs_newer.requires = { updater_protocol = 3 }
    equal(false, updater:_validateManifest(needs_newer, true))

    -- Un servidor viejo, que todavía no manda estos campos, se sigue
    -- aceptando: el contrato suma, no corta la actualización de nadie.
    assert(updater:_validateManifest(updaterManifest("9999.3", release), true))
end)

test("la entrada del menú distingue instalada de cargada", function()
    local plugin = fakePlugin()
    local tree = MenuTree.build(plugin)
    local entry = MenuTree.section(tree, "actualizacion")
    equal(false, entry.show_func())

    plugin.installed_update_version = "1.3.0"
    equal(true, entry.show_func())
    local label = entry.text_func()
    assert(label:find("Restart KOReader", 1, true), label)
    assert(label:find("1.3.0", 1, true), label)
    -- Y no vuelve a ofrecer instalar lo que ya está en disco.
    assert(not label:find("Update available", 1, true), label)
end)


-- C13 · Avisar de un problema no puede vivir en Avanzado: quien lo necesita
-- viene de mirar el estado, no de configurar nada. Y no puede pedir que se
-- escriba el reporte acá.
test("Estado y ayuda ofrece reportar un problema", function()
    local plugin = fakePlugin()
    local tree = MenuTree.build(plugin)
    local estado = MenuTree.section(tree, "estado")

    local reportar = nil
    for _, item in ipairs(estado.sub_item_table) do
        if item.text == "Report a problem" then reportar = item end
    end
    assert(reportar, "falta la entrada de reportar en Estado y ayuda")

    reportar.callback()
    equal("support", plugin.calls[#plugin.calls])

    -- Y sigue siendo vocabulario de lector: nada de protocolo.
    local labels = MenuTree.labels({ estado })
    local joined = table.concat(labels, "|"):lower()
    for _, word in ipairs(MenuTree.INTERNAL_WORDS) do
        assert(not joined:find(word, 1, true), "palabra interna en Estado: " .. word)
    end
end)


test("pairing watches approval, saves once, and stops polling", function()
    local scheduled, checks, commits = nil, 0, 0
    local scheduler = {
        scheduleIn = function(_, seconds, task) equal(5, seconds); scheduled = task end,
        unschedule = function() scheduled = nil end,
    }
    local pairing = Pairing:new{ web_api = {}, base_url = "https://example.test", now = function() return 100 end }
    pairing.resume = function()
        checks = checks + 1
        if checks == 1 then return { user_code = "ABCD-2345" } end
        return { credential = { token = "test" } }
    end
    pairing:watch({ requested_at = 100, expires_in = 300 }, scheduler, function(result)
        assert(result.credential); commits = commits + 1
    end)
    scheduled(); equal(1, checks); assert(scheduled)
    scheduled(); equal(2, checks); equal(1, commits); equal(nil, scheduled)
end)

test("manual pairing needs no password and commits the approving account automatically", function()
    local scheduled, pending, committed, polls = nil, nil, nil, 0
    local web_api = {
        postJSON = function(_, url, auth, payload)
            equal(nil, auth)
            equal(nil, payload.password)
            if url:match("/request$") then
                equal(nil, payload.user_id)
                return { request_id = "request-id", user_code = "ABCD-2345",
                    verification_url = "/devices/pair", expires_in = 300, interval = 5 }
            elseif url:match("/status$") then
                polls = polls + 1
                equal(pending.device_nonce, payload.device_nonce)
                return { status = polls == 1 and "pending" or "approved" }
            elseif url:match("/claim$") then
                return { device = { id = "reader-a" }, account = { username = "reader-owner" },
                    credential = { token = "verified-token", id = "credential-a" } }
            end
            error("unexpected endpoint")
        end,
        getJSON = function(_, url, auth)
            assert(url:match("/self$"))
            equal("verified-token", auth.token)
            return { device = { id = "reader-a" } }
        end,
    }
    local pairing = Pairing:new{ web_api = web_api, base_url = "https://example.test",
        now = function() return 100 end,
        save_pending = function(value) pending = value end,
        clear_pending = function() pending = nil end,
        commit_credential = function(value)
            committed = {}; SettingsMigration.completeLogin(committed, value)
        end,
    }
    local state = pairing:start{ device_name = "Kobo", install_id = "reader-install" }
    equal("https://example.test/devices/pair", state.verification_url)
    equal(300, state.expires_in)
    local completed = 0
    pairing:watch(state, {
        scheduleIn = function(_, seconds, task) equal(5, seconds); scheduled = task end,
        unschedule = function() scheduled = nil end,
    }, function(result) equal("reader-owner", result.account.username); completed = completed + 1 end)
    scheduled(); equal(nil, committed)
    scheduled(); equal(1, completed); equal(nil, scheduled); equal(nil, pending)
    equal("reader-owner", committed.account_username)
    equal("verified-token", committed.device_token)
end)

test("pairing expires offline and cancels a previous watch", function()
    local now, scheduled, cleared, reason = 100, nil, 0, nil
    local scheduler = {
        scheduleIn = function(_, _, task) scheduled = task end,
        unschedule = function() scheduled = nil end,
    }
    local pairing = Pairing:new{ web_api = {}, base_url = "https://example.test",
        now = function() return now end, clear_pending = function() cleared = cleared + 1 end }
    pairing.resume = function() error("offline must not request") end
    pairing:watch({ requested_at = 100, expires_in = 300 }, scheduler, function(_, err) reason = err.code end, function() return false end)
    scheduled(); equal(nil, reason)
    now = 400; scheduled(); equal("pairing_expired", reason); equal(1, cleared); equal(nil, scheduled)
    pairing:watch({ requested_at = 400, expires_in = 300 }, scheduler, function() error("cancelled") end)
    pairing:stopWatching(); equal(nil, scheduled)
end)

test('diagnostics survive restart and retry without duplicating attempts', function()
    local Diagnostics = require('diagnostics')
    local now = 1760000000
    local d = Diagnostics:new('/diagnostics-test', { now = function() return now end })
    d:scope('device-one')
    d:record('sync', false, { code = 'connection_failed' }, '1')
    equal(0, #d.state.pending)
    d:record('sync', false, { http_status = 401 }, '1')
    equal(0, #d.state.pending)
    d:record('sync', false, { code = 'plugin_error', message = 'secret book text' }, '1')
    equal(nil, d.state.pending[1].message)
    local sequence = d.state.pending[1].sequence
    local restarted = Diagnostics:new('/diagnostics-test', { now = function() return now end })
    equal(sequence, restarted.state.pending[1].sequence)
    restarted:flush(function(payload, done) equal(sequence, payload.outcomes[1].sequence); done(false) end)
    equal(1, #restarted.state.pending)
    restarted:flush(function() error('must back off') end)
    now = now + 61
    local ack
    restarted:flush(function(_, done) ack = done end)
    restarted:record('sync', true, nil, '1')
    ack(true)
    equal(1, #restarted.state.pending)
    equal('success', restarted.state.pending[1].outcome)
    restarted:setEnabled(false)
    restarted:record('sync', false, { code = 'plugin_error' }, '1')
    equal(0, #restarted.state.pending)
end)

test('diagnostics account switch discards old outcomes and bounds the queue', function()
    local d = require('diagnostics'):new('/diagnostics-account-test')
    d:scope('a')
    for _ = 1, 30 do d:record('sync', false, {}, '1') end
    equal(20, #d.state.pending)
    local old_sequence = d.state.sequence
    d:scope('b')
    equal(0, #d.state.pending)
    d:record('download', true, nil, '1')
    equal(old_sequence + 1, d.state.sequence)
end)

test('diagnostic subprocess transport returns before network completion', function()
    local Transport = require('diagnosticstransport')
    local done, scheduled, child, written
    local exited = false
    local util = {
        runInSubProcess = function(fn) child = fn; return 123, 9 end,
        writeToFD = function(_, data) written = data end,
        isSubProcessDone = function() return exited end,
        readAllFromFD = function() return written end,
    }
    Transport.send(function() return true end, function(ok) done = ok end, {
        util = util, ui = { scheduleIn = function(_, _, fn) scheduled = fn end },
    })
    equal(nil, done)
    scheduled(); equal(nil, done)
    child(123, 8); exited = true; scheduled()
    equal(true, done)
end)

local function backgroundFixture(options)
    options = options or {}
    local Background = require("backgroundsync")
    local scheduled, child, pipe, replies = {}, nil, "", {}
    local state = { now = 100, exited = false, terminated = 0, closed = 0, reads = 0 }
    local ui = {
        scheduleIn = function(_, _, fn) table.insert(scheduled, fn) end,
        unschedule = function(_, fn)
            for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end
        end,
    }
    local util = {
        runInSubProcess = function(fn) child = fn; state.exited = false; return 123, 9 end,
        getNonBlockingReadSize = function() return #pipe end,
        writeToFD = function(_, data) pipe = data end,
        isSubProcessDone = function() return state.exited or (state.child_ran and #pipe == 0) end,
        terminateSubProcess = function() state.terminated = state.terminated + 1; state.exited = true end,
        readAllFromFD = function()
            assert(state.exited or #pipe == 0, "must drain pipe before waiting for child")
            state.closed = state.closed + 1
            local rest = pipe; pipe = ""; return rest
        end,
    }
    if options.unsupported then util.runInSubProcess = nil end
    local json = {
        encode = function(reply)
            local key = tostring(#replies + 1) .. string.rep("x", options.reply_bytes or 1)
            replies[key] = reply
            return key
        end,
        decode = function(key) return replies[key] end,
    }
    local background = Background:new{
        ui = ui, util = util, json = json, now = function() return state.now end,
        read_available = function()
            state.reads = state.reads + 1
            local part = pipe:sub(1, 32768); pipe = pipe:sub(#part + 1); return part
        end,
    }
    state.child = function() state.child_ran = true; child(123, 8) end
    state.tick = function() assert(#scheduled > 0); table.remove(scheduled, 1)() end
    state.pending = function() return #scheduled end
    return background, state
end

test("automatic HTTP yields before network and commits only after parent resumes", function()
    local Background = require("backgroundsync")
    local runner, state = backgroundFixture()
    local requested, committed, done = 0, 0, false
    assert(runner:run(function()
        local ok = pcall(function()
            local result = Background.request(function() requested = requested + 1; return { cursor = "42" } end)
            equal("42", result.cursor); committed = committed + 1
        end)
        assert(ok)
    end, function(ok) done = ok end))
    equal(0, requested); equal(0, committed); equal(false, done)
    equal(false, runner:run(function() error("overlap") end))
    state.tick(); equal(0, committed)
    state.child(); equal(1, requested); equal(0, committed)
    state.tick(); equal(1, committed); equal(true, done); equal(1, state.closed)
end)

test("background sync drains replies larger than a pipe while the child is running", function()
    local Background = require("backgroundsync")
    local runner, state = backgroundFixture({ reply_bytes = 200000 })
    local committed = false
    runner:run(function()
        local reply = Background.request(function() return { entries = { "large" } } end)
        equal("large", reply.entries[1]); committed = true
    end)
    state.child()
    for _ = 1, 6 do state.tick(); equal(false, committed) end
    state.tick(); equal(true, committed); equal(1, state.closed)
end)

test("background HTTP errors return to the parent without dropping local work", function()
    local Background = require("backgroundsync")
    local runner, state = backgroundFixture()
    local pending, error_code = 3, nil
    runner:run(function()
        local result, err = Background.request(function() return nil, { code = "client_sequence_conflict" } end)
        if result then pending = 0 else error_code = err.code end
    end)
    state.child(); state.tick()
    equal(3, pending); equal("client_sequence_conflict", error_code)
end)

test("background request timeout kills and reaps its child before reporting failure", function()
    local Background = require("backgroundsync")
    local runner, state = backgroundFixture()
    local error_code
    runner:run(function()
        local _, err = Background.request(function() error("network never returned") end)
        error_code = err.code
    end)
    state.now = 146; state.tick()
    equal("connection_failed", error_code); equal(1, state.terminated); equal(1, state.closed)
    equal(false, runner:isRunning()); equal(0, state.pending())
end)

test("suspend cancellation and account changes never apply late replies", function()
    local Background = require("backgroundsync")
    for _, cancel in ipairs({ true, false }) do
        local runner, state = backgroundFixture()
        local valid, committed, outcome = true, false, nil
        runner:run(function()
            Background.request(function() return { accepted = true } end)
            committed = true
        end, function(_, err) outcome = err.code end, function() return valid end)
        state.child()
        if cancel then runner:cancel() else valid = false end
        state.tick()
        equal(false, committed); equal("background_cancelled", outcome)
        equal(false, runner:isRunning()); equal(1, state.closed)
    end
end)

test("unsupported subprocess never falls back to blocking HTTP or retry loops", function()
    local Background = require("backgroundsync")
    local runner, state = backgroundFixture({ unsupported = true })
    local error_code
    runner:run(function()
        local _, err = Background.request(function() error("must not run on UI") end)
        error_code = err.code
    end)
    equal("background_unavailable", error_code); equal(0, state.pending())
    equal(false, runner:isRunning())
end)

test("library scan can yield between books and cancel without continuing", function()
    local Background = require("backgroundsync")
    local runner, state = backgroundFixture()
    local parsed = 0
    runner:run(function()
        for _ = 1, 100 do Background.yieldToUI(); parsed = parsed + 1 end
    end)
    equal(0, parsed); state.tick(); equal(1, parsed)
    runner:cancel(); equal(0, state.pending()); equal(1, parsed)
end)

test("WebApi routes automatic calls through the worker and restores readable errors", function()
    for _, name in ipairs({ "socket", "socketutil", "ssl.https", "socket.http", "ltn12" }) do
        package.preload[name] = package.preload[name] or function() return {} end
    end
    local WebApi = require("webapi")
    local runner, state = backgroundFixture()
    local calls, error_text = 0, nil
    local api = setmetatable({ _requestJSONSync = function()
        calls = calls + 1
        return nil, { code = "connection_failed", message = "No network" }
    end }, { __index = WebApi })
    runner:run(function()
        local _, err = api:postJSON("https://example.test/api/sync", {}, {})
        error_text = tostring(err)
    end)
    equal(0, calls); equal(nil, error_text)
    state.child(); equal(1, calls); equal(nil, error_text)
    state.tick(); equal("No network", error_text)
    api:getJSON("https://example.test/api/sync", {})
    equal(2, calls)
end)

test("focused progress bypasses old history without acknowledging it", function()
    local queue = Queue:new("focus-test", {
        store = newStore("focus-test"), legacy_store = newStore("focus-test-legacy"),
    })
    local order = {}
    local focus = { event_id = "latest", event_type = "progress.changed", server_sequence = "900" }
    local response = {
        protocol_version = 2, cursor = "1", has_more = true,
        focus_event = focus,
        events = {{ event_id = "old", event_type = "annotation.created" }},
    }
    local committed = assert(queue:commitExchange(response, function(event)
        table.insert(order, event.event_id)
        return "defer"
    end))
    equal("latest", order[1]); equal("old", order[2])
    equal("1", queue:getCursor()); equal(true, committed.has_more)
    equal(2, queue:inboxCount()); equal(true, queue:getInbox()[1].focus_preview)
    -- A later normal delivery of the preview must not apply it twice in a batch.
    response.events = { focus }
    order = {}
    assert(queue:commitExchange(response, function(event)
        table.insert(order, event.event_id); return "defer"
    end))
    equal(1, #order); equal(2, queue:inboxCount())
end)

test("progress sequence ordering preserves bigint precision", function()
    local ResumeFlow = require("resumeflow")
    equal(true, ResumeFlow.sequenceBefore("9007199254740992", "9007199254740993"))
    equal(false, ResumeFlow.sequenceBefore("9007199254740993", "9007199254740992"))
    equal(false, ResumeFlow.sequenceBefore(nil, "9"))
    equal(false, ResumeFlow.sequenceBefore("09", "9"))
end)

test("sequence allocation survives logout and stale local counters", function()
    local store = newStore("sequence-reset")
    local options = { store = store, legacy_store = newStore("sequence-reset-legacy") }
    local queue = Queue:new("sequence-reset", options)
    local function enqueue()
        return queue:enqueueEvent{ event_type = "session.ended", aggregate_type = "session",
            aggregate_id = "s", payload = { duration_seconds = 10 } }
    end
    equal("1", enqueue().client_sequence)
    queue:releaseAccount()
    equal("2", enqueue().client_sequence)
    queue.state.next_client_sequence = 1
    queue = Queue:new("sequence-reset", options)
    equal("3", enqueue().client_sequence)
end)

test("124 blocked events recover without losing content or duplicating lost acknowledgements", function()
    local queue = Queue:new("sequence-recovery", {
        store = newStore("sequence-recovery"), legacy_store = newStore("sequence-recovery-legacy"),
    })
    local originals, accepted, by_sequence = {}, {}, {}
    for i = 1, 124 do
        local event = queue:enqueueEvent{ event_type = "session.ended", aggregate_type = "session",
            aggregate_id = "s:" .. i, payload = { duration_seconds = i } }
        originals[event.client_event_id] = encode(event.payload)
        by_sequence[tostring(i)] = "older-event-" .. i
    end
    -- An earlier attempt succeeded but its reply never reached this reader.
    local first = queue.state.outbox[1]
    accepted[first.client_event_id] = first.client_sequence
    by_sequence[first.client_sequence] = first.client_event_id
    queue:prepareBatch(124, 1000000, true)
    local calls, materialized, conflicts = 0, 0, 0
    local api = { postJSON = function(_, _, _, payload)
        calls = calls + 1
        assert(calls <= 14, "recovery must be bounded")
        local unrecorded, collision = {}, false
        for _, event in ipairs(payload.events) do
            equal(originals[event.client_event_id], encode(event.payload))
            if not accepted[event.client_event_id] then
                table.insert(unrecorded, { client_event_id = event.client_event_id,
                    client_sequence = event.client_sequence })
                if by_sequence[event.client_sequence] then collision = true end
            end
        end
        if collision then
            conflicts = conflicts + 1
            return nil, { code = "client_sequence_conflict", details = {
                next_client_sequence = "125", unrecorded_events = unrecorded,
            } }
        end
        local acks = {}
        for _, event in ipairs(payload.events) do
            if not accepted[event.client_event_id] then materialized = materialized + 1 end
            accepted[event.client_event_id] = event.client_sequence
            by_sequence[event.client_sequence] = event.client_event_id
            table.insert(acks, { client_event_id = event.client_event_id,
                client_sequence = event.client_sequence, status = "accepted" })
        end
        return { protocol_version = 2, acknowledgements = acks,
            pull = { cursor = "0", events = {}, has_more = false } }
    end }
    local client = SyncV2:new{ queue = queue, web_api = api, base_url = "https://example.test" }
    local result = assert(client:syncAll(true, 20))
    equal(0, result.pending)
    equal(124, result.acknowledged)
    equal(123, materialized)
    equal(7, conflicts)
    equal("1", accepted[first.client_event_id])
end)

test("sequence repair is durable and unproven conflicts never mutate the outbox", function()
    local opts = { store = newStore("repair-durable"), legacy_store = newStore("repair-durable-legacy") }
    local queue = Queue:new("repair-durable", opts)
    local event = queue:enqueueEvent{ event_type = "session.ended", aggregate_type = "session",
        aggregate_id = "session", payload = { duration_seconds = 10 } }
    local calls = 0
    local api = { postJSON = function(_, _, _, payload)
        calls = calls + 1
        if calls == 1 then return nil, { code = "client_sequence_conflict", details = {
            next_client_sequence = "100", unrecorded_events = {
                { client_event_id = event.client_event_id, client_sequence = "1" },
            },
        } } end
        equal("100", payload.events[1].client_sequence)
        return nil, { code = "connection_failed", retryable = true }
    end }
    local client = SyncV2:new{ queue = queue, web_api = api }
    local result, err = client:sync(true)
    equal(nil, result); equal("connection_failed", err.code); equal(2, calls)
    queue = Queue:new("repair-durable", opts)
    local retry = queue:prepareBatch(nil, nil, true)
    equal(event.client_event_id, retry[1].client_event_id)
    equal("100", retry[1].client_sequence)
    equal(1, queue:v2Count())
    local before = encode(queue.state.outbox)
    assert(not queue:recoverSequences({ next_client_sequence = "101", unrecorded_events = {
        { client_event_id = event.client_event_id, client_sequence = "100" },
        { client_event_id = "not-in-this-request", client_sequence = "2" },
    } }, retry))
    equal(before, encode(queue.state.outbox))
    api.postJSON = function() calls = calls + 1; return nil, { code = "client_sequence_conflict" } end
    client.queue = queue
    result, err = client:sync(true)
    equal(nil, result); equal("client_sequence_conflict", err.code); equal(3, calls)
    equal("100", queue.state.outbox[1].client_sequence)
end)

test("reading handoff holds progress durably across every exchange and leaves other work sendable", function()
    local opts = { store = newStore("handoff-held"), legacy_store = newStore("handoff-held-legacy") }
    local queue = Queue:new("handoff-held", opts)
    local book = { kind = "koreader_partial_md5", value = "book" }
    local progress = queue:enqueueEvent{ event_type = "progress.changed", aggregate_type = "reading_progress",
        aggregate_id = "koreader_partial_md5:book", book_identifier = book, payload = { percentage = 20 } }
    queue:enqueueEvent{ event_type = "session.ended", aggregate_type = "session", aggregate_id = "session",
        payload = { duration_seconds = 5 } }
    queue:holdProgress(book)
    local restored = Queue:new("handoff-held", opts)
    for _, force in ipairs({ false, true }) do
        local batch = restored:prepareBatch(nil, nil, force)
        equal(1, #batch)
        equal("session.ended", batch[1].event_type)
    end
    equal(0, restored.state.outbox[1]._attempts)
    restored:enqueue("progress", { book_hash = "book", current_page = 20 })
    local posted = 0
    local result = restored:drainOne({ postJSON = function() posted = posted + 1; return {} end }, "https://example.test", {})
    equal(false, result.sent); equal(0, posted)
    restored:releaseProgress(book)
    local batch = restored:prepareBatch(nil, nil, true)
    equal(progress.client_event_id, batch[1].client_event_id)
    equal(20, batch[1].payload.percentage)
    restored:holdPendingProgress()
    equal(true, restored:isProgressHeld(book))
    restored:resetForAccount("first"); restored:resetForAccount("second")
    equal(false, restored:isProgressHeld(book))
end)

-- Idioma del plugin: inglés salvo que KOReader esté en castellano ------------

local I18n = require("i18n")
local Gettext = require("gettext")

test("con KOReader en C (sin idioma elegido) el plugin habla inglés", function()
    I18n.setLanguage(nil)
    Gettext.current_lang = "C"
    equal("en", I18n.language())
    equal("Sync now", I18n("Sync now"))
end)

test("cualquier idioma sin catálogo cae en inglés, nunca en castellano", function()
    for _, lang in ipairs({ "fr", "pt_BR", "de_DE", "en_US", "zh_CN", "", "   " }) do
        Gettext.current_lang = lang
        equal("en", I18n.language())
        equal("Where do you want to keep reading?", I18n("Where do you want to keep reading?"))
    end
    Gettext.current_lang = "C"
end)

test("con KOReader en castellano, en cualquiera de sus variantes, traduce", function()
    for _, lang in ipairs({ "es", "es_AR", "es-ES", "ES_MX.UTF-8" }) do
        Gettext.current_lang = lang
        equal("es", I18n.language())
        equal("Sincronizar ahora", I18n("Sync now"))
        equal("Volver a la pág. 12", I18n("Go back to p. %1"):gsub("%%1", "12"))
    end
    Gettext.current_lang = "C"
end)

test("un msgid que el catálogo no conoce vuelve en inglés, y lo que no es texto no se toca", function()
    Gettext.current_lang = "es"
    equal("Brand new string", I18n("Brand new string"))
    equal(nil, I18n(nil))
    equal(42, I18n(42))
    Gettext.current_lang = "C"
end)

test("cambiar el idioma de KOReader cambia el plugin sin reiniciar nada", function()
    Gettext.current_lang = "es"
    equal("Cuenta", I18n("Account"))
    Gettext.current_lang = "C"
    equal("Account", I18n("Account"))
end)

test("si gettext no dice el idioma, manda la preferencia guardada de KOReader", function()
    local saved = Gettext.current_lang
    Gettext.current_lang = nil
    _G.G_reader_settings = { readSetting = function(_, key) return key == "language" and "es_AR" or nil end }
    equal("es", I18n.language())
    _G.G_reader_settings = { readSetting = function() return nil end }
    equal("en", I18n.language())
    _G.G_reader_settings = nil
    Gettext.current_lang = saved
end)

test("el catálogo castellano conserva los huecos %1/%2 y no tiene entradas vacías", function()
    local catalog = require("l10n/es")
    local count = 0
    for msgid, translated in pairs(catalog) do
        count = count + 1
        assert(type(translated) == "string" and translated ~= "", msgid)
        for slot in msgid:gmatch("%%%d") do
            assert(translated:find(slot, 1, true), msgid .. " -> " .. translated .. " pierde " .. slot)
        end
        for slot in translated:gmatch("%%%d") do
            assert(msgid:find(slot, 1, true), msgid .. " -> " .. translated .. " inventa " .. slot)
        end
    end
    assert(count > 300, "el catálogo quedó chico: " .. count)
end)

test("el árbol del menú sale en castellano cuando KOReader está en castellano", function()
    Gettext.current_lang = "es"
    local tree = MenuTree.build(fakePlugin(), { gettext = I18n, template = function(s) return s end })
    equal("Borges", tree.text)
    local seen = {}
    for _, item in ipairs(tree.sub_item_table) do seen[item.text or (item.text_func and item.text_func()) or ""] = true end
    assert(seen["Cuenta"], "falta Cuenta")
    assert(seen["Avanzado"], "falta Avanzado")
    Gettext.current_lang = "C"
end)

io.write(string.format("1..%d\n", passed))

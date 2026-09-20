local md5 = require("ffi/sha2").md5

local AnnotationAdapter = {}

local UUID_RE = "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]"
    .. "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
    .. "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
    .. "[1-8][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
    .. "[89aAbB][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]%-"
    .. string.rep("[0-9a-fA-F]", 12) .. "$"

local function stringValue(value)
    return type(value) == "string" and value or nil
end

local function stableEncode(value)
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then return string.format("%.17g", value) end
    if kind == "string" then
        return string.format("%q", value)
    end
    if kind ~= "table" then return string.format("%q", tostring(value)) end

    local keys = {}
    for key in pairs(value) do table.insert(keys, key) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, stableEncode(tostring(key)) .. ":" .. stableEncode(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function normalizedText(value)
    local text = stringValue(value) or ""
    return text:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function comparableText(value)
    return normalizedText(value):gsub("\194\160", " "):gsub("\194\173", "")
        :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function positionFor(item)
    if item.pos0 == nil and item.pos1 == nil then return nil end
    return { pos0 = item.pos0, pos1 = item.pos1 }
end

local function annotationText(item, kind)
    local value = normalizedText(item.text or item.notes)
    if value ~= "" or kind ~= "bookmark" then return value end
    local page = tonumber(item.pageno or item.page)
    if page then return "Bookmark - page " .. tostring(page) end
    return "Bookmark"
end

local function locatorKey(item)
    local start = type(item.page) == "string" and item.page
        or type(item.pos0) == "string" and item.pos0
        or nil
    if start then
        return "rolling:" .. start .. ":" .. tostring(item.pos1 or "")
    end
    if type(item.pos0) == "table" or type(item.pos1) == "table" then
        return "paging:" .. stableEncode({
            page = item.page or item.pageno,
            pos0 = item.pos0,
            pos1 = item.pos1,
        })
    end
    return "legacy:" .. tostring(item.page or item.pageno or 0)
        .. ":" .. md5(normalizedText(item.text))
end

local function uuidFromSeed(seed)
    local hex = md5(seed):lower()
    return table.concat({
        hex:sub(1, 8),
        hex:sub(9, 12),
        "3" .. hex:sub(14, 16),
        "8" .. hex:sub(18, 20),
        hex:sub(21, 32),
    }, "-")
end

local function validUuid(value)
    return type(value) == "string" and value:match(UUID_RE) ~= nil
end

local function datetimeToEpoch(value)
    if type(value) ~= "string" then return nil end
    local year, month, day, hour, minute, second =
        value:match("(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)")
    if not year then return nil end
    local epoch = os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(minute),
        sec = tonumber(second),
    })
    return epoch and epoch * 1000 or nil
end

local function bookPayload(book)
    if type(book) ~= "table" or type(book.title) ~= "string"
        or book.title == "" then
        return nil
    end
    return {
        title = book.title,
        author = stringValue(book.author),
        file = stringValue(book.file),
        total_pages = tonumber(book.total_pages),
    }
end

local function revisionValue(value)
    local text = tostring(value or "0")
    if not text:match("^%d+$") then return "0" end
    return text
end

function AnnotationAdapter:normalize(book_hash, item, book)
    assert(type(book_hash) == "string" and book_hash ~= "", "book_hash is required")
    assert(type(item) == "table", "annotation item is required")
    local kind = item.drawer == nil and "bookmark" or "highlight"
    local sync_id = validUuid(item.toto_sync_id)
        and item.toto_sync_id:lower()
        or uuidFromSeed(book_hash:lower() .. "|" .. kind .. "|" .. locatorKey(item))
    item.toto_sync_id = sync_id
    item.toto_revision = revisionValue(item.toto_revision)

    local payload = {
        sync_id = sync_id,
        kind = kind,
        text = annotationText(item, kind),
        note = stringValue(item.note),
        chapter = stringValue(item.chapter),
        page = tonumber(item.pageno or item.page) or 0,
        total_pages = tonumber(book and book.total_pages),
        time = datetimeToEpoch(item.datetime),
        color = stringValue(item.color),
        drawer = kind == "bookmark" and "bookmark"
            or stringValue(item.drawer) or "lighten",
        xpointer = type(item.page) == "string" and item.page or nil,
        position = positionFor(item),
        base_revision = item.toto_revision,
        book = bookPayload(book),
    }
    local fingerprint_payload = {}
    for key, value in pairs(payload) do
        if key ~= "book" and key ~= "base_revision" then
            fingerprint_payload[key] = value
        end
    end
    return {
        sync_id = sync_id,
        kind = kind,
        payload = payload,
        fingerprint = md5(stableEncode(fingerprint_payload)),
    }
end

function AnnotationAdapter:diff(book_hash, annotations, previous, book)
    annotations = type(annotations) == "table" and annotations or {}
    previous = type(previous) == "table" and previous or {}
    local events, next_state = {}, {}
    local assigned = 0

    for _, item in ipairs(annotations) do
        local prior_id = item.toto_sync_id
        local normalized = self:normalize(book_hash, item, book)
        if prior_id ~= normalized.sync_id then assigned = assigned + 1 end
        local old = previous[normalized.sync_id]
        local old_fingerprint = type(old) == "table" and old.fingerprint or old
        local old_revision = type(old) == "table"
            and revisionValue(old.revision) or normalized.payload.base_revision
        normalized.payload.base_revision = old_revision
        item.toto_revision = old_revision
        next_state[normalized.sync_id] = {
            fingerprint = normalized.fingerprint,
            kind = normalized.kind,
            revision = old_revision,
            present = true,
        }
        if old_fingerprint ~= normalized.fingerprint then
            local event_type
            if normalized.kind == "bookmark" then
                event_type = "bookmark.upserted"
            elseif old_fingerprint == nil then
                event_type = "annotation.created"
            else
                event_type = "annotation.updated"
            end
            table.insert(events, {
                event_type = event_type,
                aggregate_type = "annotation",
                aggregate_id = normalized.sync_id,
                payload = normalized.payload,
            })
        end
    end

    for sync_id, old in pairs(previous) do
        if next_state[sync_id] == nil and validUuid(sync_id)
            and (type(old) ~= "table" or old.present ~= false) then
            local old_kind = type(old) == "table" and old.kind or "highlight"
            local old_revision = type(old) == "table"
                and revisionValue(old.revision) or "0"
            table.insert(events, {
                event_type = old_kind == "bookmark"
                    and "bookmark.deleted" or "annotation.deleted",
                aggregate_type = "annotation",
                aggregate_id = sync_id,
                payload = {
                    sync_id = sync_id,
                    base_revision = old_revision,
                    book = bookPayload(book),
                },
            })
            next_state[sync_id] = {
                kind = old_kind,
                revision = old_revision,
                present = false,
            }
        end
    end

    table.sort(events, function(a, b)
        if a.aggregate_id == b.aggregate_id then
            return a.event_type < b.event_type
        end
        return a.aggregate_id < b.aggregate_id
    end)
    return events, next_state, assigned
end

local function payloadLocator(payload)
    if type(payload.xpointer) == "string" then
        return "rolling:" .. payload.xpointer .. ":"
            .. tostring(payload.position and payload.position.pos1 or "")
    end
    if type(payload.position) == "table" then
        return "paging:" .. stableEncode({
            page = payload.page,
            pos0 = payload.position.pos0,
            pos1 = payload.position.pos1,
        })
    end
    return "legacy:" .. tostring(payload.page or 0)
        .. ":" .. md5(normalizedText(payload.text))
end

local function findExisting(annotations, sync_id, payload)
    local fallback = payload and payloadLocator(payload) or nil
    for index, item in ipairs(annotations) do
        if item.toto_sync_id == sync_id then return index, item end
    end
    if fallback then
        for index, item in ipairs(annotations) do
            if locatorKey(item) == fallback
                and normalizedText(item.text or item.notes) ==
                    normalizedText(payload.text) then
                return index, item
            end
        end
    end
end

local function buildItem(payload, mode, validate_xpointer, revision)
    local item = {
        toto_sync_id = payload.sync_id,
        toto_revision = revisionValue(revision),
        datetime = os.date("%Y-%m-%d %H:%M:%S",
            payload.time and math.floor(payload.time / 1000) or os.time()),
        drawer = payload.kind == "bookmark" and nil
            or stringValue(payload.drawer) or "lighten",
        color = stringValue(payload.color),
        text = normalizedText(payload.text),
        chapter = stringValue(payload.chapter),
        pageno = tonumber(payload.page) or 0,
        note = stringValue(payload.note),
    }
    if mode == "rolling" then
        local pos1 = payload.position and payload.position.pos1 or nil
        if payload.kind == "bookmark" then
            if type(payload.xpointer) ~= "string"
                or not validate_xpointer(payload.xpointer) then
                return nil, "invalid_rolling_locator"
            end
            item.page = payload.xpointer
            item.pos0 = nil
            item.pos1 = nil
            return item
        end
        if type(payload.xpointer) ~= "string" or type(pos1) ~= "string"
            or not validate_xpointer(payload.xpointer)
            or not validate_xpointer(pos1) then
            return nil, "invalid_rolling_locator"
        end
        item.page = payload.xpointer
        item.pos0 = payload.xpointer
        item.pos1 = pos1
        return item
    end
    if mode ~= "paging" then return nil, "unknown_document_mode" end
    if payload.kind == "bookmark" and tonumber(payload.page) then
        item.page = tonumber(payload.page)
        item.pos0 = nil
        item.pos1 = nil
        return item
    end
    local position = payload.position
    if type(position) ~= "table"
        or type(position.pos0) ~= "table"
        or type(position.pos1) ~= "table"
        or position.pos0.x == nil
        or position.pos0.y == nil
        or position.pos1.x == nil
        or position.pos1.y == nil then
        return nil, "invalid_paging_locator"
    end
    item.page = tonumber(payload.page)
        or tonumber(position.pos0.page)
        or 0
    item.pos0 = position.pos0
    item.pos1 = position.pos1
    return item
end

function AnnotationAdapter:applyRemote(event, annotations, options)
    annotations = type(annotations) == "table" and annotations or {}
    options = options or {}
    local payload = event and event.payload or {}
    local sync_id = payload.sync_id or (event and event.aggregate_id)
    if not validUuid(sync_id) then return nil, "invalid_sync_id" end
    sync_id = sync_id:lower()
    local index, existing = findExisting(annotations, sync_id, payload)
    local deleting = event.event_type == "annotation.deleted"
        or event.event_type == "bookmark.deleted"
    local metadata = event.directive_metadata or {}
    local revision = revisionValue(
        metadata.annotation_revision or payload.revision
            or payload.base_revision
    )

    if deleting then
        if index then
            if options.remove then
                options.remove(index, existing)
            else
                table.remove(annotations, index)
            end
        end
        return {
            action = index and "deleted" or "noop",
            sync_id = sync_id,
            kind = event.event_type == "bookmark.deleted"
                and "bookmark" or "highlight",
            revision = revision,
            present = false,
        }
    end

    payload.sync_id = sync_id
    local incoming, err = buildItem(
        payload,
        options.mode,
        options.validate_xpointer or function() return false end,
        revision
    )
    if not incoming then return nil, err end
    -- A syntactically valid locator may still point to a different passage
    -- (DOM/layout differences). New web marks must match the native text.
    if options.read_text and payload.kind ~= "bookmark" and options.mode == "rolling" then
        local ok, selected = pcall(options.read_text, incoming.pos0, incoming.pos1)
        if not ok or type(selected) ~= "string"
            or comparableText(selected) ~= comparableText(payload.text) then
            return nil, "remote_text_mismatch"
        end
    end
    if existing then
        for key, value in pairs(incoming) do existing[key] = value end
        -- Exact remote state must also clear optional fields.
        existing.note = incoming.note
        existing.color = incoming.color
        existing.chapter = incoming.chapter
        existing.drawer = incoming.drawer
    elseif options.add then
        options.add(incoming)
    else
        table.insert(annotations, incoming)
    end

    local normalized = self:normalize(
        options.book_hash or "",
        existing or incoming,
        options.book
    )
    return {
        action = existing and "updated" or "created",
        sync_id = sync_id,
        fingerprint = normalized.fingerprint,
        kind = normalized.kind,
        revision = revision,
        present = true,
        item = existing or incoming,
    }
end

AnnotationAdapter.stableEncode = stableEncode
AnnotationAdapter.locatorKey = locatorKey
AnnotationAdapter.uuidFromSeed = uuidFromSeed

return AnnotationAdapter

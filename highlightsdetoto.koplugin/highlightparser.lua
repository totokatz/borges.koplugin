local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = nil end
local rapidjson = require("rapidjson")

local HighlightParser = {}

local function stringOrEmpty(value)
    if type(value) == "string" then return value end
    return ""
end

--- Sanitize a filename by removing or replacing invalid characters.
-- @param name string
-- @return string safe filename
function HighlightParser:sanitizeFilename(name)
    if not name then return "unknown" end
    -- Replace characters not allowed in filenames
    local safe = name:gsub('[/\\:*?"<>|]', "_")
    -- Trim leading/trailing whitespace and dots
    safe = safe:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    if safe == "" then safe = "unknown" end
    return safe
end

--- Extract title, author, page count and KOReader hash from DocSettings.
-- @param doc_settings table DocSettings object
-- @param file_path string path to the book file
-- @return string title, string author, number pages, string|nil book_hash
function HighlightParser:getBookMeta(doc_settings, file_path)
    local doc_props = doc_settings:readSetting("doc_props") or {}
    local title = doc_props.title
    if not title or title == "" then
        -- Fallback: use filename without extension
        title = file_path:match("([^/\\]+)%.[^.]+$") or file_path
    end
    local author = doc_props.authors or doc_props.author or ""
    local pages = doc_settings:readSetting("doc_pages") or 0
    local book_hash = doc_settings:readSetting("partial_md5_checksum")
    return title, author, pages, book_hash
end

--- Encode raw KOReader position data into a string for the web API.
-- The current DB already has a text `sort` column, so we store extra
-- cross-device position metadata there instead of forcing a migration.
-- @param entry table raw highlight/annotation entry
-- @return string|nil encoded position metadata
function HighlightParser:encodePositionMeta(entry)
    if type(entry.pos1) == "string" then
        return entry.pos1
    end
    if type(entry.pos0) == "table" or type(entry.pos1) == "table" then
        local ok, encoded = pcall(rapidjson.encode, {
            pos0 = entry.pos0,
            pos1 = entry.pos1,
        })
        if ok then return encoded end
    end
    return nil
end

--- Parse a single highlight/annotation entry into a normalized table.
-- @param entry table raw highlight or annotation entry
-- @return table normalized highlight data
function HighlightParser:parseEntry(entry)
    return {
        text = stringOrEmpty(entry.text),
        page = entry.pageno or entry.page or 0,
        xpointer = type(entry.page) == "string" and entry.page or nil,
        position_meta = self:encodePositionMeta(entry),
        chapter = stringOrEmpty(entry.chapter),
        datetime = stringOrEmpty(entry.datetime),
        note = stringOrEmpty(entry.note),
        style = stringOrEmpty(entry.drawer),
        color = stringOrEmpty(entry.color),
        toto_sync_id = stringOrEmpty(entry.toto_sync_id),
    }
end

--- Parse all highlights for a single book file.
-- @param file_path string full path to the book
-- @return table|nil book data with highlights, or nil if no highlights
function HighlightParser:parseBook(file_path)
    if not DocSettings:hasSidecarFile(file_path) then
        return nil
    end

    local ok, doc_settings = pcall(DocSettings.open, DocSettings, file_path)
    if not ok or not doc_settings then
        return nil
    end

    local title, author, pages, book_hash = self:getBookMeta(doc_settings, file_path)
    local entries = {}

    -- Modern annotation format (KoReader 2024+)
    local annotations = doc_settings:readSetting("annotations")
    if annotations then
        for _, ann in ipairs(annotations) do
            if ann.text and ann.text ~= "" then
                table.insert(entries, self:parseEntry(ann))
            end
        end
    end

    -- Legacy highlight format (grouped by page)
    if #entries == 0 then
        local highlights = doc_settings:readSetting("highlight") or doc_settings:readSetting("highlights")
        if highlights then
            for _, page_highlights in pairs(highlights) do
                if type(page_highlights) == "table" then
                    for _, hl in ipairs(page_highlights) do
                        if type(hl) == "table" and hl.text and hl.text ~= "" then
                            table.insert(entries, self:parseEntry(hl))
                        end
                    end
                end
            end
        end
    end

    -- Also check bookmarks for notes-only entries (even if annotations exist).
    -- Dedup by page+text to avoid duplicating a bookmark that already exists as annotation.
    local bookmarks = doc_settings:readSetting("bookmarks")
    if bookmarks then
        -- Build a set of existing entries for dedup: "page|text"
        local existing = {}
        for _, e in ipairs(entries) do
            existing[tostring(e.page) .. "|" .. e.text] = true
        end
        for _, bm in ipairs(bookmarks) do
            if type(bm) == "table" and bm.notes and bm.notes ~= "" then
                local bm_page = bm.pageno or bm.page or 0
                local key = tostring(bm_page) .. "|" .. bm.notes
                if not existing[key] then
                    table.insert(entries, {
                        text = bm.notes,
                        page = bm_page,
                        chapter = bm.chapter or "",
                        datetime = bm.datetime or "",
                        note = "",
                        style = "bookmark",
                        color = "",
                    })
                    existing[key] = true
                end
            end
        end
    end

    if #entries == 0 then
        return nil
    end

    -- Sort by page number, then by datetime
    table.sort(entries, function(a, b)
        if a.page ~= b.page then
            return (tonumber(a.page) or 0) < (tonumber(b.page) or 0)
        end
        return (a.datetime or "") < (b.datetime or "")
    end)

    return {
        title = title,
        author = author,
        file = file_path:match("([^/\\]+)$") or file_path,
        book_hash = book_hash,
        pages = pages,
        highlights_count = #entries,
        highlights = entries,
    }
end

--- Parse highlights from all books in read history.
-- @return table array of book data tables (only books with highlights)
function HighlightParser:parseAllBooks()
    local books = {}
    for _, hist_entry in ipairs(ReadHistory.hist) do
        if hist_entry.file then
            local book_data = self:parseBook(hist_entry.file)
            if book_data then
                table.insert(books, book_data)
            end
        end
    end
    -- Sort by title
    table.sort(books, function(a, b)
        return (a.title or "") < (b.title or "")
    end)
    return books
end

--- Generate the consolidated JSON string (all books in one file).
-- @return string JSON content, number total_books, number total_highlights
function HighlightParser:generateConsolidatedJSON()
    local books = self:parseAllBooks()
    local total_highlights = 0
    for _, book in ipairs(books) do
        total_highlights = total_highlights + book.highlights_count
    end

    local data = {
        exported_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        device = "KoReader",
        total_books = #books,
        total_highlights = total_highlights,
        books = books,
    }

    local json_str = rapidjson.encode(data, { pretty = true })
    return json_str, #books, total_highlights
end

--- Generate individual JSON strings for each book.
-- @return table array of {filename=string, json=string, title=string}
function HighlightParser:generatePerBookJSONs()
    local books = self:parseAllBooks()
    local results = {}

    for _, book in ipairs(books) do
        local data = {
            exported_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            title = book.title,
            author = book.author,
            file = book.file,
            pages = book.pages,
            highlights_count = book.highlights_count,
            highlights = book.highlights,
        }

        local safe_name = self:sanitizeFilename(book.title)
        table.insert(results, {
            filename = safe_name .. ".json",
            json = rapidjson.encode(data, { pretty = true }),
            title = book.title,
        })
    end

    return results
end

--- Convert a datetime string ("YYYY-MM-DD HH:MM:SS") to epoch milliseconds.
-- @param dt string datetime in KoReader format
-- @return number|nil epoch milliseconds, or nil if invalid
function HighlightParser:datetimeToEpoch(dt)
    if not dt or dt == "" then return nil end
    local y, m, d, h, min, s = dt:match("(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)")
    if not y then return nil end
    local epoch = os.time({
        year = tonumber(y), month = tonumber(m), day = tonumber(d),
        hour = tonumber(h), min = tonumber(min), sec = tonumber(s),
    })
    return epoch and (epoch * 1000) or nil
end

--- Transform a parsed book table into the web API document format.
-- @param book table from parseBook() or parseAllBooks()
-- @return table document in API format
function HighlightParser:bookToApiDocument(book)
    local entries = {}
    for _, h in ipairs(book.highlights) do
        local note = stringOrEmpty(h.note)
        local entry = {
            text = stringOrEmpty(h.text),
            page = tonumber(h.page) or 0,
            xpointer = h.xpointer,
            chapter = stringOrEmpty(h.chapter),
            time = self:datetimeToEpoch(h.datetime),
            drawer = stringOrEmpty(h.style) ~= "" and stringOrEmpty(h.style) or "lighten",
            color = stringOrEmpty(h.color),
            sort = h.position_meta,
            sync_id = stringOrEmpty(h.toto_sync_id) ~= ""
                and stringOrEmpty(h.toto_sync_id) or nil,
        }
        if note ~= "" then
            entry.note = note
        end
        table.insert(entries, entry)
    end
    return {
        title = book.title,
        author = book.author,
        file = book.file,
        book_hash = book.book_hash,
        number_of_pages = book.pages or 0,
        entries = entries,
    }
end

--- Generate the API-ready payload for a single book file.
-- @param file_path string full path to the book
-- @return table|nil { documents = [{...}] }, number highlights_count
function HighlightParser:generateApiPayloadForBook(file_path)
    local book = self:parseBook(file_path)
    if not book then return nil, 0 end
    return { documents = { self:bookToApiDocument(book) } }, book.highlights_count
end

--- Get sidecar directory mtime for a book (cheap filesystem stat).
-- @param file_path string full path to the book
-- @return number|nil modification time (epoch seconds)
function HighlightParser:getSidecarMtime(file_path)
    if not lfs then return nil end
    local base = file_path:match("(.+)%.[^.]+$")
    local ext = file_path:match("%.([^.]+)$")
    -- Check metadata file mtime (reliable on FAT32, unlike directory mtime)
    if base and ext then
        local ok, attr = pcall(lfs.attributes, base .. ".sdr/metadata." .. ext .. ".lua")
        if ok and attr then return attr.modification end
    end
    -- Fallback: directory mtime
    if base then
        local ok, attr = pcall(lfs.attributes, base .. ".sdr")
        if ok and attr and attr.mode == "directory" then return attr.modification end
    end
    return nil
end

--- Generate incremental API payload — only books whose sidecar changed since last sync.
-- Skips parsing and network for unchanged books (saves CPU + battery).
-- @param synced_books table { [full_file_path] = mtime } from previous sync
-- @return table payload, number changed_count, number total_highlights, table new_synced, number skipped_count
function HighlightParser:generateApiPayloadIncremental(synced_books, yield_to_ui)
    synced_books = synced_books or {}
    local documents = {}
    local total_highlights = 0
    local new_synced = {}
    local skipped = 0

    for _, hist_entry in ipairs(ReadHistory.hist or {}) do
        if yield_to_ui then yield_to_ui() end
        if hist_entry.file then
            local full_path = hist_entry.file
            local mtime = self:getSidecarMtime(full_path)
            local cached = mtime and synced_books[full_path] and synced_books[full_path] >= mtime

            if cached then
                new_synced[full_path] = synced_books[full_path]
                skipped = skipped + 1
            else
                local book_data = self:parseBook(full_path)
                if book_data then
                    table.insert(documents, self:bookToApiDocument(book_data))
                    total_highlights = total_highlights + book_data.highlights_count
                end
                if mtime then
                    new_synced[full_path] = mtime
                end
            end
        end
    end

    return { documents = documents }, #documents, total_highlights, new_synced, skipped
end

return HighlightParser

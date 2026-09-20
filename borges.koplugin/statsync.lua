--- Module for reading statistics.sqlite3 and packaging data for the API.
-- Encapsulates SQLite3 access, delta queries, full dumps, and chunking.

local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local logger = require("logger")
local rapidjson = require("rapidjson")
local Background = require("backgroundsync")

local StatSync = {}

local STATS_DB_PATH = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local CHUNK_SIZE = 500
local V2_MAX_ROWS = 100
local V2_MAX_PAYLOAD_BYTES = 28 * 1024

--- Open the statistics database in read-only mode.
-- Checks file existence before attempting SQ3.open to avoid noisy errors.
-- @return conn|nil sqlite3 connection, string|nil error message
function StatSync:openDB()
    -- Verify file exists before opening
    local f = io.open(STATS_DB_PATH, "r")
    if not f then
        return nil, "statistics.sqlite3 not found"
    end
    f:close()

    local ok, conn = pcall(SQ3.open, STATS_DB_PATH, "ro")
    if not ok then
        logger.warn("StatSync: cannot open statistics.sqlite3:", conn)
        return nil, "Cannot open statistics.sqlite3"
    end
    return conn
end

--- Execute a stats query and collect rows with book metadata.
-- Uses prepared statements with numeric indices (stmt:step returns values by position).
-- SELECT order must be: md5, page, start_time, duration, total_pages, title, authors, pages, series, language
-- @param conn sqlite3 connection
-- @param sql string the SQL query to execute
-- @return {books=table, page_stats=table, total_rows=number}|nil, string|nil error
local function executeStatsQuery(conn, sql)
    local rows = {}
    local book_map = {}

    local stmt
    local ok, err = pcall(function()
        stmt = conn:prepare(sql)
        local row = stmt:step({})
        while row do
            local md5 = row[1]
            if md5 then
                table.insert(rows, {
                    book_md5 = md5,
                    page = tonumber(row[2]),
                    start_time = tonumber(row[3]),
                    duration = tonumber(row[4]),
                    total_pages = tonumber(row[5]),
                })

                if not book_map[md5] then
                    book_map[md5] = {
                        md5 = md5,
                        title = row[6],
                        authors = row[7],
                        pages = tonumber(row[8]),
                        series = row[9],
                        language = row[10],
                    }
                end
            end
            row = stmt:step(row)
        end
    end)

    if stmt then
        pcall(function() stmt:close() end)
    end

    if not ok then
        return nil, tostring(err)
    end

    -- Convert book_map to array
    local books = {}
    for _, book in pairs(book_map) do
        table.insert(books, book)
    end

    return {
        books = books,
        page_stats = rows,
        total_rows = #rows,
    }
end

--- Get delta page_stat_data rows since last_sync.
-- Maps id_book to md5 via JOIN on the book table.
-- @param last_sync number epoch timestamp of last successful sync
-- @return {books=table, page_stats=table, total_rows=number}|nil, string|nil error
function StatSync:getDelta(last_sync)
    local conn, err = self:openDB()
    if not conn then return nil, err end

    local safe_last_sync = math.max(0, math.floor(tonumber(last_sync) or 0))
    local sql = [[
        SELECT b.md5, p.page, p.start_time, p.duration, p.total_pages,
               b.title, b.authors, b.pages, b.series, b.language
        FROM page_stat_data p
        JOIN book b ON b.id = p.id_book
        WHERE b.md5 IS NOT NULL
          AND p.start_time > ]] .. tostring(safe_last_sync) .. [[
        ORDER BY p.start_time ASC, b.md5 ASC, p.page ASC]]

    local result, query_err = executeStatsQuery(conn, sql)

    conn:close()

    if not result then
        logger.warn("StatSync: getDelta query error:", query_err)
        return nil, "Error querying statistics: " .. tostring(query_err)
    end

    return result
end

--- Get ALL page_stat_data rows (full dump).
-- Same as getDelta but without timestamp filter.
-- @return {books=table, page_stats=table, total_rows=number}|nil, string|nil error
function StatSync:getAllData()
    local conn, err = self:openDB()
    if not conn then return nil, err end

    local sql = [[
        SELECT b.md5, p.page, p.start_time, p.duration, p.total_pages,
               b.title, b.authors, b.pages, b.series, b.language
        FROM page_stat_data p
        JOIN book b ON b.id = p.id_book
        WHERE b.md5 IS NOT NULL
        ORDER BY p.start_time ASC, b.md5 ASC, p.page ASC]]

    local result, query_err = executeStatsQuery(conn, sql)

    conn:close()

    if not result then
        logger.warn("StatSync: getAllData query error:", query_err)
        return nil, "Error querying statistics: " .. tostring(query_err)
    end

    return result
end

--- Split page_stats into chunks for sending.
-- First chunk includes books, subsequent chunks do not (server only needs books once).
-- @param page_stats table array of page_stat rows
-- @param books table array of book metadata
-- @return table array of payloads ready to send: {{books=books, page_stats=chunk1}, {page_stats=chunk2}, ...}
function StatSync:getChunks(page_stats, books)
    local chunks = {}
    local total = #page_stats

    for i = 1, total, CHUNK_SIZE do
        local chunk_end = math.min(i + CHUNK_SIZE - 1, total)
        local chunk = {}
        for j = i, chunk_end do
            table.insert(chunk, page_stats[j])
        end

        local payload = { page_stats = chunk }
        -- Include books in ALL chunks so each chunk is self-contained.
        -- This ensures chunks replayed from the offline queue still have book metadata.
        -- The book list is small (~100 entries) so the overhead is negligible.
        payload.books = books

        table.insert(chunks, payload)
    end

    return chunks
end

local function boundedMetadata(book)
    local function text(value, max_bytes)
        if type(value) ~= "string" or value == "" then return nil end
        if #value > max_bytes then return nil end
        return value
    end
    return {
        md5 = book.md5,
        title = text(book.title, 500),
        authors = text(book.authors, 500),
        pages = tonumber(book.pages),
        series = text(book.series, 500),
        language = text(book.language, 64),
    }
end

--- Build self-contained Borges v2 page-stat payloads.
-- Chunks obey both the 100-row materializer bound and a conservative byte
-- ceiling below the protocol's 32 KiB per-event limit.
function StatSync:getV2Chunks(page_stats, books)
    page_stats = type(page_stats) == "table" and page_stats or {}
    books = type(books) == "table" and books or {}
    local books_by_md5 = {}
    for _, book in ipairs(books) do
        if type(book) == "table" and type(book.md5) == "string" then
            books_by_md5[book.md5:lower()] = boundedMetadata(book)
        end
    end

    local chunks = {}
    local rows, selected_books, selected_md5 = {}, {}, {}
    local function payload()
        return { rows = rows, books = selected_books }
    end
    local function flush()
        if #rows == 0 then return end
        table.insert(chunks, payload())
        rows, selected_books, selected_md5 = {}, {}, {}
        -- The SQLite connection has already closed; cancellation here cannot
        -- strand a query. Let the activity indicator refresh between chunks.
        Background.yieldToUI()
    end

    for _, row in ipairs(page_stats) do
        local md5 = type(row.book_md5) == "string" and row.book_md5:lower() or nil
        local added_book = false
        local book = md5 and books_by_md5[md5] or nil
        table.insert(rows, row)
        if book and not selected_md5[md5] then
            table.insert(selected_books, book)
            selected_md5[md5] = true
            added_book = true
        end

        local encoded = rapidjson.encode(payload())
        if (#rows > V2_MAX_ROWS or #encoded > V2_MAX_PAYLOAD_BYTES) and #rows > 1 then
            table.remove(rows)
            if added_book then
                table.remove(selected_books)
                selected_md5[md5] = nil
            end
            flush()
            table.insert(rows, row)
            if book then
                table.insert(selected_books, book)
                selected_md5[md5] = true
            end
        end
    end
    flush()
    return chunks
end

function StatSync:getMaxStartTime(page_stats)
    local maximum = nil
    for _, row in ipairs(page_stats or {}) do
        local value = tonumber(row.start_time)
        if value and (not maximum or value > maximum) then maximum = value end
    end
    return maximum
end

--- Get total count of syncable rows in statistics.sqlite3.
-- For display in menu status info.
-- @return number|nil row count, string|nil error
function StatSync:getTotalRows()
    local conn, err = self:openDB()
    if not conn then return nil, err end

    local sql = [[
        SELECT COUNT(*) AS total_rows
        FROM page_stat_data p
        JOIN book b ON b.id = p.id_book
        WHERE b.md5 IS NOT NULL]]

    local stmt
    local ok, total_rows = pcall(function()
        stmt = conn:prepare(sql)
        local row = stmt:step({})
        if not row then
            return 0
        end
        return row[1]
    end)

    if stmt then
        pcall(function() stmt:close() end)
    end

    conn:close()

    if not ok then
        logger.warn("StatSync: getTotalRows error:", total_rows)
        return nil, "Error counting statistics rows: " .. tostring(total_rows)
    end

    if total_rows == nil then
        return 0
    end

    return tonumber(total_rows) or 0
end

return StatSync

-- ChapterTime: cuanto te llevo cada capitulo, medido como lo mide KOReader.
--
-- Fuente: page_stat_data de statistics.sqlite3 (una fila por visita a una
-- pagina, con la duracion ya recortada a max_sec) y el indice del libro con la
-- paginacion actual. Ademas reconstruye lo que el pie de KOReader decia al
-- entrar al capitulo («⤻»): paginas que faltaban despues de la actual por el
-- promedio por pagina que KOReader tenia en ese momento.
--
-- DUPLICADO A PROPOSITO de shared/chapterTime.js (la web y el servidor). Los
-- dos pasan los vectores de shared/chapterTimeVectors.json: si cambia aca,
-- cambia alla. Modulo puro: no toca disco, red ni KOReader.

local ChapterTime = {}

ChapterTime.DEFAULT_MAX_SEC = 120

local floor = math.floor

local function int(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    if n >= 0 then return floor(n) end
    return -floor(-n)
end

local function round(value)
    return floor(value + 0.5)
end

--- Capitulos como los navega KOReader: un inicio por pagina distinta.
function ChapterTime.ranges(entries, page_count)
    local total = int(page_count)
    if not total or total < 1 or type(entries) ~= "table" then return {} end
    local by_page, starts = {}, {}
    for index, entry in ipairs(entries) do
        local page = type(entry) == "table" and int(entry.page) or nil
        if page and page >= 1 and page <= total and not by_page[page] then
            local start = {
                toc_index = int(entry.toc_index) or index,
                page = page,
                depth = int(entry.depth) or 1,
                title = type(entry.title) == "string" and entry.title or "",
            }
            by_page[page] = start
            starts[#starts + 1] = start
        end
    end
    table.sort(starts, function(a, b) return a.page < b.page end)
    for i, start in ipairs(starts) do
        start.first = start.page
        start.last = starts[i + 1] and (starts[i + 1].page - 1) or total
    end
    return starts
end

--- Una fila de page_stat_data en las paginas actuales (vista page_stat).
function ChapterTime.rescale(row, page_count, out)
    out = out or {}
    local page, total_pages = int(row.page), int(row.total_pages)
    local pages, start, duration = int(page_count), int(row.start_time), int(row.duration)
    if not page or page < 1 or not total_pages or total_pages < 1 or not pages or pages < 1
        or not start or not duration then
        return out
    end
    local first = floor(((page - 1) * pages) / total_pages) + 1
    local last = math.max(first, floor((page * pages) / total_pages))
    local share = int(duration / (last - first + 1))
    for p = first, last do
        out[#out + 1] = { page = p, start_time = start, duration = share }
    end
    return out
end

function ChapterTime.summary(chapters)
    local ratios = {}
    for _, chapter in ipairs(chapters) do
        local ko = chapter.koreader
        if ko and ko.comparable and ko.estimate_seconds > 0 then
            ratios[#ratios + 1] = ko.actual_seconds / ko.estimate_seconds
        end
    end
    if #ratios == 0 then return nil end
    table.sort(ratios)
    local n = #ratios
    local median
    if n % 2 == 1 then median = ratios[(n + 1) / 2]
    else median = (ratios[n / 2] + ratios[n / 2 + 1]) / 2 end
    local close = 0
    for _, r in ipairs(ratios) do
        if r >= 0.8 and r <= 1.25 then close = close + 1 end
    end
    return { chapters = n, median_ratio = round(median * 100) / 100, within_20_percent = close }
end

--- Tiempo de cada capitulo y lo que KOReader estimo al entrar.
-- opts = { entries, page_count, rows (page_stat_data crudo), max_sec }
function ChapterTime.compute(opts)
    local ranges = ChapterTime.ranges(opts.entries, opts.page_count)
    if #ranges == 0 then return { chapters = {} } end
    local cap = int(opts.max_sec)
    if not cap or cap <= 0 then cap = ChapterTime.DEFAULT_MAX_SEC end
    local scaled = {}
    for _, row in ipairs(opts.rows or {}) do ChapterTime.rescale(row, opts.page_count, scaled) end
    table.sort(scaled, function(a, b)
        if a.start_time ~= b.start_time then return a.start_time < b.start_time end
        return a.page < b.page
    end)

    local function chapterOf(page)
        if page < ranges[1].first then return nil end
        local lo, hi = 1, #ranges
        while lo < hi do
            local mid = floor((lo + hi + 1) / 2)
            if ranges[mid].first <= page then lo = mid else hi = mid - 1 end
        end
        return lo
    end

    local groups = {}
    for i = 1, #ranges do groups[i] = {} end
    for _, row in ipairs(scaled) do
        local at = chapterOf(row.page)
        if at then local g = groups[at]; g[#g + 1] = row end
    end

    -- Promedio al entrar: las filas anteriores son un prefijo de `scaled`.
    local order = {}
    for i, list in ipairs(groups) do
        if #list > 0 then order[#order + 1] = { i = i, start = list[1].start_time } end
    end
    table.sort(order, function(a, b)
        if a.start ~= b.start then return a.start < b.start end
        return a.i < b.i
    end)
    local entry_avg, per_page, distinct, capped, cursor = {}, {}, 0, 0, 1
    for _, item in ipairs(order) do
        while cursor <= #scaled and scaled[cursor].start_time < item.start do
            local row = scaled[cursor]
            local old = per_page[row.page]
            if not old then distinct = distinct + 1; old = 0 end
            local raw = old + row.duration
            per_page[row.page] = raw
            capped = capped + math.min(raw, cap) - math.min(old, cap)
            cursor = cursor + 1
        end
        entry_avg[item.i] = distinct > 0 and capped / distinct or floor(0.5 * cap)
    end

    local chapters = {}
    for i, range in ipairs(ranges) do
        local list = groups[i]
        local chapter = {
            toc_index = range.toc_index,
            title = range.title,
            depth = range.depth,
            first_page = range.first,
            last_page = range.last,
            pages = range.last - range.first + 1,
            seconds = 0,
            pages_read = 0,
        }
        if #list > 0 then
            local seen, pages_read, seconds, last_at = {}, 0, 0, 0
            local entry = list[1]
            local after_seen, after_count, after_seconds = {}, 0, 0
            for _, row in ipairs(list) do
                seconds = seconds + row.duration
                if not seen[row.page] then seen[row.page] = true; pages_read = pages_read + 1 end
                last_at = math.max(last_at, row.start_time + row.duration)
                if row.page > entry.page then
                    after_seconds = after_seconds + row.duration
                    if not after_seen[row.page] then after_seen[row.page] = true; after_count = after_count + 1 end
                end
            end
            local avg = entry_avg[i]
            local left = range.last - entry.page
            chapter.seconds = seconds
            chapter.pages_read = pages_read
            chapter.first_read_at = entry.start_time
            chapter.last_read_at = last_at
            chapter.koreader = {
                entry_page = entry.page,
                pages_left = left,
                avg_page_seconds = round(avg * 10) / 10,
                estimate_seconds = round(left * avg),
                actual_seconds = after_seconds,
                comparable = (entry.page - range.first <= 1) and left >= 2 and after_count >= 0.8 * left,
            }
        end
        chapters[#chapters + 1] = chapter
    end
    return { chapters = chapters, summary = ChapterTime.summary(chapters) }
end

return ChapterTime

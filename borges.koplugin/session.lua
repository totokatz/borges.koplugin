--- Session tracking for reading sessions.
-- Tracks start/end time, pages actually read (time-based), suspend/resume with 4h cap.
-- Uses KOReader's approach: only pages where user spent >= MIN_READ_SEC count as "read".

local Session = {}

local MIN_READ_SEC = 5    -- minimum seconds on a page to count as "read"
local MAX_READ_SEC = 120  -- cap per page (fell asleep, left device, etc.)
local MAX_SESSION_SEC = 4 * 60 * 60

function Session:new()
    local o = {
        active = false,
        book_hash = nil,
        device_id = nil,
        started_at = nil,
        start_page = nil,
        current_page = nil,
        suspend_time = nil,
        -- Time-based page tracking
        page_enter_time = nil,   -- when user entered current page
        read_pages = {},         -- set of pages actually read (spent >= MIN_READ_SEC)
    }
    setmetatable(o, { __index = self })
    return o
end

--- Start a new reading session.
-- @param book_hash string
-- @param device_id string
-- @param current_page number
function Session:start(book_hash, device_id, current_page)
    self.book_hash = book_hash
    self.device_id = device_id
    self.started_at = os.time()
    self.start_page = current_page
    self.current_page = current_page
    self.suspend_time = nil
    self.page_enter_time = os.time()
    self.read_pages = {}
    self.active = true
end

--- Update current page during reading.
-- Evaluates time spent on the PREVIOUS page before switching.
-- @param pageno number
function Session:updatePage(pageno)
    if not self.active then return end

    -- Evaluate time on previous page
    if self.page_enter_time and self.current_page then
        local time_on_page = os.time() - self.page_enter_time
        if time_on_page >= MIN_READ_SEC then
            self.read_pages[self.current_page] = true
        end
    end

    -- Switch to new page
    self.current_page = pageno
    self.page_enter_time = os.time()
end

--- Mark session as suspended (device going to standby).
function Session:suspend()
    if not self.active then return end
    -- Evaluate current page before suspending
    if self.page_enter_time and self.current_page then
        local time_on_page = os.time() - self.page_enter_time
        if time_on_page >= MIN_READ_SEC then
            self.read_pages[self.current_page] = true
        end
    end
    self.suspend_time = os.time()
    self.page_enter_time = nil  -- pause timer
end

--- Resume from suspend. If standby exceeded 4 hours, close current session.
-- @return table|nil session_data (if closed by cap), boolean should_start_new
function Session:resume()
    if not self.active then return nil, false end
    if not self.suspend_time then return nil, false end

    local suspend_at = self.suspend_time
    local elapsed = os.time() - suspend_at
    self.suspend_time = nil

    -- 4 hour cap: if standby > 14400s, close session and signal new one needed
    if elapsed > 14400 then
        local session_data = self:_buildSessionData(suspend_at)
        self.active = false
        if session_data then
            return session_data, true
        end
        return nil, true
    end

    -- Resume: restart page timer (suspend time doesn't count as reading)
    self.page_enter_time = os.time()
    return nil, false
end

--- Finish the session and return data for the server.
-- Sessions shorter than 60 seconds are discarded.
-- @return table|nil session data, or nil if too short
function Session:finish()
    local sessions = self:finishAll()
    return sessions[1]
end

--- Finish the session as one or more server-valid segments.
-- A genuinely long uninterrupted reading session is split instead of being
-- rejected by the four-hour safety bound.
function Session:finishAll()
    if not self.active then return {} end
    -- Evaluate current page before finishing
    if self.page_enter_time and self.current_page then
        local time_on_page = os.time() - self.page_enter_time
        if time_on_page >= MIN_READ_SEC then
            self.read_pages[self.current_page] = true
        end
    end
    local ended_at = os.time()
    local total_duration = ended_at - self.started_at
    self.active = false
    if total_duration < 60 then return {} end

    local sessions = {}
    local segment_start = self.started_at
    while ended_at - segment_start >= 60 do
        local segment_end = math.min(segment_start + MAX_SESSION_SEC, ended_at)
        local is_final = segment_end == ended_at
        local session_data = self:_buildSessionData(
            segment_end,
            segment_start,
            segment_start == self.started_at and self.start_page or self.current_page,
            is_final and self:_countReadPages() or 0
        )
        if session_data then table.insert(sessions, session_data) end
        segment_start = segment_end
    end
    return sessions
end

--- Check if session is currently active.
-- @return boolean
function Session:isActive()
    return self.active
end

--- Count pages actually read (>= MIN_READ_SEC spent on them).
-- @return number
function Session:_countReadPages()
    local count = 0
    for _ in pairs(self.read_pages) do
        count = count + 1
    end
    return count
end

--- Build session data table for API submission.
-- @param ended_at_epoch number epoch timestamp for end time
-- @return table|nil session data, nil if duration < 60s
function Session:_buildSessionData(
    ended_at_epoch,
    started_at_epoch,
    start_page,
    pages_read
)
    started_at_epoch = started_at_epoch or self.started_at
    local duration = ended_at_epoch - started_at_epoch
    -- Discard sessions shorter than 60 seconds
    if duration < 60 then return nil end

    return {
        book_hash = self.book_hash,
        device_id = self.device_id,
        started_at = os.date("!%Y-%m-%dT%H:%M:%SZ", started_at_epoch),
        ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ", ended_at_epoch),
        duration_seconds = duration,
        pages_read = pages_read == nil and self:_countReadPages() or pages_read,
        start_page = start_page or self.start_page,
        end_page = self.current_page,
    }
end

return Session

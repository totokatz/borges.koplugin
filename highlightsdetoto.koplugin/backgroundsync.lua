-- Automatic sync keeps its Lua state in the UI process. Only the HTTP call
-- runs in a child; the suspended coroutine resumes here after its reply.
local Background = {}
Background.__index = Background
local running = setmetatable({}, { __mode = "k" })
local MAX_REPLY_BYTES = 2 * 1024 * 1024

local function failure(code)
    return { code = code, message = code, retryable = true }
end

function Background.current()
    local thread = coroutine.running()
    return thread and running[thread] or nil
end

function Background.request(work)
    assert(Background.current(), "background request outside sync coroutine")
    return coroutine.yield(work)
end

function Background.yieldToUI()
    if Background.current() then coroutine.yield(false) end
end

function Background:new(options)
    options = options or {}
    return setmetatable({
        ui = options.ui or require("ui/uimanager"),
        util = options.util or require("ffi/util"),
        json = options.json or require("rapidjson"),
        now = options.now or os.time,
        read_available = options.read_available,
        timeout = options.timeout or 45,
    }, self)
end

function Background:isRunning()
    return self.thread ~= nil
end

function Background:_finish(ok, err)
    if self.thread then running[self.thread] = nil end
    self.thread = nil
    local done = self.done
    self.done = nil
    if done then done(ok, err) end
end

function Background:cancel()
    self.cancelled = true
    if self.pid then
        self.util.terminateSubProcess(self.pid)
        -- The existing poll reaps the child and closes the pipe. Never wait
        -- synchronously during suspend, nor resume a cancelled coroutine.
    elseif self.thread then
        if self.resume_task then self.ui:unschedule(self.resume_task) end
        self:_finish(false, failure("background_cancelled"))
    end
end

function Background:run(work, done, valid)
    if self.thread then return false, "busy" end
    self.cancelled = false
    self.done, self.valid = done, valid
    self.thread = coroutine.create(work)
    running[self.thread] = self
    self:_resume()
    return true
end

function Background:_resume(...)
    if self.cancelled or (self.valid and not self.valid()) then
        return self:_finish(false, failure("background_cancelled"))
    end
    local ok, work = coroutine.resume(self.thread, ...)
    if not ok then return self:_finish(false, failure("background_sync_failed")) end
    if coroutine.status(self.thread) == "dead" then return self:_finish(true) end
    if work == false then
        self.resume_task = function()
            self.resume_task = nil
            if self.thread then self:_resume() end
        end
        self.ui:scheduleIn(0.05, self.resume_task)
        return
    end
    self:_startRequest(work)
end

function Background:_readAvailable(fd)
    if self.read_available then return self.read_available(fd) end
    local size = self.util.getNonBlockingReadSize(fd)
    if size == nil then error("nonblocking_pipe_unavailable") end
    if size == 0 then return "" end
    -- Read only bytes already available. In particular, don't wait for the
    -- child to exit: a reply larger than the pipe buffer would deadlock it.
    local ffi = require("ffi")
    size = math.min(size, 32768)
    local buffer = ffi.new("char[?]", size)
    local count = tonumber(ffi.C.read(fd, buffer, size))
    if count < 0 then error("background_pipe_read_failed") end
    return ffi.string(buffer, count)
end

function Background:_startRequest(work)
    if type(self.util.runInSubProcess) ~= "function"
        or type(self.util.getNonBlockingReadSize) ~= "function" then
        return self:_resume(nil, failure("background_unavailable"))
    end
    local started, pid, fd = pcall(self.util.runInSubProcess, function(_, write_fd)
        local ok, result, err, meta = pcall(work)
        local reply = ok and { result = result, error = err, meta = meta }
            or { error = failure("background_request_failed") }
        local encoded = self.json.encode(reply)
        if #encoded > MAX_REPLY_BYTES then
            encoded = self.json.encode({ error = failure("background_reply_too_large") })
        end
        self.util.writeToFD(write_fd, encoded, true)
    end, true)
    if not started or not pid then return self:_resume(nil, failure("background_unavailable")) end
    self.pid = pid
    local chunks, size, deadline, transport_error = {}, 0, self.now() + self.timeout
    local poll
    poll = function()
        if self.valid and not self.valid() then self:cancel() end
        local ok, part = pcall(self._readAvailable, self, fd)
        if ok and part and #part > 0 then
            size = size + #part
            if size <= MAX_REPLY_BYTES then table.insert(chunks, part) end
        end
        if not ok then transport_error = failure("background_pipe_read_failed") end
        if size > MAX_REPLY_BYTES then transport_error = failure("background_reply_too_large") end
        if self.now() >= deadline then transport_error = failure("connection_failed") end
        if transport_error or self.cancelled then self.util.terminateSubProcess(pid) end
        if not self.util.isSubProcessDone(pid) then
            self.ui:scheduleIn(0.1, poll)
            return
        end
        -- With the writer gone this read is non-blocking and closes the fd.
        local tail = self.util.readAllFromFD(fd)
        self.pid = nil
        if self.cancelled then return self:_finish(false, failure("background_cancelled")) end
        if transport_error then return self:_resume(nil, transport_error) end
        if size + #tail > MAX_REPLY_BYTES then
            return self:_resume(nil, failure("background_reply_too_large"))
        end
        table.insert(chunks, tail)
        local decoded, reply = pcall(self.json.decode, table.concat(chunks))
        if not decoded or type(reply) ~= "table"
            or (reply.result == nil and reply.error == nil) then
            return self:_resume(nil, failure("invalid_response"))
        end
        self:_resume(reply.result, reply.error, reply.meta)
    end
    self.ui:scheduleIn(0.1, poll)
end

return Background

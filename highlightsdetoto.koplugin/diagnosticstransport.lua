-- KOReader's POSIX subprocess API keeps DNS/TLS waits off the reading UI.
local Transport = {}
function Transport.send(work, done, deps)
    deps = deps or {}
    local util = deps.util or require('ffi/util')
    local ui = deps.ui or require('ui/uimanager')
    local now = deps.now or os.time
    local pid, fd = util.runInSubProcess(function(_, write_fd)
        local ok, accepted = pcall(work)
        util.writeToFD(write_fd, ok and accepted and '1' or '0', true)
    end, true)
    if not pid then done(false); return end
    local deadline = now() + 15
    local poll
    poll = function()
        if util.isSubProcessDone(pid) then
            local result = util.readAllFromFD(fd)
            done(result == '1')
        else
            if now() >= deadline then util.terminateSubProcess(pid) end
            ui:scheduleIn(0.5, poll)
        end
    end
    ui:scheduleIn(0.5, poll)
end
return Transport

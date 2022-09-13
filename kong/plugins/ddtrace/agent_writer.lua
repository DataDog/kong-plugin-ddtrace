local resty_http = require "resty.http"
local encoder = require "kong.plugins.ddtrace.msgpack_encode"

local agent_writer_methods = {}
local agent_writer_mt = {
    __index = agent_writer_methods,
}


local function new(http_endpoint)
    local self = setmetatable({
        http_endpoint = http_endpoint,
        trace_segments = {},
        trace_segments_n = 0,
    }, agent_writer_mt)
    local timer_handle, err = ngx.timer.every(2.0, function()
        local ok, err = self:flush()
        if not ok then
            kong.log.err("agent_writer error ", err)
            return
        end
    end)

    if not timer_handle then
        kong.log.err("failed to create timer: " .. err)
        return self
    end
    return self
end


function agent_writer_methods:add(spans)
    local i = self.trace_segments_n + 1
    self.trace_segments[i] = spans
    self.trace_segments_n = i
end


function agent_writer_methods:flush()
    if self.trace_segments_n == 0 then
        return true
    end

    -- kong.log.err("trace_segments: ", #self.trace_segments)
    -- kong.log.err("trace_segments: ", dump(self.trace_segments))

    local payload = encoder.pack(self.trace_segments)
    -- kong.log.err("payload length: ", #payload)
    -- kong.log.err("hexdump: ", to_hex(payload))
    self.trace_segments = {}
    self.trace_segments_n = 0

    if self.http_endpoint == nil or self.http_endpoint == ngx.null then
        kong.log.err("no useful endpoint to send payload")
        return true
    end

    -- kong.log.err("sending request")

    local httpc = resty_http.new()
    local res, err = httpc:request_uri(self.http_endpoint, {
        method = "POST",
        headers = {
            ["content-type"] = "application/msgpack",
        },
        body = payload
    })
    -- TODO: on failure, retry?
    if not res then
        return nil, "failed to request: " .. err
    elseif res.status < 200 or res.status >= 300 then
        return nil, "failed: " .. res.status .. " " .. res.reason
    end
    return true
end


return {
    new = new,
}

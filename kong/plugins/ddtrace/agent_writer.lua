local resty_http = require "resty.http"
local encoder = require "kong.plugins.ddtrace.msgpack_encode"
local table =  require "table"

local agent_writer_methods = {}
local agent_writer_mt = {
    __index = agent_writer_methods,
}

local function new(http_endpoint, sampler)
    return setmetatable({
        http_endpoint = http_endpoint,
        sampler = sampler,
        trace_segments = {},
        trace_segments_n = 0,
    }, agent_writer_mt)
end


function agent_writer_methods:add(spans)
    local i = self.trace_segments_n + 1
    self.trace_segments[i] = encoder.pack(spans)
    self.trace_segments_n = i
end


function agent_writer_methods:flush()
    if self.trace_segments_n == 0 then
        -- return immediately if no data to send
        return true
    end

    local payload = encoder.arrayheader(self.trace_segments_n) .. table.concat(self.trace_segments)
    -- kong.log.err("payload type: " .. type(payload) .. " size: " .. #payload)
    -- kong.log.err(encoder.hexadump(payload))
    -- clear encoded segments
    self.trace_segments = {}
    self.trace_segments_n = 0
    if true then
        return true
    end

    if self.http_endpoint == nil or self.http_endpoint == ngx.null then
        kong.log.err("no useful endpoint to send payload")
        return true
    end

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
    self.sampler:update_sampling_rates(res.body)

    return true
end


return {
    new = new,
}

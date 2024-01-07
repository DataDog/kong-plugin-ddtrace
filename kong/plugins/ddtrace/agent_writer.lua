local resty_http = require "resty.http"
local encoder = require "kong.plugins.ddtrace.msgpack_encode"
local table =  require "table"

local agent_writer_methods = {}
local agent_writer_mt = {
    __index = agent_writer_methods,
}

local function new(http_endpoint, sampler, tracer_version)
    kong.log.notice("traces will be sent to the agent at " .. http_endpoint)
    return setmetatable({
        http_endpoint = http_endpoint,
        sampler = sampler,
        tracer_version,
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

    -- store this value for later
    local trace_count = tostring(self.trace_segments_n)

    local payload = encoder.arrayheader(self.trace_segments_n) .. table.concat(self.trace_segments)
    -- clear encoded segments
    self.trace_segments = {}
    self.trace_segments_n = 0

    if self.http_endpoint == nil or self.http_endpoint == ngx.null then
        kong.log.err("no useful endpoint to send payload")
        return true
    end

    local httpc = resty_http.new()
    local res, err = httpc:request_uri(self.http_endpoint, {
        method = "POST",
        headers = {
            ["content-type"] = "application/msgpack",
            ['X-Datadog-Trace-Count'] = trace_count,
            ['Datadog-Meta-Lang'] = "lua",
            ['Datadog-Meta-Lang-Interpreter'] = "LuaJIT",
            ['Datadog-Meta-Lang-Version'] = jit.version,
            ['Datadog-Meta-Tracer-Version'] = self.tracer_version,

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

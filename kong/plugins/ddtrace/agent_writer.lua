local resty_http = require("resty.http")
local encoder = require("kong.plugins.ddtrace.msgpack_encode")
local table = require("table")

local agent_writer_methods = {}
local agent_writer_mt = {
    __index = agent_writer_methods,
}

local function new(agent_url, sampler, tracer_version)
    local traces_endpoint = string.format("%s/v0.4/traces", agent_url)

    return setmetatable({
        traces_endpoint = traces_endpoint,
        sampler = sampler,
        tracer_version,
        trace_segments = {},
        trace_segments_n = 0,
    }, agent_writer_mt)
end

local function encode_span(span)
    return encoder.pack({
        type = span.type,
        service = span.service,
        name = span.name,
        resource = span.resource,
        trace_id = span.trace_id.low,
        span_id = span.span_id,
        parent_id = span.parent_id,
        start = span.start,
        duration = span.duration,
        sampling_priority = span.sampling_priority,
        origin = span.origin,
        meta = span.meta,
        metrics = span.metrics,
        error = span.error,
    })
end

function agent_writer_methods:add(spans)
    local i = self.trace_segments_n + 1

    local buffer = encoder.arrayheader(#spans)
    for _, span in ipairs(spans) do
        buffer = buffer .. encode_span(span)
    end

    self.trace_segments[i] = buffer
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

    if self.traces_endpoint == nil or self.traces_endpoint == ngx.null then
        kong.log.err("no useful endpoint to send payload")
        return true
    end

    local httpc = resty_http.new()
    local res, err = httpc:request_uri(self.traces_endpoint, {
        method = "POST",
        headers = {
            ["content-type"] = "application/msgpack",
            ["X-Datadog-Trace-Count"] = trace_count,
            ["Datadog-Meta-Lang"] = "lua",
            ["Datadog-Meta-Lang-Interpreter"] = "LuaJIT",
            ["Datadog-Meta-Lang-Version"] = jit.version,
            ["Datadog-Meta-Tracer-Version"] = self.tracer_version,
        },
        body = payload,
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

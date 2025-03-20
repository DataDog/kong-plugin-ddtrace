local resty_http = require("resty.http")
local encoder = require("kong.plugins.ddtrace.msgpack_encode")
local table = require("table")
local Queue = require("kong.tools.queue")

local agent_writer_methods = {}
local agent_writer_mt = {
    __index = agent_writer_methods,
}

local queue_conf = {
    name = "ddtrace",
    log_tag = "ddtrace.writer",
    max_batch_size = 100,
    max_coalescing_delay = 2,
    max_entries = 10000,
    -- Intake max payload allowed is 5MiB
    max_bytes = 5 * 8388608,
    max_retry_time = 60,
    max_retry_delay = 60,
    initial_retry_delay = 0.01,
    concurrency_limit = 1,
}

local function new(agent_url, sampler, tracer_version)
    local traces_endpoint = string.format("%s/v0.4/traces", agent_url)

    return setmetatable({
        traces_endpoint = traces_endpoint,
        sampler = sampler,
        tracer_version,
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

local function serialize_trace(spans)
    local buffer = encoder.arrayheader(#spans)
    for _, span in ipairs(spans) do
        buffer = buffer .. encode_span(span)
    end

    return buffer
end

local function send_trace(conf, traces)
    local n_traces = #traces
    local trace_count = tostring(n_traces)

    local payload = encoder.arrayheader(n_traces) .. table.concat(traces)

    local httpc = resty_http.new()
    local res, err = httpc:request_uri(conf.traces_endpoint, {
        method = "POST",
        headers = {
            ["content-type"] = "application/msgpack",
            ["X-Datadog-Trace-Count"] = trace_count,
            ["Datadog-Meta-Lang"] = "lua",
            ["Datadog-Meta-Lang-Interpreter"] = "LuaJIT",
            ["Datadog-Meta-Lang-Version"] = jit.version,
            ["Datadog-Meta-Tracer-Version"] = conf.tracer_version,
        },
        body = payload,
    })

    if not res then
        return false, "failed to request: " .. err
    elseif res.status < 200 or res.status >= 300 then
        return false, "failed: " .. res.status .. " " .. res.reason
    end

    conf.sampler:update_sampling_rates(res.body)
    return true
end

function agent_writer_methods:enqueue_trace(spans)
    assert(type(spans) == "table", "expected a table of spans, got " .. type(spans) .. " instead.")
    Queue.enqueue(queue_conf, send_trace, self, serialize_trace(spans))
end

return {
    new = new,
}

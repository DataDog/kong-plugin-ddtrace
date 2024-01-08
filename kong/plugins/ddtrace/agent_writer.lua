local resty_http = require "resty.http"
local encoder = require "kong.plugins.ddtrace.msgpack_encode"
local table =  require "table"

local agent_writer_methods = {}
local agent_writer_mt = {
    __index = agent_writer_methods,
}

local function new(conf, sampler, tracer_version)
    -- traces_endpoint is determined by the configuration with this
    -- order of precedence:
    -- - use trace_agent_url if set
    -- - use agent_host:agent_port if agent_host is set
    -- - use agent_endpoint if set but warn that it is deprecated
    -- - if nothing is set, default to http://localhost:8126/v0.4/traces
    local traces_endpoint = string.format("http://localhost:%d/v0.4/traces", conf.trace_agent_port)
    if conf.trace_agent_url then
        traces_endpoint = conf.trace_agent_url .. "/v0.4/traces"
    elseif conf.agent_host then
        traces_endpoint = string.format("http://%s:%d/v0.4/traces", conf.agent_host, conf.trace_agent_port)
    elseif conf.agent_endpoint then
        kong.log.warn("agent_endpoint is deprecated. Please use trace_agent_url or agent_host instead.")
        traces_endpoint = conf.agent_endpoint
    end
    kong.log.notice("traces will be sent to the agent at " .. traces_endpoint)
    return setmetatable({
        traces_endpoint = traces_endpoint,
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

    if self.traces_endpoint == nil or self.traces_endpoint == ngx.null then
        kong.log.err("no useful endpoint to send payload")
        return true
    end

    local httpc = resty_http.new()
    local res, err = httpc:request_uri(self.traces_endpoint, {
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

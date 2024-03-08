-- stub out the resty.http calls that aren't under test
local resty_http = require "resty.http"
local resty_http_methods = {}
function resty_http_methods:request_uri(...)
    return {
        status = 200,
        body = '{ "rate_by_service": { "service:test_service,env:": 0.1, "service:,env:": 1.0 } }',
    }, nil
end
local resty_http_mt = {
    __index = resty_http_methods,
}
resty_http.new = function(...)
    return setmetatable({}, resty_http_mt)
end

-- stub implementation of kong.log methods
_G.kong = {
    log = {
        err = function(msg) end,
        warn = function(msg) end,
        notice = function(msg) end,
    },
}

local new_agent_writer = require "kong.plugins.ddtrace.agent_writer".new
local new_sampler = require "kong.plugins.ddtrace.sampler".new
local new_span = require "kong.plugins.ddtrace.span".new

describe("agent_writer", function()
    it("adds spans then flushes them", function()
        local sampler = new_sampler(100, 1.0)
        local agent_writer = new_agent_writer("http://datadog-agent:8126", sampler, "test-version")
        assert.equal("http://datadog-agent:8126/v0.4/traces", agent_writer.traces_endpoint)
        local start_time = 1700000000000000000LL
        local duration = 100000000LL
        local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, false, nil)
        span:finish(start_time + duration)
        agent_writer:add({span})
        local ok = agent_writer:flush()
        assert.is_true(ok)
    end)
end)

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
    describe("configures the traces endpoint", function()
        local sampler = new_sampler(100, 1.0)
        it("priority #1 is trace_agent_url", function()
            local conf = { trace_agent_url = "http://trace-agent-url:8126", agent_host = "agent-host", trace_agent_port = 8126, agent_endpoint = "http://agent-endpoint:8126/v0.4/traces" }
            local agent_writer = new_agent_writer(conf, sampler, "test-version")
            assert.equal("http://trace-agent-url:8126/v0.4/traces", agent_writer.traces_endpoint)
        end)
        it("priority #2 is agent_host", function()
            local conf = { agent_host = "agent-host", trace_agent_port = 8126, agent_endpoint = "http://agent-endpoint:8126/v0.4/traces" }
            local agent_writer = new_agent_writer(conf, sampler, "test-version")
            assert.equal("http://agent-host:8126/v0.4/traces", agent_writer.traces_endpoint)
        end)
        it("priority #3 is agent_endpoint", function()
            local conf = { trace_agent_port = 8126, agent_endpoint = "http://agent-endpoint:8126/v0.4/traces" }
            local agent_writer = new_agent_writer(conf, sampler, "test-version")
            assert.equal("http://agent-endpoint:8126/v0.4/traces", agent_writer.traces_endpoint)
        end)
        it("and defaults to localhost", function()
            local conf = { trace_agent_port = 8126 }
            local agent_writer = new_agent_writer(conf, sampler, "test-version")
            assert.equal("http://localhost:8126/v0.4/traces", agent_writer.traces_endpoint)
        end)
    end)

    it("adds spans then flushes them", function()
        local sampler = new_sampler(100, 1.0)
        local agent_writer = new_agent_writer({ agent_host = "datadog-agent", trace_agent_port = 8126 }, sampler, "test-version")
        local start_time = 1700000000000000000LL
        local duration = 100000000LL
        local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil)
        span:finish(start_time + duration)
        agent_writer:add({span})
        local ok = agent_writer:flush()
        assert.is_true(ok)
    end)
end)

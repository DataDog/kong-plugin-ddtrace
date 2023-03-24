local new_sampler = require "kong.plugins.ddtrace.sampler".new
local new_span = require "kong.plugins.ddtrace.span".new

describe("trace sampler", function()
    it("is created with initial limits", function()
        local start_time = 1700000000000000000LL
        local duration = 100000000LL
        local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil)
        local sampler = new_sampler(10, 1.0)
        local sampled = sampler:sample(span)
        assert.is_true(sampled)
        assert.equal(span.metrics["_dd.rule_psr"], 1.0)
        assert.equal(span.metrics["_dd.limit_psr"], 1.0)
        span:finish(start_time + duration)
    end)
    it("applies the limits  ", function()
        local start_time = 1700000000000000000LL
        local duration = 100000000LL
        local increment = 100000000LL -- 0.1s
        local sampler = new_sampler(3, 1.0)
        for i = 1, 10 do
            local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil)
            local sampled = sampler:sample(span)
            if i <= 3 then
                assert.is_true(sampled)
                assert.equal(span.metrics["_dd.rule_psr"], 1.0)
                assert.equal(span.metrics["_dd.limit_psr"], 1.0)
                assert.equal(span.metrics["_dd.p.dm"], 3)
            else
                assert.is_true(sampled) -- still true, but not because of limiter
                assert.equal(span.metrics["_dd.rule_psr"], 1.0)
                assert.equal(span.metrics["_dd.limit_psr"], 1.0)
                assert.equal(span.metrics["_dd.agent_psr"], 1.0)
                assert.equal(span.metrics["_dd.p.dm"], 1)
            end
            span:finish(start_time + duration)
            start_time = start_time + increment
        end
    end)
    it("updates the effective rate", function()
        local start_time = 1700000000000000000LL
        local duration = 100000000LL
        local increment = 250000000LL -- 0.25s
        local sampler = new_sampler(3, 1.0)
        local span
        -- first two will be sampled, next two not sampled, and fifth one in new time interval, 
        -- so effective rate should be 0.5
        for i = 1, 5 do
            span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil)
            local sampled = sampler:sample(span)
            span:finish(start_time + duration)
            start_time = start_time + increment
        end
        assert.equal(span.metrics["_dd.limit_psr"], 0.5)
    end)
    it("uses agent rates when zero permitted by limiter config", function()
        local start_time = 1700000000000000000LL
        local duration = 100000000LL
        local sampler = new_sampler(0, 1.0)
        local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil)
        local sampled = sampler:sample(span)
        span:finish(start_time + duration)
        assert.equal(span.metrics["_dd.p.dm"], 1)
    end)
    it("applies rate supplied by the agent", function()
        local start_time = 1700000000000000000LL
        local duration = 100000000LL
        local sampler = new_sampler(0, 1.0)
        sampler:update_sampling_rates('{ "rate_by_service": { "service:test_service,env:": 0.1, "service:,env:": 1.0 } }')
        local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil)
        local sampled = sampler:sample(span)
        span:finish(start_time + duration)
        assert.equal(span.metrics["_dd.p.dm"], 1)
        assert.equal(span.metrics["_dd.agent_psr"], 0.1)
    end)
end)

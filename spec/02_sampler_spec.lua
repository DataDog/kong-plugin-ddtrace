local new_sampler = require "kong.plugins.ddtrace.sampler".new
local new_span = require "kong.plugins.ddtrace.span".new

-- stub implementation of kong.log.err
_G.kong = {
    log = {
        err = function(msg) end,
    },
}

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
                assert.equal(span.sampling_priority, 2)
            else
                assert.is_true(sampled) -- still true, but not because of limiter
                assert.equal(span.metrics["_dd.rule_psr"], 1.0)
                assert.equal(span.metrics["_dd.limit_psr"], 1.0)
                assert.equal(span.metrics["_dd.agent_psr"], 1.0)
                assert.equal(span.metrics["_dd.p.dm"], 1)
                assert.equal(span.sampling_priority, 1)
            end
            span:finish(start_time + duration)
            start_time = start_time + increment
        end
    end)
    it("applies the rate to the limit", function()
         local start_time = 1700000000000000000LL
         local duration = 100000000LL
         local increment = 10000000LL -- 0.01s
         local sampler = new_sampler(50, 0.8)
         local limit_rule_and_sampled = 0
         local limit_rule_and_not_sampled = 0
         local agent_rate_applied = 0
         for i = 1, 100 do
             local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil)
             local sampled = sampler:sample(span)
             if span.metrics["_dd.p.dm"] == 3 then
                 if sampled then
                     assert.equal(span.sampling_priority, 2)
                     limit_rule_and_sampled = limit_rule_and_sampled + 1
                 else
                     assert.equal(span.sampling_priority, -1)
                     limit_rule_and_not_sampled = limit_rule_and_not_sampled + 1
                 end
             elseif span.metrics["_dd.p.dm"] == 1 then
                 if sampled then
                     assert.equal(span.sampling_priority, 1)
                 else
                     assert.equal(span.sampling_priority, 0)
                 end
                 agent_rate_applied = agent_rate_applied + 1
             end
             span:finish(start_time + duration)
             start_time = start_time + increment
         end
         -- the quantities sampled and not sampled depend on randomness, so they fall within a range
         assert.is_true(limit_rule_and_sampled >= 49)
         assert.is_true(limit_rule_and_sampled <= 51)
         assert.is_true(limit_rule_and_not_sampled >= 6)
         assert.is_true(limit_rule_and_not_sampled <= 18)
         assert.equal(agent_rate_applied, 100 - limit_rule_and_sampled - limit_rule_and_not_sampled)
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
            sampler:sample(span)
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
        sampler:sample(span)
        span:finish(start_time + duration)
        assert.equal(span.metrics["_dd.p.dm"], 1)
    end)
    it("applies rate supplied by the agent", function()
        local start_time = 1700000000000000000LL
        local duration = 100000000LL
        local sampler = new_sampler(0, 1.0)
        local rates_applied = sampler:update_sampling_rates('{ "rate_by_service": { "service:test_service,env:": 0.1, "service:,env:": 1.0 } }')
        assert.is_true(rates_applied)
        local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil)
        sampler:sample(span)
        span:finish(start_time + duration)
        assert.equal(span.metrics["_dd.p.dm"], 1)
        assert.equal(span.metrics["_dd.agent_psr"], 0.1)
    end)
    it("reports errors when parsing fails", function()
        local sampler = new_sampler(0, 1.0)
        local empty_reply = sampler:update_sampling_rates('')
        assert.is_false(empty_reply)
        local wrong_type = sampler:update_sampling_rates('[]')
        assert.is_false(wrong_type)
        local incomplete_json = sampler:update_sampling_rates('{ "rate_by_service": "')
        assert.is_false(incomplete_json)
        local missing_rates = sampler:update_sampling_rates('{ "hello": "world" }')
        assert.is_false(missing_rates)
        local incorrect_key_type = sampler:update_sampling_rates('{ "rate_by_service": { { "object-not-key": "should have an error" } }')
        assert.is_false(incorrect_key_type)
        local incorrect_value_type = sampler:update_sampling_rates('{ "rate_by_service": { "service:test_service,env:": 0.1, "service:,env:": "this should be a number"} }')
        assert.is_false(incorrect_value_type)
    end)
end)

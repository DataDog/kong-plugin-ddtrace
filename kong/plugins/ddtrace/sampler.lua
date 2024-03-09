--[[
The sampler is used to determine whether spans should be retained
and sent to Datadog's trace intake, or dropped by the agent.

The main mechanisms are a rule-based sampler using user-defined rules,
and a rate-based sampler using rates provided by the Datadog agent.
]]

local cjson = require("cjson.safe")
cjson.decode_array_with_array_mt(true)

local sampler_methods = {}
local sampler_mt = {
    __index = sampler_methods,
}

-- returns a 64-bit value representing the max id that a hashed trace id can
-- have to be sampled.
local function max_id_for_rate(rate)
    if not rate or rate == 0.0 then
        return 0x0ULL
    end
    if rate == 1.0 then
        return 0xFFFFFFFFFFFFFFFFULL
    end
    -- calculate the rate, basically shifting decimal places
    local max_id = 0x0ULL

    -- this weird math below is because we can't multiply unsigned 64 bit numbers with flaots
    -- and get reasonable results: precision is lost.
    -- a string representation of the floating point number is used instead of arithmetic because
    -- floats can't be trusted to retain the same digits when multiplied.
    -- this way could be a bit more precise, but under-calculates the value by a tiny but
    -- insignificant amount
    local factors = { 10, 100, 1000, 10000 }
    local rate_string = string.format("%.4f", rate)
    for i, x in ipairs(factors) do
        local digit = 1ULL * tonumber(rate_string:sub(i + 2, i + 2))
        max_id = max_id + (0xFFFFFFFFFFFFFFFFULL / x) * digit
    end
    return max_id
end

-- these values are used for agent-based sampling rates
-- which is applied when the initial sampling rates are exhausted
local default_sampling_rate_key = "service:,env:"

local function new(samples_per_second, sample_rate)
    -- pre-calculate the counters used for initial sampling
    local sampled_traces = {}
    local sampling_limits = {}

    local samples_per_second_uint = samples_per_second * 1ULL
    local samples_per_decisecond = samples_per_second_uint / 10
    local remainder = samples_per_second_uint % 10
    for i = 0, 9 do
        sampled_traces[i] = 0
        if remainder > i then
            sampling_limits[i] = tonumber(samples_per_decisecond + 1)
        else
            sampling_limits[i] = tonumber(samples_per_decisecond)
        end
    end

    return setmetatable({
        samples_per_second = samples_per_second,
        sample_rate = sample_rate,
        sample_rate_max_id = max_id_for_rate(sample_rate),
        sampled_traces = sampled_traces,
        sampling_limits = sampling_limits,
        spans_counted = 0,
        effective_rate = sample_rate, -- this is updated when the time rolls over
        last_sample_interval = nil,
        agent_sample_rates = {},
    }, sampler_mt)
end

-- returns whether the span is sampled based on the max_id
local function sampling_decision(span, max_id)
    -- not-ideal knuth hashing of trace ids
    local hashed_trace_id = span.trace_id.low * 1111111111111111111ULL
    if hashed_trace_id > max_id then
        return false
    end
    return true
end

local function apply_initial_sample_rate(sampler, span)
    -- check for rollover to new sampling interval
    local span_start_interval = span.start / 1000000000ULL
    if sampler.last_sample_interval then
        if span_start_interval > sampler.last_sample_interval then
            if sampler.sample_rate > 0.0 and sampler.spans_counted > 0 then
                -- update calculations
                local total_sampled = 0
                for i = 0, 9 do
                    total_sampled = total_sampled + sampler.sampled_traces[i]
                    sampler.sampled_traces[i] = 0
                end
                sampler.effective_rate = total_sampled / sampler.spans_counted
                sampler.spans_counted = 0
            end
            sampler.last_sample_interval = span_start_interval
            -- else
            --     if this started earlier than the last sample interval and we've just reset things,
            --     then we can't do much about it
            --     this is checked for later as well
        end
    else
        sampler.last_sample_interval = span_start_interval
    end

    sampler.spans_counted = sampler.spans_counted + 1
    -- set limiter metrics, regardless of outcome of initial sampling rate
    span.meta["_dd.p.dm"] = "-3" -- "RULE"
    span.metrics["_dd.rule_psr"] = sampler.sample_rate
    span.metrics["_dd.limit_psr"] = sampler.effective_rate
    -- apply initial sampling rate
    local current_decisecond = span.start / 100000000ULL
    local idx = tonumber(current_decisecond % 10)
    if sampler.sampled_traces[idx] < sampler.sampling_limits[idx] then
        local sampled = sampling_decision(span, sampler.sample_rate_max_id)
        if sampled then
            -- only sampled traces contribute to this counter
            sampler.sampled_traces[idx] = sampler.sampled_traces[idx] + 1
        end
        return sampled
    end

    return false
end

local function apply_agent_sample_rate(sampler, span)
    local service = span.service or ""
    local env = span.meta["env"] or ""

    local sample_rate_key = "service:" .. service .. ",env:" .. env

    local rule = sampler.agent_sample_rates[sample_rate_key] or sampler.agent_sample_rates[default_sampling_rate_key]
    if rule then
        local sampled = sampling_decision(span, rule.max_id)
        span.meta["_dd.p.dm"] = "-1" -- "AGENT RATE"
        span.metrics["_dd.agent_psr"] = rule.rate
        return true, sampled
    end

    return false, false
end

-- make a sampling decision for the trace
-- if an initial sample rate is configured, apply that.
-- otherwise use rates that are calculated by the agent.
-- if there are no rates available (usually when just started), sample the trace
function sampler_methods:sample(span)
    if self.sample_rate then
        local sampled = apply_initial_sample_rate(self, span)
        -- kong.log.err("sample: initial sample rate: applied = " .. tostring(applied) .. " sampled = " .. tostring(sampled))
        if sampled then
            span:set_sampling_priority(2)
        else
            span:set_sampling_priority(-1)
        end
        return sampled
    end
    local applied, sampled = apply_agent_sample_rate(self, span)
    -- kong.log.err("sample: agent sample rate: applied = " .. tostring(applied) .. " sampled = " .. tostring(sampled))
    if applied then
        if sampled then
            span:set_sampling_priority(1)
        else
            span:set_sampling_priority(0)
        end
        return sampled
    end
    -- neither initial-sample or agent-sample rates were applied
    -- fallback is to just sample things
    span.meta["_dd.p.dm"] = "-0" -- "DEFAULT"
    span:set_sampling_priority(1)
    return true
end

local function parse_sampling_rule(key, value)
    if type(key) ~= "string" then
        return nil, "rate_by_service key has type " .. type(key) .. ", expected string"
    end
    if type(value) ~= "number" then
        return nil, "rate_by_service value has type " .. type(value) .. ", expected number"
    end
    if value < 0.0 or value > 1.0 then
        return nil, "rate_by_service value out of expected range: " .. value
    end

    return { rate = value, max_id = max_id_for_rate(value) }
end

function sampler_methods:update_sampling_rates(json_payload)
    local agent_update, err = cjson.decode(json_payload)
    if err then
        kong.log.err("error decoding agent sampling rates: " .. err)
        return false
    end
    local rate_by_service = agent_update["rate_by_service"]
    if not rate_by_service then
        kong.log.err("agent sample rates missing field: rate_by_service")
        return false
    end

    -- empty current table
    for key in pairs(self.agent_sample_rates) do
        self.agent_sample_rates[key] = nil
    end

    -- update table with new rates
    local parsed_ok = true
    for key, value in pairs(rate_by_service) do
        local rule, err = parse_sampling_rule(key, value)
        if err then
            kong.log.err(err)
            parsed_ok = false
        else
            self.agent_sample_rates[key] = rule
        end
    end

    return parsed_ok
end

return {
    new = new,
}

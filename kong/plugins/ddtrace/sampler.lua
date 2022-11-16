--[[
The sampler is used to determine whether spans should be retained
and sent to Datadog's trace intake, or dropped by the agent.

The main mechanisms are a rule-based sampler using user-defined rules,
and a rate-based sampler using rates provided by the Datadog agent.
]]

local cjson = require "cjson.safe"
cjson.decode_array_with_array_mt = true
local ffi = require "ffi"

local sampler_methods = {}
local sampler_mt = {
    __index = sampler_methods,
}


local default_sampling_rate_key = "service:,env:"
local default_sampling_rate_value = {
    rate = 1.0,
    max_id = 0xFFFFFFFFFFFFFFFFULL,
}

function new(rules)
    return setmetatable({
        agent_sample_rates = {
            [default_sampling_rate_key] = default_sampling_rate_value,
        },
        rules = rules,
    }, sampler_mt)
end

-- returns whether the span is sampled based on the max_id
local function sampling_decision(span, max_id)
    -- not-ideal knuth hashing of trace ids
    local hashed_trace_id = span.trace_id * 1111111111111111111ULL
    -- kong.log.err("sampling decision: " .. tostring(span.trace_id) .. " hashed " .. tostring(hashed_trace_id) .. " decision " .. tostring(hashed_trace_id <= max_id))
    if hashed_trace_id > max_id then
        return false
    end
    return true
end

-- returns a 64-bit value representing the max id that a hashed trace id can
-- have to be sampled.
local function max_id_for_rate(rate)
    if rate == 1.0 then
        return 0xFFFFFFFFFFFFFFFFULL
    end
    if rate == 0.0 then
        return 0x0ULL
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
        local digit = 1ULL * tonumber(rate_string:sub(i+2, i+2))
        max_id = max_id + (0xFFFFFFFFFFFFFFFFULL / x) * digit
    end
    return max_id
end


    



function sampler_methods:sample(span)
    -- apply sampling rules, if present
    --
    --
    -- no rules were applied, apply a default rule
    --
    --
    --
    -- default rule not applied, use agent sampling rates
    local service = span.service
    if not service then
        service = ""
    end
    local env = span.env
    if not env then
        env = ""
    end

    local service_env = self.agent_sample_rates["service:" .. service .. ",env:" .. env]
    if service_env then
        local sampled = sampling_decision(span, service_env.max_id)
        span.metrics["_dd.agent_psr"] = service_env.rate
        return sampled
    end
    local default = self.agent_sample_rates[default_sampling_rate_key]
    if default then
        local sampled = sampling_decision(span, default.max_id)
        span.metrics["_dd.agent_psr"] = default.rate
        return sampled
    end

    -- fallback is to just sample things
    return true
end

function sampler_methods:update_sampling_rates(json_payload)
    -- kong.log.err("update_sampling_rates: " .. json_payload)
    local agent_update, err = cjson.decode(json_payload)
    if err then
        -- log an error?
        return
    end
    local rate_by_service = agent_update["rate_by_service"]
    if not rate_by_service then
        -- log an error?
        return
    end

    -- empty current table
    for key in pairs(self.agent_sample_rates) do
        self.agent_sample_rates[key] = nil
    end

    -- update table with new rates
    for key, value in pairs(rate_by_service) do
        if type(key) ~= "string" then
            -- log an error?
            goto continue
        end
        if type(value) ~= "number" or value < 0.0 or value > 1.0 then
            -- log an error?
            goto continue
        end
        self.agent_sample_rates[key] = {
            rate = value,
            max_id = max_id_for_rate(value),
        }
        ::continue::
    end
    -- make sure the default is still there
    if not self.agent_sample_rates[default_sampling_rate_key] then
        self.agent_sample_rates[default_sampling_rate_key] = default_sampling_rate_value
    end
    local entries = 0
    for key, value in pairs(self.agent_sample_rates) do entries = entries + 1 end
    -- kong.log.err("update_sampling_rates: " .. tostring(entries) .. "rates")
end


return {
    new = new,
}

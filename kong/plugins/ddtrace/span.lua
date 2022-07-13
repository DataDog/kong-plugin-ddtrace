--[[
The internal data structure is used by Datadog's v0.4 trace api endpoint.
It is encoded in msgpack using the customized encoder.
]]

local ffi = require "ffi"

local utils = require "kong.tools.utils"
local rand_bytes = utils.get_rand_bytes
local byte = string.byte
local fmt = string.format

local span_methods = {}
local span_mt = {
    __index = span_methods,
}

local uint64_t = ffi.typeof("uint64_t")
local int64_t = ffi.typeof("int64_t")

local function generate_span_id()
    local x = rand_bytes(8)
    local b = {1ULL * byte(x,1), 1ULL * byte(x,2), 1ULL * byte(x,3), 1ULL * byte(x,4), 1ULL * byte(x,5), 1ULL * byte(x,6), 1ULL * byte(x,7), 1ULL * byte(x,8)}
    local id = bit.bor(bit.lshift(b[1], 56), bit.lshift(b[2], 48), bit.lshift(b[3], 40), bit.lshift(b[4], 32), bit.lshift(b[5], 24), bit.lshift(b[6], 16), bit.lshift(b[7], 8), b[8])
    -- truncate to 63-bit value
    return bit.band(id, 0x7FFFFFFFFFFFFFFFULL)
end

local function new(service, name, resource,
    trace_id, span_id, parent_id,
    start, sampling_priority, origin)
    assert(type(name) == "string" and name ~= "", "invalid span name")
    assert(type(resource) == "string" and resource ~= "", "invalid span resource")
    assert(trace_id == nil or ffi.istype(uint64_t, trace_id), "invalid trace id")
    assert(span_id == nil or ffi.istype(uint64_t, span_id), "invalid span id")
    assert(parent_id == nil or ffi.istype(uint64_t, parent_id), "invalid parent id")
    assert(ffi.istype(int64_t, start) and start >= 0, "invalid span start timestamp")
    assert(type(sampling_priority) == "number", "invalid sampling priority")

    if trace_id == nil then
        -- a new trace
        trace_id = generate_span_id()
        span_id = trace_id
        parent_id = uint64_t(0)
    elseif span_id == nil then
        -- a new span for an existing trace
        span_id = generate_span_id()
    end

    return setmetatable({
        type = "web",
        service = service,
        name = name,
        resource = resource,
        trace_id = trace_id,
        span_id = span_id,
        parent_id = parent_id,
        start = start,
        sampling_priority = sampling_priority,
        origin = origin,
        meta = {},
        metrics = {
            ["_sampling_priority_v1"] = sampling_priority,
        }
    }, span_mt)
end


function span_methods:new_child(name, resource, start)
    return new(
    self.service,
    name,
    resource,
    self.trace_id,
    generate_span_id(),
    self.span_id,
    start,
    self.sampling_priority,
    self.origin
    )
end


function span_methods:finish(finish_timestamp)
    assert(self.duration == nil, "span already finished")
    assert(ffi.istype(int64_t, finish_timestamp) and finish_timestamp >= 0, "invalid span finish_timestamp")
    local duration = finish_timestamp - self.start
    assert(duration >= 0, "invalid span duration: " .. tostring(finish_timestamp) .. " < " .. tostring(self.start))
    self.duration = duration
    return true
end


function span_methods:set_tag(key, value)
    -- kong.log.err(fmt("set_tag: '%s': '%s' (%s)", key, value, type(value)))
    assert(type(key) == "string", "invalid tag key")
    if value ~= nil then -- Validate value
        local vt = type(value)
        assert(vt == "string" or vt == "number" or vt == "boolean",
        "invalid tag value (expected string, number, boolean or nil)")
    end
    local meta = self.meta
    if meta then
        meta[key] = tostring(value)
    elseif value ~= nil then
        meta = {
            [key] = tostring(value)
        }
        self.meta = meta
    end
    return true
end


function span_methods:each_tag()
    local tags = self.tags
    if tags == nil then return function() end end
    return next, tags
end


return {
    new = new,
}

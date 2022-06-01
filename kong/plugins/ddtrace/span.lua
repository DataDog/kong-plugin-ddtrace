--[[
The internal data structure is used by Datadog's v0.4 trace api endpoint.
It is encoded in msgpack using the customized encoder.
]]

local ffi = require "ffi"

local utils = require "kong.tools.utils"
local rand_bytes = utils.get_rand_bytes
local byte = string.byte

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
                   start_timestamp, sampling_priority, origin)
    assert(type(name) == "string" and name ~= "", "invalid span name")
    assert(type(resource) == "string" and resource ~= "", "invalid span resource")
    assert(trace_id == nil or ffi.istype(uint64_t, trace_id), "invalid trace id")
    assert(span_id == nil or ffi.istype(uint64_t, span_id), "invalid span id")
    assert(parent_id == nil or ffi.istype(uint64_t, parent_id), "invalid parent id")
    assert(ffi.istype(int64_t, start_timestamp) and start_timestamp >= 0, "invalid span start_timestamp")
    assert(type(sampling_priority) == "number", "invalid sampling priority")

    if trace_id == nil then
        trace_id = generate_span_id()
        span_id = trace_id
        parent_id = uint64_t(0)
    elseif span_id == nil then
        span_id = generate_span_id()
    end

    return setmetatable({
        service = service,
        name = name,
        resource = resource,
        trace_id = trace_id,
        span_id = span_id,
        parent_id = parent_id,
        start_timestamp = start_timestamp,
        sampling_priority = sampling_priority,
        origin = origin,
        meta = {},
    }, span_mt)
end


function span_methods:new_child(name, resource, start_timestamp)
    return new(
    self.service,
    name,
    resource,
    self.trace_id,
    generate_span_id(),
    self.span_id,
    start_timestamp,
    self.sampling_priority,
    self.origin
    )
end


function span_methods:finish(finish_timestamp)
    assert(self.duration == nil, "span already finished")
    assert(ffi.istype(int64_t, finish_timestamp) and finish_timestamp >= 0, "invalid span finish_timestamp")
    local duration = finish_timestamp - self.start_timestamp
    assert(duration >= 0, "invalid span duration: " .. tostring(finish_timestamp) .. " < " .. tostring(self.start_timestamp))
    self.duration = duration
    return true
end


function span_methods:set_tag(key, value)
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

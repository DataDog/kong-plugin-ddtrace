--[[
The internal data structure is used by Datadog's v0.4 trace api endpoint.
It is encoded in msgpack using the customized encoder.
]]

local ffi = require("ffi")

local utils = require("kong.tools.utils")
local dd_utils = require("kong.plugins.ddtrace.utils")
local rand_bytes = utils.get_rand_bytes
local byte = string.byte

local span_methods = {}
local span_mt = {
    __index = span_methods,
}

local uint64_t = ffi.typeof("uint64_t")
local int64_t = ffi.typeof("int64_t")

local function random_64bit()
    local x = rand_bytes(8)
    local b = {
        1ULL * byte(x, 1),
        1ULL * byte(x, 2),
        1ULL * byte(x, 3),
        1ULL * byte(x, 4),
        1ULL * byte(x, 5),
        1ULL * byte(x, 6),
        1ULL * byte(x, 7),
        1ULL * byte(x, 8),
    }
    local id = bit.bor(
        bit.lshift(b[1], 56),
        bit.lshift(b[2], 48),
        bit.lshift(b[3], 40),
        bit.lshift(b[4], 32),
        bit.lshift(b[5], 24),
        bit.lshift(b[6], 16),
        bit.lshift(b[7], 8),
        b[8]
    )
    return id
end

local function legacy_63bit_ids_generator()
    -- NOTE(@dmehala): truncate to 63-bit value for legacy reasons
    return bit.band(random_64bit(), 0x7FFFFFFFFFFFFFFFULL)
end

local function trace_64bit_ids_generator(_)
    return { high = nil, low = legacy_63bit_ids_generator() }
end

local function trace_128bit_ids_generator(now_us)
    local now_s = uint64_t(now_us / 1000000)
    local msb = bit.lshift(now_s, 32)
    return { high = msb, low = random_64bit() }
end

local function new(
    service,
    name,
    resource,
    trace_id,
    span_id,
    parent_id,
    start_us,
    sampling_priority,
    origin,
    generate_128bit_trace_ids,
    root
)
    assert(type(name) == "string" and name ~= "", "invalid span name")
    assert(type(resource) == "string" and resource ~= "", "invalid span resource")
    assert(trace_id == nil or type(trace_id) == "table", "invalid trace id")
    assert(span_id == nil or ffi.istype(uint64_t, span_id), "invalid span id")
    assert(parent_id == nil or ffi.istype(uint64_t, parent_id), "invalid parent id")
    assert(ffi.istype(int64_t, start_us) and start_us >= 0, "invalid span start timestamp")
    assert(sampling_priority == nil or type(sampling_priority) == "number", "invalid sampling priority")
    assert(root == nil or type(root) == "table", "invalid root span")
    assert(type(generate_128bit_trace_ids) == "boolean")

    local trace_id_generator = (generate_128bit_trace_ids and trace_128bit_ids_generator) or trace_64bit_ids_generator

    if trace_id == nil then
        -- a new trace
        trace_id = trace_id_generator(start_us)
        span_id = trace_id.low
        parent_id = uint64_t(0)
    elseif span_id == nil then
        -- a new span for an existing trace
        span_id = legacy_63bit_ids_generator()
    end

    local meta = {
        language = "lua",
    }

    if root == nil and trace_id.high ~= nil then
        meta["_dd.p.tid"] = bit.tohex(trace_id.high)
    end

    return setmetatable({
        type = "web",
        service = service,
        name = name,
        resource = resource,
        trace_id = trace_id,
        span_id = span_id,
        parent_id = parent_id,
        start = start_us,
        sampling_priority = sampling_priority,
        origin = origin,
        meta = meta,
        metrics = {
            ["_sampling_priority_v1"] = sampling_priority,
        },
        error = 0,
        root = root,
        generate_128bit_trace_ids = generate_128bit_trace_ids,
    }, span_mt)
end

function span_methods:set_sampling_priority(sampling_priority)
    self.sampling_priority = sampling_priority
    self.metrics["_sampling_priority_v1"] = sampling_priority
end

function span_methods:set_tags(tags)
    assert(type(tags) == "table")
    for k, v in pairs(tags) do
        self:set_tag(k, v)
    end
end

function span_methods:new_child(name, resource, start)
    return new(
        self.service,
        name,
        resource,
        self.trace_id,
        legacy_63bit_ids_generator(),
        self.span_id,
        start,
        self.sampling_priority,
        self.origin,
        self.generate_128bit_trace_ids,
        self.root or self
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
    assert(type(key) == "string", "invalid tag key")
    if value ~= nil then -- Validate value
        local vt = type(value)
        assert(
            vt == "string" or vt == "number" or vt == "boolean",
            "invalid tag value (expected string, number, boolean or nil)"
        )
        self.meta[key] = tostring(value)
    end
end

function span_methods:set_http_header_tags(header_tags, get_request_header, get_response_header)
    for header_name, tag_entry in pairs(header_tags) do
        local req_header_value = get_request_header(header_name)
        local res_header_value = get_response_header(header_name)

        if req_header_value then
            local tag = (tag_entry.normalized and "http.request.headers." .. tag_entry.value) or tag_entry.value
            self:set_tag(tag, dd_utils.concat(req_header_value, ","))
        end

        if res_header_value then
            local tag = (tag_entry.normalized and "http.response.headers." .. tag_entry.value) or tag_entry.value
            self:set_tag(tag, dd_utils.concat(res_header_value, ","))
        end
    end
end

return {
    new = new,
}

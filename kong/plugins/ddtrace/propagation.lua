-- Propagation methods for Datadog APM: extration and injection of datadog-specific request headers.
--
local ffi = require "ffi"
ffi.cdef[[
unsigned long long int strtoull(const char *nptr, char **endptr, int base);
]]


local function parse_uint64(str)
    if not str then
        return nil, "unable to parse, value is nil"
    end
    ffi.errno(0)
    local parsed_str = ffi.C.strtoull(str, nil, 10)
    local err = ffi.errno()
    if err ~= 0 then
        return nil, "unable to parse '" .. str .. "' as 64-bit number, errno=" .. err
    end
    -- TODO: check the entire string was consumed, instead of partially decoded
    return parsed_str, nil
end

local function extract(headers)
    local trace_id_value = headers["x-datadog-trace-id"]
    if not trace_id_value then
        -- no trace ID, therefore no propagated trace
        return nil, nil, nil, nil, nil
    end
    local trace_id, err = parse_uint64(trace_id_value)
    if err then
        -- tracing was desired but the value wasn't understood
        return nil, nil, nil, nil, err
    end
    -- other headers are expected but aren't provided in all cases
    local parent_id = parse_uint64(headers["x-datadog-parent-id"])
    local sampling_priority = tonumber(headers["x-datadog-sampling-priority"])
    local origin = headers["x-datadog-origin"]
    return trace_id, parent_id, sampling_priority, origin, nil
end

local function inject(span)
    if not span then
        return "unable to inject: nil span"
    end
    if not span.trace_id then
        return "unable to inject: span's trace_id is nil"
    end
    local set_header = kong.service.request.set_header
    -- when concerted to a string, uint64_t values have ULL at the end of the string.
    -- string.sub is used to remove the last 3 characters.
    local trace_id_str = tostring(span.trace_id)
    set_header("x-datadog-trace-id", string.sub(trace_id_str, 1, #trace_id_str - 3))
    local parent_id_str = tostring(span.span_id)
    set_header("x-datadog-parent-id", string.sub(parent_id_str, 1, #parent_id_str - 3))
    if span.sampling_priority then
        set_header("x-datadog-sampling-priority", tostring(span.sampling_priority))
    end
    if span.origin then
        set_header("x-datadog-origin", span.origin)
    end
end

return {
    extract = extract,
    inject = inject,
}



-- Propagation methods for Datadog APM: extraction and injection of datadog-specific request headers.

local ffi = require "ffi"
ffi.cdef[[
unsigned long long int strtoull(const char *nptr, char **endptr, int base);
]]

local function id_to_string(id)
  -- when concerted to a string, uint64_t values have ULL at the end of the string.
  -- string.sub is used to remove the last 3 characters.
  local str_id = tostring(id)
  return string.sub(str_id, 1, #str_id - 3)
end

local function parse_uint64(str, base)
    if not str then
        return nil, "unable to parse, value is nil"
    end
    ffi.errno(0)
    local parsed_str = ffi.C.strtoull(str, nil, base)
    local err = ffi.errno()
    if err ~= 0 then
        return nil, "unable to parse '" .. str .. "' (base " .. base .. ") as 64-bit number, errno=" .. err
    end
    -- TODO: check the entire string was consumed, instead of partially decoded
    return parsed_str, nil
end

local function parse_dd_tags(s)
    local tags = {}

    for k,v in string.gmatch(s, "(_dd%.p%.[%w-._]+)=([%w-._]+)") do
        if k ~= "_dd.p.upstream_services" then
            tags[k] = v
        end
    end

    return tags
end

local function encode_propagation_tags(tags)
  local function startswith(s, pattern)
    return s:sub(1, #pattern) == pattern
  end

  local result = nil
  local first = true

  for k,v in pairs(tags) do
    if startswith(k, "_dd.p.") then
      local tag = k .. "=" .. v
      if first then
        result = tag
        first = false
      else
        result = result .. "," .. tag
      end
    end
  end

  return result
end

local function extract_datadog(get_header, max_header_size)
    local trace_id_value = get_header("x-datadog-trace-id")
    if not trace_id_value then
        -- no trace ID found, therefore create a new span
        return nil, nil, nil, nil, nil, nil, nil
    end
    local trace_id_low, err = parse_uint64(trace_id_value, 10)
    if err then
        -- tracing was desired but the value wasn't understood
        return nil, nil, nil, nil, nil, nil, err
    end

    -- other headers are expected but aren't provided in all cases
    local trace_id = {high=nil, low=trace_id_low}
    local parent_id = parse_uint64(get_header("x-datadog-parent-id"), 10)
    local sampling_priority = tonumber(get_header("x-datadog-sampling-priority"))
    local origin = get_header("x-datadog-origin")
    local dd_tags = {}

    if max_header_size > 0 then
        local dd_tags_value = get_header("x-datadog-tags")
        if dd_tags_value then
            if #dd_tags_value > max_header_size then
              dd_tags["_dd.propagation_error"] = "extract_max_size"
              kong.log.warn("`x-datadog-tags` exceed the limit of " .. max_header_size .. " characters")
            else
              dd_tags = parse_dd_tags(dd_tags_value)
            end
        end
    end

    local tid = dd_tags["_dd.p.tid"]
    if tid then
        if #tid ~= 16 then
            dd_tags["_dd.propagation_error"] = "malformed_tid " .. tid
            dd_tags["_dd.p.tid"] = nil
        else
            local trace_id_high, err = parse_uint64(tid, 16)
            if err then
                dd_tags["_dd.propagation_error"] = "malformed_tid " .. tid
                dd_tags["_dd.p.tid"] = nil
            else
                trace_id.high = trace_id_high
            end
        end
    end

    return trace_id, parent_id, sampling_priority, origin, dd_tags, nil
end

local function inject_datadog(span, set_header, max_header_size)
    if not span then
        return "unable to inject: nil span"
    end
    if not span.trace_id then
        return "unable to inject: span's trace_id is nil"
    end

    set_header("x-datadog-trace-id", id_to_string(span.trace_id))
    set_header("x-datadog-parent-id", id_to_string(span.span_id))

    if span.sampling_priority then
        set_header("x-datadog-sampling-priority", tostring(span.sampling_priority))
    end

    if span.origin then
        set_header("x-datadog-origin", span.origin)
    end

    local root = (span.root ~= nil and span.root) or span
    assert(root ~= nil)

    if root.meta then
        if max_header_size <= 0 then
          root:set_tag("_dd.propagation_error", "disabled")
        else
          local propagation_tags = encode_propagation_tags(root.meta)
          if propagation_tags then
            if #propagation_tags > max_header_size then
              root:set_tag("_dd.propagation_error", "inject_max_size")
              return "`x-datadog-tags` exceed the limit of " .. max_header_size .. " characters"
            end
            set_header("x-datadog-tags", propagation_tags)
          end
        end
    end
end

return {
    extract = extract_datadog,
    inject = inject_datadog,
}




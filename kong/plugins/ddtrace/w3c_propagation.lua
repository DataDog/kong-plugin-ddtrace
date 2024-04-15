local parse_uint64 = require("kong.plugins.ddtrace.utils").parse_uint64
local join_table = require("kong.plugins.ddtrace.utils").join_table
local band = bit.band
local btohex = bit.tohex
local re_match = ngx.re.match

local traceparent_format = "([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})"

local function startswith(s, pattern)
    return s:sub(1, #pattern) == pattern
end

local function parse_datadog_tracestate(tracestate)
    -- TODO:
    --   * support tracestate as an array.
    --   * there's a limit of 32 elements. If limit is reached the right
    --     most will not be processed.
    local result = {}
    local dd_state = string.match(tracestate, "dd=(.*)")
    if not dd_state then
        return result, nil
    end

    for k, v in string.gmatch(dd_state, "([%w-._]+):([%w-._]+)") do
        if k == "s" then
            local sampling, err = tonumber(v)
            if err then
                return result, 'datadog sampling "' .. v .. '" is improperly formatted (' .. err .. ")"
            end
            result["sampling_priority"] = sampling
        elseif k == "o" then
            result["origin"] = v
        elseif k == "p" then
            result["parent_id"] = v
        elseif k == "t.dm" then
            local m, err = re_match(v, "-[0-9]+", "ajo")
            if not m then
                local err_msg = 't.dm "' .. v .. '" is improperly formatted'
                if err then
                    err_msg = err_msg .. "(" .. err .. ")"
                end

                return result, err_msg
            end

            result["_dd.p.dm"] = v
        end
    end

    return result, nil
end

local function extract(get_header, _)
    local traceparent = get_header("traceparent")
    if not traceparent then
        return nil, nil
    end

    if not startswith(traceparent, "00") or #traceparent < 55 then
        return nil, "unsupported traceparent version"
    end

    -- NOTE:
    --   * traceid is 16-byte hex-encoded (128b)
    --   * parentid is 8-byte hex-encoded (64b)
    --   * trace_flags is 8-byte hex-encoded and bit-field
    local m, err = re_match(traceparent, traceparent_format, "ajo")
    if not m then
        local err_msg = 'failed to parse traceparent "' .. traceparent .. '"'
        if err then
            return nil, err_msg .. "(" .. err .. ")"
        end
        return nil, err_msg
    end

    local hex_trace_id, parent_id, trace_flags = table.unpack(m, 2) -- luacheck: ignore 143
    if hex_trace_id == 0 then
        return nil, "0 is invalid trace ID"
    end
    if parent_id == 0 then
        return nil, "0 is an invalid parent ID"
    end

    local trace_id = { high = 0, low = 0 }

    trace_id.high, err = parse_uint64(string.sub(hex_trace_id, 1, 16), 16)
    if err then
        return nil, "failed to parse trace ID: " .. err
    end

    trace_id.low, err = parse_uint64(string.sub(hex_trace_id, 17, 32), 16)
    if err then
        return nil, "failed to parse trace ID: " .. err
    end

    parent_id, err = parse_uint64(parent_id, 16)
    if err then
        return nil, "failed to parse parent ID: " .. err
    end

    trace_flags, err = parse_uint64(trace_flags, 16)
    if err then
        return nil, "could not parse trace flags: " .. err
    end

    -- tracestate
    local dd_state = {}
    local dd_tags = {}
    local tracestate = get_header("tracestate")
    if tracestate then
        dd_state, err = parse_datadog_tracestate(tracestate)
        if err then
            kong.log.warn("failed to extract datadog tracestate: " .. err)
        end
    end

    dd_tags["_dd.p.dm"] = dd_state["_dd.p.dm"]

    local sampling_priority = 0 -- luacheck: ignore 311
    local is_sampled = band(trace_flags, 0x01) > 0

    local extracted_sampling = dd_state.sampling_priority
    if is_sampled then
        if not extracted_sampling or extracted_sampling <= 0 then
            sampling_priority = 1
            dd_tags["_dd.p.dm"] = "-0" --< DEFAULT
        else
            sampling_priority = extracted_sampling
        end
    else
        if not extracted_sampling or extracted_sampling > 0 then
            sampling_priority = 0
        else
            sampling_priority = extracted_sampling
        end
    end

    return {
        trace_id = trace_id,
        parent_id = parent_id,
        sampling_priority = sampling_priority,
        origin = dd_state["origin"],
        tags = dd_tags,
    },
        nil
end

local function inject(span, request, _)
    local get_header = request.get_header
    local set_header = request.set_header

    local trace_id = btohex(span.trace_id.high or 0, 16) .. btohex(span.trace_id.low, 16)
    local parent_id = btohex(span.span_id, 16)
    local trace_flags = "00"
    if span.sampling_priority > 0 then
        trace_flags = "01"
    end

    local states = {}
    if span.sampling_priority then
        table.insert(states, "s:" .. span.sampling_priority)
    end
    if span.origin then
        table.insert(states, "o:" .. span.origin)
    end

    local root = (span.root ~= nil and span.root) or span
    assert(root ~= nil)

    if root.meta then
        for k, v in pairs(root.meta) do
            local propagation_key = string.match(k, "_dd%.p%.(.*)")
            if propagation_key then
                table.insert(states, "t." .. propagation_key .. ":" .. v)
            end
        end
    end

    -- NOTE: not ideal to always rebuild the dd state as it is not forward compatible
    -- but I plan to use `dd-trace-cpp` soon, which should fix that issue.
    local dd_state = "dd=" .. join_table(";", states)

    local tracestate = get_header("tracestate") or ""
    tracestate = string.gsub(tracestate, ",?dd=[%w-._:;]+", "")
    if #tracestate > 0 then
        tracestate = dd_state .. "," .. tracestate
    else
        tracestate = dd_state
    end

    local traceparent = string.format("00-%s-%s-%s", trace_id, parent_id, trace_flags)
    assert(#traceparent == 55)
    set_header("traceparent", traceparent)
    set_header("tracestate", tracestate)
end

return {
    extract = extract,
    inject = inject,
}

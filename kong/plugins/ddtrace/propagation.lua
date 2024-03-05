local datadog = require "kong.plugins.ddtrace.datadog_propagation"
local new_span = require "kong.plugins.ddtrace.span".new

local function extract_or_create_span(request, span_options, max_header_size)
    local trace_id, parent_id, sampling_priority, origin, propagation_tags, err = datadog.extract(request.get_header, max_header_size)
    local span = new_span(span_options.service, span_options.name, span_options.resource, trace_id, nil, parent_id, span_options.start_us, sampling_priority, origin, nil)
    if propagation_tags then
        span:set_tags(propagation_tags)
    end
    if err then
        span:set_tag("ddtrace.propagation_error", err)
    end

    return span
end

return {
    extract_or_create_span = extract_or_create_span,
    inject = datadog.inject,
}


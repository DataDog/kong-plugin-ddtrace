local datadog = require("kong.plugins.ddtrace.datadog_propagation")
local w3c = require("kong.plugins.ddtrace.w3c_propagation")
local new_span = require("kong.plugins.ddtrace.span").new

local extractors = {
    datadog = datadog.extract,
    tracecontext = w3c.extract,
}

local injectors = {
    datadog = datadog.inject,
    tracecontext = w3c.inject,
}

local propagator = {}
local propagator_mt = {
    __index = propagator,
}

local function new(extraction_styles, injection_styles, max_header_size)
    assert(extraction_styles ~= nil or type(extraction_styles) == "table")
    assert(injection_styles ~= nil or type(injection_styles) == "table")

    return setmetatable({
        extraction_styles = extraction_styles,
        injection_styles = injection_styles,
        max_header_size = max_header_size,
    }, propagator_mt)
end

function propagator:extract_or_create_span(request, span_options)
    local err
    local trace_context

    local get_header = request.get_header

    for i = 1, #self.extraction_styles do
        local style = self.extraction_styles[i]
        local extractor = extractors[style]
        local extracted
        extracted, err = extractor(get_header, self.max_header_size)
        if extracted then
            if not trace_context then
                trace_context = extracted
            elseif trace_context.trace_id ~= extracted.trace_id then
                -- TODO: add span links
                local msg = "The extracted trace ID, obtained using "
                    .. style
                    .. " style, does not match the local trace ID"
                kong.log.warn(msg)
            end
        end
    end

    local trace_id = trace_context and trace_context.trace_id
    local parent_id = trace_context and trace_context.parent_id
    local sampling_priority = trace_context and trace_context.sampling_priority
    local origin = trace_context and trace_context.origin

    local span = new_span(
        span_options.service,
        span_options.name,
        span_options.resource,
        trace_id,
        nil,
        parent_id,
        span_options.start_us,
        sampling_priority,
        origin,
        span_options.generate_128bit_trace_ids,
        nil
    )
    if trace_context and trace_context.propagation_tags then
        span:set_tags(trace_context.propagation_tags)
    end

    if err then
        kong.log.warn("Propagation error: " .. err)
    end

    return span
end

function propagator:inject(request, span)
    -- TODO: handle error
    for i = 1, #self.extraction_styles do
        local style = self.extraction_styles[i]
        local injector = injectors[style]
        local err = injector(span, request, self.max_header_size)
        if err then
            kong.log.err("An error occurred while injecting a span (id: " .. span.span_id .. "). Reason: " .. err)
        end
    end
end

return {
    new = new,
}

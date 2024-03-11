local propagator = require("kong.plugins.ddtrace.propagation")

_G.kong = {
    log = {
        warn = function(s) end,
    },
}

local default_span_opts = {
    service = "kong",
    name = "kong.handle",
    start_us = 1708943277 * 1000000LL,
    resource = "default_resource",
    generate_128bit_trace_ids = true,
}

local default_max_header_size = 512

describe("trace propagation", function()
    describe("extraction", function()
        it("empty headers generates a new span", function()
            local request = { get_header = function(s) end }
            local span = propagator.extract_or_create_span(request, default_span_opts, default_max_header_size)

            assert.is_not_nil(span)
            assert.is_nil(span.meta["ddtrace.propagation_error"])
        end)
    end)

    describe("injection", function()
        pending("Until another propagation mechanism is implemented")
    end)
end)

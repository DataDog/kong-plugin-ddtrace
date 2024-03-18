local new_span = require("kong.plugins.ddtrace.span").new
local new_propagator = require("kong.plugins.ddtrace.propagation").new

_G.kong = {
    log = {
        warn = function(s) end,
    },
}

local function make_getter(headers)
    local function getter(header)
        return headers[header]
    end

    return getter
end

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
            local styles = { "datadog", "tracecontext" }
            local propagator = new_propagator(styles, styles)
            local request = { get_header = function(s) end }
            local span = propagator:extract_or_create_span(request, default_span_opts, default_max_header_size)

            assert.is_not_nil(span)
            -- assert.is_nil(span.meta["ddtrace.propagation_error"])
        end)

        it("respect style", function()
            local datadog_propagator = new_propagator({ "datadog" }, { "datadog" })
            local request = {
                get_header = make_getter({
                    traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                    tracestate = "fizz=buzz:fizzbuzz,dd=s:2;o:rum;p:00f067aa0ba902b7;t.dm:-5",
                }),
            }

            local span = datadog_propagator:extract_or_create_span(request, default_span_opts, default_max_header_size)
            local expected_trace_id = { high = 0x4bf92f3577b34da6ULL, low = 0xa3ce929d0e0e4736ULL }
            local expected_parent_id = 0x00f067aa0ba902b7ULL
            assert.are_not.same(expected_trace_id, span.trace_id)
            assert.are_not.same(expected_parent_id, span.parent_id)

            local tracecontext_propagator = new_propagator({ "tracecontext" }, { "tracecontext" })
            local extracted_span =
                tracecontext_propagator:extract_or_create_span(request, default_span_opts, default_max_header_size)
            assert.same(expected_trace_id, extracted_span.trace_id)
            assert.same(expected_parent_id, extracted_span.parent_id)
        end)

        it("extraction style order is respected", function()
            -- NOTE: datadog and tracecontext header do not match -> datadog propagation must be use
            local datadog_first = { "datadog", "tracecontext" }
            local multi_propagator = new_propagator(datadog_first, datadog_first)
            local request = {
                get_header = make_getter({
                    traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                    tracestate = "fizz=buzz:fizzbuzz,dd=s:2;o:rum;p:00f067aa0ba902b7;t.dm:-5",
                    ["x-datadog-trace-id"] = "12345678901234567890",
                    ["x-datadog-parent-id"] = "9876543210987654321",
                }),
            }

            local span = multi_propagator:extract_or_create_span(request, default_span_opts, default_max_header_size)

            local expected_trace_id = { high = nil, low = 12345678901234567890ULL }
            local expected_parent_id = 9876543210987654321ULL
            assert.same(expected_trace_id, span.trace_id)
            assert.same(expected_parent_id, span.parent_id)
        end)
    end)

    describe("inject", function()
        local headers = {}
        local request = {
            get_header = function(k)
                return nil
            end,
            set_header = function(key, value)
                headers[key] = value
            end,
        }

        it("multiple styles", function()
            local all_styles = { "datadog", "tracecontext" }
            local multi_propagator = new_propagator(all_styles, all_styles)

            local span = new_span(
                default_span_opts.service,
                default_span_opts.name,
                default_span_opts.resource,
                nil,
                nil,
                nil,
                default_span_opts.start_us,
                1,
                "test-origin",
                default_span_opts.generate_128bit_trace_ids,
                nil
            )

            multi_propagator:inject(request, span, default_max_header_size)

            assert.is_string(headers["traceparent"])
            assert.is_string(headers["tracestate"])
            assert.is_string(headers["x-datadog-trace-id"])
            assert.is_string(headers["x-datadog-parent-id"])
        end)
    end)
end)

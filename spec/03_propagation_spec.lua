local propagator = require "kong.plugins.ddtrace.propagation"
local new_span = require "kong.plugins.ddtrace.span".new

describe("trace propagation", function()
    it("extracts an existing trace", function()
        local headers = {
            ["x-datadog-trace-id"] = "12345678901234567890",
            ["x-datadog-parent-id"] = "9876543210987654321",
            ["x-datadog-sampling-priority"] = "1",
            ["x-datadog-origin"] = "test-origin",
        }
        local trace_id, parent_id, sampling_priority, origin, err = propagator.extract(headers)
        assert.is_nil(err)
        assert.equal(trace_id, 12345678901234567890ULL)
        assert.equal(parent_id, 9876543210987654321ULL)
        assert.equal(sampling_priority, 1)
        assert.same(origin, "test-origin")
    end)
    it("injects the trace into headers", function()
        -- add kong.service.request.set_header method
        local headers = {}
        local headers_set = 0
        local set_header = function(key, value)
            headers[key] = value
            headers_set = headers_set + 1
        end
        _G.kong = {
            service = {
                request = {
                    set_header = set_header,
                },
            },
        }
        local start_time = 1700000000000000000LL
        local duration = 100000000LL
        local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil)
        propagator.inject(span)
        span:finish(start_time + duration)
        assert.equal(headers_set, 2)
        assert.is_string(headers["x-datadog-trace-id"])
        assert.is_string(headers["x-datadog-parent-id"])
    end)
end)

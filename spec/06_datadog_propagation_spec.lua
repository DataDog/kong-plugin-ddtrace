local extract_datadog = require("kong.plugins.ddtrace.datadog_propagation").extract
local inject_datadog = require("kong.plugins.ddtrace.datadog_propagation").inject
local new_span = require("kong.plugins.ddtrace.span").new

local function make_getter(headers)
    local function getter(header)
        return headers[header]
    end

    return getter
end

local function id_to_string(id)
    -- when concerted to a string, uint64_t values have ULL at the end of the string.
    -- string.sub is used to remove the last 3 characters.
    local str_id = tostring(id)
    return string.sub(str_id, 1, #str_id - 3)
end

_G.kong = {
    log = {
        warn = function(s) end,
    },
}

local function string_contains(input, pattern)
    return string.find(input, pattern, 1, true) ~= nil
end

describe("trace propagation", function()
    describe("extraction", function()
        it("extracts an existing trace", function()
            local headers = {
                ["x-datadog-trace-id"] = "12345678901234567890",
                ["x-datadog-parent-id"] = "9876543210987654321",
                ["x-datadog-sampling-priority"] = "1",
                ["x-datadog-origin"] = "test-origin",
                ["x-datadog-tags"] = "_dd.p.dm=-4",
            }

            local get_header = make_getter(headers)

            local extracted, err = extract_datadog(get_header, 512)
            assert.is_nil(err)
            assert.is_not_nil(extracted)

            local expected_trace_id = { high = nil, low = 12345678901234567890ULL }
            assert.same(expected_trace_id, extracted.trace_id)
            assert.equal(9876543210987654321ULL, extracted.parent_id)
            assert.equal(1, extracted.sampling_priority)
            assert.same("test-origin", extracted.origin)

            local expected_tags = {
                ["_dd.p.dm"] = "-4",
            }

            assert.same(expected_tags, extracted.tags)
        end)
        it("extracts 128bit trace", function()
            local headers = {
                ["x-datadog-trace-id"] = "12345678901234567890",
                ["x-datadog-parent-id"] = "9876543210987654321",
                ["x-datadog-sampling-priority"] = "1",
                ["x-datadog-origin"] = "test-origin",
                ["x-datadog-tags"] = "_dd.p.tid=cbae7cb600000000,_dd.p.dm=-0",
            }
            local get_header = make_getter(headers)

            local extracted, err = extract_datadog(get_header, 512)
            assert.is_nil(err)

            local expected_trace_id = { high = 14676805356772917248ULL, low = 12345678901234567890ULL }
            assert.same(extracted.trace_id, expected_trace_id)
            assert.equal(extracted.parent_id, 9876543210987654321ULL)
            assert.equal(extracted.sampling_priority, 1)
            assert.same(extracted.origin, "test-origin")
            assert.equal("cbae7cb600000000", extracted.tags["_dd.p.tid"])
            assert.equal("-0", extracted.tags["_dd.p.dm"])
        end)

        describe("datadog tags extraction", function()
            local base_headers = {
                ["x-datadog-trace-id"] = "12345678901234567890",
                ["x-datadog-parent-id"] = "9876543210987654321",
                ["x-datadog-sampling-priority"] = "1",
                ["x-datadog-origin"] = "test-origin",
                ["x-datadog-tags"] = "_dd.p.dm=-4",
            }

            it("format not respected", function()
                pending("not implemented yet. the parser do not return a decoded error.")
                local headers = base_headers
                headers["x-datadog-tags"] = "foo,bar"

                local expected_tags = {
                    ["_dd.propagation_error"] = "decoding_error",
                }

                local get_header = make_getter(headers)

                local extracted, err = extract_datadog(get_header, 512)
                assert.is_nil(err)
                assert.same(expected_tags, extracted.tags)
            end)

            it("only certains tags are extracted", function()
                local headers = base_headers
                headers["x-datadog-tags"] =
                    "traceparent=97382,_dd.p.dm=-1,_dd.p.upstream_services=foo,_dd.p.team=apm-proxy"

                local expected_tags = {
                    ["_dd.p.dm"] = "-1",
                    ["_dd.p.team"] = "apm-proxy",
                }

                local get_header = make_getter(headers)
                local extracted, err = extract_datadog(get_header, 512)
                assert.is_nil(err)
                assert.same(expected_tags, extracted.tags)
            end)

            describe("maximum header size", function()
                local headers = base_headers
                headers["x-datadog-tags"] = "_dd.p.dm=-2"

                local get_header = make_getter(headers)
                it("is zero", function()
                    local max_header_size = 0
                    local extracted, err = extract_datadog(get_header, max_header_size)
                    assert.is_nil(err)
                    assert.equal(0, #extracted.tags)
                end)

                it("reached", function()
                    local expected_tags = {
                        ["_dd.propagation_error"] = "extract_max_size",
                    }

                    local max_header_size = 1
                    local extracted, err = extract_datadog(get_header, max_header_size)
                    assert.is_nil(err)
                    assert.same(expected_tags, extracted.tags)
                end)
            end)
        end)
    end)

    describe("injection", function()
        local headers = {}
        local request = {
            get_header = function(header)
                return nil
            end,
            set_header = function(key, value)
                headers[key] = value
            end,
        }
        it("injects the trace into headers", function()
            local start_time = 1700000000000000000LL
            local duration = 100000000LL
            local span =
                new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, false, nil)
            inject_datadog(span, request, 512)
            span:finish(start_time + duration)
            assert.equal(id_to_string(span.trace_id.low), headers["x-datadog-trace-id"])
            assert.equal(id_to_string(span.span_id), headers["x-datadog-parent-id"])
        end)
        it("injects 128 bit trace id", function()
            local start_time = 1700000000000000000LL
            local duration = 100000000LL
            local span =
                new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, true, nil)
            inject_datadog(span, request, 512)
            span:finish(start_time + duration)
            assert.equal(id_to_string(span.trace_id.low), headers["x-datadog-trace-id"])
            assert.equal(id_to_string(span.span_id), headers["x-datadog-parent-id"])
            assert.is_string(headers["x-datadog-tags"])
            assert.equal(headers["x-datadog-tags"], "_dd.p.tid=" .. bit.tohex(span.trace_id.high))
        end)

        describe("datadog tags injection", function()
            -- reset `headers`
            headers = {}
            local start_time = 1700000000000000000LL

            describe("maximum header size", function()
                it("is zero", function()
                    local propagation_tags = {
                        ["_dd.p.dm"] = "-3",
                    }

                    local max_header_size = 0
                    local span = new_span(
                        "test_service",
                        "test_name",
                        "test_resource",
                        nil,
                        nil,
                        nil,
                        start_time,
                        nil,
                        nil,
                        false,
                        nil
                    )
                    span:set_tags(propagation_tags)
                    inject_datadog(span, request, max_header_size)

                    assert.is_nil(headers["x-datadog-tags"])
                    assert.equal(span.meta["_dd.propagation_error"], "disabled")
                end)

                it("reached", function()
                    local propagation_tags = {
                        ["_dd.p.dm"] = "-0",
                    }

                    local max_header_size = 1
                    local span = new_span(
                        "test_service",
                        "test_name",
                        "test_resource",
                        nil,
                        nil,
                        nil,
                        start_time,
                        nil,
                        nil,
                        false,
                        nil
                    )
                    span:set_tags(propagation_tags)
                    inject_datadog(span, request, max_header_size)

                    assert.is_nil(headers["x-datadog-tags"])

                    assert.equal("inject_max_size", span.meta["_dd.propagation_error"])
                end)
            end)

            it("empty propagation tags", function()
                local span = new_span(
                    "test_service",
                    "test_name",
                    "test_resource",
                    nil,
                    nil,
                    nil,
                    start_time,
                    nil,
                    nil,
                    false,
                    nil
                )
                inject_datadog(span, request, 512)

                assert.is_nil(headers["x-datadog-tags"])
            end)

            it("correctly encode valid propagation tags", function()
                local propagation_tags = {
                    ["_dd.p.dm"] = "-1",
                    ["_dd.p.hello"] = "world",
                }

                local span = new_span(
                    "test_service",
                    "test_name",
                    "test_resource",
                    nil,
                    nil,
                    nil,
                    start_time,
                    nil,
                    nil,
                    false,
                    nil
                )
                span:set_tags(propagation_tags)
                inject_datadog(span, request, 512)

                assert.is_not_nil(headers["x-datadog-tags"])

                -- NOTE: can't assure tag's order in `x-datadog-tags`
                assert.is_true(string_contains(headers["x-datadog-tags"], "_dd.p.dm=-1"))
                assert.is_true(string_contains(headers["x-datadog-tags"], "_dd.p.hello=world"))
            end)

            it("child span", function()
                local propagation_tags = {
                    ["_dd.p.dm"] = "-2",
                    ["_dd.p.hello"] = "mars",
                }

                local span = new_span(
                    "test_service",
                    "test_name",
                    "test_resource",
                    nil,
                    nil,
                    nil,
                    start_time,
                    nil,
                    nil,
                    false,
                    nil
                )
                span:set_tags(propagation_tags)

                local child_start = start_time + 10
                local child_span = span:new_child("child_span", "test_child_resource", child_start)

                inject_datadog(child_span, request, 512)
                assert.is_not_nil(headers["x-datadog-tags"])

                -- NOTE: can't assure tag's order in `x-datadog-tags`
                assert.is_true(string_contains(headers["x-datadog-tags"], "_dd.p.dm=-2"))
                assert.is_true(string_contains(headers["x-datadog-tags"], "_dd.p.hello=mars"))
            end)

            it("sampling decision is propagated", function()
                local new_sampler = require("kong.plugins.ddtrace.sampler").new
                local sampler = new_sampler(10, nil)
                local span = new_span(
                    "test_service",
                    "test_name",
                    "test_resource",
                    nil,
                    nil,
                    nil,
                    start_time,
                    nil,
                    nil,
                    false,
                    nil
                )

                local ok = sampler:sample(span)
                assert.is_true(ok)

                inject_datadog(span, request, 512)

                assert.is_not_nil(headers["x-datadog-tags"])
                assert.is_true(string_contains(headers["x-datadog-tags"], "_dd.p.dm=-0"))
            end)
        end)
    end)

    -- TODO: extract -> inject -> ==?
    describe("round-trip", function()
        local expected_headers = {
            ["x-datadog-trace-id"] = "12345678901234567890",
            ["x-datadog-sampling-priority"] = "5",
            ["x-datadog-origin"] = "test-round-trip-origin",
            ["x-datadog-tags"] = "_dd.p.tid=cbae7cb600000000,_dd.p.dm=-3",
        }

        -- NOTE: `parent-id` will differ because the injected span will
        -- generate a new span id.
        local in_headers = expected_headers
        in_headers["x-datadog-parent-id"] = "9876543210987654321"
        local out_headers = {}
        local request = {
            get_header = make_getter(in_headers),
            set_header = function(key, value)
                out_headers[key] = value
            end,
        }

        local extracted, err = extract_datadog(request.get_header, 512)
        assert.is_not_nil(extracted)

        local start_us = 1711027189 * 100000000LL
        local span = new_span(
            "kong-test",
            "round-trip",
            "resource",
            extracted.trace_id,
            nil,
            extracted.parent_id,
            start_us,
            extracted.sampling_priority,
            extracted.origin,
            true,
            nil
        )
        assert.is_not_nil(span)
        span:set_tags(extracted.tags)

        inject_datadog(span, request, 512)

        assert.same(expected_headers["x-datadog-trace-id"], out_headers["x-datadog-trace-id"])
        assert.same(expected_headers["x-datadog-sampling-priority"], out_headers["x-datadog-sampling-priority"])
        assert.same(expected_headers["x-datadog-origin"], out_headers["x-datadog-origin"])
        assert.is_true(string_contains(out_headers["x-datadog-tags"], "_dd.p.dm=-3"))
        assert.is_true(string_contains(out_headers["x-datadog-tags"], "_dd.p.tid=cbae7cb600000000"))
    end)
end)

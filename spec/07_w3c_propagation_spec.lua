local extract_w3c = require("kong.plugins.ddtrace.w3c_propagation").extract
local inject_w3c = require("kong.plugins.ddtrace.w3c_propagation").inject
local new_span = require("kong.plugins.ddtrace.span").new
local bhex = bit.tohex

local function make_getter(headers)
    local function getter(header)
        return headers[header]
    end

    return getter
end

local unused_max_header_size = 255

describe("extract w3c", function()
    it("no w3c headers", function()
        local get_header = make_getter({})
        local extracted, err = extract_w3c(get_header, get_header)
        assert.is_nil(err)
        assert.is_nil(extracted)
    end)

    describe("traceparent", function()
        it("ill-formated", function()
            -- TODO: use fuzzy
            local get_header = make_getter({
                traceparent = "no-good-format",
            })

            local extracted, err = extract_w3c(get_header, get_header)
            assert.is_nil(extracted)
            assert.is_not_nil(err)
        end)

        it("unsupported version", function()
            local get_header = make_getter({
                traceparent = "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
            })

            local extracted, err = extract_w3c(get_header, get_header)
            assert.is_nil(extracted)
            assert.is_not_nil(err)
        end)

        it("valid", function()
            local get_header = make_getter({
                traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
            })

            local extracted, err = extract_w3c(get_header, unused_max_header_size)
            assert.is_nil(err)

            local expected = {
                trace_id = { high = 0x4bf92f3577b34da6ULL, low = 0xa3ce929d0e0e4736ULL },
                parent_id = 0x00f067aa0ba902b7ULL,
                tags = { ["_dd.p.dm"] = "-0" },
                sampling_priority = 1,
            }
            assert.same(expected, extracted)
        end)
    end)

    describe("tracestate", function()
        describe("extract valid datadog state", function()
            local get_header = make_getter({
                traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                tracestate = "fizz=buzz:fizzbuzz,dd=s:2;o:rum;p:00f067aa0ba902b7;t.dm:-5",
            })
            local extracted, err = extract_w3c(get_header, unused_max_header_size)
            assert.is_nil(err)

            local expected = {
                trace_id = { high = 0x4bf92f3577b34da6ULL, low = 0xa3ce929d0e0e4736ULL },
                parent_id = 0x00f067aa0ba902b7ULL,
                origin = "rum",
                tags = { ["_dd.p.dm"] = "-5" },
                sampling_priority = 2,
            }
            assert.same(expected, extracted)
        end)
        describe("sampling priority logic", function()
            describe("trace is sampled", function()
                it("extracted datadog sampling_priority is >0 -> use it", function()
                    local get_header = make_getter({
                        traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                        tracestate = "bar=over:dd,dd=s:2",
                    })
                    local extracted, err = extract_w3c(get_header, unused_max_header_size)
                    assert.is_nil(err)

                    local expected = {
                        trace_id = { high = 0x4bf92f3577b34da6ULL, low = 0xa3ce929d0e0e4736ULL },
                        parent_id = 0x00f067aa0ba902b7ULL,
                        tags = {},
                        sampling_priority = 2,
                    }
                    assert.same(expected, extracted)
                end)
                it("datadog sampling_priority is absent -> keep", function()
                    local get_header = make_getter({
                        traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                        tracestate = "bar=over:dd",
                    })
                    local extracted, err = extract_w3c(get_header, unused_max_header_size)
                    assert.is_nil(err)

                    local expected = {
                        trace_id = { high = 0x4bf92f3577b34da6ULL, low = 0xa3ce929d0e0e4736ULL },
                        parent_id = 0x00f067aa0ba902b7ULL,
                        tags = { ["_dd.p.dm"] = "-0" },
                        sampling_priority = 1,
                    }
                    assert.same(expected, extracted)
                end)
                it("extracted datadog sampling_priority is <= 0 -> keep", function()
                    local get_header = make_getter({
                        traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                        tracestate = "dd=s:-5;bar=over:dd",
                    })
                    local extracted, err = extract_w3c(get_header, unused_max_header_size)
                    assert.is_nil(err)

                    local expected = {
                        trace_id = { high = 0x4bf92f3577b34da6ULL, low = 0xa3ce929d0e0e4736ULL },
                        parent_id = 0x00f067aa0ba902b7ULL,
                        tags = { ["_dd.p.dm"] = "-0" },
                        sampling_priority = 1,
                    }
                    assert.same(expected, extracted)
                end)
            end)
            describe("trace is not sampled", function()
                it("extracted datadog sampling_priority is >0 -> drop", function()
                    local get_header = make_getter({
                        traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00",
                        tracestate = "bar=over:dd,dd=s:3",
                    })
                    local extracted, err = extract_w3c(get_header, unused_max_header_size)
                    assert.is_nil(err)

                    local expected = {
                        trace_id = { high = 0x4bf92f3577b34da6ULL, low = 0xa3ce929d0e0e4736ULL },
                        parent_id = 0x00f067aa0ba902b7ULL,
                        tags = {},
                        sampling_priority = 0,
                    }
                    assert.same(expected, extracted)
                end)
                it("datadog sampling_priority is absent -> drop", function()
                    local get_header = make_getter({
                        traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00",
                        tracestate = "dd=foo:bar,vendor=cake:lie",
                    })
                    local extracted, err = extract_w3c(get_header, unused_max_header_size)
                    assert.is_nil(err)

                    local expected = {
                        trace_id = { high = 0x4bf92f3577b34da6ULL, low = 0xa3ce929d0e0e4736ULL },
                        parent_id = 0x00f067aa0ba902b7ULL,
                        tags = {},
                        sampling_priority = 0,
                    }
                    assert.same(expected, extracted)
                end)
                it("extracted datadog sampling_priority is <= 0 -> use it", function()
                    local get_header = make_getter({
                        traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00",
                        tracestate = "dd=s:-2;foo:bar,vendor=cake:lie",
                    })
                    local extracted, err = extract_w3c(get_header, unused_max_header_size)
                    assert.is_nil(err)

                    local expected = {
                        trace_id = { high = 0x4bf92f3577b34da6ULL, low = 0xa3ce929d0e0e4736ULL },
                        parent_id = 0x00f067aa0ba902b7ULL,
                        tags = {},
                        sampling_priority = -2,
                    }
                    assert.same(expected, extracted)
                end)
            end)
        end)
    end)
end)

describe("w3c inject", function()
    local headers = {}
    local request = {
        get_header = function(header)
            return nil
        end,
        set_header = function(key, value)
            headers[key] = value
        end,
    }
    local start_us = 1711119544 * 100000000LL
    it("64-bit trace ID", function()
        local span = new_span(
            "kong-test",
            "w3c-injection-64b-trace-id",
            "injection-resource",
            nil,
            nil,
            nil,
            start_us,
            2,
            "kong",
            false,
            nil
        )

        inject_w3c(span, request, 512)

        local expected_traceparent =
            string.format("00-0000000000000000%s-%s-01", bhex(span.trace_id.low), bhex(span.span_id))
        assert.equal(55, #headers["traceparent"])
        assert.equal(expected_traceparent, headers["traceparent"])
        assert.equal("dd=s:2;o:kong", headers["tracestate"])
    end)

    it("128-bit trace ID", function()
        local span = new_span(
            "kong-test",
            "w3c-injection-128b-trace-id",
            "injection-resource",
            nil,
            nil,
            nil,
            start_us,
            2,
            "kong",
            true,
            nil
        )

        inject_w3c(span, request, 512)

        local expected_traceparent =
            string.format("00-%s%s-%s-01", bhex(span.trace_id.high), bhex(span.trace_id.low), bhex(span.span_id))
        local expected_tracestate = string.format("dd=s:2;o:kong;t.tid:%s", bhex(span.trace_id.high))
        assert.equal(55, #headers["traceparent"])
        assert.equal(expected_traceparent, headers["traceparent"])
        assert.equal(expected_tracestate, headers["tracestate"])
    end)
end)

describe("w3c propagation round trip", function()
    it("dd state is first in tracestate", function()
        local out_headers = {}
        local request = {
            get_header = make_getter({
                traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                tracestate = "dd=s:2;o:rum;t.tid:4bf92f3577b34da6",
            }),
            set_header = function(key, value)
                out_headers[key] = value
            end,
        }

        local extracted, err = extract_w3c(request.get_header, unused_max_header_size)
        assert.is_not_nil(extracted)
        assert.is_nil(err)

        local start_us = 1711027573 * 100000000LL
        local span = new_span(
            "w3c-test",
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

        inject_w3c(span, request, 512)

        local expected_traceparent = string.format("00-4bf92f3577b34da6a3ce929d0e0e4736-%s-01", bhex(span.span_id))
        local expected_tracestate = "dd=s:2;o:rum;t.tid:4bf92f3577b34da6"

        assert.equal(expected_traceparent, out_headers["traceparent"])
        assert.equal(expected_tracestate, out_headers["tracestate"])
    end)

    it("dd state between vendors -> set dd state first", function()
        local out_headers = {}
        local request = {
            get_header = make_getter({
                traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                tracestate = "vendor=k1:v1;k2:v2,dd=s:2;o:rum;t.tid:4bf92f3577b34da6,vendor2=k1:v1;k2:v2",
            }),
            set_header = function(key, value)
                out_headers[key] = value
            end,
        }

        local extracted, err = extract_w3c(request.get_header, unused_max_header_size)
        assert.is_nil(err)
        assert.is_not_nil(extracted)

        local start_us = 1711027573 * 100000000LL
        local span = new_span(
            "w3c-test",
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

        inject_w3c(span, request, 512)

        local expected_traceparent = string.format("00-4bf92f3577b34da6a3ce929d0e0e4736-%s-01", bhex(span.span_id))
        local expected_tracestate = "dd=s:2;o:rum;t.tid:4bf92f3577b34da6,vendor=k1:v1;k2:v2,vendor2=k1:v1;k2:v2"
        assert.equal(expected_traceparent, out_headers["traceparent"])
        assert.equal(expected_tracestate, out_headers["tracestate"])
    end)

    it("dd state is at the end -> set dd state first", function()
        local out_headers = {}
        local request = {
            get_header = make_getter({
                traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                tracestate = "vendor=k1:v1;k2:v2,dd=s:2;o:rum;t.tid:4bf92f3577b34da6",
            }),
            set_header = function(key, value)
                out_headers[key] = value
            end,
        }

        local extracted, err = extract_w3c(request.get_header, unused_max_header_size)
        assert.is_nil(err)
        assert.is_not_nil(extracted)

        local start_us = 1711027573 * 100000000LL
        local span = new_span(
            "w3c-test",
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

        inject_w3c(span, request, 512)

        local expected_traceparent = string.format("00-4bf92f3577b34da6a3ce929d0e0e4736-%s-01", bhex(span.span_id))
        local expected_tracestate = "dd=s:2;o:rum;t.tid:4bf92f3577b34da6,vendor=k1:v1;k2:v2"
        assert.equal(expected_traceparent, out_headers["traceparent"])
        assert.equal(expected_tracestate, out_headers["tracestate"])
    end)
end)

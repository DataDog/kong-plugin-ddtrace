local new_span = require("kong.plugins.ddtrace.span").new

describe("span", function()
    local start_time = 1700000000000000000LL
    local duration = 100000000LL
    it("starts a new span", function()
        -- new span without trace id, parent, span id, or sampling priority
        local span =
            new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, false, nil)
        span:finish(start_time + duration)
        assert.same(span.service, "test_service")
        assert.same(span.name, "test_name")
        assert.same(span.resource, "test_resource")
        assert.same(span.trace_id.high, nil)
        assert.is_not.equal(span.trace_id.low, nil)
        assert.is_not.equal(span.span_id, nil)
        assert.equal(span.start, start_time)
        assert.equal(span.duration, duration)
    end)
    it("starts a new span for an existing trace", function()
        local trace_id = { high = nil, 12345678901234567890ULL }
        local parent_id = 9876543210987654321ULL
        local span = new_span(
            "test_service",
            "test_name",
            "test_resource",
            trace_id,
            nil,
            parent_id,
            start_time,
            nil,
            nil,
            false,
            nil
        )
        span:finish(start_time + duration)
        assert.same(span.service, "test_service")
        assert.same(span.name, "test_name")
        assert.same(span.resource, "test_resource")
        assert.equal(span.trace_id, trace_id)
        assert.equal(span.parent_id, parent_id)
        assert.is_not.equal(span.span_id, nil)
        assert.equal(span.start, start_time)
        assert.equal(span.duration, duration)
    end)
    it("starts a child span", function()
        -- new span without trace id, parent, span id, or sampling priority
        local span =
            new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, false, nil)
        local child_start_time = start_time + 50000000LL
        local child_duration = 20000000LL
        local child_span = span:new_child("child_name", "child_resource", child_start_time)
        child_span:finish(child_start_time + child_duration)
        span:finish(start_time + duration)
        assert.same(span.service, child_span.service)
        assert.same(child_span.name, "child_name")
        assert.same(child_span.resource, "child_resource")
        assert.equal(span.trace_id, child_span.trace_id)
        assert.is_not.equal(span.span_id, child_span.span_id)
        assert.equal(child_span.start, child_start_time)
        assert.equal(child_span.duration, child_duration)
    end)
    it("sets tags", function()
        local span =
            new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, false, nil)
        span:set_tag("string", "value")
        span:set_tag("number", 42)
        span:set_tag("boolean", true)
        span:finish(start_time + duration)
        assert.same(span.meta["string"], "value")
        assert.same(span.meta["number"], "42")
        assert.same(span.meta["boolean"], "true")
        assert.is_nil(span.meta["nil"])
    end)
    it("generate 128 bit trace ids", function()
        local start_us = 1708604380 * 1000000LL
        local span =
            new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_us, nil, nil, true, nil)
        assert.is_not.equal(span.trace_id.low, nil)
        assert.equal(span.trace_id.high, 0x65d73bdc00000000)
        assert.equal(span.meta["_dd.p.tid"], "65d73bdc00000000")
    end)
    it("sets http header tags", function()
        local function get_request_header(header_name)
            local request_http_headers = {}
            request_http_headers["foo"] = "bar"
            request_http_headers["host"] = "localhost:8080"
            request_http_headers["user-agent"] = "curl/8.1.2"

            return request_http_headers[header_name]
        end

        local function get_response_header(header_name)
            local response_http_headers = {}
            response_http_headers["bar"] = "boop"
            response_http_headers["ratelimit-limit"] = "15"

            return response_http_headers[header_name]
        end

        local header_tags = {}
        header_tags["bar"] = { normalized = true, value = "bar" }
        header_tags["host"] = { normalized = true, value = "host" }
        header_tags["foo"] = { normalized = false, value = "http.foo" }

        local span =
            new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, false, nil)
        span:set_http_header_tags(header_tags, get_request_header, get_response_header)

        assert.same(span.meta["http.foo"], "bar")
        assert.same(span.meta["http.request.headers.host"], "localhost:8080")
        assert.same(span.meta["http.response.headers.bar"], "boop")
    end)
end)

local ok = pcall(require, "kong.plugins.ddtrace.tracer")
if not ok then
    describe("ddtrace: span (skipped)", function()
        it("requires libdd_trace_c", function()
            pending("libdd_trace_c not available, skipping span tests")
        end)
    end)
    return
end

local ddtrace = require("kong.plugins.ddtrace.tracer")

-- Helper: create a fresh tracer for tests
local function make_tracer()
    local tracer, err = ddtrace.make_tracer({
        service = "test-service",
        agent_url = "http://127.0.0.1:8126",
    })
    assert.is_nil(err)
    assert.is_not_nil(tracer)
    return tracer
end

-- Helper: mock header getter that returns nothing
local function empty_header_getter(_)
    return nil
end

describe("ddtrace: span", function()
    local tracer

    setup(function()
        tracer = make_tracer()
    end)

    describe("extract_or_create_span", function()
        it("creates a root span with no incoming headers", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            assert.is_not_nil(span)
            span:finish()
        end)

        it("extracts trace context from incoming datadog headers", function()
            local getter = function(name)
                if name == "x-datadog-trace-id" then
                    return "12345"
                end
                if name == "x-datadog-parent-id" then
                    return "67890"
                end
                return nil
            end
            local span = ddtrace.extract_or_create_span(tracer, getter, "test.op", "/test")
            assert.is_not_nil(span)
            -- dd-trace-cpp returns zero-padded 128-bit hex trace IDs.
            -- Convert back to number and compare with the decimal input.
            assert.are.equal(12345, tonumber(span:get_trace_id(), 16))
            span:finish()
        end)
    end)

    describe("create_child", function()
        it("creates a child span from a parent", function()
            local root = ddtrace.extract_or_create_span(tracer, empty_header_getter, "root.op", "/root")
            assert.is_not_nil(root)

            local child = root:create_child("child.op", "/child")
            assert.is_not_nil(child)

            child:finish()
            root:finish()
        end)

        it("child shares trace_id but has unique span_id", function()
            local root = ddtrace.extract_or_create_span(tracer, empty_header_getter, "root", "/")
            local child = root:create_child("child", "/child")

            assert.are.equal(root:get_trace_id(), child:get_trace_id())
            assert.are_not.equal(root:get_span_id(), child:get_span_id())

            child:finish()
            root:finish()
        end)
    end)

    describe("set_tag", function()
        it("sets string tags", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            assert.has_no.errors(function()
                span:set_tag("http.method", "GET")
                span:set_tag("http.url", "http://example.com")
            end)
            span:finish()
        end)

        it("coerces numeric values to strings", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            assert.has_no.errors(function()
                span:set_tag("http.status_code", 200)
                span:set_tag("flag", true)
            end)
            span:finish()
        end)

        it("no-ops on nil value", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            assert.has_no.errors(function()
                span:set_tag("key", nil)
            end)
            span:finish()
        end)

        it("silently skips non-string key", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            assert.has_no.errors(function()
                span:set_tag(123, "value")
            end)
            span:finish()
        end)

        it("silently skips table value", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            assert.has_no.errors(function()
                span:set_tag("key", { "a", "b" })
            end)
            span:finish()
        end)
    end)

    describe("set_error", function()
        it("marks span as error", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            assert.has_no.errors(function()
                span:set_error()
            end)
            span:finish()
        end)
    end)

    describe("set_service", function()
        it("sets service name", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            assert.has_no.errors(function()
                span:set_service("my-service")
            end)
            span:finish()
        end)
    end)

    describe("finish", function()
        it("finishes a span without error", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            assert.has_no.errors(function()
                span:finish()
            end)
        end)
    end)

    describe("get_trace_id", function()
        it("returns a non-empty hex string", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            local tid = span:get_trace_id()
            assert.is_string(tid)
            assert.is_true(#tid > 0)
            span:finish()
        end)
    end)

    describe("get_span_id", function()
        it("returns a non-empty hex string", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            local sid = span:get_span_id()
            assert.is_string(sid)
            assert.is_true(#sid > 0)
            span:finish()
        end)
    end)

    describe("inject", function()
        it("calls the header setter callback", function()
            local span = ddtrace.extract_or_create_span(tracer, empty_header_getter, "test.op", "/test")
            local injected = {}

            assert.has_no.errors(function()
                span:inject(function(key, value)
                    injected[key] = value
                end)
            end)

            assert.is_true(next(injected) ~= nil, "Expected at least one injected header")
            span:finish()
        end)
    end)

    describe("lifecycle", function()
        it("creates root and child, tags, injects, finishes", function()
            local root = ddtrace.extract_or_create_span(tracer, empty_header_getter, "root", "/")
            assert.is_not_nil(root)

            root:set_tag("span.kind", "server")
            root:set_tag("http.method", "GET")

            local child = root:create_child("child", "/child")
            assert.is_not_nil(child)

            child:set_tag("span.kind", "client")
            child:set_service("upstream")
            child:set_error()

            assert.are.equal(root:get_trace_id(), child:get_trace_id())
            assert.are_not.equal(root:get_span_id(), child:get_span_id())

            child:finish()
            root:finish()
        end)
    end)
end)

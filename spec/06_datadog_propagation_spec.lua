local extract_datadog = require "kong.plugins.ddtrace.datadog_propagation".extract
local inject_datadog = require "kong.plugins.ddtrace.datadog_propagation".inject
local new_span = require "kong.plugins.ddtrace.span".new

local function get_header_builder(headers)
    local function getter(header)
        return headers[header]
    end

    return getter
end

_G.kong = {
    log = {
        warn = function(s) end
    }
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

            local get_header = get_header_builder(headers)

            local trace_id, parent_id, sampling_priority, origin, tags, err = extract_datadog(get_header, 512)
            assert.is_nil(err)
            assert.equal(trace_id, 12345678901234567890ULL)
            assert.equal(parent_id, 9876543210987654321ULL)
            assert.equal(sampling_priority, 1)
            assert.same(origin, "test-origin")

            local expected_tags = {
                ["_dd.p.dm"] = "-4"
            }

            assert.same(expected_tags, tags)
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
                    ["_dd.propagation_error"] = "decoding_error"
                }

                local get_header = get_header_builder(headers)

                local _, _, _, _, tags , err = extract_datadog(get_header, 512)
                assert.is_nil(err)
                assert.same(tags, expected_tags)
            end)

            it("only certains tags are extracted", function()
                local headers = base_headers
                headers["x-datadog-tags"] = "traceparent=97382,_dd.p.dm=-1,_dd.p.upstream_services=foo,_dd.p.team=apm-proxy"

                local expected_tags = {
                    ["_dd.p.dm"] = "-1",
                    ["_dd.p.team"] = "apm-proxy"
                }

                local get_header = get_header_builder(headers)
                local _, _, _, _, tags , err = extract_datadog(get_header, 512)
                assert.is_nil(err)
                assert.same(expected_tags, tags)
            end)

            describe("maximum header size", function()
                local headers = base_headers
                headers["x-datadog-tags"] = "_dd.p.dm=-2"

                local get_header = get_header_builder(headers)
                it("is zero", function()
                    local max_header_size = 0
                    local _, _, _, _, tags , err = extract_datadog(get_header, max_header_size)
                    assert.is_nil(err)
                    assert.equal(0, #tags)
                end)

                it("reached", function()
                    local expected_tags = {
                        ["_dd.propagation_error"] = "extract_max_size"
                    }

                    local max_header_size = 1
                    local _, _, _, _, tags , err = extract_datadog(get_header, max_header_size)
                    assert.is_nil(err)
                    assert.same(expected_tags, tags)
                end)
            end)
        end)
    end)

    describe("injection", function()
        it("injects the trace into headers", function()
            -- add kong.service.request.set_header method
            local headers = {}
            local headers_set = 0
            local set_header = function(key, value)
                headers[key] = value
                headers_set = headers_set + 1
            end

            local start_time = 1700000000000000000LL
            local duration = 100000000LL
            local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil)
            inject_datadog(span, set_header, 512)
            span:finish(start_time + duration)
            assert.equal(2, headers_set)
            assert.is_string(headers["x-datadog-trace-id"])
            assert.is_string(headers["x-datadog-parent-id"])
        end)

        describe("datadog tags injection", function()
            local headers = {}
            local headers_set = 0
            local set_header = function(key, value)
                headers[key] = value
                headers_set = headers_set + 1
            end

            local start_time = 1700000000000000000LL

            describe("maximum header size", function()
                  it("is zero", function()
                      local propagation_tags = {
                          ["_dd.p.dm"] = "-3"
                      }

                      local max_header_size = 0
                      local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, nil)
                      span:set_tags(propagation_tags)
                      inject_datadog(span, set_header, max_header_size)

                      assert.is_nil(headers["x-datadog-tags"])
                      assert.equal(span.meta["_dd.propagation_error"], "disabled")
                  end)

                  it("reached", function()
                      local propagation_tags = {
                          ["_dd.p.dm"] = "-0"
                      }

                      local max_header_size = 1
                      local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, nil)
                      span:set_tags(propagation_tags)
                      inject_datadog(span, set_header, max_header_size)

                      assert.is_nil(headers["x-datadog-tags"])

                      assert.equal("inject_max_size", span.meta["_dd.propagation_error"])
                  end)
            end)

            it("empty propagation tags", function()
                  local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, nil)
                  inject_datadog(span, set_header, 512)

                  assert.is_nil(headers["x-datadog-tags"])
            end)

            it("correctly encode valid propagation tags", function()
                local propagation_tags = {
                    ["_dd.p.dm"] = "-1",
                    ["_dd.p.hello"] = "world",
                }

                local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, nil)
                span:set_tags(propagation_tags)
                inject_datadog(span, set_header, 512)

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

                local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, nil)
                span:set_tags(propagation_tags)

                local child_start = start_time + 10
                local child_span = span:new_child("child_span", "test_child_resource", child_start)

                inject_datadog(child_span, set_header, 512)
                assert.is_not_nil(headers["x-datadog-tags"])

                -- NOTE: can't assure tag's order in `x-datadog-tags`
                assert.is_true(string_contains(headers["x-datadog-tags"], "_dd.p.dm=-2"))
                assert.is_true(string_contains(headers["x-datadog-tags"], "_dd.p.hello=mars"))
            end)

            it("sampling decision is propagated", function()
                local new_sampler = require "kong.plugins.ddtrace.sampler".new
                local sampler = new_sampler(10, nil)
                local span = new_span("test_service", "test_name", "test_resource", nil, nil, nil, start_time, nil, nil, nil)

                local ok = sampler:sample(span)
                assert.is_true(ok)

                inject_datadog(span, set_header, 512)

                assert.is_not_nil(headers["x-datadog-tags"])
                assert.is_true(string_contains(headers["x-datadog-tags"], "_dd.p.dm=-0"))
            end)
        end)
    end)
end)


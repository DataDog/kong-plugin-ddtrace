local helpers = require("spec.helpers")

local PLUGIN_NAME = "ddtrace"

local HTTP_MOCK_TIMEOUT = 1
local AGENT_PORT = helpers.get_available_port()

-- Run the tests for each strategy. Strategies include "postgres" and "off"
-- which represent the deployment topologies for Kong Gateway
for _, strategy in helpers.all_strategies() do
    describe(PLUGIN_NAME .. ": agent [#" .. strategy .. "]", function()
        -- Will be initialized before_each nested test
        local client
        local mock_agent

        setup(function()
            -- A BluePrint gives us a helpful database wrapper to
            --    manage Kong Gateway entities directly.
            -- This function also truncates any existing data in an existing db.
            -- The custom plugin name is provided to this function so it mark as loaded
            local blue_print = helpers.get_db_utils(strategy, nil, { PLUGIN_NAME })

            -- Using the BluePrint to create a test route, automatically attaches it
            --    to the default "echo" service that will be created by the test framework
            _ = blue_print.routes:insert({
                paths = { "/mock" },
            })

            -- Register the plugin globally
            blue_print.plugins:insert({
                name = PLUGIN_NAME,
                config = {
                    trace_agent_url = "http://127.0.0.1:" .. AGENT_PORT,
                },
            })

            assert(helpers.start_kong({
                nginx_conf = "spec/fixtures/custom_nginx.template",
                plugins = "bundled," .. PLUGIN_NAME,
            }))
        end)

        -- teardown runs after its parent describe block
        teardown(function()
            helpers.stop_kong(nil, true)
        end)

        -- before_each runs before each child describe
        before_each(function()
            client = helpers.proxy_client()
            mock_agent = helpers.http_mock(AGENT_PORT, { timeout = HTTP_MOCK_TIMEOUT })
        end)

        -- after_each runs after each child describe
        after_each(function()
            if client then
                client:close()
            end

            if mock_agent then
                mock_agent("close", true)
            end
        end)

        describe("receive traces", function()
            it("sends trace payload to the agent", function()
                local trace_headers, trace_body
                helpers.wait_until(function()
                    local r = client:get("/mock", {})
                    assert.res_status(200, r)

                    -- The mock agent may catch telemetry (JSON) before traces (msgpack).
                    -- Keep polling until we get the trace submission.
                    local lines, body, headers = mock_agent()
                    if lines and headers["Content-Type"] == "application/msgpack" then
                        trace_headers = headers
                        trace_body = body
                        return true
                    end
                    return false
                end)

                -- Agent receives a non-empty msgpack payload
                assert.is_string(trace_body)
                assert.is_true(#trace_body > 0)

                -- Standard HTTP headers are present
                assert.is_not_nil(trace_headers["Content-Length"])
                assert.equals(#trace_body, tonumber(trace_headers["Content-Length"]))

                -- dd-trace-cpp trace submission headers
                assert.equals("application/msgpack", trace_headers["Content-Type"])
                assert.equals("cpp", trace_headers["Datadog-Meta-Lang"])
                assert.is_not_nil(trace_headers["Datadog-Meta-Lang-Version"])
                assert.is_not_nil(trace_headers["Datadog-Meta-Tracer-Version"])
                assert.is_not_nil(trace_headers["X-Datadog-Trace-Count"])
            end)
        end)

        describe("trace context propagation", function()
            it("injects trace headers into upstream request", function()
                -- The echo service reflects received headers in the response body.
                -- Verify that the plugin injected trace context headers.
                local r = client:get("/mock", {})
                assert.res_status(200, r)

                local res_body = r:read_body()
                -- dd-trace-cpp injects at least one of: x-datadog-trace-id or traceparent
                local has_datadog = string.find(res_body, "x%-datadog%-trace%-id", 1, false)
                local has_w3c = string.find(res_body, "traceparent", 1, false)
                assert.is_truthy(
                    has_datadog or has_w3c,
                    "Expected trace context headers (x-datadog-trace-id or traceparent) in upstream request"
                )
            end)
        end)
    end)
end

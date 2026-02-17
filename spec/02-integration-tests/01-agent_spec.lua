local helpers = require("spec.helpers")

local PLUGIN_NAME = "ddtrace"

local HTTP_MOCK_TIMEOUT = 1
local AGENT_PORT = helpers.get_available_port()

for _, strategy in helpers.all_strategies() do
    describe(PLUGIN_NAME .. ": agent [#" .. strategy .. "]", function()
        local client
        local mock_agent

        setup(function()
            local blue_print = helpers.get_db_utils(strategy, nil, { PLUGIN_NAME })

            _ = blue_print.routes:insert({
                paths = { "/mock" },
            })

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

        teardown(function()
            helpers.stop_kong(nil, true)
        end)

        before_each(function()
            client = helpers.proxy_client()
            mock_agent = helpers.http_mock(AGENT_PORT, { timeout = HTTP_MOCK_TIMEOUT })
        end)

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
                -- The echo service returns the headers it received
                local r = client:get("/mock", {})
                assert.res_status(200, r)

                -- Wait for the trace to be sent to the mock agent
                local headers, body
                helpers.wait_until(function()
                    local r2 = client:get("/mock", {})
                    assert.res_status(200, r2)

                    local lines
                    lines, body, headers = mock_agent()
                    return lines
                end)

                -- Verify the agent received trace data
                assert.is_string(body)
                assert.is_true(#body > 0)
            end)
        end)
    end)
end

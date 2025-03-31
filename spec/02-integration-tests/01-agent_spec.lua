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
            it("gets the expected header and payload", function()
                local headers, body
                helpers.wait_until(function()
                    local r = client:get("/mock", {})
                    assert.res_status(200, r)

                    local lines
                    lines, body, headers = mock_agent()

                    return lines
                end)

                assert.is_string(body)

                assert.is_not_nil(headers["Datadog-Meta-Lang-Version"])
                assert.is_not_nil(headers["Host"])
                assert.is_not_nil(headers["User-Agent"])

                local len_body = #body
                assert.equals(len_body, tonumber(headers["Content-Length"]))
                assert.equals("lua", headers["Datadog-Meta-Lang"])
                assert.equals("LuaJIT", headers["Datadog-Meta-Lang-Interpreter"])
                assert.equals("2", headers["X-Datadog-Trace-Count"])
                assert.equals("application/msgpack", headers["content-type"])
            end)
        end)
    end)
end

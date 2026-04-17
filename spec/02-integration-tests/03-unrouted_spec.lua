local helpers = require("spec.helpers")
local pl_path = require("pl.path")

local PLUGIN_NAME = "ddtrace"

-- Walk the given logfile and return the first line for which `predicate`
-- returns truthy, or `false` if no matching line was found.
local function find_log_line(logfile, predicate)
    assert(predicate ~= nil)
    if pl_path.exists(logfile) and pl_path.getsize(logfile) > 0 then
        local f = assert(io.open(logfile, "r"))
        local line = f:read("*line")

        while line do
            if predicate(line) then
                f:close()
                return line
            end
            line = f:read("*line")
        end

        f:close()
    end

    return false
end

-- Poll the logfile for up to `timeout` seconds, asserting that no line
-- matching `predicate` ever appears. Used for negative assertions where
-- we want to confirm the absence of an error message after an action.
local function assert_log_absent(logfile, predicate, timeout)
    timeout = timeout or 5
    local deadline = ngx.now() + timeout
    while ngx.now() < deadline do
        local found = find_log_line(logfile, predicate)
        if found then
            error("expected log line to be absent, but found: " .. tostring(found))
        end
        ngx.sleep(0.2)
    end
end

-- Run the tests for each strategy. Strategies include "postgres" and "off"
-- which represent the deployment topologies for Kong Gateway.
for _, strategy in helpers.all_strategies() do
    describe(PLUGIN_NAME .. ": unrouted requests [#" .. strategy .. "]", function()
        local client

        lazy_setup(function()
            local blue_print = helpers.get_db_utils(strategy, nil, { PLUGIN_NAME })

            -- Configure a single route so Kong is functional. The interesting
            -- case for this test is a request that does NOT match any route.
            _ = blue_print.routes:insert({
                paths = { "/mock" },
            })

            -- Register the plugin globally so it runs on every phase, including
            -- requests that never match a route.
            blue_print.plugins:insert({
                name = PLUGIN_NAME,
            })

            assert(helpers.start_kong({
                nginx_conf = "spec/fixtures/custom_nginx.template",
                plugins = "bundled," .. PLUGIN_NAME,
                log_level = "debug",
            }))
        end)

        lazy_teardown(function()
            helpers.stop_kong(nil, true)
        end)

        before_each(function()
            helpers.clean_logfile()
            client = helpers.proxy_client()
        end)

        after_each(function()
            if client then
                client:close()
            end
        end)

        it("returns 404 without raising tracing errors", function()
            local res = assert(client:send({
                method = "GET",
                path = "/this-path-does-not-match-any-route",
            }))
            assert.res_status(404, res)

            local logfile = helpers.get_running_conf().nginx_err_logs

            -- The fix wraps the missing-span error in a "no route" check.
            -- Neither the pcall'd error nor the wrapper "tracing error"
            -- message should appear for an unrouted request.
            assert_log_absent(logfile, function(line)
                return string.find(line, "tracing error in DatadogTraceHandler", 1, true) ~= nil
            end)
            assert_log_absent(logfile, function(line)
                return string.find(line, 'proxy span missing during the "header_filter" phase', 1, true)
                    ~= nil
            end)
            assert_log_absent(logfile, function(line)
                return string.find(line, "request span is missing during the log phase", 1, true) ~= nil
            end)
        end)

        it("emits debug logs explaining the skipped header_filter and log phases", function()
            local res = assert(client:send({
                method = "GET",
                path = "/another-unrouted-path",
            }))
            assert.res_status(404, res)

            local logfile = helpers.get_running_conf().nginx_err_logs

            -- Both phases should log a debug message instead of erroring.
            helpers.wait_until(function()
                return find_log_line(logfile, function(line)
                    return string.find(
                        line,
                        "no proxy span and no matched route, skipping header_filter phase",
                        1,
                        true
                    ) ~= nil
                end) ~= false
            end, 5)

            helpers.wait_until(function()
                return find_log_line(logfile, function(line)
                    return string.find(
                        line,
                        "no request span and no matched route, skipping log phase",
                        1,
                        true
                    ) ~= nil
                end) ~= false
            end, 5)
        end)

        it("still traces requests that match a route", function()
            -- Sanity check: the early-return guards must not interfere with
            -- the normal routed-request flow. A matched route should produce
            -- spans (no "skipping" debug messages, no errors) just like before
            -- the fix.
            helpers.clean_logfile()

            local res = assert(client:send({
                method = "GET",
                path = "/mock",
            }))
            assert.res_status(200, res)

            local logfile = helpers.get_running_conf().nginx_err_logs

            assert_log_absent(logfile, function(line)
                return string.find(line, "skipping header_filter phase", 1, true) ~= nil
            end)
            assert_log_absent(logfile, function(line)
                return string.find(line, "skipping log phase", 1, true) ~= nil
            end)
            assert_log_absent(logfile, function(line)
                return string.find(line, "tracing error in DatadogTraceHandler", 1, true) ~= nil
            end)
        end)
    end)
end

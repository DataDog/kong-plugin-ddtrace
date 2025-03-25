local helpers = require("spec.helpers")
local pl_path = require("pl.path")
local cjson = require("cjson")

local PLUGIN_NAME = "ddtrace"

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

local function wait_for_ddtrace_log(logfile)
    local ddtrace_log
    helpers.wait_until(function()
        local logline = find_log_line(logfile, function(logline)
            return string.find(logline, "DATADOG TRACER CONFIGURATION")
        end)
        if logline then
            ddtrace_log = logline
            return true
        end
        return false
    end)
    return ddtrace_log
end

for _, strategy in helpers.all_strategies() do
    describe(PLUGIN_NAME .. "[#" .. strategy .. "]: configuration", function()
        lazy_setup(function()
            helpers.get_db_utils(strategy) -- runs migrations

            local blue_print = helpers.get_db_utils(strategy, nil, { PLUGIN_NAME })

            -- Register the plugin globally
            blue_print.plugins:insert({
                name = PLUGIN_NAME,
            })
        end)

        before_each(function()
            helpers.clean_logfile()
        end)

        describe("at runtime", function()
            it("resolves all environment variables", function()
                local conf = {
                    { env = "DD_SERVICE", value = "foo", conf_name = "service" },
                    { env = "DD_ENV", value = "foo_env", conf_name = "environment" },
                    { env = "DD_VERSION", value = "0.0.1", conf_name = "version" },
                    { env = "DD_TRACE_AGENT_URL", value = "http://foo:3000", conf_name = "agent_url" },
                }

                for _, entry in ipairs(conf) do
                    helpers.setenv(entry.env, entry.value)
                end

                finally(function()
                    helpers.stop_kong(nil, true)
                    for _, entry in ipairs(conf) do
                        helpers.unsetenv(entry.env, entry.value)
                    end
                end)

                assert(helpers.start_kong({
                    nginx_conf = "spec/fixtures/custom_nginx.template",
                    plugins = "bundled," .. PLUGIN_NAME,
                }))

                local logfile = helpers.get_running_conf().nginx_err_logs
                local ddtrace_log = wait_for_ddtrace_log(logfile)
                local ddtrace_raw = ddtrace_log:match("{.*}")
                local ddtrace_conf = assert(cjson.decode(ddtrace_raw))

                for _, entry in ipairs(conf) do
                    assert.equal(entry.value, ddtrace_conf[entry.conf_name])
                end
            end)

            it("resolves environment variable and build correct agent url", function()
                helpers.setenv("DD_AGENT_HOST", "bar")
                helpers.setenv("DD_TRACE_AGENT_PORT", "8090")

                finally(function()
                    helpers.stop_kong(nil, true)
                    helpers.unsetenv("DD_AGENT_HOST")
                    helpers.unsetenv("DD_TRACE_AGENT_PORT")
                end)

                assert(helpers.start_kong({
                    nginx_conf = "spec/fixtures/custom_nginx.template",
                    plugins = "bundled," .. PLUGIN_NAME,
                }))

                local logfile = helpers.get_running_conf().nginx_err_logs
                local ddtrace_log = wait_for_ddtrace_log(logfile)
                local ddtrace_raw = ddtrace_log:match("{.*}")
                local ddtrace_conf = assert(cjson.decode(ddtrace_raw))

                assert.equal("http://bar:8090", ddtrace_conf.agent_url)
            end)
        end)
    end)
end

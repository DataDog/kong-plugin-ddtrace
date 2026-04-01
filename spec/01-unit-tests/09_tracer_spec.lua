local Tracer = require("kong.plugins.ddtrace.tracer")

describe("ddtrace: tracer", function()
    describe("new", function()
        it("creates a tracer with full config", function()
            local tracer, err = Tracer.new({
                service = "test-service",
                environment = "test",
                version = "1.0.0",
                agent_url = "http://127.0.0.1:8126",
                integration_name = "kong",
                integration_version = "0.3.0",
            })
            assert.is_nil(err)
            assert.is_not_nil(tracer)
        end)

        it("creates a tracer with empty config (uses defaults)", function()
            local tracer, err = Tracer.new({})
            assert.is_nil(err)
            assert.is_not_nil(tracer)
        end)

        it("creates a tracer with nil config", function()
            local tracer, err = Tracer.new(nil)
            assert.is_nil(err)
            assert.is_not_nil(tracer)
        end)

        it("creates a tracer with only service name", function()
            local tracer, err = Tracer.new({ service = "my-service" })
            assert.is_nil(err)
            assert.is_not_nil(tracer)
        end)
    end)

    describe("get_or_create", function()
        it("returns the same tracer for the same config object", function()
            local kong_conf = { service_name = "test" }
            local config = { service = "test-service" }

            local tracer1, err1 = Tracer.get_or_create(kong_conf, config)
            assert.is_nil(err1)
            assert.is_not_nil(tracer1)

            local tracer2, err2 = Tracer.get_or_create(kong_conf, config)
            assert.is_nil(err2)
            assert.are.equal(tracer1, tracer2)
        end)

        it("returns different tracers for different config objects", function()
            local kong_conf_a = { service_name = "a" }
            local kong_conf_b = { service_name = "b" }
            local config = { service = "test-service" }

            local tracer_a, err_a = Tracer.get_or_create(kong_conf_a, config)
            assert.is_nil(err_a)

            local tracer_b, err_b = Tracer.get_or_create(kong_conf_b, config)
            assert.is_nil(err_b)

            assert.are_not.equal(tracer_a, tracer_b)
        end)
    end)
end)

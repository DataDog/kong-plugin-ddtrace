local schema_def = require("kong.plugins.ddtrace.schema")
local validate_plugin_config_schema = require("spec.helpers").validate_plugin_config_schema
local protected_tags = require("kong.plugins.ddtrace.protected_tags")

describe("ddtrace: schema", function()
    it("accepts empty config", function()
        local ok, err = validate_plugin_config_schema({}, schema_def)
        assert.is_truthy(ok)
        assert.is_nil(err)
    end)

    it("rejects invalid injection propagation styles type", function()
        local ok, _ = validate_plugin_config_schema({
            injection_propagation_styles = "foo",
        }, schema_def)

        assert.is_falsy(ok)
    end)

    it("rejects invalid injection propagation styles", function()
        local ok, err = validate_plugin_config_schema({
            injection_propagation_styles = { "b3", "zipkin" },
        }, schema_def)

        assert.is_falsy(ok)
        assert.is_not_nil(err)
    end)

    it("rejects invalid extraction propagation styles type", function()
        local ok, err = validate_plugin_config_schema({
            extraction_propagation_styles = "bar",
        }, schema_def)

        assert.is_falsy(ok)
        assert.is_not_nil(err)
    end)

    it("rejects invalid extraction propagation styles", function()
        local ok, err = validate_plugin_config_schema({
            extraction_propagation_styles = { "w3c", "fizz" },
        }, schema_def)

        assert.is_falsy(ok)
        assert.is_not_nil(err)
    end)

    it("rejects repeated header tags", function()
        local ok, err = validate_plugin_config_schema({
            header_tags = {
                { header = "hello", tag = "world" },
                { header = "hello", tag = "world" },
            },
        }, schema_def)

        assert.is_falsy(ok)
        assert.is_not_nil(err)
    end)

    for _, forbidden_tag in ipairs(protected_tags) do
        it('rejects "' .. forbidden_tag .. '" headers tags', function()
            local ok, err = validate_plugin_config_schema({
                header_tags = {
                    { header = "hello", tag = forbidden_tag },
                },
            }, schema_def)

            assert.is_falsy(ok)
            assert.is_not_nil(err)
        end)
    end

    it("rejects deprecated `agent_endpoint` config", function()
        local ok, err = validate_plugin_config_schema({
            agent_endpoint = "http://localhost:8126",
        }, schema_def)

        assert.is_falsy(ok)
        assert.same({
            config = {
                agent_endpoint = "agent_endpoint is deprecated. Please use trace_agent_url or agent_host instead",
            },
        }, err)
    end)
end)

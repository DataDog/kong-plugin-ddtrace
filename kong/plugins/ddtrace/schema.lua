local typedefs = require("kong.db.schema.typedefs")
local Schema = require("kong.db.schema")

local PROTECTED_TAGS = {
    "error",
    "http.method",
    "http.path",
    "http.status_code",
    "kong.balancer.state",
    "kong.balancer.try",
    "kong.consumer",
    "kong.credential",
    "kong.node.id",
    "kong.route",
    "kong.service",
    "lc",
    "peer.hostname",
}

local header_tag = Schema.define({
    type = "record",
    fields = {
        { header = { type = "string", required = true } },
        { tag = { type = "string", not_one_of = PROTECTED_TAGS } },
    },
})

-- TODO: check if we could use a set instead
local validate_header_tag = function(tags)
    if type(tags) ~= "table" then
        return nil
    end
    local found = {}
    for i = 1, #tags do
        local key = tags[i].header
        if found[key] then
            return nil, "repeated header are not allowed: " .. key
        end
        found[key] = true
    end
    return true
end

local static_tag = Schema.define({
    type = "record",
    fields = {
        { name = { type = "string", required = true, not_one_of = PROTECTED_TAGS } },
        { value = { type = "string", required = true } },
    },
})

local validate_static_tags = function(tags)
    if type(tags) ~= "table" then
        return true
    end
    local found = {}
    for i = 1, #tags do
        local name = tags[i].name
        if found[name] then
            return nil, "repeated tags are not allowed: " .. name
        end
        found[name] = true
    end
    return true
end

local resource_name_rule = Schema.define({
    type = "record",
    fields = {
        { match = { type = "string", required = true, is_regex = true } },
        { replacement = { type = "string" } },
    },
})

local function make_deprecated_config(err)
    return function(_)
        return nil, err
    end
end

local deprecated_agent_endpoint =
    make_deprecated_config("agent_endpoint is deprecated. Please use trace_agent_url or agent_host instead")

return {
    name = "ddtrace",
    fields = {
        {
            config = {
                type = "record",
                fields = {
                    { service_name = { type = "string", required = true, default = "kong" } },
                    { environment = { type = "string" } },
                    -- priority of values for agent address details are resolved in new_trace_agent_writer
                    { agent_host = typedefs.host({ default = "localhost" }) },
                    { trace_agent_port = { type = "integer", default = 8126, gt = 0 } },
                    { trace_agent_url = typedefs.url({ default = "http://localhost:8126" }) },
                    {
                        static_tags = {
                            type = "array",
                            elements = static_tag,
                            custom_validator = validate_static_tags,
                        },
                    },
                    { resource_name_rule = { type = "array", elements = resource_name_rule } },
                    { initial_samples_per_second = { type = "integer", default = 100, gt = 0 } },
                    { initial_sample_rate = { type = "number", default = nil, between = { 0, 1 } } },
                    { version = { type = "string" } },
                    { header_tags = { type = "array", elements = header_tag, custom_validator = validate_header_tag } },
                    { max_header_size = { type = "integer", default = 512, between = { 0, 512 } } },
                    { generate_128bit_trace_ids = { type = "boolean", default = true } },
                    -- Deprecated:
                    { agent_endpoint = { type = "string", custom_validator = deprecated_agent_endpoint } },
                },
            },
        },
    },
}

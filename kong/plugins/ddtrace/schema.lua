local typedefs = require "kong.db.schema.typedefs"
local Schema = require "kong.db.schema"

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

local static_tag = Schema.define {
    type = "record",
    fields = {
        { name = { type = "string", required = true, not_one_of = PROTECTED_TAGS } },
        { value = { type = "string", required = true } },
    },
}

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

local function allow_referenceable(field)
    if kong.version_num >= 2008000 then
        field.referenceable = true
    end
    return field
end

-- make a field referenceable if kong version >= 2.8.0
local resource_name_rule = Schema.define {
    type = "record",
    fields = {
        { match = { type = "string", required = true, is_regex = true } },
        { replacement = { type = "string" } },
    },
}

return {
    name = "ddtrace",
    fields = {
        { config = {
            type = "record",
            fields = {
                { service_name = { type = "string", required = true, default = "kong" } },
                { environment = { type = "string", default = "none" } },
                { host = allow_referenceable(typedefs.ip()) },
                { port = { type = "integer", default = 8126, gt = 0 } },
                { version = { type = "string", default = "none" } },
                { agent_endpoint = allow_referenceable(typedefs.url({ default = "http://localhost:8126/v0.4/traces" }))},
                { static_tags = { type = "array", elements = static_tag,
                custom_validator = validate_static_tags } },
                { resource_name_rule = { type = "array", elements = resource_name_rule } },
                { initial_samples_per_second = { type = "integer", default = 100, gt = 0 } },
                { initial_sample_rate = { type = "number", default = nil, between = {0, 1 } } },
            },
        }, },
    },
}

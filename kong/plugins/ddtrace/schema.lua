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

return {
  name = "ddtrace",
  fields = {
    { config = {
        type = "record",
        fields = {
          { service_name = { type = "string", required = true, default = "kong" } },
          { environment = { type = "string", default = "none" } },
          { agent_endpoint = typedefs.url },
          { static_tags = { type = "array", elements = static_tag,
                            custom_validator = validate_static_tags } },
        },
    }, },
  },
}

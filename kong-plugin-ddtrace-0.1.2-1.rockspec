package = "kong-plugin-ddtrace"
version = "0.1.2-1"

source = {
  url = "https://github.com/datadog/kong-plugin-ddtrace/archive/v0.1.2.zip",
  dir = "kong-plugin-ddtrace-0.1.2",
}

description = {
  summary = "This plugin allows Kong to trace requests and report them to the Datadog Agent",
  homepage = "https://github.com/datadog/kong-plugin-ddtrace",
  license = "Apache 2.0",
}

dependencies = {
  "lua >= 5.1",
  "lua-resty-http >= 0.11",
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.ddtrace.handler"] = "kong/plugins/ddtrace/handler.lua",
    ["kong.plugins.ddtrace.schema"] = "kong/plugins/ddtrace/schema.lua",
    ["kong.plugins.ddtrace.span"] = "kong/plugins/ddtrace/span.lua",
    ["kong.plugins.ddtrace.sampler"] = "kong/plugins/ddtrace/sampler.lua",
    ["kong.plugins.ddtrace.propagation"] = "kong/plugins/ddtrace/propagation.lua",
    ["kong.plugins.ddtrace.agent_writer"] = "kong/plugins/ddtrace/agent_writer.lua",
    ["kong.plugins.ddtrace.msgpack_encode"] = "kong/plugins/ddtrace/msgpack_encode.lua",
  },
}

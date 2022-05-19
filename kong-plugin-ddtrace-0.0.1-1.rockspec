package = "kong-plugin-ddtrace"
version = "0.0.1-1"

source = {
  url = "https://github.com/datadog/kong-plugin-ddtrace/archive/v0.0.1.zip",
  dir = "kong-plugin-ddtrace-0.0.1",
}

description = {
  summary = "This plugin allows Kong to trace requests and report them to the Datadog Agent",
  homepage = "https://github.com/datadog/kong-plugin-ddtrace",
  license = "Apache 2.0",
}

dependencies = {
  "lua >= 5.1",
  "lua-cjson",
  "lua-resty-http >= 0.11",
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.ddtrace.handler"] = "kong/plugins/ddtrace/handler.lua",
    ["kong.plugins.ddtrace.schema"] = "kong/plugins/ddtrace/schema.lua",
    ["kong.plugins.ddtrace.headers"] = "kong/plugins/ddtrace/headers.lua",
    ["kong.plugins.ddtrace.span"] = "kong/plugins/ddtrace/span.lua",
    ["kong.plugins.ddtrace.reporter"] = "kong/plugins/ddtrace/reporter.lua",
    ["kong.plugins.ddtrace.msgpack"] = "kong/plugins/ddtrace/msgpack.lua",
    ["kong.plugins.ddtrace.tags"] = "kong/plugins/ddtrace/tags.lua",
  },
}

package = "kong-plugin-ddtrace"
version = "0.2.4-1"

source = {
    url = "https://github.com/datadog/kong-plugin-ddtrace/archive/v0.2.4.zip",
    dir = "kong-plugin-ddtrace-v0.2.4",
}

description = {
    summary = "This plugin allows Kong to trace requests and report them to the Datadog Agent",
    homepage = "https://github.com/datadog/kong-plugin-ddtrace",
    license = "Apache 2.0",
}

dependencies = {
    "lua >= 5.1",
}

build = {
    type = "builtin",
    modules = {
        ["kong.plugins.ddtrace.handler"] = "kong/plugins/ddtrace/handler.lua",
        ["kong.plugins.ddtrace.schema"] = "kong/plugins/ddtrace/schema.lua",
        ["kong.plugins.ddtrace.ffi_bindings"] = "kong/plugins/ddtrace/ffi_bindings.lua",
        ["kong.plugins.ddtrace.protected_tags"] = "kong/plugins/ddtrace/protected_tags.lua",
    },
}

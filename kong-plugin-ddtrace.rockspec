package = "kong-plugin-ddtrace"
version = "$version-$revision"

source = {
    url = "https://github.com/datadog/kong-plugin-ddtrace/archive/$tag.zip",
    dir = "kong-plugin-ddtrace-$tag",
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
        ["kong.plugins.ddtrace.tracer"] = "kong/plugins/ddtrace/tracer.lua",
        ["kong.plugins.ddtrace.handler"] = "kong/plugins/ddtrace/handler.lua",
        ["kong.plugins.ddtrace.protected_tags"] = "kong/plugins/ddtrace/protected_tags.lua",
        ["kong.plugins.ddtrace.schema"] = "kong/plugins/ddtrace/schema.lua",
        ["kong.plugins.ddtrace.utils"] = "kong/plugins/ddtrace/utils.lua",
    },
    install = {
        lib = {
            ["libdd_trace_c-x86_64"] = "lib/libdd_trace_c-x86_64.so",
            ["libdd_trace_c-aarch64"] = "lib/libdd_trace_c-aarch64.so",
        },
    },
}

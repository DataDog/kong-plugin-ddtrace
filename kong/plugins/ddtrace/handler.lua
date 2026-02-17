local lib = require("kong.plugins.ddtrace.ffi_bindings")
local ffi = require("ffi")
local cjson = require("cjson")

local kong = kong
local ngx = ngx
local pcall = pcall
local fmt = string.format
local strsub = string.sub
local regex = ngx.re
local subsystem = ngx.config.subsystem

local DatadogTraceHandler = {
    VERSION = "0.2.4",
    PRIORITY = 100000,
}

-- Tracer config option constants (from datadog_sdk_tracer_option enum)
local TRACER_OPT_SERVICE_NAME = 0
local TRACER_OPT_ENV = 1
local TRACER_OPT_VERSION = 2
local TRACER_OPT_AGENT_URL = 3

-- Cache for tracer instances per configuration
local tracer_cache = setmetatable({}, { __mode = "k" })

-- Memoize worker/kong data (with nil guards for early loading phases)
local ngx_worker_pid = ngx.worker.pid() or 0
local ngx_worker_id = ngx.worker.id() or 0
local ngx_worker_count = ngx.worker.count() or 1
local kong_node_id = kong.node.get_id() or "unknown"

-- Load environment variables
local get_env = os.getenv
local AGENT_HOST = get_env("DD_AGENT_HOST")
local AGENT_PORT = get_env("DD_TRACE_AGENT_PORT")
local DD_SERVICE = get_env("DD_SERVICE")
local DD_ENV = get_env("DD_ENV")
local DD_VERSION = get_env("DD_VERSION")
local DD_AGENT_URL = get_env("DD_TRACE_AGENT_URL")
local DD_TRACE_STARTUP_LOGS = get_env("DD_TRACE_STARTUP_LOGS")

-- Current configuration
local ddtrace_conf
local header_tags

-- Normalize header_tags config into a lookup table.
-- Lowercases headers, strips whitespace, and replaces non-alphanum chars with _.
local function normalize_header_tags(raw_header_tags)
    local normalized = {}
    for i = 1, #raw_header_tags do
        local tag = raw_header_tags[i].tag or ""
        local header = raw_header_tags[i].header
        if not header then
            goto continue
        end

        local norm_header = string.lower(string.gsub(header, "%s+", ""))
        if #norm_header == 0 then
            goto continue
        end
        norm_header = string.gsub(norm_header, "[^a-zA-Z0-9 -]", "_")

        tag = string.gsub(tag, "%s+", "")
        if not tag or #tag == 0 then
            normalized[norm_header] = { normalized = true, value = norm_header }
        else
            normalized[norm_header] = { normalized = false, value = tag }
        end
        ::continue::
    end
    return normalized
end

-- Concatenate table values or return string as-is.
local function concat_value(input, separator)
    if type(input) ~= "table" then
        return input
    end
    return table.concat(input, separator)
end

local function is_truthy(v)
    return v and (v == "1" or v == "true" or v == "yes")
end

-- Helper: finish a span and free it (free triggers trace submission in dd-trace-cpp).
-- Detaches the ffi.gc guard first to prevent double-free.
local function finish_span(span)
    ffi.gc(span, nil)
    lib.datadog_sdk_span_finish(span)
    lib.datadog_sdk_span_free(span)
end

local function get_tracer(conf)
    if tracer_cache[conf] == nil then
        -- Build agent URL
        local agent_host = AGENT_HOST or conf.agent_host or "localhost"
        local agent_port = AGENT_PORT or conf.trace_agent_port or "8126"
        if type(agent_port) ~= "string" then
            agent_port = tostring(agent_port)
        end
        local agent_url = DD_AGENT_URL or conf.trace_agent_url or fmt("http://%s:%s", agent_host, agent_port)

        -- Create tracer configuration
        local service = DD_SERVICE or conf.service_name or "kong"
        local environment = DD_ENV or conf.environment
        local version = DD_VERSION or conf.version

        local dd_conf = lib.datadog_sdk_tracer_conf_new()
        if dd_conf == nil then
            kong.log.err("Failed to create tracer configuration")
            return nil
        end

        if service then
            lib.datadog_sdk_tracer_conf_set(dd_conf, TRACER_OPT_SERVICE_NAME, ffi.cast("void*", service))
        end
        if environment then
            lib.datadog_sdk_tracer_conf_set(dd_conf, TRACER_OPT_ENV, ffi.cast("void*", environment))
        end
        if version then
            lib.datadog_sdk_tracer_conf_set(dd_conf, TRACER_OPT_VERSION, ffi.cast("void*", version))
        end
        if agent_url then
            lib.datadog_sdk_tracer_conf_set(dd_conf, TRACER_OPT_AGENT_URL, ffi.cast("void*", agent_url))
        end

        -- Create tracer
        local tracer = lib.datadog_sdk_tracer_new(dd_conf)
        lib.datadog_sdk_tracer_conf_free(dd_conf)

        if tracer == nil then
            kong.log.err("Failed to create tracer")
            return nil
        end

        tracer_cache[conf] = ffi.gc(tracer, lib.datadog_sdk_tracer_free)
    end
    return tracer_cache[conf]
end

local function expose_tracing_variables(span)
    -- Get trace ID as hex string
    local trace_id_buf = ffi.new("char[33]")
    local trace_id_len = lib.datadog_sdk_span_get_trace_id(span, trace_id_buf, 33)

    -- Get span ID as hex string
    local span_id_buf = ffi.new("char[17]")
    local span_id_len = lib.datadog_sdk_span_get_span_id(span, span_id_buf, 17)

    if trace_id_len >= 0 and span_id_len >= 0 then
        local trace_id = ffi.string(trace_id_buf)
        local span_id = ffi.string(span_id_buf)

        -- Expose to Kong context
        local kong_shared = kong.ctx.shared
        kong_shared.datadog_sdk_trace_id = trace_id
        kong_shared.datadog_sdk_span_id = span_id

        -- Set nginx variables
        if ngx.var.datadog_trace_id ~= nil then
            ngx.var.datadog_trace_id = trace_id
        end
        if ngx.var.datadog_span_id ~= nil then
            ngx.var.datadog_span_id = span_id
        end
    end
end

-- Apply resource_name_rules to the provided URI
local function apply_resource_name_rules(uri, rules)
    if rules then
        for _, rule in ipairs(rules) do
            local from, to, _ = regex.find(uri, rule.match, "ajo")
            if from then
                local matched_uri = strsub(uri, from, to)
                if not rule.replacement then
                    return matched_uri
                end
                local replaced_uri, _, _ = regex.sub(matched_uri, rule.match, rule.replacement, "ajo")
                if replaced_uri then
                    return replaced_uri
                end
            end
        end
    end

    -- Default rule: replace excessive digits with ?
    local fragments = {}
    local it, _ = regex.gmatch(uri, "(/[^/]*)", "jo")
    if not it then
        return uri
    end
    while true do
        local fragment_table = it()
        if not fragment_table then
            break
        end
        local fragment = fragment_table[1]
        table.insert(fragments, fragment)
    end
    for i, fragment in ipairs(fragments) do
        local token = strsub(fragment, 2)
        local version_match = regex.match(token, "v\\d+", "ajo")
        if version_match then
            goto continue
        end

        local token_len = #token
        local _, digits, _ = regex.gsub(token, "\\d", "", "jo")
        if token_len <= 5 and digits > 2 or token_len > 5 and digits > 3 then
            fragments[i] = "/?"
        end
        ::continue::
    end

    return table.concat(fragments)
end

local function configure(conf)
    if ddtrace_conf and conf["__seq__"] == ddtrace_conf["__id__"] then
        return
    end

    local agent_host = AGENT_HOST or conf.agent_host or "localhost"
    local agent_port = AGENT_PORT or conf.trace_agent_port or "8126"
    if type(agent_port) ~= "string" then
        agent_port = tostring(agent_port)
    end
    local agent_url = string.format("http://%s:%s", agent_host, agent_port)

    ddtrace_conf = {
        __id__ = conf["__seq__"],
        service = DD_SERVICE or conf.service_name or "kong",
        environment = DD_ENV or conf.environment,
        version = DD_VERSION or conf.version,
        agent_url = DD_AGENT_URL or conf.trace_agent_url or agent_url,
        injection_propagation_styles = conf.injection_propagation_styles,
        extraction_propagation_styles = conf.extraction_propagation_styles,
    }

    local log_conf = conf.startup_log
    local env_log_conf = DD_TRACE_STARTUP_LOGS
    if env_log_conf then
        log_conf = is_truthy(env_log_conf)
    end

    if log_conf then
        kong.log.info("DATADOG TRACER CONFIGURATION - " .. cjson.encode(ddtrace_conf))
    end

    if conf and conf.header_tags then
        header_tags = normalize_header_tags(conf.header_tags)
    end
end

-- FFI callbacks for header extraction/injection
local current_request_headers
local current_response_headers

-- Anchors Lua strings returned via FFI callbacks to prevent GC from collecting
-- them while C++ still holds a pointer to the underlying buffer.
local _pinned_strings = {}

local header_getter_cb = ffi.cast("const char* (*)(const char*)", function(header_name)
    if current_request_headers == nil then
        return nil
    end
    local name = ffi.string(header_name)
    local value = current_request_headers(name)
    if value then
        _pinned_strings[#_pinned_strings + 1] = value
        return ffi.cast("const char*", value)
    end
    return nil
end)

local header_setter_cb = ffi.cast("void (*)(const char*, const char*)", function(key, value)
    if current_response_headers == nil then
        return
    end
    local key_str = ffi.string(key)
    local value_str = ffi.string(value)
    current_response_headers(key_str, value_str)
end)

local function access(conf)
    local tracer = get_tracer(conf)
    if not tracer then
        kong.log.err("Tracer not available")
        return
    end

    -- Prepare for header extraction
    current_request_headers = kong.request.get_header

    -- Extract or create root span
    local req = kong.request
    local method = req.get_method()
    local path = req.get_path()
    local resource = method .. " " .. apply_resource_name_rules(path, conf.resource_name_rule)

    local root_span = lib.datadog_sdk_tracer_extract_or_create_span(
        tracer,
        header_getter_cb,
        "kong.request",
        resource
    )

    -- Release pinned header strings now that extraction is complete
    for i = 1, #_pinned_strings do _pinned_strings[i] = nil end

    if not root_span then
        kong.log.err("Failed to create root span")
        return
    end

    -- Wrap in ffi.gc as a safety net: if an error prevents explicit finish_span,
    -- the GC will eventually free the C++ span to prevent memory leaks.
    root_span = ffi.gc(root_span, lib.datadog_sdk_span_free)

    -- Set HTTP tags
    local url = req.get_scheme() .. "://" .. req.get_host() .. ":" .. req.get_port() .. path
    lib.datadog_sdk_span_set_tag(root_span, "http.method", method)
    lib.datadog_sdk_span_set_tag(root_span, "http.url", url)

    local client_ip = kong.client.get_forwarded_ip()
    if client_ip then
        lib.datadog_sdk_span_set_tag(root_span, "http.client_ip", client_ip)
    end

    local useragent = req.get_header("user-agent")
    if useragent then
        lib.datadog_sdk_span_set_tag(root_span, "http.useragent", useragent)
    end

    local content_length = req.get_header("content-length")
    if content_length then
        lib.datadog_sdk_span_set_tag(root_span, "http.request.content_length", content_length)
    end

    local http_version = req.get_http_version()
    if http_version then
        lib.datadog_sdk_span_set_tag(root_span, "http.version", tostring(http_version))
    end

    lib.datadog_sdk_span_set_tag(root_span, "span.kind", "server")
    lib.datadog_sdk_span_set_tag(root_span, "component", "kong")

    -- Set Kong tags
    if kong.version then
        lib.datadog_sdk_span_set_tag(root_span, "kong.version", kong.version)
    end
    if kong.pdk_version then
        lib.datadog_sdk_span_set_tag(root_span, "kong.pdk_version", kong.pdk_version)
    end
    if kong_node_id then
        lib.datadog_sdk_span_set_tag(root_span, "kong.node_id", kong_node_id)
    end
    if ngx.config.nginx_version then
        lib.datadog_sdk_span_set_tag(root_span, "nginx.version", tostring(ngx.config.nginx_version))
    end
    if ngx.config.ngx_lua_version then
        lib.datadog_sdk_span_set_tag(root_span, "nginx.lua_version", tostring(ngx.config.ngx_lua_version))
    end
    if ngx_worker_pid > 0 then
        lib.datadog_sdk_span_set_tag(root_span, "nginx.worker_pid", tostring(ngx_worker_pid))
    end
    if ngx_worker_id >= 0 then
        lib.datadog_sdk_span_set_tag(root_span, "nginx.worker_id", tostring(ngx_worker_id))
    end
    if ngx_worker_count > 0 then
        lib.datadog_sdk_span_set_tag(root_span, "nginx.worker_count", tostring(ngx_worker_count))
    end

    -- Set environment/version tags
    if ddtrace_conf.environment then
        lib.datadog_sdk_span_set_tag(root_span, "env", ddtrace_conf.environment)
    end
    if ddtrace_conf.version then
        lib.datadog_sdk_span_set_tag(root_span, "version", ddtrace_conf.version)
    end

    -- Set static tags
    if type(conf.static_tags) == "table" then
        for i = 1, #conf.static_tags do
            local tag = conf.static_tags[i]
            lib.datadog_sdk_span_set_tag(root_span, tag.name, tag.value)
        end
    end

    -- Set Kong configuration tags
    if kong.configuration then
        lib.datadog_sdk_span_set_tag(root_span, "kong.role", kong.configuration.role)
        lib.datadog_sdk_span_set_tag(root_span, "kong.nginx_daemon", tostring(kong.configuration.nginx_daemon))
        lib.datadog_sdk_span_set_tag(root_span, "kong.database", kong.configuration.database)
    end

    -- Create proxy span (note: arg order is name, service, resource)
    local proxy_span = lib.datadog_sdk_span_create_child_with_options(
        root_span,
        "kong.proxy",
        nil,
        resource
    )

    if proxy_span then
        -- Wrap in ffi.gc as a safety net (same as root_span above)
        proxy_span = ffi.gc(proxy_span, lib.datadog_sdk_span_free)

        expose_tracing_variables(proxy_span)

        -- Inject trace context into upstream request
        current_response_headers = kong.service.request.set_header
        lib.datadog_sdk_span_inject(proxy_span, header_setter_cb)
    end

    -- Store spans in context
    local ctx = kong.ctx.plugin
    ctx.root_span = root_span
    ctx.proxy_span = proxy_span
end

local function header_filter(conf)
    local ctx = kong.ctx.plugin
    if ctx.proxy_span == nil then
        kong.log.err('proxy span missing during the "header_filter" phase')
        return
    end

    local span = ctx.proxy_span

    -- Set span kind to client
    lib.datadog_sdk_span_set_tag(span, "span.kind", "client")

    -- Set balancer info
    local ngx_ctx = ngx.ctx
    local balancer_data = ngx_ctx.balancer_data
    if balancer_data then
        if balancer_data.hostname then
            lib.datadog_sdk_span_set_tag(span, "peer.hostname", balancer_data.hostname)
        end
        if balancer_data.ip then
            lib.datadog_sdk_span_set_tag(span, "peer.ip", balancer_data.ip)
        end
        if balancer_data.port and balancer_data.port > 0 then
            lib.datadog_sdk_span_set_tag(span, "peer.port", tostring(balancer_data.port))
        end
        if balancer_data.try_count and balancer_data.try_count > 0 then
            lib.datadog_sdk_span_set_tag(span, "kong.balancer.tries", tostring(balancer_data.try_count))
        end

        -- Set try-specific tags
        local balancer_tries = balancer_data.tries
        local try_count = balancer_data.try_count
        for i = 1, try_count do
            local try = balancer_tries[i]
            local tag_prefix = fmt("kong.balancer.try-%d.", i)
            if i < try_count then
                lib.datadog_sdk_span_set_tag(span, tag_prefix .. "error", "true")
                lib.datadog_sdk_span_set_tag(span, tag_prefix .. "state", try.state)
                lib.datadog_sdk_span_set_tag(span, tag_prefix .. "status_code", tostring(try.code))
            end
            if try.balancer_latency then
                lib.datadog_sdk_span_set_tag(span, tag_prefix .. "latency", tostring(try.balancer_latency))
            end
        end
    end

    -- Set service and route info
    local service = kong.router.get_service()
    if service and service.id then
        lib.datadog_sdk_span_set_tag(span, "kong.service", service.id)
        if type(service.name) == "string" then
            lib.datadog_sdk_span_set_tag(span, "kong.service_name", service.name)
            lib.datadog_sdk_span_set_service(span, service.name)
        end
    end

    local route = kong.router.get_route()
    if route then
        lib.datadog_sdk_span_set_tag(span, "kong.route", route.id)
        if type(route.name) == "string" then
            lib.datadog_sdk_span_set_tag(span, "kong.route_name", route.name)
        end
    else
        lib.datadog_sdk_span_set_tag(span, "kong.route", "none")
    end

    -- Set status code and error
    local status_code = kong.response.get_status()
    if status_code > 0 then
        lib.datadog_sdk_span_set_tag(span, "http.status_code", tostring(status_code))
    end

    if status_code >= 500 then
        lib.datadog_sdk_span_set_error(span, 1)
    end

    -- Finish proxy span
    finish_span(span)
    ctx.proxy_span = nil
end

local function log(conf)
    local ctx = kong.ctx.plugin
    if ctx.root_span == nil then
        kong.log.err("root span is missing during the log phase")
        return
    end

    local root_span = ctx.root_span

    -- Set HTTP header tags
    if header_tags then
        for header_name, tag_entry in pairs(header_tags) do
            local req_header_value = kong.request.get_header(header_name)
            local res_header_value = kong.response.get_header(header_name)

            if req_header_value then
                local tag = tag_entry.normalized
                    and ("http.request.headers." .. tag_entry.value)
                    or tag_entry.value
                lib.datadog_sdk_span_set_tag(root_span, tag, concat_value(req_header_value, ","))
            end

            if res_header_value then
                local tag = tag_entry.normalized
                    and ("http.response.headers." .. tag_entry.value)
                    or tag_entry.value
                lib.datadog_sdk_span_set_tag(root_span, tag, concat_value(res_header_value, ","))
            end
        end
    end

    -- Set authenticated consumer/credential
    local ngx_ctx = ngx.ctx
    if ngx_ctx.authenticated_consumer then
        lib.datadog_sdk_span_set_tag(root_span, "kong.consumer", ngx_ctx.authenticated_consumer.id)
    end
    if conf and conf.include_credential and ngx_ctx.authenticated_credential then
        lib.datadog_sdk_span_set_tag(root_span, "kong.credential", ngx_ctx.authenticated_credential.id)
    end

    -- Finish root span
    finish_span(root_span)

    -- Clean up
    ctx.proxy_span = nil
    ctx.root_span = nil
end

function DatadogTraceHandler:configure(configs)
    local conf = configs and configs[1] or nil
    if conf then
        local ok, message = pcall(configure, conf)
        if not ok then
            kong.log.err("tracing error in DatadogTraceHandler:configure: ", message)
        end
    end
end

function DatadogTraceHandler:access(conf)
    if subsystem ~= "http" then
        return
    end

    local ok, message = pcall(access, conf)
    if not ok then
        kong.log.err("tracing error in DatadogTraceHandler:access: ", message)
    end
end

function DatadogTraceHandler:header_filter(conf)
    if subsystem ~= "http" then
        return
    end

    local ok, message = pcall(header_filter, conf)
    if not ok then
        kong.log.err("tracing error in DatadogTraceHandler:header_filter: ", message)
    end
end

function DatadogTraceHandler:log(conf)
    if subsystem ~= "http" then
        return
    end

    local ok, message = pcall(log, conf)
    if not ok then
        kong.log.err("tracing error in DatadogTraceHandler:log: ", message)
    end
end

return DatadogTraceHandler

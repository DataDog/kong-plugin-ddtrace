local ddtrace = require("kong.plugins.ddtrace.tracer")
local utils = require("kong.plugins.ddtrace.utils")
local cjson = require("cjson")

local pcall = pcall
local fmt = string.format
local strsub = string.sub
local regex = ngx.re
local subsystem = ngx.config.subsystem

local NS_PER_MS = 1000000LL

local DatadogTraceHandler = {
    VERSION = "0.3.0",
    -- We want to run first so that timestamps taken are at start of the phase.
    -- However, it might be useful to finish spans after other plugins have completed
    -- to more accurately represent the request completion time.
    PRIORITY = 100000,
}

local header_tags
local ddtrace_conf

-- NOTE(@dmehala): Load environment variable here because `os.getenv`
-- the handler is executed on master worker and has access to environment variables.
local get_env = os.getenv
local AGENT_HOST = get_env("DD_AGENT_HOST")
local AGENT_PORT = get_env("DD_TRACE_AGENT_PORT")
local DD_SERVICE = get_env("DD_SERVICE")
local DD_ENV = get_env("DD_ENV")
local DD_VERSION = get_env("DD_VERSION")
local DD_AGENT_URL = get_env("DD_TRACE_AGENT_URL")
local DD_TRACE_STARTUP_LOGS = get_env("DD_TRACE_STARTUP_LOGS")

-- Memoize some data attached to traces
local ngx_worker_pid = ngx.worker.pid()
local ngx_worker_id = ngx.worker.id()
local ngx_worker_count = ngx.worker.count()
local kong_node_id = kong.node.get_id()

local function expose_tracing_variables(span)
    -- Expose traceID and parentID for other plugin to consume and also set an NGINX variable
    -- that can be use for in `log_format` directive for correlation with logs.
    local trace_id = span:get_trace_id()
    local span_id = span:get_span_id()

    if trace_id == nil or span_id == nil then
        return
    end

    -- NOTE: kong.ctx has the same lifetime as the current request.
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

-- apply resource_name_rules to the provided URI
-- and return a replacement value.
local function apply_resource_name_rules(uri, rules)
    if rules then
        for _, rule in ipairs(rules) do
            -- try to match URI to rule's expression
            local from, to, _ = regex.find(uri, rule.match, "ajo")
            if from then
                local matched_uri = strsub(uri, from, to)
                -- if we have a match but no replacement, return the matched value
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

    -- no rules matched or errors occured, apply a default rule
    -- decompose path into fragments, and replace parts with excessive digits with ?,
    -- except if it looks like a version identifier (v1, v2 etc) or if it is
    -- a status / health check
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
        -- the iterator returns a table, but it should only have one item in it
        local fragment = fragment_table[1]
        table.insert(fragments, fragment)
    end
    for i, fragment in ipairs(fragments) do
        local token = strsub(fragment, 2)
        local version_match = regex.match(token, "v\\d+", "ajo")
        if version_match then
            -- no ? substitution for versions
            goto continue
        end

        local token_len = #token
        local _, digits, _ = regex.gsub(token, "\\d", "", "jo")
        if token_len <= 5 and digits > 2 or token_len > 5 and digits > 3 then
            -- apply the substitution
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

    -- Build agent url
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
        log_conf = utils.is_truthy(env_log_conf)
    end

    if log_conf then
        kong.log.info("DATADOG TRACER CONFIGURATION - " .. cjson.encode(ddtrace_conf))
    end

    local tracer, tracer_err = ddtrace.make_tracer({
        service = ddtrace_conf.service,
        environment = ddtrace_conf.environment,
        version = ddtrace_conf.version,
        agent_url = ddtrace_conf.agent_url,
        integration_name = "kong",
        integration_version = DatadogTraceHandler.VERSION,
    })
    if tracer == nil then
        kong.log.err("failed to create tracer: ", tracer_err)
    end
    ddtrace_conf.tracer = tracer

    if conf and conf.header_tags then
        header_tags = utils.normalize_header_tags(conf.header_tags)
    end
end

local function make_root_span(conf, resource)
    local req = kong.request
    local method = req.get_method()
    local path = req.get_path()

    local tracer = ddtrace_conf and ddtrace_conf.tracer or nil
    if tracer == nil then
        kong.log.err("tracer is missing; configure() may have failed")
        return nil
    end

    local start_time_ns = ngx.ctx.KONG_PROCESSING_START * NS_PER_MS
    local root_span = ddtrace.extract_or_create_span(tracer, req.get_header, "kong.request", resource, start_time_ns)
    if root_span == nil then
        kong.log.err("failed to create root span")
        return nil
    end

    root_span:set_service(conf.service_name or ddtrace_conf.service)

    -- Set standard tags
    root_span:set_tag("component", "kong")
    root_span:set_tag("span.kind", "server")

    local url = req.get_scheme() .. "://" .. req.get_host() .. ":" .. req.get_port() .. path
    root_span:set_tag("http.method", method)
    root_span:set_tag("http.url", url)
    root_span:set_tag("http.client_ip", kong.client.get_forwarded_ip())
    root_span:set_tag("http.request.content_length", req.get_header("content-length"))
    root_span:set_tag("http.useragent", req.get_header("user-agent"))
    root_span:set_tag("http.version", req.get_http_version())

    -- Set nginx informational tags
    root_span:set_tag("nginx.version", ngx.config.nginx_version)
    root_span:set_tag("nginx.lua_version", ngx.config.ngx_lua_version)
    root_span:set_tag("nginx.worker_pid", ngx_worker_pid)
    root_span:set_tag("nginx.worker_id", ngx_worker_id)
    root_span:set_tag("nginx.worker_count", ngx_worker_count)

    -- Set kong informational tags
    root_span:set_tag("kong.version", kong.version)
    root_span:set_tag("kong.pdk_version", kong.pdk_version)
    root_span:set_tag("kong.node_id", kong_node_id)

    if kong.configuration then
        root_span:set_tag("kong.role", kong.configuration.role)
        root_span:set_tag("kong.nginx_daemon", kong.configuration.nginx_daemon)
        root_span:set_tag("kong.database", kong.configuration.database)
    end

    local static_tags = conf and conf.static_tags or nil
    if type(static_tags) == "table" then
        for i = 1, #static_tags do
            local tag = static_tags[i]
            root_span:set_tag(tag.name, tag.value)
        end
    end

    return root_span
end

local function access(conf)
    -- Create the root span here because we have no guarantee to be called on the `rewrite` phase.
    local ctx = kong.ctx.plugin
    local access_start_ns = ngx.ctx.KONG_ACCESS_START * NS_PER_MS
    local req = kong.request
    local method = req.get_method()
    local path = req.get_path()
    local resource = method .. " " .. apply_resource_name_rules(path, conf.resource_name_rule)

    local root_span = make_root_span(conf, resource)
    if root_span == nil then
        return
    end

    -- TODO: if KONG_PROXIED then
    local proxy_span = root_span:create_child("kong.proxy", resource, access_start_ns)
    expose_tracing_variables(proxy_span)

    local ok, err = proxy_span:inject(kong.service.request.set_header)
    if not ok then
        kong.log.err("failed to inject ddtrace propagation headers: ", err)
    end

    ctx.request_span = root_span
    ctx.proxy_span = proxy_span
end

local function header_filter(_)
    local ngx_ctx = ngx.ctx
    local end_time_ns = ngx_ctx.KONG_HEADER_FILTER_START * NS_PER_MS

    local ctx = kong.ctx.plugin
    if ctx.proxy_span == nil then
        error('proxy span missing during the "header_filter" phase')
    end

    local span = ctx.proxy_span
    span:set_tag("span.kind", "client")

    local balancer_data = ngx_ctx.balancer_data
    if balancer_data then
        local balancer_tries = balancer_data.tries
        local try_count = balancer_data.try_count

        span:set_tag("peer.hostname", balancer_data.hostname)
        span:set_tag("peer.ip", balancer_data.ip)
        span:set_tag("peer.port", balancer_data.port)
        span:set_tag("kong.balancer.tries", try_count)

        for i = 1, try_count do
            local tag_prefix = fmt("kong.balancer.try-%d.", i)
            local try = balancer_tries[i]
            if i < try_count then
                span:set_tag(tag_prefix .. "error", true)
                span:set_tag(tag_prefix .. "state", try.state)
                span:set_tag(tag_prefix .. "status_code", try.code)
            end
            if try.balancer_latency then
                span:set_tag(tag_prefix .. "latency", try.balancer_latency)
            end
        end
    end

    local service = kong.router.get_service()
    if service and service.id then
        span:set_tag("kong.service", service.id)
        if type(service.name) == "string" then
            span:set_service(service.name)
            span:set_tag("kong.service_name", service.name)
        end
    end

    local route = kong.router.get_route()
    if route then
        if route.id then
            span:set_tag("kong.route", route.id)
        end
        if type(route.name) == "string" then
            span:set_tag("kong.route_name", route.name)
        end
    else
        span:set_tag("kong.route", "none")
    end

    local status_code = kong.response.get_status()
    span:set_tag("http.status_code", status_code)
    if status_code >= 500 then
        span:set_error()
    end

    span:finish(end_time_ns)
    span:free()
end

local function log(conf)
    local ngx_ctx = ngx.ctx
    local end_time_ns = ngx_ctx.KONG_LOG_START * NS_PER_MS

    local ctx = kong.ctx.plugin
    if ctx.request_span == nil then
        error("request span is missing during the log phase")
    end

    local request_span = ctx.request_span

    if header_tags then
        utils.set_http_header_tags(request_span, header_tags, kong.request.get_header, kong.response.get_header)
    end

    if ngx_ctx.authenticated_consumer then
        request_span:set_tag("kong.consumer", ngx_ctx.authenticated_consumer.id)
    end
    if conf and conf.include_credential and ngx_ctx.authenticated_credential then
        request_span:set_tag("kong.credential", ngx_ctx.authenticated_credential.id)
    end

    request_span:finish(end_time_ns)
    request_span:free()

    ctx.proxy_span = nil
    ctx.request_span = nil
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
        kong.log.err("tracing error in DatadogTraceHandler:response: ", message)
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

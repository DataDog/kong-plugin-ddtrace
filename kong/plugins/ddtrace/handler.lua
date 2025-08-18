local new_sampler = require("kong.plugins.ddtrace.sampler").new
local new_trace_agent_writer = require("kong.plugins.ddtrace.agent_writer").new
local new_propagator = require("kong.plugins.ddtrace.propagation").new
local utils = require("kong.plugins.ddtrace.utils")
local time_ns = utils.time_ns
local cjson = require("cjson")

local pcall = pcall
local fmt = string.format
local strsub = string.sub
local btohex = bit.tohex
local regex = ngx.re
local subsystem = ngx.config.subsystem

local DatadogTraceHandler = {
    VERSION = "0.2.3",
    -- We want to run first so that timestamps taken are at start of the phase.
    -- However, it might be useful to finish spans after other plugins have completed
    -- to more accurately represent the request completion time.
    PRIORITY = 100000,
}

-- This cache is keyed on Kong's config object. Setting the mode to weak ensures
-- the keys will get garbage-collected when the config object's lifecycle is completed.
local agent_writer_cache = setmetatable({}, { __mode = "k" })

-- This timer runs in the background to flush traces for all instances of the plugin.
-- Because of the way timers work in lua, this can only be initialized when there's an
-- active request. This gets initialized on the first request this plugin handles.
local propagator
local sampler
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

local function get_agent_writer(conf, agent_url)
    if agent_writer_cache[conf] == nil then
        agent_writer_cache[conf] = new_trace_agent_writer(agent_url, sampler, DatadogTraceHandler.VERSION)
    end
    return agent_writer_cache[conf]
end

local function expose_tracing_variables(span)
    -- Expose traceID and parentID for other plugin to consume and also set an NGINX variable
    -- that can be use for in `log_format` directive for correlation with logs.
    local trace_id = btohex(span.trace_id.high or 0, 16) .. btohex(span.trace_id.low, 16)
    local span_id = btohex(span.span_id, 16)

    -- NOTE: kong.ctx has the same lifetime as the current request.
    local kong_shared = kong.ctx.shared
    kong_shared.datadog_sdk_trace_id = trace_id
    kong_shared.datadog_sdk_span_id = span_id

    -- Set nginx variables
    if ngx.var.datadog_trace_id ~= nil then
        ngx.var.datadog_trace_id = trace_id
    end
    if ngx.var.datadog_span_id ~= nil then
        ngx.var.datadog_span_id = trace_id
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

    sampler = new_sampler(math.ceil(conf.initial_samples_per_second / ngx_worker_count), conf.initial_sample_rate)
    propagator = new_propagator(
        ddtrace_conf.extraction_propagation_styles,
        ddtrace_conf.injection_propagation_styles,
        conf.max_header_size
    )

    if conf and conf.header_tags then
        header_tags = utils.normalize_header_tags(conf.header_tags)
    end
end

local function make_root_span(conf, start_timestamp)
    local req = kong.request
    local method = req.get_method()
    local path = req.get_path()

    local span_options = {
        service = conf.service_name or ddtrace_conf.service,
        name = "kong.request",
        start_us = start_timestamp,
        -- TODO: decrease cardinality of path value
        resource = method .. " " .. apply_resource_name_rules(path, conf.resource_name_rule),
        generate_128bit_trace_ids = conf.generate_128bit_trace_ids,
    }

    local request_span = propagator:extract_or_create_span(req, span_options)

    -- Set datadog tags
    if ddtrace_conf.environment then
        request_span:set_tag("env", ddtrace_conf.environment)
    end
    if ddtrace_conf.version then
        request_span:set_tag("version", ddtrace_conf.version)
    end

    -- TODO: decide about deferring sampling decision until injection or not
    if not request_span.sampling_priority then
        sampler:sample(request_span)
    end

    -- Add metrics
    request_span.metrics["_dd.top_level"] = 1

    -- Set standard tags
    request_span:set_tag("component", "kong")
    request_span:set_tag("span.kind", "server")

    local url = req.get_scheme() .. "://" .. req.get_host() .. ":" .. req.get_port() .. path
    request_span:set_tag("http.method", method)
    request_span:set_tag("http.url", url)
    request_span:set_tag("http.client_ip", kong.client.get_forwarded_ip())
    request_span:set_tag("http.request.content_length", req.get_header("content-length"))
    request_span:set_tag("http.useragent", req.get_header("user-agent"))
    request_span:set_tag("http.version", req.get_http_version())

    -- Set nginx informational tags
    request_span:set_tag("nginx.version", ngx.config.nginx_version)
    request_span:set_tag("nginx.lua_version", ngx.config.ngx_lua_version)
    request_span:set_tag("nginx.worker_pid", ngx_worker_pid)
    request_span:set_tag("nginx.worker_id", ngx_worker_id)
    request_span:set_tag("nginx.worker_count", ngx_worker_count)

    -- Set kong informational tags
    request_span:set_tag("kong.version", kong.version)
    request_span:set_tag("kong.pdk_version", kong.pdk_version)
    request_span:set_tag("kong.node_id", kong_node_id)

    if kong.configuration then
        request_span:set_tag("kong.role", kong.configuration.role)
        request_span:set_tag("kong.nginx_daemon", kong.configuration.nginx_daemon)
        request_span:set_tag("kong.database", kong.configuration.database)
    end

    local static_tags = conf and conf.static_tags or nil
    if type(static_tags) == "table" then
        for i = 1, #static_tags do
            local tag = static_tags[i]
            request_span:set_tag(tag.name, tag.value)
        end
    end

    return request_span
end

local function access(conf)
    -- Create the root span here because we have no guarantee to be called on the `rewrite` phase.
    local now = time_ns() * 1LL
    local access_start = now

    local ctx = kong.ctx.plugin
    local root_span = make_root_span(conf, ngx.ctx.KONG_PROCESSING_START * 1000000LL)

    -- TODO: if KONG_PROXIED then
    local proxy_span = root_span:new_child("kong.proxy", root_span.resource, access_start)
    expose_tracing_variables(proxy_span)

    local request = {
        get_header = kong.request.get_header,
        set_header = kong.service.request.set_header,
    }

    local err = propagator:inject(request, proxy_span)
    if err then
        kong.log.error("Failed to inject trace (id: " .. root_span.trace_id .. "). Reason: " .. err)
    end

    ctx.request_span = root_span
    ctx.proxy_span = proxy_span
end

local function header_filter(_)
    local now = time_ns() * 1LL
    local ngx_ctx = ngx.ctx

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
            span.service_name = service.name
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

    span:finish(now)
end

local function log(conf)
    local now = time_ns() * 1LL
    local ngx_ctx = ngx.ctx

    local ctx = kong.ctx.plugin
    if ctx.request_span == nil then
        error("request span is missing during the log phase")
    end

    local request_span = ctx.request_span
    local agent_writer = get_agent_writer(conf, ddtrace_conf.agent_url)

    local status_code = kong.response.get_status()
    request_span:set_tag("http.status_code", status_code)
    if status_code >= 500 then
        request_span:set_tag("error", true)
        request_span.error = status_code
    end

    if header_tags then
        request_span:set_http_header_tags(header_tags, kong.request.get_header, kong.response.get_header)
    end

    if ngx_ctx.authenticated_consumer then
        request_span:set_tag("kong.consumer", ngx_ctx.authenticated_consumer.id)
    end
    if conf and conf.include_credential and ngx_ctx.authenticated_credential then
        request_span:set_tag("kong.credential", ngx_ctx.authenticated_credential.id)
    end

    request_span:finish(now)
    agent_writer:enqueue_trace({ request_span, ctx.proxy_span })

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

local ddtrace = require("kong.plugins.ddtrace.ddtrace")
local utils = require("kong.plugins.ddtrace.utils")

local pcall = pcall
local subsystem = ngx.config.subsystem
local fmt = string.format
local strsub = string.sub
local regex = ngx.re

local DatadogTraceHandler = {
    VERSION = "0.1.2",
    -- We want to run first so that timestamps taken are at start of the phase.
    -- However, it might be useful to finish spans after other plugins have completed
    -- to more accurately represent the request completion time.
    PRIORITY = 100000,
}

-- Memoize some data attached to traces
local ngx_worker_pid = ngx.worker.pid()
local ngx_worker_id = ngx.worker.id()
local ngx_worker_count = ngx.worker.count()
local kong_node_id = kong.node.get_id()

-- Globals
local initialize_request

-- adds the proxy span to the datadog context, unless it already exists
local function get_or_add_proxy_span(datadog)
    if not datadog.proxy_span then
        local request_span = datadog.request_span
        datadog.proxy_span = request_span:create_child("proxy")
    end
    return datadog.proxy_span
end

-- initialize the request span and datadog context
-- if being called the first time for this request.
-- the new or existing context is retured.
local function get_datadog_context(conf, ctx)
    local datadog = ctx.datadog
    if not datadog then
        initialize_request(conf, ctx)
        datadog = ctx.datadog
    end
    return datadog
end


-- check if a datadog context exists.
-- used in the log phase to ensure we captured tracing data.
local function has_datadog_context(ctx)
    if ctx.datadog then
        return true
    end
    return false
end

local function tag_with_service_and_route(span)
    local service = kong.router.get_service()
    if service and service.id then
        span:set_tag("kong.service", service.id)
        if type(service.name) == "string" then
            -- span.service_name = service.name
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

local header_tags
local tracer

local function build_agent_url(conf)
    -- traces_endpoint is determined by the configuration with this
    -- order of precedence:
    -- - use trace_agent_url if set
    -- - use agent_host:agent_port if agent_host is set
    -- - use agent_endpoint if set but warn that it is deprecated
    -- - if nothing is set, default to http://localhost:8126/v0.4/traces
    if conf.trace_agent_url then
      return conf.trace_agent_url
    end

    local host = conf.agent_host or "localhost"
    local port = conf.trace_agent_port or "8126"
    local agent_url = string.format("http://%s:%s", host, port)
    kong.log.notice("traces will be sent to the agent at " .. agent_url)
    return agent_url
end

if subsystem == "http" then
    initialize_request = function(conf, ctx)
        -- TODO: Support Kong 3.5.x `plugin:configure`
        if not tracer then
          local config = {
            ["service"] = conf and conf.service_name or "kong"
          }
          if conf.environment then
              config.env = conf.environment
          end
          if conf.version then
              config.version = conf.version
          end
          if conf.trace_agent_url or conf.agent_host or conf.agent_endpoint then
              config.agent_url = build_agent_url(conf)
          end

          tracer = ddtrace.make_tracer(config)
        end

        if not header_tags and (conf and conf.header_tags) then
            header_tags = utils.normalize_header_tags(conf.header_tags)
        end

        local req = kong.request

        local method = req.get_method()
        local path = req.get_path()

        local header_extractor = function(key)
          return req.get_header(key)
        end

        local span_options = {
            name = "kong.plugin.ddtrace",
            -- TODO: decrease cardinality of path value
            resource = method .. " " .. apply_resource_name_rules(path, conf.resource_name_rule)
        }

        local request_span = tracer:extract_or_create_span(header_extractor, span_options)

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

        local http_version = req.get_http_version()
        local protocol = http_version and 'HTTP/'..http_version or nil
        if protocol then
            request_span:set_tag("http.protocol", protocol)
        end

        request_span:set_tag("ip", kong.client.get_forwarded_ip())
        request_span:set_tag("port", kong.client.get_forwarded_port())
        request_span:set_tag("lc", "kong")
        request_span:set_tag("http.method", method)
        request_span:set_tag("http.host", req.get_host())
        request_span:set_tag("http.path", path)

        local static_tags = conf and conf.static_tags or nil
        if type(static_tags) == "table" then
            for i = 1, #static_tags do
                local tag = static_tags[i]
                request_span:set_tag(tag.name, tag.value)
            end
        end

        ctx.datadog = {
            request_span = request_span,
            proxy_span = nil,
            header_filter_finished = false,
        }
    end

    function DatadogTraceHandler:rewrite(conf)
        local ok, message = pcall(function() self:rewrite_p(conf) end)
        if not ok then
            kong.log.err("tracing error in DatadogTraceHandler:rewrite: " .. message)
        end
    end

    function DatadogTraceHandler:rewrite_p(conf)
        -- TODO: reconsider tagging rewrite-start timestamps on request spans
    end


    function DatadogTraceHandler:access(conf)
        local ok, message = pcall(function() self:access_p(conf) end)
        if not ok then
            kong.log.err("tracing error in DatadogTraceHandler:access: " .. message)
        end
    end

    function DatadogTraceHandler:access_p(conf)
        local datadog = get_datadog_context(conf, kong.ctx.plugin)

        local proxy_span = get_or_add_proxy_span(datadog)

        local injector = function(key, value)
          kong.service.request.set_header(key, value)
        end

        proxy_span:inject(injector)
    end

    function DatadogTraceHandler:header_filter(conf) -- luacheck: ignore 212
        local ok, message = pcall(function() self:header_filter_p(conf) end)
        if not ok then
            kong.log.err("tracing error in DatadogTraceHandler:header_filter: " .. message)
        end
    end

    function DatadogTraceHandler:header_filter_p(conf) -- luacheck: ignore 212
        local datadog = get_datadog_context(conf, kong.ctx.plugin)

        get_or_add_proxy_span(datadog)
    end


    function DatadogTraceHandler:body_filter(conf) -- luacheck: ignore 212
        local ok, message = pcall(function() self:body_filter_p(conf) end)
        if not ok then
            kong.log.err("tracing error in DatadogTraceHandler:body_filter: " .. message)
        end
    end

    function DatadogTraceHandler:body_filter_p(conf) -- luacheck: ignore 212
        local datadog = get_datadog_context(conf, kong.ctx.plugin)

        -- Finish header filter when body filter starts
        if not datadog.header_filter_finished then
            datadog.header_filter_finished = true
        end
    end

    -- TODO: consider handling stream subsystem
end

function DatadogTraceHandler:log(conf) -- luacheck: ignore 212
    local ok, message = pcall(function() self:log_p(conf) end)
    if not ok then
        kong.log.err("tracing error in DatadogTraceHandler:log: " .. message)
    end
end

function DatadogTraceHandler:log_p(conf) -- luacheck: ignore 212
    if not has_datadog_context(kong.ctx.plugin) then
        return
    end

    local datadog = get_datadog_context(conf, kong.ctx.plugin)
    local ngx_ctx = ngx.ctx
    local request_span = datadog.request_span
    local proxy_span = get_or_add_proxy_span(datadog)

    -- TODO: consider handling stream subsystem
    local balancer_data = ngx_ctx.balancer_data
    if balancer_data then
        local balancer_tries = balancer_data.tries
        local try_count = balancer_data.try_count

        proxy_span:set_tag("peer.hostname", balancer_data.hostname)
        proxy_span:set_tag("peer.ip", balancer_data.ip)
        proxy_span:set_tag("peer.port", balancer_data.port)
        proxy_span:set_tag("kong.balancer.tries", try_count)

        for i = 1, try_count do
            local tag_prefix = fmt("kong.balancer.try-%d.", i)
            local try = balancer_tries[i]
            if i < try_count then
                proxy_span:set_tag(tag_prefix .. "error", true)
                proxy_span:set_tag(tag_prefix .. "state", try.state)
                proxy_span:set_tag(tag_prefix .. "status_code", try.code)
            end
            if try.balancer_latency then
                proxy_span:set_tag(tag_prefix .. "latency", try.balancer_latency)
            end
        end
    end

    if subsystem == "http" then
        local status_code = kong.response.get_status()
        request_span:set_tag("http.status_code", status_code)
        -- TODO: allow user to define additional status codes that are treated as errors.
        if status_code >= 500 then
            request_span:set_error(true)
        end

        if header_tags then
          request_span:set_http_header_tags(header_tags, kong.request.get_header, kong.response.get_header)
        end
    end
    if ngx_ctx.authenticated_consumer then
        request_span:set_tag("kong.consumer", ngx_ctx.authenticated_consumer.id)
    end
    if conf and conf.include_credential and ngx_ctx.authenticated_credential then
        request_span:set_tag("kong.credential", ngx_ctx.authenticated_credential.id)
    end
    tag_with_service_and_route(proxy_span)

    proxy_span:finish()
    request_span:finish()
end


return DatadogTraceHandler

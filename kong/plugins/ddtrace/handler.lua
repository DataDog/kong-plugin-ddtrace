local new_sampler = require "kong.plugins.ddtrace.sampler".new
local new_trace_agent_writer = require "kong.plugins.ddtrace.agent_writer".new
local new_span = require "kong.plugins.ddtrace.span".new
local propagator = require "kong.plugins.ddtrace.propagation"

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

-- This cache is keyed on Kong's config object. Setting the mode to weak ensures
-- the keys will get garbage-collected when the config object's lifecycle is completed.
local agent_writer_cache = setmetatable({}, { __mode = "k" })
local function flush_agent_writers()
    for conf, agent_writer in pairs(agent_writer_cache) do
        local ok, err = agent_writer:flush()
        if not ok then
            kong.log.err("agent_writer error ", err)
        end
    end
end

-- This timer runs in the background to flush traces for all instances of the plugin.
-- Because of the way timers work in lua, this can only be initialized when there's an
-- active request. This gets initialized on the first request this plugin handles.
local agent_writer_timer
local sampler

local ngx_now            = ngx.now


-- Memoize some data attached to traces
local ngx_worker_pid = ngx.worker.pid()
local ngx_worker_id = ngx.worker.id()
local ngx_worker_count = ngx.worker.count()
-- local kong_cluster_id = kong.cluster.get_id()
local kong_node_id = kong.node.get_id()


-- ngx.now in microseconds
local function ngx_now_mu()
    return ngx_now() * 1000000
end


local function get_agent_writer(conf)
    if agent_writer_cache[conf] == nil then
        if conf.host then
            local host = conf.host
            local port = conf.port
            local version = conf.version
            conf.agent_endpoint = string.format("http://%s:%d/%s/traces", host, port, version)
        end
        agent_writer_cache[conf] = new_trace_agent_writer(conf.agent_endpoint, sampler, DatadogTraceHandler.VERSION)
    end
    return agent_writer_cache[conf]
end


local function tag_with_service_and_route(span)
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
end


-- adds the proxy span to the datadog context, unless it already exists
local function get_or_add_proxy_span(datadog, timestamp)
    if not datadog.proxy_span then
        local request_span = datadog.request_span
        datadog.proxy_span = request_span:new_child(
        request_span.name,
        "proxy",
        timestamp
        )
    end
    return datadog.proxy_span
end


local initialize_request


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

if subsystem == "http" then
    initialize_request = function(conf, ctx)
        -- one-time setup of the timer and sampler, only on the first request
        if not agent_writer_timer then
            agent_writer_timer = ngx.timer.every(2.0, flush_agent_writers)
        end
        if not sampler then
            -- each worker gets a chunk of the overall samples_per_second value as their per-second limit
            -- though it is rounded up. This can be more-precisely allocated if necessary
            sampler = new_sampler(math.ceil(conf.initial_samples_per_second / ngx_worker_count), conf.initial_sample_rate)
        end

        local req = kong.request
        local req_headers = req.get_headers()

        local trace_id, parent_id, sampling_priority, origin, err = propagator.extract(req_headers)
        -- propagation errors are logged after the span is created

        local method = req.get_method()
        local path = req.get_path()

        local ngx_ctx = ngx.ctx
        local rewrite_start_ns = ngx_ctx.KONG_PROCESSING_START * 1000000LL

        local request_span = new_span(
        conf and conf.service_name or "kong",
        "kong.plugin.ddtrace",
        method .. " " .. apply_resource_name_rules(path, conf.resource_name_rule), -- TODO: decrease cardinality of path value
        trace_id,
        nil,
        parent_id,
        rewrite_start_ns,
        sampling_priority,
        origin)

        -- Set datadog tags
        if conf and conf.environment then
            request_span:set_tag("env", conf.environment)
        end

        -- TODO: decide about deferring sampling decision until injection or not
        if not sampling_priority then
            sampler:sample(request_span)
        end

        -- Add metrics
        request_span.metrics["_dd.top_level"] = 1

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

        request_span.ip = kong.client.get_forwarded_ip()
        request_span.port = kong.client.get_forwarded_port()

        request_span:set_tag("lc", "kong")
        request_span:set_tag("http.method", method)
        request_span:set_tag("http.host", req.get_host())
        request_span:set_tag("http.path", path)
        if protocol then
            request_span:set_tag("http.protocol", protocol)
        end

        local static_tags = conf and conf.static_tags or nil
        if type(static_tags) == "table" then
            for i = 1, #static_tags do
                local tag = static_tags[i]
                request_span:set_tag(tag.name, tag.value)
            end
        end

        if err then
            request_span:set_tag("ddtrace.propagation_error", err)
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
        local ngx_ctx = ngx.ctx

        local access_start =
        ngx_ctx.KONG_ACCESS_START and ngx_ctx.KONG_ACCESS_START * 1000
        or ngx_now_mu()
        local proxy_span = get_or_add_proxy_span(datadog, access_start * 1000LL)

        propagator.inject(proxy_span)
    end

    function DatadogTraceHandler:header_filter(conf) -- luacheck: ignore 212
        local ok, message = pcall(function() self:header_filter_p(conf) end)
        if not ok then
            kong.log.err("tracing error in DatadogTraceHandler:header_filter: " .. message)
        end
    end

    function DatadogTraceHandler:header_filter_p(conf) -- luacheck: ignore 212
        local datadog = get_datadog_context(conf, kong.ctx.plugin)
        local ngx_ctx = ngx.ctx
        local header_filter_start_mu =
        ngx_ctx.KONG_HEADER_FILTER_STARTED_AT and ngx_ctx.KONG_HEADER_FILTER_STARTED_AT * 1000
        or ngx_now_mu()

        get_or_add_proxy_span(datadog, header_filter_start_mu * 1000LL)
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

    local now_mu = ngx_now_mu()
    local datadog = get_datadog_context(conf, kong.ctx.plugin)
    local ngx_ctx = ngx.ctx
    local request_span = datadog.request_span
    local proxy_span = get_or_add_proxy_span(datadog, now_mu * 1000LL)
    local agent_writer = get_agent_writer(conf)

    local proxy_finish_mu =
    ngx_ctx.KONG_BODY_FILTER_ENDED_AT and ngx_ctx.KONG_BODY_FILTER_ENDED_AT * 1000
    or now_mu
    local request_finish_mu =
    ngx_ctx.KONG_LOG_START and ngx_ctx.KONG_LOG_START * 1000
    or now_mu

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
            request_span:set_tag("error", true)
            request_span.error = status_code
        end
    end
    if ngx_ctx.authenticated_consumer then
        request_span:set_tag("kong.consumer", ngx_ctx.authenticated_consumer.id)
    end
    if conf and conf.include_credential and ngx_ctx.authenticated_credential then
        request_span:set_tag("kong.credential", ngx_ctx.authenticated_credential.id)
    end
    tag_with_service_and_route(proxy_span)

    proxy_span:finish(proxy_finish_mu * 1000LL)
    request_span:finish(request_finish_mu * 1000LL)
    agent_writer:add({request_span, proxy_span})
end


return DatadogTraceHandler

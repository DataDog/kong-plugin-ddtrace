local new_trace_agent_writer = require "kong.plugins.ddtrace.agent_writer".new
local new_span = require "kong.plugins.ddtrace.span".new
local utils = require "kong.tools.utils"
local propagator = require "kong.plugins.ddtrace.propagation"

local subsystem = ngx.config.subsystem
local rand_bytes = utils.get_rand_bytes

local DatadogTraceHandler = {
  VERSION = "0.0.1",
  -- We want to run first so that timestamps taken are at start of the phase.
  -- However, it might be useful to finish spans after other plugins have completed
  -- to more accurately represent the request completion time.
  PRIORITY = 100000,
}

-- This cache is keyed on Kong's config object. Setting the mode to weak ensures
-- the keys will get garbage-collected when the config object's lifecycle is completed.
local agent_writer_cache = setmetatable({}, { __mode = "k" })

local ngx_now            = ngx.now


-- ngx.now in microseconds
local function ngx_now_mu()
    return ngx_now() * 1000000
end


-- ngx.req.start_time in nanoseconds
local function ngx_req_start_time_mu()
    return ngx.ctx.KONG_REWRITE_START * 1000000LL
end


local function get_agent_writer(conf)
  if agent_writer_cache[conf] == nil then
    agent_writer_cache[conf] = new_trace_agent_writer(conf.agent_endpoint)
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


local function timer_log(premature, agent_writer)
  if premature then
    return
  end

  local ok, err = agent_writer:flush()
  if not ok then
    kong.log.err("agent_writer error ", err)
    return
  end
end


local initialize_request


local function get_datadog_context(conf, ctx)
  local datadog = ctx.datadog
  if not datadog then
    initialize_request(conf, ctx)
    datadog = ctx.datadog
  end
  return datadog
end


local function has_datadog_context(ctx)
    if ctx.datadog then
        return true
    end
    return false
end


if subsystem == "http" then
  initialize_request = function(conf, ctx)
    local req = kong.request
    local req_headers = req.get_headers()

    local trace_id, parent_id, sampling_priority, origin, err = propagator.extract(req_headers)
    if err then
        -- TODO: log the error detail(s)
    end

    local method = req.get_method()

    if not sampling_priority then
      -- TODO: actual sampling decision based on rules, rates and fallback to agent rates
      sampling_priority = 1
    end

    local ngx_ctx = ngx.ctx
    local rewrite_start_ns = ngx_ctx.KONG_PROCESSING_START * 1000000LL

    local request_span = new_span(
      conf.service or "kong",
      "kong.plugin.ddtrace",
      req.get_method(),
      trace_id,
      nil,
      parent_id,
      rewrite_start_ns,
      sampling_priority,
      origin)

    local http_version = req.get_http_version()
    local protocol = http_version and 'HTTP/'..http_version or nil

    request_span.ip = kong.client.get_forwarded_ip()
    request_span.port = kong.client.get_forwarded_port()

    request_span:set_tag("lc", "kong")
    request_span:set_tag("http.method", method)
    request_span:set_tag("http.host", req.get_host())
    request_span:set_tag("http.path", req.get_path())
    if protocol then
      request_span:set_tag("http.protocol", protocol)
    end

    local static_tags = conf.static_tags
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


  function DatadogTraceHandler:rewrite(conf) -- luacheck: ignore 212
    local datadog = get_datadog_context(conf, kong.ctx.plugin)
    local ngx_ctx = ngx.ctx
    -- note: rewrite is logged on the request_span, not on the proxy span
    local rewrite_start_mu =
      ngx_ctx.KONG_REWRITE_START and ngx_ctx.KONG_REWRITE_START * 1000
      or ngx_now_mu()
    datadog.request_span:set_tag("krs", rewrite_start_mu * 1000LL)
  end


  function DatadogTraceHandler:access(conf) -- luacheck: ignore 212
    local datadog = get_datadog_context(conf, kong.ctx.plugin)
    local ngx_ctx = ngx.ctx

    local access_start =
      ngx_ctx.KONG_ACCESS_START and ngx_ctx.KONG_ACCESS_START * 1000
      or ngx_now_mu()
    local proxy_span = get_or_add_proxy_span(datadog, access_start * 1000LL)

    propagator.inject(proxy_span)
  end


  function DatadogTraceHandler:header_filter(conf) -- luacheck: ignore 212
    local datadog = get_datadog_context(conf, kong.ctx.plugin)
    local ngx_ctx = ngx.ctx
    local header_filter_start_mu =
      ngx_ctx.KONG_HEADER_FILTER_STARTED_AT and ngx_ctx.KONG_HEADER_FILTER_STARTED_AT * 1000
      or ngx_now_mu()

    local proxy_span = get_or_add_proxy_span(datadog, header_filter_start_mu * 1000LL)
    proxy_span:set_tag("khs", header_filter_start_mu)
  end


  function DatadogTraceHandler:body_filter(conf) -- luacheck: ignore 212
    local datadog = get_datadog_context(conf, kong.ctx.plugin)

    -- Finish header filter when body filter starts
    if not datadog.header_filter_finished then
      local now_mu = ngx_now_mu()

      datadog.proxy_span:set_tag("khf", now_mu)
      datadog.header_filter_finished = true
      datadog.proxy_span:set_tag("kbs", now_mu)
    end
  end

-- TODO: consider handling stream subsystem
end


function DatadogTraceHandler:log(conf) -- luacheck: ignore 212
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

  if ngx_ctx.KONG_REWRITE_START and ngx_ctx.KONG_REWRITE_TIME then
    -- note: rewrite is logged on the request span, not on the proxy span
    local rewrite_finish_mu = (ngx_ctx.KONG_REWRITE_START + ngx_ctx.KONG_REWRITE_TIME) * 1000
    datadog.request_span:set_tag("krf", rewrite_finish_mu)
  end

  if subsystem == "http" then
    -- annotate access_start here instead of in the access phase
    -- because the plugin access phase is skipped when dealing with
    -- requests which are not matched by any route
    -- but we still want to know when the access phase "started"
    local access_start_mu =
      ngx_ctx.KONG_ACCESS_START and ngx_ctx.KONG_ACCESS_START * 1000
      or proxy_span.timestamp
    proxy_span:set_tag("kas", access_start_mu)

    local access_finish_mu =
      ngx_ctx.KONG_ACCESS_ENDED_AT and ngx_ctx.KONG_ACCESS_ENDED_AT * 1000
      or proxy_finish_mu
    proxy_span:set_tag("kaf", access_finish_mu)

    if not datadog.header_filter_finished then
      proxy_span:set_tag("khf", now_mu)
      datadog.header_filter_finished = true
    end

    proxy_span:set_tag("kbf", now_mu)
  end
  -- TODO: consider handling stream subsystem

  -- local balancer_data = ngx_ctx.balancer_data
  -- if balancer_data then
  --   local balancer_tries = balancer_data.tries
  --   for i = 1, balancer_data.try_count do
  --     local try = balancer_tries[i]
  --     local resource = fmt("balancer try %d", i)
  --     local span = request_span:new_child(request_span.name, resource, try.balancer_start * 1000LL)
  --     span.ip = try.ip
  --     span.port = try.port

  --     span:set_tag("kong.balancer.try", i)
  --     if i < balancer_data.try_count then
  --       span:set_tag("error", true)
  --       span:set_tag("kong.balancer.state", try.state)
  --       span:set_tag("http.status_code", try.code)
  --     end

  --     tag_with_service_and_route(span)

  --     if try.balancer_latency ~= nil then
  --       span:finish((try.balancer_start + try.balancer_latency) * 1000LL)
  --     else
  --       span:finish(now_mu * 1000LL)
  --     end
  --     agent_writer:add(span)
  --   end
  --   proxy_span:set_tag("peer.hostname", balancer_data.hostname) -- could be nil
  --   proxy_span.ip   = balancer_data.ip
  --   proxy_span.port = balancer_data.port
  -- end

  if subsystem == "http" then
    request_span:set_tag("http.status_code", kong.response.get_status())
  end
  if ngx_ctx.authenticated_consumer then
    request_span:set_tag("kong.consumer", ngx_ctx.authenticated_consumer.id)
  end
  if conf.include_credential and ngx_ctx.authenticated_credential then
    request_span:set_tag("kong.credential", ngx_ctx.authenticated_credential.id)
  end
  request_span:set_tag("kong.node.id", kong.node.get_id())

  tag_with_service_and_route(proxy_span)

  proxy_span:finish(proxy_finish_mu * 1000LL)
  request_span:finish(request_finish_mu * 1000LL)
  agent_writer:add({request_span, proxy_span})

  local ok, err = ngx.timer.at(0, timer_log, agent_writer)
  if not ok then
    kong.log.err("failed to create timer: ", err)
  end
end


return DatadogTraceHandler

-- LLM usage and cost metrics for requests proxied by Kong's AI Proxy plugins
-- (ai-proxy, and ai-proxy-advanced where it shares their request state).
--
-- For each client request the AI proxy handles, this module records:
-- - one provider attempt (gen_ai.client.provider_attempt@0.1.0, and
--   trajectory.gen_ai.client.token_breakdown@0.1.0 when usage is known): the
--   request Kong sent to the model provider, its duration, token usage, cache
--   reads and writes, and the cost Kong estimated for it;
-- - one gateway request (trajectory.gen_ai.gateway.request@0.1.0): the cost
--   Kong estimated for the client's request.
--
-- Token counts are read from the provider's own response: the body of a
-- buffered response, or the events of a stream as they pass through. When
-- the provider reported none, the counts Kong computed are used and marked
-- estimated. Costs are Kong's, from the model's configured input_cost and
-- output_cost. Prompts, responses and keys are never read into metrics: only
-- the usage object, the model and the service tier of a response are kept.
--
-- The metrics are sent to the Datadog Agent over DogStatsD.
--
-- Reading provider usage, the metric profiles, the Datadog series and their
-- DogStatsD encoding, provider names, error types and provider ids are
-- libdatadog's (libdd-ai-usage-ffi), so that every gateway sends the same
-- series for the same response. This module only gathers what Kong knows.

local usage_ffi = require("kong.plugins.ddtrace.ai_usage_ffi")

local ngx = ngx
local kong = kong
local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local str_find = string.find

local _M = {}

-- The metrics sent, the same as the LiteLLM integration's. The profiles
-- define more, which can be added here later.
local DEFAULT_METRICS = {
    ["gen_ai.client.inference.duration"] = true,
    ["gen_ai.client.operation.duration"] = true,
    ["gen_ai.client.inference.usage.input_tokens"] = true,
    ["gen_ai.client.inference.usage.output_tokens"] = true,
    ["gen_ai.client.inference.usage.cache_read.input_tokens"] = true,
    ["gen_ai.client.inference.usage.cache_write.input_tokens"] = true,
    ["trajectory.gen_ai.client.inference.usage.cost"] = true,
    ["trajectory.gen_ai.gateway.request.estimated_cost"] = true,
}
_M.DEFAULT_METRICS = DEFAULT_METRICS

-- Providers whose streamed and buffered counts Kong reads from the
-- provider's response rather than estimating them.
local KONG_COUNTS_REPORTED = {
    cohere = true,
    llama2 = true,
    anthropic = true,
    gemini = true,
    bedrock = true,
}

local OPT_IN_PROVIDER_IDS = {
    provider_account = "trajectory.request.provider_account_id",
    project = "trajectory.request.project_id",
}

-- Request documents are projected into a per-worker batch of points (one per
-- counter series, one per histogram sample) until the next send. The timer
-- sends every flush interval, and a batch that reaches the high-water mark is
-- sent at once by a zero-delay timer, so the rate a worker can carry does not
-- depend on the interval. The library bounds the batch: a memory ceiling, of
-- which the 20% above the high-water mark only has to hold what arrives
-- before that timer runs. A document over it is dropped whole, counted and
-- warned about; that happens only when sends cannot keep up (no timer can
-- run, or the worker is starved).
local MAX_BATCH_POINTS = 100000
local HIGH_WATER_FRACTION = 0.8
-- A warning about dropped documents is logged at most this often.
local DROP_WARN_INTERVAL = 60
-- A buffered response larger than this is not decoded.
local MAX_BODY_BYTES = 16 * 1024 * 1024

local function enabled_tags(conf)
    local tags = {}
    for _, tag in ipairs(conf.ai_usage_metrics_tags or {}) do
        tags[tag] = true
    end
    return tags
end

-- The AI proxy's request state, when an AI proxy plugin handles the request.
local function ai_state()
    local namespaced = ngx.ctx.ai_namespaced_ctx
    if type(namespaced) ~= "table" then
        return nil
    end
    local request = namespaced["normalize-request"]
    if type(request) ~= "table" or type(request.model) ~= "table" then
        return nil
    end
    return request, namespaced["_global"] or {}
end

local function count(value)
    if type(value) == "number" and value >= 0 and value == math.floor(value) then
        return value
    end
    return nil
end

local function string_value(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function provider_name(model)
    local provider = model.provider
    if type(provider) ~= "string" then
        return nil
    end
    if provider == "gemini" then
        local options = type(model.options) == "table" and model.options.gemini
        if type(options) == "table" and (options.api_endpoint or options.project_id) then
            provider = "vertex_ai"
        end
    end
    return usage_ffi.provider_name(provider)
end

-- The operation of a route type, or of a passthrough (preserve) route's
-- upstream path.
local ROUTE_OPERATIONS = {
    ["llm/v1/chat"] = "chat",
    ["llm/v1/responses"] = "chat",
    ["llm/v1/completions"] = "text_completion",
    ["llm/v1/embeddings"] = "embeddings",
}

local function operation_name(route_type)
    if route_type == "preserve" then
        return usage_ffi.operation_name(ngx.var.upstream_uri or kong.request.get_path() or "")
    end
    return ROUTE_OPERATIONS[route_type]
end

-- The error.type of a request that did not end in a 200. Kong got no
-- response from the provider when it has no status or made the response
-- itself.
local function error_type(status, source)
    local no_response = status == nil or source == "error"
    return usage_ffi.error_type_for_failure(status or tonumber(ngx.var.upstream_status), no_response, false)
end

-- Usage from a provider response

-- Feed a stream's chunks to the library as they pass.
local function feed_stream(state, chunk)
    if not state.stream_reader then
        state.stream_reader = usage_ffi.new_stream("auto", state.embeddings)
    end
    if state.stream_reader then
        state.stream_reader:feed(chunk)
    end
end

local function finish_stream(state)
    local reader = state.stream_reader
    if reader then
        state.stream_reader = nil
        state.response = reader:finish()
    end
end

local function read_buffered_body(state)
    if not ngx.ctx.buffered_proxying then
        return
    end
    local ok, body = pcall(kong.service.response.get_raw_body)
    if not ok or type(body) ~= "string" or #body == 0 or #body > MAX_BODY_BYTES then
        return
    end
    if state.gzip then
        local inflated
        ok, inflated = pcall(function()
            return require("kong.tools.gzip").inflate_gzip(body)
        end)
        if not ok or type(inflated) ~= "string" then
            return
        end
        body = inflated
    end
    state.response = usage_ffi.parse_provider_response("auto", state.embeddings, body)
end

-- Kong's own counts, for a provider whose response carried none.
local function kong_usage_fields(embeddings)
    local metrics = ngx.ctx.ai_llm_metrics
    if type(metrics) ~= "table" then
        return {}
    end
    -- Kong counts a side it never saw as 0: that is not an observation.
    local input = count(metrics.llm_prompt_tokens_count)
    local output = count(metrics.llm_completion_tokens_count)
    if input == 0 then
        input = nil
    end
    if output == 0 then
        output = nil
    end
    if input == nil and output == nil then
        return {}
    end
    local fields = { input_tokens = input, input_basis = "includes_cache" }
    if not embeddings then
        fields.output_tokens = output
        fields.output_basis = "includes_reasoning"
    end
    return fields
end

-- Writer

-- The batch of this worker, sent by a timer.
local batch = assert(usage_ffi.new_batch())
local writer = { started = false, early_pending = false }
-- Limits of the batch, in points.
local limits = {}
_M.limits = limits

-- Bound the batch to max_points, and send it early at high_water points (80%
-- of the bound by default). Tests lower them.
function _M.set_limits(max_points, high_water)
    limits.max_points = max_points
    limits.high_water = high_water or math.floor(max_points * HIGH_WATER_FRACTION)
    batch:set_limits(max_points, limits.high_water)
end
_M.set_limits(MAX_BATCH_POINTS)

-- Documents dropped since the last warning.
local drops = { pending = 0, total = 0, warned_at = nil }
_M.drops = drops

-- An email address, the one form of consumer name that is known to be a
-- person rather than a service.
local function person(value)
    value = string_value(value)
    if value and usage_ffi.is_person_identifier(value) then
        return value
    end
    return nil
end

local function send_datagrams(datagrams, host, port)
    local sock = ngx.socket.udp()
    local ok, err = sock:setpeername(host, port)
    if not ok then
        kong.log.warn("ddtrace: cannot send AI usage metrics to ", host, ":", tostring(port), ": ", err)
        return
    end
    -- The library packed the lines into datagrams small enough to cross a
    -- network without IP fragmentation, which can drop them on the way.
    local dropped, last_err = 0, nil
    for _, datagram in ipairs(datagrams) do
        local sent, send_err = sock:send(datagram)
        if not sent then
            dropped = dropped + 1
            last_err = send_err
        end
    end
    sock:close()
    if dropped > 0 then
        -- Once per flush at most: the Agent being down or not listening must
        -- not lose metrics silently.
        kong.log.warn(
            "ddtrace: sending AI usage metrics to ",
            host,
            ":",
            tostring(port),
            " failed (",
            tostring(last_err),
            "); ",
            dropped,
            " datagrams dropped"
        )
    end
end

-- Warn about the documents dropped since the last warning, at most once per
-- DROP_WARN_INTERVAL.
local function warn_drops(now)
    local dropped = batch:take_dropped()
    drops.pending = drops.pending + dropped
    drops.total = drops.total + dropped
    if drops.pending == 0 or (drops.warned_at and now - drops.warned_at < DROP_WARN_INTERVAL) then
        return
    end
    kong.log.warn(
        "ddtrace: AI usage metrics buffer full (",
        limits.max_points,
        " points); ",
        drops.pending,
        " documents dropped since the last warning, ",
        drops.total,
        " in all"
    )
    drops.pending = 0
    drops.warned_at = now
end

local function flush()
    warn_drops(ngx.now())
    if batch:is_empty() then
        return
    end
    local datagrams, err = batch:take_dogstatsd("", usage_ffi.UDP_MAX_PAYLOAD)
    if not datagrams then
        kong.log.err("ddtrace: cannot encode AI usage metrics: ", err)
        return
    end
    if err and err > 0 then
        -- Lines longer than a datagram, which the Agent would refuse.
        kong.log.warn("ddtrace: ", err, " AI usage metric lines over ", usage_ffi.UDP_MAX_PAYLOAD, " bytes dropped")
    end
    send_datagrams(datagrams, writer.host, writer.port)
end
_M.flush = flush

local function on_timer(premature)
    local ok, err = pcall(flush)
    if not ok then
        kong.log.err("ddtrace: failed to send AI usage metrics: ", err)
    end
    if premature then
        return
    end
end

local function on_early_timer(premature)
    writer.early_pending = false
    on_timer(premature)
end

-- Send the batch now, off the request path, once it reaches the high-water
-- mark. When no timer can be created, the next request tries again.
local function flush_if_full()
    if writer.early_pending or not writer.started or not batch:is_full() then
        return
    end
    local ok, err = ngx.timer.at(0, on_early_timer)
    if not ok then
        kong.log.debug("ddtrace: cannot schedule an early AI usage metrics send: ", err)
        return
    end
    writer.early_pending = true
end

local function ensure_writer(target)
    writer.host = target.host
    writer.port = target.port
    if writer.started then
        return
    end
    local ok, err = ngx.timer.every(target.interval, on_timer)
    if not ok then
        kong.log.err("ddtrace: cannot start the AI usage metrics timer: ", err)
        return
    end
    writer.started = true
end

-- Test hook: the points waiting in the batch.
function _M.buffered_points()
    return batch:len()
end

-- Test hook: the DogStatsD lines recorded so far, sorted; the batch is
-- emptied.
function _M.take_lines()
    local lines = {}
    for _, datagram in ipairs(batch:take_dogstatsd("", 65536) or {}) do
        for line in datagram:gmatch("[^\n]+") do
            lines[#lines + 1] = line
        end
    end
    table.sort(lines)
    return lines
end

local PROFILES = {
    provider_attempt = "gen_ai.client.provider_attempt@0.1.0",
    token_breakdown = "trajectory.gen_ai.client.token_breakdown@0.1.0",
    gateway_request = "trajectory.gen_ai.gateway.request@0.1.0",
}

local METRIC_NAMES = {}
for name in pairs(DEFAULT_METRICS) do
    METRIC_NAMES[#METRIC_NAMES + 1] = name
end
table.sort(METRIC_NAMES)
-- Set once on the batch, so that documents leave the list out. A library
-- that does not know them is the wrong version: the plugin does not load.
do
    local ok, err = batch:set_metrics(METRIC_NAMES)
    if not ok then
        error("ddtrace: libdd-ai-usage-ffi refused the AI usage metric list: " .. tostring(err))
    end
end

-- Phases

-- header_filter: this plugin runs before the AI proxy's own filters, so the
-- provider's status and headers are as it sent them.
function _M.header_filter(conf)
    if not conf.ai_usage_metrics_enabled then
        return
    end
    local request, global = ai_state()
    if not request then
        return
    end
    local response = kong.service.response
    local content_type = response.get_header("Content-Type") or ""
    local state = {
        status = response.get_status(),
        source = kong.response.get_source(),
        stream = global.stream_mode == true,
        sse = str_find(content_type, "text/event-stream", 1, true) ~= nil,
        gzip = response.get_header("Content-Encoding") == "gzip",
        embeddings = operation_name(request.route_type) == "embeddings",
    }
    local tags = enabled_tags(conf)
    if tags.provider_account or tags.project then
        -- The library reads the account and project from the headers it
        -- names for the provider, and the account a Bedrock model ARN names.
        -- A buffered response's get_headers() cannot be iterated, so each
        -- header is fetched.
        local provider = provider_name(request.model)
        if provider then
            local headers = {}
            for _, name in ipairs(usage_ffi.provider_id_headers(provider)) do
                headers[name] = response.get_header(name)
            end
            state.provider_ids = usage_ffi.provider_ids(provider, headers, { request.model.name })
        end
    end
    kong.ctx.plugin.ai_usage = state
end

-- body_filter: read a stream's usage events as they pass, and note when the
-- response ends.
function _M.body_filter(_)
    local state = kong.ctx.plugin.ai_usage
    if not state then
        return
    end
    if state.sse and state.status == 200 and not state.gzip and not ngx.ctx.buffered_proxying then
        local chunk = ngx.arg[1]
        if type(chunk) == "string" and #chunk > 0 then
            feed_stream(state, chunk)
        end
    end
    if ngx.arg[2] then
        finish_stream(state)
        ngx.update_time()
        state.ended_at = ngx.now()
    end
end

local function deployment_attributes(conf, target, tags, state)
    local attributes = {}
    for tag, attribute in pairs(OPT_IN_PROVIDER_IDS) do
        if tags[tag] and type(state.provider_ids) == "table" then
            attributes[attribute] = state.provider_ids[attribute]
        end
    end
    -- The ids the operator declared win, and are sent whenever declared. The
    -- API key id is only ever declared: it is never derived from a key.
    attributes["trajectory.request.api_key_id"] = conf.ai_usage_metrics_api_key_id
    attributes["trajectory.request.provider_account_id"] = conf.ai_usage_metrics_provider_account_id
        or attributes["trajectory.request.provider_account_id"]
    attributes["trajectory.request.project_id"] = conf.ai_usage_metrics_project_id
        or attributes["trajectory.request.project_id"]
    if tags.route then
        local route = kong.router.get_route()
        attributes["trajectory.gateway.route"] = route and string_value(route.name)
    end
    if tags.destination then
        local service = kong.router.get_service()
        attributes["trajectory.gateway.destination.id"] = service and string_value(service.name)
    end
    if tags.key_alias or tags.user then
        local consumer = kong.client.get_consumer()
        if consumer then
            -- The consumer's name labels the credential the caller presented,
            -- person or service. The credential itself is never read.
            if tags.key_alias then
                attributes["trajectory.gateway.key.alias"] = string_value(consumer.username)
                    or string_value(consumer.custom_id)
            end
            -- user.id is only ever a person: a consumer whose custom_id or
            -- username is an email address. A service consumer has none.
            if tags.user then
                attributes["user.id"] = person(consumer.custom_id) or person(consumer.username)
            end
        end
    end
    if tags.service and target then
        attributes["service.name"] = target.service
    end
    return attributes
end

-- Seconds from a start in milliseconds to an end in seconds.
local function seconds_since_ms(start_ms, end_s)
    if type(start_ms) ~= "number" then
        return nil
    end
    local seconds = end_s - start_ms / 1000
    return seconds > 0 and seconds or 0
end

-- log: build and record the observations of the request.
function _M.log(conf, target)
    if not conf.ai_usage_metrics_enabled then
        return
    end
    local request = ai_state()
    if not request then
        return
    end
    local model = request.model
    local operation = operation_name(request.route_type)
    local provider = provider_name(model)
    if not operation or not provider then
        return
    end
    local state = kong.ctx.plugin.ai_usage or {}
    kong.ctx.plugin.ai_usage = nil
    ngx.update_time()
    local now = ngx.now()
    local ctx = ngx.ctx
    local request_model = string_value(model.name)
    if request_model == "UNSPECIFIED" then
        request_model = nil
    end
    local options = type(model.options) == "table" and model.options or {}
    local priced = type(options.input_cost) == "number" and type(options.output_cost) == "number"
    local status = state.status
    if status == nil then
        status = kong.service.response.get_status()
    end
    local failed = status ~= 200
    local err = failed and error_type(status, state.source or kong.response.get_source()) or nil

    local tags = enabled_tags(conf)
    local attributes = deployment_attributes(conf, target, tags, state)

    local documents = {}
    local gateway_cost
    -- The provider attempt: Kong reached the balancer for it.
    local attempt_start = ctx.KONG_BALANCER_START
    local attempted = attempt_start ~= nil
    if attempted then
        local embeddings = operation == "embeddings"
        local observation = {
            operation_name = operation,
            provider_name = provider,
            request_model = request_model,
            duration_seconds = seconds_since_ms(attempt_start, state.ended_at or now),
            streaming = state.stream == true,
            observation_point = "gateway",
            error_type = err,
        }
        if not failed then
            if not state.sse then
                state.embeddings = embeddings
                read_buffered_body(state)
            end
            -- The provider's own usage, model and tier, as the library read
            -- them.
            local response = type(state.response) == "table" and state.response or {}
            observation.response_model = string_value(response.response_model)
            if response.outcome == "failed" then
                -- The provider reported a failure inside a 200 response.
                err = response.error_type
                observation.error_type = err
            end
            local fields = type(response.usage) == "table" and response.usage or {}
            local estimated = false
            if next(fields) == nil then
                fields = kong_usage_fields(embeddings)
                estimated = state.stream or not KONG_COUNTS_REPORTED[model.provider]
            end
            for key, value in pairs(fields) do
                observation[key] = value
            end
            if next(fields) ~= nil and estimated then
                observation.input_token_source = "estimated"
                observation.output_token_source = "estimated"
            end
            -- The cost at the model's configured prices, as Kong applies them
            -- to the input and output totals: the provider's when it reported
            -- them (read with inclusive totals), so the cost agrees with the
            -- token metrics.
            local input, output = observation.input_tokens, observation.output_tokens
            local cost = priced
                and input ~= nil
                and (output ~= nil or embeddings)
                and usage_ffi.estimated_cost(options.input_cost, options.output_cost, input, output)
            if cost then
                observation.cost_nano_usd = cost
                observation.cost_source = "estimated"
                gateway_cost = cost
            end
            observation.service_tier = string_value(response.service_tier)
        end
        documents[1] = {
            profile = PROFILES.provider_attempt,
            observation = observation,
            deployment_attributes = attributes,
        }
        if observation.input_tokens ~= nil then
            documents[2] = {
                profile = PROFILES.token_breakdown,
                observation = observation,
                deployment_attributes = attributes,
            }
        end
    end

    -- The gateway request. A request that failed for good was charged
    -- nothing.
    local gateway = {
        operation_name = operation,
        request_model = request_model,
        duration_seconds = seconds_since_ms(ctx.KONG_PROCESSING_START, now) or 0,
        observation_point = "gateway",
        provider_operations = attempted and 1 or 0,
        provider_operation_coverage = "complete",
        error_type = err,
    }
    gateway.estimated_cost_nano_usd = failed and 0 or gateway_cost
    documents[#documents + 1] = {
        profile = PROFILES.gateway_request,
        observation = gateway,
        deployment_attributes = attributes,
    }
    -- All of the request's documents or none: a full batch never keeps an
    -- attempt without its breakdown. A request it has no room for is
    -- counted by the library.
    local ok, add_err = batch:add_request(documents)
    if not ok then
        kong.log.debug("ddtrace: AI usage observations rejected: ", add_err)
    end
    -- The memory ceiling: reached only when sends cannot keep up.
    warn_drops(now)

    if target then
        ensure_writer(target)
        flush_if_full()
    end
end

return _M

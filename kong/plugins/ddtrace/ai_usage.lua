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

local cjson = require("cjson.safe")
local projection = require("kong.plugins.ddtrace.ai_usage_projection")
local dogstatsd = require("kong.plugins.ddtrace.ai_usage_dogstatsd")

local ngx = ngx
local kong = kong
local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local str_find = string.find
local str_sub = string.sub
local str_lower = string.lower
local concat = table.concat

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

-- Kong's provider names, as OpenTelemetry's well-known gen_ai.provider.name
-- values where they differ.
local PROVIDERS = {
    openai = "openai",
    azure = "azure.ai.openai",
    anthropic = "anthropic",
    cohere = "cohere",
    mistral = "mistral_ai",
    gemini = "gcp.gemini",
    bedrock = "aws.bedrock",
    huggingface = "huggingface",
    llama2 = "llama2",
}

local ROUTE_OPERATIONS = {
    ["llm/v1/chat"] = "chat",
    ["llm/v1/completions"] = "text_completion",
    ["llm/v1/embeddings"] = "embeddings",
    ["llm/v1/responses"] = "chat",
}

-- Providers whose streamed and buffered counts Kong reads from the
-- provider's response rather than estimating them.
local KONG_COUNTS_REPORTED = {
    cohere = true,
    llama2 = true,
    anthropic = true,
    gemini = true,
    bedrock = true,
}

-- An upstream status as the error type LiteLLM records for it, so that both
-- gateways give one series.
local STATUS_ERRORS = {
    [400] = "bad_request_error",
    [401] = "authentication_error",
    [403] = "permission_denied_error",
    [404] = "not_found_error",
    [408] = "timeout",
    [413] = "bad_request_error",
    [422] = "bad_request_error",
    [429] = "rate_limit_error",
    [500] = "internal_server_error",
    [502] = "bad_gateway_error",
    [503] = "service_unavailable_error",
    [504] = "timeout",
    [529] = "internal_server_error",
}

-- The response headers that name the account and project a call was billed
-- to: (provider, attribute, header). No other header is read.
local ID_HEADERS = {
    { "anthropic", "trajectory.request.provider_account_id", "anthropic-organization-id" },
    -- The organization's name, not its org- id.
    { "openai", "trajectory.request.provider_account_id", "openai-organization" },
    { "openai", "trajectory.request.project_id", "openai-project" },
}

local OPT_IN_PROVIDER_IDS = {
    provider_account = "trajectory.request.provider_account_id",
    project = "trajectory.request.project_id",
}

-- A streamed line longer than this is skipped rather than buffered.
local MAX_LINE_BYTES = 1024 * 1024
-- The most points a batch holds between two sends.
local MAX_BATCH_POINTS = 100000
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
            return "gcp.vertex_ai"
        end
    end
    local name = PROVIDERS[provider] or str_lower(provider):gsub("[^a-z0-9_.%-]", "_")
    if projection.is_identifier(name) then
        return name
    end
    return nil
end

-- The operation of a passthrough (preserve) route, from the upstream path.
local function preserve_operation()
    local path = ngx.var.upstream_uri or kong.request.get_path() or ""
    path = path:gsub("%?.*$", "")
    if path:find("/embeddings$") then
        return "embeddings"
    elseif path:find("/chat/completions$") or path:find("/messages$") or path:find("/responses$") then
        return "chat"
    elseif path:find("/completions$") then
        return "text_completion"
    end
    return nil
end

local function operation_name(route_type)
    if route_type == "preserve" then
        return preserve_operation()
    end
    return ROUTE_OPERATIONS[route_type]
end

local function error_type(status, source)
    if status == nil or source == "error" then
        local upstream = tonumber(ngx.var.upstream_status)
        if upstream == 504 or status == 504 then
            return "timeout"
        end
        return "api_connection_error"
    end
    return STATUS_ERRORS[status] or "api_error"
end

-- Usage from a provider response

-- Merge a usage object into the usage seen so far: a later event's counts
-- replace earlier ones (Anthropic's message_delta carries the final counts).
local function merge_usage(state, usage)
    if type(usage) ~= "table" then
        return
    end
    local merged = state.usage or {}
    for key, value in pairs(usage) do
        if value ~= cjson.null then
            merged[key] = value
        end
    end
    state.usage = merged
end

local function note_response(state, t)
    if type(t) ~= "table" then
        return
    end
    local event = t.type
    if event == "message_start" and type(t.message) == "table" then
        -- Anthropic Messages stream.
        state.response_model = state.response_model or string_value(t.message.model)
        merge_usage(state, t.message.usage)
    elseif type(t.response) == "table" and type(event) == "string" and event:find("^response%.") then
        -- OpenAI Responses stream.
        state.response_model = string_value(t.response.model) or state.response_model
        state.service_tier = string_value(t.response.service_tier) or state.service_tier
        merge_usage(state, t.response.usage)
    else
        state.response_model = state.response_model or string_value(t.model) or string_value(t.modelVersion)
        state.service_tier = string_value(t.service_tier) or state.service_tier
        merge_usage(state, t.usage)
    end
end

-- Read one server-sent event line. Only lines that can carry the usage,
-- the model or the service tier are decoded: content events hold the
-- generated output. A quote inside a JSON string is escaped, so generated
-- text cannot contain these quoted names.
local function scan_sse_line(state, line)
    if not str_find(line, '"usage"', 1, true) and not str_find(line, '"service_tier"', 1, true) then
        if state.response_model or not str_find(line, '"model"', 1, true) then
            return
        end
    end
    local start = str_find(line, "{", 1, true)
    if not start then
        return
    end
    local t = cjson.decode(str_sub(line, start))
    note_response(state, t)
end

local function scan_sse_chunk(state, chunk)
    local text = (state.rest or "") .. chunk
    local position = 1
    while true do
        local newline = str_find(text, "\n", position, true)
        if not newline then
            break
        end
        local line = str_sub(text, position, newline - 1)
        if state.skip_line then
            state.skip_line = false
        elseif #line > 0 then
            scan_sse_line(state, line)
        end
        position = newline + 1
    end
    local rest = str_sub(text, position)
    if #rest > MAX_LINE_BYTES then
        state.skip_line = true
        rest = ""
    end
    state.rest = rest
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
    if str_find(body, "^%s*data:") or str_find(body, "^%s*event:") then
        scan_sse_chunk(state, body .. "\n")
    else
        note_response(state, cjson.decode(body))
    end
end

local function detail(details, key)
    return type(details) == "table" and count(details[key]) or nil
end

-- The token fields of an observation from a provider's usage object.
-- Chat Completions usage (prompt_tokens includes cached input, and
-- completion_tokens includes reasoning) and Responses usage (input_tokens
-- and output_tokens, also inclusive) are read as they are; Anthropic's
-- input_tokens leaves cache reads and writes out. A usage object of zeros
-- is no usage.
local function usage_fields(usage, embeddings, claude, reasoning_known)
    if type(usage) ~= "table" then
        return {}
    end
    local input = count(usage.prompt_tokens)
    local output = count(usage.completion_tokens)
    local basis = "includes_cache"
    local prompt_details = usage.prompt_tokens_details
    local completion_details = usage.completion_tokens_details
    if input == nil and output == nil then
        input = count(usage.input_tokens)
        output = count(usage.output_tokens)
        prompt_details = usage.input_tokens_details
        completion_details = usage.output_tokens_details
        if count(usage.cache_read_input_tokens) ~= nil or count(usage.cache_creation_input_tokens) ~= nil then
            basis = "excludes_cache"
        end
    end
    if (input or 0) == 0 and (output or 0) == 0 then
        return {}
    end
    local fields = { input_tokens = input, input_basis = basis }
    if not embeddings then
        fields.output_tokens = output
        fields.output_basis = "includes_reasoning"
    end
    local cache_read = count(usage.cache_read_input_tokens)
    if cache_read == nil then
        cache_read = detail(prompt_details, "cached_tokens")
    end
    fields.cache_read_input_tokens = cache_read
    local cache_write = count(usage.cache_creation_input_tokens)
    if cache_write == nil then
        cache_write = detail(prompt_details, "cache_creation_tokens")
    end
    fields.cache_write_input_tokens = cache_write
    local lifetimes = type(prompt_details) == "table" and prompt_details.cache_creation_token_details
    if type(lifetimes) ~= "table" then
        lifetimes = usage.cache_creation
    end
    fields.cache_write_5m_input_tokens = detail(lifetimes, "ephemeral_5m_input_tokens")
    fields.cache_write_1h_input_tokens = detail(lifetimes, "ephemeral_1h_input_tokens")
    if not embeddings and not claude and reasoning_known then
        fields.reasoning_output_tokens = detail(completion_details, "reasoning_tokens")
    end
    if not claude then
        local sides = { { "input", prompt_details } }
        if not embeddings then
            sides[2] = { "output", completion_details }
        end
        for _, side in ipairs(sides) do
            local parts
            for _, modality in ipairs({ "image", "audio" }) do
                local value = detail(side[2], modality .. "_tokens")
                if value ~= nil then
                    parts = parts or {}
                    parts[modality] = value
                end
            end
            if parts then
                fields[side[1] .. "_tokens_by_modality"] = parts
            end
        end
    end
    return fields
end
_M.usage_fields = usage_fields

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
local batch = dogstatsd.new_batch()
local writer = { started = false }

-- An email address, the one form of consumer name that is known to be a
-- person rather than a service.
local function person(value)
    value = string_value(value)
    if value and value:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
        return value
    end
    return nil
end

-- The largest DogStatsD datagram: the usual Ethernet MTU less IP and UDP
-- headers, as Datadog's DogStatsD clients use for UDP.
local MAX_DATAGRAM_BYTES = 1432

local function send_lines(lines, host, port)
    local sock = ngx.socket.udp()
    local ok, err = sock:setpeername(host, port)
    if not ok then
        kong.log.warn("ddtrace: cannot send AI usage metrics to ", host, ":", tostring(port), ": ", err)
        return
    end
    -- Several lines per datagram, each small enough to cross a network
    -- without IP fragmentation, which can drop it on the way to the Agent.
    local packet, size = {}, 0
    local dropped, last_err = 0, nil
    local function send()
        local sent, send_err = sock:send(concat(packet, "\n"))
        if not sent then
            dropped = dropped + #packet
            last_err = send_err
        end
        packet, size = {}, 0
    end
    for _, line in ipairs(lines) do
        if size > 0 and size + #line + 1 > MAX_DATAGRAM_BYTES then
            send()
        end
        packet[#packet + 1] = line
        size = size + #line + 1
    end
    if size > 0 then
        send()
    end
    sock:close()
    if dropped > 0 then
        -- Once per flush at most: the Agent being down or not listening must
        -- not lose metrics silently.
        kong.log.warn("ddtrace: sending AI usage metrics to ", host, ":", tostring(port),
            " failed (", tostring(last_err), "); ", dropped, " lines dropped")
    end
end

local function flush()
    if batch:is_empty() then
        return
    end
    local lines = batch:lines()
    batch = dogstatsd.new_batch()
    send_lines(lines, writer.host, writer.port)
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

-- Test hook: the batch recorded so far, and a new one.
function _M.take_batch()
    local taken = batch
    batch = dogstatsd.new_batch()
    return taken
end

local function record(profile, points, resource)
    -- Points are kept until the next send; a writer that cannot send does not
    -- hold more than this many.
    if batch.size >= MAX_BATCH_POINTS then
        return
    end
    local kept = {}
    for _, point in ipairs(points) do
        if DEFAULT_METRICS[point.name] then
            kept[#kept + 1] = point
        end
    end
    if #kept == 0 then
        return
    end
    local ok, err = batch:add(profile, kept, resource, false)
    if not ok then
        kong.log.debug("ddtrace: AI usage points not recorded: ", err)
    end
end

local function project(projector, profile, observation, attributes)
    local points, err = projector(observation)
    if not points then
        kong.log.debug("ddtrace: AI usage observation rejected (", profile, "): ", err)
        return
    end
    local resource
    points, resource = projection.with_deployment_attributes(points, attributes)
    if points then
        record(profile, points, resource)
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
        headers = {},
    }
    local tags = enabled_tags(conf)
    if tags.provider_account or tags.project then
        for _, id in ipairs(ID_HEADERS) do
            local value = response.get_header(id[3])
            if type(value) == "string" then
                state.headers[id[3]] = value
            end
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
            scan_sse_chunk(state, chunk)
        end
    end
    if ngx.arg[2] then
        if state.rest and #state.rest > 0 then
            scan_sse_chunk(state, "\n")
        end
        ngx.update_time()
        state.ended_at = ngx.now()
    end
end

local function deployment_attributes(conf, target, tags, model_provider, state)
    local attributes = {}
    if tags.provider_account or tags.project then
        for _, id in ipairs(ID_HEADERS) do
            local provider, attribute, header = id[1], id[2], id[3]
            local tag = attribute == OPT_IN_PROVIDER_IDS.provider_account and "provider_account" or "project"
            if model_provider == provider and tags[tag] and attributes[attribute] == nil then
                attributes[attribute] = state.headers[header]
            end
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

-- The cost of an attempt at the model's configured prices, in USD per
-- million tokens, applied as Kong applies them to the input and output
-- totals. The totals are the provider's when it reported them, so the cost
-- agrees with the token metrics: Kong's own figure for a stream is based on
-- its own estimate of the counts.
local function attempt_cost(options, observation)
    local input = observation.input_tokens
    local output = observation.output_tokens
    if input ~= nil and observation.input_basis == "excludes_cache" then
        input = input + (observation.cache_read_input_tokens or 0) + (observation.cache_write_input_tokens or 0)
    end
    if input ~= nil and (output ~= nil or observation.operation_name == "embeddings") then
        return (input * options.input_cost + (output or 0) * options.output_cost) / 1000000
    end
    return nil
end

local function seconds_since_ms(start_ms, end_s)
    if type(start_ms) ~= "number" then
        return nil
    end
    local seconds = end_s - start_ms / 1000
    if seconds < 0 then
        return 0
    end
    return seconds
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
    local state = kong.ctx.plugin.ai_usage or { headers = {} }
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
    local attributes = deployment_attributes(conf, target, tags, model.provider, state)

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
                read_buffered_body(state)
            end
            observation.response_model = state.response_model
            local claude = model.provider == "anthropic" or str_find(str_lower(request_model or ""), "claude", 1, true)
            local usage = state.usage
            -- A stream reports reasoning only when its usage names it.
            local reasoning_known = not state.stream
                or (
                    type(usage) == "table"
                    and type(usage.completion_tokens_details) == "table"
                    and usage.completion_tokens_details.reasoning_tokens ~= nil
                )
            local fields = usage_fields(usage, embeddings, claude, reasoning_known)
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
            local cost = priced and attempt_cost(options, observation)
            if cost then
                observation.cost_usd = cost
                observation.cost_source = "estimated"
                gateway_cost = cost
            end
            -- The tier the provider served the call at: the response's own
            -- (OpenAI), else its usage object's (Anthropic).
            local tier = state.service_tier
            if tier == nil and type(usage) == "table" then
                tier = string_value(usage.service_tier)
            end
            if projection.is_service_tier(tier) then
                observation.service_tier = tier
            end
        end
        project(projection.project_provider_attempt, projection.PROVIDER_ATTEMPT, observation, attributes)
        if observation.input_tokens ~= nil then
            project(projection.project_token_breakdown, projection.TOKEN_BREAKDOWN, observation, attributes)
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
    if failed then
        gateway.estimated_cost_usd = 0
    else
        gateway.estimated_cost_usd = gateway_cost
    end
    project(projection.project_gateway_request, projection.GATEWAY_REQUEST, gateway, attributes)

    if target then
        ensure_writer(target)
    end
end

return _M

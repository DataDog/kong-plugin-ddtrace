-- Kong's own glue around libdd-ai-usage-ffi: what it reads from Kong's
-- request state, consumer and response, and how it sends the datagrams. The
-- projection, the series and the provider parsing are libdatadog's, tested
-- there against the shared conformance vectors.
--
-- Needs the library: DD_AI_USAGE_FFI_LIBRARY, lua_package_cpath, or the
-- loader's search path.

local real_ngx = ngx

-- The module captures ngx and kong when it is loaded: both are stand-ins
-- whose fields each test sets.
local fake_ngx = setmetatable({}, { __index = real_ngx })
local fake_kong = {}
_G.ngx = fake_ngx
_G.kong = fake_kong

local usage_ffi = require("kong.plugins.ddtrace.ai_usage_ffi")
local ai_usage = require("kong.plugins.ddtrace.ai_usage")

local function new_request(opts)
    opts = opts or {}
    local headers = opts.headers or { ["content-type"] = "application/json" }
    fake_ngx.ctx = {
        ai_namespaced_ctx = {
            ["normalize-request"] = {
                route_type = opts.route_type or "llm/v1/chat",
                model = {
                    provider = opts.provider or "openai",
                    name = opts.model or "gpt-4o-mini",
                    options = opts.options or { input_cost = 1.0, output_cost = 2.0 },
                },
            },
            _global = { stream_mode = opts.stream == true },
        },
        buffered_proxying = not opts.stream,
        KONG_BALANCER_START = opts.balancer_start or (real_ngx.now() * 1000 - 250),
        KONG_PROCESSING_START = real_ngx.now() * 1000 - 300,
    }
    fake_ngx.var = { upstream_status = tostring(opts.status or 200), upstream_uri = opts.path or "/" }
    fake_ngx.arg = {}
    fake_kong.log = {
        err = function(...) error(table.concat({ ... })) end,
        warn = function() end,
        debug = function() end,
    }
    fake_kong.ctx = { plugin = {} }
    fake_kong.service = {
        response = {
            get_status = function() return opts.status or 200 end,
            get_header = function(name) return headers[name:lower()] end,
            get_headers = function() return headers end,
            get_raw_body = function() return opts.body end,
        },
    }
    fake_kong.response = { get_source = function() return opts.source or "service" end }
    fake_kong.request = { get_path = function() return opts.path or "/" end }
    fake_kong.router = {
        get_route = function() return { name = "chat-route" } end,
        get_service = function() return { name = "openai-service" } end,
    }
    fake_kong.client = { get_consumer = function() return opts.consumer end }
end

local function conf(tags)
    return { ai_usage_metrics_enabled = true, ai_usage_metrics_tags = tags or {} }
end

-- Run the three phases of one request; returns the DogStatsD lines.
local function run(opts, c, chunks)
    new_request(opts)
    c = c or conf()
    ai_usage.header_filter(c)
    for i, chunk in ipairs(chunks or { "" }) do
        fake_ngx.arg = { chunk, i == #(chunks or { "" }) }
        ai_usage.body_filter(c)
    end
    ai_usage.log(c, nil)
    return ai_usage.take_lines()
end

local function find(lines, pattern)
    local found = {}
    for _, line in ipairs(lines) do
        if line:find(pattern) then
            found[#found + 1] = line
        end
    end
    return found
end

local OPENAI_BODY = '{"model":"gpt-4o-mini-2024-07-18","service_tier":"default",'
    .. '"choices":[{"message":{"content":"hi"}}],'
    .. '"usage":{"prompt_tokens":12,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":4}}}'

describe("ai usage glue", function()
    it("loads libdd-ai-usage-ffi", function()
        assert.is_true(usage_ffi.available(), tostring(usage_ffi.load_error))
    end)

    it("reads a buffered response's usage, model and tier", function()
        local lines = run({ body = OPENAI_BODY })
        assert.equal(1, #find(lines, "^gen_ai%.client%.inference%.usage%.input_tokens:12|c|"))
        assert.equal(1, #find(lines, "^gen_ai%.client%.inference%.usage%.output_tokens:5|c|"))
        assert.equal(1, #find(lines, "^gen_ai%.client%.inference%.usage%.cache_read%.input_tokens:4|c|"))
        assert.equal(0, #find(lines, "trajectory%.token%.source"))
        -- Kong's prices: (12 * 1 + 5 * 2) / 1e6.
        assert.equal(1, #find(lines, "^trajectory%.gen_ai%.client%.inference%.usage%.cost:0%.000022|c|"))
        assert.equal(1, #find(lines, "^trajectory%.gen_ai%.gateway%.request%.estimated_cost:0%.000022|c|"))
        for _, line in ipairs(find(lines, "input_tokens:12")) do
            assert.truthy(line:find("gen_ai.response.model:gpt-4o-mini-2024-07-18", 1, true))
            assert.truthy(line:find("trajectory.request.service_tier:default", 1, true))
            assert.truthy(line:find("gen_ai.provider.name:openai", 1, true))
        end
    end)

    it("reads a stream's usage across chunks that split events", function()
        local events = 'event: message_start\ndata: {"type":"message_start","message":{"model":"claude-haiku-4-5",'
            .. '"usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":3,'
            .. '"cache_creation_input_tokens":0}}}\n\n'
            .. 'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"text":"\\"usage\\""}}\n\n'
            .. 'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":7}}\n\n'
            .. 'event: message_stop\ndata: {"type":"message_stop"}\n\n'
        local chunks = { events:sub(1, 50), events:sub(51, 200), events:sub(201) }
        local lines = run({
            provider = "anthropic",
            model = "claude-haiku-4-5",
            stream = true,
            headers = { ["content-type"] = "text/event-stream" },
        }, nil, chunks)
        -- Anthropic input leaves the cache read out: 10 + 3.
        assert.equal(1, #find(lines, "^gen_ai%.client%.inference%.usage%.input_tokens:13|c|"))
        assert.equal(1, #find(lines, "^gen_ai%.client%.inference%.usage%.output_tokens:7|c|"))
        assert.equal(1, #find(lines, "^gen_ai%.client%.inference%.usage%.cache_read%.input_tokens:3|c|"))
    end)

    it("falls back to Kong's estimate, marked estimated, when the provider reported none", function()
        new_request({ body = '{"choices":[]}' })
        local c = conf()
        ai_usage.header_filter(c)
        fake_ngx.ctx.ai_llm_metrics = { llm_prompt_tokens_count = 9, llm_completion_tokens_count = 2 }
        fake_ngx.arg = { "", true }
        ai_usage.body_filter(c)
        ai_usage.log(c, nil)
        local lines = ai_usage.take_lines()
        local input = find(lines, "^gen_ai%.client%.inference%.usage%.input_tokens:9|c|")
        assert.equal(1, #input)
        assert.truthy(input[1]:find("trajectory.token.source:estimated", 1, true))
    end)

    it("labels failures with the shared error.type", function()
        local cases = {
            { 400, "bad_request_error" },
            { 408, "timeout_error" },
            { 413, "api_error" },
            { 422, "unprocessable_entity_error" },
            { 429, "rate_limit_error" },
            { 502, "internal_server_error" },
            { 503, "internal_server_error" },
            { 504, "timeout_error" },
        }
        for _, case in ipairs(cases) do
            local lines = run({ status = case[1], body = '{"error":{}}' })
            local durations = find(lines, "^gen_ai%.client%.inference%.duration:")
            assert.equal(1, #durations, tostring(case[1]))
            assert.truthy(durations[1]:find("error.type:" .. case[2], 1, true), durations[1])
            -- A request that failed for good was charged nothing.
            assert.equal(1, #find(lines, "^trajectory%.gen_ai%.gateway%.request%.estimated_cost:0|c|"))
        end
        local lines = run({ status = 502, source = "error" })
        local durations = find(lines, "^gen_ai%.client%.inference%.duration:")
        assert.truthy(durations[1]:find("error.type:api_connection_error", 1, true), durations[1])
    end)

    it("sets key_alias from the consumer and user.id only for an email", function()
        local tags = conf({ "key_alias", "user" })
        local lines = run({ body = OPENAI_BODY, consumer = { username = "billing-svc", custom_id = "Ada@Example.com" } }, tags)
        local input = find(lines, "input_tokens:12")[1]
        assert.truthy(input:find("trajectory.gateway.key.alias:billing-svc", 1, true), input)
        assert.truthy(input:find("user.id:ada_example.com", 1, true), input)

        lines = run({ body = OPENAI_BODY, consumer = { username = "batch-job" } }, tags)
        input = find(lines, "input_tokens:12")[1]
        assert.truthy(input:find("trajectory.gateway.key.alias:batch-job", 1, true), input)
        assert.falsy(input:find("user.id:", 1, true), input)
    end)

    it("reads provider ids only when their tags are enabled", function()
        local headers = {
            ["content-type"] = "application/json",
            ["openai-organization"] = "acme",
            ["openai-project"] = "proj_123",
            ["authorization"] = "Bearer never-read",
        }
        local lines = run({ body = OPENAI_BODY, headers = headers }, conf({ "provider_account" }))
        local input = find(lines, "input_tokens:12")[1]
        assert.truthy(input:find("trajectory.request.provider_account_id:acme", 1, true), input)
        assert.falsy(input:find("project_id", 1, true), input)
        assert.falsy(input:find("never-read", 1, true), input)

        lines = run({ body = OPENAI_BODY, headers = headers })
        input = find(lines, "input_tokens:12")[1]
        assert.falsy(input:find("provider_account_id", 1, true), input)
    end)

    it("names Gemini on Vertex AI gcp.vertex_ai", function()
        local lines = run({
            provider = "gemini",
            model = "gemini-2.5-flash",
            options = { gemini = { project_id = "p" } },
            body = '{"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":4,"totalTokenCount":7}}',
        })
        local input = find(lines, "input_tokens:3")[1]
        assert.truthy(input:find("gen_ai.provider.name:gcp.vertex_ai", 1, true), input)
    end)

    it("sends datagrams of at most 1432 bytes", function()
        for _ = 1, 40 do
            new_request({ body = OPENAI_BODY, model = "gpt-4o-mini-" .. string.rep("x", 60) .. _ })
            local c = conf()
            ai_usage.header_filter(c)
            fake_ngx.arg = { "", true }
            ai_usage.body_filter(c)
            ai_usage.log(c, nil)
        end
        local sent = {}
        fake_ngx.socket = {
            udp = function()
                return {
                    setpeername = function() return true end,
                    send = function(_, datagram)
                        sent[#sent + 1] = datagram
                        return true
                    end,
                    close = function() end,
                }
            end,
        }
        ai_usage.flush()
        assert.is_true(#sent > 1)
        local lines = 0
        for _, datagram in ipairs(sent) do
            assert.is_true(#datagram <= 1432, tostring(#datagram))
            for _ in datagram:gmatch("[^\n]+") do
                lines = lines + 1
            end
        end
        assert.is_true(lines >= 40 * 8)
        assert.same({}, ai_usage.take_lines())
    end)
end)

-- The per-worker batch of AI usage points between two sends: it is sent
-- early at the high-water mark, and the documents its bound has no room for
-- are counted and warned about.
--
-- Needs libdd-ai-usage-ffi (required): DD_AI_USAGE_FFI_LIBRARY, lua_package_cpath, or the
-- loader's search path.

local real_ngx = ngx

-- The module captures ngx and kong when it is loaded: both are stand-ins
-- whose fields each test sets.
local fake_ngx = setmetatable({}, { __index = real_ngx })
local fake_kong = {}
_G.ngx = fake_ngx
_G.kong = fake_kong

local ai_usage = require("kong.plugins.ddtrace.ai_usage")

local OPENAI_BODY = '{"model":"gpt-4o-mini-2024-07-18","choices":[{"message":{"content":"hi"}}],'
    .. '"usage":{"prompt_tokens":12,"completion_tokens":5}}'

local TARGET = { host = "127.0.0.1", port = 8125, interval = 10, service = "kong" }

local clock, timers, sent, warnings

local function reset(opts)
    opts = opts or {}
    clock = 1000
    timers = { every = {}, at = {} }
    sent = {}
    warnings = {}
    fake_ngx.now = function()
        return clock
    end
    fake_ngx.update_time = function() end
    fake_ngx.timer = {
        every = function(_, fn)
            timers.every[#timers.every + 1] = fn
            return true
        end,
        at = function(_, fn)
            if opts.no_timers then
                return nil, "too many pending timers"
            end
            timers.at[#timers.at + 1] = fn
            return true
        end,
    }
    fake_ngx.socket = {
        udp = function()
            return {
                setpeername = function()
                    return true
                end,
                send = function(_, datagram)
                    sent[#sent + 1] = datagram
                    return true
                end,
                close = function() end,
            }
        end,
    }
end

local function log_request()
    fake_ngx.ctx = {
        ai_namespaced_ctx = {
            ["normalize-request"] = {
                route_type = "llm/v1/chat",
                model = { provider = "openai", name = "gpt-4o-mini", options = {} },
            },
            _global = { stream_mode = false },
        },
        buffered_proxying = true,
        KONG_BALANCER_START = clock * 1000 - 250,
        KONG_PROCESSING_START = clock * 1000 - 300,
    }
    fake_ngx.var = { upstream_status = "200", upstream_uri = "/" }
    fake_ngx.arg = { "", true }
    fake_kong.log = {
        err = function(...)
            error(table.concat({ ... }))
        end,
        warn = function(...)
            warnings[#warnings + 1] = table.concat({ ... })
        end,
        debug = function() end,
    }
    fake_kong.ctx = { plugin = {} }
    fake_kong.service = {
        response = {
            get_status = function()
                return 200
            end,
            get_header = function(name)
                return name:lower() == "content-type" and "application/json" or nil
            end,
            get_headers = function()
                return { ["content-type"] = "application/json" }
            end,
            get_raw_body = function()
                return OPENAI_BODY
            end,
        },
    }
    fake_kong.response = {
        get_source = function()
            return "service"
        end,
    }
    fake_kong.request = {
        get_path = function()
            return "/"
        end,
    }
    fake_kong.router = {
        get_route = function()
            return { name = "chat-route" }
        end,
        get_service = function()
            return { name = "openai-service" }
        end,
    }
    fake_kong.client = {
        get_consumer = function()
            return nil
        end,
    }
    local conf = { ai_usage_metrics_enabled = true, ai_usage_metrics_tags = {} }
    ai_usage.header_filter(conf)
    ai_usage.body_filter(conf)
    ai_usage.log(conf, TARGET)
end

-- Run the timers that are due, as the event loop would between requests.
local function run_early_timers()
    local due = timers.at
    timers.at = {}
    for _, fn in ipairs(due) do
        fn(false)
    end
end

-- The gen_ai.client.inference.duration samples sent: one per request.
local function duration_samples()
    local n = 0
    for _, datagram in ipairs(sent) do
        for line in datagram:gmatch("[^\n]+") do
            if line:find("^gen_ai%.client%.inference%.duration:[^|]+|d") then
                n = n + 1
            end
        end
    end
    return n
end

-- The points the first request adds to an empty batch, and those each
-- further request like it adds: its counters share the first one's series,
-- so only its histogram samples are new points.
local function points_per_request()
    reset()
    ai_usage.take_lines()
    log_request()
    local first = ai_usage.buffered_points()
    log_request()
    local next = ai_usage.buffered_points() - first
    ai_usage.take_lines()
    return first, next
end

-- The count a drop warning reports since the last one.
local function dropped_in(warning)
    return tonumber(warning:match("(%d+) documents dropped since the last warning"))
end

describe("ai usage buffer", function()
    local defaults, first, step

    setup(function()
        defaults = { max_points = ai_usage.limits.max_points, high_water = ai_usage.limits.high_water }
        first, step = points_per_request()
        assert.is_true(step > 0 and first >= step)
    end)

    before_each(function()
        ai_usage.take_lines()
        ai_usage.drops.pending, ai_usage.drops.total, ai_usage.drops.warned_at = 0, 0, nil
        -- Room for ten requests, and an early send after eight.
        ai_usage.set_limits(first + 9 * step, first + 7 * step)
    end)

    after_each(function()
        run_early_timers()
    end)

    teardown(function()
        ai_usage.set_limits(defaults.max_points)
    end)

    it("defaults to an early send at 80% of the cap", function()
        assert.equal(math.floor(defaults.max_points * 0.8), defaults.high_water)
    end)

    it("schedules one early send at the high-water mark, off the request path", function()
        reset()
        for _ = 1, 7 do
            log_request()
        end
        assert.equal(0, #timers.at)
        log_request()
        assert.equal(1, #timers.at)
        assert.equal(0, #sent)
        -- One pending send at a time.
        log_request()
        assert.equal(1, #timers.at)
        run_early_timers()
        assert.equal(9, duration_samples())
        assert.equal(0, ai_usage.buffered_points())
        -- The next high-water mark schedules another.
        for _ = 1, 8 do
            log_request()
        end
        assert.equal(1, #timers.at)
    end)

    it("tries again on the next request when no timer can be created", function()
        reset({ no_timers = true })
        for _ = 1, 8 do
            log_request()
        end
        assert.equal(0, #timers.at)
        fake_ngx.timer.at = function(_, fn)
            timers.at[#timers.at + 1] = fn
            return true
        end
        log_request()
        assert.equal(1, #timers.at)
    end)

    it("counts and warns about documents over the bound, at most once a minute", function()
        reset({ no_timers = true })
        for _ = 1, 10 do
            log_request()
        end
        assert.equal(0, ai_usage.drops.total)
        assert.equal(0, #warnings)
        log_request()
        -- A request is dropped whole when its new points do not fit, so a
        -- batch never keeps an attempt without its breakdown: each of its
        -- two documents is counted.
        local per_request = ai_usage.drops.total
        assert.equal(2, per_request)
        for _ = 1, 2 do
            log_request()
        end
        assert.equal(3 * per_request, ai_usage.drops.total)
        -- The first drop warns at once, with the request it happened in.
        assert.equal(1, #warnings)
        local warned = dropped_in(warnings[1])
        assert.equal(per_request, warned, warnings[1])
        clock = clock + 30
        log_request()
        assert.equal(1, #warnings)
        -- The next send reports the rest once the minute has passed.
        clock = clock + 31
        ai_usage.flush()
        assert.equal(2, #warnings)
        assert.equal(4 * per_request - warned, dropped_in(warnings[2]), warnings[2])
        assert.truthy(warnings[2]:find(", " .. 4 * per_request .. " in all", 1, true), warnings[2])
        assert.equal(10, duration_samples())
    end)

    it("drops nothing at a rate that overflowed the cap between two timer sends", function()
        reset()
        -- Five caps' worth of requests within one flush interval.
        local requests = 50
        for _ = 1, requests do
            log_request()
            run_early_timers()
        end
        ai_usage.flush()
        assert.equal(0, ai_usage.drops.total)
        assert.equal(0, #warnings)
        assert.equal(requests, duration_samples())
    end)
end)

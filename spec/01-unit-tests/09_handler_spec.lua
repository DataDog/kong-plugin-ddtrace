-- Unit tests for the missing-span guard rails added in
-- "fix: gracefully skip header_filter and log phases for unrouted requests".
--
-- The handler relies on several `kong.*` globals that are normally injected
-- by the Kong runtime. We stub just enough of that surface here to load the
-- module and exercise the early-return paths in `header_filter` and `log`.

local recorded = {
    debug = {},
    err = {},
}

local function reset_recorded()
    recorded.debug = {}
    recorded.err = {}
end

-- Returns the first entry in `list` containing `needle` as a literal
-- substring, or `nil` if none match. Using a helper (rather than
-- `for _, msg in ipairs(list) do assert.is_nil(...) end`) ensures negative
-- assertions don't pass vacuously when the list is empty -- which is
-- precisely the case we care about for the unrouted-skip path.
local function find_containing(list, needle)
    for _, msg in ipairs(list) do
        if string.find(msg, needle, 1, true) then
            return msg
        end
    end
    return nil
end

-- A no-op router stub that each test can repoint at a function returning
-- either `nil` (no route matched) or a table (a route did match).
local current_get_route = function()
    return nil
end

_G.kong = {
    log = {
        debug = function(msg)
            table.insert(recorded.debug, tostring(msg))
        end,
        info = function(_) end,
        warn = function(_) end,
        err = function(...)
            local parts = { ... }
            for i, v in ipairs(parts) do
                parts[i] = tostring(v)
            end
            table.insert(recorded.err, table.concat(parts, ""))
        end,
        error = function(_) end,
    },
    ctx = {
        plugin = {},
        shared = {},
    },
    router = {
        get_route = function()
            return current_get_route()
        end,
        get_service = function()
            return nil
        end,
    },
    node = {
        get_id = function()
            return "test-node-id"
        end,
    },
    request = {
        get_header = function(_) end,
    },
    response = {
        get_status = function()
            return 200
        end,
        get_header = function(_) end,
    },
    client = {
        get_forwarded_ip = function()
            return "127.0.0.1"
        end,
    },
    service = {
        request = {
            set_header = function(_, _) end,
        },
    },
    version = "test",
    pdk_version = "test",
    configuration = {
        role = "traditional",
        nginx_daemon = "off",
        database = "off",
    },
}

local handler = require("kong.plugins.ddtrace.handler")

describe("handler: missing-span guard for unrouted requests", function()
    before_each(function()
        reset_recorded()
        kong.ctx.plugin = {}
        current_get_route = function()
            return nil
        end
    end)

    describe("header_filter phase", function()
        it("returns silently when no span and no matched route", function()
            -- Plugin enabled globally + scanner / direct-IP request:
            -- access phase never ran, so ctx.proxy_span is nil, AND no route
            -- matched. The fix should swallow this case with a debug log.
            current_get_route = function()
                return nil
            end

            handler:header_filter({})

            assert.is_not_nil(
                find_containing(recorded.debug, "skipping header_filter phase"),
                "expected a debug log explaining the skip"
            )

            -- Crucially, the pcall wrapper must NOT have caught a thrown
            -- error, AND the original error message must not appear anywhere
            -- (e.g. via kong.log.err). Asserting on the full recorded list
            -- catches both "no err entries at all" and "err entries exist but
            -- none mention the missing span".
            assert.is_nil(
                find_containing(recorded.err, "tracing error in DatadogTraceHandler"),
                "no tracing error should be logged when no route matched"
            )
            assert.is_nil(
                find_containing(recorded.err, "proxy span missing"),
                "the proxy-span-missing error must not be emitted on unrouted requests"
            )
        end)

        it("still errors when a route matched but the span is missing", function()
            -- This is the genuinely unexpected case the original error() was
            -- written for: a route was matched, so access *should* have run,
            -- but ctx.proxy_span is somehow nil. The fix must preserve this
            -- diagnostic.
            current_get_route = function()
                return { id = "route-1", name = "mock" }
            end

            handler:header_filter({})

            assert.is_not_nil(
                find_containing(recorded.err, "tracing error in DatadogTraceHandler"),
                "expected the pcall wrapper to log a tracing error"
            )
            assert.is_not_nil(
                find_containing(recorded.err, 'proxy span missing during the "header_filter" phase'),
                "expected the original proxy-span-missing error to be preserved"
            )

            assert.is_nil(
                find_containing(recorded.debug, "skipping header_filter phase"),
                "should not log the unrouted-skip debug when a route matched"
            )
        end)
    end)

    describe("log phase", function()
        it("returns silently when no span and no matched route", function()
            current_get_route = function()
                return nil
            end

            handler:log({})

            assert.is_not_nil(
                find_containing(recorded.debug, "skipping log phase"),
                "expected a debug log explaining the skip"
            )

            assert.is_nil(
                find_containing(recorded.err, "tracing error in DatadogTraceHandler"),
                "no tracing error should be logged when no route matched"
            )
            assert.is_nil(
                find_containing(recorded.err, "request span is missing"),
                "the request-span-missing error must not be emitted on unrouted requests"
            )
        end)

        it("still errors when a route matched but the span is missing", function()
            current_get_route = function()
                return { id = "route-1", name = "mock" }
            end

            handler:log({})

            assert.is_not_nil(
                find_containing(recorded.err, "tracing error in DatadogTraceHandler"),
                "expected the pcall wrapper to log a tracing error"
            )
            assert.is_not_nil(
                find_containing(recorded.err, "request span is missing during the log phase"),
                "expected the original request-span-missing error to be preserved"
            )

            assert.is_nil(
                find_containing(recorded.debug, "skipping log phase"),
                "should not log the unrouted-skip debug when a route matched"
            )
        end)
    end)
end)

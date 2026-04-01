local ffi = require("ffi")
local lib = require("kong.plugins.ddtrace.ffi_bindings")

-- Tracer configuration option constants (from dd_tracer_option enum in tracer.h).
local DD_OPT_SERVICE_NAME = 0
local DD_OPT_ENV = 1
local DD_OPT_VERSION = 2
local DD_OPT_AGENT_URL = 3
local DD_OPT_INTEGRATION_NAME = 4
local DD_OPT_INTEGRATION_VERSION = 5

-- This cache is keyed on Kong's config object. Setting the mode to weak ensures
-- the keys will get garbage-collected when the config object's lifecycle is completed.
local tracer_cache = setmetatable({}, { __mode = "k" })

-- Build a dd_conf_t handle from a configuration table.
-- dd_tracer_conf_set copies string values internally; the Lua string pointers
-- passed via ffi.cast are not retained after the call returns.
local function create_config(config)
    local dd_conf = lib.dd_tracer_conf_new()
    if dd_conf == nil then
        return nil, "failed to allocate tracer configuration"
    end

    if config.service then
        lib.dd_tracer_conf_set(dd_conf, DD_OPT_SERVICE_NAME, ffi.cast("void*", config.service))
    end
    if config.environment then
        lib.dd_tracer_conf_set(dd_conf, DD_OPT_ENV, ffi.cast("void*", config.environment))
    end
    if config.version then
        lib.dd_tracer_conf_set(dd_conf, DD_OPT_VERSION, ffi.cast("void*", config.version))
    end
    if config.agent_url then
        lib.dd_tracer_conf_set(dd_conf, DD_OPT_AGENT_URL, ffi.cast("void*", config.agent_url))
    end
    if config.integration_name then
        lib.dd_tracer_conf_set(dd_conf, DD_OPT_INTEGRATION_NAME, ffi.cast("void*", config.integration_name))
    end
    if config.integration_version then
        lib.dd_tracer_conf_set(dd_conf, DD_OPT_INTEGRATION_VERSION, ffi.cast("void*", config.integration_version))
    end

    return dd_conf
end

local Tracer = {}

--- Create a new tracer from a configuration table.
---
--- @param config table with optional fields:
---   service (string) - Service name, defaults to dd-trace-cpp default
---   environment (string) - Environment name
---   version (string) - Service version
---   agent_url (string) - Datadog agent URL (e.g. "http://localhost:8126")
---   integration_name (string) - Integration identifier
---   integration_version (string) - Integration version
---
--- @return tracer handle on success, or nil + error message on failure
function Tracer.new(config)
    config = config or {}

    local dd_conf, conf_err = create_config(config)
    if dd_conf == nil then
        return nil, conf_err
    end

    local err = ffi.new("dd_error_t")
    local tracer = lib.dd_tracer_new(dd_conf, err)
    lib.dd_tracer_conf_free(dd_conf)

    -- NOTE: Must use == nil for FFI pointers; NULL cdata is truthy in LuaJIT.
    if tracer == nil then
        return nil, ffi.string(err.message)
    end

    return ffi.gc(tracer, lib.dd_tracer_free)
end

--- Get or create a cached tracer for a Kong plugin config object.
--- Uses a weak-keyed cache so the tracer is freed when the config is GC'd.
---
--- @param kong_conf Kong plugin configuration object (used as cache key)
--- @param config table (same fields as Tracer.new)
--- @return tracer handle on success, or nil + error message on failure
function Tracer.get_or_create(kong_conf, config)
    if tracer_cache[kong_conf] == nil then
        local tracer, err = Tracer.new(config)
        if tracer == nil then
            return nil, err
        end
        tracer_cache[kong_conf] = tracer
    end
    return tracer_cache[kong_conf]
end

return Tracer

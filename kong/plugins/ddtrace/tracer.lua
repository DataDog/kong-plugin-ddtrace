local ffi = require("ffi")

-- C function declarations (from dd-trace-cpp/binding/c/include/datadog/c/tracer.h).
-- All types and functions are declared here since ffi.cdef is global and can only
-- define each type once. Span functions are declared here but their metatype methods
-- are defined in a separate span module (PR 2).
ffi.cdef([[
    typedef const char* (*dd_context_read_callback)(const char* key);
    typedef void (*dd_context_write_callback)(const char* key, const char* value);

    typedef struct {
        const char* name;
        const char* resource;
        const char* service;
        const char* service_type;
        const char* environment;
        const char* version;
    } dd_span_options_t;

    typedef enum {
        DD_ERROR_OK = 0,
        DD_ERROR_NULL_ARGUMENT = 1,
        DD_ERROR_INVALID_CONFIG = 2,
        DD_ERROR_ALLOCATION_FAILURE = 3
    } dd_error_code;

    typedef struct {
        dd_error_code code;
        char message[256];
    } dd_error_t;

    typedef struct dd_conf_s dd_conf_t;
    typedef struct dd_tracer_s dd_tracer_t;
    typedef struct dd_span_s dd_span_t;

    dd_conf_t* dd_tracer_conf_new(void);
    void dd_tracer_conf_free(dd_conf_t* handle);
    void dd_tracer_conf_set(dd_conf_t* handle, int option, const void* value);

    dd_tracer_t* dd_tracer_new(const dd_conf_t* conf_handle, dd_error_t* error);
    void dd_tracer_free(dd_tracer_t* tracer_handle);

    dd_span_t* dd_tracer_create_span(
        dd_tracer_t* tracer_handle,
        dd_span_options_t options);

    dd_span_t* dd_tracer_extract_or_create_span(
        dd_tracer_t* tracer_handle,
        dd_context_read_callback on_context_read,
        dd_span_options_t options);

    dd_span_t* dd_span_create_child(
        dd_span_t* span_handle,
        dd_span_options_t options);

    void dd_span_finish(dd_span_t* span_handle);
    void dd_span_free(dd_span_t* span_handle);

    void dd_span_set_tag(dd_span_t* span_handle, const char* key, const char* value);
    void dd_span_set_error(dd_span_t* span_handle, int error_value);
    void dd_span_set_error_message(dd_span_t* span_handle, const char* error_message);
    void dd_span_set_resource(dd_span_t* span_handle, const char* resource);
    void dd_span_set_service(dd_span_t* span_handle, const char* service);

    void dd_span_inject(
        dd_span_t* span_handle,
        dd_context_write_callback on_context_write);

    int dd_span_get_trace_id(dd_span_t* span_handle, char* buffer, size_t buffer_size);
    int dd_span_get_span_id(dd_span_t* span_handle, char* buffer, size_t buffer_size);
]])

-- Load the native library. Try LuaRocks install path first, then system path.
local lib_path = package.searchpath("libdd_trace_c", package.cpath)
local ok, lib = pcall(ffi.load, lib_path or "dd_trace_c")
if not ok and lib_path then
    ok, lib = pcall(ffi.load, "dd_trace_c")
end
if not ok then
    error("Failed to load libdd_trace_c: " .. tostring(lib) .. "\nSee CONTRIBUTING.md for build instructions.")
end

-- Tracer configuration option constants (from dd_tracer_option enum).
local DD_OPT_SERVICE_NAME = 0
local DD_OPT_ENV = 1
local DD_OPT_VERSION = 2
local DD_OPT_AGENT_URL = 3
local DD_OPT_INTEGRATION_NAME = 4
local DD_OPT_INTEGRATION_VERSION = 5

-- Attach methods to TracerConfig via ffi.metatype.
-- dd_tracer_conf_set copies string values internally; the Lua string pointers
-- passed via ffi.cast are not retained after the call returns.
ffi.metatype("struct dd_conf_s", {
    __index = {
        set = lib.dd_tracer_conf_set,
    },
})

-- Attach methods to Tracer via ffi.metatype.
ffi.metatype("struct dd_tracer_s", {
    __index = {
        create_span = function(self, name, resource)
            local opts = ffi.new("dd_span_options_t", { name, resource })
            local span = lib.dd_tracer_create_span(self, opts)
            if span == nil then
                return nil
            end
            return ffi.gc(span, lib.dd_span_free)
        end,
    },
})

-- This cache is keyed on Kong's config object. Setting the mode to weak ensures
-- the keys will get garbage-collected when the config object's lifecycle is completed.
local tracer_cache = setmetatable({}, { __mode = "k" })

--- Create a new tracer from a configuration table.
---
--- @param config table with optional fields:
---   service (string), environment (string), version (string),
---   agent_url (string), integration_name (string), integration_version (string)
--- @return tracer handle on success, or nil + error message on failure
local function make_tracer(config)
    config = config or {}

    local dd_conf = ffi.gc(lib.dd_tracer_conf_new(), lib.dd_tracer_conf_free)
    -- NOTE: Must use == nil for FFI pointers; NULL cdata is truthy in LuaJIT.
    if dd_conf == nil then
        return nil, "failed to allocate tracer configuration"
    end

    if config.service then
        dd_conf:set(DD_OPT_SERVICE_NAME, ffi.cast("void*", config.service))
    end
    if config.environment then
        dd_conf:set(DD_OPT_ENV, ffi.cast("void*", config.environment))
    end
    if config.version then
        dd_conf:set(DD_OPT_VERSION, ffi.cast("void*", config.version))
    end
    if config.agent_url then
        dd_conf:set(DD_OPT_AGENT_URL, ffi.cast("void*", config.agent_url))
    end
    if config.integration_name then
        dd_conf:set(DD_OPT_INTEGRATION_NAME, ffi.cast("void*", config.integration_name))
    end
    if config.integration_version then
        dd_conf:set(DD_OPT_INTEGRATION_VERSION, ffi.cast("void*", config.integration_version))
    end

    local err = ffi.new("dd_error_t")
    local tracer = lib.dd_tracer_new(dd_conf, err)

    if tracer == nil then
        return nil, ffi.string(err.message)
    end

    return ffi.gc(tracer, lib.dd_tracer_free)
end

--- Get or create a cached tracer for a Kong plugin config object.
--- Uses a weak-keyed cache so the tracer is freed when the config is GC'd.
---
--- @param kong_conf Kong plugin configuration object (used as cache key)
--- @param config table (same fields as make_tracer)
--- @return tracer handle on success, or nil + error message on failure
local function get_or_create(kong_conf, config)
    if tracer_cache[kong_conf] == nil then
        local tracer, err = make_tracer(config)
        if tracer == nil then
            return nil, err
        end
        tracer_cache[kong_conf] = tracer
    end
    return tracer_cache[kong_conf]
end

return {
    make_tracer = make_tracer,
    get_or_create = get_or_create,
}

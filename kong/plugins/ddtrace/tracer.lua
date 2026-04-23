local ffi = require("ffi")

-- C function declarations (from dd-trace-cpp/binding/c/include/datadog/c/tracer.h).
-- All types and functions are declared here since ffi.cdef is global and can only
-- define each type once.
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
        int64_t start_time_ns;
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
    void dd_span_set_end_time(dd_span_t* span_handle, int64_t end_time_ns);
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

-- Load the architecture-specific native library installed by LuaRocks, or fall
-- back to a generically-named one on the system library path.
local lib_name
if ffi.arch == "x64" then
    lib_name = "libdd_trace_c-x86_64"
elseif ffi.arch == "arm64" then
    lib_name = "libdd_trace_c-aarch64"
end
local lib_path = lib_name and package.searchpath(lib_name, package.cpath)
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

-- Matches DD_TRACE_CURRENT_TIME in the C header: sentinel meaning "use current
-- time". Must be assigned explicitly because ffi.new zero-inits to epoch 1970.
local DD_TRACE_CURRENT_TIME = -1LL

local function new_span_options(name, resource, start_time_ns)
    return ffi.new("dd_span_options_t", {
        name = name,
        resource = resource,
        start_time_ns = start_time_ns or DD_TRACE_CURRENT_TIME,
    })
end

-- Buffer sizes for hex-encoded IDs (128-bit trace ID = 32 hex chars + NUL,
-- 64-bit span ID = 16 hex chars + NUL).
local TRACE_ID_BUF_SIZE = 33
local SPAN_ID_BUF_SIZE = 17

-- Attach methods to TracerConfig via ffi.metatype.
-- dd_tracer_conf_set copies string values internally; the Lua string pointers
-- passed via ffi.cast are not retained after the call returns.
ffi.metatype("struct dd_conf_s", {
    __index = {
        set = lib.dd_tracer_conf_set,
    },
})

-------------------------------------------------------------------------------
-- Span methods (attached to struct dd_span_s via ffi.metatype)
-------------------------------------------------------------------------------

local function span_set_tag(self, key, value)
    if type(key) ~= "string" then
        return nil, "span:set_tag: key must be a string"
    end
    if value == nil then
        return nil, "span:set_tag: value must not be nil"
    end
    local value_type = type(value)
    if value_type ~= "string" and value_type ~= "number" and value_type ~= "boolean" then
        return nil, "span:set_tag: value must be a string, number, or boolean"
    end
    lib.dd_span_set_tag(self, key, tostring(value))
end

local function span_set_error(self)
    lib.dd_span_set_error(self, 1)
end

local function span_set_service(self, service)
    if type(service) ~= "string" then
        return nil, "span:set_service: service must be a string"
    end
    lib.dd_span_set_service(self, service)
end

local function span_inject(self, header_setter)
    if type(header_setter) ~= "function" then
        return nil, "span:inject: header_setter must be a function"
    end
    local setter_cb = ffi.cast("void (*)(const char*, const char*)", function(key, value)
        header_setter(ffi.string(key), ffi.string(value))
    end)
    local inject_ok, inject_err = pcall(lib.dd_span_inject, self, setter_cb)
    setter_cb:free()
    if not inject_ok then
        return nil, inject_err
    end

    return true
end

local function span_finish(self, end_time_ns)
    if end_time_ns == nil or end_time_ns == 0 then
        lib.dd_span_finish(self)
    else
        lib.dd_span_set_end_time(self, end_time_ns)
    end
end

local function span_free(self)
    ffi.gc(self, nil)
    lib.dd_span_free(self)
end

local function span_get_trace_id(self)
    local buf = ffi.new("char[?]", TRACE_ID_BUF_SIZE)
    local len = lib.dd_span_get_trace_id(self, buf, TRACE_ID_BUF_SIZE)
    if len <= 0 then
        return nil, "failed to get trace ID"
    end
    return ffi.string(buf, len)
end

local function span_get_span_id(self)
    local buf = ffi.new("char[?]", SPAN_ID_BUF_SIZE)
    local len = lib.dd_span_get_span_id(self, buf, SPAN_ID_BUF_SIZE)
    if len <= 0 then
        return nil, "failed to get span ID"
    end
    return ffi.string(buf, len)
end

local function span_create_child(self, name, resource, start_time_ns)
    if type(name) ~= "string" then
        return nil, "span:create_child: name must be a string"
    end
    if type(resource) ~= "string" then
        return nil, "span:create_child: resource must be a string"
    end
    local span = lib.dd_span_create_child(self, new_span_options(name, resource, start_time_ns))
    if span == nil then
        return nil, "failed to create child span"
    end
    return ffi.gc(span, lib.dd_span_free)
end

ffi.metatype("struct dd_span_s", {
    __index = {
        set_tag = span_set_tag,
        set_error = span_set_error,
        set_service = span_set_service,
        inject = span_inject,
        finish = span_finish,
        free = span_free,
        get_trace_id = span_get_trace_id,
        get_span_id = span_get_span_id,
        create_child = span_create_child,
    },
})

-------------------------------------------------------------------------------
-- Tracer methods (attached to struct dd_tracer_s via ffi.metatype)
-------------------------------------------------------------------------------

local function tracer_create_span(self, name, resource, start_time_ns)
    if type(name) ~= "string" then
        return nil, "tracer:create_span: name must be a string"
    end
    if type(resource) ~= "string" then
        return nil, "tracer:create_span: resource must be a string"
    end
    local span = lib.dd_tracer_create_span(self, new_span_options(name, resource, start_time_ns))
    if span == nil then
        return nil, "failed to create span"
    end
    return ffi.gc(span, lib.dd_span_free)
end

ffi.metatype("struct dd_tracer_s", {
    __index = {
        create_span = tracer_create_span,
    },
})

-------------------------------------------------------------------------------
-- Tracer lifecycle
-------------------------------------------------------------------------------

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

-------------------------------------------------------------------------------
-- Span extraction (module-level function, needs callback setup)
-------------------------------------------------------------------------------

--- Extract trace context from incoming headers, or create a new root span.
--- Handles FFI callback setup, string pinning, and cleanup internally.
---
--- @param tracer tracer handle
--- @param header_getter function(name) -> string|table|nil
--- @param name string span operation name
--- @param resource string span resource name
--- @param start_time_ns number|nil wall-clock ns since epoch; nil = use current time
--- @return span handle with metatype methods, or nil
local function extract_or_create_span(tracer, header_getter, name, resource, start_time_ns)
    if type(name) ~= "string" then
        return nil, "extract_or_create_span: name must be a string"
    end
    if type(resource) ~= "string" then
        return nil, "extract_or_create_span: resource must be a string"
    end
    if type(header_getter) ~= "function" then
        return nil, "extract_or_create_span: header_getter must be a function"
    end

    local pinned_strings = {}

    local getter_cb = ffi.cast("const char* (*)(const char*)", function(header_name)
        local hname = ffi.string(header_name)
        local value = header_getter(hname)
        -- kong.request.get_header can return a table for multi-value headers;
        -- propagation headers are single-valued, so take the first element.
        if type(value) == "table" then
            value = value[1]
        end
        if value ~= nil then
            pinned_strings[#pinned_strings + 1] = value
            return ffi.cast("const char*", value)
        end
        return nil
    end)

    local opts = new_span_options(name, resource, start_time_ns)
    local extract_ok, span_or_err = pcall(lib.dd_tracer_extract_or_create_span, tracer, getter_cb, opts)

    -- Always clean up callback, even on error.
    getter_cb:free()

    if not extract_ok then
        return nil, span_or_err
    end

    -- NOTE: Must use == nil for FFI pointers; NULL cdata is truthy in LuaJIT.
    if span_or_err == nil then
        return nil, "failed to extract or create span"
    end

    -- Wrap in ffi.gc as a safety net: if an error prevents explicit span:finish(),
    -- the GC will eventually free the C++ span to prevent memory leaks.
    return ffi.gc(span_or_err, lib.dd_span_free)
end

return {
    make_tracer = make_tracer,
    get_or_create = get_or_create,
    extract_or_create_span = extract_or_create_span,
}

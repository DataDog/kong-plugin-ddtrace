local ffi = require("ffi")

-- Load the dd-trace-cpp C binding library.
-- Requires libdd_trace_c to be installed (e.g. in /usr/local/lib/) and ldconfig run.
local ok, lib = pcall(ffi.load, "dd_trace_c")
if not ok then
    error(
        "Failed to load libdd_trace_c: "
            .. tostring(lib)
            .. "\n\nEnsure libdd_trace_c.so is installed and ldconfig has been run."
            .. "\nSee CONTRIBUTING.md for build instructions."
    )
end

-- C function declarations (from dd-trace-cpp/binding/c/include/datadog/c/tracer.h)
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

return lib

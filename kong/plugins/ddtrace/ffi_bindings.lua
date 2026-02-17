local ffi = require("ffi")

-- Load the dd-trace-cpp C binding library.
-- Requires libdd_trace_c to be installed (e.g. in /usr/local/lib/) and ldconfig run.
local ok, lib = pcall(ffi.load, "dd_trace_c")
if not ok then
    error("Failed to load libdd_trace_c: " .. tostring(lib) ..
          "\n\nRun /kong-plugin/pongo-build.sh to build and install the library.")
end

-- C function declarations (from dd-trace-cpp/binding/c/include/datadog/c/tracer.h)
ffi.cdef[[
    typedef void datadog_sdk_conf_t;
    typedef void datadog_sdk_tracer_t;
    typedef void datadog_sdk_span_t;

    typedef const char* (*datadog_sdk_context_read_callback)(const char* key);
    typedef void (*datadog_sdk_context_write_callback)(const char* key, const char* value);

    datadog_sdk_conf_t* datadog_sdk_tracer_conf_new();
    void datadog_sdk_tracer_conf_free(datadog_sdk_conf_t* handle);
    void datadog_sdk_tracer_conf_set(datadog_sdk_conf_t* handle, int option, void* value);

    datadog_sdk_tracer_t* datadog_sdk_tracer_new(datadog_sdk_conf_t* conf_handle);
    void datadog_sdk_tracer_free(datadog_sdk_tracer_t* tracer_handle);

    datadog_sdk_span_t* datadog_sdk_tracer_extract_or_create_span(
        datadog_sdk_tracer_t* tracer_handle,
        datadog_sdk_context_read_callback on_context_read,
        const char* name,
        const char* resource);

    datadog_sdk_span_t* datadog_sdk_span_create_child_with_options(
        datadog_sdk_span_t* span_handle,
        const char* name,
        const char* service,
        const char* resource);

    void datadog_sdk_span_finish(datadog_sdk_span_t* span_handle);
    void datadog_sdk_span_free(datadog_sdk_span_t* span_handle);

    void datadog_sdk_span_set_tag(datadog_sdk_span_t* span_handle, const char* key, const char* value);
    void datadog_sdk_span_set_error(datadog_sdk_span_t* span_handle, int error_value);
    void datadog_sdk_span_set_resource(datadog_sdk_span_t* span_handle, const char* resource);
    void datadog_sdk_span_set_service(datadog_sdk_span_t* span_handle, const char* service);

    void datadog_sdk_span_inject(
        datadog_sdk_span_t* span_handle,
        datadog_sdk_context_write_callback on_context_write);

    int datadog_sdk_span_get_trace_id(datadog_sdk_span_t* span_handle, char* buffer, int buffer_size);
    int datadog_sdk_span_get_span_id(datadog_sdk_span_t* span_handle, char* buffer, int buffer_size);
]]

return lib

-- A thin LuaJIT FFI binding to libdatadog's libdd-ai-usage-ffi, which holds
-- the rules every gateway shares: reading a provider's usage from its
-- response or stream, the metric profiles, the Datadog series and their
-- DogStatsD datagrams, the operation of a passthrough path, error types,
-- provider names and provider ids.
--
-- Values cross the boundary as JSON, except the datagrams a batch writes,
-- which are NUL-separated text. Durations are seconds measured to the
-- millisecond, which 16 significant digits keep.
-- Every buffer the library writes is copied into a Lua string and released
-- before the call returns.
--
-- The library is required: loading this module fails, and with it the
-- plugin, when it cannot be found. It is loaded from DD_AI_USAGE_FFI_LIBRARY
-- (a path) when set; else from lua_package_cpath, where the plugin's rock
-- installs it as libdd_ai_usage_ffi-<arch>.so (x86_64 or aarch64); else by
-- the dynamic loader's own search for libdd_ai_usage_ffi.so.

local ffi = require("ffi")
-- An instance of its own, so that its precision is not Kong's: whole numbers
-- up to 2^53 are written in full.
local cjson = require("cjson.safe").new()
cjson.encode_number_precision(16)

local ffi_string = ffi.string
local type = type
local tonumber = tonumber
local concat = table.concat
local str_find = string.find

local _M = {}

ffi.cdef([[
typedef struct ddog_ai_usage_Batch ddog_ai_usage_Batch;
typedef struct ddog_ai_usage_Stream ddog_ai_usage_Stream;
typedef struct ddog_ai_usage_Buffer { uint8_t *ptr; uintptr_t len; } ddog_ai_usage_Buffer;

int ddog_ai_usage_batch_new(ddog_ai_usage_Batch **out);
int ddog_ai_usage_batch_add_request(const ddog_ai_usage_Batch *batch, const char *input, uintptr_t input_len,
                                    ddog_ai_usage_Buffer *out);
int ddog_ai_usage_batch_set_metrics(const ddog_ai_usage_Batch *batch, const char *input, uintptr_t input_len,
                                    ddog_ai_usage_Buffer *out);
bool ddog_ai_usage_batch_is_empty(const ddog_ai_usage_Batch *batch);
uintptr_t ddog_ai_usage_batch_len(const ddog_ai_usage_Batch *batch);
void ddog_ai_usage_batch_set_max_len(const ddog_ai_usage_Batch *batch, uintptr_t max_len);
uint64_t ddog_ai_usage_batch_dropped(const ddog_ai_usage_Batch *batch);
int ddog_ai_usage_batch_take_dogstatsd_text(const ddog_ai_usage_Batch *batch, const char *constant_tags,
                                            uintptr_t constant_tags_len, uintptr_t max_payload,
                                            uintptr_t *dropped_lines, ddog_ai_usage_Buffer *out);
void ddog_ai_usage_batch_drop(ddog_ai_usage_Batch *batch);
int ddog_ai_usage_parse_provider_response_with(const char *format, uintptr_t format_len, bool embeddings,
                                               uint32_t options, const char *body, uintptr_t body_len,
                                               ddog_ai_usage_Buffer *out);
int ddog_ai_usage_stream_new_with(const char *format, uintptr_t format_len, bool embeddings, uint32_t options,
                                  ddog_ai_usage_Stream **out);
int ddog_ai_usage_stream_feed(ddog_ai_usage_Stream *stream, const char *chunk, uintptr_t chunk_len);
int ddog_ai_usage_stream_take(ddog_ai_usage_Stream *stream, ddog_ai_usage_Buffer *out);
void ddog_ai_usage_stream_drop(ddog_ai_usage_Stream *stream);
int ddog_ai_usage_provider_name(const char *name, uintptr_t name_len, ddog_ai_usage_Buffer *out);
int ddog_ai_usage_operation_name(const char *route, uintptr_t route_len, ddog_ai_usage_Buffer *out);
int ddog_ai_usage_error_type(const char *name, uintptr_t name_len, uint16_t status, ddog_ai_usage_Buffer *out);
int ddog_ai_usage_provider_id_headers(const char *provider_name, uintptr_t provider_name_len,
                                      ddog_ai_usage_Buffer *out);
int ddog_ai_usage_provider_ids(const char *input, uintptr_t input_len, ddog_ai_usage_Buffer *out);
bool ddog_ai_usage_is_person_identifier(const char *value, uintptr_t value_len);
void ddog_ai_usage_buffer_drop(ddog_ai_usage_Buffer *buffer);
]])

local OK = 0

-- The largest DogStatsD datagram over UDP, as the library defines it.
_M.UDP_MAX_PAYLOAD = 1432

local LIBRARY_NAME = "libdd_ai_usage_ffi"

local ARCH_SUFFIX = { x64 = "x86_64", arm64 = "aarch64" }

local function load_library()
    local configured = os.getenv("DD_AI_USAGE_FFI_LIBRARY")
    if configured and configured ~= "" then
        local ok, lib = pcall(ffi.load, configured)
        if ok then
            return lib
        end
        error(
            "ddtrace: cannot load libdd-ai-usage-ffi from DD_AI_USAGE_FFI_LIBRARY="
                .. configured
                .. ": "
                .. tostring(lib)
        )
    end
    local candidates = {}
    local suffix = ARCH_SUFFIX[ffi.arch]
    for _, name in ipairs({ suffix and (LIBRARY_NAME .. "-" .. suffix) or LIBRARY_NAME, LIBRARY_NAME }) do
        local path = package.searchpath(name, package.cpath)
        if path then
            candidates[#candidates + 1] = path
        end
    end
    -- The loader's own search: "dd_ai_usage_ffi" is tried as
    -- libdd_ai_usage_ffi.so.
    candidates[#candidates + 1] = "dd_ai_usage_ffi"
    local errors = {}
    for _, candidate in ipairs(candidates) do
        local ok, lib = pcall(ffi.load, candidate)
        if ok then
            return lib
        end
        errors[#errors + 1] = tostring(lib)
    end
    error(
        "ddtrace: cannot load libdatadog's libdd-ai-usage-ffi, which the plugin requires"
            .. " (its rock ships it; see doc/configuration.md): "
            .. concat(errors, "; ")
    )
end

local lib = load_library()

-- One buffer per worker: every call copies it out and releases it before
-- returning, with no yield in between.
local buffer = ffi.new("ddog_ai_usage_Buffer[1]")

local function take_buffer()
    local b = buffer[0]
    local text = ""
    if b.ptr ~= nil and b.len > 0 then
        text = ffi_string(b.ptr, b.len)
    end
    lib.ddog_ai_usage_buffer_drop(buffer)
    return text
end

-- A call whose output is JSON: the decoded output, or nil and the error.
local function json_result(status)
    local text = take_buffer()
    local value = cjson.decode(text)
    if status == OK then
        return value
    end
    local err = type(value) == "table" and type(value.error) == "table" and value.error
    return nil, err and (tostring(err.code) .. ": " .. tostring(err.message)) or ("status " .. tostring(status))
end

-- A call whose output is text: the text, or nil.
local function text_result(status)
    local text = take_buffer()
    if status == OK then
        return text
    end
    return nil
end

local function encode(document)
    local input, err = cjson.encode(document)
    if not input then
        return nil, "cannot encode: " .. tostring(err)
    end
    return input
end

-- Batch

local batch_methods = {}
local batch_mt = { __index = batch_methods }

local dropped_lines = ffi.new("uintptr_t[1]")
local NUL = "\0"

function _M.new_batch()
    local out = ffi.new("ddog_ai_usage_Batch*[1]")
    if lib.ddog_ai_usage_batch_new(out) ~= OK then
        return nil, "cannot create a batch"
    end
    return setmetatable({ handle = ffi.gc(out[0], lib.ddog_ai_usage_batch_drop) }, batch_mt)
end

-- The metric names kept of every document, set once on the batch so that
-- documents leave them out and the library parses them once.
function batch_methods:set_metrics(names)
    local input, err = encode(names)
    if not input then
        return nil, err
    end
    return json_result(lib.ddog_ai_usage_batch_set_metrics(self.handle, input, #input, buffer))
end

-- Add the documents of one request (its provider attempt, token breakdown
-- and gateway request) together: true, or nil and the reason one was
-- rejected. A full batch drops the request whole, each document counted by
-- take_dropped(), and it still returns true. No output is built on success.
function batch_methods:add_request(documents)
    local input, err = encode(documents)
    if not input then
        return nil, err
    end
    if lib.ddog_ai_usage_batch_add_request(self.handle, input, #input, nil) == OK then
        return true
    end
    -- Rejected, which adds nothing: ask again for the reason.
    return json_result(lib.ddog_ai_usage_batch_add_request(self.handle, input, #input, buffer))
end

function batch_methods:is_empty()
    return lib.ddog_ai_usage_batch_is_empty(self.handle)
end

-- The points the batch holds: one per counter series and one per histogram
-- sample.
function batch_methods:len()
    return tonumber(lib.ddog_ai_usage_batch_len(self.handle))
end

-- Bound the batch to max_len points (0 lifts the bound), and ask for it to
-- be sent early from high_water points (0 never).
function batch_methods:set_limits(max_len, high_water)
    lib.ddog_ai_usage_batch_set_max_len(self.handle, max_len)
    self.high_water = high_water
end

-- Whether the batch reached its high-water mark.
function batch_methods:is_full()
    return (self.high_water or 0) > 0 and self:len() >= self.high_water
end

-- The documents dropped for a full batch since the last call.
function batch_methods:take_dropped()
    local dropped = tonumber(lib.ddog_ai_usage_batch_dropped(self.handle))
    local since = dropped - (self.dropped_reported or 0)
    self.dropped_reported = dropped
    return since
end

-- Take every point as DogStatsD datagrams, each at most max_payload bytes,
-- and the number of lines dropped for being longer than that.
function batch_methods:take_dogstatsd(constant_tags, max_payload)
    constant_tags = constant_tags or ""
    dropped_lines[0] = 0
    local status = lib.ddog_ai_usage_batch_take_dogstatsd_text(
        self.handle,
        constant_tags,
        #constant_tags,
        max_payload or _M.UDP_MAX_PAYLOAD,
        dropped_lines,
        buffer
    )
    if status ~= OK then
        return json_result(status)
    end
    local text = take_buffer()
    local datagrams = {}
    local at = 1
    while at <= #text do
        local nul = str_find(text, NUL, at, true)
        datagrams[#datagrams + 1] = string.sub(text, at, (nul or #text + 1) - 1)
        if not nul then
            break
        end
        at = nul + 1
    end
    return datagrams, tonumber(dropped_lines[0])
end

-- Provider responses

-- Usage is read with inclusive totals (cache in the input, reasoning in the
-- output), as gen_ai.client.inference.usage.input_tokens and output_tokens
-- count them.
local INCLUSIVE_TOTALS = 1

-- {usage, response_model, service_tier, outcome, error_name, error_type}
-- for a whole response body.
function _M.parse_provider_response(format, embeddings, body)
    format = format or ""
    return json_result(
        lib.ddog_ai_usage_parse_provider_response_with(
            format,
            #format,
            embeddings == true,
            INCLUSIVE_TOTALS,
            body,
            #body,
            buffer
        )
    )
end

local stream_methods = {}
local stream_mt = { __index = stream_methods }

function _M.new_stream(format, embeddings)
    format = format or ""
    local out = ffi.new("ddog_ai_usage_Stream*[1]")
    if lib.ddog_ai_usage_stream_new_with(format, #format, embeddings == true, INCLUSIVE_TOTALS, out) ~= OK then
        return nil, "cannot read a stream in format " .. format
    end
    return setmetatable({ handle = ffi.gc(out[0], lib.ddog_ai_usage_stream_drop) }, stream_mt)
end

function stream_methods:feed(chunk)
    if self.handle and #chunk > 0 then
        lib.ddog_ai_usage_stream_feed(self.handle, chunk, #chunk)
    end
end

-- What the stream reported; the stream is released, its state taken
-- rather than copied.
function stream_methods:finish()
    local handle = self.handle
    if not handle then
        return nil, "the stream was finished"
    end
    self.handle = nil
    ffi.gc(handle, nil)
    return json_result(lib.ddog_ai_usage_stream_take(handle, buffer))
end

-- Helpers

function _M.provider_name(name)
    if type(name) ~= "string" then
        return nil
    end
    return text_result(lib.ddog_ai_usage_provider_name(name, #name, buffer))
end

-- The gen_ai.operation.name of a Kong route type or an upstream path, or
-- nil for one the profiles do not measure.
function _M.operation_name(route)
    if type(route) ~= "string" then
        return nil
    end
    return text_result(lib.ddog_ai_usage_operation_name(route, #route, buffer))
end

-- The error.type of a call from its HTTP status (nil for none), whether it
-- got no response or timed out, and its error name; nil when it did not
-- fail.
function _M.error_type_for_failure(status, no_response, timed_out, name)
    if no_response then
        return (timed_out or status == 504) and "timeout_error" or "api_connection_error"
    end
    if timed_out then
        return "timeout_error"
    end
    if status == nil or status == 200 then
        return nil
    end
    name = name or ""
    -- A status other than 200 that is not a failure is api_error.
    return text_result(lib.ddog_ai_usage_error_type(name, #name, status, buffer)) or "api_error"
end

-- The lower-case response headers provider_ids reads for a provider, as a
-- list; cached per provider, since the rule only changes with the library.
local id_headers = {}

function _M.provider_id_headers(provider_name)
    provider_name = provider_name or ""
    local headers = id_headers[provider_name]
    if headers == nil then
        headers = json_result(lib.ddog_ai_usage_provider_id_headers(provider_name, #provider_name, buffer)) or {}
        id_headers[provider_name] = headers
    end
    return headers
end

-- {attribute: value} from a provider's response headers and model ARNs.
function _M.provider_ids(provider_name, headers, models)
    local input, err = encode({
        provider_name = provider_name,
        headers = headers or {},
        models = models and models[1] ~= nil and models or cjson.empty_array,
    })
    if not input then
        return nil, err
    end
    return json_result(lib.ddog_ai_usage_provider_ids(input, #input, buffer))
end

function _M.is_person_identifier(value)
    return type(value) == "string" and lib.ddog_ai_usage_is_person_identifier(value, #value)
end

return _M

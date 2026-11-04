-- A thin LuaJIT FFI binding to libdatadog's libdd-ai-usage-ffi, which holds
-- the rules every gateway shares: reading a provider's usage from its
-- response or stream, the metric profiles, the Datadog series and their
-- DogStatsD datagrams, provider names, error types and provider ids.
--
-- Values cross the boundary as JSON. Every buffer the library writes is
-- copied into a Lua string and released before the call returns.
--
-- The library is found at DD_AI_USAGE_FFI_LIBRARY when set, else on
-- lua_package_cpath, else by the dynamic loader's own search.

local ffi = require("ffi")
local cjson = require("cjson.safe")

local ffi_string = ffi.string
local type = type
local pairs = pairs
local sfmt = string.format
local concat = table.concat
local huge = math.huge

local _M = {}

ffi.cdef([[
typedef struct ddog_ai_usage_Batch ddog_ai_usage_Batch;
typedef struct ddog_ai_usage_Stream ddog_ai_usage_Stream;
typedef struct ddog_ai_usage_Buffer { uint8_t *ptr; uintptr_t len; } ddog_ai_usage_Buffer;

int ddog_ai_usage_project(const char *input, uintptr_t input_len, ddog_ai_usage_Buffer *out);
int ddog_ai_usage_batch_new(ddog_ai_usage_Batch **out);
int ddog_ai_usage_batch_add(const ddog_ai_usage_Batch *batch, const char *input, uintptr_t input_len,
                            ddog_ai_usage_Buffer *out);
bool ddog_ai_usage_batch_is_empty(const ddog_ai_usage_Batch *batch);
int ddog_ai_usage_batch_take_dogstatsd(const ddog_ai_usage_Batch *batch, const char *constant_tags,
                                       uintptr_t constant_tags_len, uintptr_t max_payload,
                                       ddog_ai_usage_Buffer *out);
void ddog_ai_usage_batch_drop(ddog_ai_usage_Batch *batch);
int ddog_ai_usage_parse_provider_response(const char *format, uintptr_t format_len, bool embeddings,
                                          const char *body, uintptr_t body_len, ddog_ai_usage_Buffer *out);
int ddog_ai_usage_stream_new(const char *format, uintptr_t format_len, bool embeddings,
                             ddog_ai_usage_Stream **out);
int ddog_ai_usage_stream_feed(ddog_ai_usage_Stream *stream, const char *chunk, uintptr_t chunk_len);
int ddog_ai_usage_stream_finish(const ddog_ai_usage_Stream *stream, ddog_ai_usage_Buffer *out);
void ddog_ai_usage_stream_drop(ddog_ai_usage_Stream *stream);
int ddog_ai_usage_provider_name(const char *name, uintptr_t name_len, ddog_ai_usage_Buffer *out);
int ddog_ai_usage_error_type(const char *name, uintptr_t name_len, uint16_t status, ddog_ai_usage_Buffer *out);
int ddog_ai_usage_provider_ids(const char *input, uintptr_t input_len, ddog_ai_usage_Buffer *out);
bool ddog_ai_usage_is_person_identifier(const char *value, uintptr_t value_len);
void ddog_ai_usage_buffer_drop(ddog_ai_usage_Buffer *buffer);
]])

local OK = 0

-- The largest DogStatsD datagram over UDP, as the library defines it.
_M.UDP_MAX_PAYLOAD = 1432

local LIBRARY_NAMES = { "libdd_ai_usage_ffi", "liblibdd_ai_usage_ffi" }

local function load_library()
    local candidates = {}
    local configured = os.getenv("DD_AI_USAGE_FFI_LIBRARY")
    if configured and configured ~= "" then
        candidates[1] = configured
    else
        for _, name in ipairs(LIBRARY_NAMES) do
            local path = package.searchpath(name, package.cpath)
            if path then
                candidates[#candidates + 1] = path
            end
        end
        candidates[#candidates + 1] = "dd_ai_usage_ffi"
        candidates[#candidates + 1] = "libdd_ai_usage_ffi"
    end
    local last_err
    for _, candidate in ipairs(candidates) do
        local ok, lib = pcall(ffi.load, candidate)
        if ok then
            return lib
        end
        last_err = lib
    end
    return nil, last_err
end

local lib, load_err = load_library()
_M.load_error = load_err

function _M.available()
    return lib ~= nil
end

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

-- JSON for a request document. Costs and durations cross as 17 significant
-- digits, which read back as the same double (cjson stops at 16). A table
-- with a [1] is an array, any other an object.
local function encode_value(value, out)
    local kind = type(value)
    if kind == "string" then
        out[#out + 1] = cjson.encode(value)
    elseif kind == "number" then
        if value ~= value or value == huge or value == -huge then
            return nil, "a number is not finite"
        end
        out[#out + 1] = value == math.floor(value) and value < 2 ^ 53 and value > -2 ^ 53
            and sfmt("%d", value) or sfmt("%.17g", value)
    elseif kind == "boolean" then
        out[#out + 1] = value and "true" or "false"
    elseif kind == "table" then
        if value[1] ~= nil then
            out[#out + 1] = "["
            for i = 1, #value do
                if i > 1 then
                    out[#out + 1] = ","
                end
                local ok, err = encode_value(value[i], out)
                if not ok then
                    return nil, err
                end
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local first = true
            for k, v in pairs(value) do
                if type(k) ~= "string" then
                    return nil, "a key is not a string"
                end
                out[#out + 1] = first and cjson.encode(k) .. ":" or "," .. cjson.encode(k) .. ":"
                first = false
                local ok, err = encode_value(v, out)
                if not ok then
                    return nil, err
                end
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = "null"
    end
    return true
end

local function encode(document)
    local out = {}
    local ok, err = encode_value(document, out)
    if not ok then
        return nil, "cannot encode: " .. err
    end
    return concat(out)
end

-- {"series": [...], "issues": [...]} for one request document.
function _M.project(document)
    local input, err = encode(document)
    if not input then
        return nil, err
    end
    return json_result(lib.ddog_ai_usage_project(input, #input, buffer))
end

-- Batch

local batch_methods = {}
local batch_mt = { __index = batch_methods }

function _M.new_batch()
    local out = ffi.new("ddog_ai_usage_Batch*[1]")
    if lib.ddog_ai_usage_batch_new(out) ~= OK then
        return nil, "cannot create a batch"
    end
    return setmetatable({ handle = ffi.gc(out[0], lib.ddog_ai_usage_batch_drop), documents = 0 }, batch_mt)
end

-- Add a request document; true, or nil and the reason it was rejected.
function batch_methods:add(document)
    local input, err = encode(document)
    if not input then
        return nil, err
    end
    local result
    result, err = json_result(lib.ddog_ai_usage_batch_add(self.handle, input, #input, buffer))
    if not result then
        return nil, err
    end
    self.documents = self.documents + 1
    return true
end

function batch_methods:is_empty()
    return lib.ddog_ai_usage_batch_is_empty(self.handle)
end

-- Take every point as DogStatsD datagrams, each at most max_payload bytes.
function batch_methods:take_dogstatsd(constant_tags, max_payload)
    constant_tags = constant_tags or ""
    local result, err = json_result(lib.ddog_ai_usage_batch_take_dogstatsd(
        self.handle, constant_tags, #constant_tags, max_payload or _M.UDP_MAX_PAYLOAD, buffer))
    self.documents = 0
    if not result then
        return nil, err
    end
    return result.datagrams or {}
end

-- Provider responses

-- {usage, response_model, service_tier, outcome, error_name, error_type}
-- for a whole response body.
function _M.parse_provider_response(format, embeddings, body)
    format = format or ""
    return json_result(lib.ddog_ai_usage_parse_provider_response(
        format, #format, embeddings == true, body, #body, buffer))
end

local stream_methods = {}
local stream_mt = { __index = stream_methods }

function _M.new_stream(format, embeddings)
    format = format or ""
    local out = ffi.new("ddog_ai_usage_Stream*[1]")
    if lib.ddog_ai_usage_stream_new(format, #format, embeddings == true, out) ~= OK then
        return nil, "cannot read a stream in format " .. format
    end
    return setmetatable({ handle = ffi.gc(out[0], lib.ddog_ai_usage_stream_drop) }, stream_mt)
end

function stream_methods:feed(chunk)
    if self.handle and #chunk > 0 then
        lib.ddog_ai_usage_stream_feed(self.handle, chunk, #chunk)
    end
end

-- What the stream reported; the stream is released.
function stream_methods:finish()
    local handle = self.handle
    if not handle then
        return nil, "the stream was finished"
    end
    local result, err = json_result(lib.ddog_ai_usage_stream_finish(handle, buffer))
    self.handle = nil
    ffi.gc(handle, nil)
    lib.ddog_ai_usage_stream_drop(handle)
    return result, err
end

-- Helpers

function _M.provider_name(name)
    if type(name) ~= "string" then
        return nil
    end
    return text_result(lib.ddog_ai_usage_provider_name(name, #name, buffer))
end

-- The error.type of a failure from its error name and HTTP status (0 for
-- none), or nil when neither says it failed.
function _M.error_type(name, status)
    name = name or ""
    return text_result(lib.ddog_ai_usage_error_type(name, #name, status or 0, buffer))
end

-- {attribute: value} from a provider's response headers and model ARNs.
function _M.provider_ids(provider_name, headers, models)
    local input, err = encode({ provider_name = provider_name, headers = headers or {}, models = models or {} })
    if not input then
        return nil, err
    end
    return json_result(lib.ddog_ai_usage_provider_ids(input, #input, buffer))
end

function _M.is_person_identifier(value)
    return type(value) == "string" and lib.ddog_ai_usage_is_person_identifier(value, #value)
end

return _M

local ffi = require("ffi")

ffi.cdef [[
  typedef struct TracerConfig TracerConfig;
  typedef struct Tracer Tracer;
  typedef struct Span Span;
  typedef const char* (*ReaderFunc)(const char*);
  typedef void (*WriterFunc)(const char*, const char*);

  // Tracer Config
  TracerConfig* datadog_sdk_tracer_conf_new();
  void datadog_sdk_tracer_conf_free(TracerConfig*);
  void datadog_sdk_tracer_conf_set(TracerConfig*, int, void*);

  // Tracer
  Tracer* datadog_sdk_tracer_new(TracerConfig*);
  void datadog_sdk_tracer_free(Tracer*);
  Span* datadog_sdk_tracer_create_span(Tracer*, const char*);
  Span* datadog_sdk_tracer_extract_or_create_span(Tracer*, ReaderFunc, const char*, const char*);

  // Span
  void datadog_sdk_span_free(Span*);
  void datadog_sdk_span_set_tag(Span*, const char*, const char*);
  void datadog_sdk_span_set_error(void*, bool);
  void datadog_sdk_span_set_error_message(void*, const char*);
  void datadog_sdk_span_inject(Span*, WriterFunc);
  Span* datadog_sdk_span_create_child(Span*, const char*);
  void datadog_sdk_span_finish(Span*);
]]

local lib_ddtrace = ffi.load("ddtrace.so")

-- Keep config strings alive to prevent GC
local tracer_config_strings = {}

local function make_tracer(lua_config)
  assert(lua_config == nil or type(lua_config) == "table")
  
  ngx.log(ngx.NOTICE, "DEBUG make_tracer: lua_config = " .. tostring(lua_config))
  if lua_config then
    for k, v in pairs(lua_config) do
      ngx.log(ngx.NOTICE, "DEBUG make_tracer: config[" .. tostring(k) .. "] = " .. tostring(v))
    end
  end

  local options = {
    ["service"] = 0,
    ["env"] = 1,
    ["version"] = 2,
    ["agent_url"] = 3,
  }

  local config = lib_ddtrace.datadog_sdk_tracer_conf_new()

  if config == nil then
    ngx.log(ngx.ERR, "DEBUG make_tracer: datadog_sdk_tracer_conf_new returned nil")
    return nil
  end
  
  if not lua_config then
    ngx.log(ngx.NOTICE, "DEBUG make_tracer: lua_config is nil, creating tracer with empty config")
    local tracer = lib_ddtrace.datadog_sdk_tracer_new(config)
    return tracer
  end

  for k, v in pairs(lua_config) do
    if k == "service" then
      if type(v) ~= "string" then
        lib_ddtrace.datadog_sdk_tracer_conf_free(config)
        return nil
      end
      if #v == 0 then
        ngx.log(ngx.ERR, "DEBUG make_tracer: service name is empty, skipping")
        -- Skip empty service names - let C++ use environment variable or fail with clear error
        goto continue
      end
      ngx.log(ngx.NOTICE, "DEBUG make_tracer: setting service = '" .. v .. "', length = " .. #v)
      -- Create a C string and store it to keep it alive
      tracer_config_strings.service = ffi.new("char[?]", #v + 1)
      ffi.copy(tracer_config_strings.service, v, #v)
      -- Verify null termination
      ngx.log(ngx.NOTICE, "DEBUG make_tracer: service C string = '" .. ffi.string(tracer_config_strings.service) .. "'")
      lib_ddtrace.datadog_sdk_tracer_conf_set(config, options.service, ffi.cast("void*", tracer_config_strings.service))
      ngx.log(ngx.NOTICE, "DEBUG make_tracer: datadog_sdk_tracer_conf_set called for service")
    elseif k == "env" then
      if type(v) ~= "string" then
        lib_ddtrace.datadog_sdk_tracer_conf_free(config)
        return nil
      end
      if #v == 0 then
        goto continue
      end
      tracer_config_strings.env = ffi.new("char[?]", #v + 1)
      ffi.copy(tracer_config_strings.env, v, #v)
      lib_ddtrace.datadog_sdk_tracer_conf_set(config, options.env, ffi.cast("void*", tracer_config_strings.env))
    elseif k == "version" then
      if type(v) ~= "string" then
        lib_ddtrace.datadog_sdk_tracer_conf_free(config)
        return nil
      end
      if #v == 0 then
        goto continue
      end
      tracer_config_strings.version = ffi.new("char[?]", #v + 1)
      ffi.copy(tracer_config_strings.version, v, #v)
      lib_ddtrace.datadog_sdk_tracer_conf_set(config, options.version, ffi.cast("void*", tracer_config_strings.version))
    elseif k == "agent_url" then
      if type(v) ~= "string" then
        lib_ddtrace.datadog_sdk_tracer_conf_free(config)
        return nil
      end
      if #v == 0 then
        goto continue
      end
      tracer_config_strings.agent_url = ffi.new("char[?]", #v + 1)
      ffi.copy(tracer_config_strings.agent_url, v, #v)
      lib_ddtrace.datadog_sdk_tracer_conf_set(config, options.agent_url, ffi.cast("void*", tracer_config_strings.agent_url))
    end
    ::continue::
  end

  local tracer = lib_ddtrace.datadog_sdk_tracer_new(config)

  -- Don't free the config - the tracer might need it
  -- Store it to keep it alive
  tracer_config_strings._config = config

  -- Don't add GC finalizer - we'll manage lifecycle manually
  return tracer
end

-- TRACER

local tracer_config_index = {
  set = lib_ddtrace.datadog_sdk_tracer_conf_set
}

local tracer_config_mt = ffi.metatype("TracerConfig", {
  __index = tracer_config_index
})

local function create_span_gc(self, name)
  local span = lib_ddtrace.datadog_sdk_tracer_create_span(self, name)
  return ffi.gc(span, lib_ddtrace.datadog_sdk_span_free)
end

local function extract_or_create_span_gc(self, f)
  return ffi.gc(lib_ddtrace.datadog_sdk_tracer_extract_or_create_span(self, f), lib_ddtrace.datadog_sdk_span_free)
end

local function create_child_no_gc(self, name)
  return lib_ddtrace.datadog_sdk_span_create_child(self, name)
end

local function extract(tracer, callback, span_options)
  -- Just use a plain function without ffi.cast - LuaJIT handles conversion
  local reader = function(key)
    if key == nil then
      return nil
    end
    local key_str = ffi.string(key)
    local value = callback(key_str)
    return value
  end

  local span = lib_ddtrace.datadog_sdk_tracer_extract_or_create_span(tracer, reader, span_options.name, span_options.resource)

  if span == nil then
    error("Failed to create span")
  end
  -- Don't add GC finalizer - we'll call finish() manually
  return span
end

-- TODO: Find a way to tie span lifecycle to the tracer?
local tracer_index = {
  create_span = lib_ddtrace.datadog_sdk_tracer_create_span,
  extract_or_create_span = extract,
}

local tracer_mt = ffi.metatype("Tracer", {
  __index = tracer_index
})

-- SPAN

local function finish_span(span)
  ffi.gc(span, nil)
  lib_ddtrace.datadog_sdk_span_free(span)
end

local function set_tag(span, tag, value)
  lib_ddtrace.datadog_sdk_span_set_tag(span, tag, tostring(value))
end

local function inject(span, callback)
  local writer = function(key, value)
    callback(ffi.string(key), ffi.string(value))
  end

  lib_ddtrace.datadog_sdk_span_inject(span, writer)
end

local span_index = {
  create_child = create_child_no_gc,
  inject_span = inject,
  set_tag = set_tag,
  set_error = lib_ddtrace.datadog_sdk_span_set_error,
  set_error_message = lib_ddtrace.datadog_sdk_span_set_error_message,
  finish = lib_ddtrace.datadog_sdk_span_free,
}

local span_mt = ffi.metatype("Span", {
  __index = span_index
})

return {
  make_tracer = make_tracer,
}

local ffi = require("ffi")

ffi.cdef [[
  typedef struct TracerConfig TracerConfig;
  typedef struct Tracer Tracer;
  typedef struct Span Span;
  typedef const char* (*ReaderFunc)(const char*);
  typedef void (*WriterFunc)(const char*, const char*);

  // Tracer Config
  TracerConfig* tracer_config_new();
  void tracer_config_free(TracerConfig*);
  void tracer_config_set(TracerConfig*, int, void*);

  // Tracer
  Tracer* tracer_new(TracerConfig*);
  void tracer_free(Tracer*);
  Span* tracer_create_span(Tracer*, const char*);
  Span* tracer_extract_or_create_span(Tracer*, ReaderFunc, const char*, const char*);

  // Span
  void span_free(Span*);
  void span_set_tag(Span*, const char*, const char*);
  void span_set_error(void*, bool);
  void span_set_error_message(void*, const char*);
  void span_inject(Span*, WriterFunc);
  Span* span_create_child(Span*, const char*);
  void span_finish(Span*);
]]

local lib_ddtrace = ffi.load("ddtrace.so")

local function make_tracer(lua_config)
  assert(lua_config == nil or type(lua_config) == "table")

  local options = {
    ["service"] = 0,
    ["env"] = 1,
    ["version"] = 2,
    ["agent_url"] = 3,
  }

  local config = ffi.gc(lib_ddtrace.tracer_config_new(), lib_ddtrace.tracer_config_free)
  for k, v in pairs(lua_config) do
    if k == "service" then
      if type(v) ~= "string" then
        return nil
        -- goto error
      end
      config:set(options.service, ffi.cast("void*", v))
    elseif k == "env" then
      if type(v) ~= "string" then
        return nil
      end
      config:set(options.env, ffi.cast("void*", v))
    elseif k == "version" then
      if type(v) ~= "string" then
        return nil
      end
      config:set(options.version, ffi.cast("void*", v))
    elseif k == "agent_url" then
      if type(v) ~= "string" then
        return nil
      end
      config:set(options.agent_url, ffi.cast("void*", v))
    end
  end

  -- return lib_ddtrace.tracer_new(config)
  return ffi.gc(lib_ddtrace.tracer_new(config), lib_ddtrace.tracer_free)

  -- goto ::error::
  -- return nil
end

-- TRACER

local tracer_config_index = {
  set = lib_ddtrace.tracer_config_set
}

local tracer_config_mt = ffi.metatype("TracerConfig", {
  __index = tracer_config_index
})

local function create_span_gc(self, name)
  local span = lib_ddtrace.tracer_create_span(self, name)
  return ffi.gc(span, lib_ddtrace.span_free)
end

local function extract_or_create_span_gc(self, f)
  return ffi.gc(lib_ddtrace.tracer_extract_or_create_span(self, f), lib_ddtrace.span_free)
end

local function create_child_gc(self, name)
  return ffi.gc(lib_ddtrace.span_create_child(self, name), lib_ddtrace.span_free)
end

local function extract(tracer, callback, span_options)
  local reader = function(key)
    return callback(ffi.string(key))
  end

  return lib_ddtrace.tracer_extract_or_create_span(tracer, reader, span_options.name, span_options.resource)
end

-- TODO: Find a way to tie span lifecycle to the tracer?
local tracer_index = {
  create_span = lib_ddtrace.tracer_create_span,
  extract_or_create_span = extract,
}

local tracer_mt = ffi.metatype("Tracer", {
  __index = tracer_index
})

-- SPAN

local function finish_span(span)
  ffi.gc(span, nil)
  lib_ddtrace.span_free(span)
end

local function set_tag(span, tag, value)
  lib_ddtrace.span_set_tag(span, tag, tostring(value))
end

local function inject(span, callback)
  local writer = function(key, value)
    callback(ffi.string(key), ffi.string(value))
  end

  lib_ddtrace.span_inject(span, writer)
end

local span_index = {
  create_child = lib_ddtrace.span_create_child,
  inject_span = inject,
  set_tag = set_tag,
  set_error = lib_ddtrace.span_set_error,
  set_error_message = lib_ddtrace.span_set_error_message,
  finish = lib_ddtrace.span_free,
  -- finish = finish_span,
}

local span_mt = ffi.metatype("Span", {
  __index = span_index
})

return {
  make_tracer = make_tracer,
}

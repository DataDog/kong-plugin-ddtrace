local ffi = require "ffi"
ffi.cdef[[
    int clock_gettime(clockid_t clk_id, struct timespec *tp);
]]

local CLOCK_REALTIME = 0

-- NOTE: ngx.now in microseconds
local function ngx_now_ns(tp)
  return tp and tp * 1000000LL or ngx.now() * 1000000000LL
end

local function gettime_now_ns(_)
  local tp = assert(ffi.new("struct timespec[?]", 1))
  ffi.C.clock_gettime(CLOCK_REALTIME, tp)

  local result = (tp[0].tv_sec * 1000000000) + tp[0].tv_nsec
  return result
end

local function new(conf)
  if conf.disable_high_resolution_clock then
    return ngx_now_ns
  else
    return gettime_now_ns
  end
end

return {
  new = new
}

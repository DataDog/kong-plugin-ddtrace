# Shared Variables

The plugin shares variables that can be accessed by other plugins through [kong.ctx.shared](https://docs.konghq.com/gateway/latest/plugin-development/pdk/kong.ctx/#kongctxshared).

- `kong_shared.datadog_sdk_trace_id` is the TraceID of the current request.
- `kong_shared.datadog_sdk_span_id` is the SpanID of the current request.

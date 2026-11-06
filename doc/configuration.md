# Configuration

The plugin supports a number of configuration options. These can be supplied when registering the plugin.

## Applying Configurations
Kong support a wide variety of way to configure the plugin. It can done using [Kong Admin API]( configurations) or opt for the [Declarative Configuration in DB-less mode](https://docs.konghq.com/gateway/latest/production/deployment-topologies/db-less-and-declarative-config/). In Kubernetes environments, numerous configuration methods exist, which are not covered here to keep the documentation concise. However, you can derive these methods based on the provided examples.

## Configuration Precedence
Configuration can be set either through the plugin configuration field or environment variables, each with its precedence order. Here is the precedence sequence:
1. Environment variables.
2. Plugin configuration field.
3. Default value.

## Configuration Fields

| Name | Environment Variable | Description | Since | Type | Default |
| ---- | -------------------- | ----------- | ----- | ---- | ------- |
| `agent_host` | `DD_AGENT_HOST` | Hostname or IP to reach the Datadog Agent | `v0.2.0` | `string` | `localhost` |
| `trace_agent_port` | `DD_TRACE_AGENT_PORT` | Port to reach the Datadog Agent | `v0.2.0` | `number` | `8126` |
| `trace_agent_url` | `DD_TRACE_AGENT_URL` | URL used to reach the Datadog Agent | `v0.2.0` | `string` | `http://localhost:8126` |
| `service_name` | `DD_SERVICE` | Name of the service that is producing traces | `v0.0.1` | `string` | Service registered by Kong or `kong` |
| `environment` | `DD_ENV` | Add `env` tag for [Unified Service Tagging](https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/?tab=kubernetes)  | `v0.0.1` | `string` | `nil` |
| `version` | `DD_VERSION` | Sets the version of the service and add `version` tag for [Unified Service Tagging](https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/?tab=kubernetes) | `v0.2.0` | `string` | `nil` |
| `static_tags` |  | List of tags to be added to root spans | `v0.0.1` | `array[tag] with tag = {name=str, value=str}]` | `nil` |
| `injection_propagation_styles` |  | Propagation style used for injecting trace context | `v0.2.0` | `array[str]` | `{ "datadog", "tracecontext"}` |
| `extraction_propagation_styles` |  | Propagation style used for extracting trace context. Values are limited to `datadog` and `tracecontext`.  | `v0.2.0` | `array[str]` | `{ "datadog", "tracecontext"}` |
| `initial_sample_rate` | | Set the sampling rate for all generated traces. The value must be between `0.0` and `1.0` (inclusive) | `v0.0.1` | `float` | `1.0` |
| `intial_samples_per_second` | | Maximum number of traces allowed to be submitted per second | `v0.0.1` | `number` | `100` |
| `resource_name_rule` | | Replace matching resources to lower the cardinality on resource names | `v0.0.1` | `array[rule] with rule = {match=str, replacement=str}]` | `nil` |
| `header_tags` |  | Set HTTP Headers as root tags | `v0.2.0` | `array[header_tag] with header_tag = {header=str, tag=str}]` | `nil` |
| `startup_log` | `DD_TRACE_STARTUP_LOGS` | Log the tracer configuration once the tracer is fully initialized and every time there's a config update | `v0.2.3` | `boolean` | `true` |
| `ai_usage_metrics_enabled` | | Send LLM usage and cost metrics for requests handled by Kong's AI Proxy plugin. See [LLM Usage and Cost Metrics](#llm-usage-and-cost-metrics) | unreleased | `boolean` | `false` |
| `dogstatsd_port` | `DD_DOGSTATSD_PORT` | DogStatsD port of the Datadog Agent, on `agent_host`, that LLM usage metrics are sent to | unreleased | `number` | `8125` |
| `ai_usage_metrics_flush_interval` | | Seconds between two sends of LLM usage metrics | unreleased | `number` | `10` |
| `ai_usage_metrics_tags` | | Optional tags to add to LLM usage metrics: `provider_account`, `project`, `route`, `destination`, `key_alias`, `user`, `service` | unreleased | `array[str]` | `{}` |
| `ai_usage_metrics_api_key_id` | | Id of the provider API key the route uses, as shown in the provider's console, sent as `trajectory.request.api_key_id` | unreleased | `string` | `nil` |
| `ai_usage_metrics_provider_account_id` | | Provider account (organization) the route is billed to, sent as `trajectory.request.provider_account_id` | unreleased | `string` | `nil` |
| `ai_usage_metrics_project_id` | | Provider project the route is billed to, sent as `trajectory.request.project_id` | unreleased | `string` | `nil` |

## Sampling Controls

Sampling of traces is required in environments with high traffic load to reduce the amount of trace data produced and ingested by Datadog.

By default, sampling rates are provided by the Datadog agent, and additional controls are available if necessary using configuration of `initial_sample_rate` and `initial_samples_per_second`.

The `initial_sample_rate` can be set to a value between 0.0 (0%) and 1.0 (100%), and this is limited by the setting for `initial_samples_per_second` (default: 100).
After that amount of sampled traces has been exceeded, traces will not be sampled.

For example with `initial_sample_rate=0.1`, `initial_samples_per_second=5` and a traffic rate of 100 RPS:
- The first 40-50 requests per second will be sampled at 10% until 5 traces have been sampled
- The remaining 50-60 requests for that second will not be sampled.

`--data 'config.initial_samples_per_second=100' --data 'config.initial_sample_rate=1.0'`

## Resource Name Rules

The resource name represents a common access method and resource being used by a service. For Kong, this is typically the HTTP request method, and part of the URI.

By default, the full URI will be used. This can lead to a high number of unique values (cardinality), or exposing IDs and tokens contained in the URI.
To avoid this, resource name rules are used to match path of the URI, and replace the resource name with either the matched part or a user-configured replacement value.

The required `match` field is a regular expression, implicitly anchored to the beginning of the URI value.

The optional `replacement` field is used to provide an updated value for the resource name.

`--data 'config.resource_name_rule[1].match=/api/v1/users'`

`--data 'config.resource_name_rule[2].match=/api/v1/features/xyz/enabled' --data 'config.resource_name_rule[2].replacement=/api/v1/features/?/enabled'`

The first matching rule in a list of rules is used, and any remaining rules are ignored.
So if a rule matching `/api` exists before a more-specific match like `/api/v1/users`, the `/api` rule will be used.

Example setup:
```bash
--data 'config.resource_name_rule[1].match=/api/v1/users'
--data 'config.resource_name_rule[2].match=/api/v1/features/\w*/enabled' --data 'config.resource_name_rule[2].replacement=/api/v1/features/?/enabled'
--data 'config.resource_name_rule[3].match=/reset_password/' --data 'config.resource_name_rule[3].replacement=PASSWORD_RESET'
--data 'config.resource_name_rule[4].match=/([^/]*)/' --data 'config.resource_name_rule[4].replacement=/$1/?
```

Example outcomes:
| HTTP Method | Request URI | Matches Rule | Final Resource Name |
| ----------- | ----------- | ------------ | ------------------- |
| GET | /api/v1/users/1234/profile | 1 | GET /api/v1/users |
| GET | /api/v1/features/abc/enabled | 2 | GET /api/v1/features/?/enabled |
| GET | /api/v1/features/xyz/enabled | 2 | GET /api/v1/features/?/enabled |
| POST | /reset_password/D6T6wVRw | 3 | POST PASSWORD_RESET |
| GET | /static/site.js | 4 | GET /static/? |
| GET | /favicon.ico | none | GET /favicon.ico |

> [!NOTE]
> A plus (+) symbol in regular expressions is often used to match "one-or-more", but when configurig this in a resource name rule, it should be encoded. This is because it overlaps with URL encoding. Without encoding it, the URL encoding performed by curl or Kong will replace a plus with a space character. `%2B` should be used instead of the `+` character to avoid this issue.
>
> When configuring a Kong plugin using `curl`, the `--data` values should be wrapped in single-quotes to avoid expansion of special characters by the shell.
>
> Additional details about regular expressions can be found in OpenResty documentation for [ngx.re.match](https://github.com/openresty/lua-nginx-module#ngxrematch) and [ngx.re.sub](https://github.com/openresty/lua-nginx-module#ngxresub) which are used to apply the resource name rules.

## LLM Usage and Cost Metrics

With `ai_usage_metrics_enabled`, the plugin sends usage and cost metrics for every request that Kong's
AI Proxy plugin (`ai-proxy`) sends to a model provider. The metrics follow the
[OpenTelemetry GenAI metrics semantic conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-token-metrics.md)
and are the same series that Datadog's LiteLLM integration sends, so dashboards and monitors work across
both gateways. They are sent to the Datadog Agent over DogStatsD (`agent_host`, `dogstatsd_port`).
Kong Gateway `v3.9` or newer is required. Reading the providers' usage and encoding the series is
libdatadog's shared library `libdd-ai-usage-ffi`, which every Datadog gateway integration uses, so they
all send the same series for the same response. The plugin requires it: the rock installs it for x86_64
and aarch64 Linux (glibc 2.17 or newer) on `lua_package_cpath` as `libdd_ai_usage_ffi-<arch>.so`, and the
plugin does not load without it, naming the paths it tried. To use another build, set
`DD_AI_USAGE_FFI_LIBRARY` to its path (and declare it with `KONG_NGINX_MAIN_ENV` or an `env` directive so
that Kong's workers see it), or install `libdd_ai_usage_ffi.so` on the system's library search path. When
installing from source, build it with `scripts/build-libdd-ai-usage.sh`, which needs `git` and `cargo`
and builds the libdatadog version in `.libdatadog-version`.

Per request to a model provider:

| Metric | Type | Description |
| ------ | ---- | ----------- |
| `gen_ai.client.inference.duration` | distribution | Duration of the provider request, in seconds (`gen_ai.client.operation.duration` for embeddings), with `error.type` when it failed (`bad_request_error`, `rate_limit_error`, `timeout_error`, `internal_server_error`, `api_connection_error`, ...: the vocabulary all Datadog gateways share) |
| `gen_ai.client.inference.usage.input_tokens` | count | Input tokens, cached input included |
| `gen_ai.client.inference.usage.output_tokens` | count | Output tokens, reasoning included |
| `gen_ai.client.inference.usage.cache_read.input_tokens` | count | Input tokens read from the provider's prompt cache, when the provider reports them |
| `gen_ai.client.inference.usage.cache_write.input_tokens` | count | Input tokens written to the provider's prompt cache, by `trajectory.cache.lifetime`, when the provider reports them |
| `trajectory.gen_ai.client.inference.usage.cost` | count | Estimated cost in USD, at the model's configured `input_cost` and `output_cost` |

Per client request:

| Metric | Type | Description |
| ------ | ---- | ----------- |
| `trajectory.gen_ai.gateway.request.estimated_cost` | count | Estimated cost of the request in USD; `0` for a request that failed |

Every distribution also sends `<name>.sum` and `<name>.count` counts.

Tags: `gen_ai.operation.name` (`chat`, `text_completion` or `embeddings`), `gen_ai.provider.name` (`openai`,
`anthropic`, `azure.ai.openai`, `aws.bedrock`, `gcp.gemini`, `gcp.vertex_ai`, `mistral_ai`, `cohere`, ...),
`gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.token.modality`, `trajectory.request.service_tier`
(as the provider's response names it), `trajectory.token.source:estimated` (when the provider reported no
count and Kong's own estimate is used), `trajectory.cost.source:estimated`, `trajectory.observation.point:gateway`
and `trajectory.profile`. A value that was not observed is left out, never sent as zero. Prompts, responses
and keys are never read into metrics.

Token counts are read from the provider's response as it passes through Kong: the usage of a buffered
response, or the usage events of a stream (for OpenAI streams, the client must ask for usage with
`stream_options.include_usage`). The cost is only sent when the AI Proxy model sets `input_cost` and
`output_cost`.

Each Kong worker buffers its metrics and sends them every `ai_usage_metrics_flush_interval` seconds, or
sooner when the buffer is 80% full, so the request rate does not depend on the interval. Metrics are dropped
only when the buffer is full because sends cannot keep up; Kong then logs a warning with the number dropped,
at most once a minute.

Optional tags, with `ai_usage_metrics_tags`:

- `provider_account`, `project`: the account and project the provider billed, from its response headers
  (`openai-organization`, `openai-project`, `anthropic-organization-id`) or, for Bedrock, the account of a
  model ARN, sent as
  `trajectory.request.provider_account_id` and `trajectory.request.project_id`. The values declared with
  `ai_usage_metrics_provider_account_id` and `ai_usage_metrics_project_id` take precedence, and are sent
  whether or not these tags are enabled.
- `route`: the Kong route name, as `trajectory.gateway.route`.
- `destination`: the Kong service name, as `trajectory.gateway.destination.id`.
- `key_alias`: the authenticated Kong consumer's `username`, or else its `custom_id`, as
  `trajectory.gateway.key.alias`: the label of the caller, person or service. The credential itself is never
  read.
- `user`: the person the call was made for, as `user.id`: the authenticated consumer's `custom_id` or
  `username` when it is an email address. A service consumer has no `user.id`; use `key_alias` to tell
  services apart.
- `service`: the service name of the plugin's traces (`DD_SERVICE`, `service_name`, or `kong`), as `service`.

`trajectory.request.api_key_id` is only ever the value declared with `ai_usage_metrics_api_key_id`; it is
never derived from a key.

```yaml
plugins:
- name: ddtrace
  config:
    agent_host: datadog-agent
    ai_usage_metrics_enabled: true
    ai_usage_metrics_tags: [provider_account, project, route]
```

## Tag root span with HTTP Headers (DD_TRACE_HEADER_TAGS)

For security reasons, only a subset of HTTP headers are reported as tags. It is possible to configure the plugin to report specific HTTP Headers as span tags.
Nonetheless, be careful on which headers you are deciding to add as a span tag.

Learn more about [HTTP header collection](https://docs.datadoghq.com/tracing/configure_data_security/?tab=net#collect-headers)

Example setup:

````sh
# curl
--data 'config.header_tags[1].header=Ratelimit-Limit' --data 'config.header_tags[1].tag=rate-limit'

# The tag can be omitted, a tag following this format will be used: `http.<request|response>.headers.<http-header-name>`
--data 'config.header_tags[1].header=Ratelimit-Limit'
````

## Configuration Examples

### Using Kong Admin API with cURL

```bash
curl -i -X POST --url http://${KONG_ADMIN_HOST}:${KONG_ADMIN_PORT}/plugins/ \
     -H "content-type: application/json" \
     -d '{
        "name": "ddtrace",
        "config": {
          "agent_host": "datadog-agent",
          "service_name": "example-service",
          "environment": "dev",
          "version": "0.2.0",
          "static_tags": [
            {
                "name": "foo",
                "value": "bar"
            },
            {
                "name": "team",
                "value": "api"
            }
          ],
          "injection_propagation_styles": ["datadog", "tracecontext"],
          "extraction_propagation_styles": ["datadog", "tracecontext"],
          "initial_sample_rate": 1.0,
          "initial_samples_per_second": 200,
          "resource_name_rule": [
            {
                "match": "/api/v1/features/\\w*/enabled",
                "replacement": "/api/v1/features/?/enabled"
            }
          ],
          "header_tags": [
            {
                "header": "X-Gateway",
                "tag": "gateway-name"
            }
          ]
        }
    }'
```

### Using Kong DB-less

```yaml
# Enable for a specific service
_format_version: "3.0"
_transform: true

plugins:
- name: ddtrace
  config:
    agent_host: datadog-agent
    service_name: example-service
    environment: dev
    version: 0.2.0
    static_tags:
      - name: foo
        value: bar
      - name: team
        value: api
    injection_propagation_styles:
      - datadog
      - tracecontext
    extraction_propagation_styles:
      - datadog
      - tracecontext
    initial_sample_rate: 1.0
    initial_samples_per_second: 200
    resource_name_rule:
      - match: /api/v1/features/\w*/enabled
        replacement: /api/v1/features/?/enabled
    header_tags:
      - header: X-Gateway
        tag: gateway-name
```

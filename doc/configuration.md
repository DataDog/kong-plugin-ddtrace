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
| `environment` | `DD_ENV` | Add `env` tag for [Unified Service Tagging](https://docs-staging.datadoghq.com/dmehala/cpp-updates/getting_started/tagging/unified_service_tagging/?tab=kubernetes)  | `v0.0.1` | `string` | `nil` |
| `version` | `DD_VERSION` | Sets the version of the service and add `version` tag for [Unified Service Tagging](https://docs-staging.datadoghq.com/dmehala/cpp-updates/getting_started/tagging/unified_service_tagging/?tab=kubernetes) | `v0.2.0` | `string` | `nil` |
| `static_tags` |  | List of tags to be added to root spans | `v0.0.1` | `array[tag] with tag = {name=str, value=str}]` | `nil` |
| `injection_propagation_styles` | `DD_TRACE_PROPAGATION_STYLE_INJECT` | Propagation style used for injecting trace context | `v0.2.0` | `array[str]` | `{ "datadog", "tracecontext"}` |
| `extraction_propagation_styles` | `DD_TRACE_PROPAGATION_STYLE_EXTRACT` | Propagation style used for extracting trace context. Values are limited to `datadog` and `tracecontext`.  | `v0.2.0` | `array[str]` | `{ "datadog", "tracecontext"}` |
| `initial_sample_rate` | | Set the sampling rate for all generated traces. The value must be between `0.0` and `1.0` (inclusive) | `v0.0.1` | `float` | `1.0` |
| `intial_samples_per_second` | | Maximum number of traces allowed to be submitted per second | `v0.0.1` | `number` | `100` |
| `resource_name_rule` | | Replace matching resources to lower the cardinality on resource names | `v0.0.1` | `array[rule] with rule = {match=str, replacement=str}]` | `nil` | 
| `header_tags` |  | Set HTTP Headers as root tags | `v0.2.0` | `array[header_tag] with header_tag = {header=str, tag=str}]` | `nil` |

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
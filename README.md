# Datadog APM Plugin for Kong

This plugin adds Datadog tracing to Kong.
It was originally based on the [zipkin plugin](https://github.com/Kong/kong-plugin-zipkin), although it is now significantly modified for Datadog-specific functionality.

## Compatibility

This plugin is compatible with Kong Gateway `v2.x` and `v3.x`.
The oldest version tested is `v2.0.5` and the newest is `v3.6.1`

## Installation

This plugin can be installed using `luarocks`.

```bash
luarocks install kong-plugin-ddtrace
```

After kong is started/restarted, the plugin can be enabled. One example:
```bash
# Enabled globally
curl -i -X POST --url http://localhost:8001/plugins/ --data 'name=ddtrace'
# Enabled for specific service only
curl -i -X POST --url http://localhost:8001/services/example-service/plugins/ --data 'name=ddtrace'
```

If the datadog agent is not reachable on `http://localhost:8126`, then you will need to configure this as well.

## Configuration

This plugin supports a number of configuration options. These can be supplied when enabling the plugin by providing additional `--data` options to the `curl` request.
The option is prefixed by `config`, eg: to configure the service name, the `curl` option will be represented as `--data 'config.service_name=your-preferred-name'`.

Some options can be set using environment variables or vault references.

### Agent Host

The hostname or IP that will be used to connect to the agent.

`--data 'config.agent_host=your-agent-address'`

The default value is `localhost`.

This value can also be set using the environment variable `DD_AGENT_HOST` and overrides any other specified value, including the default setting.

### Agent URL

The URL that will be used to connect to the agent. The value should not include the trailing `/` character.

`--data 'config.trace_agent_url=http://localhost:8126'`

The default value is `http://localhost:8126`.

The value set through the environment variable `DD_TRACE_AGENT_URL` overrides any other specified value, including the default setting.

### Agent Endpoint (deprecated)

The full URL for submitting traces to the agent. It is preferred to use `agent_host` or `trace_agent_url` options instead.
This option will be deprecated in future releases.

`--data config.agent_endpoint=http://localhost:8126/v0.4/traces'`

This value can use vault references. The default value is nil.

### Service Name

The service name represents the application or component that is producing traces. All traces created by this plugin will use the configured service name.

`--data 'config.service_name=your-preferred-name'`

The value set through the environment variable `DD_SERVICE` overrides any other specified value, including the default setting.

### Environment

The environment is a larger grouping of related services, such as `prod`, `staging` or `dev`. By default, generated spans will not have an `environment` tag.

`--data 'config.environment=prod'`

The value set through the environment variable `DD_ENV` overrides any other specified value, including the default setting.

### Version

The version is a user-defined value for tracking a application version, or a versioned combination of applications, configuration, and other assets. By default, generated spans will not have a `version` tag.

`--data 'config.version=1234'`

The value set through the environment variable `DD_VERSION` overrides any other specified value, including the default setting.

### Sampling Controls

Sampling of traces is required in environments with high traffic load to reduce the amount of trace data produced and ingested by Datadog.

By default, sampling rates are provided by the Datadog agent, and additional controls are available if necessary using configuration of `initial_sample_rate` and `initial_samples_per_second`.

The `initial_sample_rate` can be set to a value between 0.0 (0%) and 1.0 (100%), and this is limited by the setting for `initial_samples_per_second` (default: 100).
After that amount of sampled traces has been exceeded, traces will not be sampled.

For example with `initial_sample_rate=0.1`, `initial_samples_per_second=5` and a traffic rate of 100 RPS:
- The first 40-50 requests per second will be sampled at 10% until 5 traces have been sampled
- The remaining 50-60 requests for that second will not be sampled.

`-- data 'config.initial_samples_per_second=100' --data 'config.initial_sample_rate=1.0'`

### Resource Name Rules

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
```
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


### Tag root span with HTTP Headers (DD_TRACE_HEADER_TAGS)

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

**NOTES**

A plus (+) symbol in regular expressions is often used to match "one-or-more", but when configurig this in a resource name rule, it should be encoded. This is because it overlaps with URL encoding. Without encoding it, the URL encoding performed by curl or Kong will replace a plus with a space character. `%2B` should be used instead of the `+` character to avoid this issue.

When configuring a Kong plugin using `curl`, the `--data` values should be wrapped in single-quotes to avoid expansion of special characters by the shell.

Additional details about regular expressions can be found in OpenResty documentation for [ngx.re.match](https://github.com/openresty/lua-nginx-module#ngxrematch) and [ngx.re.sub
](https://github.com/openresty/lua-nginx-module#ngxresub) which are used to apply the resource name rules.

## Testing

### Test Environment

Testing can be performed using `pongo`. Installation instructions are [here](https://github.com/Kong/kong-pongo#installation).

Prepare the environment:

```bash
export DD_API_KEY=... # your API key is required for this test to successfully submit traces from the agent to Datadog.
git clone https://github.com/Datadog/kong-plugin-ddtrace
cd kong-plugin-ddtrace
pongo up
pongo shell
```

Inside the shell:
```bash
# This migration step is only required the first time after running `pongo up`
kong migrations bootstrap


export KONG_PLUGINS=bundled,ddtrace
kong start

# Create a service named example service that handles requests for httpbin.org and routes requests for example.com to that endpoint.
curl -i -X POST --url http://localhost:8001/services/ --data 'name=example-service' --data 'url=http://httpbin.org'
curl -i -X POST --url http://localhost:8001/services/example-service/routes --data 'hosts[]=example.com'
curl -i -X POST --url http://localhost:8001/services/example-service/plugins/ --data 'name=ddtrace' --data 'config.agent_host=datadog-agent'

curl --header 'Host: example.com' http://localhost:8000/headers
```

This should result in a JSON response from the final `curl` request, with headers containing `x-datadog-trace-id`, `x-datadog-parent-id` and `x-datadog-sampling-priority`.
If the `DD_API_KEY` was correctly set, then the trace should appear at https://app.datadoghq.com/apm/traces

### Built-in Tests

The built-in tests can be executed by running `pongo run --no-datadog-agent`.

A report for test coverage is produced when run with additional options: `pongo run --no-datadog-agent -- --coverage`.

## Issues and Incomplete features

- The request span's start time appears incorrect, as it is a rounded-down millisecond value provided by Kong.
- More details should be collected for errors
- A high resolution timer option should be added (eg: using `clock_gettime` instead of `ngx.now()`)

## Reporting an issue

When reporting an issue, please provide the following:
- Version of kong: the output of running `kong version`
- Platform: kubernetes, docker, or the specific OS type
- `ddtrace` version: the output of running `luarocks list kong-plugin-ddtrace`
- Configuration Type: plugin enabled globally or for specific service(s)
- Configuration Details: output of `curl -s http://localhost:8001/plugins/` for globally enabled and `curl -s http://localhost:8001/services/example-service/plugins/` for a service specifically named `example-service`
- Detailed description of the problem, and if known, the expected behavior.

## Acknowledgements

This plugin is based on the original Zipkin plugin developed and maintained by Kong. It provided the overall architecture and a number of implementation details that were used as-is in this plugin.

The pongo tool was especially helpful in the development of this plugin. It is easy to use, very featureful and is clearly written "by developers, for developers".

For encoding datadog trace information in MessagePack, the Lua module from François Perrad (https://framagit.org/fperrad) was used as the base. Modifications were made to support encoding `uint64_t` and `int64_t` values.


# Datadog APM Plugin for Kong

This plugin adds Datadog tracing to Kong.
This version is heavily based on the [zipkin plugin](https://github.com/Kong/kong-plugin-zipkin), but is expected to be refactored as additional features are developed.

## Status: Early Access

At the moment, this plugin is being made available, with known issues and incomplete features.
It should only be used in development and testing/staging environments, and issues should be reported either via Github or by contacting your Datadog Technical Account Manager.

This plugin is not maintained by Kong.

## Installation

In the future, installation will be performed using `luarocks`. However, a release has not been published yet.

For now, it can be installed by manually cloning the repository to the kong/plugins directory.

```bash
cd /path/to/kong/plugins
git clone https://github.com/Datadog/kong-plugin-ddtrace ddtrace
```

After kong is started/restarted, the plugin can be enabled. One example:
```bash
curl -i -X POST --url http://localhost:8001/services/example-service/plugins/ --data 'name=ddtrace' --data 'config.agent_endpoint=http://localhost:8126/v0.4/traces'
```

The `agent_endpoint` will need configuring to match the address of the datadog agent.

## Configuration

This plugin supports a number of configuration options. These can be supplied when enabling the plugin by providing additional `--data` options to the `curl` request.
The option is prefixed by `config`, eg: to configure the service name, the `curl` option will be represented as `--data 'config.service_name=your-preferred-name'`.

### Service Name

The service name represents the application or component that is producing traces. All traces created by this plugin will use the configured service name.
If not configured, a default value of `kong` will be used.

`--data 'config.service_name=your-preferred-name'`

### Environment

The environment is a larger grouping of related services, such as `prod`, `staging` or `dev`.
If not configured, it will not be sent, and traces will be categorized as `env:none`.

`--data 'config.environment=prod`

### Sampling Controls

Sampling of traces is required in environments with high traffic load to reduce the amount of trace data produced and ingested by Datadog.

An initial sampling amount of 100 traces-per-second is applied, with a default rate of 1.0 (100%).
When traces-per-second has been exceeded, sample rates provided by the datadog agent are used instead.
These rates are updated dynamically to values between 0.0 (0%) and 1.0 (100%).

The value of `initial_samples_per_second` and `initial_sample_rate` can be configured to increase or decrease the base amount of traces that are sampled.

-- data 'config.initial_samples_per_second=100' --data 'config.initial_sample_rate=1.0'

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



**NOTES**

A plus (+) symbol in regular expressions is often used to match "one-or-more", but when configurig this in a resource name rule, it should be encoded. This is because it overlaps with URL encoding. Without encoding it, the URL encoding performed by curl or Kong will replace a plus with a space character. `%2B` should be used instead of the `+` character to avoid this issue.

When configuring a Kong plugin using `curl`, the `--data` values should be wrapped in single-quotes to avoid expansion of special characters by the shell.

Additional details about regular expressions can be found in OpenResty documentation for [ngx.re.match](https://github.com/openresty/lua-nginx-module#ngxrematch) and [ngx.re.sub
](https://github.com/openresty/lua-nginx-module#ngxresub) which are used to apply the resource name rules.

## Testing

Testing can be performed using `pongo`.

Prepare the environment:

```bash
git clone https://github.com/Datadog/kong-plugin-ddtrace
cd kong-plugin-ddtrace
pongo up
pongo shell
```

Inside the shell:
```bash
kong migrations bootstrap
export KONG_PLUGINS=bundled,ddtrace
kong start

curl -i -X POST --url http://localhost:8001/services/ --data 'name=example-service' --data 'url=http://mockbin.org'
curl -i -X POST --url http://localhost:8001/services/example-service/routes --data 'hosts[]=example.com'
curl -i -X POST --url http://localhost:8001/services/example-service/plugins/ --data 'name=ddtrace' --data 'config.agent_endpoint=http://datadog-agent:8126/v0.4/traces'

curl -i -X GET --url http://localhost:8000/ --header 'Host: example.com'
```

At this stage, there are no built-in unit or integration tests. These will be added as part of additional feature development of this plugin.

## Issues and Incomplete features

- The request span's start time appears incorrect
- There are no sampling options - all traces are sampled
- Span names could be improved
- The v0.4 API is being used to send to the agent - an update will use v0.7
- More details should be collected for errors
- A high resolution timer option should be added (eg: using `clock_gettime` instead of `ngx.now()`)

## Acknowledgements

This plugin is based on the original Zipkin plugin developed and maintained by Kong. It provided the overall architecture and a number of implementation details that were used as-is in this plugin.

The pongo tool was especially helpful in the development of this plugin. It is easy to use, very featureful and is clearly written "by developers, for developers".

For encoding datadog trace information in MessagePack, the Lua module from François Perrad (https://framagit.org/fperrad) was used as the base. Modifications were made to support encoding `uint64_t` and `int64_t` values.


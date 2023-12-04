# Datadog APM Plugin for Kong

This plugin adds Datadog tracing to Kong.
It was originally based on the [zipkin plugin](https://github.com/Kong/kong-plugin-zipkin), although it is now significantly modified for Datadog-specific functionality.

## Compatibility

This plugin is compatible with Kong Gateway v2.x and v3.x.
The oldest version tested is v2.0.5 and the newest is v3.2.2

## Installation

This plugin can be installed using `luarocks`.

```bash
luarocks install kong-plugin-ddtrace
```

After kong is started/restarted, the plugin can be enabled. One example:
```bash
# Enabled globally
curl -i -X POST --url http://localhost:8001/plugins/ --data 'name=ddtrace' --data 'config.agent_endpoint=http://localhost:8126/v0.4/traces'
# Enabled for specific service only
curl -i -X POST --url http://localhost:8001/services/example-service/plugins/ --data 'name=ddtrace' --data 'config.agent_endpoint=http://localhost:8126/v0.4/traces'
```

If the datadog agent is not reachable on `http://localhost:8126`, then you will need to configure this as well.

## Configuration

This plugin supports a number of configuration options. These can be supplied when enabling the plugin by providing additional `--data` options to the `curl` request.
The option is prefixed by `config`, eg: to configure the service name, the `curl` option will be represented as `--data 'config.service_name=your-preferred-name'`.

### Agent Trace Endpoint

The address where this plugin will submit traces to the datadog agent. The default is `http://localhost:8126/v0.4/traces`.

`--data 'config.agent_endpoint=http://your-agent-address:8126/v0.4/traces'`

If you are using the [Kong secrets management](https://docs.konghq.com/gateway/latest/kong-enterprise/secrets-management/) system, you can pass a reference to this field as well

`--data 'config.agent_endpoint='{vault://env/agent-trace-endpoint}'`

If you are using Helm with Kubernetes, you can dynamically refer the host IP of the datadog agent. Due to the limit of Kong, `{vault://}` only works for the beginning of the string, therefore, you need to specify the host IP, port and trace version other than `agent_endpoint`. We will construct the endpoint according to the IP and port in the plugin.

For example, there is a Helm Kong values.yaml file
```yaml
env:
...
  KONG_DATADOG_AGENT_HOST:
    valueFrom:
      fieldRef:
        fieldPath: status.hostIP
...
dblessConfig:
  config:
    _format_version: "2.1"
    plugins:
      - name: ddtrace
        config:
          service_name: kong-ddtrace
          host: "{vault://env/KONG_DATADOG_AGENT_HOST}"
          port: "8126"
          version: "v0.4"
          environment: 'dev'
...
```


### Service Name

The service name represents the application or component that is producing traces. All traces created by this plugin will use the configured service name.
If not configured, a default value of `kong` will be used.

`--data 'config.service_name=your-preferred-name'`

### Environment

The environment is a larger grouping of related services, such as `prod`, `staging` or `dev`.
If not configured, it will not be sent, and traces will be categorized as `env:none`.

`--data 'config.environment=prod'`

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

# Create a service named example service that handles requests for mockbin.org and routes requests for example.com to that endpoint.
curl -i -X POST --url http://localhost:8001/services/ --data 'name=example-service' --data 'url=http://mockbin.org'
curl -i -X POST --url http://localhost:8001/services/example-service/routes --data 'hosts[]=example.com'
curl -i -X POST --url http://localhost:8001/services/example-service/plugins/ --data 'name=ddtrace' --data 'config.agent_endpoint=http://datadog-agent:8126/v0.4/traces'

curl --header 'Host: example.com' http://localhost:8000/headers
```

This should result in a JSON response from the final `curl` request, with headers containing `x-datadog-trace-id`, `x-datadog-parent-id` and `x-datadog-sampling-priority`.
If the `DD_API_KEY` was correctly set, then the trace should appear at https://app.datadoghq.com/apm/traces

### Built-in Tests

The built-in tests can be executed by running `pongo test`.

A report for test coverage is produced when run with additional options: `pongo run -- --coverage`.

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


# Datadog APM Plugin for Kong
[![codecov](https://codecov.io/github/DataDog/kong-plugin-ddtrace/graph/badge.svg?token=htSU1hFalA)](https://codecov.io/github/DataDog/kong-plugin-ddtrace)

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

## Usage
Kong Admin API:

```bash
# Enabled globally
curl -i -X POST --url http://${KONG_ADMIN_HOST}:${KONG_ADMIN_PORT}/plugins/ --data 'name=ddtrace'

# Enabled for specific service only
curl -i -X POST --url http://${KONG_ADMIN_HOST}:${KONG_ADMIN_PORT}/services/example-service/plugins/ --data 'name=ddtrace'
```

Kong DB-less:
````yaml
# Enable for a specific service
_format_version: "3.0"
_transform: true

services:
- name: example-service
  url: http://httpbin.org/headers
  plugins:
  - name: ddtrace
    config:
      service_name: example-service
      agent_host: datadog-agent
  routes:
  - name: my-route
    paths:
    - /
````

## Configuration

This plugin supports a number of configuration options. These can be supplied when registering the plugin or by setting environment variables.

More details on the [Configuration page](doc/configuration.md).

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

## Acknowledgements

This plugin is based on the original Zipkin plugin developed and maintained by Kong. It provided the overall architecture and a number of implementation details that were used as-is in this plugin.

The pongo tool was especially helpful in the development of this plugin. It is easy to use, very featureful and is clearly written "by developers, for developers".

For encoding datadog trace information in MessagePack, the Lua module from François Perrad (https://framagit.org/fperrad) was used as the base. Modifications were made to support encoding `uint64_t` and `int64_t` values.

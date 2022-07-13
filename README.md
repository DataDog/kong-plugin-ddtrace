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


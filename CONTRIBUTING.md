Contributing to kong-plugin-ddtrace
===================================
Pull requests for bug fixes are welcome.

Before submitting new features or changes to current functionality, [open an
issue](https://github.com/DataDog/kong-plugin-ddtrace/issues/new) and discuss your
ideas or propose the changes you wish to make. After a resolution is reached, a
PR can be submitted for review.

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

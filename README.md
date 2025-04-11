# Kong Plugin for Datadog APM
[![codecov](https://codecov.io/github/DataDog/kong-plugin-ddtrace/graph/badge.svg?token=htSU1hFalA)](https://codecov.io/github/DataDog/kong-plugin-ddtrace)

The `kong-plugin-ddtrace` is a Datadog APM plugin designed to integrate seamlessly with the Kong Gateway.
This plugin enables detailed tracing of requests passing through Kong, providing insights into the performance and behavior of your APIs.

## Features

- **Detailed Tracing**: Capture and report trace data to the Datadog Agent, allowing you to monitor and diagnose performance issues in real-time.
- **Real-Time Monitoring**: Integrate with Datadog to monitor API performance and diagnose issues in real-time.
- **Configurable**: Supports a wide range of configuration options to tailor tracing to your specific needs.
- **Compatibility**: Works with various Kong deployment environments, including Kubernetes.

## Getting Started

> [!IMPORTANT]
> This plugin is compatible with Kong Gateway `v3.4` LTS (>= `v3.4.3.5`) or newer.
> For older version of Kong, please use [v0.2.2](https://github.com/DataDog/kong-plugin-ddtrace/releases/tag/v0.2.2) or older versions.

### Prerequisites

- Kong Gateway installed and running.
- Datadog Agent installed and configured.
- API key for Datadog.

### Installation

```bash
luarocks install kong-plugin-ddtrace
```

### Usage

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

### Configuration

This plugin supports a number of configuration options. These can be supplied when registering the plugin or by setting environment variables.

More details on the [Configuration page](doc/configuration.md).

## Support

For support, please [open an issue on the GitHub repository](/issues) or [contact Datadog support](https://help.datadoghq.com/hc/en-us/requests/new).

## Contributing

Contributions are welcome! Please read [the contributing guidelines](./CONTRIBUTING.md) and follow the best practices outlined in the project documentation.

## License

This project is licensed under the Apache License 2.0. See the LICENSE file for details.


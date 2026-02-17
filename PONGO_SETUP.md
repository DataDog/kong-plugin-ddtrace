# Running Kong Plugin DDTrace with Pongo

This plugin uses `dd-trace-cpp` via LuaJIT FFI. The C++ library must be built inside the Pongo container before running tests.

## Quick Start

```bash
# From the kong-plugin-ddtrace directory
pongo up
pongo shell

# The C++ library is built automatically on first shell entry.
# If you need to rebuild manually:
/kong-plugin/pongo-build.sh
```

## Running Tests

```bash
# Run all tests
pongo run

# Run a specific test file
pongo run spec/01-unit-tests/08_schema_spec.lua
```

## Manual Testing

Inside the Pongo shell:

```bash
kong migrations bootstrap
export KONG_PLUGINS=bundled,ddtrace
kong start

curl -i -X POST --url http://localhost:8001/services/ --data 'name=example-service' --data 'url=http://httpbin.org'
curl -i -X POST --url http://localhost:8001/services/example-service/routes --data 'hosts[]=example.com'
curl -i -X POST --url http://localhost:8001/services/example-service/plugins/ --data 'name=ddtrace' --data 'config.agent_host=datadog-agent'

curl --header 'Host: example.com' http://localhost:8000/headers
```

## What the Build Script Does

`pongo-build.sh` inside the Pongo container will:

1. Install build dependencies (`cmake`, `g++`, `libcurl4-openssl-dev`)
2. Build `dd-trace-cpp`'s C binding (`libdd_trace_c.so`)
3. Install the library to `/usr/local/lib`
4. Update the dynamic linker cache with `ldconfig`

This takes ~2-3 minutes on first run. The library persists in the container until `pongo down`.

## Directory Structure

Your workspace should have both repositories accessible:

```
workspace/
├── dd-trace-cpp/              # The C++ tracing library (mounted via .pongo/dd-trace-cpp.yml)
│   ├── binding/c/             # C binding used by this plugin
│   └── CMakeLists.txt
└── kong-plugin-ddtrace/       # This plugin (mounted at /kong-plugin)
    ├── kong/plugins/ddtrace/
    ├── pongo-build.sh
    └── .pongo/
```

Pongo mounts `kong-plugin-ddtrace` to `/kong-plugin` and `dd-trace-cpp` to `/dd-trace-cpp` via the Docker Compose override in `.pongo/dd-trace-cpp.yml`.

## Troubleshooting

### "Failed to load libdd_trace_c" error

The library hasn't been built yet. Run:
```bash
/kong-plugin/pongo-build.sh
```

### Need to rebuild the library

```bash
rm /usr/local/lib/libdd_trace_c.so
/kong-plugin/pongo-build.sh
```

### dd-trace-cpp not mounted

Ensure `.pongo/dd-trace-cpp.yml` has the correct volume mount path pointing to your local `dd-trace-cpp` checkout.

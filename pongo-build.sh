#!/bin/bash
# Build script for dd-trace-cpp C binding library in Pongo
# Note: We don't use 'set -e' because this script may be sourced by pongo-setup.sh

echo "🔨 Building dd-trace-cpp C binding library..."

# Check if already built
if [ -f "/usr/local/lib/libdd_trace_c.so" ]; then
    echo "✓ Library already built"
    return 0 2>/dev/null || exit 0
fi

# Install build dependencies
echo "  → Installing build dependencies..."
if ! apt-get update -qq; then
    echo "ERROR: Failed to update apt"
    return 1 2>/dev/null || exit 1
fi
if ! apt-get install -y -qq cmake g++ libcurl4-openssl-dev; then
    echo "ERROR: Failed to install build dependencies"
    return 1 2>/dev/null || exit 1
fi

# Check dd-trace-cpp is mounted
DD_TRACE_CPP_DIR="/dd-trace-cpp"
if [ ! -d "$DD_TRACE_CPP_DIR" ]; then
    echo "ERROR: dd-trace-cpp not mounted at $DD_TRACE_CPP_DIR"
    echo "Make sure --dd-trace-cpp is in .pongo/pongorc and .pongo/dd-trace-cpp.yml exists"
    return 1 2>/dev/null || exit 1
fi

# Build dd-trace-cpp C binding
echo "  → Building dd-trace-cpp C binding..."
cd "$DD_TRACE_CPP_DIR" || { echo "ERROR: Cannot cd to $DD_TRACE_CPP_DIR"; return 1 2>/dev/null || exit 1; }

# Clean any previous build to ensure options are picked up
rm -rf build

echo "    Running cmake configure..."
if ! cmake -S . -B build \
    -DDD_TRACE_BUILD_C_BINDING=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON; then
    echo "ERROR: cmake configure failed for dd-trace-cpp"
    return 1 2>/dev/null || exit 1
fi

echo "    Running cmake build..."
if ! cmake --build build --target dd_trace_c -j$(nproc); then
    echo "ERROR: cmake build failed for dd-trace-cpp"
    return 1 2>/dev/null || exit 1
fi

# Install library
echo "  → Installing dd-trace-cpp library..."
cp build/binding/c/libdd_trace_c.so /usr/local/lib/

# Update library cache
ldconfig
#!/usr/bin/env bash

# This script runs inside the Kong container on startup
# Copy the ddtrace library to the system library path

echo "Setting up ddtrace library..."

# Copy the library from the mounted plugin directory
if [ -f "/kong-plugin/lib/libddtrace.so" ]; then
  cp /kong-plugin/lib/libddtrace.so /usr/local/lib/libddtrace.so
  chmod 755 /usr/local/lib/libddtrace.so
  echo "ddtrace library installed to /usr/local/lib/libddtrace.so"
  ls -la /usr/local/lib/libddtrace.so
else
  echo "WARNING: libddtrace.so not found at /kong-plugin/lib/libddtrace.so"
fi

# Set LD_LIBRARY_PATH for the session
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
echo "LD_LIBRARY_PATH set to: $LD_LIBRARY_PATH"

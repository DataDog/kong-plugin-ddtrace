#!/bin/bash
# This script is sourced by Pongo at container startup (not executed directly).
# It builds the C++ library if not already present and sets LD_LIBRARY_PATH.

if [ -f "/usr/local/lib/libdd_trace_c.so" ]; then
    echo "✓ DDTrace C++ library is available"
else
    /kong-plugin/pongo-build.sh
fi

export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
echo "ready"

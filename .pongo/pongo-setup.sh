#!/bin/bash
# Pongo setup script - automatically runs at container startup
# Builds the C++ library if not already present

if [ -f "/usr/local/lib/libdd_trace_c.so" ]; then
    echo "✓ DDTrace C++ library is available"
else
    /kong-plugin/pongo-build.sh
fi

export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
echo "ready"

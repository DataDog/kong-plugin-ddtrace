# Sourced by Pongo at container startup (not executed directly).
# Builds the C++ library if not already present and sets LD_LIBRARY_PATH.

if [ -f "/usr/local/lib/libdd_trace_c.so" ]; then
    echo "✓ libdd_trace_c.so already installed"
else
    # Build may fail if DD_TRACE_CPP_DIR is not set (e.g., in CI).
    # This is expected — tracer tests skip gracefully when the library is absent.
    /kong-plugin/pongo-build.sh
fi

export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
echo "pongo-setup.sh: dd-trace-cpp setup complete"

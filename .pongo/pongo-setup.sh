# Sourced by Pongo when its container starts. Installs libdd-ai-usage-ffi,
# which the plugin requires, where its rock would: on Kong's
# lua_package_cpath. Build it first with scripts/build-libdd-ai-usage.sh
# (CI downloads it into lib/).
lib="/kong-plugin/lib/libdd_ai_usage_ffi-$(uname -m).so"
if [ ! -f "$lib" ]; then
    echo "pongo-setup.sh: $lib is missing: run scripts/build-libdd-ai-usage.sh" >&2
    return 1 2>/dev/null || exit 1
fi
cp "$lib" /usr/local/lib/lua/5.1/

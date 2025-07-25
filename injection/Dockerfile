# This dockerfile builds an image means to be used as an init container
FROM busybox:latest

WORKDIR /datadog/

COPY kong/plugins/ddtrace /datadog/ddtrace

RUN printf '#!/bin/sh \n \
# Script to copy the `kong-plugin-ddtrace` into the given `dest` \n \
# By default, it copies the content of the module in the default folder \n \
# Kong uses to load plugins. \n\n \
\
dest="${1:-/opt/kong/plugins/ddtrace/}" \n\n \
\
cp -v /datadog/ddtrace/* "${dest}"' >> /datadog/install.sh && chmod +x /datadog/install.sh

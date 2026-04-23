# Builds libdd_trace_c.so from a pinned dd-trace-cpp ref.
#
# Build:
#   docker buildx build \
#     --build-arg DD_TRACE_CPP_REF=$(cat .dd-trace-cpp-version) \
#     --output type=local,dest=./lib \
#     --target export \
#     -f build/Dockerfile build/
#
# Output: ./lib/libdd_trace_c.so (for the builder's native architecture).

# Stage 1: compile the C binding.
FROM ubuntu:22.04 AS builder

# Kong Gateway 3.5 ships on Ubuntu 22.04. Build here so glibc / libstdc++
# symbols stay compatible with the runtime image.
#
# dd-trace-cpp requires cmake >= 3.28 (Ubuntu 22.04 ships 3.22), so pull the
# latest cmake from the Kitware APT repo.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        gnupg \
        wget \
    && wget -qO- https://apt.kitware.com/keys/kitware-archive-latest.asc \
        | gpg --dearmor -o /usr/share/keyrings/kitware-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ jammy main" \
        > /etc/apt/sources.list.d/kitware.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        libcurl4-openssl-dev \
        git \
    && rm -rf /var/lib/apt/lists/*

ARG DD_TRACE_CPP_REF
RUN test -n "$DD_TRACE_CPP_REF" \
    || (echo "DD_TRACE_CPP_REF build arg is required" >&2 && exit 1)

WORKDIR /src
RUN git clone https://github.com/DataDog/dd-trace-cpp.git . \
    && git checkout "$DD_TRACE_CPP_REF"

RUN cmake -S . -B build \
        -DDD_TRACE_BUILD_C_BINDING=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    && cmake --build build --target dd_trace_c -j"$(nproc)"

# Stage 2: export stage containing only the shared library.
# `docker buildx build --output type=local,dest=./lib --target export` copies the
# contents of this stage's filesystem into the host-side `./lib` directory.
FROM scratch AS export
COPY --from=builder /src/build/binding/c/libdd_trace_c.so /libdd_trace_c.so

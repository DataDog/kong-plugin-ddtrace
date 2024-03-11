FROM ubuntu:22.04

# Expose Docker's predefined platform ARGs
# For more information: <https://docs.docker.com/engine/reference/builder/#automatic-platform-args-in-the-global-scope>
ARG TARGETARCH

# Don't issue blocking prompts during installation (sometimes an installer
# prompts for the current time zone).
ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /workspace

RUN apt-get update && apt-get install \
 && apt install -y lua5.1 luarocks liblua5.1-dev \
 && luarocks install luacheck

# Install `stylua`
# TODO: Convert TARGETARCH to x86-64 and use it
RUN wget https://github.com/JohnnyMorganz/StyLua/releases/download/v0.20.0/stylua-linux-x86_64.zip \
 && unzip stylua-linux-x86_64.zip \
 && chmod +x stylua \
 && ln -s /workspace/stylua /usr/local/bin/stylua

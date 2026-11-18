# Build environment for the Linux launcher.
#
# Ubuntu 22.04 on purpose: its glibc (2.35) is the oldest the launcher
# requires, so it starts on Ubuntu 22.04+, Debian 12, Fedora, Arch/SteamOS.
# libstdc++ is linked statically and libcurl is loaded at run time, so glibc is
# the only system library the binary itself needs. squashfs-tools makes the
# small desktop-file image appended to the AppImage (build_appimage.sh).
FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        build-essential cmake ninja-build pkg-config file ca-certificates curl binutils squashfs-tools \
        libcurl4-openssl-dev \
        libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxfixes-dev libxi-dev libxss-dev \
        libxtst-dev libxkbcommon-dev libwayland-dev wayland-protocols libegl-dev libgl-dev \
        libdecor-0-dev libdbus-1-dev libudev-dev \
    && rm -rf /var/lib/apt/lists/*

# SDL3 source (the same pin as CMakeLists.txt; used via FETCHCONTENT_SOURCE_DIR_SDL3).
RUN curl -fsSL -o /tmp/sdl3.tar.gz https://github.com/libsdl-org/SDL/releases/download/release-3.4.16/SDL3-3.4.16.tar.gz \
    && echo "7322236cd12090c3eb40b9728be4d49c76f66ad17d04369584d4ecad5cf77c68  /tmp/sdl3.tar.gz" | sha256sum -c - \
    && mkdir -p /opt/sdl3 && tar -xzf /tmp/sdl3.tar.gz -C /opt/sdl3 --strip-components=1 && rm /tmp/sdl3.tar.gz

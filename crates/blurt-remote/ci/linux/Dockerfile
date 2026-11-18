# The Linux backend of blurt-remote, built and tested on a Mac or any Docker host (docs/design/remote-linux.md §Testing).
#
#   docker build -t blurt-remote-linux crates/blurt-remote/ci/linux                  # build, clippy, tests, GStreamer, PipeWire
#   docker build -t blurt-remote-gnome --target gnome crates/blurt-remote/ci/linux   # + a headless GNOME for the real portals
#   crates/blurt-remote/ci/linux/run.sh [check|test|gnome]                             # runs them with the crate mounted
#
# Ubuntu 26.04, the release the backend is for: GStreamer 1.28, PipeWire 1.6, GNOME 50.
FROM ubuntu:26.04 AS build
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git pkg-config clang libclang-dev build-essential \
        rustc cargo rust-clippy rustfmt \
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
        gstreamer1.0-libav gstreamer1.0-tools gstreamer1.0-pipewire \
        libpipewire-0.3-dev pipewire pipewire-bin wireplumber \
        libdbus-1-dev dbus dbus-x11 ffmpeg \
    && rm -rf /var/lib/apt/lists/*
ENV CARGO_TARGET_DIR=/target CARGO_HOME=/cargo
WORKDIR /src/crates/blurt-remote

# What a stock Ubuntu desktop adds for a real session: gnome-shell (headless), mutter, the portals and their GNOME backend.
FROM build AS gnome
RUN apt-get update && apt-get install -y --no-install-recommends \
        gnome-shell mutter xdg-desktop-portal xdg-desktop-portal-gnome gnome-settings-daemon \
        gsettings-desktop-schemas xwayland python3-gi gir1.2-glib-2.0 libglib2.0-bin at-spi2-core \
    && rm -rf /var/lib/apt/lists/*

#!/usr/bin/env bash
# Installs the AnyPS5 full-build dependencies with whatever package manager this system has.
set -euo pipefail
. /etc/os-release 2>/dev/null || true
echo "system: ${PRETTY_NAME:-unknown}"
if command -v apt-get >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq build-essential cmake ninja-build ccache python3 git tmux jq \
    libx11-dev libxext-dev libxrandr-dev libwayland-dev libxkbcommon-dev libegl-dev libdecor-0-dev \
    libpipewire-0.3-dev libpulse-dev libasound2-dev mesa-vulkan-drivers vulkan-tools
elif command -v dnf >/dev/null; then
  sudo dnf install -y gcc gcc-c++ make cmake ninja-build ccache python3 git tmux jq \
    libX11-devel libXext-devel libXrandr-devel wayland-devel libxkbcommon-devel mesa-libEGL-devel libdecor-devel \
    pipewire-devel pulseaudio-libs-devel alsa-lib-devel mesa-vulkan-drivers vulkan-tools glibc-static libstdc++-static
elif command -v pacman >/dev/null; then
  sudo pacman -S --needed --noconfirm base-devel cmake ninja ccache python git tmux jq \
    libx11 libxext libxrandr wayland libxkbcommon mesa libdecor libpipewire libpulse alsa-lib vulkan-swrast vulkan-tools
elif command -v zypper >/dev/null; then
  sudo zypper -n install gcc gcc-c++ make cmake ninja ccache python3 git tmux jq \
    libX11-devel libXext-devel libXrandr-devel wayland-devel libxkbcommon-devel Mesa-libEGL-devel libdecor-devel \
    pipewire-devel libpulse-devel alsa-devel Mesa-vulkan-device-select libvulkan_lvp vulkan-tools glibc-devel-static
else
  echo "No supported package manager found (apt-get, dnf, pacman, zypper)."; exit 1
fi

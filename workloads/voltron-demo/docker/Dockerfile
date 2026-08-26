# syntax=docker/dockerfile:1.4

# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ==============================================================================
# Software Defined Vehicle (SDV) Cloud Workstation Image
#
# Base: Android Studio for Platform (ASfP) Custom Workstation Image from
#       GoogleCloudPlatform/cicd-foundation (includes GNOME Wayland, Apache
#       Guacamole, ASfP Canary, Cuttlefish emulator, and core AOSP build tools).
#
# Additions:
#   - Standalone Python 3.7.17 environment with CARLA 0.9.15 and SOME/IP bindings
#   - CARLA simulator 0.9.15 setup & management utilities
#   - SOME/IP bridge and client orchestration scripts
#   - AAOS (Android Automotive OS 26Q2) demo & patching utilities
# ==============================================================================

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV CARLA_DIR=/home/user/Workspace/carla-installation
ENV PATH="/var/lib/nvidia/bin:${CARLA_DIR}:${PATH}"
ENV LD_LIBRARY_PATH="/var/lib/nvidia/lib64:/var/lib/nvidia/lib:${LD_LIBRARY_PATH}"
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics,display

# Register NVIDIA libraries with dynamic linker and system profiles
RUN mkdir -p /etc/ld.so.conf.d /etc/profile.d && \
    printf "/var/lib/nvidia/lib64\n/var/lib/nvidia/lib\n" > /etc/ld.so.conf.d/nvidia.conf && \
    echo 'export PATH="/var/lib/nvidia/bin:${PATH}"' > /etc/profile.d/00-nvidia.sh && \
    echo 'export LD_LIBRARY_PATH="/var/lib/nvidia/lib64:/var/lib/nvidia/lib:${LD_LIBRARY_PATH}"' >> /etc/profile.d/00-nvidia.sh && \
    chmod 644 /etc/profile.d/00-nvidia.sh

# 1. Install build dependencies for Python 3.7 compilation, Vulkan tools, and additional utilities
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      htop \
      libbz2-dev \
      libffi-dev \
      libgl1-mesa-dev \
      liblzma-dev \
      libncursesw5-dev \
      libreadline-dev \
      libsqlite3-dev \
      libssl-dev \
      libvulkan1 \
      libxml2-dev \
      libxmlsec1-dev \
      llvm \
      make \
      neovim \
      stow \
      tk-dev \
      tmux \
      vulkan-tools \
      wget \
      xz-utils && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 2. Build and install standalone Python 3.7.17 with CARLA and SOME/IP dependencies
RUN wget -q https://www.python.org/ftp/python/3.7.17/Python-3.7.17.tgz && \
    tar -xzf Python-3.7.17.tgz && \
    cd Python-3.7.17 && \
    ./configure --prefix=/opt/python3.7 --with-ensurepip=install && \
    make -j$(nproc) && \
    make altinstall && \
    cd .. && rm -rf Python-3.7.17* && \
    ln -sf /opt/python3.7/bin/python3.7 /usr/local/bin/python3.7 && \
    ln -sf /opt/python3.7/bin/pip3.7 /usr/local/bin/pip3.7 && \
    ln -sf /opt/python3.7/bin/python3.7 /usr/local/bin/python37 && \
    /opt/python3.7/bin/pip3.7 install --no-cache-dir --upgrade pip==23.1.2 setuptools==47.1.0 wheel && \
    /opt/python3.7/bin/pip3.7 install --no-cache-dir --ignore-requires-python \
      numpy==1.18.4 \
      carla==0.9.15 \
      protobuf \
      someipy==1.0.0 \
      pygame==2.6.1 \
      typing-extensions==4.7.1 && \
    echo "import typing, typing_extensions; typing.Protocol = getattr(typing, 'Protocol', getattr(typing_extensions, 'Protocol', None))" > /opt/python3.7/lib/python3.7/site-packages/sitecustomize.py && \
    chmod -R 755 /opt/python3.7

# 3. CARLA 0.9.15 Utilities
COPY scripts/carla915-utils/setup_carla.sh /google/carla915-utils/setup_carla.sh

# 4. SOME/IP Bridge & Client Utilities
COPY scripts/someip-bridge/carla_someip_client.py /google/someip-bridge/carla_someip_client.py
COPY scripts/someip-bridge/get_data_logic.py /google/someip-bridge/get_data_logic.py
COPY scripts/someip-bridge/run_carla_and_bridge.sh /google/someip-bridge/run_carla_and_bridge.sh
COPY scripts/someip-bridge/external_utils/manual_control.py /google/someip-bridge/external_utils/manual_control.py

# 5. AAOS Demo Utilities (Permanently hardcoded to 26Q2 release)
COPY scripts/aaos-latest-demo-utils/checkout_aaos.sh /google/aaos-utils/checkout_aaos.sh
COPY scripts/aaos-latest-demo-utils/deploy_aaos_26q2_entry_point.sh /google/aaos-utils/deploy_aaos_26q2_entry_point.sh
COPY scripts/aaos-latest-demo-utils/dev_utils.sh /google/aaos-utils/dev_utils.sh
COPY scripts/aaos-latest-demo-utils/patch_applier/patch_aaos /google/aaos-utils/patch_applier/patch_aaos
COPY scripts/aaos-latest-demo-utils/patch_applier/patches.json /google/aaos-utils/patch_applier/patches.json
COPY scripts/aaos-latest-demo-utils/patch_applier/patches/ /google/aaos-utils/patch_applier/patches/

# 6. SDV Welcome Layer & Utility Scripts
COPY scripts/sdv-welcome-layer/ /google/sdv-utils/

# 7. Apply permissions across injected utilities
RUN chmod -R 755 /google/carla915-utils /google/someip-bridge /google/sdv-utils /google/tests 2>/dev/null || true && \
    chmod -R 755 /google/aaos-utils 2>/dev/null || true && \
    chmod 644 /google/aaos-utils/dev_utils.sh /google/aaos-utils/patch_applier/patches.json /google/aaos-utils/patch_applier/patches/* 2>/dev/null || true && \
    chmod +x /google/aaos-utils/checkout_aaos.sh /google/aaos-utils/deploy_aaos_26q2_entry_point.sh /google/aaos-utils/patch_applier/patch_aaos 2>/dev/null || true && \
    chmod 644  /google/sdv-utils/README 2>/dev/null || true && \
    chmod +x /google/sdv-utils/sdv_voltron_bash_utils 2>/dev/null || true

# 8. Dynamic NVIDIA Driver, Vulkan, Shared Memory, and Shell Welcome Integration
RUN mkdir -p /etc/workstation-startup.d /etc/vulkan/icd.d /usr/share/glvnd/egl_vendor.d /etc/glvnd/egl_vendor.d && \
    printf '{\n    "file_format_version" : "1.0.0",\n    "ICD": {\n        "library_path": "libGLX_nvidia.so.0",\n        "api_version" : "1.3.277"\n    }\n}\n' > /etc/vulkan/icd.d/nvidia_icd.json && \
    printf '{\n    "file_format_version" : "1.0.0",\n    "ICD" : {\n        "library_path" : "libEGL_nvidia.so.0"\n    }\n}\n' > /usr/share/glvnd/egl_vendor.d/10_nvidia.json && \
    cp /usr/share/glvnd/egl_vendor.d/10_nvidia.json /etc/glvnd/egl_vendor.d/10_nvidia.json && \
    printf '#!/bin/bash\nmount -o remount,size=16G /dev/shm 2>/dev/null || true\n' > /etc/workstation-startup.d/000_remount-shm.sh && \
    chmod 755 /etc/workstation-startup.d/000_remount-shm.sh && \
    printf '#!/bin/bash\nif [[ -d "/var/lib/nvidia/bin" ]]; then\n  ln -sf /var/lib/nvidia/bin/* /usr/local/bin/ 2>/dev/null || true\nfi\nif [[ -d "/var/lib/nvidia/lib64" ]]; then\n  ldconfig /var/lib/nvidia/lib64 /var/lib/nvidia/lib 2>/dev/null || true\nfi\n' > /etc/workstation-startup.d/005_setup-nvidia.sh && \
    chmod 755 /etc/workstation-startup.d/005_setup-nvidia.sh && \
    printf '\n# SDV Welcome & Environment Hooks\nif [[ $- == *i* ]] && [ -f /google/sdv-utils/sdv_voltron_bash_utils ]; then\n  source /google/sdv-utils/sdv_voltron_bash_utils\nfi\n' >> /etc/bash.bashrc && \
    printf '\n# SDV Welcome & Environment Hooks\nif [[ $- == *i* ]] && [ -f /google/sdv-utils/sdv_voltron_bash_utils ]; then\n  source /google/sdv-utils/sdv_voltron_bash_utils\nfi\n' >> /etc/skel/.bashrc

ENTRYPOINT ["/google/scripts/entrypoint.sh"]

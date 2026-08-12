# syntax=docker/dockerfile:1
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#######################################################
# Architecture Note:
# This Dockerfile is structured modularly.
# Mode 1 (Standalone): Builds from predefined/base, assembling desktop, Cuttlefish,
#                      ASFP, Python 3.7 + CARLA/SOME-IP, and Voltron assets.
# Mode 2 (Layered): To base on prebuilt horizon-asfp at a later date, update BASE_IMAGE:
#                   ARG BASE_IMAGE=${REGISTRY}/${CLOUD_PROJECT}/sdv-images/horizon-asfp:latest
#                   and skip redundant OS/ASFP installation stages.
#######################################################

ARG BASE_IMAGE=us-west1-docker.pkg.dev/cloud-workstations-images/predefined/base:latest

#######################################################
# Stage 1: NoVNC Builder
#######################################################
FROM us-west1-docker.pkg.dev/cloud-workstations-images/predefined/base:latest AS novnc-builder

ARG NOVNC_BRANCH=v1.5.0
ARG WEBSOCKIFY_BRANCH=v0.12.0

WORKDIR /out

RUN git clone --quiet --depth 1 --branch "${NOVNC_BRANCH}" https://github.com/novnc/noVNC.git && \
    cd noVNC/utils && \
    git clone --quiet --depth 1 --branch "${WEBSOCKIFY_BRANCH}" https://github.com/novnc/websockify.git

#######################################################
# Stage 2: Cuttlefish Builder (Prebuilt Package Provider)
#######################################################
FROM us-west1-docker.pkg.dev/cloud-workstations-images/predefined/code-oss:latest AS cuttlefish-builder

USER root

# Build/repack cuttlefish host packages
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      devscripts \
      equivs \
      config-package-dev \
      debhelper-compat \
      golang \
      curl \
      wget && \
    git clone https://github.com/google/android-cuttlefish /android-cuttlefish && \
    /bin/bash -c /android-cuttlefish/tools/buildutils/build_packages.sh && \
    mkdir -p /out && \
    cp /android-cuttlefish/cuttlefish-base_*_*64.deb /out/ && \
    cp /android-cuttlefish/cuttlefish-user_*_*64.deb /out/ && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

#######################################################
# Stage 3: Main Voltron Demo Container
#######################################################
FROM ${BASE_IMAGE}

USER root

ARG HORIZON_DOMAIN
ARG GOOGLE_CLOUD_PROJECT
ARG ASFP_VERSION=canary

ENV GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT}"

# 1. Systemd & SSH configuration
RUN /google/scripts/refresh-preinstalled-apt-keys.sh 2>/dev/null || true && \
    apt-get update && apt-get install -y \
    systemd \
    ca-certificates \
    curl \
    gnupg \
    openssh-server && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    ln -s /dev/null /etc/systemd/system/apache2.service && \
    ln -s /dev/null /etc/systemd/system/getty@tty1.service && \
    ln -s /dev/null /etc/systemd/system/ldconfig.service && \
    /sbin/ldconfig -Xv && \
    ln -s /dev/null /etc/systemd/system/systemd-modules-load.service && \
    echo "d /run/sshd 0755 root root" > /usr/lib/tmpfiles.d/sshd.conf && \
    echo -e "x /run/docker.socket - - - - -\nx /var/run/docker.socket - - - - -" > /usr/lib/tmpfiles.d/docker.conf

# 2. GNOME Minimal Desktop Setup
RUN apt-get update && apt-get install -y \
    gnome-software \
    gnome-software-common \
    libappstream-glib8 \
    libgd3 \
    colord \
    gnome-control-center \
    gvfs-backends \
    gnome-terminal \
    ubuntu-desktop-minimal && \
    apt-get remove -y gnome-initial-setup && \
    apt-get remove -y --purge cloud-init && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    chmod -x /usr/lib/ubuntu-release-upgrader/check-new-release-gtk 2>/dev/null || true

# 3. Copy noVNC & Install TigerVNC stack
COPY --from=novnc-builder /out/noVNC /opt/noVNC
RUN apt-get update && apt-get install -y \
    dbus-x11 \
    tigervnc-common \
    tigervnc-scraping-server \
    tigervnc-standalone-server \
    tigervnc-xorg-extension \
    python3-numpy && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 4. Install AOSP Recommended Build Tools, Utilities & NVIDIA Drivers
RUN apt-get update && apt-get install -y \
    git-core \
    gnupg \
    flex \
    bison \
    build-essential \
    zip \
    curl \
    zlib1g-dev \
    libc6-dev-i386 \
    x11proto-core-dev \
    libx11-dev \
    lib32z1-dev \
    libgl1-mesa-dev \
    libxml2-utils \
    xsltproc \
    unzip \
    fontconfig \
    fonts-dejavu-core \
    libncurses6 \
    make \
    libssl-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    llvm \
    libncursesw5-dev \
    xz-utils \
    tk-dev \
    libxml2-dev \
    libxmlsec1-dev \
    libffi-dev \
    liblzma-dev \
    repo \
    rsync \
    config-package-dev \
    neovim \
    tmux \
    htop \
    stow \
    libnvidia-gl-580 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN ln -s /usr/lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5 2>/dev/null || : && \
    ln -s /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5 2>/dev/null || :

# 5. Build and install standalone Python 3.7.17 with CARLA and SOME/IP dependencies
RUN wget -q https://www.python.org/ftp/python/3.7.17/Python-3.7.17.tgz && \
    tar -xzf Python-3.7.17.tgz && \
    cd Python-3.7.17 && \
    ./configure --prefix=/opt/python3.7 --enable-optimizations --with-ensurepip=install && \
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

# 6. Install Android Studio for Platform (ASFP Canary)
RUN if [ "$ASFP_VERSION" = "canary" ]; then \
      PACKAGE="asfp-canary-current-linux.deb"; \
    else \
      PACKAGE="asfp-current-linux.deb"; \
    fi && \
    wget -q https://dl.google.com/android/asfp/${PACKAGE} && \
    dpkg -i ${PACKAGE} && \
    rm ${PACKAGE}

# 7. Install Google Chrome (clean upstream launcher)
RUN wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && \
    dpkg -i google-chrome-stable_current_amd64.deb || (apt-get update && apt-get install -y -f) && \
    rm google-chrome*.deb && \
    xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null || true && \
    if [ ! -f /usr/bin/x-www-browser ]; then update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/google-chrome-stable 200; fi && \
    update-alternatives --set x-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true && \
    if [ ! -f /usr/bin/gnome-www-browser ]; then update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/google-chrome-stable 200; fi && \
    update-alternatives --set gnome-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 8. Install Cuttlefish debian packages from builder stage
COPY --from=cuttlefish-builder /out /cuttlefish
RUN cd /cuttlefish && \
    apt-get update && \
    apt install -y ./cuttlefish-base_*.deb ./cuttlefish-user_*.deb && \
    cd / && \
    rm -rf /cuttlefish && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 9. Configure default user 'user' and nsswitch for systemd
RUN sed -i "s/ systemd//g" /etc/nsswitch.conf 2>/dev/null || : && \
    sed -i "s/ sss//g" /etc/nsswitch.conf 2>/dev/null || : && \
    userdel -r ubuntu 2>/dev/null || true && \
    groupadd -g 1000 user 2>/dev/null || true && \
    useradd -m -u 1000 -g 1000 -G sudo,users,kvm,cvdnetwork,render -s /bin/bash user 2>/dev/null || true && \
    passwd -d user 2>/dev/null || true && \
    echo "%sudo ALL=NOPASSWD: ALL" >> /etc/sudoers

# 10. Merge assets into the container & enable VNC and SSH services
COPY assets/. /

RUN chmod 755 /etc /google /usr /usr/local /usr/local/bin 2>/dev/null || : && \
    chmod -R 755 /usr/local/bin /google /etc/workstation-startup.d /etc/skel 2>/dev/null || : && \
    chmod +x /google/demo-aaos-utils/patch_applier/patch_aaos 2>/dev/null || : && \
    ln -s /etc/systemd/system/tigervnc.service /etc/systemd/system/multi-user.target.wants/ 2>/dev/null || : && \
    ln -s /etc/systemd/system/novnc.service /etc/systemd/system/multi-user.target.wants/ 2>/dev/null || : && \
    systemctl enable ssh 2>/dev/null || : && \
    systemctl enable tigervnc 2>/dev/null || : && \
    systemctl enable novnc 2>/dev/null || :

# 11. Clean conflicting startup scripts & fix D-Bus terminal service
RUN rm -f /etc/workstation-startup.d/000_configure-docker.sh \
          /etc/workstation-startup.d/040_start-terminal-notify.sh \
          /etc/workstation-startup.d/110_start-code-oss.sh && \
    sed -i "/SystemdService=/d" /usr/share/dbus-1/services/org.gnome.Terminal.service 2>/dev/null || :

ENTRYPOINT ["/google/scripts/entrypoint.sh"]

# Copyright (c) 2025-2026 Accenture, All Rights Reserved.
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
# NoVNC Builder Container
#######################################################
FROM us-central1-docker.pkg.dev/cloud-workstations-images/predefined/base AS novnc-builder

ARG NOVNC_BRANCH=v1.5.0
ARG WEBSOCKIFY_BRANCH=v0.12.0

WORKDIR /out

RUN git clone --quiet --depth 1 --branch "${NOVNC_BRANCH}" https://github.com/novnc/noVNC.git && \
    cd noVNC/utils && \
    git clone --quiet --depth 1 --branch "${WEBSOCKIFY_BRANCH}" https://github.com/novnc/websockify.git

#######################################################
# End NoVNC Builder Container
#######################################################

#######################################################
# Cuttlefish Builder Container
#######################################################
FROM us-central1-docker.pkg.dev/cloud-workstations-images/predefined/code-oss AS cuttlefish-builder

# Add Yarn GPG key fix BEFORE apt-get update
# Cuttlefish dependencies and build
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://dl.yarnpkg.com/debian/pubkey.gpg -o /etc/apt/keyrings/yarn.asc && \
    curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | \
      gpg --dearmor > /usr/share/keyrings/helm.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
      > /etc/apt/sources.list.d/helm-stable-debian.list && \
    apt-get update -y && \
    apt-get install -y --no-install-recommends \
      git \
      devscripts \
      equivs \
      config-package-dev \
      debhelper-compat \
      golang \
      curl \
      wget \
      libncurses6 && \
    (ln -s /usr/lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5 2>/dev/null || true) && \
    (ln -s /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5 2>/dev/null || true) && \
    git clone https://github.com/google/android-cuttlefish && \
    find /android-cuttlefish -name '*.MODULE.bazel' -o -name 'MODULE.bazel' \
      | xargs sed -i 's|https://git.kernel.org/pub/scm/linux/kernel/git/jaegeuk/f2fs-tools|https://github.com/jaegeuk/f2fs-tools|g' && \
    /bin/bash -c /android-cuttlefish/tools/buildutils/build_packages.sh && \
    mkdir out && \
    cp /android-cuttlefish/cuttlefish-base_*_*64.deb /out && \
    cp /android-cuttlefish/cuttlefish-user_*_*64.deb /out && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

#######################################################
# End Cuttlefish Builder Container
#######################################################

# Main container
FROM us-west1-docker.pkg.dev/cloud-workstations-images/predefined/base

ARG HORIZON_DOMAIN
ARG GOOGLE_CLOUD_PROJECT
ARG NODE_MAJOR=20
ARG ASFP_VERSION=canary

ENV GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT}"

# Install systemd, Helm, Yarn key fix, Node.js, Gemini CLI
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://dl.yarnpkg.com/debian/pubkey.gpg -o /etc/apt/keyrings/yarn.asc && \
    curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | \
      gpg --dearmor > /usr/share/keyrings/helm.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
      > /etc/apt/sources.list.d/helm-stable-debian.list && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
      gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update -y && \
    apt-get install -y --no-install-recommends \
      systemd \
      ca-certificates \
      curl \
      gnupg \
      python3-pip \
      python3-requests \
      python3-dotenv \
      nodejs && \
    npm install -g @google/gemini-cli && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    ln -s /dev/null /etc/systemd/system/apache2.service && \
    ln -s /dev/null /etc/systemd/system/getty@tty1.service && \
    ln -s /dev/null /etc/systemd/system/ldconfig.service && \
    /sbin/ldconfig -Xv && \
    ln -s /dev/null /etc/systemd/system/systemd-modules-load.service && \
    ln -s /dev/null /etc/systemd/system/ssh.socket && \
    ln -s /dev/null /etc/systemd/system/ssh.service && \
    echo "d /run/sshd 0755 root root" > /usr/lib/tmpfiles.d/sshd.conf && \
    echo -e "x /run/docker.socket - - - - -\nx /var/run/docker.socket - - - - -" > /usr/lib/tmpfiles.d/docker.conf

# Install GNOME, TigerVNC, noVNC, repo, rsync, AOSP tools, GNOME Terminal
COPY --from=novnc-builder /out/noVNC /opt/noVNC
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      gnome-software \
      gnome-software-common \
      gnome-software-plugin-snap \
      libappstream-glib8 \
      libgd3 \
      colord \
      gnome-control-center \
      gvfs-backends \
      hplip \
      libgphoto2-6 \
      libsane1 \
      sane-utils \
      ubuntu-desktop-minimal \
      dbus-x11 \
      tigervnc-common \
      tigervnc-scraping-server \
      tigervnc-standalone-server \
      tigervnc-xorg-extension \
      python3-numpy \
      repo \
      rsync \
      git-core \
      flex \
      bison \
      build-essential \
      zip \
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
      gnome-terminal && \
    apt-get remove -y gnome-initial-setup && \
    apt-get remove -y --purge cloud-init && \
    ln -s /usr/lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5 && \
    ln -s /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    chmod -x /usr/lib/ubuntu-release-upgrader/check-new-release-gtk

# Install Cuttlefish from builder
COPY --from=cuttlefish-builder /out /cuttlefish
RUN apt-get update -y && \
    apt install -y ./cuttlefish/cuttlefish-base_*.deb ./cuttlefish/cuttlefish-user_*.deb && \
    rm -rf /cuttlefish && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Android Studio for Platform
RUN if [ "${ASFP_VERSION}" = "canary" ]; then \
      PACKAGE="asfp-canary-current-linux.deb"; \
    else \
      PACKAGE="asfp-current-linux.deb"; \
    fi && \
    wget "https://dl.google.com/android/asfp/${PACKAGE}" && \
    dpkg -i "${PACKAGE}" && \
    rm "${PACKAGE}"

# Install Google Chrome
RUN wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && \
    dpkg -i google-chrome-stable_current_amd64.deb || apt-get update -y && apt-get install -y -f && \
    rm google-chrome-stable_current_amd64.deb && \
    # Ensure chrome will work in our headless environment without gpu support by
    # specifying environment variables and flags.
    echo "QT_X11_NO_MITSHM=1 _X11_NO_MITSHM=1 _MITSHM=0 $(tail -n -1 /opt/google/chrome/google-chrome) --disable-gpu --disable-dev-shm-usage --use-gl=swiftshader" \
      >> /opt/google/chrome/google-chrome && \
    sed -i 'N;$!P;D' /opt/google/chrome/google-chrome && \
    # Set google-chrome as the default browser.
    xdg-settings set default-web-browser google-chrome.desktop || true && \
    if [ ! -f /usr/bin/x-www-browser ]; then \
      update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/google-chrome-stable 200; \
    fi && \
    update-alternatives --set x-www-browser /usr/bin/google-chrome-stable && \
    if [ ! -f /usr/bin/gnome-www-browser ]; then \
      update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/google-chrome-stable 200; \
    fi && \
    update-alternatives --set gnome-www-browser /usr/bin/google-chrome-stable && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Merge assets into the container
COPY assets/. /

# Configure deterministic GNOME Terminal defaults for VNC/noVNC rendering.
RUN mkdir -p /etc/dconf/profile /etc/dconf/db/local.d && \
    printf "user-db:user\nsystem-db:local\n" > /etc/dconf/profile/user && \
    printf "[org/gnome/terminal/legacy/profiles:]\ndefault='b1dcc9dd-5262-4d8d-a863-c897e6d979b9'\nlist=['b1dcc9dd-5262-4d8d-a863-c897e6d979b9']\n\n[org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9]\nuse-system-font=false\nfont='DejaVu Sans Mono 12'\ncell-width-scale=1.0\ncell-height-scale=1.0\n" > /etc/dconf/db/local.d/00-horizon-terminal-font

# Run VNC services and configure desktop entry
RUN ln -s /etc/systemd/system/tigervnc.service /etc/systemd/system/multi-user.target.wants/tigervnc.service && \
    ln -s /etc/systemd/system/novnc.service /etc/systemd/system/multi-user.target.wants/novnc.service && \
    systemctl enable tigervnc && \
    systemctl enable novnc && \
    # Apply image-level dconf defaults (including terminal font profile).
    dconf update && \
    # Update desktop entry to canary if applicable
    if [ "${ASFP_VERSION}" = "canary" ]; then \
      sed -i 's/android-studio-for-platform/android-studio-for-platform-canary/g' /usr/share/applications/jetbrains-studio.desktop; \
    fi && \
    chmod +x /google/scripts/entrypoint.sh

# Configure gemini-mcp-agent script
COPY --chmod=755 ./common-utils/gemini/gemini-mcp-agent.py /usr/local/bin/gemini-mcp-agent
RUN sed -i 's/^\(HORIZON_DOMAIN = os.environ.get("HORIZON_DOMAIN", "\)##DOMAIN##\(")\)/\1'"${HORIZON_DOMAIN}"'\2/' /usr/local/bin/gemini-mcp-agent

ENTRYPOINT ["/google/scripts/entrypoint.sh"]

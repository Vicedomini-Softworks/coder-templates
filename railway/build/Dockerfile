FROM codercom/enterprise-base:ubuntu

USER root

# Avoid apt prompting for input during the build (doesn't persist to the
# runtime image since it's an ARG, not ENV).
ARG DEBIAN_FRONTEND=noninteractive

# Keep the base image current before installing anything else.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        openssl \
        unzip \
        zip \
        zsh \
    && rm -rf /var/lib/apt/lists/*

# zsh as the coder user's default shell.
RUN usermod -s "$(command -v zsh)" coder

# --- Claude Code CLI ---
# https://code.claude.com/docs/en/setup#install-with-linux-package-managers
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
        -o /etc/apt/keyrings/claude-code.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
        > /etc/apt/sources.list.d/claude-code.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends claude-code \
    && rm -rf /var/lib/apt/lists/*

# --- Cursor CLI (cursor-agent) ---
# Upstream installer only understands $HOME, so it's pointed at a throwaway
# home dir and the resulting binaries are linked into /usr/local/bin, which
# is on PATH for every user regardless of how /home/coder is mounted.
RUN mkdir -p /opt/cursor-agent \
    && HOME=/opt/cursor-agent bash -c 'curl -fsSL https://cursor.com/install | bash' \
    && for f in cursor-agent agent; do \
        if [ -e "/opt/cursor-agent/.local/bin/$f" ]; then ln -sf "/opt/cursor-agent/.local/bin/$f" "/usr/local/bin/$f"; fi; \
       done

# --- Kiro CLI ---
RUN mkdir -p /opt/kiro-cli \
    && HOME=/opt/kiro-cli bash -c 'curl -fsSL https://cli.kiro.dev/install | bash' \
    && for f in kiro-cli kiro-cli-chat q; do \
        if [ -e "/opt/kiro-cli/.local/bin/$f" ]; then ln -sf "/opt/kiro-cli/.local/bin/$f" "/usr/local/bin/$f"; fi; \
       done

# --- GitHub CLI (gh) ---
RUN install -d -m 0755 /usr/share/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- Cloudflare Zero Trust (cloudflared) ---
RUN install -d -m 0755 /usr/share/keyrings \
    && curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        -o /usr/share/keyrings/cloudflare-main.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
        > /etc/apt/sources.list.d/cloudflared.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends cloudflared \
    && rm -rf /var/lib/apt/lists/*

# --- Cloudflare WARP (Zero Trust device client, `warp-cli`) ---
# Separate product/repo from cloudflared above: cloudflared is the tunnel
# connector, cloudflare-warp is the Zero Trust client that enrolls this
# device into an org's Zero Trust network.
RUN . /etc/os-release \
    && install -d -m 0755 /usr/share/keyrings \
    && curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends cloudflare-warp \
    && rm -rf /var/lib/apt/lists/*

# --- Tailscale ---
# Adding the repo directly (rather than piping tailscale.com/install.sh)
# skips its `systemctl enable --now tailscaled`, which fails at build time
# since there's no init system running in a Docker build.
RUN . /etc/os-release \
    && install -d -m 0755 /usr/share/keyrings \
    && curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

# --- Podman (rootless) as a Docker-in-Docker substitute ---
# Railway containers run unprivileged with no way to grant
# --privileged/SYS_ADMIN, so a real dockerd can't run inside the
# workspace. Podman is daemonless and works rootless via user
# namespaces; podman-docker installs a `docker` CLI shim that forwards
# to it, so `docker build`/`docker run`/`docker ps` keep working
# as-is for testing. Removes any docker.io/docker-ce packages the base
# image may ship first, since podman-docker conflicts with them over
# ownership of /usr/bin/docker.
RUN apt-get update \
    && (apt-get remove -y docker.io docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin containerd containerd.io || true) \
    && apt-get install -y --no-install-recommends \
        podman \
        podman-docker \
        fuse-overlayfs \
        slirp4netns \
        uidmap \
    && rm -rf /var/lib/apt/lists/*

# Rootless podman needs a UID/GID subordinate range for the coder user
# to map container UIDs into.
RUN (grep -q "^coder:" /etc/subuid || echo "coder:100000:65536" >> /etc/subuid) \
    && (grep -q "^coder:" /etc/subgid || echo "coder:100000:65536" >> /etc/subgid)

# --- PHP 8.5 + Composer ---
# Toolchain for vicedomini-cloud's Laravel app (vcloud-auth), which targets
# PHP 8.5 (see its CLAUDE.md and CI workflow). Ubuntu's own repos already
# carry PHP 8.5 and Composer 2.x directly, so no extra PPA is needed here.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        php8.5-cli \
        php8.5-common \
        php8.5-curl \
        php8.5-mbstring \
        php8.5-xml \
        php8.5-zip \
        php8.5-bcmath \
        php8.5-gd \
        php8.5-intl \
        php8.5-sqlite3 \
        php8.5-redis \
        composer \
    && rm -rf /var/lib/apt/lists/*

# --- kubectl + kustomize ---
# Ahead of vcloud-kustomize's planned Kustomize/ArgoCD-driven Kubernetes
# config (an empty scaffold today). kubectl isn't in Ubuntu's own repos, so
# it's pulled from the official Kubernetes apt repo; kustomize has no apt
# repo at all, so it's installed via its official install script instead.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends kubectl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" \
    | bash -s -- /usr/local/bin

# --- AWS CLI v2 ---
# Needed for vcloud-kustomize's TUTORIAL.md deploy workflow (ECR push, RDS,
# Secrets Manager, Route53, ACM). No apt repo exists for it, so it's
# installed via AWS's official installer, matching the CPU architecture
# Docker reports for the build.
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
        amd64) awsarch=x86_64 ;; \
        arm64) awsarch=aarch64 ;; \
        *) echo "Unsupported architecture for AWS CLI: $arch" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${awsarch}.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# --- Helm ---
# Needed for vcloud-kustomize's TUTORIAL.md one-time cluster setup (ArgoCD,
# the AWS Load Balancer Controller, and the External Secrets Operator are
# all installed via Helm there). No apt repo, so it's installed via Helm's
# official install script.
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# --- ArgoCD CLI ---
# Used in vcloud-kustomize's TUTORIAL.md to confirm ArgoCD picked up a
# change (`argocd app get ...`). No apt repo, so the binary is pulled
# directly from GitHub releases, matching the CPU architecture Docker
# reports for the build.
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL -o /usr/local/bin/argocd "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${arch}" \
    && chmod +x /usr/local/bin/argocd

# --- Chromium OS dependencies (for Playwright, installed below as `coder`) ---
# `playwright install --with-deps` would normally apt-get these itself, but
# that means shelling out to `sudo apt-get` from a non-root RUN step, which
# is flaky in a `docker buildx build` (no TTY, sudoers behavior varies by
# base image). Installing them directly as root here sidesteps that
# entirely. Exact package list for `ubuntu26.04-x64` (this base image's
# Ubuntu release) taken from Playwright 1.63.0's own dependency registry:
# https://github.com/microsoft/playwright/blob/v1.63.0/packages/playwright-core/src/server/registry/nativeDeps.ts
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        xvfb \
        fonts-noto-color-emoji \
        fonts-unifont \
        libfontconfig1 \
        libfreetype6 \
        xfonts-cyrillic \
        xfonts-scalable \
        fonts-liberation \
        fonts-ipafont-gothic \
        fonts-wqy-zenhei \
        fonts-tlwg-loma-otf \
        fonts-freefont-ttf \
        libasound2t64 \
        libatk-bridge2.0-0t64 \
        libatk1.0-0t64 \
        libatspi2.0-0t64 \
        libcairo2 \
        libcups2t64 \
        libdbus-1-3 \
        libdrm2 \
        libgbm1 \
        libglib2.0-0t64 \
        libnspr4 \
        libnss3 \
        libpango-1.0-0 \
        libx11-6 \
        libxcb1 \
        libxcomposite1 \
        libxdamage1 \
        libxext6 \
        libxfixes3 \
        libxkbcommon0 \
        libxrandr2 \
    && rm -rf /var/lib/apt/lists/*

# --- Oh My Zsh ---
# Installed before the SDKMAN block below appends its own lines to
# .zshrc, so Oh My Zsh's template is in place first and our tool-init
# lines land after it, not the other way around (Oh My Zsh's installer
# overwrites an existing .zshrc unless told to keep it).
USER coder
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc

# --- SDKMAN! (Maven 3.9.9, Temurin JDK 8/11/21, JBang) + Camel JBang kit,
#     and NVM (Node 22) ---
# Installed as the real `coder` user (not root with a faked $HOME): JBang
# and Maven are JVM/Java-tooling and resolve their data/repo dirs from the
# JVM's `user.home`, which is derived from the OS passwd entry rather than
# the $HOME env var - overriding $HOME while running as root still bakes
# /root/... paths into things like JBang's dependency cache. Running as
# coder makes user.home correctly resolve to /home/coder.
#
# Everything then gets copied into /etc/skel so it survives the
# volume-mount reseed in entrypoint.sh's `cp -rT /etc/skel /home/coder` on
# a workspace's first boot, and /home/coder itself is reset to empty
# afterward so the image doesn't ship the ~1GB of tooling twice.
#
# coder's default shell is zsh (set above), so this block also wires
# SDKMAN/JBang/NVM into .zshrc, not just the .bashrc the installers
# default to.
RUN <<'EOF'
#!/usr/bin/env bash
set -e
curl -s "https://get.sdkman.io" | bash
# Every install after the first prompts "set as default? (Y/n)" on stdin;
# auto-answer so a non-interactive build doesn't hang on EOF.
sed -i "s/sdkman_auto_answer=false/sdkman_auto_answer=true/" "$HOME/.sdkman/etc/config"
source "$HOME/.sdkman/bin/sdkman-init.sh"

# Java identifiers are resolved to the latest Temurin patch for each major
# at build time rather than hardcoded, since SDKMAN doesn't accept bare
# "8-tem"/"11-tem" short forms for older majors. Matched straight off the
# "-tem"-suffixed identifier column (`sdk list java`'s layout has changed
# vendor/version columns before - matching the stable identifier suffix is
# less fragile than matching table structure), first hit wins since SDKMAN
# lists each major's builds newest-first.
for major in 8 11 21; do
  id=$(sdk list java 2>&1 | grep -oE "\b${major}\.[0-9][0-9.+]*-tem\b" | head -1)
  if [ -z "$id" ]; then
    echo "No Temurin build found for Java ${major} in 'sdk list java' output" >&2
    exit 1
  fi
  sdk install java "$id" < /dev/null
done
id21=$(sdk list java 2>&1 | grep -oE "\b21\.[0-9][0-9.+]*-tem\b" | head -1)
sdk default java "$id21"

sdk install maven 3.9.9 < /dev/null
sdk install jbang < /dev/null

# Camel JBang kit: the `camel` CLI (camel init/run/...), installed as a
# JBang app. `jbang trust add` is required for non-interactive installs.
jbang trust add https://github.com/apache/camel/
jbang app install camel@apache/camel

curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
nvm install 22
nvm alias default 22

# Playwright + a headless Chromium build, for vcloud-library(-angular|-react)'s
# Vitest browser suites (@vitest/browser-playwright), which exercise real
# Shadow DOM/Custom Element behavior instead of jsdom. Run as `coder` (not
# root) so the browser binary lands under $HOME/.cache/ms-playwright and
# gets baked into /etc/skel below. No `--with-deps` here - the OS packages
# it would install are already handled by the root-level apt block above.
npm install -g playwright@1.63.0
npx playwright install chromium

# The installers above only reliably wire themselves into .bashrc: SDKMAN
# only appends to .zshrc if it already exists at install time (it doesn't
# yet, here), and NVM/JBang key off the currently running shell (bash, in
# this RUN step) rather than checking for other rc files. Since coder is
# now a zsh user, write the same init lines into .zshrc explicitly rather
# than depend on each installer's shell detection.
cat >> "$HOME/.zshrc" <<'ZSHRC_EOF'

# --- SDKMAN, JBang, NVM ---
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"

alias j!=jbang
export PATH="$HOME/.jbang/bin:$PATH"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

export PATH="$HOME/.config/composer/vendor/bin:$PATH"
ZSHRC_EOF
EOF

USER root
RUN cp -rT /home/coder /etc/skel \
    && rm -rf /home/coder \
    && mkdir -p /home/coder \
    && chown coder:coder /home/coder

# Final upgrade pass: the first apt-get upgrade at the top of this file
# only covers Ubuntu's own repos. By this point several more repos have
# been registered (Claude Code, cloudflared, cloudflare-warp, Tailscale),
# so re-run update+upgrade to pick up any patches for those too.
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /coder-entrypoint.sh
RUN chmod +x /coder-entrypoint.sh

ENTRYPOINT ["/coder-entrypoint.sh"]

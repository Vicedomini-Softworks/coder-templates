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
        unzip \
        zip \
    && rm -rf /var/lib/apt/lists/*

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

# --- SDKMAN! (Maven 3.9.9, Temurin JDK 8/11/21, JBang) + Camel JBang kit ---
# Installed into /etc/skel (not /home/coder) so it survives the volume-mount
# reseed in entrypoint.sh's `cp -rT /etc/skel /home/coder` on a workspace's
# first boot. Java identifiers are resolved to the latest Temurin patch for
# each major at build time rather than hardcoded, since SDKMAN doesn't
# accept bare "8-tem"/"11-tem" short forms for older majors.
RUN <<'EOF'
#!/usr/bin/env bash
set -e
export HOME=/etc/skel
curl -s "https://get.sdkman.io" | bash
# Every install after the first prompts "set as default? (Y/n)" on stdin;
# auto-answer so a non-interactive build doesn't hang on EOF.
sed -i "s/sdkman_auto_answer=false/sdkman_auto_answer=true/" /etc/skel/.sdkman/etc/config
source /etc/skel/.sdkman/bin/sdkman-init.sh

for major in 8 11 21; do
  id=$(sdk list java 2>&1 | grep -E "\| ${major}\.[0-9.]+ *\| tem " | head -1 | grep -oE "[0-9]+\.[0-9.]+-tem")
  sdk install java "$id" < /dev/null
done
id21=$(sdk list java 2>&1 | grep -E "\| 21\.[0-9.]+ *\| tem " | head -1 | grep -oE "[0-9]+\.[0-9.]+-tem")
sdk default java "$id21"

sdk install maven 3.9.9 < /dev/null
sdk install jbang < /dev/null

# Camel JBang kit: the `camel` CLI (camel init/run/...), installed as a
# JBang app. `jbang trust add` is required for non-interactive installs.
jbang trust add https://github.com/apache/camel/
jbang app install camel@apache/camel
EOF

# --- NVM (Node 22) ---
# Same /etc/skel rationale as SDKMAN above.
RUN <<'EOF'
#!/usr/bin/env bash
set -e
export HOME=/etc/skel
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
nvm install 22
nvm alias default 22
EOF

COPY entrypoint.sh /coder-entrypoint.sh
RUN chmod +x /coder-entrypoint.sh

ENTRYPOINT ["/coder-entrypoint.sh"]

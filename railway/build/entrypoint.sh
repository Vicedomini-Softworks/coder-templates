#!/bin/bash
set -e

# Railway volumes are root-owned by default. When the container
# runs as root (via RAILWAY_RUN_UID=0), we fix ownership before
# dropping privileges to the coder user.
if [ "$(id -u)" = "0" ]; then
  chown coder:coder /home/coder 2> /dev/null || true
fi

# Best-effort background start of the VPN/Zero Trust daemons, so
# `tailscale` and `warp-cli` work without the user having to remember to
# start them by hand each session. Both need NET_ADMIN + /dev/net/tun,
# which the container runtime may not grant - failures here are logged
# but must never block the workspace from starting.
if [ "$(id -u)" = "0" ]; then
  if command -v tailscaled > /dev/null 2>&1; then
    # Without /dev/net/tun (typical on Railway) fall back to userspace mode.
    # SOCKS5 + HTTP proxy on localhost:1055 (one port, both protocols) so
    # programs can reach the tailnet in userspace mode, opt-in per command
    # (`curl --proxy socks5h://localhost:1055 ...`); no global *_PROXY env
    # (only Claude Code is pointed at it, by the template's tailscale script).
    # --state=mem: registers an ephemeral node: every start is a new
    # container, so old nodes leave the tailnet instead of piling up as
    # -1, -2, ... In userspace mode the netstack MTU is lowered to 1200:
    # with the default 1280, large TCP segments from subnet routers are
    # dropped on direct (non-DERP) paths and TLS handshakes hang.
    TS_FLAGS="--state=mem: --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055"
    TS_ENV=""
    if [ ! -c /dev/net/tun ]; then
      TS_FLAGS="$TS_FLAGS --tun=userspace-networking"
      TS_ENV="TS_DEBUG_MTU=1200"
    fi
    # Subshell: tailscaled is reparented to tini, which reaps it if it is
    # ever restarted (a direct child of the su below would stay a zombie).
    (env $TS_ENV tailscaled $TS_FLAGS > /tmp/tailscaled.log 2>&1 &)
    chmod 666 /tmp/tailscaled.log 2> /dev/null || true
  fi
  command -v warp-svc > /dev/null 2>&1 && warp-svc > /tmp/warp-svc.log 2>&1 &
fi

# Best-effort OS patching on every start: update + upgrade, then purge the
# apt cache/lists to keep the layer small. Runs in the background so it never
# delays the agent coming up; output goes to /tmp/apt-upgrade.log. Needs root.
if [ "$(id -u)" = "0" ]; then
  (
    export DEBIAN_FRONTEND=noninteractive
    apt-get update \
      && apt-get upgrade -y \
      ; apt-get clean \
      ; rm -rf /var/lib/apt/lists/*
  ) > /tmp/apt-upgrade.log 2>&1 &
fi

# Seed home directory with skeleton files on first start.
if [ ! -f /home/coder/.init_done ]; then
  cp -rT /etc/skel /home/coder 2> /dev/null || true
  touch /home/coder/.init_done
  if [ "$(id -u)" = "0" ]; then
    chown -R coder:coder /home/coder 2> /dev/null || true
  fi
else
  # Home already seeded on a previous boot, possibly from an older
  # image. Backfill anything a newer image added to /etc/skel (new
  # tool installs etc.) without touching files the user already has -
  # cp -n skips any destination path that already exists. Runs as
  # coder directly so newly added files land correctly owned without
  # a recursive chown of the whole (possibly multi-GB) home dir on
  # every single start.
  if [ "$(id -u)" = "0" ]; then
    su -s /bin/bash coder -c 'cp -rTn /etc/skel /home/coder 2> /dev/null || true'
  else
    cp -rTn /etc/skel /home/coder 2> /dev/null || true
  fi
fi

# The Coder init script is passed base64-encoded to avoid shell
# escaping issues with multi-line environment variable values.
if [ -n "$CODER_INIT_SCRIPT_B64" ]; then
  INIT_SCRIPT_FILE=$(mktemp /tmp/coder-init.XXXXXX)
  echo "$CODER_INIT_SCRIPT_B64" | base64 -d > "$INIT_SCRIPT_FILE"
  chmod +x "$INIT_SCRIPT_FILE"
  if [ "$(id -u)" = "0" ]; then
    chown coder:coder "$INIT_SCRIPT_FILE"
    exec su -s /bin/bash coder "$INIT_SCRIPT_FILE"
  else
    exec "$INIT_SCRIPT_FILE"
  fi
else
  echo "ERROR: CODER_INIT_SCRIPT_B64 is not set."
  echo "This image is designed to run as a Coder workspace on Railway."
  sleep infinity
fi

#!/bin/bash
set -e

# Railway volumes are root-owned by default. When the container
# runs as root (via RAILWAY_RUN_UID=0), we fix ownership before
# dropping privileges to the coder user.
if [ "$(id -u)" = "0" ]; then
  chown coder:coder /home/coder 2> /dev/null || true
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

#!/usr/bin/env bash
# Push a template to Coder pinned to the workspace image built for the
# current commit.
#
# `coder templates push` reuses the previous template version's variable
# values unless they are passed again, so a plain push keeps deploying the
# old workspace_image. This script always passes workspace_image, pinned to
# the immutable sha tag CI pushed (never :latest), so image changes reach
# new workspace builds. Other variables keep their previous values; extra
# arguments are passed through to `coder templates push`.
#
# Usage: ./push-template.sh <railway|kubernetes> [coder templates push args...]
set -euo pipefail

IMAGE=docker.io/vicedominisoftworks/railway-vicedominidev
TEMPLATE="${1:?usage: $0 <railway|kubernetes> [extra push args...]}"
shift
cd "$(dirname "$0")"
[ -d "$TEMPLATE" ] || {
  echo "no such template directory: $TEMPLATE" >&2
  exit 1
}

tag_digest() {
  curl -fsS "https://hub.docker.com/v2/repositories/${IMAGE#docker.io/}/tags/$1" 2> /dev/null \
    | jq -r '.digest // empty'
}

# CI tags each image with the sha of the commit it was built from (the head
# of each push to main touching railway/**). Use the newest such commit.
git fetch -q origin main
SHA=""
for c in $(git rev-list --first-parent -n 50 origin/main); do
  if [ -n "$(tag_digest "$c")" ]; then
    SHA=$c
    break
  fi
done
[ -n "$SHA" ] || {
  echo "no image tag found for the last 50 commits of origin/main" >&2
  exit 1
}

PENDING=$(git log --oneline "$SHA..origin/main" -- railway/build)
if [ -n "$PENDING" ]; then
  echo "ERROR: railway/build changed after $SHA and that image is not on Docker Hub yet" >&2
  echo "(build still running or failed?):" >&2
  echo "$PENDING" >&2
  exit 1
fi
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ] || [ -n "$(git status --porcelain -- "$TEMPLATE")" ]; then
  echo "WARNING: pushing $TEMPLATE/ from a working tree that differs from origin/main." >&2
fi

echo "Pushing $TEMPLATE with $IMAGE:$SHA ($(tag_digest "$SHA"))"
coder templates push "$TEMPLATE" \
  --directory "$TEMPLATE" \
  --variable "workspace_image=$IMAGE:$SHA" \
  --message "$(git log -1 --format='%h %s' HEAD) (image ${SHA:0:7})" \
  --yes \
  "$@"

#!/usr/bin/env bash
# Update the source-news submodule to the latest commit on origin/main.
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel)
SUBMODULE_DIR="$ROOT_DIR/source-news"

echo "::group::Synchronizing source-news submodule"

git submodule update --init --quiet source-news

if [[ ! -d "$SUBMODULE_DIR" ]]; then
  echo "::error::Failed to initialise source-news submodule"
  exit 1
fi

git -C "$SUBMODULE_DIR" fetch --depth=1 origin main

git -C "$SUBMODULE_DIR" checkout -B main origin/main >/dev/null 2>&1 || \
  git -C "$SUBMODULE_DIR" checkout main

git -C "$SUBMODULE_DIR" pull --ff-only origin main

CURRENT_COMMIT=$(git -C "$SUBMODULE_DIR" rev-parse --short HEAD)
CURRENT_DATE=$(git -C "$SUBMODULE_DIR" log -1 --pretty=format:'%cI')

echo "::notice::source-news updated to ${CURRENT_COMMIT} (${CURRENT_DATE})"

echo "::endgroup::"

#!/usr/bin/env bash
# Update the source-news submodule to the latest commit on origin/main.
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel)
SUBMODULE_DIR="$ROOT_DIR/source-news"

echo "::group::Synchronizing source-news submodule"

# Ensure the submodule directory exists
if [[ ! -d "$SUBMODULE_DIR" ]]; then
  git submodule update --init source-news
fi

if [[ ! -e "$SUBMODULE_DIR/.git" ]]; then
  echo "::error::source-news is not a valid git repository"
  exit 1
fi

cd "$SUBMODULE_DIR"

# Fetch the latest main branch and fast-forward
if git ls-remote --exit-code origin main >/dev/null 2>&1; then
  git fetch --depth=1 origin main
  git checkout main >/dev/null 2>&1 || git checkout -b main origin/main
  git pull --ff-only origin main
else
  echo "::error::origin/main not found for source-news"
  exit 1
fi

CURRENT_COMMIT=$(git rev-parse --short HEAD)
CURRENT_DATE=$(git log -1 --pretty=format:'%cI')

echo "::notice::source-news updated to ${CURRENT_COMMIT} (${CURRENT_DATE})"

cd "$ROOT_DIR"

echo "::endgroup::"

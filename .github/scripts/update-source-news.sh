#!/usr/bin/env bash
# Fetch or refresh the ai-briefing-archive repository into source-news/.
# Designed to be idempotent so both CI and local use produce the same result.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)"
SOURCE_DIR="${ROOT_DIR}/source-news"
REPO_URL_DEFAULT="https://github.com/Joe-oss9527/ai-briefing-archive.git"
REPO_URL="${SOURCE_NEWS_REPO_URL:-$REPO_URL_DEFAULT}"
REF="${SOURCE_NEWS_REF:-main}"
MAX_RETRIES="${SOURCE_NEWS_FETCH_RETRIES:-3}"
BACKOFF_SECONDS="${SOURCE_NEWS_FETCH_BACKOFF:-2}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

clone_repo() {
  if [[ -e "${SOURCE_DIR}" ]]; then
    log "Removing incomplete clone at ${SOURCE_DIR} before retry"
    rm -rf "${SOURCE_DIR}"
  fi

  log "Cloning ${REPO_URL} (${REF}) into ${SOURCE_DIR}";
  git clone --depth=1 --branch "${REF}" "${REPO_URL}" "${SOURCE_DIR}"
}

update_repo() {
  log "Fetching latest ${REF} from ${REPO_URL}"
  git -C "${SOURCE_DIR}" fetch --depth=1 origin "${REF}"
  git -C "${SOURCE_DIR}" checkout -B "${REF}" "origin/${REF}"
  git -C "${SOURCE_DIR}" reset --hard "origin/${REF}"
  git -C "${SOURCE_DIR}" clean -ffd
}

prepare_source_dir() {
  if [[ -d "${SOURCE_DIR}/.git" ]]; then
    return
  fi

  if [[ -f "${SOURCE_DIR}/.git" ]]; then
    log "Removing legacy submodule metadata from ${SOURCE_DIR}"
    rm -rf "${SOURCE_DIR}"
    return
  fi

  if [[ -d "${SOURCE_DIR}" ]]; then
    log "Existing ${SOURCE_DIR} without git metadata detected; removing"
    rm -rf "${SOURCE_DIR}"
  fi
}

ensure_remote() {
  local current_url
  current_url="$(git -C "${SOURCE_DIR}" remote get-url origin 2>/dev/null || echo '')"
  if [[ "${current_url}" != "${REPO_URL}" ]]; then
    log "Updating origin remote to ${REPO_URL}"
    git -C "${SOURCE_DIR}" remote set-url origin "${REPO_URL}"
  fi
}

with_retries() {
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi

    if [[ ${attempt} -ge ${MAX_RETRIES} ]]; then
      log "Command failed after ${MAX_RETRIES} attempts: $*"
      return 1
    fi

    local sleep_for=$((BACKOFF_SECONDS * attempt))
    log "Command failed (attempt ${attempt}), retrying in ${sleep_for}s"
    sleep "${sleep_for}"
    attempt=$((attempt + 1))
  done
}

main() {
  mkdir -p "${ROOT_DIR}"
  prepare_source_dir

  if [[ ! -d "${SOURCE_DIR}" ]]; then
    with_retries clone_repo
  else
    ensure_remote
    with_retries update_repo
  fi

  local commit short_commit commit_date
  commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
  short_commit="$(git -C "${SOURCE_DIR}" rev-parse --short HEAD)"
  commit_date="$(git -C "${SOURCE_DIR}" show -s --format=%cI HEAD)"

  echo "SOURCE_NEWS_COMMIT=${commit}" > "${ROOT_DIR}/.source-news-meta"
  echo "SOURCE_NEWS_COMMIT_DATE=${commit_date}" >> "${ROOT_DIR}/.source-news-meta"

  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::notice::source-news updated to ${short_commit} (${commit_date})"
  else
    log "source-news updated to ${short_commit} (${commit_date})"
    log "Metadata written to ${ROOT_DIR}/.source-news-meta"
  fi
}

main "$@"

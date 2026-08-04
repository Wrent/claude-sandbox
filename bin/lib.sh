#!/bin/bash
# Shared helpers for claude-sandbox / claude-sandbox-proxy / grant-secret.sh.
set -euo pipefail

SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="claude-sandbox:latest"
NETWORK_NAME="claude-sandbox-internal"
PROXY_HOST="claude-sandbox-proxy"
GRADLE_CACHE_DIR="$HOME/.cache/claude-sandbox/gradle"
STATE_DIR="$HOME/.cache/claude-sandbox/state"

require_task_name() {
    if [ -z "${1:-}" ]; then
        echo "usage: $(basename "$0") <task-name>" >&2
        exit 1
    fi
}

container_name() {
    echo "claude-sandbox-$1"
}

# claude-sandbox / claude-sandbox-proxy are run from inside the repo you
# want to sandbox; this is how the tool learns which repo that is.
resolve_repo_root() {
    if ! git rev-parse --show-toplevel 2>/dev/null; then
        echo "error: run this from inside the git repo you want to sandbox" >&2
        exit 1
    fi
}

# grant-secret.sh can be run from anywhere, so it looks up the repo a given
# task name was started against instead of relying on the caller's cwd.
save_repo_root() {
    mkdir -p "$STATE_DIR"
    echo "$2" > "$STATE_DIR/$1"
}

load_repo_root() {
    local f="$STATE_DIR/$1"
    if [ ! -f "$f" ]; then
        echo "error: no known repo for task '$1' — was claude-sandbox ever started for it?" >&2
        exit 1
    fi
    cat "$f"
}

worktree_path() {
    echo "$2/.claude/worktrees/$1"
}

ensure_proxy_stack() {
    docker compose -f "$SANDBOX_DIR/docker-compose.yml" up -d --build proxy >/dev/null
}

ensure_image() {
    docker build \
        --build-arg USER_UID="$(id -u)" \
        -t "$IMAGE_NAME" \
        "$SANDBOX_DIR" >/dev/null
}

# Creates the worktree on a new branch named after the task if it doesn't
# already exist. Reuses it (and whatever branch it's on) otherwise.
ensure_worktree() {
    local name="$1" repo_root="$2" wt_path
    wt_path="$(worktree_path "$name" "$repo_root")"
    if [ ! -d "$wt_path" ]; then
        git -C "$repo_root" worktree add "$wt_path" -b "$name" >&2
    fi
    echo "$wt_path"
}

git_common_dir() {
    (cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd)
}

# Populates the DOCKER_ARGS array with everything shared between the
# subscription and proxy wrappers: network/hardening flags, the worktree +
# shared .git mounts (kept at identical absolute paths inside the container,
# since git worktree linkage files embed absolute host paths), and the
# Gradle cache mount.
build_common_docker_args() {
    local name="$1" wt_path="$2" repo_root="$3" git_common
    git_common="$(git_common_dir "$repo_root")"
    mkdir -p "$GRADLE_CACHE_DIR"

    DOCKER_ARGS=(
        --rm -it
        --name "$(container_name "$name")"
        --network "$NETWORK_NAME"
        --cap-drop ALL
        --security-opt no-new-privileges
        -e "http_proxy=http://${PROXY_HOST}:8888"
        -e "https_proxy=http://${PROXY_HOST}:8888"
        -e "HTTP_PROXY=http://${PROXY_HOST}:8888"
        -e "HTTPS_PROXY=http://${PROXY_HOST}:8888"
        -e "no_proxy=localhost,127.0.0.1"
        -e "GRANT_SECRET_HINT=${SANDBOX_DIR}/bin/grant-secret.sh ${name}"
        -v "${wt_path}:${wt_path}"
        -v "${git_common}:${git_common}"
        -v "${git_common}/config:${git_common}/config:ro"
        -v "${GRADLE_CACHE_DIR}:/home/sandbox/.gradle"
        -w "${wt_path}"
    )
}
